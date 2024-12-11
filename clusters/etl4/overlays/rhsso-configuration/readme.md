## RH-SSO - LDAP Integration

```shell
export admin_password=$(oc get secret credential-rhsso -n sso -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
oc exec -n sso keycloak-0 -- /opt/jboss/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user admin --password ${admin_password} --config /tmp/kcadm.config
export ldap_integration_id=$(cat ./keycloak/ldap-federation.json | envsubst | oc exec -i -n keycloak-operator keycloak-0 -- /opt/jboss/keycloak/bin/kcadm.sh create components --config /tmp/kcadm.config -r ocp -f - -i)
echo created ldap integration $ldap_integration_id
cat ./keycloak/role-mapper.json | envsubst | oc exec -i -n keycloak-operator keycloak-0 -- /opt/jboss/keycloak/bin/kcadm.sh create components --config /tmp/kcadm.config -r ocp -f -
```