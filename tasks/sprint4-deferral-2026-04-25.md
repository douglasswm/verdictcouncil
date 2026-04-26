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

---

# 2026-04-26 update — Sprint 4 4.A5.2 stability migration deferred

> **2026-04-26 update (resolved):** the stability migration described
> below shipped on `feat/sprint4-a5-stability-fork-migration`. The
> route now drives N forks via `services/whatif/stability.py`, the
> legacy `whatif_controller/` package is deleted, and the **A5.2
> grep-zero acceptance holds**. `tests/unit/test_stability_score.py`
> is rewritten against the fork primitive (threshold + integration
> coverage); `tests/unit/test_what_if_controller.py` is removed.

`feat/sprint4-a5-whatif-fork` shipped the LangGraph-native fork
primitive (4.A5.1) and the API-layer cross-judge isolation fix
(4.A5.4), and migrated the `/cases/{id}/what-if` background task to
use the fork. **Stability scoring (`/cases/{id}/stability`) still
calls the legacy `WhatIfController.compute_stability_score`** — that
piece of 4.A5.2 is intentionally deferred.

## What's parked

- `_run_stability_computation` in `src/api/routes/what_if.py` still
  imports `src.services.whatif_controller.controller.WhatIfController`
  and drives N parallel `runner.run_what_if` calls.
- `src/services/whatif_controller/controller.py` still exists and is
  reachable via the stability path. `controller.create_scenario` is
  unused by the route now (the route uses the fork primitive) — only
  `compute_stability_score` and `_identify_perturbations` are live.
- The **A5.2 acceptance "grep -r whatif_controller|WhatIfController
  src returns zero"** does not hold yet.

## What did ship

- `src/services/whatif/` package (fork primitive, modification
  appliers, diff engine — moved from `whatif_controller/diff_engine.py`
  to `whatif/diff.py`).
- `_run_whatif_scenario` route handler now uses `create_whatif_fork` +
  `drive_whatif_to_terminal`, reads the fork's terminal CaseState off
  the saver, and stores the fork's `thread_id` under
  `WhatIfScenario.scenario_run_id`.
- The R-10 cross-judge isolation gap on `GET
  /cases/{id}/what-if/{scenario_id}` is closed (`created_by ==
  current_user.id` 404 check).

## Why deferred

Stability scoring is a multi-fork aggregation (N=5 perturbations) with
its own asyncio.gather concurrency model and a separate test surface
(`tests/unit/test_stability_score.py`, 200+ LOC of mocked-runner
contract). Migrating it requires:

1. Per-perturbation `create_whatif_fork` + `drive_whatif_to_terminal`
   parallelisation (the fork primitive returns a `thread_id`; driving
   N forks to terminal in parallel needs a fan-out pattern).
2. Re-keying the diff calls to read terminal state from the saver per
   fork rather than from the runner's return value.
3. Rewriting `tests/unit/test_stability_score.py` since the mocked
   runner contract is incompatible with the saver-driven fork.

That's S/M of work, lands cleanly in its own branch, and does not
block the frontend C5b work. Park behind:

## Suggested follow-up branch

`feat/sprint4-a5-stability-fork-migration` — port
`compute_stability_score` to drive N forks via the new primitive,
delete `src/services/whatif_controller/` outright (verifying the
A5.2 grep-zero criterion), and rewrite `test_stability_score.py`
against the fork-based contract.

---

# 2026-04-26 close-out — Sprint 4 feature-complete; manual-ops parked

All Sprint 4 coding tasks landed across PRs #88–#96 (backend) and
#152–#160 (frontend). Three acceptance criteria are deferred because
they require a deployed environment that this offline session can't
exercise. They are not "incomplete work" — they are smoke-tests
gating the next deploy.

## Manual-ops parked

- **4.C5.3** — Sentry → LangSmith link verification. The wiring
  (`src/sentry.js` + `useAgentStream` `tagSession` call) is unit-tested
  but the LangSmith URL pattern in `langsmithTraceUrl()` is best-effort
  against the public UI as of 2026-04. Confirm with a real DSN in
  staging: trigger a frontend error → check the Sentry event has
  `backend_trace_id` + `backend_trace_url` tags → click the URL and
  confirm it opens the matching backend run. If the URL pattern has
  shifted, edit `src/sentry.js::langsmithTraceUrl`.

- **4.C5b.5** — end-to-end gate-flow smoke. Drive a real case through
  all four gates with the new `<GateReviewPanel>` mounted on
  `InterruptEvent` SSE frames. Submit one of each `ResumePayload`
  variant (advance / rerun / halt / send_back) and confirm the
  worker resumes the graph correctly per Sprint-4 4.A3 cutover.

- **4.A5.3 manual smoke** — the deliverable says "open gate 3, click
  'What if we excluded the police body cam?', confirm fork launches
  and renders comparison." The hook + modal + compare view are
  unit-tested with mocks; needs a running backend to confirm the
  scenario-poll cadence + LangSmith fork-trace link are correct.

- **4.D3.4** — eval-gate meta-test. Open a PR with a deliberately
  broken prompt → confirm `eval.yml` fails the >5% drop check.
  Open the same PR with the `eval/skip-regression` label → confirm
  it merges. Needs a real LangSmith baseline experiment.

## Why parked, not blocking

Each item is a single manual click-through against a deployed stack.
None of them require code changes (or if they reveal a bug, the fix
is a small follow-up). The Sprint-5 cloud-deployment work
(`5.DEP.1`–`5.DEP.11`) provides exactly the environment these smokes
need — running them after Sprint 5 batches the manual ops behind one
deploy instead of three.

## Suggested order post-Sprint-5

1. After `5.DEP.5` (LangGraph Platform deploy succeeds): run **4.C5.3**
   and **4.A5.3 manual smoke** against the deployed BFF + LangSmith.
2. After `5.DEP.6` (Vercel frontend deploy succeeds): run **4.C5b.5**
   end-to-end with judge auth.
3. After `5.DEP.7` (eval baseline pinned in cloud LangSmith project):
   run **4.D3.4** with a throwaway PR.

If any smoke uncovers a behavioural gap, file it as a Sprint-5
follow-up (P1/P2) rather than re-opening Sprint 4.
