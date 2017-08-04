###  Updating Fluentd Pod Config in ViaQ  ###

This information is based on having a VM with [OpenShift Logging](https://github.com/openshift/origin-aggregated-logging) stack ViaQ (EFK) as described in:
https://github.com/ViaQ/Main/blob/master/README-mux.md

All the logs from journald get sent to fluentd.
Fluentd is throttled and may lose logs if in a storm, but all the logs shall get processed under normal circumstances.

The logs can be seen, in a root shell of the VM, with 

    # journalctl -u origin-master
    # journalctl -u origin-node

To modify configuration of the fluentd pod it can be done via configmap

    # oc edit configmap logging-fluentd

To add new filters we need to go to the “fluent.conf” section and in “<label @INGRESS>” add a new include file

    @include configs.d/user/filter-my-filter.conf

Note: it has to be in ```“configs.d/user/”``` which is where ConfigMap drops the files.

Then we can add a new section for the new file

    filter-my-filter.conf: |
    <filter systemd.origin>
      @type rewrite_tag_filter
      rewriterule1 _SYSTEMD_UNIT ^origin-master.service kubernetes.master
      rewriterule2 _SYSTEMD_UNIT ^origin-node.service kubernetes.node
    </filter>

We need to delete the fluentd pods after each changes/updates to refresh the configuration

    # oc delete pods $FLUENTD_POD_NAME

To check if fluentd running well …

    # oc logs $FLUENTD_POD_NAME
