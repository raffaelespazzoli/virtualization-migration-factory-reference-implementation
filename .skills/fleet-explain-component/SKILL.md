---
name: fleet-explain-component
description: "Explain a GitOps fleet component. Use when user says 'explain component' or 'what does <component> do'."
---

# Overview

Produce a structured JSON explanation of what a fleet component does, how it's configured, and how it relates to sibling components. Act as a senior platform engineer who knows this GitOps repo's architecture deeply. The output is a JSON file conforming to the component documentation schema, viewable through the fleet component viewer.

**Args:** `<component-name>` — any part of a lifecycle group (e.g. `metallb`, `metallb-operator`, or `metallb-configuration` all resolve to the same group).

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Run `python {fleet-common}/scripts/find_component_siblings.py <component-name> --repo-root {project-root}` to resolve the lifecycle group. If it returns an error, tell the user the component wasn't found and list similar names from `python {fleet-common}/scripts/resolve_repo_structure.py --repo-root {project-root}`.

2. If the component has an operator-policy, run `python {fleet-common}/scripts/parse_operator_policy.py <component-name> --repo-root {project-root}` to extract operator metadata.

3. Read all YAML manifests in each part directory (`components/<part>/`). Understand what Kubernetes resources are created.

4. Load `{fleet-common}/references/fleet-repo-structure.md` as architectural context.

## Research

Map the component to its upstream project using:
- OperatorPolicy `subscription.name` and `subscription.source`
- Namespace naming and CRD groups
- Known mappings: `nmstate-operator` → Kubernetes NMState, `mtv-operator` → Migration Toolkit for Virtualization, `acm-operator` → Red Hat Advanced Cluster Management, `trident-operator` → NetApp Astra Trident, `odf-operator` → OpenShift Data Foundation

Web-search for the upstream project documentation and Red Hat product docs. Use these to ground the configuration summary — explain not just what values are set but why, based on official documentation.

## Build the JSON Output

Produce a JSON file at `{project-root}/components/<primary-part>/<base-name>.json` conforming to the schema at `{fleet-common}/assets/component-schema.json`. Place the JSON in the part with the most configuration context (typically `-configuration` or `-instance`, or the base component if standalone). The structure has:

- **Metadata:** component name, title, generation timestamp, upstream info (product, docs URL, operator, channel, source), lifecycle parts with sync-waves, and target clusters.
- **Sections** (array, rendered in order):
  - `type: "text"` — titled prose paragraphs (overview, dependencies, customization points)
  - `type: "config-summary"` — ties actual repo configuration values to upstream documentation. Each value entry names the resource, field, current value, and a rationale drawn from the docs explaining why that value matters.
  - `type: "diagram"` — Mermaid source string rendered client-side. Produce two when they add clarity:
    - **Infrastructure architecture** — what the configured infrastructure looks like (topology, resources created, relationships to other components and consumers)
    - **Deployment sequence** — sync-wave ordering and dependencies
  - `type: "table"` — structured data (lifecycle parts, cluster deployment)

Place diagrams immediately after the introductory text sections (Overview, How It Works) so the reader gets the visual architecture before detailed configuration summaries and tables.

Only produce diagrams that illuminate non-obvious relationships. A single-part component with no dependencies needs no diagram.

## Validate and Write

1. Validate the JSON with `python {fleet-common}/scripts/validate_component_json.py {project-root}/components/<primary-part>/<base-name>.json`. Fix any schema violations before proceeding.

2. Write or update `components/<primary-part>/readme.md` — keep it minimal:

```markdown
# {Component Title}

{One-sentence description.}

**Documentation:** Open [component-viewer.html]({fleet-common}/assets/component-viewer.html) and load `components/<primary-part>/{base-name}.json`.

**Upstream:** {link to official docs}
```

Place the readme in the part with the most configuration context (typically `-configuration` or `-instance`, or the base component if standalone).

3. Tell the user the JSON is ready and where to find it.

## Gotchas

- Some components exist in `components/` but aren't referenced by any active values.yaml entry — they're available inventory. Report this rather than assuming it's an error.
- The `gitops-boostrap-policy` name is a known typo — don't flag it.
- Components with `acm-` prefix: `acm-operator` and `acm-instance` are core ACM; `acm-configuration` is provisioning config; `acm-observability` is multi-cluster monitoring; `acm-fusion-dr` is disaster recovery. Don't conflate them.
- `openshift-virtualization-operator` creates the operator, but the instance part deploys a `HyperConverged` CR — the naming is misleading without context.
- Trident has three tiers: `trident-operator`, `trident-instance`, `trident-configuration` — plus separate `trident-protect-*` components (a different product).
