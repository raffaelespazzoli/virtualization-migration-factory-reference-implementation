# Analysis Report: .skills/fleet-add-capability

Generated: 2026-08-16T13:20:00+00:00 · Schema: 2

**Grade: Fair**

> Lean, well-structured skill with clean architecture and determinism boundaries, but missing working-state and degradation paths expected of a multi-turn file-producing workflow.

The skill's primary strength is its concise encoding of repo-specific conventions (sync-wave contract, OperatorPolicy pattern, lifecycle-group decomposition, env-var-vs-overlay decision criteria) in under 1500 tokens. Its primary opportunity is adding the multi-turn patterns its sibling skills already carry: a memlog for decision persistence, a fast path for experts, and fallback routes when scripts or web search fail.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 3 |
| Medium | 3 |
| Low | 5 |

## Themes

### 1. Multi-turn resilience

- Root cause: The skill accumulates decisions across turns (capability name, method, parts, waves, targets) but has no mechanism to persist them — if context compacts or the session resumes, earlier decisions are lost.
- Fix: Add a memlog (matching sibling skills fleet-add-cluster and fleet-add-node) that captures each decision as it lands, enabling resume and audit.
- Findings:
  - `enhancement-1` Add Working-state-across-turns — `SKILL.md:entire file`

### 2. Expert and automation paths

- Root cause: The skill forces all users through the same linear flow regardless of how much information they already have. An expert who provides all inputs upfront still waits through research; an automator cannot invoke it headlessly at all.
- Fix: Gate on input completeness: if the user supplies method + parts + target in the invocation, skip research and confirm; if a structured block is provided with --headless, produce files without interaction.
- Findings:
  - `enhancement-2` Add Three-mode-architecture — `SKILL.md:entire file`
  - `enhancement-6` Remove over-applied forced research — `SKILL.md:Collect Requirements step 1`

### 3. Failure path coverage

- Root cause: Two hard dependencies (resolve_repo_structure.py, web search) have no fallback. The skill dead-ends if either fails rather than asking the user to supply what the tool could not.
- Fix: Add graceful degradation: fall back to manual component listing if the script fails; ask the user to paste docs or describe the method if web search returns nothing; confirm product identity before committing to research.
- Findings:
  - `enhancement-3` Add Graceful-degradation — `SKILL.md:On Activation + Collect Requirements`
  - `enhancement-4` Strengthen Intent-before-ingestion — `SKILL.md:Collect Requirements`

### 4. Natural-behavior ceremony

- Root cause: A few instructions describe behaviors a capable model would perform unprompted (showing summaries, reminding about .gitignore, awaiting confirmation before multi-file writes).
- Fix: Trim Post-Generation to the fleet-explain-component cross-reference; collapse Research bullets to a single sentence naming the key dimensions.
- Findings:
  - `leanness-1` Post-Generation section is mostly natural model behavior — `SKILL.md:Post-Generation`
  - `leanness-2` Research bullet list partially redundant — `SKILL.md:Collect Requirements > step 1`
  - `leanness-3` Explicit confirmation gate is natural multi-file behavior — `SKILL.md:Collect Requirements (final sentence)`

## Strengths

- Excellent token efficiency — 1411 tokens encoding deep repo-specific knowledge that a model cannot infer
- Clean intelligence-placement boundary: deterministic parsing in scripts, judgment in the prompt
- Sound progressive disclosure — everything inline, nothing carved unnecessarily, all paths resolve
- Installation-method classification table is the highest-leverage content: it prevents the most common error (wrong component pattern for the deployment mechanism)
- Gotchas section encodes institutional knowledge with real consequences (OperatorPolicy not Subscription, wave 6 reservation, namespace placement)

## Recommendations

1. Add a memlog strategy matching the sibling skills — init on activation, append decisions at each phase gate (research confirmed, structure proposed, files generated, wiring applied) (resolves: enhancement-1)
2. Add input-completeness gate: if method + lifecycle + target are present in invocation, skip research and jump to structure proposal confirmation (resolves: enhancement-2, enhancement-6)
3. Add fallback paths for script failure (manual ls + user listing) and web-search failure (user pastes docs or describes method) (resolves: enhancement-3)
4. Add product-identity confirmation before committing to web research, and orientation context when invoked without args (resolves: enhancement-4, enhancement-5)
5. Trim Post-Generation to the fleet-explain-component offer; collapse Research sub-bullets to one sentence (resolves: leanness-1, leanness-2, leanness-3)

## Experience

- **First-timer without args** — Gets blank prompt with no guidance — needs orientation (enhancement-5)
- **Expert with full spec** — Forced through redundant web research — needs fast path (enhancement-2, enhancement-6)
- **Air-gapped environment** — Web search fails with no fallback — needs degradation path (enhancement-3)
- Headless: Not currently supported — blocks automation use cases (enhancement-2)

## Findings

### High (3)

#### enhancement-1 — Add Working-state-across-turns

- Lens: enhancement
- Location: `SKILL.md:entire file`
- Evidence: Multi-turn skill accumulating decisions (name, method, parts, waves, targets) with no persistence mechanism. Sibling skills use memlogs.
- Recommendation: Add memlog init on activation and append at each phase gate (research, proposal, generation, wiring).

#### enhancement-2 — Add Three-mode-architecture

- Lens: enhancement
- Location: `SKILL.md:entire file`
- Evidence: Only supports Guided mode. No Headless for CI/automation, no fast-path for experts who already know the classification.
- Recommendation: Add input-completeness gate: if all fields present, skip to generation; if --headless flag, produce files without interaction.

#### enhancement-3 — Add Graceful-degradation

- Lens: enhancement
- Location: `SKILL.md:On Activation + Collect Requirements`
- Evidence: Two hard dependencies (resolve_repo_structure.py, web search) have no fallback path.
- Recommendation: Fall back to manual ls for script failure; ask user to paste docs for search failure.

### Medium (3)

#### leanness-1 — Post-Generation section is mostly natural model behavior

- Lens: leanness
- Location: `SKILL.md:Post-Generation`
- Evidence: "Show a summary of everything created" and "Remind the user to add secrets to .gitignore" are default behaviors a capable model would perform after generating multiple files. Only the fleet-explain-component offer is novel.
- Recommendation: Collapse to: 'After generation, offer to run `fleet-explain-component <name>` for verification.'
- Proposed smallest: Offer to run `fleet-explain-component <name>` to verify the generated readme matches reality.
- Predicted delta: Saves ~60 tokens. The summary and .gitignore reminders would still happen naturally.

#### enhancement-4 — Strengthen Intent-before-ingestion

- Lens: enhancement
- Location: `SKILL.md:Collect Requirements`
- Evidence: 'add vault' could mean HashiCorp Vault, Vault Secrets Operator, or External Secrets with Vault backend. Research starts before confirming which product.
- Recommendation: Add brief product-identity confirmation before web research.

#### enhancement-5 — Add Soft-gate-elicitation for arg-less activation

- Lens: enhancement
- Location: `SKILL.md:Collect Requirements (first line)`
- Evidence: When invoked without args, the user gets a blank prompt with no context about existing components or common additions.
- Recommendation: Present orientation: categories of capabilities, component count, and offer to suggest gaps.

### Low (5)

#### leanness-2 — Research bullet list partially redundant

- Lens: leanness
- Location: `SKILL.md:Collect Requirements > step 1`
- Evidence: Bullets for namespaces, CRDs, and dependencies are standard items any model researching an operator install would surface. The guiding bullet is the installation method classification.
- Recommendation: Trim to one sentence: 'Research the product's OpenShift installation method (OLM, helm, raw manifests), namespace requirements, and dependencies.'
- Proposed smallest: Research the product's OpenShift install method and dependencies.
- Predicted delta: Saves ~40 tokens. Marginal risk.

#### leanness-3 — Explicit confirmation gate is natural multi-file behavior

- Lens: leanness
- Location: `SKILL.md:Collect Requirements (final sentence)`
- Evidence: 'Present the proposed structure to the user for confirmation before generating any files.' — models already gate multi-file creation behind user approval.
- Recommendation: Could be cut; ~15 tokens saved with virtually zero quality difference.
- Proposed smallest: (omit entirely)
- Predicted delta: ~15 tokens. Zero output quality difference.

#### customization-1 — Hardcoded readme template path could be a scalar

- Lens: customization
- Location: `SKILL.md:Generate Files section`
- Evidence: The skill references `{fleet-common}/references/readme-template.md` as the template. An org with different doc standards would need to fork the skill.
- Recommendation: If customize.toml is ever added, expose as `readme_template` scalar. Not urgent — the template lives in fleet-common and can be edited directly.

#### customization-2 — Post-generation is an on_complete hook candidate

- Lens: customization
- Location: `SKILL.md:Post-Generation`
- Evidence: The skill produces files then suggests follow-ups — the classic 'produces artifact and stops' pattern for on_complete.
- Recommendation: If customize.toml is added, consider `on_complete = "fleet-explain-component"`. Low priority.

#### enhancement-6 — Remove over-applied forced research

- Lens: enhancement
- Location: `SKILL.md:Collect Requirements step 1`
- Evidence: Research is mandatory even when the expert user has already provided all classification info.
- Recommendation: Make research conditional on whether user input already specifies method + lifecycle + target.
