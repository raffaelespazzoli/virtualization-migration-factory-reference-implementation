# Fleet Skills

AI-assisted workflows for managing an OpenShift GitOps fleet — cluster provisioning, node expansion, documentation generation, and architecture explanation. These skills work with both **Claude Code** and **Cursor**.

## Skills

| Skill | Trigger | Description |
|-------|---------|-------------|
| `fleet-add-capability` | "add capability", "add operator", "new component" | Add a new operator, helm chart, or raw-manifest component to the fleet |
| `fleet-add-cluster` | "add cluster", "new cluster", "onboard cluster" | Walk through adding a new bare-metal managed cluster to the fleet |
| `fleet-add-node` | "add node", "new node", "expand cluster" | Add a bare-metal node to an existing cluster |
| `fleet-cluster-lld` | "generate LLD", "design document", "cluster LLD" | Generate a structured LLD JSON for a cluster, viewable in the LLD viewer |
| `fleet-explain-cluster` | "explain cluster", "what does this cluster run" | Generate a structured cluster summary JSON, viewable in the cluster viewer |
| `fleet-explain-component` | "explain component", "what does X do" | Generate a structured component JSON, viewable in the component viewer |

## Shared Library

`fleet-common/` contains scripts and references shared across all fleet skills:

- `scripts/resolve_repo_structure.py` — Parse the repo hierarchy and produce a merged component view for a cluster
- `scripts/find_component_siblings.py` — Resolve a component's lifecycle group (operator/instance/configuration)
- `scripts/parse_operator_policy.py` — Extract operator metadata from OperatorPolicy manifests
- `references/fleet-repo-structure.md` — Architectural context document loaded by all skills
- `references/readme-template.md` — Canonical template for component readme files

## Prerequisites

- Python 3.11+
- `uv` (for `fleet-cluster-lld` script execution)

## Installation in Another Repo

These skills are designed to be portable to any repo that follows the same GitOps fleet pattern.

### 1. Copy the skills directory

```bash
cp -r .skills/ <target-repo>/.skills/
```

### 2. Register with Claude Code

```bash
cd <target-repo>
mkdir -p .claude/skills
for d in .skills/fleet-*; do
  ln -sf "../../$d" ".claude/skills/$(basename "$d")"
done
```

### 3. Register with Cursor

```bash
cd <target-repo>
mkdir -p .agents/skills
for d in .skills/fleet-*; do
  ln -sf "../../$d" ".agents/skills/$(basename "$d")"
done
```

### 4. Verify

```bash
# All symlinks should resolve
ls -la .claude/skills/fleet-*
ls -la .agents/skills/fleet-*

# SKILL.md should be readable through the symlink
cat .claude/skills/fleet-explain-cluster/SKILL.md
```

## Customization

### Resolution paths

All skills use these resolution rules:
- `{fleet-common}` resolves to `.skills/fleet-common`
- `{project-root}` resolves to the repository root
- `{skill-root}` resolves to the individual skill's directory

If your repo uses a different directory structure, update `fleet-common/references/fleet-repo-structure.md` to match.

### Adapt for your fleet

The skills assume a repo following the components/groups/clusters hierarchy with ArgoCD app-of-apps and Kustomize. If your repo differs:

1. Update `fleet-repo-structure.md` to describe your layout
2. Modify the Python scripts in `fleet-common/scripts/` to parse your structure
3. Skill SKILL.md files generally don't need changes — they consume script output

## Runtime Files

Files prefixed with `.` (like `.memlog.md`, `.analysis/`) are runtime state generated during skill execution. They are **not** part of the exportable skill definition and can be safely excluded or deleted when copying to another repo:

```bash
# Export without runtime state
rsync -a --exclude='.*' .skills/ <target>/.skills/
```

## Platform Notes

Git symlinks work natively on Linux and macOS. On Windows, ensure `git config core.symlinks true` is set before cloning, or use directory junctions as an alternative.
