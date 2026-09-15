# Story 1.2: Deploy ZTWIM Operands (SpireServer, OIDC Discovery Provider, CSI Driver)

Status: done
baseline_commit: efe45306d63c30e5ad9ece0713df828815be234b

## Story

As a platform engineer,
I want the SPIRE server, OIDC discovery provider, SPIFFE CSI driver, and supporting operands deployed on etl7,
so that workloads can receive SPIFFE identities and external services can validate JWT-SVIDs via OIDC.

## Acceptance Criteria

1. New component `components/ztwim-instance/` created following the `<name>-instance` naming convention
2. Contains five ZTWIM operand CRs, each named `cluster` (singleton enforcement), deployed in the `zero-trust-workload-identity-manager` namespace:
   - `ZeroTrustWorkloadIdentityManager` CR with trust domain and cluster name
   - `SpireServer` CR with OIDC issuer URL, CA subject, persistence, and datastore
   - `SpireAgent` CR with k8sPSAT node attestation (defaults — not used in this experiment but part of standard operand set)
   - `SpiffeCSIDriver` CR with standard socket path and plugin name (defaults — not used in this experiment but part of standard operand set)
   - `SpireOIDCDiscoveryProvider` CR with managed Route and matching JWT issuer
3. Contains `kustomization.yaml` referencing all operand CRs
4. Overlay at `clusters/etl7/overlays/ztwim-instance/` with cluster-specific configuration via Kustomize patches:
   - Trust domain set to `etl7.ocp.rht-labs.com`
   - Cluster name set to `etl7`
   - JWT issuer / OIDC discovery URL set to `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}`
   - SpireServer persistence storage class set to `ontap-san`
5. Sync-wave set to `15` (instance tier) on the ArgoCD Application entry
6. Application entry in `clusters/etl7/values.yaml`
7. OIDC discovery endpoint is accessible via Route (auto-created by `managedRoute: "true"`)
8. Component has a `readme.md`

## Tasks / Subtasks

- [x] Task 1: Create `components/ztwim-instance/` directory (AC: #1)
- [x] Task 2: Create `zero-trust-workload-identity-manager.yaml` (AC: #2)
  - [x] 2.1: apiVersion `operator.openshift.io/v1alpha1`, kind `ZeroTrustWorkloadIdentityManager`, name `cluster`
  - [x] 2.2: Placeholder `trustDomain` and `clusterName` (patched by overlay)
- [x] Task 3: Create `spire-server.yaml` (AC: #2)
  - [x] 3.1: `jwtIssuer` placeholder (patched by overlay)
  - [x] 3.2: `caSubject` with org "Red Hat Labs", commonName "SPIRE Server CA"
  - [x] 3.3: `persistence` with `size: "1Gi"`, `accessMode: "ReadWriteOnce"` (storageClass patched by overlay)
  - [x] 3.4: `datastore` with sqlite3, standard connection string
- [x] Task 4: Create `spire-agent.yaml` — all defaults, not used in this experiment (AC: #2)
  - [x] 4.1: Copy verbatim from Red Hat docs example (k8sPSAT, k8s workload attestor)
- [x] Task 5: Create `spiffe-csi-driver.yaml` — all defaults, not used in this experiment (AC: #2)
  - [x] 5.1: Copy verbatim from Red Hat docs example (standard socket path and plugin name)
- [x] Task 6: Create `spire-oidc-discovery-provider.yaml` (AC: #2)
  - [x] 6.1: `csiDriverName: "csi.spiffe.io"` matching SpiffeCSIDriver
  - [x] 6.2: `jwtIssuer` placeholder (patched by overlay, must match SpireServer)
  - [x] 6.3: `managedRoute: "true"` for automatic OpenShift Route
  - [x] 6.4: `replicaCount: 1`
- [x] Task 7: Create `kustomization.yaml` for the base component (AC: #3)
  - [x] 7.1: Set `namespace: zero-trust-workload-identity-manager` (matches existing `*-instance` pattern)
- [x] Task 8: Create overlay `clusters/etl7/overlays/ztwim-instance/` (AC: #4)
  - [x] 8.1: `kustomization.yaml` referencing base component and applying patches
  - [x] 8.2: Patches for trust domain, cluster name, JWT issuer, storage class
- [x] Task 9: Add application entry to `clusters/etl7/values.yaml` (AC: #5, #6)
- [x] Task 10: Create `components/ztwim-instance/readme.md` (AC: #8)

### Review Findings

- [x] [Review][Patch] Readme says operand CRs live in the operator namespace; they are cluster-scoped singletons [`readme.md:7`]
- [x] [Review][Patch] Readme says SpireAgent/SpiffeCSIDriver are unused; OIDC provider needs them (operator creates ClusterSPIFFEID) [`readme.md:51`]
- [x] [Review][Patch] Immutable-fields warning omits `bundleConfigMap` on ZeroTrustWorkloadIdentityManager [`readme.md:38`]
- [x] [Review][Patch] Note that Stories 1.5/1.6b will use create-only mode; ArgoCD will otherwise revert x509pop mutations [`readme.md:47`]
- [x] [Review][Patch] Operator readme still says the next component deploys ClusterSPIFFEID operands [`ztwim-operator/readme.md:32`]

## Dev Notes

### SpireAgent and SpiffeCSIDriver — Deployed with Defaults, Not Used in This Experiment

The **SpireAgent** (cluster-level DaemonSet with k8sPSAT) and **SpiffeCSIDriver** are standard ZTWIM operands deployed as part of the complete operand set. However, they are **not functionally used in this experiment**:

- The VM's spire-agent (Story 6b) uses **x509pop** attestation and runs standalone inside the VM — it does NOT use the cluster-level SpireAgent DaemonSet
- No cluster workloads in this experiment need SPIFFE identities via the CSI driver

Deploy both with **all defaults** — no cluster-specific configuration or overlay patches needed for these two CRs. They are included for completeness and to follow the standard ZTWIM deployment procedure.

### ⚠️ CRITICAL: x509pop NOT Supported in SpireServer CRD

The SpireServer CRD (`operator.openshift.io/v1alpha1`) does **NOT** expose a field for configuring additional NodeAttestor plugins like x509pop. The CRD only supports:
- `jwtIssuer`, `caValidity`, `defaultX509Validity`, `defaultJWTValidity`, `jwtKeyType`
- `caSubject` (country, organization, commonName)
- `persistence` (size, accessMode, storageClass)
- `datastore` (databaseType, connectionString, etc.)
- `upstreamAuthority` (cert-manager or Vault — added in v1.1.0, but this is for CA delegation, NOT node attestation)

**x509pop server-side configuration requires manual patching** (Stories 5/6b):
1. Enable `create-only` mode via annotation `ztwim.openshift.io/create-only=true`
2. Create a Secret containing the cert-manager CA bundle
3. Mount the Secret into the spire-server StatefulSet
4. Patch the `spire-server` ConfigMap to add the x509pop NodeAttestor plugin
5. Restart the SPIRE Server pod

This procedure is documented in [Sky Computing Part 2](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration). **Do NOT attempt x509pop config in this story.**

### ⚠️ CRITICAL: Immutable Fields — Get These Right First Time

The following fields on the CRDs are **immutable after creation** (enforced by CEL validation):
- `ZeroTrustWorkloadIdentityManager`: `trustDomain`, `clusterName`, `bundleConfigMap`
- `SpireServer`: All `persistence` fields (`size`, `accessMode`, `storageClass`)

If these are set incorrectly, the CRs must be deleted and recreated. Choose values carefully.

### ⚠️ CRITICAL: jwtIssuer Must Match Everywhere

The `jwtIssuer` value MUST be identical on both:
- `SpireServer.spec.jwtIssuer`
- `SpireOIDCDiscoveryProvider.spec.jwtIssuer`

A mismatch causes JWT validation failures. Use the exact same value in both overlay patches: `https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}`

### ⚠️ CRITICAL: CRD Deployment Order Matters

The Red Hat docs mandate this deployment sequence:
1. `ZeroTrustWorkloadIdentityManager` (creates controller infrastructure)
2. `SpireServer` (central identity authority)
3. `SpireAgent` (node-level agent DaemonSet)
4. `SpiffeCSIDriver` (CSI driver for workload socket mounting)
5. `SpireOIDCDiscoveryProvider` (OIDC endpoint for external JWT validation)

Since ArgoCD applies all resources in a single sync, the ZTWIM operator controller handles ordering internally. However, list resources in the `kustomization.yaml` in the above order to express intent.

### ⚠️ CRITICAL: All CRDs Must Be Named "cluster"

Every ZTWIM operand CRD is enforced as a singleton — the `metadata.name` **must** be `cluster`. This is validated by CEL admission rules.

### Operand CRD Specifications (Verified Sep 2026, ZTWIM v1.1.0)

#### ZeroTrustWorkloadIdentityManager

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ZeroTrustWorkloadIdentityManager
metadata:
  name: cluster
spec:
  trustDomain: "PLACEHOLDER"       # Patched by overlay → etl7.ocp.rht-labs.com
  clusterName: "PLACEHOLDER"       # Patched by overlay → etl7
  bundleConfigMap: "spire-bundle"   # Default, optional
```

Red Hat recommends `trustDomain` match the base application URL (`apps.mycluster.example.com`) for automatic Route hostname generation. For our experiment `etl7.ocp.rht-labs.com` follows the trust domain convention used in the epic architecture.

#### SpireServer

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireServer
metadata:
  name: cluster
spec:
  logLevel: "info"
  logFormat: "text"
  jwtIssuer: "PLACEHOLDER"         # Patched → https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}
  caValidity: "24h"
  defaultX509Validity: "1h"
  defaultJWTValidity: "5m"
  caKeyType: "rsa-2048"
  jwtKeyType: "rsa-2048"
  caSubject:
    country: "US"
    organization: "Red Hat Labs"
    commonName: "SPIRE Server CA"
  persistence:
    size: "1Gi"
    accessMode: "ReadWriteOnce"
    storageClass: "PLACEHOLDER"    # Patched → ontap-san
  datastore:
    databaseType: "sqlite3"
    connectionString: "/run/spire/data/datastore.sqlite3"
    maxOpenConns: 100
    maxIdleConns: 10
    connMaxLifetime: 0
    disableMigration: "false"
```

- 1Gi persistence is acceptable for this experiment (sqlite3 datastore)
- Production would use PostgreSQL; sqlite3 is fine for a single-replica SPIRE Server

#### SpireAgent

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireAgent
metadata:
  name: cluster
spec:
  socketPath: "/run/spire/agent-sockets"
  logLevel: "info"
  logFormat: "text"
  nodeAttestor:
    k8sPSATEnabled: "true"
  workloadAttestors:
    k8sEnabled: "true"
    workloadAttestorsVerification:
      type: "auto"
    disableContainerSelectors: "false"
    useNewContainerLocator: "true"
```

- Deployed with all defaults — not functionally used in this experiment
- k8sPSAT is for cluster workloads (pods); the VM uses x509pop separately (Story 6b)

#### SpiffeCSIDriver

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpiffeCSIDriver
metadata:
  name: cluster
spec:
  agentSocketPath: "/run/spire/agent-sockets"
  pluginName: "csi.spiffe.io"
```

- Deployed with all defaults — not functionally used in this experiment
- `pluginName` value `csi.spiffe.io` is the standard; matches `SpireOIDCDiscoveryProvider.spec.csiDriverName`

#### SpireOIDCDiscoveryProvider

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: SpireOIDCDiscoveryProvider
metadata:
  name: cluster
spec:
  logLevel: "info"
  logFormat: "text"
  csiDriverName: "csi.spiffe.io"
  jwtIssuer: "PLACEHOLDER"        # Patched → same as SpireServer.spec.jwtIssuer
  replicaCount: 1
  managedRoute: "true"
```

- `managedRoute: "true"` auto-creates an OpenShift Route at `oidc-discovery.apps.<cluster-domain>`
- The generated Route URL becomes the OIDC discovery endpoint used by Vault in Story 5

### Overlay Patch Strategy

Use JSON patches in the overlay `kustomization.yaml` to set cluster-specific values. The base component uses PLACEHOLDER values that MUST be patched:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../../components/ztwim-instance

patches:
  - target:
      kind: ZeroTrustWorkloadIdentityManager
      group: operator.openshift.io
      version: v1alpha1
    patch: |-
      - op: replace
        path: /spec/trustDomain
        value: 'etl7.ocp.rht-labs.com'
      - op: replace
        path: /spec/clusterName
        value: 'etl7'
  - target:
      kind: SpireServer
      group: operator.openshift.io
      version: v1alpha1
    patch: |-
      - op: replace
        path: /spec/jwtIssuer
        value: 'https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}'
      - op: replace
        path: /spec/persistence/storageClass
        value: 'ontap-san'
  - target:
      kind: SpireOIDCDiscoveryProvider
      group: operator.openshift.io
      version: v1alpha1
    patch: |-
      - op: replace
        path: /spec/jwtIssuer
        value: 'https://oidc-discovery.apps.${CLUSTER_BASE_DOMAIN}'
```

This pattern follows the [GitOps + ZTWIM integration guide](https://developers.redhat.com/articles/2026/05/07/integrate-zero-trust-workload-identity-manager-red-hat-openshift-gitops) which uses the same Kustomize patch approach.

### Application Entry for `clusters/etl7/values.yaml`

Insert after the `ztwim-operator` entry under the `# Zero Trust` section:

```yaml
  ztwim-instance:
    annotations:
      argocd.argoproj.io/sync-wave: '15'
    source:
      path: clusters/etl7/overlays/ztwim-instance
```

- Wave `15` is the instance tier (follows operator at wave `5`)
- Path points to the overlay, NOT the base component
- No `destination.namespace` override needed — the CRs are namespace-scoped to `zero-trust-workload-identity-manager` which the operator already created

### Files Created/Modified by This Story

| File | Action | Notes |
|---|---|---|
| `components/ztwim-instance/zero-trust-workload-identity-manager.yaml` | NEW | Primary ZTWIM manager CR |
| `components/ztwim-instance/spire-server.yaml` | NEW | SpireServer CR |
| `components/ztwim-instance/spire-agent.yaml` | NEW | SpireAgent CR (defaults — not used in experiment) |
| `components/ztwim-instance/spiffe-csi-driver.yaml` | NEW | SpiffeCSIDriver CR (defaults — not used in experiment) |
| `components/ztwim-instance/spire-oidc-discovery-provider.yaml` | NEW | OIDC Discovery Provider CR |
| `components/ztwim-instance/kustomization.yaml` | NEW | Kustomize base |
| `components/ztwim-instance/readme.md` | NEW | Component docs |
| `clusters/etl7/overlays/ztwim-instance/kustomization.yaml` | NEW | Cluster overlay with patches |
| `clusters/etl7/values.yaml` | UPDATE | Add `ztwim-instance` app entry |

### What NOT to Do

- **Do NOT configure x509pop in this story** — the SpireServer CRD does not support it; x509pop requires create-only mode + manual patching (Stories 5/6b)
- **Do NOT skip the SpireAgent or SpiffeCSIDriver CRs** — even though they're not used in this experiment, deploy them with defaults as part of the standard ZTWIM operand set
- **Do NOT use a trust domain that doesn't follow SPIFFE conventions** — must be lowercase alphanumeric with hyphens and dots, max 255 chars
- **Do NOT add sync-wave annotations to the component YAML files** — waves go on the ArgoCD Application only (same pattern as Story 1.1)
- **Do NOT put cluster-specific values in the base component** — use the overlay with Kustomize patches for trust domain, JWT issuer, and storage class
- **Do NOT use different `jwtIssuer` values** between SpireServer and SpireOIDCDiscoveryProvider — they MUST be identical
- **Do NOT customize the SpireAgent or SpiffeCSIDriver CRs** — use the exact defaults from the Red Hat docs; they are not functionally used in this experiment
- **Do NOT modify `clusters/etl4/` or any other cluster** — this story is etl7-only
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment

### Codebase Patterns to Follow

Follow the `*-instance` component pattern established in the repo. Key conventions from Story 1.1 and existing components:
- Base component at `components/ztwim-instance/` with reusable YAML + `kustomization.yaml`
- **Set `namespace: zero-trust-workload-identity-manager` on the base `kustomization.yaml`** — all existing `*-instance` components do this (e.g. `nmstate-instance` has `namespace: openshift-nmstate`, `trident-instance` has `namespace: netapp-trident`)
- Cluster overlay at `clusters/etl7/overlays/ztwim-instance/` with Kustomize patches for cluster-specific values
- The naming convention `ztwim-operator` → `ztwim-instance` follows the `<name>-operator` / `<name>-instance` lifecycle group pattern
- No sync-wave annotations on component YAML — wave `15` is on the Application entry

### Cross-Story Dependencies and Impact

| Story | Dependency | Impact on This Story |
|---|---|---|
| **Story 1.1** (ZTWIM Operator) | Prerequisite — operator must be installed | Our CRs require the operator's CRDs to exist |
| **Story 1.5** (SPIRE↔Vault Trust) | Consumer — uses OIDC discovery Route URL | The Route URL from `managedRoute: "true"` will be referenced by Vault's JWT auth config |
| **Story 1.6b** (SPIRE Agent + Helper) | Cross-dependency — needs x509pop on SpireServer | After this story, the SpireServer needs create-only mode + manual x509pop patching (not in scope here) |

### Project Structure Notes

- Component lives at `components/ztwim-instance/` following the `<name>-instance` naming convention
- Overlay at `clusters/etl7/overlays/ztwim-instance/` for cluster-specific patches
- The naming prefix `ztwim-` groups related components: `ztwim-operator` (wave 5) → `ztwim-instance` (wave 15)
- All five CRDs deploy into the operator's namespace `zero-trust-workload-identity-manager`

### References

- [OCP 4.22 ZTWIM docs — Deploying operands §12.5](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)
- [ZTWIM + GitOps integration guide](https://developers.redhat.com/articles/2026/05/07/integrate-zero-trust-workload-identity-manager-red-hat-openshift-gitops) — Kustomize patch pattern for trust domain and JWT issuer
- [Sky Computing Part 2 — x509pop on ZTWIM](https://developers.redhat.com/blog/2026/04/23/sky-computing-openshift-service-mesh-spire-multicloud-integration) — Procedure for adding x509pop to ZTWIM SpireServer (future stories)
- [SPIRE x509pop server plugin](https://github.com/spiffe/spire/blob/main/doc/plugin_server_nodeattestor_x509pop.md) — x509pop server-side config reference
- [ZTWIM SpireServer CRD types](https://github.com/openshift/zero-trust-workload-identity-manager/blob/e2e8ee5088b1/api/v1alpha1/spire_server_config_types.go) — CRD field reference
- [ZTWIM ZeroTrustWorkloadIdentityManager CRD types](https://github.com/openshift/zero-trust-workload-identity-manager/blob/e2e8ee5088b1/api/v1alpha1/zero_trust_workload_identity_manager_types.go) — Manager CRD reference
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.2]
- [Pattern reference: Story 1.1 — ztwim-operator] — component and values.yaml patterns

## Dev Agent Record

### Agent Model Used



### Debug Log References

### Completion Notes List

### File List

## Suggested Review Order

**Cluster overlay — how etl7 customizes the base**

- JSON patches for trust domain, cluster name, jwtIssuer, and storageClass
  [`kustomization.yaml:7`](../../clusters/etl7/overlays/ztwim-instance/kustomization.yaml#L7)

**Base component — the reusable operand set**

- Resource list in CRD deployment order, namespace set
  [`kustomization.yaml:1`](../../components/ztwim-instance/kustomization.yaml#L1)

- Primary manager CR — immutable trustDomain and clusterName
  [`zero-trust-workload-identity-manager.yaml:1`](../../components/ztwim-instance/zero-trust-workload-identity-manager.yaml#L1)

- SpireServer CR — CA config, immutable persistence, sqlite3 datastore
  [`spire-server.yaml:1`](../../components/ztwim-instance/spire-server.yaml#L1)

- OIDC Discovery Provider — jwtIssuer must match SpireServer exactly
  [`spire-oidc-discovery-provider.yaml:1`](../../components/ztwim-instance/spire-oidc-discovery-provider.yaml#L1)

- SpireAgent CR — defaults only, not used in experiment
  [`spire-agent.yaml:1`](../../components/ztwim-instance/spire-agent.yaml#L1)

- SpiffeCSIDriver CR — defaults only, not used in experiment
  [`spiffe-csi-driver.yaml:1`](../../components/ztwim-instance/spiffe-csi-driver.yaml#L1)

**Integration — ArgoCD app-of-apps wiring**

- Application entry at sync-wave 15 with manifest-generate-paths
  [`values.yaml:50`](../../clusters/etl7/values.yaml#L50)

**Documentation**

- Component readme with customization table and immutability warnings
  [`readme.md:1`](../../components/ztwim-instance/readme.md#L1)
