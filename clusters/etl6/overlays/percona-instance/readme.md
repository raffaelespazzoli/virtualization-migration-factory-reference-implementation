# Demo script

0. preparation 

```sh
oc login -u raffa -p raffa https://api.etl4.ocp.rht-labs.com:6443
oc login -u raffa -p raffa https://api.etl6.ocp.rht-labs.com:6443
oc login -u raffa -p raffa https://api.etl7.ocp.rht-labs.com:6443
oc login -u raffa -p raffa https://api.hub2.ocp.rht-labs.com:6443
oc config rename-context openshift-gitops/api-etl4-ocp-rht-labs-com:6443/raffa etl4
oc config rename-context openshift-gitops/api-etl6-ocp-rht-labs-com:6443/raffa etl6
oc config rename-context openshift-gitops/api-etl7-ocp-rht-labs-com:6443/raffa etl7
oc config rename-context openshift-gitops/api-hub2-ocp-rht-labs-com:6443/raffa hub2
```

create pbench database

```sh
export DATABASE_URL='percona-demo.glb.ocp.rht-labs.com'
export PGPASSWORD=$(oc --context etl6 get secret demo-pguser-demo -n percona-operator -o jsonpath='{.data.password}' | base64 -d)
export USERNAME=$(oc --context etl6 get secret demo-pguser-demo -n percona-operator -o jsonpath='{.data.user}' | base64 -d)
psql -h $DATABASE_URL -U $USERNAME
```

1. describe the steady state situation
2. prepare pgbench

```sh
pgbench --initialize -h  $DATABASE_URL  -U $USERNAME demo
```

3. run pgbench

```sh
pgbench -T 3600  -R 2 -v -P 2 -h $DATABASE_URL -U $USERNAME demo 
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

clear cache in chrome:

```
chrome://net-internals/#dns
```

scale pet clinic to 1

reload browser




troubleshooting:

```
psql
\l

\c <database>
\dt