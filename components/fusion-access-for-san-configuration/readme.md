docs can be found here:
https://www.ibm.com/docs/en/scalecontainernative/5.2.3?topic=installing-storage-scale-container-native-operator-cluster


useful troubleshooting commands

oc exec $(oc get pods -lapp.kubernetes.io/name=core -ojsonpath="{.items[0].metadata.name}" -n ibm-spectrum-scale) -c gpfs -n ibm-spectrum-scale -- mmlsnsd -L
oc exec $(oc get pods -lapp.kubernetes.io/name=core -ojsonpath="{.items[0].metadata.name}" -n ibm-spectrum-scale) -c gpfs -n ibm-spectrum-scale -- mmlscluster


iscsiadm -m session --rescan


oc exec $(oc get pods -lapp.kubernetes.io/name=core -ojsonpath="{.items[0].metadata.name}" -n ibm-spectrum-scale) -it -c gpfs -n ibm-spectrum-scale -- bash

/usr/lpp/mmfs/bin/mmchconfig maxblocksize=DELETE,prefetchPct=DELETE,enforceFilesetQuotaOnRoot=DELETE --force-rg-server --class-mode=vdisk

to delete a partition:
```
fidsk delete partition
multipath -f /dev
multipath -r 
```
