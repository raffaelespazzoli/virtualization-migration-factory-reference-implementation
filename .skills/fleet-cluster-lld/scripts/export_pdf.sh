#!/usr/bin/env bash
# Export a markdown LLD document to PDF using pandoc + weasyprint.
# Pre-renders Mermaid diagrams to SVG before conversion.
#
# Usage: export_pdf.sh <input.md> [output.pdf]
#
# If output path is omitted, writes to the same directory as input with .pdf extension.
# Requires: pandoc, weasyprint (install via: sudo dnf install pandoc && uv tool install weasyprint)

set -euo pipefail

INPUT="${1:?Usage: export_pdf.sh <input.md> [output.pdf]}"
OUTPUT="${2:-${INPUT%.md}.pdf}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULT_CSS="$SKILL_DIR/assets/style.css"

if ! command -v pandoc &>/dev/null; then
    echo "ERROR: pandoc is not installed." >&2
    echo "Install with: sudo dnf install pandoc" >&2
    exit 1
fi

if ! command -v weasyprint &>/dev/null; then
    echo "ERROR: weasyprint is not installed." >&2
    echo "Install with: uv tool install weasyprint" >&2
    exit 1
fi

# Create a temporary copy for mermaid pre-processing
WORK_DIR="$(mktemp -d)"
WORK_MD="$WORK_DIR/$(basename "$INPUT")"
cp "$INPUT" "$WORK_MD"

# Make output path absolute before cd
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$(pwd)/$OUTPUT"
fi

# Pre-render Mermaid diagrams to SVG
echo "Rendering Mermaid diagrams..."
uv run "$SCRIPT_DIR/render_mermaid.py" "$WORK_MD" --img-dir "$WORK_DIR"

# Run pandoc from the working directory so relative image paths resolve
PANDOC_ARGS=(
    "$WORK_MD"
    -o "$OUTPUT"
    --from markdown
    --pdf-engine=weasyprint
    --toc
    --toc-depth=3
    --metadata title="Low-Level Design Document"
    --resource-path="$WORK_DIR"
)

if [[ -f "$DEFAULT_CSS" ]]; then
    PANDOC_ARGS+=(--css "$DEFAULT_CSS")
fi

cd "$WORK_DIR"
pandoc "${PANDOC_ARGS[@]}" 2>&1 | grep -v "WARNING: Ignored" || true

# Cleanup
rm -rf "$WORK_DIR"

echo "PDF exported to: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
