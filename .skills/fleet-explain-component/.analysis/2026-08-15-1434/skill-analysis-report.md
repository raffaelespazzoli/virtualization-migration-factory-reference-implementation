# Analysis Report: .skills/fleet-explain-component

Generated: 2026-08-15 · Schema: 2

**Grade: Fair**

> Lean, well-structured one-shot utility with strong script/prompt separation; the primary gap is no headless mode for batch automation and no graceful degradation when dependencies are absent.

The skill is impressively lean at 1212 tokens with clear outcome-driven structure and excellent delegation of deterministic parsing to shared scripts. Its primary weakness is that it was built interactive-only — no headless path for batch readme generation across all components, no fallback when web search or scripts are unavailable, and repo-specific product mappings hardcoded rather than externalized.

| Severity | Count |
| --- | --- |
| Critical | 1 |
| High | 4 |
| Medium | 8 |
| Low | 10 |

## Themes

### 1. No automation path

- Root cause: The skill was built interactive-only without considering that batch readme generation across all 52 components is a natural use case for one of five fleet workflows sharing common scripts.
- Fix: Add three-mode architecture: Guided (current), Yolo (auto-approve readme writes), Headless (suppress chat, emit structured output, exit). Make readme generation opt-in in guided mode, automatic in yolo/headless.
- Findings:
  - `enhancement-1` No headless mode — blocks automation entirely — `SKILL.md:Readme Generation`
  - `customization-5` Approval gate not bypassable for automation — `SKILL.md:Readme Generation`
  - `enhancement-5` Dual-output is unconditional — readme generation is forced — `SKILL.md:Readme Generation`

### 2. Hardcoded repo-specific data without customization surface

- Root cause: Product mappings, template path, and web-search behavior are baked into the skill body. This forces a fork for any repo that uses a different readme format, has different component-to-product mappings, or operates in an air-gapped environment.
- Fix: Add a customize.toml with: product_mappings path (externalize the 5-entry table to a CSV/JSON data file), readme_template path, web_search boolean default true. SKILL.md reads these as {workflow.<name>}.
- Findings:
  - `customization-1` Product-mapping table hardcoded in skill body — `SKILL.md:Product Identification`
  - `customization-2` Readme template path hardcoded — `SKILL.md:Readme Generation`
  - `customization-4` Web-search behavior not toggleable — `SKILL.md:Product Identification`
  - `determinism-2` Hardcoded product-mapping lookup table in prompt — `SKILL.md:Product Identification`

### 3. No graceful degradation

- Root cause: Every dependency (Python scripts, web search, fleet-common references) is treated as mandatory with no fallback. A hostile environment (air-gapped, missing fleet-common, script error) produces unhandled failures.
- Fix: Add a Graceful degradation clause: script failures fall back to manual file listing; web search failures fall back to manifest-only analysis with a 'locally-derived' marker; missing references proceed without architectural context and note the gap.
- Findings:
  - `enhancement-2` No graceful degradation for dependency failures — `SKILL.md:On Activation`
  - `enhancement-6` Web search is mandated with no offline fallback — `SKILL.md:Product Identification`

### 4. Structural compliance nits

- Root cause: Minor heading-level violation and an unused resolution-rule entry from the build process.
- Fix: Change `# Overview` to `## Overview`, remove unused `{skill-root}` resolution rule, unnumber step 4 (fleet-repo-structure.md load is order-independent).
- Findings:
  - `architecture-1` Overview uses h1 instead of h2 — `SKILL.md:line 6`
  - `architecture-2` Unused resolution-rule entry {skill-root} — `SKILL.md:Resolution rules`
  - `leanness-5` On Activation step 4 is not sequentially dependent — `SKILL.md:On Activation step 4`

## Strengths

- Excellent script/prompt boundary — all deterministic parsing delegated to shared Python scripts that return structured JSON
- Lean at 1212 tokens (well under 1500 desired budget) with no waste patterns or back-references
- Institutional knowledge (Gotchas section) captures the non-derivable repo-specific edge cases a bare model would miss
- Domain-specific Mermaid examples calibrate diagram output for this repo's relationship types
- Outcome-driven structure — tells the model what to produce, not a step-by-step march

## Recommendations

1. Add three-mode architecture (guided/yolo/headless) with structured output in headless mode (resolves: enhancement-1, customization-5, enhancement-5)
2. Add customize.toml with product_mappings, readme_template, and web_search scalars; externalize product mappings to a data file (resolves: customization-1, customization-2, customization-4, determinism-2)
3. Add graceful degradation for each dependency (scripts, web search, references) (resolves: enhancement-2, enhancement-6)
4. Fix heading level (# → ##), remove unused {skill-root}, unnumber step 4 (resolves: architecture-1, architecture-2, leanness-5)
5. Add a list_component_resources.py script to fleet-common that enumerates manifests and extracts resource metadata as JSON (resolves: determinism-1)

## Experience

- **Expert with clear intent** — Invokes with component name → gets full explanation + readme proposal → approves or declines. Works well.
- **First-timer** — Invokes → gets dense technical output with repo-specific terminology and no orientation. Workable but could be smoother.
- **Automator (batch)** — Cannot invoke headless. Blocked entirely by approval gate and chat-only output.
- **Air-gapped environment** — Web search fails with no fallback. Partial explanation produced but product identification is weak.
- Headless: Not supported. Adding headless mode is the single highest-leverage enhancement given the batch-orchestration context.

## Findings

### Critical (1)

#### enhancement-1 — No headless mode — blocks automation entirely

- Location: `SKILL.md:Readme Generation`
- Evidence: The skill mandates 'ask for approval before writing' with no way to bypass it. An automator wanting to batch-generate readmes for all components hits a blocking prompt on every invocation. There is no --headless or --auto-approve path, and no structured output contract.
- Recommendation: Add Three-mode architecture. Guided (current behavior), Yolo (skip approval, write readme directly), Headless (suppress chat explanation, emit only the readme as a structured artifact to a known path, exit zero/non-zero).

### High (4)

#### enhancement-2 — No graceful degradation for dependency failures

- Location: `SKILL.md:On Activation`
- Evidence: Step 1 handles 'component not found' but nothing else. If Python isn't available, if find_component_siblings.py has a runtime error, if fleet-common/references/fleet-repo-structure.md is missing, or if the web search returns nothing, the skill has no fallback path.
- Recommendation: Add a Graceful degradation section. For each dependency name the fallback: script failures → manual directory listing; missing references → proceed without; web search failure → manifest-only analysis marked as 'locally-derived'.

#### enhancement-3 — No intent-before-ingestion — wrong-intent user gets a wall of output

- Location: `SKILL.md:On Activation → Explanation`
- Evidence: The skill goes from activation straight to running scripts, reading all YAML manifests, and web-searching before producing any output. A user who says 'what does metallb do' wanting a two-sentence answer gets a multi-section explanation with Mermaid diagrams and a readme proposal.
- Recommendation: Add a single soft gate after resolving the lifecycle group: 'Found <N> parts in the <name> lifecycle group. I'll produce a full explanation with diagrams and a readme. Want the full treatment, or just a quick summary?'

#### architecture-1 — Overview uses h1 instead of h2

- Location: `SKILL.md:line 6`
- Evidence: Skill begins with `# Overview` (h1). Pre-pass flagged 'Missing ## Overview section'. In BMad skill structure the frontmatter name serves as the implicit h1; body sections must start at h2.
- Recommendation: Change `# Overview` to `## Overview`.

#### customization-1 — Product-mapping table hardcoded in skill body

- Location: `SKILL.md:Product Identification`
- Evidence: Five component-to-product mappings are embedded as prose in the skill. Every new component requires editing SKILL.md itself.
- Recommendation: Extract mappings to a data file (CSV or JSON) referenced via customize.toml. The skill reads the file at runtime; repos extend it without touching the skill.

### Medium (8)

#### enhancement-4 — No plan-validate-execute — user can't course-correct before heavy work

- Location: `SKILL.md:On Activation → Explanation`
- Evidence: The skill reads all YAML manifests, loads architectural context, does web searches, generates diagrams, and generates a readme — all before the user sees anything. If the sibling resolution pulled in the wrong group, all that work is wasted.
- Recommendation: After step 2, emit a brief plan showing the resolved group and intended outputs. One confirmation before the expensive steps.

#### enhancement-5 — Dual-output is unconditional — readme generation is forced

- Location: `SKILL.md:Readme Generation`
- Evidence: The Readme Generation section always fires. An expert who just wants to understand a component before debugging doesn't want a readme proposal.
- Recommendation: Make readme generation opt-in in guided mode. After the explanation, ask: 'Want me to generate/update the readme?' In headless mode, always generate.

#### enhancement-6 — Web search is mandated with no offline fallback

- Location: `SKILL.md:Product Identification`
- Evidence: 'Web-search for the upstream project documentation' is an imperative with no fallback. In a disconnected environment the skill stalls or produces an error.
- Recommendation: Reframe as best-effort: 'Web-search if available. If unavailable, use known-mappings and manifest analysis. Mark product identification as locally-derived when web sources weren't consulted.'

#### customization-2 — Readme template path hardcoded

- Location: `SKILL.md:Readme Generation`
- Evidence: Template fixed to `{fleet-common}/references/readme-template.md`. A repo wanting a different format must fork.
- Recommendation: Add customize.toml [paths].readme_template defaulting to the current path.

#### customization-3 — No on_complete hook after readme write

- Location: `SKILL.md:Readme Generation (end)`
- Evidence: After readme is written, no mechanism to chain follow-up actions (lint, git stage, update index).
- Recommendation: Add customize.toml [hooks].on_complete supporting a post-write action.

#### customization-4 — Web-search behavior not toggleable

- Location: `SKILL.md:Product Identification`
- Evidence: Unconditional web search. Air-gapped or policy-restricted environments fail.
- Recommendation: Add customize.toml [workflow].web_search = true (default). When false, skip search and rely on manifest analysis and product-mapping data file.

#### determinism-1 — Prompt enumerates and parses YAML manifests

- Location: `SKILL.md:Step 3 (On Activation)`
- Evidence: Step 3 instructs the prompt to 'Read all YAML manifests in each part directory' and 'Understand what Kubernetes resources are created.' Enumerating files and extracting resource kind/apiVersion/name is deterministic plumbing.
- Recommendation: Add a list_component_resources.py script that walks part dirs, parses YAML, and returns JSON [{file, kind, apiVersion, name, namespace, annotations}]. The prompt interprets meaning; the script handles fetch-and-parse.

#### leanness-1 — Sequence diagram example is calibration weight without proportional return

- Location: `SKILL.md:Diagrams`
- Evidence: Two full Mermaid examples (~150 tokens). The architecture diagram concretely calibrates the expected style. The sequence diagram demonstrates a standard Mermaid pattern models produce correctly without demonstration.
- Recommendation: Cut the sequence diagram example. Keep the architecture diagram example and append: 'Also generate a sequence diagram when multi-part sync-wave ordering is non-obvious.'

### Low (10)

#### leanness-2 — Product Identification sources bullets teach what model would naturally do

- Location: `SKILL.md:Product Identification`
- Evidence: First two bullets describe inference steps a capable model would take automatically after reading operator-policy.yaml.
- Recommendation: Collapse into lead-in: 'Map the component to its upstream project using OperatorPolicy metadata and these repo-specific mappings:'

#### leanness-3 — Component Description first bullet fails core test

- Location: `SKILL.md:Component Description`
- Evidence: 'What the product/project does (from upstream docs, 2-3 sentences)' instructs what a model asked to 'explain a component' would do without prompting.
- Recommendation: Remove the bullet. The product description is implied by the overall instruction.

#### leanness-4 — Gotcha duplicates AGENTS.md workspace rule

- Location: `SKILL.md:Gotchas bullet 2`
- Evidence: The gitops-boostrap-policy typo gotcha is identical to the always-applied workspace rule in AGENTS.md.
- Recommendation: Delete the bullet. The workspace rule covers it unconditionally.

#### leanness-5 — On Activation step 4 is not sequentially dependent

- Location: `SKILL.md:On Activation step 4`
- Evidence: Step 4 ('Load fleet-repo-structure.md') has no dependency on steps 1-3. Placing it in a numbered sequence implies a dependency that doesn't exist.
- Recommendation: Move to Overview or a context note. Reserve numbering for truly ordered steps 1-3.

#### architecture-2 — Unused resolution-rule entry {skill-root}

- Location: `SKILL.md:Resolution rules`
- Evidence: `{skill-root}` is defined but never referenced anywhere in the skill body.
- Recommendation: Remove or add a reference that uses it.

#### determinism-2 — Hardcoded product-mapping lookup table in prompt

- Location: `SKILL.md:Product Identification`
- Evidence: Five key→value mappings embedded as prose. This is a deterministic lookup that should be a data file.
- Recommendation: Move to a data file (fleet-common/references/product-mappings.json). Have the skill load it at runtime.

#### determinism-3 — Readme existence re-checked when script already returns it

- Location: `SKILL.md:Readme Generation`
- Evidence: find_component_siblings.py already returns readme_path. The Readme Generation section tells the prompt to 'check if the component has a readme.md' — repeating a deterministic check the script already performed.
- Recommendation: Reword to reference the script output: 'Using the readme_path from the siblings output, determine whether a readme exists.'

#### customization-5 — Approval gate not bypassable for automation

- Location: `SKILL.md:Readme Generation`
- Evidence: Mandates 'ask for approval before writing.' In headless or batch-mode invocations, blocks on interactive confirmation.
- Recommendation: Add customize.toml [workflow].auto_approve = false (default). When true, write readme immediately.

#### enhancement-7 — No open-floor orientation for first-timers

- Location: `SKILL.md:Overview`
- Evidence: First-timer receives dense technical explanation using repo-specific terminology (lifecycle groups, sync-waves) without introduction.
- Recommendation: Add a brief orientation block at the start of Explanation output: 'This repo organizes components into lifecycle groups...'

#### enhancement-8 — Capture-don't-interrupt opportunity missed

- Location: `SKILL.md:Explanation → Gotchas`
- Evidence: During manifest analysis, the skill may encounter anomalies (missing CRDs, uncommented blocks, namespace mismatches). Currently no mechanism to capture and present these separately from the main explanation.
- Recommendation: Add an 'observations' capture: anomalies collected during analysis get presented in a separate section after the explanation rather than interrupting the narrative.
