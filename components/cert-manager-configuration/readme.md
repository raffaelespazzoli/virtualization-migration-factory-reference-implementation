# cert-manager-configuration

We use cert manager to mint certificates on demand.
In this particular instance we connect it to let's encrypt and we respond to the DNS challenge using AWS DNS. 
Hence we need to create credentials to the appropriate zone.

for now manually create the secret

```sh
oc apply -f ./aws-secret.yaml -n cert-manager
```