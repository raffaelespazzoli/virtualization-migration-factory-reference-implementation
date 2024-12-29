# OVA-Server
upload OVAs files like this:

```sh
oc exec -i -n ova-server nfs-server-<xxx> -- mkdir -p /exports/ovas
tar cf - <ova-file>.ova | oc exec -i -n ova-server nfs-server-<xxx> -- tar xf - -C /exports/ovas
```