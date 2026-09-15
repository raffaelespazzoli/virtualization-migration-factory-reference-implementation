# Story 1.4: Deploy vault-config-operator on etl7

---
baseline_commit: c17fdf40fe5bd9f4bbdf6d45062e21a78fe4233d
---

Status: done

## Story

As a platform engineer,
I want the vault-config-operator deployed on etl7,
so that Vault configuration (auth methods, policies, secret engines, roles) can be managed declaratively via Kubernetes CRDs.

## Acceptance Criteria

1. New component `components/vault-config-operator/` created
2. Deployment via OperatorPolicy (OLM) — vault-config-operator is available on OperatorHub as a community operator
3. Targets namespace `vault-config-operator`
4. Namespace created with:
   - `openshift.io/cluster-monitoring: "true"` label (Prometheus metrics scraping)
   - `argocd.argoproj.io/managed-by: openshift-gitops` label
   - `argocd.argoproj.io/sync-options: Delete=false` annotation (namespace protection)
5. OCP service-serving CA ConfigMap created for Vault TLS trust
6. Sync-wave set to `5` (operator tier) on the ArgoCD Application entry
7. VAULT_ADDR and VAULT_CACERT set via `subscription.config` in the OperatorPolicy
8. Application entry in `clusters/etl7/values.yaml`
9. Component has a `readme.md`

## Tasks / Subtasks

- [x] Task 1: Verify `components/vault-config-operator/namespace.yaml` (AC: #1, #3, #4) — already correct from prior implementation
- [x] Task 2: Verify `components/vault-config-operator/configmap-ocp-service-ca.yaml` (AC: #5) — already correct from prior implementation
- [x] Task 3: Create `components/vault-config-operator/operator-policy.yaml` (AC: #2, #7)
  - [x] 3.1: OperatorPolicy targeting `vault-config-operator` package from `community-operators` catalog, channel `alpha`
  - [x] 3.2: `subscription.config.env` with VAULT_ADDR and VAULT_CACERT
  - [x] 3.3: `subscription.config.volumes` and `subscription.config.volumeMounts` for OCP service-CA ConfigMap mount
- [x] Task 4: Update `components/vault-config-operator/kustomization.yaml` (AC: #1)
  - [x] 4.1: Add `operator-policy.yaml` to resources list
- [x] Task 5: Remove Helm overlay artifacts (AC: #2)
  - [x] 5.1: Delete entire `clusters/etl7/overlays/vault-config-operator/` directory (charts, values.yaml, kustomization.yaml)
- [x] Task 6: Update `clusters/etl7/values.yaml` application entry (AC: #6, #8)
  - [x] 6.1: Change source path from `clusters/etl7/overlays/vault-config-operator` to `components/vault-config-operator`
  - [x] 6.2: Remove `manifest-generate-paths` annotation (not needed without Helm)
  - [x] 6.3: Remove `ignoreDifferences` extraFields (OLM manages webhooks; ConfigMap injection is OpenShift-managed)
- [x] Task 7: Update `components/vault-config-operator/readme.md` (AC: #9)
  - [x] 7.1: Replace Helm chart references with OperatorPolicy/OLM deployment method

### Review Findings

- [x] [Review][Patch] Pin OperatorPolicy `startingCSV` and `spec.versions` to `vault-config-operator.v1.0.2` [`components/vault-config-operator/operator-policy.yaml:20`]
- [x] [Review][Patch] `ocp-service-ca` ConfigMap has no `metadata.namespace` [`components/vault-config-operator/configmap-ocp-service-ca.yaml:1`]
- [x] [Review][Patch] Application dropped `ignoreDifferences` for injected ConfigMap `/data` [`clusters/etl7/values.yaml:65`]
- [x] [Review][Patch] Volume mount does not require the `service-ca.crt` key, so the operator can start before CA injection [`components/vault-config-operator/operator-policy.yaml:32`]
- [x] [Review][Patch] Readme lists non-existent CRD `KVSecretEngineConfig` [`components/vault-config-operator/readme.md:19`]
- [x] [Review][Defer] etl7 `soteria` Application still sources `clusters/etl6/overlays/soteria-instance` [`clusters/etl7/values.yaml:116`] — deferred, pre-existing

## Dev Notes

### Course Correction: Helm → OLM/OperatorPolicy

This story was previously implemented using a Helm chart. Per the approved Sprint Change Proposal (2026-09-15), it is being reworked to use OLM via OperatorPolicy — the repo's canonical operator deployment pattern.

### vault-config-operator on OperatorHub

vault-config-operator IS available on OperatorHub as a community operator. The [official README](https://github.com/redhat-cop/vault-config-operator/blob/main/readme.md) recommends OLM deployment and documents the exact Subscription manifest with `config.env`, `config.volumes`, and `config.volumeMounts`.

| Field | Value |
|---|---|
| OLM package name | `vault-config-operator` |
| Channel | `alpha` |
| Source | `community-operators` |
| Source namespace | `openshift-marketplace` |
| Recommended namespace | `vault-config-operator` |
| Source | [redhat-cop/vault-config-operator](https://github.com/redhat-cop/vault-config-operator/) |
| Key CRDs | `AuthEngineMount`, `JWTOIDCAuthEngineConfig`, `JWTOIDCAuthEngineRole`, `SecretEngineMount`, `Policy`, `KVSecretEngineConfig`, `KubernetesAuthEngineConfig`, `KubernetesAuthEngineRole` |

### VCO Needs Vault Connection at the Operator Level

The vault-config-operator requires `VAULT_ADDR` and `VAULT_CACERT` environment variables set on the operator deployment. These are injected via the OLM Subscription `config` block in the OperatorPolicy.

**For etl7**, Vault runs on the same cluster (Story 1.3), so:
- `VAULT_ADDR = https://vault.vault.svc:8200` (cluster-internal service URL)
- `VAULT_CACERT = /vault-ca/service-ca.crt` (OCP service-serving CA, injected via ConfigMap annotation)

### OCP Service-Serving CA for Vault TLS

OpenShift's service-serving certificate infrastructure signs the Vault server's TLS cert. The VCO operator needs to trust this CA.

1. Create a ConfigMap with annotation `service.beta.openshift.io/inject-cabundle: "true"`
2. OpenShift automatically injects the service-CA bundle (key `service-ca.crt`) into this ConfigMap
3. Mount the ConfigMap in the operator pod via `subscription.config.volumes`/`volumeMounts`

### Codebase Patterns to Follow

**OperatorPolicy pattern** — follows the canonical `<name>-operator` pattern used by all OLM-deployed operators:

| Component | Pattern | Why Similar |
|---|---|---|
| `components/ztwim-operator/` | namespace.yaml + operator-policy.yaml | **Exact same pattern** |
| `components/openshift-gitops-operator/` | operator-policy.yaml with `subscription.config.env` | **Same config approach** — env vars via subscription config |
| `components/kubecost-operator/` | operator-policy.yaml with `subscription.config.resources` | Same subscription config mechanism |

Key conventions:
- **No overlay needed** — the OperatorPolicy contains all configuration (including VAULT_ADDR via subscription config), so the values.yaml entry points directly to `components/vault-config-operator` (like ztwim-operator)
- **No sync-wave annotations on component YAML** — wave `5` is set on the Application entry in `values.yaml` only

### Sync-Wave and Startup Ordering

- Wave `5` (operator tier) is correct for VCO
- VCO starts at wave 5, Vault starts at wave 15 (Story 1.3) — VCO will start before Vault, but this is fine:
  - The VCO operator pod starts and registers its webhooks/controllers
  - It will not attempt to reconcile any CRDs until they are created (Story 1.5, wave 25)
  - By wave 25, Vault (wave 15) will be initialized and accessible

### What NOT to Do

- **Do NOT use a Helm chart** — follow the repo's canonical OperatorPolicy deployment pattern
- **Do NOT use the Route URL for VAULT_ADDR** — use the in-cluster service URL `https://vault.vault.svc:8200`
- **Do NOT add sync-wave annotations to the component YAML files** — waves go on the ArgoCD Application only
- **Do NOT add this to `groups/prod/values.yaml`** — this is an etl7-only experiment
- **Do NOT modify `clusters/etl4/` or any other cluster** — etl7 only
- **Do NOT skip the `ocp-service-ca` ConfigMap** — without it, the operator cannot trust Vault's TLS certificate

### Cross-Story Dependencies and Impact

| Story | Relationship | Impact |
|---|---|---|
| **Story 1.3** (Vault on etl7) | Runtime dependency — VAULT_ADDR must resolve | VCO pod can start before Vault, but CRD reconciliation requires Vault to be running |
| **Story 1.5** (SPIRE↔Vault Trust) | Consumer — uses VCO's CRDs | All VCO CRDs in Story 1.5 require this operator to be running. Story 1.5 at wave 25 |
| **Story 1.1** (ZTWIM Operator) | No dependency | Parallel-deployable |
| **Story 1.2** (ZTWIM Instance) | No dependency | Parallel-deployable |

### References

- [vault-config-operator GitHub](https://github.com/redhat-cop/vault-config-operator/) — source repo, OLM subscription docs
- [Sprint Change Proposal](../../_bmad-output/planning-artifacts/sprint-change-proposal-2026-09-15.md) — approved course correction
- [Pattern reference: components/ztwim-operator/] — OperatorPolicy pattern
- [Pattern reference: components/openshift-gitops-operator/] — subscription.config.env pattern

## Dev Agent Record

### Agent Model Used

Claude Opus 4.6 (Cursor)

### Debug Log References

Course correction from Helm to OLM/OperatorPolicy per approved Sprint Change Proposal (2026-09-15).

### Completion Notes List

- Course correction: Helm chart deployment replaced with OLM/OperatorPolicy per approved Sprint Change Proposal (2026-09-15)
- Created `operator-policy.yaml` following the `ztwim-operator` OperatorPolicy pattern with `subscription.config` for env, volumes, volumeMounts — matches the VCO README's documented OLM deployment approach
- OLM package `vault-config-operator` on channel `alpha` from `community-operators` catalog
- VAULT_ADDR (`https://vault.vault.svc:8200`) and VAULT_CACERT (`/vault-ca/service-ca.crt`) injected via subscription config — same mechanism as `openshift-gitops-operator`'s env injection
- OCP service-CA ConfigMap mounted via `subscription.config.volumes`/`volumeMounts`
- Deleted entire overlay directory (`clusters/etl7/overlays/vault-config-operator/`) — no cluster-specific overlay needed since all config is in the OperatorPolicy
- Simplified `clusters/etl7/values.yaml` entry to match the `ztwim-operator` pattern (no `manifest-generate-paths`, no `ignoreDifferences`, path points directly to base component)
- Preserved unchanged files: `namespace.yaml`, `configmap-ocp-service-ca.yaml` (both still correct and needed)
- Updated `readme.md` to document OperatorPolicy deployment method

### File List

- `components/vault-config-operator/operator-policy.yaml` — NEW (OperatorPolicy for OLM deployment)
- `components/vault-config-operator/kustomization.yaml` — MODIFIED (added operator-policy.yaml to resources)
- `components/vault-config-operator/readme.md` — MODIFIED (Helm → OLM deployment docs)
- `components/vault-config-operator/namespace.yaml` — UNCHANGED
- `components/vault-config-operator/configmap-ocp-service-ca.yaml` — UNCHANGED
- `clusters/etl7/overlays/vault-config-operator/kustomization.yaml` — DELETED
- `clusters/etl7/overlays/vault-config-operator/values.yaml` — DELETED
- `clusters/etl7/values.yaml` — MODIFIED (simplified vault-config-operator entry)

### Change Log

- 2026-09-15: Course correction — replaced Helm chart deployment with OLM/OperatorPolicy per approved Sprint Change Proposal. Deleted overlay, created operator-policy.yaml, simplified values.yaml entry.
