# Ticket: Prompt-pack realignment audit

**Filed**: 2026-04-26
**Source**: Follow-up to streaming/ingestion plan (`tasks/plan-2026-04-26-streaming-and-ingestion.md`)
**Severity**: Medium (quality / drift, not correctness)
**Scope**: 7 markdown files under `VerdictCouncil_Backend/prompts/` (`intake.md`, `research-{evidence,facts,witnesses,law}.md`, `synthesis.md`, `audit.md`) — the live read path via `prompt_registry.get_prompt(phase)`. The legacy `AGENT_PROMPTS` dict in `src/pipeline/graph/prompts.py` is dead weight (referenced only by 2 tests) and is out of scope.
**Out of scope of**: streaming + ingestion plan, gate-2 rerun ticket

> **Re-scoped 2026-04-26 (evening).** Original draft assumed Sprint 1 C3a hadn't shipped and that the audit target was the 9-key `AGENT_PROMPTS` literal in `prompts.py`. Re-verification against the actual code showed C3a HAS shipped — `prompt_registry.py` pulls from LangSmith with `prompts/<phase>.md` as fallback, the factory consumes 7 phase-keyed prompts (not 9 agent-keyed ones), and `argument-construction` + `hearing-analysis` are merged into `synthesis.md`. The audit checklist below applies unchanged; the file targets shift. The "conversational-mode placeholder" requirement is also DROPPED from scope: Q1.6 shipped runtime-only with no prompt-section added to `intake.md`, so there is no pattern to copy. Defer until a real pattern is needed.

---

## Summary

The streaming/ingestion plan touches **2 of the 9** agent prompts in `prompts.py` — only `case-processing` (intake) and `complexity-routing` (triage). The other 7 are untouched, but several have drifted relative to the current tool inventory, state schema, and the conversational-mode pattern that intake/triage now establish. This ticket scopes a one-pass realignment audit so the prompt pack stays coherent before the streaming rollout expands beyond the first two phases.

This is a quality/drift ticket, not a correctness bug — the prompts work today. But shipping intake/triage with a new conversational-prose pattern while the other 7 still emit JSON-only widens the inconsistency, and the longer that gap stays open the harder it is to close.

## Why now

- The streaming plan introduces a clear "conversational-mode" prompt section for intake (Q1.6) and triage (Q1.13). Without a parallel pass on the other prompts, future engineers will copy-paste the section without consistency review.
- The Sprint 1 C3a stream (per `tasks/todo.md`) already plans to push these 7 prompts to LangSmith and rewrite `prompts.py` as a registry lookup. Doing the realignment as part of that move avoids editing the file twice.
- The `intake_extraction` field added in Q2.3b is referenced only by the intake prompt today — research subagents could benefit from knowing about authoritative pre-parse data too.

## Prompts in scope

The 7 phase-keyed markdown prompts under `prompts/` (loaded by `prompt_registry.get_prompt(phase)`):

| File | Factory phase / scope | Touched by streaming plan? | Audit candidate |
|---|---|---|---|
| `prompts/intake.md` | `intake` | Yes (Q2.3b, Q2.4, Q1.6) | — |
| `prompts/research-evidence.md` | `research-evidence` (research scope `evidence`) | No | ✅ |
| `prompts/research-facts.md` | `research-facts` (scope `facts`) | No | ✅ |
| `prompts/research-witnesses.md` | `research-witnesses` (scope `witnesses`) | No | ✅ |
| `prompts/research-law.md` | `research-law` (scope `law`) | No | ✅ |
| `prompts/synthesis.md` | `synthesis` (merges legacy `argument-construction` + `hearing-analysis`) | No | ✅ |
| `prompts/audit.md` | `audit` | No | ⚠️ drift-only — see Risk |

(Triage / `complexity-routing` is no longer a standalone prompt; routing is data-driven off intake's `RoutingDecision` output.)

## Audit checklist (per prompt)

For each of the 7 prompts, verify and fix where misaligned:

- [ ] **Tool inventory match**: prompt mentions exactly the tools that `PHASE_TOOL_NAMES` / `RESEARCH_TOOL_NAMES` permit for this agent — no references to removed tools (e.g. legacy SAM tools), no missing references to current tools (`search_precedents`, `search_domain_guidance`, `cross_reference`, `timeline_construct`, `generate_questions`, `confidence_calc`).
- [ ] **State-schema match**: prompt references state fields that actually exist in `CaseState` today. Specifically check for stale references to fields renamed/removed in Sprints 1-4 (e.g. `calibration_records` was dropped per todo.md notes).
- [ ] **`raw_documents` shape**: prompts that read documents now expect `parsed_text` to be present (post-Q2.2). Update phrasing so the agent isn't told to call `parse_document` for files it can already read inline.
- [ ] **`intake_extraction` awareness**: research/synthesis prompts that consume case metadata should mention `intake_extraction` is available as authoritative pre-parse data when populated (Q2.3b adds the field; only intake prompt is updated by that task).
- [ ] **Output-schema match**: each prompt's "your output must match this shape" section matches the current `PHASE_SCHEMAS[phase]` Pydantic model. Schemas drifted in Sprint 3 / Sprint 4; spot-check vs `schemas.py`.
- [ ] **Citation contract**: research prompts have consistent guidance on `supporting_sources` / `source_ids` so the `research_join` validator doesn't see prompt-induced format drift.
- [ ] ~~**Conversational-mode placeholder**~~ — **DROPPED from scope (re-scoped 2026-04-26 evening).** Q1.6 shipped runtime-only with no prompt-section added to `intake.md`, so there is no pattern to copy. Defer until a real pattern is needed.

## Risk: audit-prompt scope

`prompts/audit.md` (the audit phase) is intentionally **not** part of the conversational-mode rollout (architecture decision A3 in the streaming plan). The audit prompt should still be checked for tool/schema drift. With the conversational-mode placeholder dropped from this ticket's scope, this risk is moot — recorded for posterity. Audit stays JSON-only.

## Acceptance criteria

- [ ] One-pass audit completed for all 7 prompts using the checklist above. Findings recorded in a single PR description with one row per prompt × checklist item.
- [ ] All identified drift fixed (or explicitly waived with rationale in the PR).
- [ ] No behavior change in the JSON-mode path: existing intake/research/synthesis/audit replay tests still pass byte-equal.
- [ ] Realigned prompts pushed back to LangSmith (`scripts/migrate_prompts_to_langsmith.py`) so registry pull and local fallback agree.
- [ ] ~~Conversational-mode placeholder~~ DROPPED — see re-scope note at top.

## Verification

- [ ] Existing replay tests pass (`pytest tests/pipeline/test_*_replay.py` — or whatever the equivalent suite is named).
- [ ] Add a contract test: for each phase, snapshot the rendered prompt and assert it mentions every tool in `PHASE_TOOL_NAMES[phase]` exactly once. Fails on tool/prompt drift in the future.
- [ ] Field-fidelity smoke: run each phase against a fixture case → assert `*_output` payload validates against its current schema.

## Dependencies

- **Soft dependency**: easiest to land **after** Q2 (so `intake_extraction` field exists in `CaseState`).
- **Hard dependency**: none.
- **Sprint 1 C3a HAS shipped** — coordination is now a workflow note, not a fold-in: edits go to `prompts/*.md`, then `scripts/migrate_prompts_to_langsmith.py` syncs the result back to LangSmith.

## Branch

`feat/prompt-pack-realignment` off `development` in `VerdictCouncil_Backend`. Single PR — the audit table doesn't decompose cleanly into smaller commits and reviewers want to see the full delta.

## Files likely touched

- `VerdictCouncil_Backend/prompts/intake.md`
- `VerdictCouncil_Backend/prompts/research-{evidence,facts,witnesses,law}.md`
- `VerdictCouncil_Backend/prompts/synthesis.md`
- `VerdictCouncil_Backend/prompts/audit.md` (drift-only, no conversational section)
- `VerdictCouncil_Backend/tests/unit/test_prompt_tool_parity.py` (new contract test)
- `VerdictCouncil_Backend/scripts/pull_prompts_from_langsmith.py` (companion to the existing push script — already added in this PR)

## Estimated scope

L (one large file, no architectural change). Realistically ~1-2 days of focused review + edits + the contract test. Not a multi-day sprint.

## Why this isn't bundled with the streaming plan

The streaming/ingestion plan deliberately keeps blast radius small: 4 surgical prompt edits in 2 prompts, all gated by the conversational-mode flag for the prose-mode addition. A 7-prompt realignment in the same PR would (a) couple a quality pass to a feature ship, (b) widen the review surface without clear benefit, (c) make the streaming rollout's regression tests harder to attribute when something breaks.
