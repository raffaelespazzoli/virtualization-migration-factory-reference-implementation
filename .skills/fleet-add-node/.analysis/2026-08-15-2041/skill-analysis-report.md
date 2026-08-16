# Analysis Report: .agents/skills/fleet-add-node

Generated: 2026-08-15T20:41:00Z · Schema: 2

**Grade: Excellent**

> Clean, lean procedural skill with correct script-boundary placement; two low-severity opportunities around edge-case coherence and headless formalization.

The skill's primary strength is its lean, outcome-driven structure that correctly delegates all deterministic work (YAML templating, kustomization patching, repo parsing) to shared scripts while reserving the prompt for user interaction and document interpretation. The only opportunities are a minor coherence gap where the Overview promises a from-scratch path that the execution instructions don't fulfill, and an optional headless entry point that the document-input mode nearly provides already.

| Severity | Count |
| --- | --- |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |

## Strengths

- Correct intelligence-placement boundary: all template substitution, file writing, and kustomization patching delegated to deterministic scripts; prompt handles only judgment (interpreting user documents, deciding what to clone, confirming results).
- Extremely lean at 1180 tokens with no ceremony, no scoring rubrics, no re-teaching of native behaviors. Every section carries domain knowledge the model would not have without instruction.
- The Gotchas section encodes six specific repo conventions (commented-out BMH pattern, type-grouped kustomization, vendor-dependent BMC URLs, shared credentials secret, envsub interpolation, same-cluster-only cloning) that prevent real errors.
- Clean linear coherence: activation discovers the cluster state, collection gathers only what differs, generation is scripted, and the user reviews before commit.

## Recommendations

1. Remove or scope the Overview's 'When no existing nodes exist' claim. The skill's execution path requires a template node (generate_node_files.py --template-node is required). Either drop the sentence or add a one-line note that fleet-add-cluster handles the first-node case. (resolves: architecture-1)
2. Optionally formalize headless readiness by noting that when all required fields are pre-supplied (via args or a single input document), the skill can skip interactive prompts and proceed directly to generation and patching. This requires no structural change—just a one-line note in the Overview or Args section. (resolves: enhancement-1)

## Experience

- **Clone from existing node** — Activation resolves cluster → lists nodes → user picks template → collects diffs → generates → patches → confirms
- **Bulk input via document** — Activation resolves cluster → user passes CSV/inventory → skill extracts fields → confirms extraction → generates → patches → confirms
- Headless: Partially adaptable: if all required fields are supplied via document or args, the skill could skip prompts, but no explicit headless entry point is declared.

## Findings

### Low (2)

#### architecture-1 — Overview promises a from-scratch path not fulfilled by execution instructions

- Lens: architecture
- Location: `SKILL.md:Overview`
- Evidence: Overview states 'When no existing nodes exist or the user prefers to start fresh, collects all fields interactively' but the Generate Files section requires --template-node (a required arg to generate_node_files.py). No fallback path exists for a cluster with zero nodes.
- Recommendation: Either remove the from-scratch claim (fleet-add-cluster handles the first-node case) or add a brief fallback noting that without a template, the model constructs YAML from the field table and the fleet-repo-structure reference.

#### enhancement-1 — Opportunity: headless entry point not formalized

- Lens: enhancement
- Location: `SKILL.md:Overview`
- Evidence: The skill accepts --cluster and --hostname args, and the Input Modes section supports document-based bulk input. Together these nearly enable headless operation, but no explicit headless path is declared.
- Recommendation: Add a one-line note that when all required fields are pre-supplied (args + document), the skill proceeds without interactive prompts. This formalizes what the document-mode already implies without adding structure.
