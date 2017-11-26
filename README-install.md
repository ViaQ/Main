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

To verify that passwordless ssh works, and that you do not get prompted to
accept host verification, try this:

    # ssh localhost 'ls -al'
    # ssh **public_hostname** 'ls -al'

Allow connections on the following ports/protocols:
  * icmp (for ping)
  * tcp ports 22, 80, 443, 8443 (openshift console), 9200 (Elasticsearch)

You should not be prompted for a password nor to accept the host verification.

This will allow you to access the machine via ssh (in order to run Ansible -
see below), to access the external services such as Kibana and to
access the OpenShift UI console. openshift-ansible in some cases will
attempt to ssh to localhost.

ViaQ on OCP requires a RHEL and OCP subscription.  For more information about
RHEL configuration, see
[Host Registration](https://access.redhat.com/documentation/en-us/openshift_container_platform/3.5/html/installation_and_configuration/installing-a-cluster#host-registration)
For RHEL, you must enable the Extras and the rhel-7-fast-datapath-rpms channels
(for docker and ovs, among others).

ViaQ on Origin requires these [Yum Repos](centos7-viaq.repo).
You will need to install the following packages: docker, iptables-services.

    # yum install docker iptables-services

You will need to configure sudo to not require a tty.  For example, create a
file like `/etc/sudoers.d/999-cloud-init-requiretty` with the following contents:

    # cat /etc/sudoers.d/999-cloud-init-requiretty
    Defaults !requiretty

Persistent Storage
------------------

Elasticsearch and Fluentd require persistent storage for the database.
Inside the pods, these are mounted at
`/var/lib/fluentd`.
Do not run this with reduced disk space, pre-allocated the required disk space to the partition
that you plan to use for the persistent storage.
We recommand 500GB ssd disk, for 50 about hosts.

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
- make this directory writable by the group `chmod -R g+w /var/lib/elasticsearch`
- add the following selinux policy:

        # semanage fcontext -a -t svirt_sandbox_file_t "/var/lib/elasticsearch(/.*)?"
        
        # restorecon -R -v /var/lib/elasticsearch


Installing ViaQ Packages
------------------------

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

### Customizing vars.yaml

During the installation, the ansible-playbook command is used together with an Ansible inventory file and a vars.yaml file.
All customization can be done via the vars.yaml file.
The following procedures explain which parameters must be customized,
which parameters may need to be customized, after running tests
and which parameters you may want to customize, depending on your environment.

1. Download the files [vars.yaml.template](vars.yaml.template) and
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

2. Copy `vars.yaml.template` to `vars.yaml`.

3. Update openshift_logging_mux_namespaces.

It represents the environment name that you are sending logs from.
It is a list (ansible/yaml list format) of OpenShift namespaces, to create in OpenShift for your logs.
Only users who are members of those namespaces can view those logs.

**NOTE POSSIBLE LOSS OF DATA** Data tagged with project.namespace.* WILL BE LOST if namespace does not exist,
so make sure any such namespaces are specified in openshift_logging_mux_namespaces

4. Run Ansible to verify whether the default value for  public_hostname is correct, and if not update it.  

        # ansible -m setup localhost -a 'filter=ansible_fqdn'

to see if ansible correctly reports your host's FQDN, as defined in Configuring Ansible Prerequisites.
If it is different, edit the value of openshift_public_hostname to match the public_hostname.

5. Run Ansible to verify whether the default value for and public_ip matches
the value you defined in Configuring Ansible Prerequisites.

        # ansible -m setup localhost -a 'filter=ansible_default_ipv4'

Check that the address field, matches public_ip.
Now ensure that you receive the same IP address that is used for external use by running:

        # ip -4 route get 8.8.8.8


You will receive an output similar to the following, where 10.10.10.10 is the IP address.
8.8.8.8 via 10.0.0.1 dev enp0s25 src 10.10.10.10 uid 1000


If the result of these two tests match, but the IP is different from the value defined in public_ip,
edit the value of openshift_public_ip to match the public_ip. 
This is the IP address that will be used from other machines to connect to this machine.
It will typically be used in your DNS, /etc/hosts.
This may be the same as the eth0 IP address of the machine,
in which case, just use "{{ ansible_default_ipv4.address }}" as the value.

6. The following parameters are optional and may be changed as required.

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
  Kibana, and Elasticsearch.  By default, the
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
* `openshift_logging_es_hostname` - this is the public hostname for
  Elasticsearch direct API access - you can usually use the default value

You can also override variables in the inventory by setting them in
`vars.yaml`.


Running Ansible
---------------

**NOTE**: In the sections that follow, the text that refers to specifc
  hostnames and IP addresses should be changed to the values you set in your
  `vars.yaml` file.
* `10.16.19.171` - replace this with your `openshift_public_ip`
* `192.168.122.4` - replace this with your `openshift_ip`
* `openshift.logging.test` - replace this with your `openshift_public_hostname`
* `kibana.logging.test` - replace this with `openshift_logging_kibana_hostname`

The public hostname should typically be a DNS entry for the
public IP address.

1. Run ansible:

    # cd /usr/share/ansible/openshift-ansible
    # (or wherever you cloned the git repo if using git)
    # ANSIBLE_LOG_PATH=/tmp/ansible.log ansible-playbook -vvv \
      -e @/path/to/vars.yaml \
      -i /path/to/ansible-inventory playbooks/byo/config.yml

where `/path/to/vars.yaml` is the full path and file name where you saved your
`vars.yaml` file, and `/path/to/ansible-inventory` is the full path and file
name where you saved your `ansible-inventory` file.

2. Check `/tmp/ansible.log` if there are any errors during the run.  If this
hangs, just kill it and run it again - Ansible is (mostly) idempotent.  Same
applies if there are any errors during the run - fix the machine and/or the
`vars.yaml` and run it again.

Note : If the installation hangs, kill it and run it again.

Enabling Elasticsearch to Mount the Directory
---------------------------------------------
The installation of Elasticsearch will fail because there is currently no way to grant
the Elasticsearch service account permission to mount that directory.
After installation is complete, do the following steps to enable Elasticsearch to mount the directory:
        # oc project logging
        # oadm policy add-scc-to-user hostmount-anyuid \
          system:serviceaccount:logging:aggregated-logging-elasticsearch

        # oc rollout cancel $( oc get -n logging dc -l component=es -o name )
        # oc rollout latest $( oc get -n logging dc -l component=es -o name )
        # oc rollout status -w $( oc get -n logging dc -l component=es -o name )

Enabling External Fluentd Access
--------------------------------

Edit the Elasticsearch service definition to add an external IP using the openshift_public_ip from above.

1. Run the following command from OpenShift Aggregated Logging machine:

        # oc edit svc logging-es

2. Look for the line with clusterIP and add two line beneath it so that the result looks like this:

spec:
  clusterIP: 172.xx.yy.zz
  externalIP:
  -  <openshift_public_ip>

3. Save the file and exit.  The changes will take effect immediately.

Enabling Kopf
-------------
kopf is a simple web administration tool for elasticsearch.

It offers an easy way of performing common tasks on an elasticsearch cluster.
Not every single API is covered by this plugin, but it does offer a REST client
which allows you to explore the full potential of the ElasticSearch API.

See:

https://github.com/openshift/origin-aggregated-logging/tree/master/hack/kopf



### Post-Install Checking ###

1. To confirm that Elasticsearch, Curator, Kibana, and Fluentd pods are running, run:

    # oc project logging
    # oc get pods

2. To confirm that the Elasticsearch and Kibana services are running, run:

    # oc project logging
    # oc get svc

3. To confirm that there are routes for Elasticsearch and Kibana, run:


    # oc project logging
    # oc get routes


### Test Elasticsearch ###

To search Elasticsearch, first get the name of the Elasticsearch pod, then use oc exec to query Elasticsearch.
The example search below will look for all log records in project.logging and will sort them by @timestamp
(which is the timestamp when the record was created at the source) in descending order (that is, latest first):

        # oc project logging
        # espod=`oc get pods -l component=es -o jsonpath='{.items[0].metadata.name}'`
        # oc exec -c elasticsearch $espod -- curl --connect-timeout 1 -s -k \
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

Creating the Admin User
-----------------------

Manually create an admin OpenShift user to allow access to Kibana to view the RHV metrics and log data. 

To create an admin user:

        # oc project logging
        # oc create user admin
        # oc create identity allow_all:admin
        # oc create useridentitymapping allow_all:admin admin
        # oadm policy add-cluster-role-to-user cluster-admin admin

This will create the user account.  The password is set at the
first login.  To set the password now:

        # oc login --username=admin --password=admin
        # oc login --username=system:admin


Running Kibana
--------------


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
