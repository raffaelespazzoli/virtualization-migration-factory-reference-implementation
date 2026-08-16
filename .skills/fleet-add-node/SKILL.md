---
name: fleet-add-node
description: "Add a bare-metal node to an existing fleet cluster. Use when user says 'add node', 'new node', or 'expand cluster'."
---

## Overview

Add a bare-metal node to an existing managed cluster by generating the required BareMetalHost, NMStateConfig, and DNSEndpoint manifests and patching the hub overlay's kustomization.yaml. The default flow clones an existing node in the same cluster and asks the user to supply only what differs (hostname, IPs, MAC addresses, BMC address). The target cluster must already have at least one node to use as a template; for first-node provisioning use `fleet-add-cluster` instead.

**Args:** `--cluster <cluster-name>` (required). Optional `--hostname <hostname>` to pre-fill. When all required fields are pre-supplied (via args and an input document), the skill proceeds without interactive prompts.

## Resolution rules

- `{fleet-common}` → `.skills/fleet-common` (shared scripts, references).
- `{project-root}` → the project working directory.
- `{skill-root}` → this skill's installed directory.

## On Activation

1. Load `{fleet-common}/references/fleet-repo-structure.md` for architectural context.
2. Run `python {fleet-common}/scripts/resolve_repo_structure.py --cluster <cluster-name> --repo-root {project-root}`. If the cluster is not found, report available clusters and stop.
3. Identify the hub overlay directory: `clusters/hub/overlays/cluster-<cluster-name>/`.
4. List existing nodes from the script output. If nodes exist, read one node's files (all three: BareMetalHost, NMStateConfig, FQDN) to use as the clone template.

## Collect Node Information

Present existing nodes and offer to clone from one (default: the first node listed). Then collect what differs.

**Required fields** (stop and ask when missing):

| Field | Example | Notes |
|-------|---------|-------|
| Hostname | `dl380g9-8` | Must be unique within the cluster |
| BMC address | `redfish://10.9.48.216/redfish/v1/Systems/1/` | Full URL including protocol |
| BMC credentials secret | `bmc-credentials` | Usually shared across the cluster |
| Boot MAC address | `00:11:0a:6a:28:10` | Primary NIC used for PXE |
| Node IP (API/management VLAN) | `10.9.52.136` | On the cluster's management VLAN |
| Storage IP (if cluster uses a storage VLAN) | `192.168.52.136` | Same prefix-length as template |
| Default gateway | Clone from template | Only ask if it differs |

**Cloned from template** (confirm, don't re-ask):
- Bond interfaces and mode
- VLAN IDs
- DNS servers
- Interface names and types
- Node role (master/worker)
- Prefix lengths
- Route configuration (next-hop interface)

**Input modes:** The user can provide fields one at a time in response to prompts, or pass a document (CSV, inventory file, spreadsheet, or freeform text) from which multiple fields are extracted at once. When a document is provided, parse it for all recognizable fields and confirm the extraction before proceeding.

## Generate Files

Run `python {fleet-common}/scripts/generate_node_files.py` with the collected inputs:

```
python {fleet-common}/scripts/generate_node_files.py \
  --repo-root {project-root} \
  --cluster <cluster-name> \
  --hostname <hostname> \
  --bmc-address <bmc-url> \
  --bmc-credentials-name <secret-name> \
  --boot-mac <mac> \
  --node-ip <ip> \
  --template-node <existing-hostname> \
  [--storage-ip <ip>] \
  [--role master|worker] \
  [--gateway <ip>]
```

The script outputs the three YAML files into the hub overlay directory. Review the generated files with the user before patching the kustomization.

## Patch Kustomization

Run `python {fleet-common}/scripts/patch_kustomization.py` to add the new resources:

```
python {fleet-common}/scripts/patch_kustomization.py \
  --file clusters/hub/overlays/cluster-<cluster-name>/kustomization.yaml \
  --add "# ./<hostname>-baremetal-host.yaml" \
  --add "./<hostname>-nmstate-config.yaml" \
  --add "./<hostname>-fqdn.yaml"
```

BareMetalHost entries are added commented-out (they are only active during initial cluster install). NMState and FQDN entries are added active.

Show the final diff of all changes and confirm with the user.

## Gotchas

- BareMetalHost entries are commented out in kustomization.yaml for already-installed clusters. Only uncomment during re-provisioning or initial install.
- NMState configs vary by cluster: some have multi-VLAN with storage NICs, others are single-VLAN. Always clone from the same cluster, never cross-cluster.
- The kustomization.yaml groups resources by type (all BMH together, all nmstate together, all fqdn together). The patch script respects this grouping.
- BMC address format varies by vendor: `redfish://` for iLO/iDRAC, `ipmi://` for IPMI. Preserve whatever format the cluster already uses.
- The `credentialsName` in BareMetalHost usually points to a shared secret (`bmc-credentials`) per cluster, not per node.
- The FQDN entry uses `${PLATFORM_BASE_DOMAIN}` interpolation — this is resolved by the envsub CMP sidecar at deploy time, not by the script.
