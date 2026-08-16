#!/usr/bin/env python3
"""Parse an OperatorPolicy YAML and extract key operator metadata.

Usage:
    python parse_operator_policy.py <path-to-operator-policy.yaml>
    python parse_operator_policy.py <component-name> [--repo-root PATH]

Outputs JSON:
    {
        "operator_name": "kubernetes-nmstate-operator",
        "channel": "stable",
        "source": "redhat-operators",
        "namespace": "openshift-nmstate",
        "starting_csv": "kubernetes-nmstate-operator.4.19.0-202507291138",
        "current_version": "4.19.0-202507291138",
        "upgrade_approval": "Automatic",
        "versions_count": 25,
        "latest_version": "kubernetes-nmstate-operator.4.22.0-202607280824",
        "has_operator_group": true
    }
"""

import argparse
import json
import re
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


def extract_version_from_csv(csv: str) -> str:
    """Extract version string from a CSV name like 'operator-name.v4.19.0-202507291138'."""
    match = re.search(r"\.v?(\d+\.\d+[\w.+-]*)", csv)
    if match:
        return match.group(1)
    parts = csv.rsplit(".", 1)
    if len(parts) == 2:
        return parts[1]
    return csv


def parse_operator_policy(path: Path) -> dict:
    """Parse a single operator-policy.yaml file."""
    with open(path) as f:
        data = yaml.safe_load(f)

    if not data or data.get("kind") != "OperatorPolicy":
        return {"error": f"Not an OperatorPolicy: {path}"}

    spec = data.get("spec", {})
    subscription = spec.get("subscription", {}) or {}
    operator_group = spec.get("operatorGroup")
    versions = spec.get("versions", []) or []

    operator_name = subscription.get("name", "")
    channel = subscription.get("channel", "")
    source = subscription.get("source", "")
    namespace = subscription.get("namespace", "")
    starting_csv = subscription.get("startingCSV", "")
    upgrade_approval = spec.get("upgradeApproval", "")

    current_version = extract_version_from_csv(starting_csv) if starting_csv else ""
    latest_version = versions[-1] if versions else starting_csv

    return {
        "operator_name": operator_name,
        "channel": channel,
        "source": source,
        "namespace": namespace,
        "starting_csv": starting_csv,
        "current_version": current_version,
        "upgrade_approval": upgrade_approval,
        "versions_count": len(versions),
        "latest_version": latest_version,
        "has_operator_group": operator_group is not None,
    }


def resolve_policy_path(component_name: str, repo_root: Path) -> Path | None:
    """Find the operator-policy.yaml for a component by name."""
    components_dir = repo_root / "components"

    direct = components_dir / component_name / "operator-policy.yaml"
    if direct.exists():
        return direct

    base = component_name
    for suffix in LIFECYCLE_SUFFIXES:
        if component_name.endswith(suffix):
            base = component_name[: -len(suffix)]
            break

    operator_dir = components_dir / f"{base}-operator"
    if (operator_dir / "operator-policy.yaml").exists():
        return operator_dir / "operator-policy.yaml"

    for d in components_dir.iterdir():
        if d.is_dir() and d.name.startswith(base) and (d / "operator-policy.yaml").exists():
            return d / "operator-policy.yaml"

    return None


def main():
    parser = argparse.ArgumentParser(description="Parse OperatorPolicy YAML")
    parser.add_argument("target", help="Path to operator-policy.yaml or component name")
    parser.add_argument("--repo-root", type=Path, default=None)
    args = parser.parse_args()

    target_path = Path(args.target)

    if target_path.exists() and target_path.is_file():
        policy_path = target_path
    else:
        try:
            repo_root = find_repo_root(args.repo_root) if args.repo_root else find_repo_root()
        except FileNotFoundError as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)

        policy_path = resolve_policy_path(args.target, repo_root)
        if policy_path is None:
            print(json.dumps({"error": f"No operator-policy.yaml found for '{args.target}'"}))
            sys.exit(0)

    result = parse_operator_policy(policy_path)
    result["policy_path"] = str(policy_path)

    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
