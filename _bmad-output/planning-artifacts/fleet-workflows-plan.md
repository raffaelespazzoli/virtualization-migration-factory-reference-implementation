# Fleet Management Workflows — Planning Document

Five workflows for managing the virtualization-migration-factory GitOps repo. All built with `bmad-workflow-builder`. They share a common structural understanding of the repo and are designed to compose with each other.

## Shared Infrastructure

### Common Reference: `references/fleet-repo-structure.md`

All five workflows load this shared reference. It codifies:

- **Three-tier hierarchy:** `components/` (reusable bases) → `groups/` (cluster-role aggregation) → `clusters/` (per-cluster composition with overlays)
- **Component lifecycle groups:** Related components share a name prefix. `<name>-operator` deploys via OperatorPolicy at sync-wave 5; `<name>-instance` or `<name>-configuration` creates the operand at wave 15; `<name>-application` or anything depending on configuration runs at wave 25
- **Overlay pattern:** Cluster-specific customization lives in `clusters/<name>/overlays/<component>/`, patching the base component via Kustomize
- **Values-driven app-of-apps:** Each cluster/group directory has a `values.yaml` consumed by the `argocd-app-of-app` Helm chart. Enabled components appear as entries; commented-out entries are available but inactive inventory
- **Node file pattern:** Per-node files in cluster overlays: `<hostname>-nmstate-config.yaml`, `<hostname>-fqdn.yaml`, `<hostname>-baremetal-host.yaml`
- **Version pinning:** `clusters/cluster-versions.yaml` maps cluster names to git refs
- **Key Helm charts:** `argocd-app-of-app`, `bm-cluster-agent-install`, `cluster-registration`

### Script: `scripts/resolve_repo_structure.py`

A shared Python script that, given the repo root, returns a JSON structure:

```json
{
  "components": [
    {
      "name": "metallb",
      "parts": ["metallb-operator", "metallb-configuration"],
      "has_readme": true,
      "readme_path": "components/metallb-configuration/readme.md"
    }
  ],
  "groups": [
    { "name": "all", "components": ["openshift-gitops-operator", "..."] },
    { "name": "prod", "components": ["openshift-virtualization-operator", "..."] }
  ],
  "clusters": [
    {
      "name": "hub",
      "role": "hub",
      "groups": ["all"],
      "cluster_specific_components": ["acm-operator", "..."],
      "overlays": ["openshift-config", "metallb-configuration", "..."],
      "nodes": []
    },
    {
      "name": "etl6",
      "role": "managed",
      "groups": ["all", "prod"],
      "cluster_specific_components": ["..."],
      "overlays": ["openshift-config", "nmstate-configuration", "..."],
      "nodes": ["dl380g9-5", "dl380g9-6", "dl380g9-7"]
    }
  ],
  "version_pins": { "hub": "main", "etl6": "main", "etl7": "main" }
}
```

This avoids every workflow re-parsing the same Kustomize and Helm files.

---

## Phase 1 — Knowledge Workflows

### 1. `fleet-explain-component`

**Purpose:** Produce a clear explanation of what a component does, how it's configured, and how it relates to sibling components. Optionally validate against a live cluster.

**Invocation:**
- `fleet-explain-component <component-name>` — explain from repo only
- `fleet-explain-component <component-name> --cluster <cluster-name>` — also validate against live cluster

**Inputs:**
- Component name (e.g. `metallb`, `metallb-operator`, or `metallb-configuration` — any part of the lifecycle group)
- Optional: cluster name for live validation

**Process:**

1. Run `resolve_repo_structure.py` to find the component and its lifecycle siblings
2. Read the component's Kustomize resources and all YAML manifests
3. Identify the product/project: extract from operator-policy.yaml (subscription name, channel), CRD group, or namespace naming
4. **Web-search** for upstream project documentation and Red Hat product docs
5. Describe:
   - What the component/product does (from upstream docs)
   - Which parts are deployed (operator, instance, configuration — what each contributes)
   - Key configuration choices made in this repo (what CRs are created, what values are set, what is commented-out/available)
   - Which clusters use this component (scan group and cluster values files)
   - Sync-wave placement and why
6. If `--cluster` is provided:
   - Connect via `oc` and verify the operator is installed and healthy
   - Check the operand CR exists and matches the repo definition
   - Report any drift between repo and live state
7. If the component has a `readme.md`, compare it to the generated explanation. If outdated or incomplete, propose an update
8. If no `readme.md` exists, generate one and offer to write it
9. Optionally generate a Mermaid graph showing the component's relationships (operator → instance → configuration, dependencies to other components)

**Output:** Explanation in chat + updated/created `readme.md` on approval

**Tricky bits:**
- Mapping component names to upstream product names (e.g. `nmstate-operator` → Kubernetes NMState, `mtv-operator` → Migration Toolkit for Virtualization)
- Some components are not operators at all (e.g. `openshift-config`, `bookinfo`, `wasp-agent`, `kube-ops-view`)
- The `--cluster` variant needs to handle unreachable clusters gracefully

---

### 2. `fleet-explain-cluster`

**Purpose:** Summarize a cluster's full configuration — what groups it belongs to, what components are enabled, what overlays customize them, and link to each component's readme.

**Invocation:**
- `fleet-explain-cluster <cluster-name>`
- `fleet-explain-cluster <cluster-name> --cluster` — also connect and validate

**Inputs:**
- Cluster name as it appears in `clusters/`

**Process:**

1. Run `resolve_repo_structure.py` to get the cluster's composition
2. Read the cluster's `kustomization.yaml` and `values.yaml`
3. Determine:
   - Which groups are included and what they contribute
   - Which components are enabled vs commented-out in each values file
   - What cluster-specific overlays exist and what they customize
   - For hub clusters: which managed clusters are provisioned from it
4. For each enabled component, link to its `readme.md` (or note it's missing)
5. Compose `fleet-explain-component` for any component the user wants to drill into
6. If `--cluster` is provided:
   - Connect and verify ArgoCD Applications are synced and healthy
   - List any Applications in degraded/progressing state
   - Report overall cluster health
7. Produce a summary document with:
   - Cluster role (hub vs managed)
   - Network topology (from NMState/MetalLB overlays)
   - Storage configuration (from trident/ODF overlays)
   - Enabled operator stack with versions (from operator-policy.yaml channels)
   - Component readmes linkage

**Output:** Cluster summary in chat + optional markdown document

**Tricky bits:**
- Hub cluster has a dual role — it runs its own workloads AND provisions managed clusters
- Group composition is additive — need to merge values from all groups plus cluster-specific
- Commented-out entries need to be distinguished from never-existed entries

---

## Phase 2 — Lifecycle Workflows

### 3. `fleet-add-cluster`

**Purpose:** Walk the user through collecting all information needed to add a new managed cluster, generate the required files, and create a PR.

**Invocation:**
- `fleet-add-cluster` (interactive)
- `fleet-add-cluster --name <cluster-name>` (partially pre-filled)

**Information to collect:**

| Field | Source | Notes |
|---|---|---|
| Cluster name | User | Must be unique, becomes namespace and directory name |
| Number of nodes | User | Typically 3+ for HA (masters) |
| Per-node: hostname, BMC address, BMC credentials, MAC address, boot disk | User | One set per node |
| Network config: bond interfaces, storage NIC, VM NIC, VLANs | User | Per-node NMState config |
| API VIP, Ingress VIP | User | Cluster-level |
| Pod CIDR, Service CIDR | User | Defaults: 10.128.0.0/14, 172.30.0.0/16 |
| SSH public key | User | For node access |
| Cluster set (e.g. `dr`, `default`) | User | ACM cluster set |
| Labels (cloud, vendor, feature toggles) | User | Drives ACM policy placement |
| Masters schedulable? | User | Default: true for compact clusters |
| OCP version / image set | User | Maps to ClusterImageSet |
| Groups to include | User | Default: `all` + `prod` |
| Additional cluster-specific components | User | Beyond what groups provide |
| Version pin | User | Default: `main` |

**Files generated:**

1. `clusters/<name>/kustomization.yaml` — composing groups, rendering app-of-apps
2. `clusters/<name>/values.yaml` — cluster-specific ArgoCD Applications
3. `clusters/hub/overlays/cluster-<name>/kustomization.yaml` — provisioning resources
4. `clusters/hub/overlays/cluster-<name>/namespace.yaml`
5. Per-node files in the hub overlay:
   - `<hostname>-baremetal-host.yaml`
   - `<hostname>-nmstate-config.yaml`
   - `<hostname>-fqdn.yaml`
6. `clusters/hub/overlays/cluster-<name>/pull-secret.yaml` (template — user fills credentials)
7. `clusters/hub/overlays/cluster-<name>/bmc-credentials-secret.yaml` (template)
8. Updated `clusters/cluster-versions.yaml` with new entry
9. Updated `clusters/hub/values.yaml` with new managed cluster Application entry
10. `.gitignore` entries for the new secret files

**Composability:** Calls `fleet-add-node` logic for each node rather than duplicating it.

**Post-generation:** Offer to create a PR via `gh pr create`.

**Tricky bits:**
- Secret files need to be generated as templates but added to `.gitignore`
- The hub's `values.yaml` must be patched (not overwritten) to add the new cluster entry
- Kustomize replacements block must reference the right cluster name in `cluster-versions.yaml`
- Existing cluster names must be checked for conflicts
- BMC credentials vary by vendor (iLO, iDRAC, IPMI)

---

### 4. `fleet-add-node`

**Purpose:** Add a bare-metal node to an existing cluster.

**Invocation:**
- `fleet-add-node --cluster <cluster-name>` (interactive)
- `fleet-add-node --cluster <cluster-name> --hostname <hostname>` (partially pre-filled)

**Information to collect:**

| Field | Source | Notes |
|---|---|---|
| Cluster name | User/arg | Must exist in `clusters/` |
| Hostname | User/arg | Must be unique within the cluster |
| BMC address | User | IPMI/iLO/iDRAC URL |
| BMC credentials | User | Username + password |
| MAC address | User | Primary boot NIC |
| Boot disk | User | e.g. `/dev/sda` |
| Network config | User or clone from existing node | Bond interfaces, IPs if static |

**Files generated:**

1. `clusters/hub/overlays/cluster-<name>/<hostname>-baremetal-host.yaml`
2. `clusters/hub/overlays/cluster-<name>/<hostname>-nmstate-config.yaml`
3. `clusters/hub/overlays/cluster-<name>/<hostname>-fqdn.yaml`
4. Updated `clusters/hub/overlays/cluster-<name>/kustomization.yaml` — add new resources

**Smart defaults:** Offer to clone network config from an existing node in the same cluster, adjusting hostname and addresses.

**Tricky bits:**
- Kustomization.yaml patch is append-only — must not disturb existing entries
- NMState config varies by cluster (different bond interfaces, VLANs)
- BMC credential secrets need `.gitignore` handling

---

### 5. `fleet-remove-node`

**Purpose:** Remove a bare-metal node from an existing cluster.

**Invocation:**
- `fleet-remove-node --cluster <cluster-name> --hostname <hostname>`
- `fleet-remove-node --cluster <cluster-name>` (interactive — lists nodes, user picks)

**Process:**

1. Run `resolve_repo_structure.py` to verify the cluster exists
2. List the cluster's nodes (from the hub overlay files)
3. If no hostname given, present the list and ask which to remove
4. Identify all files for that node:
   - `<hostname>-baremetal-host.yaml`
   - `<hostname>-nmstate-config.yaml`
   - `<hostname>-fqdn.yaml`
5. Remove the files
6. Update `clusters/hub/overlays/cluster-<name>/kustomization.yaml` — remove the resource references
7. Warn if this would reduce the cluster below 3 control plane nodes
8. Show the diff and confirm before writing

**Safety checks:**
- Minimum node count warning
- Confirmation before destructive changes
- Check if the node is referenced anywhere else (unlikely but safe)

**Tricky bits:**
- Not all nodes have all three files (some BareMetalHosts may be commented out)
- The kustomization.yaml may reference files via comments — don't remove commented lines that reference other nodes

---

## Build Sequence

| Order | Workflow | Dependencies | Estimated Complexity |
|---|---|---|---|
| 1 | `fleet-explain-component` | None — establishes conventions | Medium (web search, readme gen) |
| 2 | `fleet-explain-cluster` | Benefits from explain-component readmes | Medium (composition logic) |
| 3 | `fleet-add-node` | None (but needed by fleet-add-cluster) | Low-Medium (file generation) |
| 4 | `fleet-add-cluster` | Composes fleet-add-node | High (most inputs, most files, PR creation) |
| 5 | `fleet-remove-node` | Inverse of fleet-add-node | Low (file deletion + kustomization patch) |

## Shared Scripts

| Script | Used by | Purpose |
|---|---|---|
| `resolve_repo_structure.py` | All five | Parse repo into structured JSON |
| `find_component_siblings.py` | explain-component, explain-cluster | Given one component name, find the lifecycle group |
| `parse_operator_policy.py` | explain-component | Extract operator name, channel, version from OperatorPolicy YAML |
| `generate_node_files.py` | add-node, add-cluster | Template BMH, NMState, FQDN files from collected inputs |
| `patch_kustomization.py` | add-node, remove-node, add-cluster | Safely add/remove resource entries in kustomization.yaml |

## Open Questions

1. **Cluster-connected variants:** Should `--cluster` use `oc` directly, or should we require a kubeconfig path? The hub stores kubeconfigs at `clusters/hub/kubeconfig` — should we use that?
2. **PR workflow:** `fleet-add-cluster` creates a PR. Should it create a branch automatically, or work on the current branch?
3. **Secret handling in fleet-add-cluster:** Generate template files with placeholder values, or prompt for real credentials and write them (relying on `.gitignore`)?
4. **Readme format:** Should `fleet-explain-component` follow a standard readme template, or adapt to what already exists in the 10 existing readmes?
5. **Graph generation:** Mermaid in the readme, or a separate `.drawio.png` like the existing media files?
