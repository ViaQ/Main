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
INVENTORY_SOURCE=${INVENTORY_SOURCE:-$1}
INVENTORY=${INVENTORY:-ansible.inventory}
VARS=${VARS:-vars.yaml}

ANSIBLE_LOCAL="-c local"

if [ -n "${OPENSHIFT_ANSIBLE_REPO:-}" ] ; then
    cd /root
    git clone https://github.com/$OPENSHIFT_ANSIBLE_REPO/openshift-ansible ${OPENSHIFT_ANSIBLE_BRANCH:+-b $OPENSHIFT_ANSIBLE_BRANCH} $HOME/openshift-ansible
    OPENSHIFT_ANSIBLE_DIR=$HOME/openshift-ansible
else
    OPENSHIFT_ANSIBLE_DIR=${OPENSHIFT_ANSIBLE_DIR:-/usr/share/ansible/openshift-ansible}
fi

# add ip to known_hosts to avoid
# Are you sure you want to continue connecting (yes/no)?
# prompt
ssh-keyscan -H $hostname >> /root/.ssh/known_hosts
ssh-keyscan -H localhost >> /root/.ssh/known_hosts

cp $HOME/ViaQ/vars.yaml.template $HOME/ViaQ/vars.yaml
cp $HOME/ViaQ/$INVENTORY_SOURCE $HOME/ViaQ/$INVENTORY
# run ansible
cd $OPENSHIFT_ANSIBLE_DIR

for file in $HOME/ViaQ/*.patch ; do
    if [ -f "$file" ] ; then
        patch -p1 -b < $file
    fi
done

needpath=
if grep -q -i \^openshift_logging_elasticsearch_storage_type=hostmount $HOME/ViaQ/$INVENTORY ; then
    path=$( awk -F'[ =]+' '/^openshift_logging_elasticsearch_hostmount_path/ {print $2}' $HOME/ViaQ/$INVENTORY )
    needpath=1
elif grep -q -i "^openshift_logging_elasticsearch_storage_type: hostmount" $HOME/ViaQ/$VARS ; then
    path=$( awk -F'[ :]+' '/^openshift_logging_elasticsearch_hostmount_path/ {print $2}' $HOME/ViaQ/$VARS )
    needpath=1
fi

if [ -n "$needpath" -a -z "${path:-}" ] ; then
    echo Error: storage type is hostmount but no openshift_logging_elasticsearch_hostmount_path was specified
    exit 1
elif [ -n "$needpath" ] ; then
    if [ ! -d $path ] ; then
        mkdir -p $path
    fi
    chown 0:65534 $path
    chmod g+w $path
    semanage fcontext -a -t svirt_sandbox_file_t "$path(/.*)?"
    restorecon -R -v $path
fi

ANSIBLE_LOG_PATH=/var/log/ansible.log ansible-playbook ${ANSIBLE_LOCAL:-} -vvv -e @$HOME/ViaQ/$VARS -i $HOME/ViaQ/$INVENTORY playbooks/byo/config.yml

oc project logging
oc login --username=admin --password=admin
oc login --username=system:admin
oc project logging
oadm policy add-cluster-role-to-user cluster-admin admin
oc get pods

if [ -x $HOME/ViaQ/setup-mux.sh ] ; then
    MUX_HOST=mux.$hostname $HOME/ViaQ/setup-mux.sh
fi
