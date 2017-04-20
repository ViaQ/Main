#!/bin/sh

set -euxo pipefail

if [ -z "${HOME:-}" ] ; then
    export HOME=/root
fi

if [ ! -d /root/.ssh ] ; then
    mkdir -p /root/.ssh
fi
pushd /root/.ssh
if [ -f id_rsa ] ; then
    mv id_rsa save.id_rsa
fi
if [ -f id_rsa.pub ] ; then
    mv id_rsa.pub save.id_rsa.pub
fi
ssh-keygen -q -N "" -f /root/.ssh/id_rsa
popd

hostname=`hostname`
OPENSHIFT_PRIVATE_IP=${OPENSHIFT_PRIVATE_IP:-`getent ahostsv4 $hostname|awk "/$hostname/ "'{print $1}'`}
INVENTORY_SOURCE=${INVENTORY_SOURCE:-$1}
INVENTORY=${INVENTORY:-ansible.inventory}
VARS=${VARS:-vars.yaml}

ANSIBLE_LOCAL="-c local"

if [ -n "${OPENSHIFT_ANSIBLE_REPO:-}" ] ; then
    cd /root
    git clone https://github.com/$OPENSHIFT_ANSIBLE_REPO/openshift-ansible ${OPENSHIFT_ANSIBLE_BRANCH:+-b $OPENSHIFT_ANSIBLE_BRANCH} $HOME
    OPENSHIFT_ANSIBLE_DIR=$HOME/openshift-ansible
else
    OPENSHIFT_ANSIBLE_DIR=${OPENSHIFT_ANSIBLE_DIR:-/usr/share/ansible/openshift-ansible}
fi

# add ip to known_hosts to avoid
# Are you sure you want to continue connecting (yes/no)?
# prompt
ssh-keyscan -H $hostname >> /root/.ssh/known_hosts

# create vars.yaml file
cat > $HOME/ViaQ/vars.yaml <<EOF
ansible_ssh_user: root
ansible_become: false
openshift_master_default_subdomain: $hostname
openshift_public_ip: $OPENSHIFT_PRIVATE_IP
openshift_ip: $OPENSHIFT_PRIVATE_IP
openshift_public_hostname: $hostname
openshift_hostname: $hostname
openshift_hosted_logging_master_public_url: https://${hostname}:8443
openshift_hosted_logging_hostname: kibana.{{ openshift_public_hostname }}
EOF
cp $HOME/ViaQ/$INVENTORY_SOURCE $HOME/ViaQ/$INVENTORY
# run ansible
cd $OPENSHIFT_ANSIBLE_DIR

# vvv HACK HACK HACK
setenforce Permissive
# ^^^ HACK HACK HACK

ANSIBLE_LOG_PATH=/var/log/ansible.log ansible-playbook ${ANSIBLE_LOCAL:-} -vvv -e @$HOME/ViaQ/$VARS -i $HOME/ViaQ/$INVENTORY playbooks/byo/config.yml

oc project logging
oc login --username=admin --password=admin
oc login --username=system:admin
oc project logging
oadm policy add-cluster-role-to-user cluster-admin admin
oc get pods

MUX_HOST=mux.$hostname $HOME/ViaQ/setup-mux.sh
