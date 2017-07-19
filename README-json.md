TCP JSON listener
-----------------

**NOTE** This is currently not supported by the Ansible based installer.  You
could use the old setup-mux.sh script to hack something together.

Rsyslog Client side setup
-------------------------

Assuming you have a template `viaq-json-format` that will format your records
using a ViaQ JSON format, and `mux` is configured to use the `TCP JSON`
listener, you can output your records using something like the
following:

    module(load="builtin:omfwd")
    action(type="omfwd"
           target="mux.logging.test"
           port="23456"
           protocol="tcp"
           template="viaq-json-format")
