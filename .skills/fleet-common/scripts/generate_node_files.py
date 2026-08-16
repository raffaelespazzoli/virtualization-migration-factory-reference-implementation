#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml>=6.0"]
# ///
"""Generate BareMetalHost, NMStateConfig, and DNSEndpoint files for a new node.

Clones an existing node's files from the same cluster and substitutes per-node
values (hostname, IPs, MACs, BMC address). Preserves the template's structure
and formatting for everything not explicitly substituted.

Usage:
    python generate_node_files.py \\
      --repo-root /path/to/repo \\
      --cluster etl6 \\
      --hostname dl380g9-8 \\
      --bmc-address "redfish://10.9.48.218/redfish/v1/Systems/1/" \\
      --bmc-credentials-name bmc-credentials \\
      --boot-mac 00:11:0a:6a:29:00 \\
      --node-ip 10.9.52.138 \\
      --template-node dl380g9-5 \\
      [--storage-ip 192.168.52.138] \\
      [--role master|worker] \\
      [--gateway 10.9.52.129] \\
      [--dry-run]

Outputs JSON with the paths of generated files.
"""

import argparse
import json
import re
import sys
from pathlib import Path

import yaml


def find_repo_root(start: Path | None = None) -> Path:
    if start is None:
        start = Path.cwd()
    current = start.resolve()
    while current != current.parent:
        if (current / "components").is_dir() and (current / "clusters").is_dir():
            return current
        current = current.parent
    raise FileNotFoundError("Cannot locate repo root (need components/ and clusters/ dirs)")


def extract_template_values(overlay_dir: Path, template_hostname: str) -> dict:
    """Extract substitution-relevant values from a template node's files."""
    values = {"hostname": template_hostname}

    bmh_path = overlay_dir / f"{template_hostname}-baremetal-host.yaml"
    if bmh_path.exists():
        with open(bmh_path) as f:
            bmh = yaml.safe_load(f)
        spec = bmh.get("spec", {})
        bmc = spec.get("bmc", {})
        values["bmc_address"] = bmc.get("address", "")
        values["bmc_credentials_name"] = bmc.get("credentialsName", "")
        values["boot_mac"] = spec.get("bootMACAddress", "")
        annotations = bmh.get("metadata", {}).get("annotations", {})
        values["role"] = annotations.get("bmac.agent-install.openshift.io/role", "master")

    fqdn_path = overlay_dir / f"{template_hostname}-fqdn.yaml"
    if fqdn_path.exists():
        with open(fqdn_path) as f:
            fqdn = yaml.safe_load(f)
        endpoints = fqdn.get("spec", {}).get("endpoints", [])
        if endpoints:
            targets = endpoints[0].get("targets", [])
            values["node_ip"] = targets[0] if targets else ""

    nmstate_path = overlay_dir / f"{template_hostname}-nmstate-config.yaml"
    if nmstate_path.exists():
        with open(nmstate_path) as f:
            nmstate = yaml.safe_load(f)
        config = nmstate.get("spec", {}).get("config", {})
        routes = config.get("routes", {}).get("config", [])
        if routes:
            values["gateway"] = routes[0].get("next-hop-address", "")

        interfaces = config.get("interfaces", [])
        for iface in interfaces:
            if iface.get("type") == "vlan" and iface.get("ipv4", {}).get("enabled"):
                addrs = iface.get("ipv4", {}).get("address", [])
                if addrs:
                    ip = addrs[0].get("ip", "")
                    if ip == values.get("node_ip"):
                        continue
                    values["storage_ip"] = ip
                    break

    return values


def substitute_file(content: str, old_values: dict, new_values: dict) -> str:
    """Apply text substitutions from old values to new values."""
    result = content

    result = result.replace(old_values["hostname"], new_values["hostname"])

    if "bmc_address" in new_values and old_values.get("bmc_address"):
        result = result.replace(old_values["bmc_address"], new_values["bmc_address"])

    if "boot_mac" in new_values and old_values.get("boot_mac"):
        result = result.replace(old_values["boot_mac"], new_values["boot_mac"])

    if "node_ip" in new_values and old_values.get("node_ip"):
        result = result.replace(old_values["node_ip"], new_values["node_ip"])

    if "storage_ip" in new_values and old_values.get("storage_ip"):
        result = result.replace(old_values["storage_ip"], new_values["storage_ip"])

    if "gateway" in new_values and old_values.get("gateway"):
        result = result.replace(old_values["gateway"], new_values["gateway"])

    if "bmc_credentials_name" in new_values and old_values.get("bmc_credentials_name"):
        result = result.replace(old_values["bmc_credentials_name"], new_values["bmc_credentials_name"])

    if "role" in new_values and old_values.get("role"):
        old_role_line = f"bmac.agent-install.openshift.io/role: {old_values['role']}"
        new_role_line = f"bmac.agent-install.openshift.io/role: {new_values['role']}"
        result = result.replace(old_role_line, new_role_line)

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Generate BareMetalHost, NMStateConfig, and DNSEndpoint files for a new node"
    )
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--cluster", required=True, help="Target cluster name")
    parser.add_argument("--hostname", required=True, help="New node hostname")
    parser.add_argument("--bmc-address", required=True, help="BMC address URL")
    parser.add_argument("--bmc-credentials-name", default="bmc-credentials",
                        help="Name of BMC credentials secret")
    parser.add_argument("--boot-mac", required=True, help="Primary boot NIC MAC address")
    parser.add_argument("--node-ip", required=True, help="Node management IP address")
    parser.add_argument("--template-node", required=True,
                        help="Hostname of existing node to clone from")
    parser.add_argument("--storage-ip", default=None, help="Storage VLAN IP address")
    parser.add_argument("--role", default=None, choices=["master", "worker"],
                        help="Node role (default: clone from template)")
    parser.add_argument("--gateway", default=None, help="Default gateway IP")
    parser.add_argument("--dry-run", action="store_true", help="Print files without writing")
    args = parser.parse_args()

    try:
        repo_root = find_repo_root(args.repo_root) if args.repo_root else find_repo_root()
    except FileNotFoundError as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        sys.exit(2)

    overlay_dir = repo_root / "clusters" / "hub" / "overlays" / f"cluster-{args.cluster}"
    if not overlay_dir.exists():
        print(json.dumps({"error": f"Hub overlay not found: {overlay_dir}"}), file=sys.stderr)
        sys.exit(1)

    template_files = {
        "bmh": overlay_dir / f"{args.template_node}-baremetal-host.yaml",
        "nmstate": overlay_dir / f"{args.template_node}-nmstate-config.yaml",
        "fqdn": overlay_dir / f"{args.template_node}-fqdn.yaml",
    }

    missing = [k for k, v in template_files.items() if not v.exists()]
    if missing:
        print(json.dumps({
            "error": f"Template node files missing for '{args.template_node}': {missing}",
            "overlay_dir": str(overlay_dir),
        }), file=sys.stderr)
        sys.exit(1)

    old_values = extract_template_values(overlay_dir, args.template_node)

    new_values = {
        "hostname": args.hostname,
        "bmc_address": args.bmc_address,
        "bmc_credentials_name": args.bmc_credentials_name,
        "boot_mac": args.boot_mac,
        "node_ip": args.node_ip,
    }
    if args.storage_ip:
        new_values["storage_ip"] = args.storage_ip
    if args.role:
        new_values["role"] = args.role
    if args.gateway:
        new_values["gateway"] = args.gateway

    generated = {}
    for kind, template_path in template_files.items():
        with open(template_path) as f:
            content = f.read()

        new_content = substitute_file(content, old_values, new_values)

        suffix = template_path.name.replace(args.template_node, "")
        new_filename = f"{args.hostname}{suffix}"
        new_path = overlay_dir / new_filename

        if args.dry_run:
            generated[kind] = {
                "path": str(new_path.relative_to(repo_root)),
                "content": new_content,
            }
        else:
            new_path.write_text(new_content)
            generated[kind] = {
                "path": str(new_path.relative_to(repo_root)),
                "written": True,
            }

    json.dump({"ok": True, "files": generated}, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
