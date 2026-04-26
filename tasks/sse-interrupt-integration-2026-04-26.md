# SSE InterruptEvent integration gap

**Date:** 2026-04-26
**Surfaced by:** MLflow scrub (this conversation) — regenerating `docs/sse-schema.json` from the Pydantic source exposed two event kinds (`interrupt`, `narration`) that were declared backend-side and never reflected in the committed schema snapshot. `narration` already has a frontend listener; `interrupt` does not.
**Severity:** Low — not user-facing today (polled-status fallback masks it). Fragile under load and on reconnects, and likely-broken for future Sprint 4/5 latency or audit-trail work.

---

## 1. Problem

The backend pushes `InterruptEvent` SSE frames at every HITL gate pause (Sprint 4 4.A3.7 / 4.A3.8). The frontend never registers an `addEventListener('interrupt', ...)` on its `EventSource`, so those frames are dropped on the floor by the browser. The gate UI works only because `publish_interrupt(...)` *also* writes a legacy-compat `cases.status = awaiting_review_gateN` field, which `currentGateFromStatus(overallStatus)` reads off the polled `/cases/{id}/status` endpoint.

Net result:
- Gate UI mounts on the next `/status` poll tick (delay = `VITE_PIPELINE_STATUS_POLL_MS`, default 3000ms) instead of immediately.
- Interrupt-frame metadata (`actions`, `phase_output`, `audit_summary`, `trace_id`, `ts`) is *never* delivered to the React tree — the panel re-fetches phase output via REST instead of consuming the event payload that was already pushed.
- The SSE-vs-poll seam is the silent kind: looks fine when both are healthy, breaks subtly when poll falls behind or the legacy-compat write races the SSE publish.
- Schema/consumer drift is masked because the committed `docs/sse-schema.json` snapshot was never regenerated when `InterruptEvent` was added — `npm run check:contract:sse` silently passed.

## 2. Evidence

### Backend declares and emits the event
- `VerdictCouncil_Backend/src/api/schemas/pipeline_events.py:106-150` — `InterruptEvent` defined; included in the `Event` discriminated union (`Field(discriminator="kind")`).
- `VerdictCouncil_Backend/src/services/pipeline_events.py:111` — `publish_interrupt(...)` async helper.
- `VerdictCouncil_Backend/src/api/routes/cases.py:1448` — published from the `/cases/{id}/respond` resume path.
- `VerdictCouncil_Backend/src/workers/tasks.py:233` — published from the worker after each gate-pause.
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/gates.py:30` and `src/pipeline/graph/resume.py:25,295` — narrate the design intent ("4.C5b mounts on receipt").

### Frontend declares the type but never listens
- `VerdictCouncil_Frontend/src/lib/sseEvents.ts:61-84` — `InterruptEvent` type; member of `SseEvent` union at line 91.
- `VerdictCouncil_Frontend/src/hooks/useAgentStream.js:93-99` — registers `progress`, `agent`, `narration`, `heartbeat`, `auth_expiring`. **No `addEventListener('interrupt', ...)` anywhere in `src/`.**
- `VerdictCouncil_Frontend/src/pages/visualizations/BuildingSimulation.jsx:472,614-617` — `currentGate = currentGateFromStatus(overallStatus)` derives the panel from the polled status field; gate UI mounts only as a side-effect of the polling tick.
- `VerdictCouncil_Frontend/src/components/cases/GateReviewPanel.jsx` — the active component re-fetches phase output via REST instead of consuming the interrupt payload that the backend already pushed.

### Schema snapshot was stale
- Committed `VerdictCouncil_Backend/docs/sse-schema.json` (pre-MLflow scrub) declared 4 kinds: `agent`, `auth_expiring`, `heartbeat`, `progress`. Pydantic source has 6: those four plus `interrupt` and `narration`.
- `VerdictCouncil_Frontend/scripts/check-api-contract-sse.mjs` is the right tool, but it was checking the union against a stale snapshot, so the gap never tripped CI.

## 3. Goals

1. The frontend handles `interrupt` SSE frames as the primary trigger for gate-pause UI, with the polled `overall_status` retained only as a reconnect/recovery fallback.
2. `docs/sse-schema.json` matches the Pydantic source and stays that way under CI.
3. `npm run check:contract:sse` returns to a meaningful pass — schema and listener set match, both at the current 6 kinds.
4. No regression: existing gate workflow continues to work for already-paused cases (cold reload, mid-pause refresh).

## 4. Non-goals

- Reworking the legacy-compat `cases.status = awaiting_review_gateN` field. The polled fallback is intentional belt-and-braces and stays.
- Redesigning `<GateReviewPanel>`'s panel-internal data flow (REST fetches for phase output / audit summary). The interrupt payload carries that data, but consuming it is a separate optimisation.
- Moving narration UI off polling — narration is already SSE-wired (`useAgentStream.js:95`).

## 5. Approach

Order matters. Backend changes first so the frontend has a real source of truth for testing.

### Phase 1 — Backend (submodule, `feat/sse-schema-regen` from `development`)

1. **Regenerate `docs/sse-schema.json`** from the Pydantic source:
   ```bash
   .venv/bin/python -c "
   import json
   from src.api.schemas.pipeline_events import Event
   from pydantic import TypeAdapter
   print(json.dumps(TypeAdapter(Event).json_schema(), indent=2))
   " > docs/sse-schema.json
   ```
   This adds `InterruptEvent` and `NarrationEvent` defs and pushes the union from 4 to 6 kinds.

2. **Add a CI guard** so the snapshot can never drift again. New Make target:
   ```
   openapi-check:: openapi-check ## (existing) verify openapi.json is current
   sse-schema-check: ## verify docs/sse-schema.json matches Pydantic source
   	@.venv/bin/python -m scripts.check_sse_schema
   ```
   Where `scripts/check_sse_schema.py` regenerates in-memory and `diff`s against the committed file. Fail nonzero on drift. Wire into the existing pre-merge CI step alongside `openapi-check`.

3. **Optional but cheap:** make `publish_interrupt` idempotent on its legacy-compat write (already mostly is per the inline comment at `src/services/pipeline_events.py:133`); confirm with a unit test that two replays produce identical SSE frames + identical `cases.status` writes.

### Phase 2 — Frontend (submodule, `feat/sse-interrupt-listener` from `development`)

4. **Add the interrupt listener** in `src/hooks/useAgentStream.js` after line 99:
   ```js
   es.addEventListener('interrupt', handleInterrupt);
   ```
   With a new `handleInterrupt(event)` that parses `JSON.parse(event.data)` as `InterruptEvent`, then either:
   - **5a (minimal):** sets a `currentInterrupt` ref/state on the hook's return value, which `BuildingSimulation.jsx` and `OfficeSimulation.jsx` consume to mount `<GateReviewPanel gateName={interrupt.gate}>` *immediately* without waiting for the next `/status` poll. Polled `overallStatus` remains the source of truth on reconnect / first-mount; SSE just shortcuts the steady-state delay.
   - **5b (preferred, slightly more work):** same as 5a, plus pass the `phase_output` / `audit_summary` / `actions` payload through to `<GateReviewPanel>` so it skips its initial REST refetch when the interrupt arrived live. Falls back to REST when the panel mounts cold (page reload mid-pause).

5. **Update `useAgentStream` tests** (`src/__tests__/useAgentStream.test.jsx`) to add a case that fires a mock `interrupt` event and asserts the consumer state updates.

6. **Bump submodule SHAs at the orchestration root** after both PRs merge to `development` (per gitflow at `CLAUDE.md` lines 14-29).

### Phase 3 — Verification

7. `cd VerdictCouncil_Frontend && npm run check:contract:sse` → must show:
   ```
   Schema kinds (6): agent, auth_expiring, heartbeat, interrupt, narration, progress
   Client kinds (6): agent, auth_expiring, heartbeat, interrupt, narration, progress
   ✓ SSE contract OK
   ```

8. Manual test: run a case to a gate pause, watch the Network tab — gate UI should mount within ~50ms of the SSE frame, not on the next 3-second poll boundary.

9. Manual test: simulate SSE outage (Chrome DevTools Network → throttle / block `/status/stream`) — gate UI should still mount, just on the polling cadence (proves the fallback still works).

## 6. Acceptance criteria

- [ ] Backend `docs/sse-schema.json` regenerated; lists 6 kinds.
- [ ] Backend `make sse-schema-check` exists and fails on schema drift.
- [ ] Frontend `useAgentStream.js` registers `addEventListener('interrupt', ...)`.
- [ ] Frontend test exercises the interrupt path with a mock `EventSource`.
- [ ] `npm run check:contract:sse` passes with 6 kinds on both sides.
- [ ] Manual gate pause demos sub-100ms UI mount under healthy SSE.
- [ ] Manual SSE-outage demo confirms the polled fallback still mounts the panel.

## 7. Risks

- **Double-mount on reconnect:** If SSE delivers an `interrupt` while the polled status already advanced the gate UI, both paths could try to mount. Mitigation: `<GateReviewPanel>` is keyed off `currentGate` (gate name), so React reconciles instead of double-mounting; verify `onAdvanced={retry}` doesn't fire twice.
- **Out-of-order frames on reconnect:** SSE last-event-id semantics are not currently used. If a stale `interrupt` is replayed after the case advanced past that gate, the UI could briefly show the wrong gate. Mitigation: gate the SSE handler on `event.case_id === caseId && event.gate === expectedNextGate(overallStatus)`. Polled status takes precedence on tie.
- **Schema-check CI noise:** Regenerating schema introduces a new failure surface. Pydantic field-order changes or `description` edits will trip it. Acceptable trade for catching real drift; if it gets noisy, normalise via `json.dumps(..., sort_keys=True)` in the check.

## 8. Estimate

- Phase 1: 1-2 hours (schema regen + Make target + tiny check script).
- Phase 2: 3-5 hours (listener + state plumbing + test; longer if going with 5b and threading the payload through).
- Phase 3: 30 min manual verification.
- Total: half a day to a day.

## 9. Adjacent issues uncovered (flag-only, not in this plan)

- **Duplicate `GateReviewPanel`.** Two implementations exist:
  - `src/components/cases/GateReviewPanel.jsx` — actively imported by both `BuildingSimulation.jsx` and `OfficeSimulation.jsx`.
  - `src/components/GateReviewPanel.jsx` + `GateReviewPanel.test.jsx` — orphan; the test file imports the orphan, not the live component, so the test suite is effectively testing dead code.

  Worth a separate cleanup pass to delete the orphan and either move the tests over to the live component or rewrite them.

- **`docs/sse-schema.json` was the only artefact catching contract drift, and it was stale.** Beyond the new `make sse-schema-check`, consider running it (and `openapi-check`) in the pre-commit hook, not just CI.
