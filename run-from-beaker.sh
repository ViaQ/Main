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
    # workaround until commit eddb211416770e68a5d31d926d017f64a362810f
    # Date:   Thu Feb 15 17:39:03 2018 -0600
    # Removing include_tasks calls and fixing prior cherrypicks
    # is available in openshift-ansible 3.7.x
    filtfile=$OPENSHIFT_ANSIBLE_DIR/roles/lib_utils/filter_plugins/oo_filters.py
    if grep -q "def lib_utils_oo_random_word" $filtfile ; then
        echo using fixed ansible
    else
        find $OPENSHIFT_ANSIBLE_DIR -name \*.yaml -exec sed -i -e 's/lib_utils_oo_random_word/oo_random_word/g' {} \;
    fi
fi

# add ip to known_hosts to avoid
# Are you sure you want to continue connecting (yes/no)?
# prompt
ssh-keyscan -H $hostname >> /root/.ssh/known_hosts
ssh-keyscan -H localhost >> /root/.ssh/known_hosts

cp $HOME/ViaQ/vars.yaml.template $HOME/ViaQ/vars.yaml
cp $HOME/ViaQ/$INVENTORY_SOURCE $HOME/ViaQ/$INVENTORY
cd $OPENSHIFT_ANSIBLE_DIR

for file in $HOME/ViaQ/*.patch ; do
    if [ -f "$file" ] ; then
        patch -p1 -b < $file
    fi
done

pushd $HOME/ViaQ > /dev/null 2>&1
for file in *.te ; do
    if [ -f "$file" ] ; then
        rc=0
        mod=$( echo "$file" | sed -e 's/[.]te$//' )
        checkmodule -M -m -o ${mod}.mod $file || rc=1
        semodule_package -o ${mod}.pp -m ${mod}.mod || rc=1
        semodule -i ${mod}.pp || rc=1
        if [ $rc = 1 ] ; then
            echo Error: could not apply selinux policy from $HOME/ViaQ/$file
        fi
    fi
done
popd > /dev/null 2>&1

needpath=
if grep -q -i \^openshift_logging_elasticsearch_storage_type=hostmount $HOME/ViaQ/$INVENTORY ; then
    path=$( awk -F'[ =]+' '/^openshift_logging_elasticsearch_hostmount_path/ {print $2}' $HOME/ViaQ/$INVENTORY )
    needpath=1
elif grep -q -i "^openshift_logging_elasticsearch_storage_type: hostmount" $HOME/ViaQ/$VARS ; then
    path=$( awk -F'[ :]+' '/^openshift_logging_elasticsearch_hostmount_path/ {print $2}' $HOME/ViaQ/$VARS )
    needpath=1
fi

# need a function for this!
# return true if the given selinux type exists, false otherwise
se_type_exists() {
    { semanage fcontext --list 2> /dev/null || : ; } | grep -q $1
}

if [ -n "$needpath" -a -z "${path:-}" ] ; then
    echo Error: storage type is hostmount but no openshift_logging_elasticsearch_hostmount_path was specified
    exit 1
elif [ -n "$needpath" ] ; then
    if [ ! -d $path ] ; then
        mkdir -p $path
    fi
    chown 0:65534 $path
    chmod g+w $path
    # use container_file_t if available, otherwise svirt_sandbox_file_t
    if se_type_exists container_file_t ; then
        setype=container_file_t
    elif se_type_exists svirt_sandbox_file_t ; then
        setype=svirt_sandbox_file_t
    fi
    if [ -n "${setype:-}" ] ; then
        semanage fcontext -a -t $setype "$path(/.*)?"
        restorecon -R -v $path
    else
        echo no container_file_t or svirt_sandbox_file_t yet - try again after logging install
    fi
fi

# ensure docker is enabled and running
systemctl enable docker
systemctl start docker

if [ -s "playbooks/prerequisites.yml" ] ; then
    ANSIBLE_LOG_PATH=/var/log/ansible-prereqs.log ansible-playbook ${ANSIBLE_LOCAL:-} -vvv \
        -e @$HOME/ViaQ/$VARS ${EXTRA_EVARS:-} -i $HOME/ViaQ/$INVENTORY "playbooks/prerequisites.yml"
fi

if [ -s "playbooks/openshift-node/network_manager.yml" ]; then
    playbook="playbooks/openshift-node/network_manager.yml"
else
    playbook="playbooks/byo/openshift-node/network_manager.yml"
fi
ANSIBLE_LOG_PATH=/var/log/ansible-network.log ansible-playbook ${ANSIBLE_LOCAL:-} -vvv \
    -e @$HOME/ViaQ/$VARS ${EXTRA_EVARS:-} -i $HOME/ViaQ/$INVENTORY $playbook

if [ -s "playbooks/deploy_cluster.yml" ]; then
    playbook="playbooks/deploy_cluster.yml"
else
    playbook="playbooks/byo/config.yml"
fi
ANSIBLE_LOG_PATH=/var/log/ansible.log ansible-playbook ${ANSIBLE_LOCAL:-} -vvv \
    -e @$HOME/ViaQ/$VARS ${EXTRA_EVARS:-} -i $HOME/ViaQ/$INVENTORY $playbook

if oc get project openshift-logging > /dev/null 2>&1 ; then
    LOGGING_NS=openshift-logging
else
    LOGGING_NS=logging
fi
oc project $LOGGING_NS
oc create user admin
oc create identity allow_all:admin
oc create useridentitymapping allow_all:admin admin
oc adm policy add-cluster-role-to-user cluster-admin admin
oc login --username=admin --password=admin
oc login --username=system:admin

if [ -n "$needpath" ] ; then
    if [ -z "${setype:-}" ] ; then
        if se_type_exists container_file_t ; then
            setype=container_file_t
        elif se_type_exists svirt_sandbox_file_t ; then
            setype=svirt_sandbox_file_t
        else
            echo ERROR: no container_file_t or svirt_sandbox_file_t
        fi
        if [ -n "${setype:-}" ] ; then
            semanage fcontext -a -t $setype "$path(/.*)?"
            restorecon -R -v $path
        fi
    fi
    oc adm policy add-scc-to-user hostmount-anyuid \
      system:serviceaccount:$LOGGING_NS:aggregated-logging-elasticsearch
    esdc=`oc get dc -l component=es -o name`
    oc rollout cancel $esdc
    sleep 10 # error if rollout latest while cancel not finished
    oc rollout latest $esdc
    oc rollout status -w $esdc
fi

if [ -x $HOME/ViaQ/setup-mux.sh ] ; then
    MUX_HOST=mux.$hostname $HOME/ViaQ/setup-mux.sh
fi
oc get pods
