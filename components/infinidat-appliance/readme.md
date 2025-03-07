```sh
podman build . -t quay.io/raffaelespazzoli/infinibox-demo-7.3.11.0-cbdev-7.3.11:20250206-1
podman push quay.io/raffaelespazzoli/infinibox-demo-7.3.11.0-cbdev-7.3.11:20250206-1
```

```sh
oc apply -f raffa-secret.yaml -n openshift-cnv
oc apply -f raffa-secret.yaml -n infinidat-appliance
```

multicluster services will be:
`etl6.infinibox-http.infinidat-appliance.svc.clusterset.local`
`etl7.infinibox-http.infinidat-appliance.svc.clusterset.local`