# OVA-Server
upload OVAs files like this:

```sh
oc exec -i -n ova-server nfs-server-<xxx> -- mkdir -p /exports/ovas
tar cf - <ova-file>.ova | oc exec -i -n ova-server nfs-server-<xxx> -- tar xf - -C /exports/ovas
```oc 

```sh 
virtctl image-upload dv infinibox-demo-7.3.11.0 --size 200Gi --uploadproxy-url https://cdi-uploadproxy-openshift-cnv.apps.etl4.ocp.rht-labs.com --image-path ./infinibox-demo-7.3.11.0-cbdev-7.3.11-RHOSV-20250114-1.qcow2 -n openshift-virtualization-os-images
```