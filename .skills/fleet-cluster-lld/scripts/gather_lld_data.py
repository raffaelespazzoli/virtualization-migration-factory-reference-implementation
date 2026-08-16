#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml"]
# ///
"""Gather all data needed to produce an LLD for a given cluster.

Calls resolve_repo_structure.py for the cluster's component stack, then reads
BareMetalHost, NMState, storage, auth, and monitoring manifests to produce a
single JSON structure the LLD-writing prompt can consume without further reads.

Usage:
    python gather_lld_data.py --cluster <name> --repo-root <path>
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml


def safe_load_all(path: Path) -> list[dict]:
    """Load all YAML documents from a file, skipping parse errors."""
    docs = []
    try:
        with open(path) as f:
            for doc in yaml.safe_load_all(f.read()):
                if doc:
                    docs.append(doc)
    except (yaml.YAMLError, OSError):
        pass
    return docs


def extract_baremetal_hosts(hub_overlay: Path) -> list[dict]:
    """Extract node hardware info from BareMetalHost manifests."""
    nodes = []
    for f in sorted(hub_overlay.glob("*-baremetal-host.yaml")):
        for doc in safe_load_all(f):
            if doc.get("kind") != "BareMetalHost":
                continue
            meta = doc.get("metadata", {})
            annotations = meta.get("annotations", {})
            spec = doc.get("spec", {})
            bmc = spec.get("bmc", {})
            nodes.append({
                "name": meta.get("name", ""),
                "hostname": annotations.get("bmac.agent-install.openshift.io/hostname", ""),
                "role": annotations.get("bmac.agent-install.openshift.io/role", "worker"),
                "bmc_address": bmc.get("address", ""),
                "boot_mac": spec.get("bootMACAddress", ""),
                "online": spec.get("online", False),
            })
    return nodes


def extract_nmstate_install(hub_overlay: Path) -> list[dict]:
    """Extract installation-time NMState configs (agent-install NMStateConfig)."""
    configs = []
    for f in sorted(hub_overlay.glob("*-nmstate-config.yaml")):
        for doc in safe_load_all(f):
            if doc.get("kind") != "NMStateConfig":
                continue
            spec = doc.get("spec", {})
            config = spec.get("config", {})
            interfaces = config.get("interfaces", [])
            routes = config.get("routes", {}).get("config", [])
            dns = config.get("dns-resolver", {}).get("config", {}).get("server", [])
            configs.append({
                "name": doc.get("metadata", {}).get("name", ""),
                "interfaces": interfaces,
                "routes": routes,
                "dns_servers": dns,
            })
    return configs


def extract_day2_nmstate(overlay_dir: Path) -> list[dict]:
    """Extract day-2 NodeNetworkConfigurationPolicy from cluster overlays."""
    policies = []
    nmstate_dir = overlay_dir / "nmstate-configuration"
    if not nmstate_dir.exists():
        return policies
    for f in sorted(nmstate_dir.glob("*.yaml")):
        for doc in safe_load_all(f):
            if doc.get("kind") != "NodeNetworkConfigurationPolicy":
                continue
            spec = doc.get("spec", {})
            policies.append({
                "name": doc.get("metadata", {}).get("name", ""),
                "node_selector": spec.get("nodeSelector", {}),
                "interfaces": spec.get("desiredState", {}).get("interfaces", []),
                "ovn_mappings": spec.get("desiredState", {}).get("ovn", {}).get("bridge-mappings", []),
            })
    return policies


def extract_storage_config(overlay_dir: Path) -> list[dict]:
    """Extract storage backends and StorageClasses from trident/ODF overlays."""
    storage = []
    for pattern in ("trident-configuration", "odf-configuration", "trident-instance"):
        sd = overlay_dir / pattern
        if not sd.exists():
            continue
        for f in sorted(sd.glob("*.yaml")):
            for doc in safe_load_all(f):
                kind = doc.get("kind", "")
                if kind in ("TridentBackendConfig", "StorageClass", "StorageCluster"):
                    entry = {
                        "kind": kind,
                        "name": doc.get("metadata", {}).get("name", ""),
                    }
                    if kind == "TridentBackendConfig":
                        spec = doc.get("spec", {})
                        entry["driver"] = spec.get("storageDriverName", "")
                        entry["management_lif"] = spec.get("managementLIF", "")
                        entry["svm"] = spec.get("svm", "")
                    elif kind == "StorageClass":
                        entry["provisioner"] = doc.get("provisioner", "")
                        entry["reclaim_policy"] = doc.get("reclaimPolicy", "")
                        entry["volume_expansion"] = doc.get("allowVolumeExpansion", False)
                        params = doc.get("parameters", {})
                        entry["backend_type"] = params.get("backendType", "")
                        entry["is_default_virt"] = doc.get("metadata", {}).get(
                            "annotations", {}
                        ).get("storageclass.kubevirt.io/is-default-virt-class", "false")
                    storage.append(entry)
    return storage


def extract_auth_config(overlay_dir: Path) -> dict:
    """Extract OAuth and RBAC config from openshift-config overlay."""
    oc_dir = overlay_dir / "openshift-config"
    auth = {"identity_providers": [], "rbac": [], "other": []}
    if not oc_dir.exists():
        return auth
    for f in sorted(oc_dir.glob("*.yaml")):
        for doc in safe_load_all(f):
            kind = doc.get("kind", "")
            if kind == "OAuth":
                providers = doc.get("spec", {}).get("identityProviders", [])
                for p in providers:
                    auth["identity_providers"].append({
                        "name": p.get("name", ""),
                        "type": p.get("type", ""),
                    })
            elif kind in ("ClusterRoleBinding", "RoleBinding", "Group"):
                auth["rbac"].append({
                    "kind": kind,
                    "name": doc.get("metadata", {}).get("name", ""),
                })
            else:
                auth["other"].append({
                    "kind": kind,
                    "name": doc.get("metadata", {}).get("name", ""),
                    "file": f.name,
                })
    return auth


def extract_cluster_version(overlay_dir: Path) -> dict:
    """Extract ClusterVersion / upgrade channel config."""
    oc_dir = overlay_dir / "openshift-config"
    if not oc_dir.exists():
        return {}
    cv_file = oc_dir / "cluster-version.yaml"
    if not cv_file.exists():
        return {}
    for doc in safe_load_all(cv_file):
        if doc.get("kind") == "ClusterVersion":
            spec = doc.get("spec", {})
            return {
                "channel": spec.get("channel", ""),
                "upstream": spec.get("upstream", ""),
                "cluster_id": spec.get("clusterID", ""),
            }
    return {}


def extract_metallb_config(overlay_dir: Path) -> list[dict]:
    """Extract MetalLB configuration (IPAddressPools, L2Advertisements, etc.)."""
    metallb = []
    metallb_dir = overlay_dir / "metallb-configuration"
    if not metallb_dir.exists():
        return metallb
    for f in sorted(metallb_dir.glob("*.yaml")):
        for doc in safe_load_all(f):
            kind = doc.get("kind", "")
            if kind in ("IPAddressPool", "L2Advertisement", "BGPAdvertisement", "BGPPeer", "MetalLB"):
                entry = {
                    "kind": kind,
                    "name": doc.get("metadata", {}).get("name", ""),
                    "file": f.name,
                }
                if kind == "IPAddressPool":
                    spec = doc.get("spec", {})
                    entry["addresses"] = spec.get("addresses", [])
                    entry["auto_assign"] = spec.get("autoAssign", True)
                elif kind == "L2Advertisement":
                    spec = doc.get("spec", {})
                    entry["ip_address_pools"] = spec.get("ipAddressPools", [])
                    entry["node_selectors"] = spec.get("nodeSelectors", [])
                metallb.append(entry)
    return metallb


def extract_monitoring_config(overlay_dir: Path) -> dict:
    """Extract monitoring/observability configuration."""
    oc_dir = overlay_dir / "openshift-config"
    monitoring = {"config_maps": [], "alerts": []}
    if not oc_dir.exists():
        return monitoring
    for f in sorted(oc_dir.glob("*monitoring*")):
        for doc in safe_load_all(f):
            monitoring["config_maps"].append({
                "kind": doc.get("kind", ""),
                "name": doc.get("metadata", {}).get("name", ""),
                "file": f.name,
            })
    return monitoring


def extract_operator_policies(repo_root: Path, components: list[dict]) -> list[dict]:
    """Extract operator metadata from operator-policy.yaml for all cluster components."""
    operators = []
    for comp in components:
        comp_path = comp.get("component_path", "")
        if not comp_path:
            continue
        policy_file = repo_root / comp_path / "operator-policy.yaml"
        if not policy_file.exists():
            continue
        for doc in safe_load_all(policy_file):
            if doc.get("kind") != "OperatorPolicy":
                continue
            spec = doc.get("spec", {})
            sub = spec.get("subscription", {})
            operators.append({
                "component": comp["name"],
                "sync_wave": comp.get("sync_wave", ""),
                "package": sub.get("name", ""),
                "channel": sub.get("channel", ""),
                "source": sub.get("source", ""),
                "namespace": sub.get("namespace", ""),
                "starting_csv": sub.get("startingCSV", ""),
                "versions": spec.get("versions", []),
                "upgrade_approval": spec.get("upgradeApproval", ""),
            })
    return operators


def main():
    parser = argparse.ArgumentParser(description="Gather LLD data for a cluster")
    parser.add_argument("--cluster", required=True, help="Cluster name")
    parser.add_argument("--repo-root", type=Path, required=True, help="Repo root path")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    cluster_name = args.cluster

    # Import and call resolve_repo_structure
    sys.path.insert(0, str(repo_root / ".skills" / "fleet-common" / "scripts"))
    from resolve_repo_structure import resolve_cluster, discover_clusters

    cluster_data = resolve_cluster(cluster_name, repo_root)
    if "error" in cluster_data:
        print(json.dumps({"error": cluster_data["error"]}), file=sys.stderr)
        sys.exit(1)

    # Hub overlay for this cluster (provisioning data)
    hub_overlay = repo_root / "clusters" / "hub" / "overlays" / f"cluster-{cluster_name}"

    # Cluster's own overlay directory
    cluster_overlays = repo_root / "clusters" / cluster_name / "overlays"

    # Gather fleet context (all clusters for multi-cluster section)
    all_clusters = discover_clusters(repo_root)

    result = {
        "cluster": cluster_data,
        "fleet": {
            "clusters": [
                {"name": c["name"], "role": c["role"], "groups": c["groups"], "nodes": c["nodes"]}
                for c in all_clusters
            ],
        },
        "nodes": extract_baremetal_hosts(hub_overlay) if hub_overlay.exists() else [],
        "install_nmstate": extract_nmstate_install(hub_overlay) if hub_overlay.exists() else [],
        "day2_nmstate": extract_day2_nmstate(cluster_overlays),
        "storage": extract_storage_config(cluster_overlays),
        "metallb": extract_metallb_config(cluster_overlays),
        "auth": extract_auth_config(cluster_overlays),
        "cluster_version": extract_cluster_version(cluster_overlays),
        "monitoring": extract_monitoring_config(cluster_overlays),
        "operators": extract_operator_policies(repo_root, cluster_data.get("components", [])),
    }

    # Emit a files_read manifest so the model knows what the script already covered
    files_read = []
    if hub_overlay.exists():
        files_read.extend(str(f.relative_to(repo_root)) for f in sorted(hub_overlay.glob("*.yaml")))
    for subdir in ("nmstate-configuration", "trident-configuration", "trident-instance",
                   "odf-configuration", "openshift-config", "metallb-configuration"):
        sd = cluster_overlays / subdir
        if sd.exists():
            files_read.extend(str(f.relative_to(repo_root)) for f in sorted(sd.glob("*.yaml")))
    result["files_read"] = files_read

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
