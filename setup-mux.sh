#!/bin/sh

if [[ $VERBOSE ]]; then
    set -ex
    exec 6>&2
else
    set -e
    VERBOSE=
    exec 6> /dev/null
fi
set -o nounset
set -o pipefail

info() {
    echo `date` '[INFO]' "$@"
}

err() {
    echo `date` '[ERR]' "$@"
}

debug() {
    if [ -n "${VERBOSE:-}" ] ; then
        echo `date` '[DEBUG]' "$@"
    fi
}

# check required arguments

if [ -z "${MUX_HOST:-}" ] ; then
    err MUX_HOST must be specified.  This is the external FQDN by which this service will be accessed.
    exit 1
fi

get_running_pod() {
    # $1 is component for selector
    oc get pods -l component=$1 2>&6 | awk -v sel=$1 '$1 ~ sel && $3 == "Running" {print $1}'
}

get_local_ip_addr() {
    ip ro get 8.8.8.8 | awk '{print $7}'
}

get_mux_config_files() {
    cat > $1/input-post-forward-mux.conf <<EOF
<source>
  @type secure_forward
  @label @MUX
  port "#{ENV['FORWARD_LISTEN_PORT'] || '24284'}"
  # bind 0.0.0.0 # default
  log_level "#{ENV['FORWARD_INPUT_LOG_LEVEL'] || ENV['LOG_LEVEL'] || 'warn'}"
  self_hostname "#{ENV['FORWARD_LISTEN_HOST'] || 'mux.example.com'}"
  shared_key    "#{File.open('/etc/fluent/muxkeys/mux-shared-key') do |f| f.readline end.rstrip}"

  secure yes

  cert_path        /etc/fluent/muxkeys/mux-cert
  private_key_path /etc/fluent/muxkeys/mux-key
  private_key_passphrase not_used_key_is_unencrypted
</source>
<source>
  @type tcp
  bind "#{ENV['TCP_JSON_BIND_ADDR'] || '0.0.0.0'}"
  port "#{ENV['TCP_JSON_PORT'] || '23456'}"
  tag "#{ENV['TCP_JSON_TAG'] || 'tcpjson'}"
  log_level "#{ENV['TCP_JSON_LOG_LEVEL'] || 'error'}"
  format json
  @label @MUX
</source>
<label @MUX>
  # these are usually coming as raw logs from an openshift fluentd acting
  # as a collector only
  # specifically - an openshift fluentd collector configured to use secure_forward as
  # described in https://github.com/openshift/origin-aggregated-logging/pull/264/files

  # mux hardcodes USE_JOURNAL=true to force the k8s-meta plugin to look for
  # CONTAINER_NAME instead of the tag to extract the k8s metadata - logs coming
  # from a fluentd using json-file will usually not have these fields, so add them
  <filter kubernetes.var.log.containers.**>
    @type record_transformer
    enable_ruby
    <record>
      CONTAINER_NAME \${record['CONTAINER_NAME'] || (md = /var\.log\.containers\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log\$/.match(tag); "k8s_" + md["container_name"] + ".0_" + md["pod_name"] + "_" + md["namespace"] + "_0_01234567")}
      CONTAINER_ID_FULL \${record['CONTAINER_ID_FULL'] || (md = /var\.log\.containers\.(?<pod_name>[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)_(?<namespace>[^_]+)_(?<container_name>.+)-(?<docker_id>[a-z0-9]{64})\.log\$/.match(tag); md["docker_id"])
    </record>
  </filter>

  # just redirect these to their standard processing/filtering
  <match journal system.var.log.messages system.var.log.messages.** kubernetes.var.log.containers.**>
    @type relabel
    @label @INGRESS
  </match>
  # figure out what our namespace is, and if we need to get k8s metadata
  <filter **>
    @type record_transformer
    enable_ruby
    <record>
      mux_namespace_name \${record['namespace_name'] || (tag_parts[0] == "project" && tag_parts[1]) || ENV["MUX_UNDEFINED_NAMESPACE"] || "mux-undefined"}
      mux_need_k8s_meta \${(record['namespace_uuid'] || record.fetch('kubernetes', {})['namespace_id'].nil?) ? "true" : "false"}
      kubernetes {"namespace_name":"\${record['namespace_name'] || (tag_parts[0] == 'project' && tag_parts[1]) || ENV['MUX_UNDEFINED_NAMESPACE'] || 'mux-undefined'}","namespace_id":"\${record['namespace_uuid'] || record.fetch('kubernetes', {})['namespace_id']}"}
    </record>
  </filter>
  # if the record already has k8s metadata (e.g. record forwarded from another
  # openshift or mux) then tag so that k8s meta will be skipped
  # the "mux" tag will skip all operation and app specific filtering
  # the kubernetes.mux.** tag will match the k8s-meta but no other ops and apps filtering
  <match **>
    @type rewrite_tag_filter
    @label @INGRESS
    rewriterule1 mux_need_k8s_meta ^false\$ mux
    rewriterule2 mux_namespace_name (.+) kubernetes.mux.var.log.containers.mux-mux.mux-mux_\$1_mux-0123456789012345678901234567890123456789012345678901234567890123.log
  </match>
</label>
EOF
    cat > $1/filter-pre-mux.conf <<EOF
<filter kubernetes.mux.var.log.containers.mux-mux.mux-mux_**>
  @type record_transformer
  enable_ruby
  <record>
    # add these in case k8s-meta is configured to look for journald metadata
    # mux_namespace_name added in input-post-forward-mux.conf
    CONTAINER_NAME \${record.fetch('CONTAINER_NAME', 'k8s_mux-mux.mux-mux_mux_' + record['mux_namespace_name'] + '_mux_01234567')}
    CONTAINER_ID_FULL \${record.fetch('CONTAINER_ID_FULL', '0123456789012345678901234567890123456789012345678901234567890123')}
  </record>
</filter>
EOF
    cat > $1/filter-post-mux.conf <<EOF
<filter mux kubernetes.mux.var.log.containers.mux-mux.mux-mux_**>
  # remove any fields added by previous steps
  @type record_transformer
  enable_ruby
  remove_keys mux_namespace_name,docker,CONTAINER_NAME,CONTAINER_ID_FULL,mux_need_k8s_meta,namespace_name,namespace_uuid
</filter>
EOF

    cat > $1/output-pre-internal.conf <<EOF
<match fluent.**>
  @type file
  path /var/log/mux
  time_slice_format %H
</match>
EOF
}

MUX_PUBLIC_IP=${MUX_PUBLIC_IP:-`get_local_ip_addr`}
if [ -z "$MUX_PUBLIC_IP" ] ; then
    err could determine main IP address of this system used as the public gateway
    err specify MUX_PUBLIC_IP=ip.addr which is the public egress IP address
    exit 1
fi

FORWARD_LISTEN_PORT=${FORWARD_LISTEN_PORT:-24284}

TCP_JSON_PORT=${TCP_JSON_PORT:-23456}

MUX_MEMORY_LIMIT=${MUX_MEMORY_LIMIT:-2Gi}
MUX_CPU_LIMIT=${MUX_CPU_LIMIT:-500m}

MASTER_CONFIG_DIR=${MASTER_CONFIG_DIR:-/etc/origin/master}

if [ ! -d $MASTER_CONFIG_DIR ] ; then
    # test/dev env - see if we have a KUBECONFIG
    if [ -n "${KUBECONFIG:-}" ] ; then
        MASTER_CONFIG_DIR=`dirname $KUBECONFIG`
    fi
fi

if [ ! -d $MASTER_CONFIG_DIR ] ; then
    # get from openshift server ps
    # e.g.
    #    root      2477  2471 30 04:48 ?        04:03:58 /data/src/github.com/openshift/origin/_output/local/bin/linux/amd64/openshift start --loglevel=4 --logspec=*importer=5 --latest-images=false --node-config=/tmp/openshift/origin-aggregated-logging//openshift.local.config/node-192.168.78.2/node-config.yaml --master-config=/tmp/openshift/origin-aggregated-logging//openshift.local.config/master/master-config.yaml
    MASTER_CONFIG_DIR=`ps -ef|grep -v awk|awk '/openshift.*master-config=/ {print gensub(/^.*--master-config=(\/.*)\/master-config.yaml.*$/, "\\\1", 1)}'|head -1`
fi

if [ ! -f $MASTER_CONFIG_DIR/ca.key ] ; then
    err could not find the openshift ca key needed to create the mux server cert
    err Check your permissions - you may need to run this script as root
    err Otherwise, please specify MASTER_CONFIG_DIR correctly and re-run this script
    exit 1
fi

cacert=$MASTER_CONFIG_DIR/ca.crt
cakey=$MASTER_CONFIG_DIR/ca.key
caser=$MASTER_CONFIG_DIR/ca.serial.txt

workdir=`mktemp -d`

info cleanup old mux configuration, if any . . .
oc delete -n logging dc logging-mux > /dev/null 2>&1 || :
oc delete -n logging secret logging-mux  > /dev/null 2>&1|| :
oc delete -n logging configmap logging-mux  > /dev/null 2>&1|| :
oc delete -n logging service logging-mux  > /dev/null 2>&1|| :
oc delete -n logging route logging-mux  > /dev/null 2>&1|| :
oc delete project mux-undefined  > /dev/null 2>&1 && sleep 10 || : # give it some time before recreating

# generate mux server cert/key
info generate mux server cert, key
openshift admin ca create-server-cert  \
          --key=$workdir/mux.key \
          --cert=$workdir/mux.crt \
          --hostnames=mux,$MUX_HOST \
          --signer-cert=$cacert --signer-key=$cakey --signer-serial=$caser

# generate mux shared_key
info generate mux shared key
openssl rand -base64 48 > "$workdir/mux-shared-key"

# add secret for mux
info create secret for mux
oc secrets -n logging new logging-mux \
   mux-key=$workdir/mux.key mux-cert=$workdir/mux.crt \
   mux-shared-key=$workdir/mux-shared-key mux-ca=$cacert > /dev/null

# add mux secret to fluentd service account
info add mux secret to fluentd service account
oc secrets -n logging add serviceaccount/aggregated-logging-fluentd \
   logging-fluentd logging-mux > /dev/null

# add namespace for records from unknown namespaces
info add namespace [mux-undefined] for records from unknown namespaces
oadm new-project mux-undefined --node-selector='' > /dev/null

# add namespaces for projects
for ns in ${MUX_NAMESPACES:-} ; do
    if oc get project $ns > /dev/null 2>&1 ; then
        info using existing project [$ns] - not recreating
        info "  " delete with \"oc delete project $ns\"
    else
        info adding namespace [$ns]
        oadm new-project $ns --node-selector='' > /dev/null
    fi
done

# # allow externalIPs in services
# cp ${SERVER_CONFIG_DIR}/master/master-config.yaml ${SERVER_CONFIG_DIR}/master/master-config.orig.yaml
# openshift ex config patch ${SERVER_CONFIG_DIR}/master/master-config.orig.yaml \
#           --patch="{\"networkConfig\": {\"externalIPNetworkCIDRs\": [\"0.0.0.0/0\"]}}" > \
#           ${SERVER_CONFIG_DIR}/master/master-config.yaml
# needed for 1.6/3.6

# if the fluentd image does not have /etc/fluent/configs.d/input-post-forward-mux.conf
# and the other files then we need to create a configmap for logging-mux, copy
# the fluent.conf to it from logging-fluentd configmap, and edit it to add
# the input-post-forward-mux.conf, filter-pre-mux.conf, and filter-post-mux.conf

fpod=`get_running_pod fluentd`
if oc exec $fpod -- ls /etc/fluent/configs.d/input-post-forward-mux.conf > /dev/null 2>&1 ; then
    dc_config_map=logging-fluentd
    info fluentd image has mux configuration files
else
    dc_config_map=logging-mux
    get_mux_config_files $workdir
    oc get configmap logging-fluentd \
       --template='{{index .data "fluent.conf"}}' | \
        sed -e '/dynamic\/input-docker-/d' \
            -e '/dynamic\/input-syslog-/d' \
            -e "/openshift\/input-post-/r $workdir/input-post-forward-mux.conf" \
            -e "/openshift\/filter-pre-/r $workdir/filter-pre-mux.conf" \
            -e "/openshift\/filter-post-/r $workdir/filter-post-mux.conf" \
            -e "/openshift\/output-pre-/r $workdir/output-pre-internal.conf" \
            > $workdir/fluent.conf
    oc create -n logging configmap logging-mux \
       --from-file=fluent.conf=$workdir/fluent.conf > /dev/null
    oc label -n logging configmap/logging-mux logging-infra=support > /dev/null
    info added mux configuration based on fluentd configuration
fi

# generate the mux dc from the fluentd daemonset
oc get -n logging daemonset logging-fluentd -o yaml > $workdir/fluentd.yaml

# create snippet files that we can insert with sed
cat > $workdir/1 <<EOF
  replicas: 1
  selector:
    component: mux
    provider: openshift
  strategy:
    resources: {}
    rollingParams:
      intervalSeconds: 1
      timeoutSeconds: 600
      updatePeriodSeconds: 1
    type: Rolling
  template:
EOF

cat > $workdir/2 <<EOF
        ports:
        - containerPort: ${FORWARD_LISTEN_PORT}
          name: mux-forward
        - containerPort: ${TCP_JSON_PORT}
          name: tcp-json
        volumeMounts:
        - mountPath: /etc/fluent/configs.d/user
          name: config
          readOnly: true
        - mountPath: /etc/fluent/keys
          name: certs
          readOnly: true
        - name: dockerhostname
          mountPath: /etc/docker-hostname
          readOnly: true
        - name: localtime
          mountPath: /etc/localtime
          readOnly: true
        - name: muxcerts
          mountPath: /etc/fluent/muxkeys
          readOnly: true
EOF

cat > $workdir/3 <<EOF
      volumes:
      - configMap:
          name: $dc_config_map
        name: config
      - name: certs
        secret:
          secretName: logging-fluentd
      - name: dockerhostname
        hostPath:
          path: /etc/hostname
      - name: localtime
        hostPath:
          path: /etc/localtime
      - name: muxcerts
        secret:
          secretName: logging-mux
EOF

FORWARD_LISTEN_HOST=$MUX_HOST
cat > $workdir/4 <<EOF
        - name: FORWARD_LISTEN_HOST
          value: ${FORWARD_LISTEN_HOST}
        - name: FORWARD_LISTEN_PORT
          value: "${FORWARD_LISTEN_PORT}"
        - name: TCP_JSON_PORT
          value: "${TCP_JSON_PORT}"
        - name: MUX_ALLOW_EXTERNAL
          value: "true"
        - name: USE_MUX
          value: "true"
        - name: USE_JOURNAL
          value: "true"
EOF

cp $workdir/fluentd.yaml $workdir/mux.yaml
sed -i -e 's/logging-infra: fluentd/logging-infra: mux/g' \
    -e '/creationTimestamp:/d' \
    -e '/^  generation:/d' \
    -e '/^  resourceVersion:/d' \
    -e '/^  selfLink:/d' \
    -e '/^  uid:/d' \
    -e "s/^  name: logging-fluentd/  name: logging-mux/g" \
    -e 's/component: fluentd/component: mux/' \
    -e 's/^apiVersion:.*$/apiVersion: v1/' \
    -e 's/kind: "DaemonSet"/kind: "DeploymentConfig"/' \
    -e 's/kind: DaemonSet/kind: DeploymentConfig/' \
    -e 's/name: fluentd-elasticsearch/name: mux/' \
    -e '/^  selector:/,/^  template:/d' \
    -e '/- name: USE_JOURNAL/d' \
    -e "/^spec:/r $workdir/1" \
    -e "/^        volumeMounts:/,/^      dnsPolicy:/c\      dnsPolicy: ClusterFirst" \
    -e "/^      nodeSelector:/,/^      restartPolicy:/c\      restartPolicy: Always" \
    -e "/^        imagePullPolicy: Always/r $workdir/2" \
    -e '/^      volumes:/,$d' \
    -e "/^      terminationGracePeriodSeconds:/r $workdir/3" \
    -e "/^      - env:/r $workdir/4" \
    -e "s/cpu: .*$/cpu: ${MUX_CPU_LIMIT}/" \
    -e "s/memory: .*$/memory: ${MUX_MEMORY_LIMIT}/" \
    $workdir/mux.yaml

oc create -f $workdir/mux.yaml > /dev/null
info created mux deployment configuration

cat <<EOF | oc create -n logging -f - > /dev/null
apiVersion: v1
kind: Service
metadata:
  name: logging-mux
spec:
  ports:
    -
      port: ${FORWARD_LISTEN_PORT}
      targetPort: mux-forward
      name: mux-forward
    -
      port: ${TCP_JSON_PORT}
      targetPort: tcp-json
      name: tcp-json
  externalIPs:
  - $MUX_PUBLIC_IP
  selector:
    provider: openshift
    component: mux
EOF
info created mux service

# test with openssl s_client like this:
## openssl s_client -quiet -connect mux.example.com:24284
# depth=1 CN = openshift-signer@1480618407
# verify return:1
# depth=0 CN = mux
# verify return:1
# �Y*,�auth��keepalive��
# ��PONG´invalid ping message��
# note the garbage looking message above - that means you are talking directly to the
# fluentd secure_forward, not an http proxy/router

oc get -n logging secret logging-mux --template='{{index .data "mux-ca"}}' | base64 -d > mux-ca.crt
if [ -n "${VERBOSE:-}" ] ; then
    openssl x509 -in mux-ca.crt -text | head
fi

oc get -n logging secret logging-mux --template='{{index .data "mux-shared-key"}}' | \
    base64 -d > mux-shared-key

info Success: the CA cert is in mux-ca.crt - the shared key is in mux-shared-key
ls -al mux-ca.crt mux-shared-key
