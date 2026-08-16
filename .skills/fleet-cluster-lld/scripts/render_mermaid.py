#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["requests"]
# ///
"""Pre-process a Markdown file to render Mermaid code blocks as PNG images.

Finds all ```mermaid fenced code blocks, renders each via the mermaid.ink
service to PNG, saves the images alongside the markdown, and replaces the
code blocks with image references. Outputs the processed markdown to stdout
or a specified file.

Usage:
    python render_mermaid.py <input.md> [-o output.md] [--img-dir <dir>]

The mermaid.ink API is free and requires no authentication. If unreachable,
diagrams remain as code blocks. For offline rendering, install mmdc:
    npm install -g @mermaid-js/mermaid-cli
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
from pathlib import Path

import requests

MERMAID_INK_PNG_URL = "https://mermaid.ink/img/"

MERMAID_BLOCK_RE = re.compile(
    r"```mermaid\s*\n(.*?)```",
    re.DOTALL,
)


def render_mermaid_to_png(diagram: str) -> bytes | None:
    """Render a Mermaid diagram to PNG via mermaid.ink."""
    encoded = base64.urlsafe_b64encode(diagram.encode("utf-8")).decode("ascii")
    url = MERMAID_INK_PNG_URL + encoded
    try:
        resp = requests.get(url, timeout=30)
        if resp.status_code == 200 and resp.headers.get("content-type", "").startswith("image/"):
            return resp.content
    except requests.RequestException as e:
        print(f"WARNING: Failed to render diagram: {e}", file=sys.stderr)
    return None


def process_markdown(content: str, img_dir: Path, base_name: str) -> str:
    """Replace mermaid blocks with PNG image references."""
    counter = 0

    def replacer(match: re.Match) -> str:
        nonlocal counter
        counter += 1
        diagram = match.group(1).strip()

        png_content = render_mermaid_to_png(diagram)
        if png_content is None:
            print(f"WARNING: Could not render diagram {counter}, keeping as code block", file=sys.stderr)
            return match.group(0)

        png_filename = f"{base_name}-diagram-{counter}.png"
        png_path = img_dir / png_filename
        png_path.write_bytes(png_content)
        size_kb = len(png_content) / 1024
        print(f"  Rendered diagram {counter} → {png_path} ({size_kb:.1f} KB)", file=sys.stderr)

        rel_path = png_filename
        return f"![Diagram {counter}]({rel_path})"

    return MERMAID_BLOCK_RE.sub(replacer, content)


def main():
    parser = argparse.ArgumentParser(description="Render Mermaid diagrams in Markdown to PNG")
    parser.add_argument("input", help="Input markdown file")
    parser.add_argument("-o", "--output", help="Output markdown file (default: overwrite input)")
    parser.add_argument("--img-dir", help="Directory for PNG files (default: same as input)")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: {input_path} not found", file=sys.stderr)
        sys.exit(1)

    img_dir = Path(args.img_dir) if args.img_dir else input_path.parent
    img_dir.mkdir(parents=True, exist_ok=True)

    content = input_path.read_text(encoding="utf-8")
    base_name = input_path.stem

    block_count = len(MERMAID_BLOCK_RE.findall(content))
    if block_count == 0:
        print("No mermaid blocks found.", file=sys.stderr)
        output_path = Path(args.output) if args.output else input_path
        if args.output:
            output_path.write_text(content, encoding="utf-8")
        sys.exit(0)

    # Pre-flight connectivity check
    try:
        resp = requests.head(MERMAID_INK_PNG_URL, timeout=5)
        if resp.status_code >= 500:
            print(
                "WARNING: mermaid.ink appears unreachable — diagrams will remain as code blocks.\n"
                "  For offline rendering, install mmdc: npm install -g @mermaid-js/mermaid-cli",
                file=sys.stderr,
            )
    except requests.RequestException:
        print(
            "WARNING: mermaid.ink is not reachable — diagrams will remain as code blocks.\n"
            "  For offline rendering, install mmdc: npm install -g @mermaid-js/mermaid-cli",
            file=sys.stderr,
        )

    print(f"Found {block_count} mermaid diagram(s), rendering...", file=sys.stderr)
    processed = process_markdown(content, img_dir, base_name)

    output_path = Path(args.output) if args.output else input_path
    output_path.write_text(processed, encoding="utf-8")
    print(f"Output written to: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
