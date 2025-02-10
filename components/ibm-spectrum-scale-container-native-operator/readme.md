create the pull secret like this

https://gist.github.com/mvazquezc/ca0243452a058b730fa94e13116b4419

```sh
oc apply -f pull-secret.yaml -n ibm-spectrum-scale  
oc apply -f pull-secret.yaml -n ibm-spectrum-scale-dns
oc apply -f pull-secret.yaml -n ibm-spectrum-scale-csi
```