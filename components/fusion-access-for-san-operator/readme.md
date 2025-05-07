create the pull secret

```sh
oc create secret -n openshift-fusion-access generic fusion-pullsecret  \
 --from-file=.dockerconfigjson=./pull-secret.json \
 --type=kubernetes.io/dockerconfigjson
```