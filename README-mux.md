Setting Up ViaQ Logging
=======================

Intro
-----

ViaQ Logging is based on the [OpenShift
Logging](https://github.com/openshift/origin-aggregated-logging) stack.  You
can use either the OpenShift Container Platform (OCP) based on RHEL7, or
OpenShift Origin (Origin) based on CentOS7.

The component which uses the secure_forward listener in OpenShift is called
*mux*, short for multiplex, because it acts like a multiplexor or manifold,
taking in connections from many collectors, and distributing them to a data
store.  Another term would be FEAN, short for
Forward/Enrich/Aggregate/Normalize.

This document uses the term *mux* to refer to this component.

Provisioning a machine to run ViaQ
----------------------------------

**WARNING** DO NOT INSTALL `libvirt` on the OpenShift machine!  You will run
  into all sorts of problems related to name resolution and DNS.  For example,
  your pods will not start, will be in the Error state, and will have messages
  like this: `tcp: lookup kubernetes.default.svc.cluster.local: no such host`

ViaQ on OCP requires a RHEL 7.3 or later machine.  ViaQ on Origin requires a
up-to-date CentOS 7 machine.  You must be able to ssh into the machine using an
ssh keypair.  This means you will need to:

* assign the machine an FQDN and IP address so that it can be reached from
  another machine - these are the **public_hostname** and **public_ip**
* use `root` (or create a user account) - this user will be referred to below
  as `$USER`
* provide an ssh pubkey for this user account (`ssh-keygen`)
* add the ssh pubkey to the user account `$USER/.ssh/authorized_keys`
  * `cat $USER/.ssh/id_rsa.pub >> $USER/.ssh/authorized_keys`
* add the ssh hostkey for localhost to your SSH `known_hosts`
  * `ssh-keyscan -H localhost >> $USER/.ssh/known_hosts`
* add the ssh hostkey for **public_hostname** to your SSH `known_hosts`
  * `ssh-keyscan -H **public_hostname** >> $USER/.ssh/known_hosts`
* if not using root, enable passwordless sudo e.g. in sudoers config:
  * `$USER ALL=(ALL) NOPASSWD:ALL`
* allow connections on the following ports/protocols:
  * icmp (for ping)
  * tcp ports 22, 80, 443, 8443 (openshift console), 24284 (secure_forward)

This will allow you to access the machine via ssh (in order to run Ansible -
see below), to access the external services such as Kibana and mux, and to
access the OpenShift UI console.  Yes, openshift-ansible in some cases will
attempt to ssh to localhost.

ViaQ on OCP requires a RHEL and OCP subscription.

ViaQ on Origin requires these [Yum Repos](centos7-viaq.repo).
You will need to install the following packages: docker iptables-services

You will need to configure sudo to not require a tty.  For example, create a
file like `/etc/sudoers.d/999-cloud-init-requiretty` with the following contents:

    # cat /etc/sudoers.d/999-cloud-init-requiretty
    Defaults !requiretty

Installing ViaQ
---------------

These instructions and config files are for an all-in-one, single machine, run
ansible on the same machine you are installing ViaQ on.

*NOTE* *THIS IS NOT FOR PRODUCTION USE*

The setup below is for a developer or demo machine, all-in-one, running
Ansible in *local* mode to install ViaQ on the same machine as Ansible is
running on.  It also configures the `AllowAllPasswordIdentityProvider` which
means anyone can log in using the OpenShift UI.

Ansible is used to install ViaQ and OCP or Origin using OpenShift Ansible.
The following packages are required: openshift-ansible
openshift-ansible-callback-plugins openshift-ansible-filter-plugins
openshift-ansible-lookup-plugins openshift-ansible-playbooks
openshift-ansible-roles

    # yum install openshift-ansible \
      openshift-ansible-callback-plugins openshift-ansible-filter-plugins \
      openshift-ansible-lookup-plugins openshift-ansible-playbooks \
      openshift-ansible-roles

If the 3.5/1.5 versions of these packages are not available, you can use the
git repo `https://github.com/openshift/openshift-ansible.git` and the
`release-1.5` branch:

    # git clone https://github.com/openshift/openshift-ansible.git -b release-1.5

You will need to use the `ansible-playbook` command with an Ansible inventory
file and a `vars.yaml` file.  You should not have to edit the inventory file.
All customization can be done via the `vars.yaml` file.

Download the files [vars.yaml.template](vars.yaml.template) and
[ansible-inventory-origin-15-aio](ansible-inventory-origin-15-aio)

    # curl https://raw.githubusercontent.com/ViaQ/Main/master/vars.yaml.template > vars.yaml.template
    # curl https://raw.githubusercontent.com/ViaQ/Main/master/ansible-inventory-origin-15-aio > ansible-inventory

To use ViaQ on Red Hat OCP, use the
[ansible-inventory-ocp-35-aio](ansible-inventory-ocp-35-aio) file:

    # curl https://raw.githubusercontent.com/ViaQ/Main/master/ansible-inventory-ocp-35-aio > ansible-inventory

There is currently a bug in openshift-ansible 1.5
[cert_ext bug](https://github.com/openshift/openshift-ansible/pull/4019) which
requires the following patch:

    # curl https://raw.githubusercontent.com/ViaQ/Main/master/0001-Compatibility-updates-to-openshift_logging-role-for-.patch > 0001-Compatibility-updates-to-openshift_logging-role-for-.patch
    # cd /usr/share/ansible/openshift-ansible
    # patch -p1 -b < 0001-Compatibility-updates-to-openshift_logging-role-for-.patch

It doesn't matter where you save these files, but you will need to know the
full path and filename for the `ansible-inventory` and `vars.yaml` files for
the `ansible-playbook` command below.

Copy `vars.yaml.template` to `vars.yaml`.  Then edit `vars.yaml`.  You can use
ansible to check some of the values, to see which values you need to edit. For
example, use

    ansible -m setup localhost -a 'filter=ansible_fqdn'

to see if ansible correctly reports your host's FQDN, the **public_hostname**
value from above.  If so, then you do not have to edit
`openshift_public_hostname` below.  Use

    ansible -m setup localhost -a 'filter=ansible_default_ipv4'

to see if ansible correctly reports your IP address in the `"address"` field,
which should be the same as the **public_ip** value from above.  If so, then
you do not have to edit `openshift_public_ip`.  You can also verify which IP
address is used for external use by using the following command:

    $ ip -4 route get 8.8.8.8
    8.8.8.8 via 10.0.0.1 dev enp0s25 src 10.10.10.10 uid 1000

This means your IP address is `10.10.10.10`.  Depending on what you can
determine using ansible, you may need to change the following fields in
`vars.yaml`:

* `ansible_ssh_user` - this is either `root`, or the user created in
  [provisioning](#provisioning-a-machine-to-run-viaq) which can use
  passwordless ssh
* `ansible_become` - use `no` if `ansible_ssh_user` is `root`, otherwise,
  use `yes`
* `openshift_public_hostname` - this is the **public_hostname** value mentioned
  above which should have been assigned during the provisioning of the
  machine.  This must be an FQDN, and must be accessible from another machine.
* `openshift_public_ip` - this is the **public_ip** address value mentioned
  above which should have been assigned during the provisioning of the machine.
  This is the IP address that will be used from other machines to connect to
  this machine.  It will typically be used in your DNS, `/etc/hosts`, or
  whatever host look up is used for browsers and other external client
  programs.  For example, in OpenStack, this will be the **floating ip**
  address of the machine.  This may be the same as the `eth0` IP address of the
  machine, in which case, just use `"{{ ansible_default_ipv4.address }}"` as the
  value
* `openshift_master_default_subdomain` - this is the public subdomain to use
  for all of the external facing logging services, such as the OpenShift UI,
  Kibana, mux, and Elasticsearch.  By default, the
  **openshift_public_hostname** will be used.  Kibana will be accessed at
  `https://kibana.{{ openshift_master_default_subdomain }}`, etc.
* `openshift_hostname` - this is the private hostname of the machine that will
  be used inside the cluster.  For example, OpenStack machines will have a
  "private" hostname assigned by Neutron networking.  This may be the same as
  the external hostname if you do not have a "private" hostname - in that case,
  just use `{{ openshift_public_hostname }}`
* `openshift_ip` - the private IP address, if your machine has a different
  public and private IP address - this is almost always the value reported by
  `ansible -m setup localhost -a filter=ansible_default_ipv4` as described above
* `openshift_logging_master_public_url` - this is the public URL for
  OpenShift UI access - you can usually use the default value
* `openshift_logging_kibana_hostname` - this is the public hostname for Kibana
  browser access - you can usually use the default value

You can also override variables in the inventory by setting them in `vars.yaml`.

### Note about hostnames and IP addresses in this document ###

**NOTE**: In the sections that follow, the text that refers to specifc
  hostnames and IP addresses should be changed to the values you set in your
  `vars.yaml` file.
* `10.16.19.171` - replace this with your `openshift_public_ip`
* `192.168.122.4` - replace this with your `openshift_ip`
* `openshift.logging.test` - replace this with your `openshift_public_hostname`
* `kibana.logging.test` - replace this with `openshift_logging_kibana_hostname`
* `mux.logging.test` - replace this with mux.`openshift_master_default_subdomain`

The public hostname would typically be a DNS entry for the
public IP address, but you can "fake" these out with `/etc/hosts` entries:

    10.16.19.171 openshift.logging.test kibana.logging.test mux.logging.test

That is, unless you have configured DNS or some other host lookup service, you
will need to make similar changes to `/etc/hosts` from all client machines from
which you will use Kibana, or access the Elasticsearch API directly, or from
which you will send logs to the mux.

Once you have your inventory and `vars.yaml`, you can run ansible:

    # cd /usr/share/ansible/openshift-ansible
    # (or wherever you cloned the git repo if using git)
    # ANSIBLE_LOG_PATH=/tmp/ansible.log ansible-playbook -vvv \
      -e @/path/to/vars.yaml \
      -i /path/to/ansible-inventory playbooks/byo/config.yml

where `/path/to/vars.yaml` is the full path and file name where you saved your
`vars.yaml` file, and `/path/to/ansible-inventory` is the full path and file
name where you saved your `ansible-inventory` file.

Check `/tmp/ansible.log` if there are any errors during the run.  If this
hangs, just kill it and run it again - Ansible is (mostly) idempotent.  Same
applies if there are any errors during the run - fix the machine and/or the
`vars.yaml` and run it again.

To confirm that OpenShift and logging are working:

    # oc project logging
    # oc get pods

You should see the Elasticsearch, Curator, Kibana, and Fluentd pods running.

Configuring mux
---------------

You will need a publicly accessible hostname to access the mux.  You can use a
hostname alias in `/etc/hosts` as described above in
[Installing](#installing-viaq).  By default, the mux hostname is
mux.`openshift_master_default_subdomain`

    10.16.19.171 openshift.logging.test kibana.logging.test mux.logging.test

Download and run the [setup-mux.sh](setup-mux.sh) script.  The only required
parameter is `MUX_HOST` which is the FQDN you will use to access mux
externally, and will also be used in the mux TLS server cert subject DN.  The
`MUX_NAMESPACES` parameter is used to pass in a list of space-delimited
namespaces to create in mux for your logs.  See
[mux-logging-service.md](https://github.com/openshift/origin-aggregated-logging/blob/master/docs/mux-logging-service.md)
for a description about how mux detects and separates logs into
namespaces. Basically, you can specify a namespace for your logs, and only
users who are members of those namespaces can view those logs.  If you do not
use `MUX_NAMESPACES` your logs will go into the `mux-undefined` namespace.

    # oc project logging
    # curl https://raw.githubusercontent.com/ViaQ/Main/master/setup-mux.sh > setup-mux.sh
    # chmod +x setup-mux.sh
    # MUX_HOST=mux.logging.test MUX_NAMESPACES="my-first-namespace my-other-ns" ./setup-mux.sh

This will create the `logging-mux` configmap, secrets, dc, pod, and service.

    # oc get pods -l component=mux
    NAME                  READY     STATUS    RESTARTS   AGE
    logging-mux-1-yxx1o   1/1       Running   0          1h
    # oc get svc logging-mux
    NAME          CLUSTER-IP      EXTERNAL-IP   PORT(S)     AGE
    logging-mux   172.30.215.88   10.0.0.3      24284/TCP   1h

mux also creates a `TCP JSON` listener.  *THIS IS INSECURE - USE WITH
CAUTION*.  By default it listens to port `23456`.  You can use this for testing
clients that do not support fluentd secure_forward.  e.g.

    $ echo '{"hello":"world","@timestamp":"2017-05-23T21:27:52.554908+00:00"}' | \
      nc --send-only 192.168.122.4 23456

The externalIP value should be the IP address of your `eth0` interface, or
whichever interface on the machine is used for external egress.  The script
should automatically determine this.  If it is unable to, specify it with
the environment variable `MUX_PUBLIC_IP`:

    # MUX_HOST=mux.logging.test MUX_PUBLIC_IP=192.168.122.4 \
      MUX_NAMESPACES="my-first-namespace my-other-ns" ./setup-mux.sh

You can test with `openssl s_client` like this:

    # echo hello | openssl s_client -quiet -connect localhost:24284
    depth=1 CN = openshift-signer@1480618407
    verify return:1
    depth=0 CN = mux
    verify return:1
    ��HELO��nonce�Aa���3�/��Ps��auth��keepaliveÕ�PONG´invalid ping message��

If you get something that looks like this: `Connection refused connect:errno=111`
Try this:

    # netstat -nlt|grep 24284

It should show mux listening to port 24284 on some IP address:

    tcp        0      0 10.16.19.171:24284        0.0.0.0:*               LISTEN

Try `echo hello | openssl s_client -quiet -connect 10.16.19.171:24284`, or try
`$(hostname):24284`.  If this works, this means you are able to access the
Fluentd secure_forward listener.  Don't worry about the garbage characters and
invalid message.

There is a test script [test-mux.sh](test-mux.sh) you can use to test that the
mux is working.  It will reconfigure the regular OpenShift Fluentd to send its
logs to the mux instead of to Elasticsearch directly, and then add some log
messages to see if the mux sends them to Elasticsearch.

    # oc project logging
    # curl https://raw.githubusercontent.com/ViaQ/Main/master/test-mux.sh > test-mux.sh
    # chmod +x test-mux.sh
    # MUX_HOST=mux.logging.test ./test-mux.sh

To search Elasticsearch, first get the name of the Elasticsearch pod:

    # oc project logging
    # espod=`oc get pods -l component=es -o jsonpath='{.items[0].metadata.name}'`

Then use `oc exec` and `curl` like this.  Substitute `logging` with
`mux-undefined` or your namespace name:

    # oc exec $espod -- curl --connect-timeout 1 -s -k \
      --cert /etc/elasticsearch/secret/admin-cert \
      --key /etc/elasticsearch/secret/admin-key \
      'https://localhost:9200/project.logging.*/_search?sort=@timestamp:desc' | \
      python -mjson.tool | more
    {
        "_shards": {
            "failed": 0,
            "successful": 1,
            "total": 1
        },
        "hits": {
            "hits": [
                {
                    "_id": "AVi70uBa6F1hLfsBbCQq",
                    "_index": "project.logging.42eab680-b7f9-11e6-a793-fa163e8a98f9.2016.12.01",
                    "_score": 1.0,
                    "_source": {
                        "@timestamp": "2016-12-01T14:09:53.848788-05:00",
                        "docker": {
                            "container_id": "adcf8981baf37f3dab0a659fbd78d6084fde0a2798020d3c567961a993713405"
                        },
                        "hostname": "host-192-168-78-2.openstacklocal",
                        "kubernetes": {
                            "container_name": "deployer",
                            "host": "host-192-168-78-2.openstacklocal",
                            "labels": {
                                "app": "logging-deployer-template",
                                "logging-infra": "deployer",
                                "provider": "openshift"
                            },
                            "namespace_id": "42eab680-b7f9-11e6-a793-fa163e8a98f9",
                            "namespace_name": "logging",
                            "pod_id": "b2806c29-b7f9-11e6-a793-fa163e8a98f9",
                            "pod_name": "logging-deployer-akqwb"
                        },
                        "level": "3",
                        "message": "writing new private key to '/etc/deploy/scratch/system.logging.fluentd.key'",
                        "pipeline_metadata": {
                            "collector": {
                                "inputname": "fluent-plugin-systemd",
                                "ipaddr4": "10.128.0.26",
                                "ipaddr6": "fe80::30e3:7cff:fe55:4134",
                                "name": "fluentd openshift",
                                "received_at": "2016-12-01T14:09:53.848788-05:00",
                                "version": "0.12.29 1.4.0"
                            }
                        }
                    },
                    "_type": "com.redhat.viaq.common"
                }
            ],
            "max_score": 1.0,
            "total": 1453
        },
        "timed_out": false,
        "took": 15
    }

Getting the shared_key and CA cert
----------------------------------

In order to configure the client side of Fluentd secure_forward, you will need
the values for the `shared_key` and the `ca_cert_path`.  For the first
iteration, you will just use the ones generated by the `setup-mux.sh` script.

    # oc project logging
    # oc get secret logging-mux --template='{{index .data "mux-ca"}}' | base64 -d > mux-ca.crt
    # openssl x509 -in mux-ca.crt -text | more
    Certificate:
    ...
        Subject: CN=openshift-signer@1480618407
    ...
    # oc get secret logging-mux --template='{{index .data "mux-shared-key"}}' | \
      base64 -d > mux-shared-key

Use the `mux-ca.crt` and `mux-shared-key` to configure the Fluent
secure_forward clients.  The `setup-mux.sh` script will generate these for you,
but use the above instructions if you need to regenerate them.

Client side setup
-----------------

The client side setup should look something like this:

    # warn is too verbose unless you are debugging
    <system>
      log_level error
    </system>

    # do not send internal fluentd events to mux
    <match fluent.**>
      @type stdout
    </match>

    <match **something**>
      @type secure_forward
      self_hostname forwarding-${hostname}
      ca_cert_path /path/to/mux-ca.crt
      secure yes
      enable_strict_verification true
      shared_key "#{File.open('/path/to/mux-shared-key') do |f| f.readline end.rstrip}"
      <server>
        host mux.logging.test
        hostlabel mux.logging.test
        port 24284
      </server>
    </match>

Running Kibana
--------------

You will first need to create an OpenShift user and assign this user rights to
view the application and operations logs.  The install above uses the
AllowAllPasswordIdentityProvider which makes it easy to create test users like
this:

    # oc project logging
    # oc login --username=admin --password=admin
    # oc login --username=system:admin
    # oadm policy add-cluster-role-to-user cluster-admin admin

Now you can use the `admin` username and password to access Kibana.  Just
point your web browser at `https://kibana.logging.test` where the
`logging.test` part is whatever you specified in the 
`openshift_master_default_subdomain` parameter in the `vars.yaml` file.

## Appendix 1 CentOS7 ViaQ yum repos

[CentOS 7 ViaQ](centos7-viaq.repo)
