#!/usr/bin/env python3
"""Parse the fleet GitOps repo into a structured JSON representation.

Usage:
    python resolve_repo_structure.py [--repo-root PATH]
    python resolve_repo_structure.py --cluster <name> [--repo-root PATH]

Without --cluster: outputs full repo structure (components, groups, clusters, version pins).
With --cluster: outputs a merged view of a single cluster's complete component stack.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

import yaml


def find_repo_root(start: Path | None = None) -> Path:
    """Walk up from start to find the repo root (contains clusters/ and components/)."""
    if start is None:
        start = Path.cwd()
    current = start.resolve()
    while current != current.parent:
        if (current / "components").is_dir() and (current / "clusters").is_dir():
            return current
        current = current.parent
    raise FileNotFoundError("Cannot locate repo root (need components/ and clusters/ dirs)")


def parse_values_file(path: Path) -> dict:
    """Parse a values.yaml and return applications dict (active and commented-out)."""
    if not path.exists():
        return {"active": {}, "commented_out": []}

    with open(path) as f:
        content = f.read()

    active = {}
    try:
        data = yaml.safe_load(content) or {}
        apps = data.get("applications", {}) or {}
        for name, config in apps.items():
            source_path = ""
            sync_wave = ""
            if config and isinstance(config, dict):
                source = config.get("source", {}) or {}
                source_path = source.get("path", "")
                annotations = config.get("annotations", {}) or {}
                sync_wave = annotations.get("argocd.argoproj.io/sync-wave", "")
            active[name] = {"path": source_path, "sync_wave": sync_wave}
    except yaml.YAMLError:
        pass

    commented_out = []
    for match in re.finditer(r"#\s+([\w-]+):\s*\n(?:#\s+.*\n)*?#\s+.*path:\s*components/([\w-]+)", content):
        commented_out.append(match.group(1))

    return {"active": active, "commented_out": list(set(commented_out))}


def discover_components(repo_root: Path) -> list[dict]:
    """Discover all components and group them by lifecycle prefix."""
    components_dir = repo_root / "components"
    if not components_dir.exists():
        return []

    all_dirs = sorted(
        d.name for d in components_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )

    suffixes = ("-operator", "-instance", "-configuration", "-application")
    groups: dict[str, list[str]] = {}

    for dirname in all_dirs:
        base = dirname
        for suffix in suffixes:
            if dirname.endswith(suffix):
                base = dirname[: -len(suffix)]
                break
        groups.setdefault(base, []).append(dirname)

    results = []
    for base_name, parts in groups.items():
        comp_dir = components_dir / parts[0]
        readme_candidates = [components_dir / p / "readme.md" for p in parts]
        readme_path = next((r for r in readme_candidates if r.exists()), None)

        has_operator_policy = any(
            (components_dir / p / "operator-policy.yaml").exists() for p in parts
        )

        results.append({
            "name": base_name,
            "parts": parts,
            "has_readme": readme_path is not None,
            "readme_path": str(readme_path.relative_to(repo_root)) if readme_path else None,
            "has_operator_policy": has_operator_policy,
        })

    return results


def discover_groups(repo_root: Path) -> list[dict]:
    """Discover groups and which components each enables."""
    groups_dir = repo_root / "groups"
    if not groups_dir.exists():
        return []

    results = []
    for group_dir in sorted(groups_dir.iterdir()):
        if not group_dir.is_dir() or group_dir.name.startswith("."):
            continue

        values_path = group_dir / "values.yaml"
        parsed = parse_values_file(values_path)

        components = list(parsed["active"].keys())
        results.append({
            "name": group_dir.name,
            "components": components,
            "commented_out": parsed["commented_out"],
            "values_path": str(values_path.relative_to(repo_root)),
        })

    return results


def discover_clusters(repo_root: Path) -> list[dict]:
    """Discover clusters, their group memberships, overlays, and nodes."""
    clusters_dir = repo_root / "clusters"
    if not clusters_dir.exists():
        return []

    results = []
    for cluster_dir in sorted(clusters_dir.iterdir()):
        if not cluster_dir.is_dir() or cluster_dir.name.startswith("."):
            continue
        if cluster_dir.name == "cluster-versions.yaml":
            continue

        kustomization_path = cluster_dir / "kustomization.yaml"
        if not kustomization_path.exists():
            continue

        with open(kustomization_path) as f:
            kust_content = f.read()

        groups_included = []
        for match in re.finditer(r"../../groups/(\w+)", kust_content):
            groups_included.append(match.group(1))

        is_hub = cluster_dir.name == "hub"

        values_path = cluster_dir / "values.yaml"
        parsed = parse_values_file(values_path)
        cluster_specific = list(parsed["active"].keys())

        overlays_dir = cluster_dir / "overlays"
        overlays = []
        if overlays_dir.exists():
            overlays = sorted(
                d.name for d in overlays_dir.iterdir()
                if d.is_dir() and not d.name.startswith(".")
            )

        nodes = []
        hub_overlay_dir = repo_root / "clusters" / "hub" / "overlays" / f"cluster-{cluster_dir.name}"
        if hub_overlay_dir.exists():
            for f in hub_overlay_dir.iterdir():
                if f.name.endswith("-baremetal-host.yaml"):
                    hostname = f.name.replace("-baremetal-host.yaml", "")
                    if hostname not in nodes:
                        nodes.append(hostname)
            nodes.sort()

        results.append({
            "name": cluster_dir.name,
            "role": "hub" if is_hub else "managed",
            "groups": groups_included,
            "cluster_specific_components": cluster_specific,
            "commented_out": parsed["commented_out"],
            "overlays": overlays,
            "nodes": nodes,
        })

    return results


def get_version_pins(repo_root: Path) -> dict:
    """Read cluster-versions.yaml and return the data map."""
    versions_path = repo_root / "clusters" / "cluster-versions.yaml"
    if not versions_path.exists():
        return {}

    with open(versions_path) as f:
        data = yaml.safe_load(f) or {}

    return data.get("data", {})


def resolve_cluster(cluster_name: str, repo_root: Path) -> dict:
    """Produce a merged view of a cluster's complete component stack.

    Merges components from all groups the cluster belongs to with
    cluster-specific components, enriched with readme and overlay info.
    """
    clusters = discover_clusters(repo_root)
    cluster = next((c for c in clusters if c["name"] == cluster_name), None)
    if cluster is None:
        available = [c["name"] for c in clusters]
        return {"error": f"Cluster '{cluster_name}' not found. Available: {available}"}

    groups = discover_groups(repo_root)
    components_index = {c["name"]: c for c in discover_components(repo_root)}
    version_pins = get_version_pins(repo_root)

    SUFFIXES = ("-operator", "-instance", "-configuration", "-application")

    def component_base_name(name: str) -> str:
        for s in SUFFIXES:
            if name.endswith(s):
                return name[: -len(s)]
        return name

    merged = []
    seen = set()

    for group_name in cluster["groups"]:
        group = next((g for g in groups if g["name"] == group_name), None)
        if group is None:
            continue
        parsed = parse_values_file(repo_root / group["values_path"])
        for comp_name, info in parsed["active"].items():
            if comp_name in seen:
                continue
            seen.add(comp_name)
            base = component_base_name(comp_name)
            comp_meta = components_index.get(base, {})
            has_overlay = comp_name in cluster["overlays"] or any(
                o == comp_name for o in cluster["overlays"]
            )
            merged.append({
                "name": comp_name,
                "source": f"group:{group_name}",
                "sync_wave": info["sync_wave"].strip("'\"") if info["sync_wave"] else "",
                "component_path": info["path"],
                "has_readme": comp_meta.get("has_readme", False),
                "readme_path": comp_meta.get("readme_path"),
                "has_overlay": has_overlay,
            })

    cluster_values_path = repo_root / "clusters" / cluster_name / "values.yaml"
    cluster_parsed = parse_values_file(cluster_values_path)
    for comp_name, info in cluster_parsed["active"].items():
        if comp_name in seen:
            continue
        seen.add(comp_name)
        base = component_base_name(comp_name)
        comp_meta = components_index.get(base, {})
        has_overlay = comp_name in cluster["overlays"]
        merged.append({
            "name": comp_name,
            "source": "cluster-specific",
            "sync_wave": info["sync_wave"].strip("'\"") if info["sync_wave"] else "",
            "component_path": info["path"],
            "has_readme": comp_meta.get("has_readme", False),
            "readme_path": comp_meta.get("readme_path"),
            "has_overlay": has_overlay,
        })

    merged.sort(key=lambda c: (int(c["sync_wave"]) if c["sync_wave"].isdigit() else 99, c["name"]))

    commented_out = []
    commented_seen = set()
    for group_name in cluster["groups"]:
        group = next((g for g in groups if g["name"] == group_name), None)
        if group is None:
            continue
        for name in group.get("commented_out", []):
            if name not in commented_seen and name not in seen:
                commented_seen.add(name)
                commented_out.append({"name": name, "source": f"group:{group_name}"})
    for name in cluster.get("commented_out", []):
        if name not in commented_seen and name not in seen:
            commented_seen.add(name)
            commented_out.append({"name": name, "source": "cluster-specific"})

    provisioned_clusters = []
    if cluster["role"] == "hub":
        for overlay in cluster["overlays"]:
            if overlay.startswith("cluster-"):
                provisioned_clusters.append(overlay.removeprefix("cluster-"))

    return {
        "cluster_name": cluster_name,
        "role": cluster["role"],
        "groups": cluster["groups"],
        "version_pin": version_pins.get(cluster_name, ""),
        "nodes": cluster["nodes"],
        "overlays": cluster["overlays"],
        "components": merged,
        "commented_out": commented_out,
        "provisioned_clusters": provisioned_clusters,
    }


def main():
    parser = argparse.ArgumentParser(description="Parse fleet GitOps repo structure")
    parser.add_argument("--repo-root", type=Path, default=None,
                        help="Path to repo root (auto-detected if omitted)")
    parser.add_argument("--cluster", type=str, default=None,
                        help="Produce merged component view for a single cluster")
    args = parser.parse_args()

    try:
        repo_root = find_repo_root(args.repo_root) if args.repo_root else find_repo_root()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.cluster:
        result = resolve_cluster(args.cluster, repo_root)
        if "error" in result:
            print(f"Error: {result['error']}", file=sys.stderr)
            sys.exit(1)
    else:
        result = {
            "repo_root": str(repo_root),
            "components": discover_components(repo_root),
            "groups": discover_groups(repo_root),
            "clusters": discover_clusters(repo_root),
            "version_pins": get_version_pins(repo_root),
        }

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
