# Demo script

0. preparation 

```sh
oc login -u raffa -p raffa https://api.etl6.ocp.rht-labs.com:6443
oc login -u raffa -p raffa https://api.etl7.ocp.rht-labs.com:6443
oc login -u raffa -p raffa https://api.hub2.ocp.rht-labs.com:6443
oc config rename-context openshift-gitops/api-etl6-ocp-rht-labs-com:6443/raffa etl6
oc config rename-context openshift-gitops/api-etl7-ocp-rht-labs-com:6443/raffa etl7
oc config rename-context openshift-gitops/api-hub2-ocp-rht-labs-com:6443/raffa hub2
```

1. describe the steady state situation
2. prepare pgbench

```sh
export PGPASSWORD=$(oc --context etl6 get secret demo-pguser-demo -n percona-operator -o jsonpath='{.data.password}' | base64 -d)
pgbench --initialize -h  percona-demo.glb.ocp.rht-labs.com  -U demo dbbench --scale=50
```

3. run pgbench

```sh
pgbench -h percona-demo.glb.ocp.rht-labs.com  -U postgres  postgres -T 10  -R 2 -v
```

4. navigate the pet clinic

```sh
http://petclinic.glb.ocp.rht-labs.com
```

and book an appointment

5. isolate primary

change kustomize in etl6

6. failover

change records in dns and shange acrive in etl7

7. verify failover

flush the dns caches

```sh
sudo resolvectl flush-caches
```

reload borwser