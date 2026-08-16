---
name: fleet-cluster-lld
description: "Generate a customer-facing Low-Level Design document for a fleet cluster. Use when user says 'generate LLD', 'design document', or 'cluster LLD'."
---

## Overview

Produce a complete, customer-facing Low-Level Design (LLD) document for a cluster in the virtualization-migration-factory GitOps fleet. The document covers architecture, compute, networking, storage, operators, observability, authentication, upgrades, and design decisions — all extracted from the GitOps repository configuration. Output is a structured markdown file with an option to export as PDF.

**Args:** `<cluster-name>` — as it appears in `clusters/`. Optional `--output <path>` to specify output location (default: `_bmad-output/lld/<cluster-name>-lld.md`). Optional `--headless` to write directly without confirmation and return a status JSON.

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

## Document Composition

With the gathered data and section guidance loaded, compose the LLD using `assets/lld-template.md` as the structural scaffold, filling each section per the guidance in `references/lld-sections.md`. Web-search for current Red Hat documentation links using the OCP version from the ClusterVersion channel.

**Post-composition review:** Before presenting, scan the composed document to verify: (1) all sections are populated with real data (no placeholder braces remain), (2) table row counts match the source JSON, (3) Mermaid fences are well-formed. Fix any issues inline.

## Output

Write the LLD markdown to `{project-root}/_bmad-output/lld/<cluster-name>-lld.md` (or user-specified path). Also persist the gathered data as `{project-root}/_bmad-output/lld/<cluster-name>-lld.json` for programmatic consumption by other skills.

Present a summary: section count, word count, and output paths. Then offer:

- **Export as PDF** — run `{skill-root}/scripts/export_pdf.sh <markdown-path>` which uses pandoc + weasyprint. If not installed, provide: `sudo dnf install pandoc && uv tool install weasyprint`.
- **Adjust sections** — rewrite or expand specific sections on request.

**Headless mode (`--headless`):** Skip all interaction. Write both files and return:
```json
{"status": "complete", "markdown": "<path>", "json": "<path>", "sections": 15, "gaps": []}
```

## Gotchas

- Hub cluster has a dual role: it runs its own workloads AND provisions managed clusters. When generating an LLD for the hub, the provisioning role gets its own section under Multi-Cluster Architecture.
- The `gitops-boostrap-policy` name is a known typo — do not flag it.
- Commented-out entries are available inventory. Report them in the Component Deployment Sequence section as "available but not enabled" rather than ignoring them.
- Some operator names don't match their component directory (e.g., `openshift-virtualization` in values.yaml points to `components/openshift-virtualization-operator`). Use the values.yaml name as the application name and note the component path.
- Secrets visible in the repo (like the Trident ontap-san-secret) should be noted as "credentials managed via sealed secret / GitOps" — do not reproduce credential values in the LLD.
- NMState configs can be complex. Summarize the topology (bonding mode, VLANs, purpose) rather than reproducing every line.
- The `render_mermaid.py` script depends on the external mermaid.ink service. If unreachable (air-gapped, proxy), diagrams remain as code blocks in the PDF. For offline rendering, install `mmdc`: `npm install -g @mermaid-js/mermaid-cli`.
