# Sprint Change Proposal: Story 1-4 — Helm → OLM/OperatorPolicy Migration

**Date:** 2026-09-15
**Triggered by:** Story 1-4 (Deploy vault-config-operator on etl7)
**Change scope:** Minor — Direct implementation by Developer agent
**Status:** ✅ Approved (2026-09-15)

---

## Section 1: Issue Summary

Story 1-4 was implemented using a **Helm chart** deployment for vault-config-operator, but the correct approach is **OLM via OperatorPolicy**.

**Root cause:** The dev agent's research incorrectly concluded that vault-config-operator was not available on OperatorHub (citing GitHub issue #267). This overrode the epic's guidance, which correctly stated: *"Deployment via OperatorPolicy (if available on OperatorHub) or Helm chart"* and *"Available on OperatorHub as a community operator."*

**Impact of the incorrect approach:**
- 70+ vendored Helm chart files committed under `clusters/etl7/overlays/vault-config-operator/charts/`
- Helm-specific overlay with `helmCharts` directive and `values.yaml`
- Complex `ignoreDifferences` in `clusters/etl7/values.yaml` for Helm-managed webhooks
- Inconsistency with the repo's canonical operator deployment pattern (OperatorPolicy via ACM)

## Section 2: Impact Analysis

### Epic Impact
- **No epic text changes needed** — the epic already prefers OperatorPolicy and the architecture diagram is deployment-method agnostic
- Epic story list, dependency graph, and success criteria are unaffected

### Story Impact
- **Story 1-4:** Major rewrite of implementation artifact (description, AC, dev notes, tasks)
- **Story 1-5:** No impact — consumes VCO CRDs (`AuthEngineMount`, `JWTOIDCAuthEngineConfig`, etc.) regardless of how the operator was deployed
- **Other stories:** No impact

### Technical Impact
- **Delete:** ~70 files (vendored Helm chart + templates + CRDs under overlay)
- **Delete:** Overlay `values.yaml` (Helm values)
- **Create:** `operator-policy.yaml` in base component
- **Modify:** Base `kustomization.yaml`, `readme.md`, overlay `kustomization.yaml`, `clusters/etl7/values.yaml`

## Section 3: Recommended Approach

**Direct Adjustment** — modify Story 1-4 and refactor code in place.

**Rationale:**
- The OperatorPolicy pattern is well-established in the repo (31 existing operator-policy.yaml files)
- The `subscription.config` field supports `env`, `volumes`, `volumeMounts` — confirmed by existing usage in `openshift-gitops-operator` and `kubecost-operator`
- VAULT_ADDR and VAULT_CACERT can be set via `subscription.config.env` with volume mounts for the OCP service-CA ConfigMap
- The base component + thin overlay pattern matches the existing repo conventions
- Effort: **Medium** (mostly deletion + new OperatorPolicy file)
- Risk: **Low** (well-established pattern, no new architectural decisions)
- Timeline impact: **None** (Story 1-5 is next and is unaffected)

## Section 4: Detailed Change Proposals

### 4.1 Story 1-4 Implementation Artifact Changes

#### Story Description
No change (the story statement remains the same).

#### Acceptance Criteria

```
OLD:
2. Deployment via Helm chart (vault-config-operator is NOT on OperatorHub — see dev notes)

NEW:
2. Deployment via OperatorPolicy (OLM) — vault-config-operator IS available on OperatorHub as a community operator
```

```
OLD:
7. Overlay at `clusters/etl7/overlays/vault-config-operator/` with cluster-specific Vault connection config

NEW:
7. Overlay at `clusters/etl7/overlays/vault-config-operator/` with OCP service-CA ConfigMap (Vault TLS trust)
   NOTE: VAULT_ADDR and VAULT_CACERT are set via subscription config in the OperatorPolicy
```

#### Dev Notes — Replace "CRITICAL: NOT on OperatorHub" Block

```
OLD:
### ⚠️ CRITICAL: vault-config-operator is NOT on OperatorHub

The epic mentions "Deployment via OperatorPolicy (if available on OperatorHub) or Helm chart." Research confirms:
- **vault-config-operator is NOT listed on OperatorHub** — [open issue #267](...) confirms it was removed
- **Deploy via Helm chart only**
- **Do NOT create an OperatorPolicy**

NEW:
### vault-config-operator on OperatorHub

vault-config-operator IS available on OperatorHub as a community operator. Deploy via OperatorPolicy following the standard `<name>-operator` pattern.

- OLM package name: `vault-config-operator` (verify exact name in community-operators catalog)
- Source: `community-operators`
- Channel: verify current stable channel
- VAULT_ADDR and VAULT_CACERT: set via `subscription.config.env` in the OperatorPolicy
- Volume mounts for OCP service-CA: set via `subscription.config.volumes` / `subscription.config.volumeMounts`
- Pattern reference: `openshift-gitops-operator` uses the same subscription config approach for env vars
```

#### Dev Notes — Replace "What NOT to Do" Section

```
OLD:
- **Do NOT create an OperatorPolicy** — vault-config-operator is not on OperatorHub; this is a Helm-only deployment

NEW:
- **DO create an OperatorPolicy** — vault-config-operator is available on OperatorHub as a community operator
- **Do NOT use a Helm chart** — follow the repo's canonical OperatorPolicy deployment pattern
```

#### Dev Notes — Replace "Codebase Patterns to Follow" Section

```
OLD:
**Helm-based component pattern** — follows vault/, reflector-operator, kyverno-operator patterns

NEW:
**OperatorPolicy pattern** — follows the canonical `<name>-operator` pattern used by all OLM-deployed operators:

| Component | Pattern | Why Similar |
|---|---|---|
| `components/ztwim-operator/` | namespace.yaml + operator-policy.yaml | **Exact same pattern** — OperatorPolicy with subscription config |
| `components/openshift-gitops-operator/` | operator-policy.yaml with subscription.config.env | **Same config approach** — env vars via subscription config |

The overlay (`clusters/etl7/overlays/vault-config-operator/`) still exists but only contains the OCP service-CA ConfigMap and reference to the base component. No Helm chart, no Helm values.
```

### 4.2 Code Changes

#### DELETE: Entire vendored Helm chart directory
```
clusters/etl7/overlays/vault-config-operator/charts/  (~70 files)
```
**Rationale:** OLM manages the operator installation, CRDs, and RBAC. No vendored chart needed.

#### DELETE: Helm values file
```
clusters/etl7/overlays/vault-config-operator/values.yaml
```
**Rationale:** Helm values replaced by subscription config in OperatorPolicy.

#### NEW: `components/vault-config-operator/operator-policy.yaml`

```yaml
apiVersion: policy.open-cluster-management.io/v1beta1
kind: OperatorPolicy
metadata:
  name: vault-config-operator
  namespace: open-cluster-management-policies
spec:
  upgradeApproval: Automatic
  complianceConfig:
    catalogSourceUnhealthy: Compliant
    deploymentsUnavailable: NonCompliant
    upgradesAvailable: Compliant
  complianceType: musthave
  remediationAction: enforce
  removalBehavior:
    clusterServiceVersions: Delete
    customResourceDefinitions: Keep
    operatorGroups: DeleteIfUnused
    subscriptions: Delete
  severity: medium
  subscription:
    channel: <VERIFY-CHANNEL>
    name: vault-config-operator
    namespace: vault-config-operator
    source: community-operators
    sourceNamespace: openshift-marketplace
    startingCSV: <VERIFY-STARTING-CSV>
    config:
      env:
        - name: VAULT_ADDR
          value: https://vault.vault.svc:8200
        - name: VAULT_CACERT
          value: /vault-ca/service-ca.crt
      volumes:
        - name: vault-ca
          configMap:
            name: ocp-service-ca
      volumeMounts:
        - mountPath: /vault-ca
          name: vault-ca
```

**Dev agent must verify:**
- Exact OLM package name (`vault-config-operator` or variant)
- Channel name (e.g., `alpha`, `stable`, etc.)
- Starting CSV version
- Whether `subscription.config.volumes` / `subscription.config.volumeMounts` are supported by OperatorPolicy (they ARE supported in OLM Subscription spec; verify ACM OperatorPolicy passes them through)

#### MODIFY: `components/vault-config-operator/kustomization.yaml`

```
OLD:
resources:
  - namespace.yaml
  - configmap-ocp-service-ca.yaml

NEW:
resources:
  - namespace.yaml
  - configmap-ocp-service-ca.yaml
  - operator-policy.yaml
```

#### MODIFY: `clusters/etl7/overlays/vault-config-operator/kustomization.yaml`

```
OLD:
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: vault-config-operator

resources:
  - ../../../../components/vault-config-operator

helmCharts:
  - name: vault-config-operator
    releaseName: vault-config-operator
    namespace: vault-config-operator
    repo: https://redhat-cop.github.io/vault-config-operator
    version: v0.8.50
    includeCRDs: true
    valuesFile: values.yaml

NEW:
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../../../components/vault-config-operator
```

**Note:** The overlay becomes a simple passthrough. If no cluster-specific patches are needed, the values.yaml entry could point directly to `components/vault-config-operator` (like ztwim-operator) and the overlay could be deleted entirely. The dev agent should decide based on whether future cluster-specific configuration is anticipated.

#### MODIFY: `clusters/etl7/values.yaml` — vault-config-operator entry

```
OLD:
  vault-config-operator:
    annotations:
      argocd.argoproj.io/sync-wave: '5'
      argocd.argoproj.io/manifest-generate-paths: ".;/components/vault-config-operator"
    source:
      path: clusters/etl7/overlays/vault-config-operator
    extraFields: |
      ignoreDifferences:
        - group: ''
          kind: ConfigMap
          name: ocp-service-ca
          jsonPointers:
            - /data
        - group: admissionregistration.k8s.io
          kind: MutatingWebhookConfiguration
          jsonPointers:
            - /webhooks/0/clientConfig/caBundle
            - /webhooks/1/clientConfig/caBundle
            - /webhooks/2/clientConfig/caBundle
        - group: admissionregistration.k8s.io
          kind: ValidatingWebhookConfiguration
          jsonPointers:
            - /webhooks/0/clientConfig/caBundle
            - /webhooks/1/clientConfig/caBundle
            - /webhooks/2/clientConfig/caBundle

NEW:
  vault-config-operator:
    annotations:
      argocd.argoproj.io/sync-wave: '5'
    source:
      path: components/vault-config-operator
```

**Rationale:**
- Path changes from overlay to base component (like ztwim-operator)
- `manifest-generate-paths` dropped — not needed without Helm
- `ignoreDifferences` dropped — OLM manages webhooks and the ocp-service-ca ConfigMap data injection is handled by OpenShift (ArgoCD should not track it for OperatorPolicy-managed resources)
- **Dev agent should verify:** if ArgoCD still shows drift on the ConfigMap after OLM deployment, add back just the ConfigMap ignoreDifferences

#### MODIFY: `components/vault-config-operator/readme.md`

```
OLD:
Deploys the vault-config-operator via Helm chart. ... not available on OperatorHub ...

NEW:
Deploys the vault-config-operator via OperatorPolicy (OLM). This operator enables declarative
Vault configuration through Kubernetes CRDs.

## Deployment Method

Deployed via OperatorPolicy from the `community-operators` catalog on OperatorHub. Follows the
standard `<name>-operator` pattern used by all OLM-deployed operators in this repo.

VAULT_ADDR and VAULT_CACERT are injected into the operator pod via `subscription.config` in the
OperatorPolicy.
```

### 4.3 Downstream Story Impact

**Story 1-5 (SPIRE-Vault OIDC Trust):** No changes needed. Story 1-5 creates VCO CRDs (AuthEngineMount, JWTOIDCAuthEngineConfig, etc.) which are consumed by the operator regardless of deployment method.

### 4.4 Sprint Status Update

No status changes needed — Story 1-4 remains `done` after the refactor is applied. (It's a correction, not a regression to `in-progress`.)

## Section 5: Implementation Handoff

**Change scope:** Minor — Direct implementation by Developer agent

**Handoff:**
1. Developer agent updates Story 1-4 implementation artifact per Section 4.1
2. Developer agent refactors code per Section 4.2:
   - Delete vendored Helm chart (~70 files)
   - Delete Helm values.yaml
   - Create operator-policy.yaml (verify OLM package details first)
   - Modify kustomization.yaml, values.yaml, readme.md
3. Developer agent runs code review on the refactored component

**Open questions for dev agent:**
- Verify exact OLM package name, channel, and starting CSV for vault-config-operator
- Verify that OperatorPolicy passes `subscription.config.volumes` / `subscription.config.volumeMounts` through to the OLM Subscription (env is confirmed to work)
- Decide whether to keep the thin overlay or point values.yaml directly to the base component
- If `subscription.config.volumes`/`volumeMounts` are NOT supported by OperatorPolicy, fall back to a Kustomize patch on the operator Deployment in the overlay

**Success criteria:**
- vault-config-operator deployed via OperatorPolicy on etl7
- Operator pod has VAULT_ADDR and VAULT_CACERT environment variables set
- OCP service-CA ConfigMap mounted in the operator pod
- VCO CRDs are available (installed by OLM)
- Story 1-5 can proceed unchanged
