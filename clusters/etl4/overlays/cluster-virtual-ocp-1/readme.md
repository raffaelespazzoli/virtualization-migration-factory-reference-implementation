# Create cluster etl7

for now we create the needed secret manually (they will not be present in the git repository), use the following templates:

and the pull secret:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: pullsecret-etl7
stringData:
  '.dockerconfigjson': '<pull-secret>'
type: 'kubernetes.io/dockerconfigjson'
```

notice of you want to reuse the pull secret of the acm cluster, you can find it here `openshift-config/pull-secret`

create the secret

```sh
oc new-project virtual-ocp-1
oc apply -f ./pull-secret.yaml -n virtual-ocp-1
```
