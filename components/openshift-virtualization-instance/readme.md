create the pull secret for the vddk image

```sh
oc create secret docker-registry quay-pull-secret --docker-server quay.io --docker-username raffaelespazzoli --docker-password xxxx -n openshift-mtv
```