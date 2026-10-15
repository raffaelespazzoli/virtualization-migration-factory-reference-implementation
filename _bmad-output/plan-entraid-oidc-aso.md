---
title: 'Entra ID OIDC via ASO — operator and application registration component'
type: 'feature'
ticket: ''
created: '2026-10-13'
status: 'built'
baseline_revision: '59401fa2b742d92850f12c18c490faa1e2b07892'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** When a new ACM-managed cluster is provisioned, its OpenShift OAuth callback URI must be registered on the Entra ID app registration. Today there is no automation for this; the redirect URI list must be updated manually in the Azure portal.

**Approach:** Deploy Azure Service Operator (ASO) via OperatorPolicy and create an Entra `Application` resource that declaratively manages the redirect URI list. The component is split into `entraid-operator` (ASO deployment) and `entraid-configuration` (credential setup, CRD filtering, and the Entra Application resource with example redirect URIs). A README documents the required Azure-side configuration.

## Boundaries & Constraints

**Always:**
- Follow the repository's OperatorPolicy pattern for the operator component.
- Follow the `<name>-operator` / `<name>-configuration` naming convention.
- Use sync-wave 5 for the operator, sync-wave 15 for the configuration.
- Use the `azure.com/reconcile-policy: detach-on-delete` annotation on the Application resource so deleting the K8s object does not delete the Entra app registration.
- The credential Secret is a placeholder with clear documentation — actual secrets are supplied externally (sealed-secret, vault, or manual). Never commit real credentials.
- The redirect URI list in the example manifest uses `${CLUSTER_NAME}` and `${CLUSTER_BASE_DOMAIN}` envsubst variables where possible, plus additional example entries showing the pattern.
- The ASO namespace must carry the `argocd.argoproj.io/managed-by: openshift-gitops` label.

**Never:**
- Do not commit real Azure credentials or secrets.
- Do not modify existing components, groups, or cluster overlays — the user will wire these in.
- Do not parameterize the redirect URI list dynamically from ACM — the user will handle that.
- Do not create test files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fresh deploy | No ASO on cluster | OperatorPolicy installs ASO; CRD filter enables Entra resources; Application CR creates/adopts Entra app with listed redirect URIs | ASO reports status on the Application resource |
| Add cluster | New cluster provisioned | User adds a new redirect URI entry to the Application resource and commits | ASO patches the Entra app registration additively |
| Delete K8s resource | Application CR removed from cluster | `detach-on-delete` annotation prevents deletion of the Entra app in Azure | No Azure-side effect |
| Existing app adoption | Entra app already exists in Azure | `spec.azureName` references the existing app's display name; ASO adopts and reconciles redirect URIs | If credentials lack ownership, ASO reports auth error on the resource status |

</frozen-after-approval>

## Code Map

- `components/cert-manager-operator/` — reference for OperatorPolicy pattern (namespace + operator-policy + kustomization)
- `components/cert-manager-configuration/` — reference for configuration component pattern (kustomization + resources + readme)
- `components/trident-operator/operator-policy.yaml` — another OperatorPolicy reference showing `community-operators` source catalog is not used here but pattern is the same
- `groups/all/values.yaml` — where the new components would be wired in (user's responsibility, not in scope)
- `clusters/etl7/overlays/openshift-config/oauth.yaml` — existing OAuth config using HTPasswd; shows the cluster-level overlay pattern for identity providers

## Tasks & Acceptance

**Execution:**
- [ ] `components/entraid-operator/namespace.yaml` — Create ASO namespace (`azureserviceoperator-system`) with required labels
- [ ] `components/entraid-operator/operator-policy.yaml` — Create OperatorPolicy for `azure-service-operator` from `community-operators` catalog
- [ ] `components/entraid-operator/kustomization.yaml` — Wire namespace and operator-policy resources
- [ ] `components/entraid-configuration/aso-credential-secret.yaml` — Placeholder Secret for ASO Azure credentials (`aso-controller-settings`)
- [ ] `components/entraid-configuration/aso-crd-filter.yaml` — ConfigMap to restrict ASO to only install Entra CRDs
- [ ] `components/entraid-configuration/application.yaml` — Entra Application resource with example redirect URI list including envsubst pattern
- [ ] `components/entraid-configuration/kustomization.yaml` — Wire all configuration resources
- [ ] `components/entraid-configuration/readme.md` — Document Azure-side prerequisites: service principal creation, API permissions, app ownership, and credential provisioning

**Acceptance Criteria:**
- Given a clean checkout, when `kustomize build components/entraid-operator` is run, then it produces valid YAML containing a Namespace and an OperatorPolicy
- Given a clean checkout, when `kustomize build components/entraid-configuration` is run, then it produces valid YAML containing a Secret, a ConfigMap, and an Entra Application resource
- Given the readme, when an operator follows it, then they know which Azure permissions to grant, how to make the automation identity an owner, and how to supply the credential secret

## Implementation Notes

- CRD filter ConfigMap moved to `entraid-operator/` during review — it must be present before ASO controller starts.
- OperatorPolicy pinned to v2.21.0 (ASO's Entra resource introduction); verify against live OperatorHub catalog before deployment.
- Placeholder Secret kept in git for kustomize build validation; README warns Manual method is overwritten by ArgoCD sync.


## Plan Change Log



## Review Triage Log

Quick lens — 3 findings (0 high / 3 medium / 0 low / 0 false / 0 maybe-false):

| Finding | Verdict | Route | Evidence |
|---------|---------|-------|----------|
| Secret overwrite on sync — ArgoCD applies empty placeholder values over manually created credentials | medium | patch | `Delete=false` only gates prune, not apply. Added warning to README Manual method row noting ArgoCD will overwrite; recommend SealedSecret/ExternalSecret for production. |
| CRD filter at wave 15 — ASO starts at wave 5 without the filter, installs all CRDs | medium | patch | Moved `aso-crd-filter.yaml` from `entraid-configuration` to `entraid-operator` so it deploys alongside the OperatorPolicy at wave 5. Updated both kustomizations and README. |
| Missing startingCSV/versions — only OperatorPolicy without version pinning | medium | patch | Added `startingCSV: azure-service-operator.v2.21.0` and `versions` list with a comment to verify against OperatorHub catalog. Matches repo-wide convention. |

## Verification

**Commands:**
- `kustomize build components/entraid-operator` -- expected: valid YAML with Namespace and OperatorPolicy resources
- `kustomize build components/entraid-configuration` -- expected: valid YAML with Secret, ConfigMap, and Application resources

**Manual checks (if no CLI):**
- Inspect `components/entraid-configuration/readme.md` for completeness: covers service principal setup, API permissions (`Application.ReadWrite.OwnedBy`), app ownership assignment, credential secret provisioning, and the `detach-on-delete` annotation purpose
