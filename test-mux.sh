#! /bin/bash

# test the mux route and service
# - can accept secure_forward from a "client" fluentd

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

ARTIFACT_DIR=${ARTIFACT_DIR:-${TMPDIR:-/tmp}/origin-aggregated-logging}
if [ ! -d $ARTIFACT_DIR ] ; then
    mkdir -p $ARTIFACT_DIR
fi

PROJ_PREFIX=project.

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

# $1 - es pod name
# $2 - index name (e.g. project.logging, project.test, .operations, etc.)
# $3 - _count or _search
# $4 - field to search
# $5 - search string
# stdout is the JSON output from Elasticsearch
# stderr is curl errors
query_es_from_es() {
    oc exec $1 -- curl --connect-timeout 1 -s -k \
       --cert /etc/elasticsearch/secret/admin-cert --key /etc/elasticsearch/secret/admin-key \
       https://localhost:9200/${2}*/${3}\?q=${4}:${5}
}

get_count_from_json() {
    python -c 'import json, sys; print json.loads(sys.stdin.read()).get("count", 0)'
}

# $1 - unique value to search for in es
add_test_message() {
    local kib_pod=`get_running_pod kibana`
    oc exec $kib_pod -c kibana -- curl --connect-timeout 1 -s \
       http://localhost:5601/$1 > /dev/null 2>&1
}

# $1 - shell command or function to call to test if wait is over -
#      this command/function should return true if the condition
#      has been met, or false if still waiting for condition to be met
# $2 - shell command or function to call if we timed out for error handling
# $3 - timeout in seconds - should be a multiple of $4 (interval)
# $4 - loop interval in seconds
wait_until_cmd_or_err() {
    let ii=$3
    interval=${4:-1}
    while [ $ii -gt 0 ] ; do
        $1 && break
        sleep $interval
        let ii=ii-$interval
    done
    if [ $ii -le 0 ] ; then
        $2
        return 1
    fi
    return 0
}

get_running_pod() {
    # $1 is component for selector
    oc get pods -l component=$1 2>&6 | awk -v sel=$1 '$1 ~ sel && $3 == "Running" {print $1}'
}

wait_for_pod_action() {
    # action is $1 - start or stop
    # $2 - if action is stop, $2 is the pod name
    #    - if action is start, $2 is the component selector
    ii=120
    incr=10
    if [ $1 = start ] ; then
        curpod=`get_running_pod $2`
    else
        curpod=$2
    fi
    while [ $ii -gt 0 ] ; do
        if [ $1 = stop ] && oc describe pod/$curpod > /dev/null 2>&1 ; then
            debug pod $curpod still running
        elif [ $1 = start ] && [ -z "$curpod" ] ; then
            debug pod for component=$2 not running yet
        else
            break # pod is either started or stopped
        fi
        sleep $incr
        ii=`expr $ii - $incr`
        if [ $1 = start ] ; then
            curpod=`get_running_pod $2`
        fi
    done
    if [ $ii -le 0 ] ; then
        err pod $2 not in state $1 after several minutes
        oc get pods
        return 1
    fi
    return 0
}

cleanup_forward() {

  # Revert configmap if we haven't yet
  if [ -n "$(oc get configmap/logging-fluentd -o yaml | grep '<match \*\*>')" ]; then
    oc get configmap/logging-fluentd -o yaml | sed -e '/<match \*\*>/ d' \
        -e '/@include configs\.d\/user\/secure-forward\.conf/ d' \
        -e '/<\/match>/ d' | oc replace -f - > /dev/null
  fi

  if oc get daemonset/logging-fluentd -o yaml | grep -q /etc/fluent/mux ; then
      oc patch daemonset/logging-fluentd --type=json --patch '[
       {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts/8"},
       {"op":"remove","path":"/spec/template/spec/volumes/8"}]' > /dev/null
  fi

  oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "replace", "path": "/data/secure-forward.conf", "value": "\
# @type secure_forward\n\
# self_hostname forwarding-${HOSTNAME}\n\
# shared_key aggregated_logging_ci_testing\n\
#  secure no\n\
#  <server>\n\
#   host ${FLUENTD_FORWARD}\n\
#   port 24284\n\
#  </server>"}]' > /dev/null || :

}

update_current_fluentd() {
  # this will update it so the current fluentd does not send logs to an ES host
  # but instead forwards to the forwarding fluentd

  # undeploy fluentd
  oc label node --all logging-infra-fluentd- > /dev/null

  wait_for_pod_action stop $fpod

  # edit so we don't filter or send to ES
  oc get configmap/logging-fluentd -o yaml | sed '/## filters/ a\
      <match **>\
        @include configs.d/user/secure-forward.conf\
      </match>' | oc replace -f - > /dev/null

  MUX_HOST=${MUX_HOST:-mux.example.com}
  # ca cert `oc get secret/logging-fluentd --template='{{index .data "ca"}}'`
  # add a volume and volumemount for the logging-mux secret to fluentd
  oc patch daemonset/logging-fluentd --type=json --patch '[
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/8","value":{"name":"mux","mountPath":"/etc/fluent/mux","readOnly":true}},
    {"op":"add","path":"/spec/template/spec/volumes/8","value":{"name":"mux","secret":{"secretName":"logging-mux"}}}]' > /dev/null
  # update configmap secure-forward.conf
  oc patch configmap/logging-fluentd --type=json --patch '[{ "op": "replace", "path": "/data/secure-forward.conf", "value": "\
  @type secure_forward\n\
  self_hostname forwarding-${HOSTNAME}\n\
  ca_cert_path /etc/fluent/mux/mux-ca\n\
  secure yes\n\
  shared_key \"#{File.open('"'"'/etc/fluent/mux/mux-shared-key'"'"') do |f| f.readline end.rstrip}\"\n\
  <server>\n\
   host logging-mux\n\
   hostlabel '"$MUX_HOST"'\n\
   port 24284\n\
  </server>"}]' > /dev/null

  # redeploy fluentd
  oc label node --all logging-infra-fluentd=true > /dev/null

  # wait for fluentd to start
  wait_for_pod_action start fluentd
}

# return true if the actual count matches the expected count, false otherwise
test_count_expected() {
    myfield=${myfield:-message}
    local nrecs=`query_es_from_es $espod $myproject _count $myfield $mymessage | \
           get_count_from_json`
    test "$nrecs" = $expected
}

# display an appropriate error message if the expected count did not match
# the actual count
test_count_err() {
    myfield=${myfield:-message}
    nrecs=`query_es_from_es $espod $myproject _count $myfield $mymessage | \
           get_count_from_json`
    err found $nrecs records for project $myproject message $mymessage - expected $expected
    for thetype in _count _search ; do
        query_es_from_es $espod $myproject $thetype $myfield $mymessage | python -mjson.tool
    done
}

write_and_verify_logs() {
    # expected number of matches
    expected=$1
    local es_pod=`get_running_pod es`
    local es_ops_pod=`get_running_pod es-ops`
    if [ -z "$es_ops_pod" ] ; then
        es_ops_pod=$es_pod
    fi
    local uuid_es=`uuidgen`
    local uuid_es_ops=`uuidgen`

    add_test_message $uuid_es
    logger -i -p local6.info -t $uuid_es_ops $uuid_es_ops

    local rc=0

    # poll for logs to show up

    info added test messages, waiting 10 minutes for them to show up in Elasticsearch . . .
    if espod=$es_pod myproject=project.logging mymessage=$uuid_es expected=$expected \
            wait_until_cmd_or_err test_count_expected test_count_err 600 ; then
        info good - record found for project logging for $uuid_es
    else
        err failed - record not found for project logging for $uuid_es
        rc=1
    fi

    if espod=$es_ops_pod myproject=.operations mymessage=$uuid_es_ops expected=$expected myfield=systemd.u.SYSLOG_IDENTIFIER \
            wait_until_cmd_or_err test_count_expected test_count_err 600 ; then
        info good - record found for .operations for $uuid_es_ops
    else
        err failed - record not found for .operations for $uuid_es_ops
        rc=1
    fi

    return $rc
}

restart_fluentd() {
    oc label node --all logging-infra-fluentd- > /dev/null
    # wait for fluentd to stop
    wait_for_pod_action stop $fpod
    # create the daemonset which will also start fluentd
    oc label node --all logging-infra-fluentd=true > /dev/null
    # wait for fluentd to start
    wait_for_pod_action start fluentd
}

TEST_DIVIDER="------------------------------------------"

oc project logging > /dev/null

fpod=`get_running_pod fluentd`

if [ -z "$fpod" ] ; then
    err fluentd is not running
    exit 1
fi

if [ -z "`get_running_pod kibana`" ] ; then
    err kibana is not running
    exit 1
fi

if [ -z "`get_running_pod es`" ] ; then
    err es is not running
    exit 1
fi

# run test to make sure fluentd is working normally - no forwarding
info Testing to see if logging is working normally . . .
write_and_verify_logs 1 || {
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
    exit 1
}

cleanup() {
    # put back original configuration
    oc logs $fpod  > $ARTIFACT_DIR/$fpod.log
    cleanup_forward
    restart_fluentd
    oc get events -o yaml > $ARTIFACT_DIR/all-events.yaml 2>&1
}
trap "cleanup" INT TERM EXIT

info logging is working normally - changing fluentd to write to mux and testing mux . . . 
update_current_fluentd

fpod=`get_running_pod fluentd`

write_and_verify_logs 1

# put back original configuration
cleanup
fpod=`get_running_pod fluentd`

info mux is working normally - resetting logging and testing again . . .
write_and_verify_logs 1
info Success - mux works, logging is working normally
