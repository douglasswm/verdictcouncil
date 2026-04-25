# Gate-node idempotency audit (Sprint 4 4.A3.1)

- Run: 2026-04-25
- Surveyed: every node touched by a gate boundary in the post-Sprint-1
  topology (`src/pipeline/graph/nodes/`)

## Why this matters

`langgraph.types.interrupt()` re-runs the entire node from the top on
every resume. Any DB INSERT, external API call, message publish, or
counter increment that runs **before** `interrupt()` will fire again
each time the judge resumes, producing duplicates. Acceptance for
4.A3.2 is "zero non-idempotent writes before `interrupt()`."

The Sprint 1 1.A1.7 rewrite deleted the legacy 9-agent gate nodes
(`case_processing.py`, `complexity_routing.py`, `gate2_join.py`,
`argument_construction.py`, `hearing_analysis.py`,
`hearing_governance.py` — all removed in commit `c2a891a`). The audit
target is therefore the current minimal gate factories plus the only
remaining node that emits a side effect.

## Files in scope (post-Sprint-1)

| File | Role | Verdict |
|---|---|---|
| `src/pipeline/graph/nodes/gates.py` `make_gate_pause` | Calls `interrupt()` and stores the resume value. | **Clean.** No writes before `interrupt()`. The single state mutation (`{"pending_action": decision}`) happens after the resume returns, so duplication is impossible. |
| `src/pipeline/graph/nodes/gates.py` `make_gate_apply` | Reads `pending_action`, returns a `Command`. | **Clean.** Pure function. No DB I/O, no SSE, no external calls. |
| `src/pipeline/graph/nodes/terminal.py` `terminal` | Emits the run-level terminal SSE via `publish_progress`. | **No interrupt boundary inside.** `terminal` is reached as a goto target from a gate-apply (`halt` action), not from inside an `interrupt()`-bearing node. The publish is idempotent at the consumer (Redis pub/sub fan-out, no INSERT) and the node itself is reached at most once per run because `halt` is set exactly once. |

## Files mentioned in the original 4.A3.1 plan

`case_processing.py`, `complexity_routing.py`, `gate2_join.py`,
`argument_construction.py`, `hearing_analysis.py`,
`hearing_governance.py` — **deleted in 1.A1.6 / 1.A1.7**. The plan was
written against the legacy 9-agent topology; Sprint 1 collapsed those
into `make_phase_node(...)` / `make_research_subagent(...)` plus the
two-line gate factories above. There is nothing left to audit in the
named files.

## Phase nodes (`make_phase_node`, `make_research_subagent`)

These are **not** gate-end nodes — gates wrap them via the `pause` →
`apply` pair. The phase nodes themselves do not call `interrupt()`,
so the re-entry hazard does not apply. Side-effect surface inside
phase nodes (audit middleware writes via `audit_tool_call`, SSE events
via `sse_tool_emitter`) is bounded by LangChain's middleware layer,
which runs once per tool call regardless of node re-entry.

If a future Sprint 4.A3 task moves `interrupt()` *inside* a phase node,
this audit must be redone. Today, every `interrupt()` site is a
dedicated pause node that does nothing else.

## Verdict

**No non-idempotent writes occur before `interrupt()` in the current
topology.** 4.A3.2 has no INSERTs to convert to UPSERTs; its work
materialises only when 4.A3.3 introduces the full pause/apply payloads
that include `awaiting_review_gateN` status writes — that's where the
idempotency contract becomes load-bearing.

## Recommendation for 4.A3.3

When the full review surface lands, follow these rules:

1. **Snapshot writes (gate snapshot, status row) must come BEFORE
   `interrupt()`** but use UPSERT (composite primary key on
   `(case_id, gate)`), so a re-fired snapshot overwrites in place.
2. **Audit-log entries that record "judge decided X" must come AFTER
   the resume returns**, in the apply node, not the pause node.
3. **Any `publish_progress` emitted from the pause node must be
   keyed on `(case_id, gate, "review_required")` at the consumer**
   so re-emission is deduplicated downstream.

These mirror the LangGraph reference patterns used by
`PostgresSaver`-backed HITL apps and avoid the double-write trap.
