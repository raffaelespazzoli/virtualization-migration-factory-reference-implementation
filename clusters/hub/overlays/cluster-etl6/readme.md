# Create cluster etl6

for now we create the needed secret manually (they will not be present in the git repository), use the following templates:

bmc credentials:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: bmc-credentials
stringData: 
  username: <username>
  password: <password>
```

and the pull secret:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: pullsecret-etl6
stringData:
  '.dockerconfigjson': '<pull-secret>'
type: 'kubernetes.io/dockerconfigjson'
```

notice of you want to reuse the pull secret of the acm cluster, you can find it here `openshift-config/pull-secret`

create the secret

```sh
oc new-project etl6
oc apply -f ./bmc-credentials-secret.yaml -n etl6
oc apply -f ./pull-secret.yaml -n etl6
```
