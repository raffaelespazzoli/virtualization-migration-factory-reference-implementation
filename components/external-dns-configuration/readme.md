# external-dns configuration

This component installs external dns in such a way that it can update DNS using the rfc2136 protocol.
This is the option we had in this environment.
Red Hat does not support that, hence we had to do a non-operator-driven installation.

```sh
oc apply -f components/external-dns-configuration/rfc2136-tsig-secret.yaml
```

```sh
for cluster in hub2 etl4 etl6 etl7; do
  oc --context $cluster apply -f components/external-dns-configuration/rfc2136-tsig-secret.yaml;
done
```  