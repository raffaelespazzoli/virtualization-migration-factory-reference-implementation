# Analysis Report: .skills/fleet-cluster-lld

Generated: 2026-08-16 · Schema: 2

**Grade: Fair**

> Solid data-gathering architecture; main gaps are missing headless mode, unreferenced template asset, and no validation gate before composing a customer-facing deliverable.

The skill is impressively lean at 892 tokens with a well-drawn intelligence-placement boundary — scripts handle extraction, the model owns synthesis. However, three high-severity issues (structural H1/H2 error, missing headless mode, missing data-sufficiency validation) and a pattern of duplicated/disconnected content (inline section list, unreferenced template, hardcoded branding) prevent a higher grade.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 3 |
| Medium | 11 |
| Low | 7 |

## Themes

### 1. Disconnected template and duplicated section enumeration

- Root cause: lld-template.md exists but is never loaded; the 15-item section list in SKILL.md duplicates the authoritative ordering in references/lld-sections.md, wasting tokens and creating a shadow that would block future customization overrides.
- Fix: Wire assets/lld-template.md as the structural scaffold in Document Composition; remove the inline section enumeration (lines 37–52) and let lld-sections.md be authoritative.
- Findings:
  - `architecture-2` Template asset exists but is never loaded
  - `enhancement-3` Unreferenced template — same as architecture-2
  - `leanness-1` Inline section list duplicates reference file ordering
  - `customization-3` Inline section list would shadow template override

### 2. No quality gates for customer-facing output

- Root cause: A customer-facing LLD can ship with empty sections, stale placeholders, or mismatched table counts because there's no validation between gather and compose, and no self-review after composition.
- Fix: Add a data-sufficiency check after gather (report which sections lack data) and a completeness scan after composition (no placeholders, section count matches, table rows match JSON).
- Findings:
  - `enhancement-2` Missing data-sufficiency validation between gather and compose
  - `enhancement-6` Missing lightweight reviewer gate for customer-facing output

### 3. Missing headless and composability mode

- Root cause: The skill is fully scriptable but lacks headless invocation, JSON persistence, and writes only after an unnecessary confirmation round-trip.
- Fix: Add a --headless flag that writes directly and returns a status JSON; persist gathered data as <cluster>-lld.json for downstream consumption; default to writing immediately in interactive mode too.
- Findings:
  - `enhancement-1` Missing headless mode — skill is trivially adaptable but unwired
  - `enhancement-4` Missing composability hook — gathered JSON is not persisted
  - `enhancement-5` Interactive confirmation gate is over-applied

### 4. Gather script coverage gap forces model into extraction work

- Root cause: gather_lld_data.py doesn't extract metallb-configuration data, forcing the model to read raw YAML overlays and compute which files the script missed — both deterministic operations.
- Fix: Extend gather_lld_data.py to cover metallb-configuration and emit a files_read manifest so the model never needs to diff coverage.
- Findings:
  - `determinism-1` MetalLB overlay not extracted by gather script
  - `determinism-2` Model must diff script coverage vs filesystem

### 5. Hardcoded templates with no customization surface

- Root cause: references/lld-sections.md and assets/style.css contain org-specific content (section structure, brand colors/fonts) with no customize.toml entry point for override.
- Fix: Create customize.toml with lld_sections_template and pdf_style_template override points. Document the contract each template must satisfy.
- Findings:
  - `customization-1` Section template hardcoded with no customize.toml override
  - `customization-2` PDF style hardcoded with org-specific brand colors

## Strengths

- Well-drawn intelligence-placement boundary: scripts own extraction (YAML parsing, structured data), model owns synthesis and writing.
- Extremely lean SKILL.md at 892 tokens — well under the 1500-token desired budget with no waste patterns or decorative formatting.
- Robust gotchas section captures genuine institutional knowledge (typo preservation, secret handling, NMState summarization).
- Clean path standards — no bare-bmad references, no absolute paths, no cross-dir dot-slash patterns.
- gather_lld_data.py has unit tests and produces clean structured JSON with stderr-only diagnostics.

## Recommendations

1. Fix H1 Overview to H2 and wire lld-template.md into the Document Composition section; remove inline section list. (resolves: architecture-1, architecture-2, enhancement-3, leanness-1, customization-3)
2. Add headless mode (--headless flag), persist JSON dual-output, remove interactive confirmation gate for default flow. (resolves: enhancement-1, enhancement-4, enhancement-5)
3. Add data-sufficiency validation after gather and a completeness self-review scan after composition. (resolves: enhancement-2, enhancement-6)
4. Extend gather_lld_data.py to extract metallb-configuration and emit a files_read manifest. (resolves: determinism-1, determinism-2)
5. Create customize.toml with lld_sections_template and pdf_style_template points. (resolves: customization-1, customization-2)
6. Fix {fleet-common} resolution to use {project-root}/.skills/fleet-common and add bare-path preamble to resolution rules. (resolves: architecture-3, architecture-4)

## Experience

- **Interactive LLD generation** — User says 'generate LLD for etl7' → skill gathers data → composes document → writes to file → optionally exports PDF
- **PDF export** — User says 'export as PDF' after generation → skill runs export_pdf.sh → mermaid diagrams rendered → PDF delivered
- Headless: Not wired — skill is trivially adaptable (accepts all args, deterministic script) but currently lacks the --headless flag and status JSON contract.

## Findings

### High (3)

#### architecture-1 — Overview uses H1 instead of H2

- Lens: architecture
- Evidence: Line 6 is `# Overview` (H1) while all other sections use `## …` (H2). Tooling and compaction logic key on `## Overview` specifically.
- Recommendation: Change `# Overview` to `## Overview`.

#### enhancement-1 — Missing headless mode — skill is trivially adaptable but unwired

- Lens: enhancement
- Evidence: The skill accepts fully-specified args and runs a deterministic script, yet no headless invocation path exists.
- Recommendation: Add a --headless flag. When set, skip confirmation and return {"status":"complete","path":"<output>"} as the headless JSON contract.

#### enhancement-2 — Missing data-sufficiency validation between gather and compose

- Lens: enhancement
- Evidence: The skill transitions from script output directly to document composition with no check that the JSON covers all 15 sections.
- Recommendation: After gather, validate minimum required fields per section. Report missing data and ask user whether to proceed with reduced document.

### Medium (11)

#### architecture-2 — Template asset exists but is never loaded

- Lens: architecture
- Evidence: No reference to assets/lld-template.md appears in SKILL.md, references, or scripts.
- Recommendation: Route to it from Document Composition as the structural skeleton, or delete it.

#### architecture-3 — {fleet-common} resolves to ambiguous bare relative path

- Lens: architecture
- Evidence: Resolution rules define {fleet-common} → .skills/fleet-common. Bare paths resolve from the skill's installed directory, making this resolve to a non-existent nested path.
- Recommendation: Change to {fleet-common} → {project-root}/.skills/fleet-common.

#### leanness-1 — Inline section list duplicates reference file ordering

- Lens: leanness
- Evidence: The 15-item section list on lines 37–52 is a verbatim copy of what's already in references/lld-sections.md, which line 30 already routes to.
- Recommendation: Remove the inline enumeration; let references/lld-sections.md be authoritative for section order.

#### enhancement-3 — Unreferenced template — same as architecture-2

- Lens: enhancement
- Evidence: Duplicate of architecture-2: lld-template.md exists but is never loaded by any skill file.
- Recommendation: Wire as structural scaffold or delete.

#### enhancement-4 — Missing composability hook — gathered JSON is not persisted

- Lens: enhancement
- Evidence: The gather script produces structured JSON consumed once by the model and then lost. Downstream skills would need to re-run the script.
- Recommendation: Save the script JSON alongside the markdown as <cluster-name>-lld.json.

#### enhancement-5 — Interactive confirmation gate is over-applied

- Lens: enhancement
- Evidence: The user already asked for the LLD explicitly. Forcing a confirmation adds a round-trip with no gain.
- Recommendation: Default to writing immediately; present summary with path and offer adjustments.

#### enhancement-6 — Missing lightweight reviewer gate for customer-facing output

- Lens: enhancement
- Evidence: 15 sections composed with no self-review step. Placeholders or miscounted tables could ship to customer.
- Recommendation: Add a post-composition scan: verify sections populated, no placeholders remain, table counts match JSON.

#### determinism-1 — MetalLB overlay not extracted by gather script

- Lens: determinism
- Evidence: Step 4 asks the model to read metallb-configuration/ overlays — the same deterministic extraction work the script does for trident/nmstate.
- Recommendation: Extend gather_lld_data.py to extract metallb-configuration data.

#### determinism-2 — Model must diff script coverage vs filesystem

- Lens: determinism
- Evidence: Step 4 says 'Only read files not already captured by the script' — the model must compute what the script missed, a deterministic operation.
- Recommendation: Have gather script emit a files_read manifest so the model knows exactly what remains.

#### customization-1 — Section template hardcoded with no customize.toml override

- Lens: customization
- Evidence: Orgs needing different LLD sections (Compliance, Security Posture, SLA) must fork the skill.
- Recommendation: Lift to a lld_sections_template customization point in customize.toml.

#### customization-2 — PDF style hardcoded with org-specific brand colors

- Lens: customization
- Evidence: Colors #1e3a5f, #1d4ed8, fonts Liberation Sans, and A4 page size are baked in with no override mechanism.
- Recommendation: Add a pdf_style_template customization point in customize.toml.

### Low (7)

#### leanness-2 — Three composition bullets restate writing rules from reference

- Lens: leanness
- Evidence: Tone, tables, and Mermaid bullets duplicate the General Writing Rules block in references/lld-sections.md.
- Recommendation: Keep only the web-search bullet; the others are covered by the reference.

#### architecture-4 — Resolution rules omit bare-path convention preamble

- Lens: architecture
- Evidence: Bare paths like references/lld-sections.md appear in the body but resolution rules don't state they resolve from the skill root.
- Recommendation: Add: 'Bare paths (e.g. references/lld-sections.md) resolve from this skill's installed directory.'

#### customization-3 — Inline section list would shadow template override

- Lens: customization
- Evidence: If the template were made configurable, the hardcoded list on lines 37–52 would silently override it.
- Recommendation: Remove inline enumeration; let the template be authoritative.

#### determinism-3 — Readme bulk-read partially deterministic

- Lens: determinism
- Evidence: Step 3 reads every component readme with has_readme=true. The list is deterministic from the JSON but the model chooses how many to read.
- Recommendation: Consider having gather script extract readme summaries for smaller components.

#### determinism-4 — Mermaid regex pattern has no unit test

- Lens: determinism
- Evidence: The MERMAID_BLOCK_RE regex is untested — edge cases (nested fences, empty blocks) could silently pass through.
- Recommendation: Add test cases for edge-case Mermaid blocks in scripts/tests/.

#### determinism-5 — SVG URL constant defined but unused after PNG switch

- Lens: determinism
- Evidence: MERMAID_INK_SVG_URL is still defined but the script only uses the PNG endpoint. Dead code.
- Recommendation: Remove the unused MERMAID_INK_SVG_URL constant.

#### enhancement-7 — No graceful degradation when mermaid.ink is unreachable

- Lens: enhancement
- Evidence: Individual failures are handled (kept as code block) but no pre-flight check or offline fallback guidance.
- Recommendation: Add a connectivity pre-check and mention mmdc as an offline alternative in Gotchas.
