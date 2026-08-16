# Analysis Report: .skills/fleet-explain-cluster

Generated: 2026-08-15 · Schema: 2

**Grade: Good**

> Good skill — lean and well-structured, with two medium findings on reducible ceremony (Mermaid example) and a determinism leak in live validation.

The skill delegates its core repo-parsing work to a shared script, stays well under token budget (1311 tokens), and carries genuine institutional knowledge in its Gotchas. Two medium findings share a common root: the skill does work the model already knows (teaching Mermaid syntax) or that a script could handle deterministically (parsing oc get JSON). One enhancement opportunity for headless readiness.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 1 |

## Themes

### 1. Reducible ceremony in output guidance

- Root cause: The skill teaches the model things it already knows (Mermaid syntax) and numbers steps that have no ordering dependency — both add tokens without changing behavior.
- Fix: Cut the Mermaid example block and replace with a one-clause participant-naming convention. Convert On Activation steps 2–3 to bullets since only step 1 gates on error.
- Findings:
  - `leanness-1` Mermaid example block is format teaching — `SKILL.md:Sequence Diagram (lines 58–74)`
  - `leanness-2` On Activation steps 2–3 are a false sequence — `SKILL.md:On Activation (lines 20–24)`

### 2. Live validation determinism leak

- Root cause: The optional --context path asks the model to parse raw oc JSON, count statuses, and diff lists — all deterministic operations that belong in a script.
- Fix: Extract a validate_live_cluster.py script that consumes oc output and the expected component list, returning compact JSON the model reasons over instead of raw API output.
- Findings:
  - `determinism-1` Live validation JSON parsing and comparison is deterministic work — `SKILL.md:Live Validation`

## Strengths

- Core repo parsing fully delegated to resolve_repo_structure.py with the new --cluster flag — clean intelligence placement
- Well under token budget at 1311 tokens with room to spare
- Gotchas carry genuine institutional knowledge (hub dual role, gitops-boostrap-policy typo, name-path mismatches)
- Clean composability with fleet-explain-component for drill-down
- Graceful degradation on live validation failure

## Recommendations

1. Cut the 15-line Mermaid example block and replace with a one-clause naming convention. Convert On Activation steps 2–3 to bullets. (resolves: leanness-1, leanness-2)
2. Extract a validate_live_cluster.py script for the --context path that parses oc JSON and returns compact status summary. (resolves: determinism-1)
3. Add --write-readme flag for headless invocation, with a JSON return contract. (resolves: enhancement-1)

## Findings

### Medium (3)

#### leanness-1 — Mermaid example block is format teaching

- Lens: leanness
- Location: `SKILL.md:Sequence Diagram (lines 58–74)`
- Evidence: A 15-line fenced Mermaid example teaches the model how to compose a sequence diagram — syntax it already drives fluently. The surrounding prose already specifies the outcome: a sequence diagram with wave-grouped participants, component names in messages, and the dependency chain visible.
- Recommendation: Cut the fenced example block. The prose instructions are sufficient. Add at most one clause clarifying the desired participant-alias style.
- Proposed smallest: Generate a Mermaid sequence diagram with one participant per distinct sync-wave present in the cluster. Messages from ArgoCD list the components deployed in that wave (abbreviate with '...' above five). Use `Note over` blocks to mark readiness gates between tiers. Adapt participants to the actual waves — include non-standard waves (7, 16) as distinct participants when they appear.
- Predicted delta: Minimal. The model knows Mermaid syntax and will produce a structurally equivalent diagram from the prose description alone. The only unique signal the example carries — the participant alias naming convention — can be conveyed in a phrase.

#### determinism-1 — Live validation JSON parsing and comparison is deterministic work

- Lens: determinism
- Location: `SKILL.md:Live Validation`
- Evidence: The model is instructed to run oc get applications JSON, then count totals, tally by sync status, filter degraded, and diff against the repo list. Signal-verb scan hits: count, compare, extract, check structure.
- Recommendation: Extract a validate_live_cluster.py script that consumes raw oc JSON plus the expected component list and emits compact JSON: {total, synced_healthy, degraded: [{name, status, message}], extra_in_cluster, missing_from_cluster}.

#### enhancement-1 — Add --write-readme flag for headless readiness

- Lens: enhancement
- Location: `SKILL.md:Readme Output`
- Evidence: The skill has exactly one interaction point: the readme write approval. Every other input is already a parameter. This single confirmation is the only gate between the current skill and full headless invocation.
- Recommendation: Add a --write-readme flag to Args (default false). When set, skip the offer and write directly. Define a headless JSON return: {status: 'complete', readme: 'clusters/<name>/readme.md'}.

### Low (1)

#### leanness-2 — On Activation steps 2–3 are a false sequence

- Lens: leanness
- Location: `SKILL.md:On Activation (lines 20–24)`
- Evidence: Steps 2 and 3 are independent loads with no data dependency. Only step 1 must be first because it may error and halt. Numbering implies a strict order that does not exist.
- Recommendation: Keep step 1 numbered. Convert steps 2–3 to bullets or fold into one line.
