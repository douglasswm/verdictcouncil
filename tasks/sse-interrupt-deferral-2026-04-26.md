# SSE InterruptEvent integration — parked follow-ups

**Date:** 2026-04-26
**Parent plan:** `tasks/sse-interrupt-integration-2026-04-26.md`
**Status of parent:** Phases 1, 2 (option 5a), and 3 done — on `feat/sse-schema-regen` (backend) and `feat/sse-interrupt-listener` (frontend), both branched from `development`. PRs not yet opened, submodule SHAs not yet bumped at the root.

## What shipped

- Backend: regenerated `docs/sse-schema.json` (4 → 6 kinds) and added `make sse-schema-snapshot` / `make sse-schema-check` plus matching `scripts/export_sse_schema.py` / `scripts/check_sse_schema.py`. Idempotency of `publish_interrupt(...)` was already covered by `tests/integration/test_gate_review_payload.py::test_publish_interrupt_idempotent_on_replay`.
- Frontend: `useAgentStream` listens for `interrupt` frames, exposes the latest one as `interrupt` plus a `clearInterrupt()` callback. `BuildingSimulation` / `OfficeSimulation` consume both — SSE-pushed gate wins while polled `overall_status` is still in flight; polled status takes precedence once it catches up. New unit test in `src/__tests__/useAgentStream.test.jsx`. `npm run check:contract:sse` passes at 6 kinds on both sides.

## What is parked

### 1. Option 5b — thread interrupt payload into `<GateReviewPanel>`

Plan §5.5b: pass `phase_output` / `audit_summary` / `actions` through to the panel so it can skip the initial REST refetch when the interrupt arrived live, falling back to REST on cold mount (page reload mid-pause).

**Why parked:** plan §4 lists "Redesigning `<GateReviewPanel>`'s panel-internal data flow (REST fetches for phase output / audit summary)" as a non-goal. The panel currently makes 4 different gate-specific REST fanouts (case detail / evidence+timeline+witnesses+statutes / arguments+hearing-analysis / fairness-audit+hearing-analysis). Threading the SSE payload in correctly per-gate is a separate optimisation pass, and the user-visible win from 5a (~3 s → ~50 ms panel mount) is the primary criterion.

**How to apply when picking up:** add `initialPayload` prop to `<GateReviewPanel>`, branch the data-loading effect to skip the relevant REST call when payload matches the current `gateName`, and pass the prop from `BuildingSimulation` / `OfficeSimulation` (currently `interrupt?.case_id === caseId ? interrupt : null`).

### 2. Submodule bumps + PRs

Both feature branches (`feat/sse-schema-regen` on backend, `feat/sse-interrupt-listener` on frontend) are committed locally but not pushed. Per the orchestration root's trunk-based workflow, after each submodule's `feat/*` → `development` PR lands, the root needs `git add VerdictCouncil_Backend VerdictCouncil_Frontend && git commit -m "chore: bump submodules — SSE interrupt integration"` straight to `main`.

**Why parked:** opening PRs and pushing to remotes is a user-visible action; deferring per the project's "confirm before risky operations" rule.

### 3. Manual verification

Plan §6 acceptance items requiring a live stack:

- Sub-100 ms gate UI mount under healthy SSE.
- Polled fallback still mounts the panel when `/status/stream` is throttled / blocked.

**Why parked:** no live environment was running during this autonomous build pass. The unit test exercises the hook-level state transition (RED → GREEN), and `check:contract:sse` proves schema/listener parity, but the end-to-end latency claim still wants a manual demo before the work is signed off.

### 4. Adjacent issues from plan §9

- Duplicate `GateReviewPanel.jsx` (orphan at `src/components/GateReviewPanel.jsx` plus its test file) — out of scope for this plan but worth a separate cleanup pass. The active component lives at `src/components/cases/GateReviewPanel.jsx`.
- Wire `make sse-schema-check` and `make openapi-check` into the backend pre-commit hook (currently only enforced by CI). Belt-and-braces against drift like the one this plan was triggered by.

## Pickup pointer

Next session: run `npm run check:contract:sse` and `make sse-schema-check` to confirm the 6-kind contract is still healthy, then either pick up 5b (panel payload threading) or take the duplicate-`GateReviewPanel` cleanup. PR-open / submodule-bump tasks are user-confirm-first; surface them on session start rather than executing autonomously.
