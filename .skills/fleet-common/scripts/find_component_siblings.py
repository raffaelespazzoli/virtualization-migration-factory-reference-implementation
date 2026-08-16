#!/usr/bin/env python3
"""Find lifecycle siblings for a component.

Given any component part name (e.g. 'metallb-operator', 'metallb', or
'metallb-configuration'), returns the full lifecycle group.

Usage:
    python find_component_siblings.py <component-name> [--repo-root PATH]

Outputs JSON:
    {
        "base_name": "metallb",
        "parts": ["metallb-operator", "metallb-configuration"],
        "input_matched": "metallb-operator",
        "has_operator_policy": true,
        "operator_policy_path": "components/metallb-operator/operator-policy.yaml",
        "readme_path": null,
        "deployed_in_groups": ["all"],
        "deployed_in_clusters": ["hub", "etl6", "etl7"],
        "sync_waves": {"metallb-operator": "5", "metallb-configuration": "15"}
    }
"""

import argparse
import json
import sys
from pathlib import Path

import yaml

LIFECYCLE_SUFFIXES = ("-operator", "-instance", "-configuration", "-application")


def find_repo_root(start: Path | None = None) -> Path:
    if start is None:
        start = Path.cwd()
    current = start.resolve()
    while current != current.parent:
        if (current / "components").is_dir() and (current / "clusters").is_dir():
            return current
        current = current.parent
    raise FileNotFoundError("Cannot locate repo root")


def strip_suffix(name: str) -> str:
    for suffix in LIFECYCLE_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def find_siblings(component_name: str, repo_root: Path) -> dict:
    components_dir = repo_root / "components"
    base_name = strip_suffix(component_name)

    parts = sorted(
        d.name for d in components_dir.iterdir()
        if d.is_dir() and strip_suffix(d.name) == base_name
    )

    if not parts:
        if (components_dir / component_name).is_dir():
            parts = [component_name]
            base_name = component_name
        else:
            return {"error": f"No component found matching '{component_name}'"}

    input_matched = component_name if component_name in parts else (
        base_name if base_name in parts else parts[0]
    )

    operator_policy_path = None
    for part in parts:
        candidate = components_dir / part / "operator-policy.yaml"
        if candidate.exists():
            operator_policy_path = str(candidate.relative_to(repo_root))
            break

    readme_path = None
    for part in parts:
        candidate = components_dir / part / "readme.md"
        if candidate.exists():
            readme_path = str(candidate.relative_to(repo_root))
            break

    groups_dir = repo_root / "groups"
    deployed_in_groups = []
    sync_waves: dict[str, str] = {}

    if groups_dir.exists():
        for group_dir in sorted(groups_dir.iterdir()):
            values_path = group_dir / "values.yaml"
            if not values_path.exists():
                continue
            try:
                with open(values_path) as f:
                    data = yaml.safe_load(f) or {}
                apps = data.get("applications", {}) or {}
                group_has_component = False
                for part in parts:
                    if part in apps:
                        group_has_component = True
                        config = apps[part] or {}
                        if isinstance(config, dict):
                            annotations = config.get("annotations", {}) or {}
                            wave = annotations.get("argocd.argoproj.io/sync-wave", "")
                            if wave:
                                sync_waves[part] = wave.strip("'\"")
                if group_has_component:
                    deployed_in_groups.append(group_dir.name)
            except (yaml.YAMLError, AttributeError):
                continue

    clusters_dir = repo_root / "clusters"
    deployed_in_clusters = []

    if clusters_dir.exists():
        for cluster_dir in sorted(clusters_dir.iterdir()):
            if not cluster_dir.is_dir():
                continue
            kust_path = cluster_dir / "kustomization.yaml"
            if not kust_path.exists():
                continue

            with open(kust_path) as f:
                kust_content = f.read()

            cluster_groups = []
            import re
            for match in re.finditer(r"../../groups/(\w+)", kust_content):
                cluster_groups.append(match.group(1))

            if any(g in deployed_in_groups for g in cluster_groups):
                deployed_in_clusters.append(cluster_dir.name)
                continue

            values_path = cluster_dir / "values.yaml"
            if values_path.exists():
                try:
                    with open(values_path) as f:
                        data = yaml.safe_load(f) or {}
                    apps = data.get("applications", {}) or {}
                    if any(part in apps for part in parts):
                        deployed_in_clusters.append(cluster_dir.name)
                except (yaml.YAMLError, AttributeError):
                    continue

    return {
        "base_name": base_name,
        "parts": parts,
        "input_matched": input_matched,
        "has_operator_policy": operator_policy_path is not None,
        "operator_policy_path": operator_policy_path,
        "readme_path": readme_path,
        "deployed_in_groups": deployed_in_groups,
        "deployed_in_clusters": deployed_in_clusters,
        "sync_waves": sync_waves,
    }


def main():
    parser = argparse.ArgumentParser(description="Find lifecycle siblings for a component")
    parser.add_argument("component", help="Component name (any part of the lifecycle group)")
    parser.add_argument("--repo-root", type=Path, default=None)
    args = parser.parse_args()

    try:
        repo_root = find_repo_root(args.repo_root) if args.repo_root else find_repo_root()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    result = find_siblings(args.component, repo_root)
    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
