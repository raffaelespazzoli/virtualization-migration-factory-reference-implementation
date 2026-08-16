---
name: fleet-add-cluster
description: "Add a new managed cluster to the fleet. Use when user says 'add cluster', 'new cluster', or 'onboard cluster'."
---

## Overview

Walk the user through adding a new bare-metal managed cluster to the fleet GitOps repo — collecting cluster and node information, generating all required files, updating cross-references, and offering a PR. Act as a senior platform engineer facilitating provisioning. The user knows their hardware and network topology; the skill knows the repo's file patterns and wiring. The default flow clones an existing cluster's structure and asks only what differs.

**Args:** Optional `--name <cluster-name>`, `--like <existing-cluster>`.

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Load `{fleet-common}/references/fleet-repo-structure.md` for architectural context.
2. Run `python {fleet-common}/scripts/resolve_repo_structure.py --repo-root {project-root}` to get existing clusters, groups, and version pins. Verify `--name` does not collide.
3. Resume check: glob `{skill-root}/.memlog.md`. If found, read once to rebuild state and resume append-only; otherwise init with `uv run {project-root}/_bmad/scripts/memlog.py init --path {skill-root}/.memlog.md`.

## Collect Cluster Information

Present existing clusters as reference points and offer to clone from one. When a reference is chosen, load its `kustomization.yaml`, `values.yaml`, and hub overlay — the new cluster inherits group membership, component selection, network structure, and labels. Ask only what differs.

**Input modes:** The user can answer field-by-field or supply a document (CSV, inventory file, LLD, freeform text) from which many fields are extracted at once. When a document is provided, parse it for all recognizable fields, present the extraction for confirmation, then ask for what remains. Stop and ask when a required field is missing — never guess.

**Required fields:**

| Field | Default | Notes |
|-------|---------|-------|
| Cluster name | — | Unique; becomes namespace and directory name |
| Groups | `all`, `prod` | Group directories to compose |
| API VIP, Ingress VIP | — | Cluster virtual IPs |
| Cluster set | `default` | ACM ManagedClusterSet |
| Labels | `cloud: BareMetal`, `vendor: OpenShift`, `gitops: deploy` | ACM placement labels |
| OCP image set | — | ClusterImageSet name |
| SSH public key | — | For node access |
| Node count | 3 | How many times node collection runs |
| Pod CIDR | `10.128.0.0/14` | Must not overlap with other clusters |
| Service CIDR | `172.30.0.0/16` | Must not overlap with other clusters |
| Version pin | `main` | Git ref in cluster-versions.yaml |
| Masters schedulable | `true` | Compact cluster default |

## Collect Node Information

For each node, follow the `fleet-add-node` collection pattern: clone a node from the reference cluster as template and collect only what differs — hostname, BMC address, boot MAC, node IP, storage IP (if applicable). When no reference was chosen, collect all node fields interactively per `fleet-add-node`'s full flow.

Present a summary table of all nodes after collection for corrections before generation.

## Generate Files

Read existing cluster files as templates and substitute collected values. Generate:

**Cluster directory** (`clusters/<name>/`): `kustomization.yaml` (group composition + version-pin replacements), `values.yaml` (cluster-specific ArgoCD Applications).

**Hub overlay** (`clusters/hub/overlays/cluster-<name>/`): `kustomization.yaml` (node files, namespace, cluster-registration chart, commented-out bm-cluster-agent-install), `namespace.yaml`, per-node files via `python {fleet-common}/scripts/generate_node_files.py` (run `--help` for interface), `bmc-credentials-secret.yaml` and `pull-secret.yaml` (templates with placeholders), `readme.md` (manual secret creation instructions).

**Cross-reference updates:** add entry to `clusters/cluster-versions.yaml`, append managed cluster Application at sync-wave 25 to `clusters/hub/values.yaml`, add secret file paths to `.gitignore`.

Present all files for review. Apply only after the user confirms.

## Post-Generation

Show a summary of everything created and modified. Offer to create a branch and PR via `gh pr create`. Remind the user to manually create BMC credentials and pull secret in the cluster namespace before enabling.

## Gotchas

- BareMetalHost entries go into the hub overlay kustomization.yaml commented-out — active only during initial install or re-provisioning.
- Hub `values.yaml` must be patched (append among existing managed cluster entries), never overwritten.
- Secret templates use placeholder values and must be in `.gitignore`. Never commit real credentials.
- FQDN entries use `${PLATFORM_BASE_DOMAIN}` — resolved by the envsub CMP sidecar at deploy time, not by the skill.
- Pod and Service CIDRs must not overlap with existing clusters. Each cluster uses a unique pair carried in the bm-cluster-agent-install chart values.
- The `gitops-boostrap-policy` typo is intentional — do not fix it.
- BMC protocol format varies by vendor: `ipmi://` for IPMI, `redfish://` for iLO/iDRAC. Match the reference cluster's format.
- Kustomize replacements need `fieldPath: data.<cluster-name>` pointing at `cluster-versions.yaml`.
- Resources in the hub overlay kustomization are grouped by type: all BMH together (commented), all nmstate together, all fqdn together.
