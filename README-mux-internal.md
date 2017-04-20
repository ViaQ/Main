# Setting Up ViaQ Logging using internal Red Hat repos/registries

You can mostly follow the directions in [README-mux.md](README-mux.md) except
for a few directions and files below.

## Provisioning a machine to run ViaQ

Use these [Yum Repos](rhel7-viaq.repo) direct [link](http://git.app.eng.bos.redhat.com/git/ViaQ.git/plain/rhel7-viaq.repo?h=3.5)

## Installing ViaQ

To use ViaQ on Red Hat OCP using the internal repos/registries, use the
[ansible-inventory-ocp-35-aio-internal](ansible-inventory-ocp-35-aio-internal) file:

    # curl http://git.app.eng.bos.redhat.com/git/ViaQ.git/plain/ansible-inventory-ocp-35-aio-internal?h=3.5 > ansible-inventory
