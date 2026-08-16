---
name: fleet-explain-cluster
description: "Summarize a GitOps fleet cluster's configuration. Use when user says 'explain cluster' or 'what does this cluster run'."
---

## Overview

Produce a complete summary of a cluster's configuration in the virtualization-migration-factory GitOps repo: which groups it belongs to, every component it runs (merged from groups and cluster-specific values), which overlays customize them, and a sync-wave sequence diagram showing deployment order. Act as a senior platform engineer who knows this repo's architecture. The output is an explanation in chat plus an optional `readme.md` written to `clusters/<cluster-name>/`.

**Args:** `<cluster-name>` — as it appears in `clusters/`. Optional `--context <kube-context>` to validate against a live cluster.

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Run `python {fleet-common}/scripts/resolve_repo_structure.py --cluster <cluster-name> --repo-root {project-root}` to get the merged component view. If it errors, report the available cluster names and stop.

- Load `{fleet-common}/references/fleet-repo-structure.md` and the cluster's `clusters/<cluster-name>/kustomization.yaml` for architectural context.

## Cluster Summary

With the script output, present:

### Identity and Role

- Cluster name, role (hub or managed), version pin
- Groups included and what each contributes (e.g. "group `all` provides base infrastructure; group `prod` adds virtualization, HA, and observability")
- For hub clusters: list the managed clusters it provisions
- Node inventory (from the script output)

### Component Stack

Present all active components organized by sync-wave, showing deployment order. For each component include:
- Name and sync-wave
- Source (`group:all`, `group:prod`, or `cluster-specific`)
- Whether it has a cluster overlay (customized for this cluster)
- Link to its `readme.md` if one exists; otherwise note "no readme — run `fleet-explain-component <name>` to generate one"

Group components by wave tier:
- **Wave 5** — Operators
- **Wave 6** — Early dependencies (cert-manager-configuration, nmstate-instance, etc.)
- **Wave 15** — Operator instances and configurations
- **Wave 16+** — Cluster config and late dependencies
- **Wave 25** — Applications depending on operator configuration

After the active stack, list commented-out (available but inactive) components if any exist.

### Sequence Diagram

Generate a Mermaid sequence diagram with one participant per distinct sync-wave present in the cluster (label each as `WaveN as Wave N — Role`). Messages from ArgoCD list the components deployed in that wave (abbreviate with "..." above five, listing the most important ones). Use `Note over` blocks to mark readiness gates between tiers. Include non-standard waves (e.g. 7, 16) as distinct participants when they appear.

## Live Validation (when `--context` is provided)

When the user passes `--context <kube-context>`, connect using `oc` or `kubectl` (whichever is available) with `--context <kube-context>` and:

1. List ArgoCD Applications: `oc get applications.argoproj.io -n openshift-gitops -o json --context <context>`. Check each application's sync status and health.
2. Report:
   - Total applications and how many are Synced/Healthy
   - Any applications in Degraded, Progressing, or Unknown state — list them with their status and any status message
   - Applications present in the repo but missing from the cluster, or vice versa
3. If connection fails, report the error and continue with the repo-only analysis — do not abort.

## Readme Output

After presenting the summary in chat, offer to write it as `clusters/<cluster-name>/readme.md`. The readme should contain:
- The identity/role section
- The component stack table
- The sequence diagram (embedded as Mermaid)
- The live validation results if they were gathered

Write only on approval.

## Gotchas

- Hub cluster has a dual role: it runs its own workloads AND provisions managed clusters. The provisioned cluster entries (etl4, etl6, etl7 in the hub's values) are not "components" in the traditional sense — they are cluster provisioning overlays. Distinguish them in the summary.
- Group composition is additive. The merged view from the script handles this, but when explaining, note which group contributes what.
- The `gitops-boostrap-policy` name is a known typo — do not flag it.
- Some values.yaml entries use names that don't match their component path (e.g. `openshift-virtualization` points to `components/openshift-virtualization-operator`, `hyperconverged-instance` points to `components/openshift-virtualization-instance`). Use the values.yaml entry name as the application name and note the actual component path when they differ.
- Commented-out entries are intentional available inventory, not dead code.
