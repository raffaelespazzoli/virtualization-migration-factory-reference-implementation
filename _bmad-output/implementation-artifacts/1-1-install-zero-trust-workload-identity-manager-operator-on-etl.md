---
baseline_commit: c17fdf40fe5bd9f4bbdf6d45062e21a78fe4233d
---

# Story 1.1: Install Zero Trust Workload Identity Manager Operator on etl7

Status: done

## Story

As a platform engineer,
I want the ZTWIM operator installed on etl7 via OperatorPolicy,
so that I can deploy SPIRE server/agent and SPIFFE infrastructure.

## Acceptance Criteria

1. New component `components/ztwim-operator/` created following the repo `<name>-operator` naming convention
2. Contains `namespace.yaml` creating namespace `zero-trust-workload-identity-manager` with:
   - `argocd.argoproj.io/sync-options: Delete=false` annotation (protects namespace from ArgoCD prune)
   - `argocd.argoproj.io/managed-by: openshift-gitops` label
   - `openshift.io/cluster-monitoring: "true"` label
3. Contains `operator-policy.yaml` with OperatorPolicy targeting the `zero-trust-workload-identity-manager` package in channel `stable-v1` from `redhat-operators`
4. Contains `kustomization.yaml` referencing the above resources
5. Sync-wave annotation set to `5` (operator tier) — on the ArgoCD Application in `clusters/etl7/values.yaml`, NOT on the component manifests
6. Component has a `readme.md` explaining what it deploys
7. Application entry added to `clusters/etl7/values.yaml` (etl7 only — **not** `groups/prod`) at wave 5

## Tasks / Subtasks

- [x] Task 1: Create `components/ztwim-operator/` directory (AC: #1)
- [x] Task 2: Create `namespace.yaml` (AC: #2)
  - [x] 2.1: Namespace name `zero-trust-workload-identity-manager`
  - [x] 2.2: Annotation: `argocd.argoproj.io/sync-options: Delete=false`
  - [x] 2.3: Labels: `openshift.io/cluster-monitoring: "true"` and `argocd.argoproj.io/managed-by: openshift-gitops`
- [x] Task 3: Create `operator-policy.yaml` (AC: #3)
  - [x] 3.1: OperatorPolicy in namespace `open-cluster-management-policies`
  - [x] 3.2: Subscription targeting package `zero-trust-workload-identity-manager`, channel `stable-v1`, source `redhat-operators`
  - [x] 3.3: Determine the exact `startingCSV` and `versions` values (see dev notes)
- [x] Task 4: Create `kustomization.yaml` (AC: #4)
  - [x] 4.1: Two resources: `namespace.yaml` and `operator-policy.yaml`
- [x] Task 5: Create `readme.md` (AC: #6)
- [x] Task 6: Add application entry to `clusters/etl7/values.yaml` (AC: #5, #7)
  - [x] 6.1: Entry under a new `# Zero Trust` section comment
  - [x] 6.2: Sync-wave `'5'`, source path `components/ztwim-operator`

### Review Findings

- [x] [Review][Patch] Set OperatorPolicy `subscription.name` to `openshift-zero-trust-workload-identity-manager` (catalog package) [`components/ztwim-operator/operator-policy.yaml:22`] — user chose catalog name over AC3 short name. Readme Operator Details updated.
- [x] [Review][Patch] Pin `startingCSV` / `versions` to etl7 live PackageManifest CSV `zero-trust-workload-identity-manager.v1.1.1` [`components/ztwim-operator/operator-policy.yaml:26`] — confirmed via `oc get packagemanifests` on `stable-v1`.

## Dev Notes

### ⚠️ CRITICAL: Epic Discrepancies Corrected by Research

The original epic contains two factual errors corrected by the Red Hat OCP 4.22 documentation:

1. **Namespace:** Epic says `openshift-zero-trust-workload-identity-manager`. The correct default namespace per [Red Hat docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) is **`zero-trust-workload-identity-manager`**. Use this.
2. **Channel:** Epic says `stable`. The correct channel is **`stable-v1`**. All Red Hat docs and official subscription examples use `stable-v1`.

Source: [OCP 4.22 ZTWIM §12.4 — Installing](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager)

### Operator Details (verified Sep 2026)

| Field | Value |
|---|---|
| OLM package name | `zero-trust-workload-identity-manager` |
| Channel | `stable-v1` |
| Source catalog | `redhat-operators` |
| Default namespace | `zero-trust-workload-identity-manager` |
| Latest version (OCP 4.22) | 1.1.0 (issued Jun 30, 2026) |
| SPIRE Server version | 1.14.7 |
| SPIRE Agent version | 1.14.7 |

### Determining the `startingCSV` and `versions`

The OperatorPolicy requires `startingCSV` and `versions` fields. To find the exact CSV name, run on the etl7 cluster:

```bash
oc get packagemanifests -n openshift-marketplace zero-trust-workload-identity-manager -o jsonpath='{.status.channels[?(@.name=="stable-v1")].currentCSV}'
```

The CSV name will likely follow the pattern `zero-trust-workload-identity-manager.v1.1.0` — use whatever the above command returns. Add it to both `startingCSV` and the `versions` array.

### Exact File Templates

#### `components/ztwim-operator/namespace.yaml`

Copy this verbatim:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: zero-trust-workload-identity-manager
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    openshift.io/cluster-monitoring: "true"
    argocd.argoproj.io/managed-by: openshift-gitops
```

#### `components/ztwim-operator/operator-policy.yaml`

Copy this structure, replacing `<CSV_NAME>` with the value from the `oc get packagemanifests` command above:

```yaml
apiVersion: policy.open-cluster-management.io/v1beta1
kind: OperatorPolicy
metadata:
  name: zero-trust-workload-identity-manager
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
    channel: stable-v1
    name: zero-trust-workload-identity-manager
    namespace: zero-trust-workload-identity-manager
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    startingCSV: <CSV_NAME>
  versions:
    - <CSV_NAME>
```

#### `components/ztwim-operator/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - ./operator-policy.yaml
```

#### `clusters/etl7/values.yaml` — add this block

Insert after the existing `# Storage` section, before `# percona demo`:

```yaml
# Zero Trust

  ztwim-operator:
    annotations:
      argocd.argoproj.io/sync-wave: '5'
    source:
      path: components/ztwim-operator
```

#### `components/ztwim-operator/readme.md`

Create a brief readme explaining:
- This component deploys the Zero Trust Workload Identity Manager Operator via ACM OperatorPolicy
- The operator manages SPIRE server, agent, OIDC discovery provider, and SPIFFE CSI driver lifecycle
- Channel: `stable-v1`, source: `redhat-operators`
- Part of Epic 1: Zero-Trust Secret Delivery to VM Workloads via SPIFFE/Vault on etl7
- Depends on: nothing (first component in the chain)
- Next in chain: `ztwim-instance` (Story 1.2) deploys the SPIRE operands

### Codebase Patterns to Follow

The OperatorPolicy pattern is used by 32 of 36 operator components. Use `scylladb-operator` or `openshift-connectivity-link-operator` as your reference — they are the cleanest examples. Key conventions:

- **OperatorPolicy always deploys to `open-cluster-management-policies` namespace** — this is the ACM policy namespace, not where the operator runs
- **`subscription.namespace`** is where the operator actually installs — `zero-trust-workload-identity-manager`
- **No sync-wave annotations on component YAML** — wave `5` is set on the Application entry in `values.yaml`
- **No `operatorGroup` field needed** — the ZTWIM operator is cluster-scoped (manages cluster-wide SPIRE infra), so OLM will create a default OperatorGroup in the target namespace
- **Path style in kustomization.yaml**: either `./operator-policy.yaml` or `operator-policy.yaml` are acceptable — the repo uses both

### Files Modified by This Story

| File | Action | Notes |
|---|---|---|
| `components/ztwim-operator/namespace.yaml` | NEW | Namespace resource |
| `components/ztwim-operator/operator-policy.yaml` | NEW | ACM OperatorPolicy |
| `components/ztwim-operator/kustomization.yaml` | NEW | Kustomize base |
| `components/ztwim-operator/readme.md` | NEW | Component docs |
| `clusters/etl7/values.yaml` | UPDATE | Add `ztwim-operator` app entry |

### What NOT to Do

- **Do NOT create an OperatorGroup resource** — OLM handles this automatically for the ZTWIM operator; the OperatorPolicy's `operatorGroup` field is optional and not needed here
- **Do NOT add sync-wave annotations to the namespace.yaml or operator-policy.yaml** — waves go on the ArgoCD Application only
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment, not a fleet-wide deployment
- **Do NOT use channel `stable`** — the correct channel is `stable-v1`
- **Do NOT use namespace `openshift-zero-trust-workload-identity-manager`** — the correct namespace is `zero-trust-workload-identity-manager` per Red Hat docs
- **Do NOT modify `clusters/etl4/` or any other cluster** — this story is etl7-only
- **Do NOT create a Subscription resource** — the OperatorPolicy handles the subscription lifecycle; legacy Subscription files are migration artifacts

### Project Structure Notes

- Component lives at `components/ztwim-operator/` following the `<name>-operator` naming convention
- This is a reusable base component — no cluster-specific overlay needed since no cluster-specific configuration is required for the operator install
- The `ztwim-instance` component (Story 1.2) will be the next sibling at `components/ztwim-instance/` with a cluster overlay at `clusters/etl7/overlays/ztwim-instance/`
- The naming prefix `ztwim-` groups related components: `ztwim-operator` (wave 5) → `ztwim-instance` (wave 15)

### References

- [OCP 4.22 ZTWIM docs — Installing the operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) §12.4
- [ZTWIM 1.1.0 release notes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/security_and_compliance/zero-trust-workload-identity-manager) §12.3.1
- [ZTWIM 1.1 GA blog](https://www.redhat.com/en/blog/zero-trust-workload-identity-manager-11-generally-available-red-hat-openshift)
- [Source: epic-zero-trust-secret-delivery-etl7.md — Story 1.1]
- [Pattern reference: components/scylladb-operator/] — cleanest OperatorPolicy example in this repo
- [Pattern reference: components/openshift-connectivity-link-operator/] — clean Red Hat operator example

## Dev Agent Record

### Agent Model Used

Claude Opus 4.6

### Debug Log References

- No cluster access available; used `startingCSV: zero-trust-workload-identity-manager.v1.1.0` based on verified dev notes (OCP 4.22, version 1.1.0 issued Jun 30, 2026). Confirm on etl7 with: `oc get packagemanifests -n openshift-marketplace zero-trust-workload-identity-manager -o jsonpath='{.status.channels[?(@.name=="stable-v1")].currentCSV}'`
- All YAML validated programmatically (python3 yaml.safe_load + assertion checks)
- Followed scylladb-operator pattern as reference for OperatorPolicy structure

### Completion Notes List

- Created `components/ztwim-operator/` with all 4 files (namespace, operator-policy, kustomization, readme)
- namespace.yaml: Namespace `zero-trust-workload-identity-manager` with `Delete=false` sync-option, `cluster-monitoring` and `managed-by` labels
- operator-policy.yaml: OperatorPolicy in `open-cluster-management-policies` targeting `zero-trust-workload-identity-manager` package, `stable-v1` channel, `redhat-operators` source, CSV `zero-trust-workload-identity-manager.v1.1.0`
- kustomization.yaml: References both `namespace.yaml` and `./operator-policy.yaml`
- readme.md: Documents operator purpose, details, deployment method, and chain context
- clusters/etl7/values.yaml: Added `ztwim-operator` entry under new `# Zero Trust` section at sync-wave `'5'` with source path `components/ztwim-operator`
- No sync-wave annotations on component manifests (wave set on Application entry only)
- No OperatorGroup created (OLM handles this automatically)
- etl7-only deployment — no changes to groups/prod or other clusters

### File List

- `components/ztwim-operator/namespace.yaml` — NEW
- `components/ztwim-operator/operator-policy.yaml` — NEW
- `components/ztwim-operator/kustomization.yaml` — NEW
- `components/ztwim-operator/readme.md` — NEW
- `clusters/etl7/values.yaml` — MODIFIED (added ztwim-operator application entry)

### Change Log

- 2026-09-15: Story 1.1 implemented — created ztwim-operator component and added to etl7 cluster values
- 2026-09-15: Code review — OLM package `openshift-zero-trust-workload-identity-manager`, CSV pin `zero-trust-workload-identity-manager.v1.1.1` from etl7 PackageManifest
