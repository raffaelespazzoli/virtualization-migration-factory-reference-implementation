---
name: fleet-add-capability
description: "Add a new capability to the fleet. Use when user says 'add capability', 'add operator', 'new component', or 'add component'."
---

## Overview

Walk the user through adding a new capability (operator, helm chart, or raw manifests) to the fleet GitOps repo — researching installation requirements, scaffolding the correct component directories, writing manifests, and wiring them into the app-of-apps values. Act as a senior platform engineer who knows both upstream product documentation and this repo's conventions deeply.

**Args:** Optional `<capability-name>` (e.g. `vault`, `falco`, `istio`). Optional `--headless` with a structured input block for non-interactive use.

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Load `{fleet-common}/references/fleet-repo-structure.md` as architectural context.
2. Run `python {fleet-common}/scripts/resolve_repo_structure.py --repo-root {project-root}` to get existing components. If the script fails, fall back to `ls {project-root}/components/` and ask the user to confirm.
3. Init memlog: `uv run {project-root}/_bmad/scripts/memlog.py init --path {skill-root}/.memlog.md` (skip if `.memlog.md` already exists — read it to resume).
4. **Route by input completeness:**
   - If the user supplies capability name + installation method + lifecycle parts + target group(s), skip to **Structure Proposal** (fast path).
   - If `--headless` with a structured block (name, method, parts, waves, targets), skip all interaction — go directly to **Generate Files** and return JSON status on completion.
   - Otherwise, proceed to **Collect Requirements**.

## Collect Requirements

When invoked without args, orient the user: mention how many components already exist, name a few categories (observability, security, storage, networking), and ask what they'd like to add — or offer to suggest gaps based on what's missing.

When the user names a capability, confirm the specific product before researching. "Vault" could mean HashiCorp Vault, Vault Secrets Operator, or External Secrets with Vault backend — clarify which, and whether they want just the operator or the full stack.

**Research** — web-search for the product's OpenShift installation method (OLM, helm, raw manifests), namespace requirements, and dependencies. If web search fails or returns insufficient information, ask the user to paste the relevant installation documentation or describe the method themselves.

Log the confirmed product identity and research findings to the memlog.

## Structure Proposal

With research complete (or skipped on the fast path), determine:

1. **Installation method:**

   | Method | When | Component pattern |
   |--------|------|-------------------|
   | OLM Operator | Product is in a catalog (redhat-operators, certified-operators, community-operators) | `<name>-operator` with OperatorPolicy + namespace + operator-group |
   | Helm chart | Product distributes as a Helm chart and is not in OLM | `<name>` or `<name>-instance` with Kustomize referencing an internal `.helm-charts/<name>` |
   | Raw manifests | Neither of the above; Deployments, ConfigMaps, Routes etc. | `<name>` with Kustomize base containing the manifests directly |

2. **Lifecycle parts:**
   - One-part: standalone capability with no operator lifecycle (raw manifests or helm)
   - Two-part: operator + instance/configuration (most OLM operators)
   - Three-part: operator + instance + configuration (complex operators like Trident or ACM)

   Split out configuration when it is independently reusable or requires a separate sync-wave gate.

3. **Sync waves** per the contract: 5 (operator), 6 (rare — only deps other wave-15 components need), 15 (operand CRs / day-2 config), 25 (workloads depending on operator config).

4. **Cluster-level customization:**
   - **Prefer env variables** when a suitable `${VAR}` already exists (`CLUSTER_NAME`, `CLUSTER_BASE_DOMAIN`, `PLATFORM_BASE_DOMAIN`, `HUB_BASE_DOMAIN`, `INFRA_GITOPS_REPO`) or when a new variable would serve multiple components.
   - **Use cluster-level overlays** only when customization is structural or truly unique to one cluster.

Present the proposed structure and log it to the memlog. Proceed on confirmation.

## Generate Files

For each component directory, generate:

**OLM Operator** (`components/<name>-operator/`):
- `kustomization.yaml` — lists all resources
- `namespace.yaml` — target namespace
- `operator-policy.yaml` — OperatorPolicy CR (channel, source, startingCSV, versions, upgradeApproval)

**OLM Instance/Configuration** (`components/<name>-instance/` or `<name>-configuration/`):
- `kustomization.yaml`
- Operand CR YAML (the custom resource that creates the running instance)
- Any additional ConfigMaps, Secrets (templates), or RBAC

**Helm-based** (`components/<name>/`):
- `kustomization.yaml` — may use helmCharts generator or reference an internal chart
- `values.yaml` or inline values

**Raw manifests** (`components/<name>/`):
- `kustomization.yaml`
- Individual resource YAMLs (Deployment, Service, Route, etc.)

**For all types**, also generate:
- `readme.md` following `{fleet-common}/references/readme-template.md`

Log generated file paths to the memlog.

## Wire Into App-of-Apps

Identify which group(s) or cluster(s) should get this capability and propose the `values.yaml` entries:

```yaml
  <component-name>:
    annotations:
      argocd.argoproj.io/sync-wave: '<wave>'
    source:
      path: components/<component-name>
```

For multi-part capabilities, each part gets its own entry at its assigned wave. Present the diff before applying. Log wiring decisions to the memlog.

## Post-Generation

Offer to run `fleet-explain-component <name>` to verify the generated readme matches reality.

**Headless mode:** return JSON status and skip interaction:
```json
{"status": "complete", "components": ["<paths>"], "wired_to": ["<group-or-cluster>"]}
```

## Gotchas

- OperatorPolicy is the canonical deployment mechanism in this repo, not Subscription or ClusterExtension. Legacy files exist as migration artifacts.
- The `gitops-boostrap-policy` typo is intentional — do not fix it.
- Commented-out entries in values.yaml are intentional inventory. When adding a capability that not all clusters need, add it commented-out in the group values and active only in specific cluster values.
- Wave 6 is reserved for dependencies that other wave-15 components need. Do not use it for general operator instances.
- ArgoCD uses `--load-restrictor LoadRestrictionsNone` so Kustomize cross-directory references work.
- Namespace creation should be in the operator component, not the instance/configuration component.
- The operator-group is only needed when the operator targets a specific namespace (not all-namespaces).
