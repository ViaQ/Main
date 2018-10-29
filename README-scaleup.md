Scaling Up ViaQ Logging - Multiple Nodes
========================================

Provisioning additional nodes
-----------------------------

You must first provision the nodes and configure them as described at [Node Pre-requisites](https://docs.okd.io/3.11/install/prerequisites.html)

**Steps:**

- Add the openshift repo to the node
- Add the nodes to the ansible-inventory under the [nodes] section and add the openshift_hostname and openshift_public_hostname to each node
- Update the master node's address in the ansible-inventory from localhost to the FQDN
- Update the ansible_connection to ssh
- Copy the ssh key to the node so it will not require a password
- Configure persistent storage on the node
- Update ansible-inventory - add openshift_logging_es_cluster_size=N where N is the total number of nodes on which you want to run Elasticsearch
- Rerun all 3 playbooks again and last playbook failed
- Rolled out latest es pods and it worked

Relevant docs:
https://docs.okd.io/3.11/install_config/aggregate_logging_sizing.html#install-config-aggregate-logging-sizing-guidelines-scaling-up
https://docs.okd.io/3.11/install_config/aggregate_logging_sizing.html#install-config-aggregate-logging-sizing-guidelines-storage

Documentation will also need to include nodes prerequisites
https://docs.okd.io/3.11/install/prerequisites.html
