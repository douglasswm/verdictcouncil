# Sprint 4 — runtime cutover deferral note

Authored 2026-04-25 on `feat/sprint4-a3-interrupt-hitl`.

> **2026-04-26 update:** the worker-side runtime cutover described
> below has shipped on `feat/sprint4-a3-runtime-cutover` (backend
> PR #91). Tasks 4.A3.5, 4.A3.6, 4.A3.7, and parts of 4.A3.10–12
> (graph-level + worker-glue tests) are now done. Tasks **4.A3.9**
> (cancellation via saver-halt), **4.A3.13** (manual smoke), and
> **4.A3.14** (auditor send_back) remain parked; the legacy
> `/advance` + `/rerun` thin-wrapper conversion is also deferred
> because `_run_gate_via_legacy` keeps the legacy endpoints fully
> functional.

## What shipped this sprint

Schema and API contract layer for the interrupt()-driven HITL flow:

- **4.A3.2** — gate-node idempotency invariant locked by integration test
- **4.A3.3** — `make_gate_pause` factory enriched (phase_output / trace_id /
  gate4 audit_summary). Replay-stable.
- **4.A3.4** — builder.py wiring (no edits — factory signature unchanged)
- **4.A3.7** — `InterruptEvent` Pydantic schema + `publish_interrupt()`
  publisher with legacy `awaiting_review_gateN` UPSERT compat
- **4.A3.15** — unified `POST /cases/{id}/respond` endpoint with
  `ResumePayload` (extra="forbid" + action-vs-field invariants)

This unblocks the frontend C5b panel work — the TS `ResumePayload`
type can target a finalised Python contract.

## What is intentionally deferred

The **worker-side cutover** to saver-driven `Command(resume=...)`
semantics is not on this branch. Concretely:

- `src/workers/tasks.py::run_gate_job` still calls the legacy
  `runner.run_gate(state, gate_name, start_agent=..., extra_instructions=...)`
  path — it does **not** consume `resume_action` / `phase` /
  `subagent` / `field_corrections` from the job payload, even
  though `/respond` now writes those keys.
- `publish_interrupt()` is defined and tested, but is **not yet
  called** from any production code path. The legacy
  `PipelineProgressEvent(phase="awaiting_review")` is still the
  signal the worker emits at gate pause.
- The graph never receives `Command(resume=...)` end-to-end through
  the API → worker → graph round-trip.

## Tasks parked behind this gap

- **4.A3.5** — `/advance` endpoint refactor (becomes thin wrapper around
  `/respond` once the worker reads the new payload keys)
- **4.A3.6** — `/rerun` endpoint refactor (same)
- **4.A3.9** — cancellation via saver-halt (currently still uses Redis
  cancel-flag from `services/pipeline_events.py`)
- **4.A3.10–12** — three integration tests (`test_interrupt_resume.py`,
  `test_node_idempotency.py` extension, `test_cancellation.py`) that
  exercise the full API → worker → graph round-trip
- **4.A3.13** — manual gate-flow smoke (depends on 4.A3.10–12)
- **4.A3.14** — auditor `send_back` mechanic (`/respond` already returns
  501 for `action=send_back` with the schema final; needs worker
  `get_state_history` + `update_state` + `invoke(None, target_config)`
  wiring)

The frontend pieces (4.C5b.1–4) and the wider Sprint 4 scope
(4.A4 / 4.C4 / 4.C5 / 4.A5 / 4.D3) are **not** blocked by this gap
and proceed normally on this branch / follow-up branches.

## Why the deferral

The worker rewrite touches:

- `runner.run_gate(...)` semantics (state-manipulation → Command(resume))
- `worker_tasks.py::run_gate_job` (legacy run_gate call → ainvoke +
  publish_interrupt + state-history inspection for pauses)
- Audit-log integration (where do `judge_corrections` rows get written
  when the apply node receives notes / field_corrections?)
- Watchdog queries that key off the legacy status (kept compat via
  `publish_interrupt` legacy UPSERT, but coordination is non-trivial)
- In-flight migration semantics (cases mid-run during cutover)

Each of those is a coordination point with prior Sprint 1/2 work
(1.A1.7, 2.A2.6, 2.A2.7 in-flight migrator, 2.A2.8 saver API tests).
Doing the rewrite at the tail end of a long Sprint-4 session risks
shipping a half-rewritten worker. The contract layer landed in this
branch is sufficient to unblock the frontend; the runtime cutover
gets a focused follow-up.

## Suggested follow-up branch

`feat/sprint4-a3-runtime-cutover` — pick up from this branch, rewrite
`run_gate_job` to consume `resume_action` and call `Command(resume=...)`,
wire `publish_interrupt()` into the post-invoke path, then land the
A3.10–12 tests against the real round-trip. Estimate ~1 substantial
PR with associated test additions.
