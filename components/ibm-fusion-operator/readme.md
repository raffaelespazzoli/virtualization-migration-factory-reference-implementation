create the pull secret like this

```sh
oc apply -f pull-secret.yaml -n ibm-spectrum-fusion-ns
oc apply -f pull-secret.yaml -n openshift-storage
```