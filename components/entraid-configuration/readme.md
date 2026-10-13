# Entra ID (Azure AD) OIDC Configuration

Manages an Entra ID application registration via Azure Service Operator (ASO) so that OpenShift OAuth callback URIs for every cluster in the fleet are declared in Git and reconciled automatically.

## How It Works

| Resource | Purpose |
|----------|---------|
| `aso-credential-secret.yaml` | Placeholder Secret (`aso-controller-settings`) — supplies Azure credentials to the ASO controller. **Must be replaced with real values** via SealedSecret, Vault, or manual creation before ASO can reconcile. |
| `application.yaml` | Entra `Application` resource declaring the OAuth redirect URI list. Uses `${CLUSTER_NAME}` / `${CLUSTER_BASE_DOMAIN}` envsubst variables for the hub cluster and provides commented examples for managed clusters. |

> **Note:** The CRD filter ConfigMap (`aso-crd-filter.yaml`) lives in `components/entraid-operator/` alongside the OperatorPolicy so it is applied at sync-wave 5 — before the ASO controller starts. Without the filter present at startup ASO installs hundreds of Azure CRDs.

## Azure-Side Prerequisites

### 1. Create a Service Principal

```bash
az ad sp create-for-rbac --name "aso-migration-factory" --skip-assignment
```

Record the `appId` (client ID), `password` (client secret), and `tenant` (tenant ID) from the output.

### 2. Grant Permissions

Use an **Entra custom directory role** to restrict the service principal to the narrowest available permission. Entra's RBAC for application registrations is property-group-level — `authentication/update` is the most granular action that covers redirect URIs. There is no single-field `redirectUris/update` action in Azure.

`authentication/update` covers: redirect/reply URIs, sign-out URL, implicit flow, and publisher domain. It does **not** cover credentials, API permissions, branding, ownership, or account-type changes. [Custom role permissions reference](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/custom-available-permissions)

#### Create the custom role

```bash
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions" \
  --body '{
    "displayName": "Application Authentication Updater",
    "description": "Read app registrations and update authentication settings (redirect URIs, sign-out URL, implicit flow, publisher domain).",
    "isEnabled": true,
    "rolePermissions": [{
      "allowedResourceActions": [
        "microsoft.directory/applications/standard/read",
        "microsoft.directory/applications/authentication/update"
      ]
    }]
  }'
```

Record the `id` from the response — this is `<CUSTOM_ROLE_ID>`.

#### Assign the role scoped to the target app registration

```bash
SP_OBJECT_ID=$(az ad sp show --id <CLIENT_ID> --query id -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" \
  --body "{
    \"principalId\": \"${SP_OBJECT_ID}\",
    \"roleDefinitionId\": \"<CUSTOM_ROLE_ID>\",
    \"directoryScopeId\": \"/<APP_REGISTRATION_OBJECT_ID>\"
  }"
```

This scopes the permission to **one specific app registration** — the service principal cannot read or modify any other app in the tenant. No ownership of the app registration is required. No Graph application permission or admin consent is needed.

#### ASO compatibility note

ASO sends the full Application spec in its PATCH call (including `displayName`). When a field's current value in Azure matches what ASO sends, Entra should not require write permission for it — it is a no-op. During the PoC, confirm this behavior. If Entra rejects the call because `displayName` is present in the body even though unchanged, add `microsoft.directory/applications/basic/update` to the custom role. That is still far narrower than `Application.ReadWrite.OwnedBy`, which grants full management of every property.

#### Fallback — `Application.ReadWrite.OwnedBy` (broader)

If the custom role proves insufficient with ASO, fall back to the Graph application permission `Application.ReadWrite.OwnedBy` (role ID `18a4783c-866b-4cc7-a460-3d5e5662c884`). This requires admin consent and making the service principal an **owner** of the target app registration. It grants full read/write to all properties of owned app registrations — credentials, permissions, URIs, and everything else. Use this only if the custom role path does not work.

```bash
# Grant Application.ReadWrite.OwnedBy
GRAPH_SP=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0].id' -o tsv)
ROLE_ID="18a4783c-866b-4cc7-a460-3d5e5662c884"

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GRAPH_SP}/appRoleAssignments" \
  --body "{\"principalId\":\"$(az ad sp show --id <CLIENT_ID> --query id -o tsv)\",\"resourceId\":\"${GRAPH_SP}\",\"appRoleId\":\"${ROLE_ID}\"}"

# Add ownership
az ad app owner add --id <EXISTING_APP_OBJECT_ID> \
  --owner-object-id $(az ad sp show --id <CLIENT_ID> --query id -o tsv)
```

#### Permission comparison

| | Custom role (`authentication/update`) | Graph permission (`Application.ReadWrite.OwnedBy`) |
|---|---|---|
| **Scope** | Redirect URIs + sign-out URL + implicit flow + publisher domain, on one app registration | All properties of all owned app registrations |
| **Ownership required** | No | Yes |
| **Admin consent** | No | Yes |
| **Risk surface** | Small — authentication settings only | Full application management |
| **Entra license** | Requires Entra ID P1 (for custom roles) | None beyond base |

### 3. Supply the Credential Secret

Populate the `aso-controller-settings` Secret in the `azureserviceoperator-system` namespace with the real values. Choose one approach:

| Method | Notes |
|--------|-------|
| **SealedSecret** | Encrypt the Secret with `kubeseal` and commit the SealedSecret to the cluster overlay. |
| **External Secrets Operator** | Create an `ExternalSecret` referencing a Vault/AWS Secrets Manager entry. |
| **Manual** | `oc create secret generic aso-controller-settings -n azureserviceoperator-system --from-literal=AZURE_SUBSCRIPTION_ID=... --from-literal=AZURE_TENANT_ID=... --from-literal=AZURE_CLIENT_ID=... --from-literal=AZURE_CLIENT_SECRET=...` ⚠️ **ArgoCD will overwrite manually created values on next sync** with the empty placeholders from Git. Use this method only for initial testing. For production, prefer SealedSecret or External Secrets Operator. |

> **Warning:** The placeholder Secret in this component contains empty values and exists only so that Kustomize builds succeed. Never commit real credentials to Git.

## Adding a New Cluster

When a new ACM-managed cluster is provisioned, add its OAuth callback URI to `application.yaml`:

```yaml
- "https://oauth-openshift.apps.<cluster-name>.<base-domain>/oauth2callback/EntraID"
```

Commit and push — ArgoCD syncs the change, ASO patches the Entra app registration, and the new cluster's OAuth flow works immediately.

## Detach-on-Delete Behavior

The `Application` resource carries the annotation:

```yaml
azure.com/reconcile-policy: detach-on-delete
```

This means deleting the Kubernetes resource (e.g. removing the component from a cluster's app-of-apps) **does not** delete the Entra app registration in Azure. The app and its redirect URIs remain intact.

## Wiring Into the Fleet

Add the components to the appropriate `values.yaml` (e.g. `groups/all/values.yaml`):

```yaml
entraid-operator:
  annotations:
    argocd.argoproj.io/sync-wave: '5'
  source:
    path: components/entraid-operator

entraid-configuration:
  annotations:
    argocd.argoproj.io/sync-wave: '15'
  destination:
    namespace: azureserviceoperator-system
  source:
    path: components/entraid-configuration
```
