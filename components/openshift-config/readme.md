# OpenShift-config


We do a few things here.

1. disable the csv propagation for olm, this makes installing several operator more bearable for the master API
2. setup the authentication for the cluster. In this case it a very simple oauth. If you keep this approach, you will have to create the httpwd secret manually.
3. we assign the admin role
4. we create a certificate to be used for ingress.


create the secret as follows:

```sh
oc create secret generic htpass-secret --from-file htpasswd -n openshift-config
```