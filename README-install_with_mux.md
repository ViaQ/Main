Setting Up ViaQ Logging
=======================

Intro
-----

ViaQ Logging is based on the [OpenShift
Logging](https://github.com/openshift/origin-aggregated-logging) stack.  You
can use either the OpenShift Container Platform (OCP) based on RHEL7, or
OpenShift Origin (Origin) based on CentOS7.  Ansible is used to install logging
using the [OpenShift Ansible](https://github.com/openshift/openshift-ansible)
logging
[roles](https://github.com/openshift/openshift-ansible/blob/master/roles/openshift_logging/README.md).

Provisioning a machine to run ViaQ
----------------------------------

**WARNING** DO NOT INSTALL `libvirt` on the OpenShift machine!  You will run
  into all sorts of problems related to name resolution and DNS.  For example,
  your pods will not start, will be in the Error state, and will have messages
  like this: `tcp: lookup kubernetes.default.svc.cluster.local: no such host`

ViaQ is based on OpenShift logging.  The instructions below assume that you
will be installing on a machine that will be the OpenShift master node, so you
will need to ensure the machine meets at least the Minimum Hardware
Requirements for a [master
node](https://docs.openshift.org/latest/install_config/install/prerequisites.html#hardware)

ViaQ on OCP requires a RHEL 7.3 or later machine.  ViaQ on Origin requires a
up-to-date CentOS 7 machine.  You must be able to ssh into the machine using an
ssh keypair.  The instructions below assume you are running ansible on the same
machine that you are going to be using to run logging (as an all-in-one or aio
deployment).  You will need to do the following on this machine:

* assign the machine an FQDN and IP address so that it can be reached from
  another machine - these are the **public_hostname** and **public_ip**
* use `root` (or create a user account) - this user will be referred to below
  as `$USER`
* provide an ssh pubkey for this user account (`ssh-keygen`)
* add the ssh pubkey to the user account `$HOME/.ssh/authorized_keys`
  * `cat $HOME/.ssh/id_rsa.pub >> $HOME/.ssh/authorized_keys`
* add the ssh hostkey for localhost to your SSH `known_hosts`
  * `ssh-keyscan -H localhost >> $HOME/.ssh/known_hosts`
* add the ssh hostkey for **public_hostname** to your SSH `known_hosts`
  * `ssh-keyscan -H **public_hostname** >> $HOME/.ssh/known_hosts`
* This step is only needed if not using root - enable passwordless sudo e.g. in
  sudoers config:
  * `$USER ALL=(ALL) NOPASSWD:ALL`
* allow connections on the following ports/protocols:
  * icmp (for ping)
  * tcp ports 22, 80, 443, 8443 (openshift console), 24284 (secure_forward)

To verify that passwordless ssh works, and that you do not get prompted to
accept host verification, try this:

    # ssh localhost 'ls -al'
    # ssh **public_hostname** 'ls -al'

You should not be prompted for a password nor to accept the host verification.

This will allow you to access the machine via ssh (in order to run Ansible -
see below), to access the external services such as Kibana and mux, and to
access the OpenShift UI console.  Yes, openshift-ansible in some cases will
attempt to ssh to localhost.

ViaQ on OCP requires a RHEL and OCP subscription.  For more information about
RHEL configuration, see
[Host Registration](https://access.redhat.com/documentation/en-us/openshift_container_platform/3.5/html/installation_and_configuration/installing-a-cluster#host-registration)
For RHEL, you must enable the Extras and the rhel-7-fast-datapath-rpms channels
(for docker and ovs, among others).

ViaQ on Origin requires these [Yum Repos](centos7-viaq.repo).
You will need to install the following packages: docker, iptables-services &
NetworkManager.

You'll also need to enable and start NetworkManager:

    systemctl enable NetworkManager
    systemctl start NetworkManager

You will need to configure sudo to not require a tty.  For example, create a
file like `/etc/sudoers.d/999-cloud-init-requiretty` with the following contents:

    # cat /etc/sudoers.d/999-cloud-init-requiretty
    Defaults !requiretty

Persistent Storage
------------------

**NOTE** You currently cannot have two mux pods running on the same host at the
  same time when both are using persistent storage.  If you set
  `openshift_logging_mux_replicas` to be greater than 1, you must also disable
  persistent storage for mux:
  `openshift_logging_mux_file_buffer_storage_type: "emptydir"`
  See [BZ 1489410](https://bugzilla.redhat.com/show_bug.cgi?id=1489410)

Elasticsearch, Fluentd, and mux all require persistent storage - Elasticsearch
for the database, and Fluentd and mux for the file buffering.  Fluentd and mux
will use the host paths `/var/lib/fluentd` and `/var/log/fluentd`,
respectively, by default.  Inside the pods, these are mounted at
`/var/lib/fluentd`.  The disk space usage for Fluentd and mux will depend on
how fast mux and Elasticsearch can process and ingest the logs.  Fluentd uses
the `vars.yaml` (see below) parameter
`openshift_logging_fluentd_file_buffer_limit` (default `1Gi` for 1 Gigabyte) to
control the size of the file buffer, and mux uses
`openshift_logging_mux_file_buffer_limit` (default `2Gi` for 2 Gigabytes).
This amount of disk space in the `/var` partition is usually not a problem, but
if you plan to run on a system with reduced disk space, you should make sure
that `/var` has enough to accomodate this.  The buffer file limit is per output
plugin, so if you have enabled the separate `ops` cluster, or are copying logs
off of the cluster using `secure_forward`, this will increase the disk space
usage.

We recommend using SSD drives for the partition on which you will install
logging.  Your storage needs will vary based on the number of applications, the
number of hosts, the log severity level, and the log retention policy.  A large
installation may need 100GB per day of retention, or more.

Elasticsearch uses ephemeral storage by default, and so has to be manually
configured to use persistence.

- First, since Elasticsearch can use many GB of disk space, and may fill up the
  partition, you are strongly recommended to use a partition other than root
  `/` to avoid filling up the root partition.
- Find a partition that can easily accomodate many GB of storage.
- Create the directory e.g. `mkdir -p /var/lib/elasticsearch`
- Change the group ownership to the value of your
  `openshift_logging_elasticsearch_storage_group` parameter (default `65534`)
  e.g. `chgrp 65534 /var/lib/elasticsearch`
- make this directory accessible by the group `chmod -R 0770 /var/lib/elasticsearch`
- add the following selinux policy:

        semanage fcontext -a -t container_file_t "/var/lib/elasticsearch(/.*)?"

If `container_file_t` is not available, use `svirt_sandbox_file_t` instead:

        semanage fcontext -a -t svirt_sandbox_file_t "/var/lib/elasticsearch(/.*)?"

Then apply the changes to the filesystem:

        restorecon -R -v /var/lib/elasticsearch

Then run ViaQ installation.  The installation of Elasticsearch will fail
because there is currently no way to grant the Elasticsearch service account
permission to mount that directory.  After installation is complete, do the
following steps to enable Elasticsearch to mount the directory:

        # oc project logging
        # oadm policy add-scc-to-user hostmount-anyuid \
          system:serviceaccount:logging:aggregated-logging-elasticsearch

        # oc rollout cancel $( oc get -n logging dc -l component=es -o name )
        # oc rollout latest $( oc get -n logging dc -l component=es -o name )
        # oc rollout status -w $( oc get -n logging dc -l component=es -o name )

Installing ViaQ
---------------

These instructions and config files are for an all-in-one, single machine, run
ansible on the same machine you are installing ViaQ on.

The setup below is for a an all-in-one machine, running
Ansible in *local* mode to install ViaQ on the same machine as Ansible is
running on.  It also configures the `AllowAllPasswordIdentityProvider` with
`mappingMethod: lookup`, which means the administrator will need to manually
create users.  See below for more information about users.

Ansible is used to install ViaQ and OCP or Origin using OpenShift Ansible.
The following packages are required: openshift-ansible
openshift-ansible-callback-plugins openshift-ansible-filter-plugins
openshift-ansible-lookup-plugins openshift-ansible-playbooks
openshift-ansible-roles

    # yum install openshift-ansible \
      openshift-ansible-callback-plugins openshift-ansible-filter-plugins \
      openshift-ansible-lookup-plugins openshift-ansible-playbooks \
      openshift-ansible-roles

If the 3.6 version of these packages are not available, you can use the
git repo `https://github.com/openshift/openshift-ansible.git` and the
`release-3.6` branch:

    # git clone https://github.com/openshift/openshift-ansible.git -b release-3.6

You will need to use the `ansible-playbook` command with an Ansible inventory
file and a `vars.yaml` file.  You should not have to edit the inventory file.
All customization can be done via the `vars.yaml` file.

Download the files [vars.yaml.template](vars.yaml.template) and
[ansible-inventory-origin-36-aio](ansible-inventory-origin-36-aio)

    # curl https://raw.githubusercontent.com/ViaQ/Main/master/vars.yaml.template > vars.yaml.template
    # curl https://raw.githubusercontent.com/ViaQ/Main/master/ansible-inventory-origin-36-aio > ansible-inventory

To use ViaQ on Red Hat OCP, use the
[ansible-inventory-ocp-36-aio](ansible-inventory-ocp-36-aio) file instead
of the origin-36-aio file (you still need vars.yaml.template):

    # curl https://raw.githubusercontent.com/ViaQ/Main/master/ansible-inventory-ocp-36-aio > ansible-inventory
    
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
* `openshift_logging_mux_namespaces` - **REQUIRED** Represents the environment
  name that you are sending logs from.  It is a list (ansible/yaml list format)
  namespaces, to create in mux for your logs. Only users who are members of
  those namespaces can view those logs.  **NOTE POSSIBLE LOSS OF DATA**  Data
  tagged with `project.namespace.*` WILL BE LOST if `namespace` does not exist,
  so make sure any such namespaces are specified in
  `openshift_logging_mux_namespaces`
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
* `openshift_logging_mux_hostname` - this is the public hostname for mux
  secure_forward access - you can usually use the default value
* `openshift_logging_es_hostname` - this is the public hostname for
  Elasticsearch direct API access - you can usually use the default value

You can also override variables in the inventory by setting them in
`vars.yaml`.

**NOTE:** Log records sent to mux, which are not tagged in the form
`project.namespace`, will go into the `mux-undefined` namespace, and will be
available via Elasticsearch/Kibana using an index pattern of
`project.mux-undefined.*`.

See
[mux-logging-service.md](https://github.com/openshift/origin-aggregated-logging/blob/master/docs/mux-logging-service.md)
for a description about how mux detects and separates logs into namespaces.

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

### Post-Install Checking ###

To confirm that OpenShift and logging are working:

    # oc project logging
    # oc get pods

You should see the Elasticsearch, Curator, Kibana, Fluentd, and mux pods
running.

    # oc project logging
    # oc get svc

You should see services for Elasticsearch, Kibana, and mux.

    # oc project logging
    # oc get routes

You should see routes for Elasticsearch and Kibana.

You should have a `logging-mux` configmap, secrets, dc, pod, and service.

    # oc get pods -l component=mux
    NAME                  READY     STATUS    RESTARTS   AGE
    logging-mux-1-yxx1o   1/1       Running   0          1h
    # oc get svc logging-mux
    NAME          CLUSTER-IP      EXTERNAL-IP   PORT(S)     AGE
    logging-mux   172.30.215.88   10.0.0.3      24284/TCP   1h

The externalIP value should be the IP address of your `eth0` interface, or
whichever interface on the machine is used for external egress, that you
configured with the `openshift_ip` in Ansible.  You can test with `openssl
s_client` like this:

    # echo hello | openssl s_client -quiet -connect localhost:24284
    depth=1 CN = openshift-signer@1480618407
    verify return:1
    depth=0 CN = mux
    verify return:1
    ��HELO��nonce�Aa���3�/��Ps��auth��keepaliveÕ�PONG´invalid ping message��

If you get something that looks like this: `Connection refused connect:errno=111`
Try this:

    # netstat -nlt | grep 24284

It should show mux listening to port 24284 on some IP address:

    tcp        0      0 10.16.19.171:24284        0.0.0.0:*               LISTEN

Try `echo hello | openssl s_client -quiet -connect 10.16.19.171:24284`, or try
`$(hostname):24284`.  If this works, this means you are able to access the
Fluentd secure_forward listener.  Don't worry about the garbage characters and
invalid message.

### Test Elasticsearch ###

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
iteration, you will just use the ones generated by the ansible install.

    # oc project logging
    # oc get secret logging-mux --template='{{index .data "ca"}}' | base64 -d > mux-ca.crt
    # openssl x509 -in mux-ca.crt -text | more
    Certificate:
    ...
        Subject: CN=openshift-signer@1480618407
    ...
    # oc get secret logging-mux --template='{{index .data "shared_key"}}' | \
      base64 -d > mux-shared-key

Use the `mux-ca.crt` and `mux-shared-key` to configure the Fluent
secure_forward clients.

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

You will first need to create an OpenShift user and assign this user
rights to view the application and operations logs.  The install above
uses the `AllowAllPasswordIdentityProvider` with `mappingMethod: lookup`.
You will need to manually create users to allow access to Kibana.
See [OpenShift Authentication Docs](https://docs.openshift.org/3.6/install_config/configuring_authentication.html#LookupMappingMethod)
for more information.
To create an admin user:

    # oc project logging
    # oc create user admin
    # oc create identity allow_all:admin
    # oc create useridentitymapping allow_all:admin admin
    # oadm policy add-cluster-role-to-user cluster-admin admin

This will create the user account.  The password is set when at the
first login.  To set the password now:

    # oc login --username=admin --password=admin
    # oc login --username=system:admin

Now you can use the `admin` username and password to access Kibana.  Just
point your web browser at `https://kibana.logging.test` where the
`logging.test` part is whatever you specified in the 
`openshift_master_default_subdomain` parameter in the `vars.yaml` file.

To create an "normal" user that can only view logs in a particular set of
projects, follow the steps above, except do not assign the `cluster-admin`
role, use the following instead:

    # oc project $namespace
    # oadm policy add-role-to-user view $username

Where `$username` is the name of the user you created instead of `admin`,
and `$namespace` is the name of the project or namespace you wish to allow
the user to have access to the logs of.  For example, to create a user
named `loguser` that can view logs in `ovirt-metrics-engine`:

    # oc create user loguser
    # oc create identity allow_all:loguser
    # oc create useridentitymapping allow_all:loguser loguser
    # oc project ovirt-metrics-engine
    # oadm policy add-role-to-user view loguser

and to assign the password immediately instead of waiting for the user
to login:

    # oc login --username=loguser --password=loguser
    # oc login --username=system:admin


## Appendix 1 CentOS7 ViaQ yum repos

[CentOS 7 ViaQ](centos7-viaq.repo)
