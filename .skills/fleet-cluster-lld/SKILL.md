---
name: fleet-cluster-lld
description: "Generate a customer-facing Low-Level Design document for a fleet cluster. Use when user says 'generate LLD', 'design document', or 'cluster LLD'."
---

## Overview

Produce a complete, customer-facing Low-Level Design (LLD) for a cluster in the virtualization-migration-factory GitOps fleet. The document covers architecture, compute, networking, storage, operators, observability, authentication, upgrades, and design decisions — all extracted from the GitOps repository configuration. The output is a structured JSON file conforming to the LLD schema, viewable through the fleet LLD viewer.

**Args:** `<cluster-name>` — as it appears in `clusters/`. Optional `--headless` to write directly without confirmation and return a status JSON.

## Resolution rules

- Bare paths (e.g. `references/lld-sections.md`) resolve from this skill's installed directory.
- `{fleet-common}` → `{project-root}/.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Run `uv run {skill-root}/scripts/gather_lld_data.py --cluster <cluster-name> --repo-root {project-root}` to produce the consolidated data JSON. If it errors, report available cluster names and stop.

2. **Validate data sufficiency:** Check the JSON for minimum viable data per section — nodes non-empty (Compute), storage non-empty (Storage), cluster_version non-empty (Upgrades), operators non-empty (Operator Stack). If any critical section lacks data, report which sections will be thin and ask the user whether to proceed with a reduced document or provide supplementary input. In headless mode, proceed with available data and note gaps in the Executive Summary.

3. Load `{fleet-common}/references/fleet-repo-structure.md` and `references/lld-sections.md` as context.

4. For each component that has a `readme.md` (from the data's `has_readme` field), read it to enrich the component descriptions.

## Build the JSON Output

Produce a JSON file at `{project-root}/clusters/<cluster-name>/<cluster-name>-lld.json` conforming to the schema at `{fleet-common}/assets/lld-schema.json`. The structure has:

- **Metadata:** cluster name, title, generation timestamp, OCP version, role (hub/managed).
- **Sections** (array, rendered in order):
  - `type: "text"` — titled prose paragraphs (executive summary, architecture overview, design decisions, etc.)
  - `type: "diagram"` — Mermaid diagrams (architecture, network topology, deployment sequence)
  - `type: "table"` — structured data (compute inventory, operator stack, storage configuration, etc.)
  - `type: "config-summary"` — ties configuration values to upstream documentation with rationale

With the gathered data and section guidance loaded, compose the LLD sections per the guidance in `references/lld-sections.md`. Web-search for current Red Hat documentation links using the OCP version from the ClusterVersion channel.

**Diagram placement:** Place architecture and sequence diagrams immediately after the introductory/overview sections so the reader gets the high-level picture before detailed configuration tables.

**Post-composition review:** Before writing, scan the composed JSON to verify: (1) all sections are populated with real data (no placeholder braces remain), (2) table row counts match the source data, (3) Mermaid strings are well-formed. Fix any issues inline.

## Validate and Write

1. Validate the JSON with `python {fleet-common}/scripts/validate_component_json.py {project-root}/clusters/<cluster-name>/<cluster-name>-lld.json --schema {fleet-common}/assets/lld-schema.json`. Fix any schema violations before proceeding.

2. Present a brief chat summary: section count and output path. Then provide the viewer link:

```
Open [lld-viewer.html]({fleet-common}/assets/lld-viewer.html) and load `clusters/<cluster-name>/<cluster-name>-lld.json`.
```

Then offer to adjust sections — rewrite or expand specific sections on request.

**Headless mode (`--headless`):** Skip all interaction. Write the JSON and return:
```json
{"status": "complete", "json": "clusters/<cluster-name>/<cluster-name>-lld.json", "sections": 15, "gaps": []}
```

## Gotchas

- Hub cluster has a dual role: it runs its own workloads AND provisions managed clusters. When generating an LLD for the hub, the provisioning role gets its own section under Multi-Cluster Architecture.
- The `gitops-boostrap-policy` name is a known typo — do not flag it.
- Commented-out entries are available inventory. Report them in the Component Deployment Sequence section as "available but not enabled" rather than ignoring them.
- Some operator names don't match their component directory (e.g., `openshift-virtualization` in values.yaml points to `components/openshift-virtualization-operator`). Use the values.yaml name as the application name and note the component path.
- Secrets visible in the repo (like the Trident ontap-san-secret) should be noted as "credentials managed via sealed secret / GitOps" — do not reproduce credential values in the LLD.
- NMState configs can be complex. Summarize the topology (bonding mode, VLANs, purpose) rather than reproducing every line.
