# Story 1.5: Configure SPIRE-Vault OIDC Trust via vault-config-operator

Status: done
baseline_commit: 992a97560abf757dc76e3443bb000f32931ad8ce

## Story

As a platform engineer,
I want Vault configured to trust SPIRE-issued JWT-SVIDs via OIDC federation,
so that workloads with SPIFFE identities can authenticate to Vault without pre-shared credentials.

## Acceptance Criteria

1. `vault-admin` namespace created with:
   - `argocd.argoproj.io/managed-by: openshift-gitops` label
   - `argocd.argoproj.io/sync-options: Delete=false` annotation
2. `AuthEngineMount` CR enables JWT auth engine at Vault path `auth/spire-jwt`
3. `JWTOIDCAuthEngineConfig` CR configures the JWT auth engine with:
   - `OIDCDiscoveryURL` pointing to the SPIRE OIDC Discovery Route: `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}`
   - `OIDCDiscoveryCAPEM` populated with the OpenShift ingress CA (see dev notes)
   - `defaultRole` set to `spire-vm-role`
4. `Policy` CR creates Vault policy `experiment-read` granting KV2 read access at `secret/data/experiment/*`
5. `JWTOIDCAuthEngineRole` CR creates role `spire-vm-role` with:
   - `roleType: jwt` (NOT `oidc`)
   - `boundAudiences: ["vault"]`
   - `boundSubject` matching the workload SPIFFE ID: `spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm`
   - `userClaim: sub`
   - `tokenPolicies` referencing `experiment-read`
   - `tokenTTL: "1h"`
6. `SecretEngineMount` CR enables KV v2 engine at Vault path `secret/`
7. A Kubernetes Job writes the test secret at `secret/data/experiment/demo` with key `message` = `"Hello from Vault via SPIFFE zero-trust!"`
8. All CRDs include the `authentication` block referencing Kubernetes auth at path `etl7`, role `vault-admin`, SA `default`
9. Overlay at `clusters/etl7/overlays/vault-spire-trust/`
10. Sync-wave `25` on the ArgoCD Application entry
11. Application entry in `clusters/etl7/values.yaml`

## Tasks / Subtasks

- [x] Task 1: Create `clusters/etl7/overlays/vault-spire-trust/` directory (AC: #9)
- [x] Task 2: Create `namespace.yaml` — vault-admin namespace (AC: #1)
  - [x] 2.1: Namespace `vault-admin`
  - [x] 2.2: Annotation `argocd.argoproj.io/sync-options: Delete=false`
  - [x] 2.3: Label `argocd.argoproj.io/managed-by: openshift-gitops`
- [x] Task 3: Create `auth-engine-mount.yaml` — JWT auth engine (AC: #2, #8)
- [x] Task 4: Create `jwt-auth-config.yaml` — OIDC discovery config (AC: #3, #8)
  - [x] 4.1: Set `OIDCDiscoveryURL` to Route URL
  - [x] 4.2: Populate `OIDCDiscoveryCAPEM` with OpenShift ingress CA (see dev notes)
  - [x] 4.3: Set `defaultRole: spire-vm-role`
- [x] Task 5: Create `policy.yaml` — Vault read policy (AC: #4, #8)
- [x] Task 6: Create `jwt-auth-role.yaml` — JWT auth role (AC: #5, #8)
  - [x] 6.1: `roleType: jwt`, `userClaim: sub`
  - [x] 6.2: `boundAudiences: ["vault"]`
  - [x] 6.3: `boundSubject: "spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm"`
  - [x] 6.4: `tokenPolicies: ["experiment-read"]`
- [x] Task 7: Create `secret-engine-mount.yaml` — KV v2 engine (AC: #6, #8)
- [x] Task 8: Create `seed-secret-job.yaml` — test secret writer (AC: #7)
- [x] Task 9: Create `configmap-ocp-service-ca.yaml` — OCP service-CA for Vault TLS trust (AC: #7)
  - [x] 9.1: ConfigMap `ocp-service-ca` with annotation `service.beta.openshift.io/inject-cabundle: "true"`
- [x] Task 10: Create `kustomization.yaml` (AC: #9)
  - [x] 10.1: Set `namespace: vault-admin`
  - [x] 10.2: List resources in dependency order
- [x] Task 11: Add application entry to `clusters/etl7/values.yaml` (AC: #10, #11)
  - [x] 11.1: Entry under the `# Zero Trust` section
  - [x] 11.2: Sync-wave `'25'`, source path `clusters/etl7/overlays/vault-spire-trust`

## Dev Notes

### ⚠️ CRITICAL: `bound_subject` is the WORKLOAD's SPIFFE ID — NOT the Agent's

The epic incorrectly states `bound_subject` should match `spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<fingerprint>`. This is **WRONG**.

The JWT-SVID `sub` claim contains the **workload's** SPIFFE ID (from the SPIRE registration entry), NOT the agent's x509pop identity. The agent SPIFFE ID is used only as the `parentID` in the registration entry.

**Correct mapping:**
- **Agent SPIFFE ID** (`parentID`): `spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<sha1-fingerprint>` — used by SPIRE internally to link the registration entry to the attested agent
- **Workload SPIFFE ID** (`spiffeID`): `spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm` — appears in the JWT-SVID `sub` claim, used in Vault's `boundSubject`

Story 6d will create the SPIRE registration entry with:
```bash
spire-server entry create \
  -parentID "spiffe://etl7.ocp.rht-labs.com/spire/agent/x509pop/<fingerprint>" \
  -spiffeID "spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm" \
  -selector "unix:uid:$(id -u vault-agent-user)"
```

The `boundSubject` here MUST match the `-spiffeID` in that registration entry exactly.

### ⚠️ CRITICAL: VCO CRD Field Naming is Case-Sensitive

The vault-config-operator CRD YAML keys use **mixed casing** that differs from the Vault CLI/API. Getting the casing wrong causes silent failures (fields ignored, defaults applied).

Key casing rules (`apiVersion: redhatcop.redhat.io/v1alpha1`):
- **UPPERCASE start:** `OIDCDiscoveryURL`, `OIDCDiscoveryCAPEM`, `JWTSupportedAlgs`, `JWKSURL`
- **lowercase start:** `boundIssuer`, `defaultRole`, `boundSubject`, `boundAudiences`, `boundClaims`, `boundClaimsType`, `roleType`, `userClaim`, `tokenPolicies`, `tokenTTL`, `tokenMaxTTL`
- **authentication block:** `path`, `role`, `serviceAccount.name`

### ⚠️ CRITICAL: OIDC Discovery URL Must Match JWT `iss` Claim Byte-for-Byte

Three values MUST be identical (including scheme, trailing slash, case):

| Component | Field | Value |
|---|---|---|
| SpireServer (Story 1.2) | `spec.jwtIssuer` | `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}` |
| SpireOIDCDiscoveryProvider (Story 1.2) | `spec.jwtIssuer` | `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}` |
| JWTOIDCAuthEngineConfig (this story) | `spec.OIDCDiscoveryURL` | `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}` |

If these don't match, Vault rejects every JWT-SVID with `issuer mismatch` error. The `${CLUSTER_BASE_DOMAIN}` envsubst variable resolves identically across all three.

### ⚠️ CRITICAL: OpenShift Ingress CA for OIDC Discovery TLS

The OIDC Discovery Provider Route uses the OpenShift ingress CA for TLS. Vault must trust this CA to fetch the OIDC discovery document. Most non-production OCP clusters use a self-signed ingress CA.

**How to extract the ingress CA:**
```bash
oc get secret -n openshift-ingress-operator router-ca \
  -o jsonpath='{.data.tls\.crt}' | base64 -d
```

**How to handle in GitOps:**
The `OIDCDiscoveryCAPEM` field takes inline PEM content. Since this is a **public CA certificate** (not a secret), it CAN be committed to the repo. Options:

1. **Inline the PEM directly** in `jwt-auth-config.yaml` — acceptable for experiment; update when CA rotates
2. **Use a PLACEHOLDER** and document a post-deploy manual step — less friction for initial commit

**For this experiment, use option 1:** Extract the CA cert, inline it in the YAML, commit it. The CA cert is public and changes rarely (typically years).

If the cluster uses a well-known CA (Let's Encrypt, etc.), `OIDCDiscoveryCAPEM` can be omitted — Vault's system trust store already has it.

### ⚠️ CRITICAL: Audience Must Match in Three Places

| Component | Config | Value |
|---|---|---|
| spiffe-helper (Story 6b) | `jwt_audience` in `helper.conf` | `"vault"` |
| JWT-SVID | `aud` claim (set at fetch time by spiffe-helper) | `["vault"]` |
| JWTOIDCAuthEngineRole (this story) | `boundAudiences` | `["vault"]` |

Vault 1.20+ enforces `bound_audiences` strictly — if the JWT `aud` claim doesn't contain at least one matching value, authentication fails.

### VCO Authentication Path — From Story 1.3's vault-admin-initializer

The vault-admin-initializer sidecar (Story 1.3) creates the Kubernetes auth backend that VCO CRDs use:

| Setting | Value | Source |
|---|---|---|
| Auth mount path | `etl7` | `vault auth enable --path etl7 kubernetes` |
| Role | `vault-admin` | `vault write auth/etl7/role/vault-admin ...` |
| Bound SA | `default` | `bound_service_account_names=default` |
| Bound Namespace | `vault-admin` | `bound_service_account_namespaces=vault-admin` |
| Policy | `vault-admin` | `path "/*" { capabilities = ["create","read","update","delete","list","sudo"] }` |

Every VCO CRD in this story references:
```yaml
authentication:
  path: etl7
  role: vault-admin
  serviceAccount:
    name: default
```

This tells VCO: "authenticate to Vault by fetching a token for the `default` SA in this CRD's namespace (`vault-admin`), and present it at `auth/etl7/login` with role `vault-admin`."

### VCO CRD Path Construction

The vault-config-operator constructs Vault API paths from CRD fields:

| CRD | Vault Path | Our Values |
|---|---|---|
| AuthEngineMount | `sys/auth/{metadata.name}` | `sys/auth/spire-jwt` → mounts at `auth/spire-jwt` |
| JWTOIDCAuthEngineConfig | `auth/{spec.path}/config` | `auth/spire-jwt/config` |
| JWTOIDCAuthEngineRole | `auth/{spec.path}/role/{spec.name}` | `auth/spire-jwt/role/spire-vm-role` |
| Policy | `sys/policies/acl/{metadata.name}` | `sys/policies/acl/experiment-read` |
| SecretEngineMount | `sys/mounts/{metadata.name}` | `sys/mounts/secret` → mounts at `secret/` |

When `spec.path` is omitted on AuthEngineMount/SecretEngineMount, `metadata.name` is the full mount path. When `spec.path` IS set, the full path is `{spec.path}/{metadata.name}`. Do NOT set `spec.path` on our CRDs — we want simple top-level mount paths.

### KVSecretEngineConfig Does NOT Exist

There is no `KVSecretEngineConfig` CRD in vault-config-operator. KV v2 is fully configured through `SecretEngineMount` with `options: {version: "2"}`. There is no VCO CRD for writing KV secrets — use a Kubernetes Job to seed the test secret.

### Exact File Templates

#### `clusters/etl7/overlays/vault-spire-trust/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault-admin
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

#### `clusters/etl7/overlays/vault-spire-trust/auth-engine-mount.yaml`

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: AuthEngineMount
metadata:
  name: spire-jwt
spec:
  authentication:
    path: etl7
    role: vault-admin
    serviceAccount:
      name: default
  type: jwt
  description: "SPIRE JWT auth for workload identity via OIDC federation"
```

#### `clusters/etl7/overlays/vault-spire-trust/jwt-auth-config.yaml`

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: JWTOIDCAuthEngineConfig
metadata:
  name: spire-jwt-config
spec:
  authentication:
    path: etl7
    role: vault-admin
    serviceAccount:
      name: default
  path: spire-jwt
  OIDCDiscoveryURL: "https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}"
  OIDCDiscoveryCAPEM: |
    PLACEHOLDER — replace with output of:
    oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' | base64 -d
  boundIssuer: "https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}"
  JWTSupportedAlgs:
    - RS256
  defaultRole: spire-vm-role
```

**Before committing:** Replace the `OIDCDiscoveryCAPEM` placeholder with the actual ingress CA PEM content. See the OIDC CA section in dev notes.

#### `clusters/etl7/overlays/vault-spire-trust/policy.yaml`

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Policy
metadata:
  name: experiment-read
spec:
  authentication:
    path: etl7
    role: vault-admin
    serviceAccount:
      name: default
  type: acl
  policy: |
    path "secret/data/experiment/*" {
      capabilities = ["read"]
    }
    path "secret/metadata/experiment/*" {
      capabilities = ["read", "list"]
    }
```

Note: `secret/metadata/` access is included so vault-agent can verify the secret exists; `secret/data/` is the actual KV2 data path.

#### `clusters/etl7/overlays/vault-spire-trust/jwt-auth-role.yaml`

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: JWTOIDCAuthEngineRole
metadata:
  name: spire-vm-role
spec:
  authentication:
    path: etl7
    role: vault-admin
    serviceAccount:
      name: default
  path: spire-jwt
  name: spire-vm-role
  roleType: jwt
  userClaim: sub
  boundAudiences:
    - vault
  boundSubject: "spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm"
  tokenPolicies:
    - experiment-read
  tokenTTL: "1h"
  tokenMaxTTL: "24h"
```

#### `clusters/etl7/overlays/vault-spire-trust/secret-engine-mount.yaml`

```yaml
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata:
  name: secret
spec:
  authentication:
    path: etl7
    role: vault-admin
    serviceAccount:
      name: default
  type: kv
  description: "KV v2 engine for experiment secrets"
  options:
    version: "2"
```

#### `clusters/etl7/overlays/vault-spire-trust/seed-secret-job.yaml`

This Job authenticates to Vault and writes the test secret. It runs once and uses the vault-admin SA token:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: seed-experiment-secret
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 10
  template:
    spec:
      serviceAccountName: default
      restartPolicy: OnFailure
      containers:
        - name: seed-secret
          image: registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi
          env:
            - name: VAULT_ADDR
              value: "https://vault.vault.svc:8200"
            - name: VAULT_CACERT
              value: "/vault-ca/service-ca.crt"
          command:
            - /bin/sh
            - -c
            - |
              SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

              # Authenticate to Vault via Kubernetes auth
              VAULT_TOKEN=$(vault write -field=token auth/etl7/login \
                role=vault-admin \
                jwt="${SA_TOKEN}")
              export VAULT_TOKEN

              # Wait for KV v2 engine to be ready (VCO may still be reconciling)
              for i in $(seq 1 30); do
                if vault secrets list | grep -q '^secret/'; then
                  echo "KV v2 engine ready"
                  break
                fi
                echo "Waiting for KV v2 engine... attempt $i"
                sleep 10
              done

              # Write the test secret
              vault kv put secret/experiment/demo \
                message="Hello from Vault via SPIFFE zero-trust!"

              echo "Test secret seeded successfully"
              vault kv get secret/experiment/demo
          volumeMounts:
            - name: vault-ca
              mountPath: /vault-ca
              readOnly: true
      volumes:
        - name: vault-ca
          configMap:
            name: ocp-service-ca
```

**Notes:**
- Uses ArgoCD `Sync` hook so it runs after CRD resources are applied
- `BeforeHookCreation` delete policy ensures re-runs on re-sync
- `backoffLimit: 10` and retry loop handle timing — the Job may start before VCO finishes reconciling the `SecretEngineMount`
- The Job needs the OCP service-CA to trust Vault's TLS (Vault uses service-serving certs from Story 1.3)
- If the `openshift-service-ca.crt` ConfigMap isn't available, the Job may need to use `VAULT_SKIP_VERIFY=true` as a fallback — evaluate and adjust

#### `clusters/etl7/overlays/vault-spire-trust/configmap-ocp-service-ca.yaml`

This ConfigMap is auto-populated by OpenShift with the service-serving CA bundle (same pattern as Story 1.4):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
  name: ocp-service-ca
```

The seed-secret Job uses this CA to trust Vault's TLS certificate (Vault uses OCP service-serving certs from Story 1.3).

#### `clusters/etl7/overlays/vault-spire-trust/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: vault-admin

resources:
  - namespace.yaml
  - configmap-ocp-service-ca.yaml
  - auth-engine-mount.yaml
  - jwt-auth-config.yaml
  - policy.yaml
  - jwt-auth-role.yaml
  - secret-engine-mount.yaml
  - seed-secret-job.yaml
```

Resources are listed in dependency order (auth engine before config, policy before role referencing it, secret engine before seed job). ArgoCD applies them in a single sync; VCO handles reconciliation ordering via its controller.

#### `clusters/etl7/values.yaml` — add this block

Insert under the `# Zero Trust` section (after `vault-config-operator` from Story 1.4):

```yaml
  vault-spire-trust:
    annotations:
      argocd.argoproj.io/sync-wave: '25'
    source:
      path: clusters/etl7/overlays/vault-spire-trust
```

Wave `25` ensures this deploys after:
- ZTWIM instance (wave 15, Story 1.2) — OIDC discovery endpoint must be running
- Vault (wave 15, Story 1.3) — Vault must be initialized and accessible
- vault-config-operator (wave 5, Story 1.4) — VCO must be running to reconcile CRDs

### Files Created/Modified by This Story

| File | Action | Notes |
|---|---|---|
| `clusters/etl7/overlays/vault-spire-trust/namespace.yaml` | NEW | vault-admin namespace |
| `clusters/etl7/overlays/vault-spire-trust/configmap-ocp-service-ca.yaml` | NEW | OCP service-CA for Vault TLS trust |
| `clusters/etl7/overlays/vault-spire-trust/auth-engine-mount.yaml` | NEW | JWT auth engine mount |
| `clusters/etl7/overlays/vault-spire-trust/jwt-auth-config.yaml` | NEW | OIDC discovery config |
| `clusters/etl7/overlays/vault-spire-trust/policy.yaml` | NEW | experiment-read policy |
| `clusters/etl7/overlays/vault-spire-trust/jwt-auth-role.yaml` | NEW | spire-vm-role JWT role |
| `clusters/etl7/overlays/vault-spire-trust/secret-engine-mount.yaml` | NEW | KV v2 engine |
| `clusters/etl7/overlays/vault-spire-trust/seed-secret-job.yaml` | NEW | Test secret writer Job |
| `clusters/etl7/overlays/vault-spire-trust/kustomization.yaml` | NEW | Kustomize config |
| `clusters/etl7/values.yaml` | UPDATE | Add `vault-spire-trust` app entry |

### What NOT to Do

- **Do NOT set `roleType: oidc`** — SPIRE uses direct JWT presentation, not interactive OIDC browser flow; use `roleType: jwt`
- **Do NOT set `boundSubject` to the agent's x509pop SPIFFE ID** — the `sub` claim contains the WORKLOAD's SPIFFE ID from the registration entry, not the agent's identity
- **Do NOT omit `OIDCDiscoveryCAPEM`** on non-production clusters — the OpenShift ingress CA is self-signed and Vault won't trust it without the CA cert
- **Do NOT use `OIDCClientID` or `OIDCClientSecret`** — those are for interactive OIDC flows, not JWT auth
- **Do NOT use `VaultSecret` or `RandomSecret`** to create the test secret — `VaultSecret` reads from Vault (doesn't write), `RandomSecret` generates random values; use a Job
- **Do NOT use `path` field on `AuthEngineMount` or `SecretEngineMount`** — omitting it makes `metadata.name` the full mount path; setting `path` adds a prefix (e.g., `path: foo` + `name: bar` → mount at `foo/bar`)
- **Do NOT confuse `boundIssuer` casing** with `OIDCDiscoveryURL` casing — `boundIssuer` starts lowercase, `OIDCDiscoveryURL` starts uppercase; this is not a typo, it matches the Go struct json tags
- **Do NOT create an `OperatorPolicy`** — this story creates VCO CRDs (Custom Resources), not an operator
- **Do NOT add sync-wave annotations to the component YAML files** — wave `25` goes on the ArgoCD Application only
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment
- **Do NOT modify `clusters/etl4/` or any other cluster** — etl7 only
- **Do NOT create a base component in `components/`** — the trust config is inherently cluster-specific (trust domain, OIDC URL, SPIFFE IDs); put everything directly in the overlay

### Cross-Story Dependencies and Impact

| Story | Dependency Type | Impact |
|---|---|---|
| **Story 1.2** (ZTWIM Instance) | Prerequisite — OIDC Discovery Route | `OIDCDiscoveryURL` points to the Route created by `SpireOIDCDiscoveryProvider` with `managedRoute: "true"`. The Route must be serving `/.well-known/openid-configuration` and `/keys` endpoints |
| **Story 1.3** (Vault on etl7) | Prerequisite — Vault initialized | The `vault-admin-initializer` sidecar creates K8s auth at path `etl7` with role `vault-admin` bound to SA `default` in ns `vault-admin`. All our CRDs depend on this auth being operational |
| **Story 1.4** (vault-config-operator) | Prerequisite — VCO running | VCO must be running to reconcile our CRDs. VCO's `VAULT_ADDR=https://vault.vault.svc:8200` connects to the Vault from Story 1.3 |
| **Story 1.6b** (SPIRE Agent + Helper) | Consumer — uses `boundAudiences` | spiffe-helper's `jwt_audience` must be `"vault"` to match our `boundAudiences` |
| **Story 1.6c** (Vault Agent + httpd) | Consumer — uses JWT auth path | vault-agent's `auto_auth.method.jwt.mount_path` must be `"auth/spire-jwt"` and `role` must be `"spire-vm-role"` |
| **Story 1.6d** (Deploy VM) | Consumer — uses `boundSubject` | The SPIRE registration entry's `-spiffeID` must be exactly `spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm` to match our `boundSubject` |

### Sync-Wave and Startup Ordering

- Wave `5`: ZTWIM operator (Story 1.1), vault-config-operator (Story 1.4)
- Wave `15`: ZTWIM instance with OIDC (Story 1.2), Vault (Story 1.3)
- Wave `25`: **vault-spire-trust** (this story) — all dependencies ready

VCO reconciliation behavior at wave 25:
1. VCO sees new CRDs in `vault-admin` namespace
2. For each CRD, VCO authenticates to Vault using the SA token at `auth/etl7/login`
3. VCO applies the Vault configuration via the Vault API
4. If Vault or the OIDC endpoint isn't ready, VCO retries with exponential backoff

If the seed-secret Job runs before the `SecretEngineMount` is reconciled, it will retry (up to `backoffLimit: 10` with sleep between attempts).

### Previous Story Intelligence

From Stories 1.1–1.4:
- **Namespace pattern**: Use the same annotation/label set — `Delete=false` annotation, `managed-by: openshift-gitops` label
- **No sync-wave on component YAML**: Confirmed — waves only on the ArgoCD Application entry in values.yaml
- **values.yaml placement**: Entries go under the `# Zero Trust` section, ordered by dependency/wave
- **VCO Vault connection**: VCO (Story 1.4) connects to Vault at `https://vault.vault.svc:8200` using the OCP service-serving CA — the seed-secret Job should use the same address and CA
- **Auth path `etl7`**: Confirmed in Story 1.3 — the vault-admin-initializer creates K8s auth at path `etl7` (not `hub`)
- **Image version**: Use `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi` for the seed-secret Job (matches Story 1.3)

### SPIRE OIDC Discovery Provider Endpoints

The managed Route at `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}` serves:

| Endpoint | Returns |
|---|---|
| `/.well-known/openid-configuration` | OIDC discovery document (JSON) with `issuer` and `jwks_uri` |
| `/keys` | JWKS (public keys for JWT validation) |

Vault fetches the discovery document, extracts `jwks_uri`, then fetches the JWKS to validate JWT-SVIDs. This happens on first login and periodically when new `kid` values are encountered.

### JWT-SVID Claims Structure

When a workload (vault-agent on the VM) fetches a JWT-SVID from spiffe-helper:

```json
{
  "sub": "spiffe://etl7.ocp.rht-labs.com/experiment/demo-vm",
  "aud": ["vault"],
  "iss": "https://oidc-discovery.apps.etl7.ocp.rht-labs.com",
  "iat": 1726400000,
  "exp": 1726400300
}
```

Vault validates:
- `iss` matches `OIDCDiscoveryURL` ✓
- `aud` contains at least one value from `boundAudiences` ✓
- `sub` matches `boundSubject` ✓
- Signature validates against JWKS from the discovery endpoint ✓
- Token not expired ✓

### Known Gotchas

1. **JWT-SVID short TTL (5m)**: SPIRE issues short-lived JWTs by default (`defaultJWTValidity: "5m"` in Story 1.2). spiffe-helper refreshes them automatically. vault-agent's auto-auth re-reads the JWT file on change. Ensure vault-agent's `remove_jwt_after_reading = false` (Story 6c) so spiffe-helper can overwrite it.

2. **JWKS key rotation**: SPIRE rotates JWT signing keys periodically. Vault caches JWKS and auto-refreshes when it encounters an unknown `kid`. This is self-healing but may cause brief auth failures during rotation.

3. **VCO reconciliation timing**: VCO may attempt to configure JWT auth before the OIDC discovery endpoint is reachable. VCO retries with backoff, so this is self-healing. Check VCO logs if CRDs stay in `Error` status.

4. **Namespace must exist before CRDs**: The `vault-admin` namespace must be created before VCO CRDs are applied to it. Kustomize sets `namespace: vault-admin` on all resources. ArgoCD applies resources in order listed in `kustomization.yaml` — list `namespace.yaml` first.

### Project Structure Notes

- All resources live at `clusters/etl7/overlays/vault-spire-trust/` — no base component in `components/` because the trust config is inherently cluster-specific (OIDC URL, trust domain, SPIFFE IDs, ingress CA)
- The `vault-spire-trust` name follows the `<name>-<purpose>` convention; it groups logically with `vault` (Story 1.3) and `vault-config-operator` (Story 1.4)
- The cross-namespace pattern (VCO operator in `vault-config-operator` ns, CRDs in `vault-admin` ns) follows the established repo pattern used by external-dns, otel, netobserv, and kiali

### References

- [vault-config-operator GitHub](https://github.com/redhat-cop/vault-config-operator/) — CRD API types and examples
- [vault-config-operator auth section docs](https://github.com/redhat-cop/vault-config-operator/blob/main/docs/auth-section.md) — authentication block reference
- [SPIFFE/Vault OIDC federation tutorial](https://spiffe.io/docs/latest/keyless/vault/readme/) — overall OIDC trust flow
- [OCP ZTWIM Vault OIDC docs §12.7.2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) — OpenShift-specific config
- [Vault JWT auth method](https://developer.hashicorp.com/vault/docs/auth/jwt) — JWT role fields and behavior
- [SPIRE x509pop server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_x509pop.md) — agent SPIFFE ID format
- [SPIFFE JWT-SVID specification](https://spiffe.io/docs/latest/spiffe-specs/jwt-svid/) — JWT claim structure
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.5]
- [Pattern reference: Story 1.4 — VCO deployment and Vault connection]
- [Pattern reference: Story 1.3 — vault-admin-initializer auth path `etl7`]
- [Pattern reference: Story 1.2 — OIDC discovery Route URL]

## Dev Agent Record

### Agent Model Used



### Debug Log References

### Completion Notes List

### File List

## Suggested Review Order

**ArgoCD Integration**

- Entry point: new ArgoCD Application at sync-wave 25 with `ignoreDifferences` for injected ConfigMap
  [`values.yaml:85`](../../clusters/etl7/values.yaml#L85)

**Vault Trust Configuration (VCO CRDs)**

- Resource ordering and namespace injection — dependency chain for reconciliation
  [`kustomization.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/kustomization.yaml#L1)

- OIDC discovery config — the architectural core: binds Vault's JWT auth to SPIRE's OIDC endpoint
  [`jwt-auth-config.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/jwt-auth-config.yaml#L1)

- JWT role with SPIFFE ID binding — `boundSubject` must match workload SPIFFE ID exactly
  [`jwt-auth-role.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/jwt-auth-role.yaml#L1)

- JWT auth engine mount at `auth/spire-jwt`
  [`auth-engine-mount.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/auth-engine-mount.yaml#L1)

- KV2 read policy scoped to `secret/data/experiment/*`
  [`policy.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/policy.yaml#L1)

**Secret Engine & Seed**

- KV v2 engine at `secret/` with version 2 options
  [`secret-engine-mount.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/secret-engine-mount.yaml#L1)

- Sync hook Job with `set -euo pipefail`, explicit KV2 readiness check, and timeout guard
  [`seed-secret-job.yaml:26`](../../clusters/etl7/overlays/vault-spire-trust/seed-secret-job.yaml#L26)

**Supporting Resources**

- vault-admin namespace with ArgoCD labels/annotations
  [`namespace.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/namespace.yaml#L1)

- OCP service-CA ConfigMap for Vault TLS trust (auto-injected by service-ca-operator)
  [`configmap-ocp-service-ca.yaml:1`](../../clusters/etl7/overlays/vault-spire-trust/configmap-ocp-service-ca.yaml#L1)
