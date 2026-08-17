#!/usr/bin/env python3
"""Validate a component documentation JSON file against the schema.

Usage:
    python validate_component_json.py <path-to-json>
    python validate_component_json.py <path-to-json> --schema <path-to-schema>

Exit codes:
    0 = valid
    1 = validation errors (printed to stderr)
    2 = file not found or unparseable
"""

import argparse
import json
import sys
from pathlib import Path


def find_schema(explicit: Path | None = None) -> Path:
    if explicit and explicit.exists():
        return explicit
    here = Path(__file__).resolve().parent.parent / "assets" / "component-schema.json"
    if here.exists():
        return here
    raise FileNotFoundError("Cannot locate component-schema.json")


def validate_required(data: dict, path: str = "") -> list[str]:
    """Lightweight validation without jsonschema dependency."""
    errors = []

    required_root = ["component", "title", "generated", "sections"]
    for field in required_root:
        if field not in data:
            errors.append(f"{path}missing required field: {field}")

    if not isinstance(data.get("component"), str) or not data["component"]:
        errors.append(f"{path}'component' must be a non-empty string")

    if not isinstance(data.get("title"), str) or not data["title"]:
        errors.append(f"{path}'title' must be a non-empty string")

    if not isinstance(data.get("generated"), str) or not data["generated"]:
        errors.append(f"{path}'generated' must be a non-empty string")

    sections = data.get("sections")
    if not isinstance(sections, list) or len(sections) == 0:
        errors.append(f"{path}'sections' must be a non-empty array")
    else:
        for i, section in enumerate(sections):
            sp = f"{path}sections[{i}]: "
            if not isinstance(section, dict):
                errors.append(f"{sp}must be an object")
                continue
            stype = section.get("type")
            if stype not in ("text", "config-summary", "diagram", "table"):
                errors.append(f"{sp}invalid type '{stype}' (must be text|config-summary|diagram|table)")
                continue
            if "title" not in section:
                errors.append(f"{sp}missing required field 'title'")
            if stype == "text" and "body" not in section:
                errors.append(f"{sp}text section missing 'body'")
            if stype == "diagram" and "mermaid" not in section:
                errors.append(f"{sp}diagram section missing 'mermaid'")
            if stype == "table":
                if "columns" not in section:
                    errors.append(f"{sp}table section missing 'columns'")
                if "rows" not in section:
                    errors.append(f"{sp}table section missing 'rows'")
            if stype == "config-summary" and "values" in section:
                values = section["values"]
                if not isinstance(values, list):
                    errors.append(f"{sp}'values' must be an array")
                else:
                    for j, val in enumerate(values):
                        vp = f"{sp}values[{j}]: "
                        for req in ("resource", "field", "value", "rationale"):
                            if req not in val:
                                errors.append(f"{vp}missing required field '{req}'")

    if "lifecycle_parts" in data:
        parts = data["lifecycle_parts"]
        if not isinstance(parts, list):
            errors.append(f"{path}'lifecycle_parts' must be an array")
        else:
            for i, part in enumerate(parts):
                pp = f"{path}lifecycle_parts[{i}]: "
                for req in ("name", "wave", "purpose"):
                    if req not in part:
                        errors.append(f"{pp}missing required field '{req}'")

    if "clusters" in data:
        if not isinstance(data["clusters"], list):
            errors.append(f"{path}'clusters' must be an array")

    allowed_root = {"component", "title", "generated", "upstream", "lifecycle_parts", "clusters", "sections"}
    extra = set(data.keys()) - allowed_root
    if extra:
        errors.append(f"{path}unexpected top-level fields: {', '.join(sorted(extra))}")

    return errors


def validate_with_jsonschema(data: dict, schema_path: Path) -> list[str]:
    """Full JSON Schema validation when jsonschema is available."""
    try:
        import jsonschema
    except ImportError:
        return validate_required(data)

    with open(schema_path) as f:
        schema = json.load(f)

    validator = jsonschema.Draft7Validator(schema)
    return [
        f"{'.'.join(str(p) for p in err.absolute_path)}: {err.message}" if err.absolute_path
        else err.message
        for err in sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
    ]


def main():
    parser = argparse.ArgumentParser(description="Validate component documentation JSON")
    parser.add_argument("json_file", type=Path, help="Path to the JSON file to validate")
    parser.add_argument("--schema", type=Path, default=None, help="Path to schema file")
    args = parser.parse_args()

    if not args.json_file.exists():
        print(f"Error: file not found: {args.json_file}", file=sys.stderr)
        sys.exit(2)

    try:
        with open(args.json_file) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON: {e}", file=sys.stderr)
        sys.exit(2)

    try:
        schema_path = find_schema(args.schema)
        errors = validate_with_jsonschema(data, schema_path)
    except FileNotFoundError:
        errors = validate_required(data)

    if errors:
        print(f"Validation failed ({len(errors)} error{'s' if len(errors) != 1 else ''}):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    print(f"Valid: {args.json_file.name}")
    sys.exit(0)


if __name__ == "__main__":
    main()
