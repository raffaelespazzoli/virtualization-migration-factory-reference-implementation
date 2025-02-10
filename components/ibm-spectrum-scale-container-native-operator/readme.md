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