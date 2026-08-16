#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# ///
"""Add or remove resource entries in a kustomization.yaml file.

Respects the fleet convention of grouping resources by type (all BMH together,
all nmstate together, all fqdn together). Handles both active and commented-out
entries (BareMetalHost entries are typically commented out for installed clusters).

Usage:
    python patch_kustomization.py \\
      --file clusters/hub/overlays/cluster-etl6/kustomization.yaml \\
      --add "# ./dl380g9-8-baremetal-host.yaml" \\
      --add "./dl380g9-8-nmstate-config.yaml" \\
      --add "./dl380g9-8-fqdn.yaml"

    python patch_kustomization.py \\
      --file clusters/hub/overlays/cluster-etl6/kustomization.yaml \\
      --remove dl380g9-8 \\
      [--dry-run]

Outputs JSON with the result.
"""

import argparse
import json
import re
import sys
from pathlib import Path


RESOURCE_TYPE_ORDER = ["baremetal-host", "nmstate-config", "fqdn"]


def classify_resource(entry: str) -> str | None:
    """Determine the resource type from a resource line."""
    cleaned = entry.lstrip("# ").strip().strip("- ").strip("./")
    for rtype in RESOURCE_TYPE_ORDER:
        if rtype in cleaned:
            return rtype
    return None


def find_insertion_point(lines: list[str], resource_type: str) -> int:
    """Find the line index where a new resource of the given type should be inserted.

    Inserts after the last resource of the same type, or after the last resource
    of a preceding type if no matching type exists yet.
    """
    last_of_type = -1
    last_resource = -1
    in_resources = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("resources:"):
            in_resources = True
            last_resource = i
            continue
        if in_resources:
            if stripped.startswith("- ") or stripped.startswith("# - "):
                last_resource = i
                line_type = classify_resource(stripped)
                if line_type == resource_type:
                    last_of_type = i
            elif stripped and not stripped.startswith("#"):
                in_resources = False

    if last_of_type >= 0:
        return last_of_type + 1
    return last_resource + 1


def add_resources(content: str, entries: list[str]) -> str:
    """Add resource entries to the kustomization, grouped by type."""
    lines = content.splitlines()

    entries_by_type: dict[str, list[str]] = {}
    for entry in entries:
        rtype = classify_resource(entry) or "other"
        entries_by_type.setdefault(rtype, []).append(entry)

    for rtype in reversed(RESOURCE_TYPE_ORDER + ["other"]):
        if rtype not in entries_by_type:
            continue
        for entry in entries_by_type[rtype]:
            cleaned = entry.lstrip("# ").strip()
            is_commented = entry.strip().startswith("#")

            already_exists = False
            for line in lines:
                line_clean = line.lstrip("# ").strip().lstrip("- ").strip()
                entry_clean = cleaned.lstrip("- ").strip()
                if line_clean == entry_clean:
                    already_exists = True
                    break

            if already_exists:
                continue

            insert_at = find_insertion_point(lines, rtype)

            indent = "  "
            for line in lines:
                if line.strip().startswith("- ./") or line.strip().startswith("# - ./"):
                    indent = line[: len(line) - len(line.lstrip())]
                    break

            if is_commented:
                new_line = f"{indent}# - {cleaned.lstrip('- ').strip()}"
            else:
                new_line = f"{indent}- {cleaned.lstrip('- ').strip()}"

            lines.insert(insert_at, new_line)

    return "\n".join(lines) + "\n"


def remove_resources(content: str, hostname: str) -> str:
    """Remove all resource entries for a given hostname."""
    lines = content.splitlines()
    filtered = []
    for line in lines:
        stripped = line.lstrip("# ").strip()
        if stripped.startswith("- ") or stripped.startswith("./"):
            cleaned = stripped.lstrip("- ").strip().strip("./")
            if cleaned.startswith(hostname + "-"):
                continue
        filtered.append(line)
    return "\n".join(filtered) + "\n"


def main():
    parser = argparse.ArgumentParser(
        description="Add or remove resource entries in a kustomization.yaml"
    )
    parser.add_argument("--file", required=True, type=Path, help="Path to kustomization.yaml")
    parser.add_argument("--add", action="append", default=[],
                        help="Resource entry to add (repeatable). Prefix with '# ' for commented-out entries.")
    parser.add_argument("--remove", type=str, default=None,
                        help="Hostname to remove (removes all matching resource entries)")
    parser.add_argument("--dry-run", action="store_true", help="Print result without writing")
    args = parser.parse_args()

    if not args.add and not args.remove:
        print(json.dumps({"error": "Specify --add or --remove"}), file=sys.stderr)
        sys.exit(1)

    if not args.file.exists():
        print(json.dumps({"error": f"File not found: {args.file}"}), file=sys.stderr)
        sys.exit(1)

    content = args.file.read_text()

    if args.remove:
        content = remove_resources(content, args.remove)

    if args.add:
        content = add_resources(content, args.add)

    if args.dry_run:
        json.dump({"ok": True, "content": content, "path": str(args.file)}, sys.stdout, indent=2)
    else:
        args.file.write_text(content)
        json.dump({"ok": True, "path": str(args.file), "written": True}, sys.stdout, indent=2)

    print()


if __name__ == "__main__":
    main()
