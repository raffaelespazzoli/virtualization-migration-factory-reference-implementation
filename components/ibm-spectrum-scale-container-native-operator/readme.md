create the pull secret like this

https://gist.github.com/mvazquezc/ca0243452a058b730fa94e13116b4419

```sh
oc apply -f pull-secret.yaml -n ibm-spectrum-scale  
oc apply -f pull-secret.yaml -n ibm-spectrum-scale-dns
oc apply -f pull-secret.yaml -n ibm-spectrum-scale-csi
```

```sh
for master_node in $(oc get nodes -l node-role.kubernetes.io/master -o name)
do
  oc label ${master_node} scale.spectrum.ibm.com/role=storage
  oc label ${master_node} scale.spectrum.ibm.com/daemon-selector=""
done
```

# discover volumes in each node

```sh
iscsiadm --mode discovery -t sendtargets --portal 192.168.51.228
iscsiadm -m node -l
iscsiadm -m node -T iqn.1992-08.com.netapp:sn.23ef8da95f5611efa2c200a09884167a:vs.40 -p 192.168.51.228:3260 -l
```