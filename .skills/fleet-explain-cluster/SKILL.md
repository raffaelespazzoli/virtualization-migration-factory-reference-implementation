---
name: fleet-explain-cluster
description: "Summarize a GitOps fleet cluster's configuration. Use when user says 'explain cluster' or 'what does this cluster run'."
---

## Overview

Produce a structured JSON explanation of a cluster's configuration in the virtualization-migration-factory GitOps repo: which groups it belongs to, every component it runs (merged from groups and cluster-specific values), which overlays customize them, and a sync-wave sequence diagram showing deployment order. Act as a senior platform engineer who knows this repo's architecture. The output is a JSON file conforming to the cluster documentation schema, viewable through the fleet cluster viewer.

**Args:** `<cluster-name>` — as it appears in `clusters/`. Optional `--context <kube-context>` to validate against a live cluster.

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Run `python {fleet-common}/scripts/resolve_repo_structure.py --cluster <cluster-name> --repo-root {project-root}` to get the merged component view. If it errors, report the available cluster names and stop.

2. Load `{fleet-common}/references/fleet-repo-structure.md` and the cluster's `clusters/<cluster-name>/kustomization.yaml` for architectural context.

## Build the JSON Output

Produce a JSON file at `{project-root}/clusters/<cluster-name>/<cluster-name>.json` conforming to the schema at `{fleet-common}/assets/cluster-schema.json`. The structure has:

- **Metadata:** cluster name, title, role (hub/managed), version pin, groups, managed clusters (hub only), node inventory.
- **Sections** (array, rendered in order):
  - `type: "text"` — titled prose paragraphs (identity and role, dependencies, customization points)
  - `type: "diagram"` — Mermaid sequence diagram showing sync-wave deployment order
  - `type: "table"` — component stack organized by sync-wave
  - `type: "config-summary"` — notable configuration values when relevant

### Section Guidance

**Identity and Role** (`text`): Cluster name, role (hub or managed), version pin. Groups included and what each contributes (e.g. "group `all` provides base infrastructure; group `prod` adds virtualization, HA, and observability"). For hub clusters: list the managed clusters it provisions. Node inventory.

**Deployment Sequence** (`diagram`): Generate a Mermaid sequence diagram with one participant per distinct sync-wave present in the cluster (label each as `WaveN as Wave N — Role`). Messages from ArgoCD list the components deployed in that wave (abbreviate with "..." above five, listing the most important ones). Use `Note over` blocks to mark readiness gates between tiers. Include non-standard waves (e.g. 7, 16) as distinct participants when they appear.

Place diagrams immediately after Identity and Role so the reader gets the high-level deployment flow before the detailed component table.

**Component Stack** (`table`): All active components organized by sync-wave, showing deployment order. Columns: Name, Sync-Wave, Source (`group:all`, `group:prod`, or `cluster-specific`), Has Overlay, Has Readme. Group components by wave tier:
- **Wave 5** — Operators
- **Wave 6** — Early dependencies
- **Wave 15** — Operator instances and configurations
- **Wave 16+** — Cluster config and late dependencies
- **Wave 25** — Applications depending on operator configuration

**Available Inventory** (`table`): Commented-out (available but inactive) components, if any exist.

## Live Validation (when `--context` is provided)

When the user passes `--context <kube-context>`, connect using `oc` or `kubectl` (whichever is available) with `--context <kube-context>` and:

1. List ArgoCD Applications: `oc get applications.argoproj.io -n openshift-gitops -o json --context <context>`. Check each application's sync status and health.
2. Add a **Live Validation** section to the JSON:
   - Total applications and how many are Synced/Healthy
   - Any applications in Degraded, Progressing, or Unknown state — list them with their status and any status message
   - Applications present in the repo but missing from the cluster, or vice versa
3. If connection fails, report the error and continue with the repo-only analysis — do not abort.

## Validate and Write

1. Validate the JSON with `python {fleet-common}/scripts/validate_component_json.py {project-root}/clusters/<cluster-name>/<cluster-name>.json --schema {fleet-common}/assets/cluster-schema.json`. Fix any schema violations before proceeding.

2. Tell the user the JSON is ready and provide the viewer link:

```
Open [cluster-viewer.html]({fleet-common}/assets/cluster-viewer.html) and load `clusters/<cluster-name>/<cluster-name>.json`.
```

## Gotchas

- Hub cluster has a dual role: it runs its own workloads AND provisions managed clusters. The provisioned cluster entries (etl4, etl6, etl7 in the hub's values) are not "components" in the traditional sense — they are cluster provisioning overlays. Distinguish them in the JSON.
- Group composition is additive. The merged view from the script handles this, but when explaining, note which group contributes what.
- The `gitops-boostrap-policy` name is a known typo — do not flag it.
- Some values.yaml entries use names that don't match their component path (e.g. `openshift-virtualization` points to `components/openshift-virtualization-operator`, `hyperconverged-instance` points to `components/openshift-virtualization-instance`). Use the values.yaml entry name as the application name and note the actual component path when they differ.
- Commented-out entries are intentional available inventory, not dead code.
