# LLD Section Guidance

Per-section extraction and writing guidance for the fleet-cluster-lld skill. Each section below describes what data to extract, what to write, and what tone/depth is appropriate for a customer-facing Low-Level Design document.

## General Writing Rules

- **Tone:** Professional consulting deliverable. Write as a senior architect presenting to a customer's technical staff.
- **Specificity:** Use actual values from the config (hostnames, IPs, VLANs, operator versions). Never leave placeholders where real data exists.
- **Tables:** Prefer tables for structured data (node inventory, operator list, network interfaces).
- **Mermaid:** Use diagrams for architecture relationships, network topology, and deployment sequence.
- **References:** Link to official Red Hat documentation where relevant (use the current OCP version from ClusterVersion channel).

---

## 1. Title & Metadata

Source: cluster name, domain from NMState hostnames, date.

Write: A formal title page block with document title, cluster name, version, date, and a "Generated from GitOps repository" note.

---

## 2. Executive Summary

Source: cluster role, group membership, node count, component count.

Write: 2-3 paragraphs summarizing what this cluster is, its role in the fleet, what it runs, and how it's managed. Mention: GitOps-driven via ArgoCD, ACM-managed (if managed role), operator count, storage backend, key workloads (virtualization if openshift-virtualization is present).

---

## 3. Multi-Cluster Architecture

Source: `fleet.clusters` (all clusters in the fleet), cluster role, provisioned_clusters (for hub).

Write:
- Fleet topology: which clusters exist, their roles (hub vs managed), how they relate.
- How this cluster fits: managed by which hub, what cluster set, what labels.
- ACM relationship: policy-based governance, GitOps delivery model.
- Include a Mermaid diagram showing hub → managed relationships.

---

## 4. Cluster Identity

Source: `cluster.cluster_name`, `cluster.role`, `cluster.groups`, `cluster.version_pin`, `cluster_version.channel`.

Write:
- Table: cluster name, role, OCP version/channel, version pin (git ref), groups included.
- What each group contributes (base infra from `all`, virtualization/HA/observability from `prod`, etc.).

---

## 5. Compute & Node Inventory

Source: `nodes` (BareMetalHost data), `install_nmstate` (MAC addresses, interface names).

Write:
- Node inventory table: hostname, role (master/worker), BMC address, boot MAC, online status.
- Hardware identification: server model (from hostname pattern, e.g. "dl380g9" = HPE ProLiant DL380 Gen9).
- NIC inventory per node (from NMState interfaces list).
- Note on masters schedulable (if role=master for all nodes in a 3-node cluster, it's compact/converged).

---

## 6. Networking

Source: `install_nmstate` (bonding, VLANs, IPs, routes, DNS), `day2_nmstate` (OVS bridges, bridge mappings).

Write subsections:

### 6.1 Installation Network
- Bond configuration (mode, ports).
- VLAN assignments: which VLAN IDs, what purpose (control plane, storage, VM traffic).
- IP addressing scheme (subnet, gateway from routes).
- DNS servers.

### 6.2 Day-2 Network Configuration
- OVS bridge setup (name, ports, purpose).
- OVN bridge-mappings (localnet names mapped to bridges).
- Per-node variations if any.

### 6.3 Network Summary Table
Table: Interface/VLAN | Purpose | Subnet | Nodes

### 6.4 Network Topology Diagram
Mermaid diagram showing node → bond → VLANs → OVS bridges → localnet mappings.

---

## 7. Storage

Source: `storage` (TridentBackendConfig, StorageClass).

Write:
- Storage backend: vendor (NetApp/ODF), driver, management endpoint, SVM.
- StorageClass table: name, provisioner, reclaim policy, volume expansion, default-virt-class.
- Note on RWX support for live migration.
- Diagram if multiple backends exist.

---

## 8. Installation Method

Source: BareMetalHost BMC addresses (Redfish URLs indicate agent-based install), hub overlay structure.

Write:
- Installation method: ACM agent-based install via hub cluster.
- How it works: hub provisions via BareMetalHost CRs + InfraEnv + AgentClusterInstall.
- BMC protocol: Redfish (deduce from `redfish://` in BMC addresses).
- Boot method: virtual media (Redfish virtual media, not PXE).

---

## 9. Operator Stack

Source: `operators` list from gather_lld_data, `cluster.components`.

Write:
- Table: Operator | Package | Channel | Source | Namespace | Sync-Wave | Upgrade Policy
- Group by wave tier (5, 6, 15, 25).
- Note on operator lifecycle management via OperatorPolicy (ACM policy-based, not traditional Subscription).
- Highlight key operators: OpenShift Virtualization, Trident, cert-manager, MetalLB, NMState, MTV.

---

## 10. Observability

Source: `monitoring` config, presence of monitoring-related components (cluster-observability-operator, user-workload-monitoring, acm-observability, grafana).

Write:
- What's deployed: which observability components are active.
- Custom monitoring configuration (from cluster-monitoring-configmap if present).
- Multi-cluster observability (ACM observability if present in the fleet).
- Alerting configuration notes.

---

## 11. Authentication & Authorization

Source: `auth` (identity providers, RBAC entries).

Write:
- Identity providers configured (type, name).
- RBAC model: what roles/bindings are defined at cluster level.
- Note on whether OIDC/LDAP is configured or if it's htpasswd-only (and recommend OIDC for production).

---

## 12. Cluster Upgrades

Source: `cluster_version` (channel, upstream), operator `upgrade_approval` fields.

Write:
- OCP upgrade channel and strategy.
- Operator upgrade policy (Automatic vs Manual) — per-operator table if they differ.
- Recommendations for upgrade coordination (control plane first, then operators, then worker nodes).

---

## 13. Component Deployment Sequence

Source: `cluster.components` (sorted by sync-wave).

Write:
- Full component table sorted by sync-wave: Component | Wave | Source | Has Overlay | Purpose.
- Mermaid sequence diagram showing deployment order by wave tier.
- Note commented-out (available but inactive) components.

---

## 14. Design Decisions

Source: Inferred from configuration choices throughout the document.

Write a table of key design decisions, each with:
- ID (e.g. DD-01)
- Topic
- Decision made (what the config shows)
- Rationale (why this is a reasonable choice — draw from Red Hat best practices)

Examples to look for:
- Compact cluster (masters schedulable) vs dedicated workers
- Storage driver choice (ontap-san vs ontap-nas, thin provisioning)
- Network topology (dedicated OVS bridge for VMs vs shared SDN)
- HTPasswd vs OIDC (note if this appears to be a lab/interim config)
- Upgrade channel choice (stable vs fast vs eus)
- Agent-based install vs IPI vs UPI

---

## 15. References

Write: Links to official Red Hat documentation for each major technology used, using the OCP version detected from ClusterVersion channel.
