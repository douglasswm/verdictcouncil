# Ticket: Gate-2 per-agent rerun is not actually targeted

**Filed**: 2026-04-26
**Source**: Risk #3 from `/Users/douglasswm/.claude/plans/use-the-langchain-and-quirky-cook.md`
**Severity**: Medium
**Scope**: `VerdictCouncil_Backend` only (with a possible UI/API copy change in `VerdictCouncil_Frontend`)
**Out of scope of**: streaming + ingestion plan (`tasks/plan-2026-04-26-streaming-and-ingestion.md`)

---

## Summary

The gate-2 rerun route enqueues `subagent` and `start_agent` and the frontend exposes per-agent rerun, but the resume worker only consults `subagent` when `notes` are present. A no-instructions rerun of `research-evidence` therefore resumes with `action=rerun` and re-runs the **whole research fan-out**, overwriting the other three research subagents' outputs.

This means the user's intent ("rerun just this one") is silently widened to "rerun all four", and three already-completed agents have their outputs replaced.

## Where

- Route enqueueing the rerun job:
  `VerdictCouncil_Backend/src/api/routes/cases.py:1854-1863`
  ```python
  if subagent is not None:
      job_payload["subagent"] = subagent
  if body.instructions:
      job_payload["instructions"] = body.instructions
      job_payload["notes"] = body.instructions
  if body.agent_name:
      job_payload["start_agent"] = body.agent_name
  ```
- Resume worker that forwards the payload — the path that only reads `subagent` when `notes` is set. (Search the workers/resume code for where `subagent` is consumed; the spec implies it gates on `notes` truthiness.)

## Reproduction

1. Run a case to gate 2 (post-research).
2. Click "Rerun" on a single research subagent (e.g. `research-evidence`) **without** entering correction notes.
3. Observe: pipeline re-runs all four research subagents (`research-evidence`, `research-precedent`, `research-statute`, `research-witness`), overwriting the three the user did not target.

Expected: only `research-evidence` re-runs; the other three subagents' outputs are preserved.

## Root cause

The resume worker's branching uses `notes` as the signal that the user wants a scoped/targeted rerun. When `notes` is empty, the worker takes the broad path and re-dispatches the full research fan-out, regardless of `subagent` / `start_agent` in the payload.

This is structurally backwards: `subagent` is the targeting field; `notes` is the corrective-instruction field. They are independent inputs.

## Two acceptable fixes

### Fix A — Thread `subagent` through and scope dispatch (preferred)

- Resume worker reads `subagent` regardless of `notes` presence.
- When `subagent` is set, the research-phase dispatch only sends to that subagent; the other three subagents' state in `CaseState` is preserved.
- When `subagent` is unset, today's full fan-out behavior is the intended fallback.
- Frontend continues to send `subagent` on per-agent rerun clicks (already does).

### Fix B — Change copy to reflect actual behavior (cheaper, worse UX)

- UI copy: "Rerun research" instead of "Rerun this agent".
- API removes per-subagent button.
- Documents that gate-2 reruns the full research layer.

Pick A unless there's a research-phase consistency reason that the four subagents must always be re-dispatched together (none documented today; the SHA history doesn't support that).

## Acceptance criteria (Fix A)

- [ ] Resume worker consumes `payload["subagent"]` independent of `payload["notes"]`.
- [ ] When `subagent` is set, only that subagent re-runs; the other three subagents' outputs in `CaseState` (and their persisted `research_*_output` fields) are unchanged.
- [ ] When `subagent` is unset (legacy / "rerun all" path), full fan-out behavior unchanged.
- [ ] No-instructions rerun of `research-evidence` produces a state where `research_evidence_output` is overwritten and `research_precedent_output`, `research_statute_output`, `research_witness_output` are byte-equal to their pre-rerun values.

## Verification

- [ ] Unit test on the resume worker: payload `{action: "rerun", subagent: "research-evidence"}` → only `research-evidence` is dispatched.
- [ ] Integration test: gate2 → click rerun on one agent → assert other three agent outputs are unchanged.
- [ ] Existing "rerun all" path still passes its current tests.

## Dependencies

None on the streaming + ingestion plan. Independent ticket. Can land any time.

## Branch

`feat/gate2-scoped-rerun` off `development` in `VerdictCouncil_Backend`.

## Files likely touched

- `VerdictCouncil_Backend/src/workers/tasks.py` (or wherever the resume worker lives — search for `_run_gate_via_legacy` and the resume-payload consumer)
- `VerdictCouncil_Backend/src/pipeline/graph/resume.py` (if dispatch lives there)
- `VerdictCouncil_Backend/tests/api/test_gate_rerun.py`
- `VerdictCouncil_Backend/tests/integration/test_gate2_scoped_rerun.py`

## Why this isn't bundled with the streaming plan

The streaming plan (`tasks/plan-2026-04-26-streaming-and-ingestion.md`) deliberately keeps blast radius small. This bug is in a different code path (resume worker / gate routing) and a different user flow (judge-driven rerun, not pipeline run-start). Bundling it would slow Q2's intake fix without any technical coupling between the two.
