# Tasks

## Adversarial Review Findings Artifact

- [x] Review the pipeline RAG observability overhaul plan and task breakdown.
- [x] Capture seven adversarial findings with priority, anchors, and required fixes.
- [x] Write findings to `tasks/adversarial-review-findings-2026-04-25-pipeline-rag-observability.md`.
- [x] Verify the findings file renders as a standalone review artifact.

### Review

- Created a dedicated markdown review artifact instead of modifying the implementation plan directly.
- Flagged two P0 blockers before Sprint 1: dependency migration gap and HITL gate-stub risk.
- Captured P1/P2 issues covering LangGraph `Send` wiring, trace propagation across the outbox, missing resume endpoint, audit table integrity, and agent tool scoping.
- Follow-up: the plan should be revised before Sprint 1 execution.

## Update Deep Research Review Plan

- [x] Review requested findings and relevant LangGraph skill guidance.
- [x] Update `/Users/douglasswm/.claude/plans/do-deep-research-and-concurrent-walrus.md` to incorporate the six findings.
- [x] Verify the plan no longer contains stale or unsafe recommendations.
- [x] Document review results.

### Review

- Updated retry-count guidance to avoid incrementing inside `_run_agent_node` under `count < _MAX_RETRIES` semantics; routed counter mutation is now tied to the retry routing boundary.
- Replaced SSE-disconnect cancellation guidance with an explicit authorized cancel path and verification that plain disconnects do not cancel jobs.
- Added LangGraph HITL/checkpointer caveats about node re-execution and idempotent side effects before any future `interrupt()` migration.
- Corrected stream auth-expiry wording to reflect fixed SSE request headers.
- Narrowed formatter guidance to the remaining `AgentStreamPanel` gap.
- Strengthened retry verification to cover compiled/router behavior, counter merge, and parallel LWW risk.

---

# LangGraph & Streaming Remediation — Root-level Tracking

Spec: `/Users/douglasswm/.claude/plans/users-douglasswm-claude-plans-do-deep-r-serene-platypus.md`

## Open PRs (both awaiting review)

| PR | Submodule | Branch | Phases |
|----|-----------|--------|--------|
| [#74](https://github.com/ShashankBagda/VerdictCouncil_Backend/pull/74) | Backend | `feat/langgraph-state-reducers` | P0, P1, P2, P4.22 |
| [#152](https://github.com/ShashankBagda/VerdictCouncil_Frontend/pull/152) | Frontend | `feat/sse-event-types` | P2, P3 |

## Root submodule bumps (do after each PR merges to development)

- [x] After backend PR #74 merges: bumped to `3ebf56f` — `7b5e1cf`
- [x] After frontend PR #152 merges: bumped to `98aebf9` — `7b5e1cf`

## End-to-end smoke (run after both submodule bumps land on root main)

Prerequisites: `.env` files configured, `./dev.sh up` from this directory, seeded judge credentials.

- [ ] **Scenario A** — kill backend mid-run (`docker stop` the API container): AgentStreamPanel transitions from "Live" → "Polling", then error toast appears within ~15s (one heartbeat window). Current behaviour: silent hang on "Polling". Fix verified by PR #74 `auth_expiring` + heartbeat logic.
- [ ] **Scenario B** — `POST /api/v1/cases/{id}/cancel` from a second browser tab: both tabs receive a `phase=cancelled` SSE frame via Redis fanout; pipeline stops within one inter-turn window; token burn stops. Verify with MLflow: the run ends, no further tool calls logged.
- [ ] **Scenario C** — two browser tabs on the same case, close one tab: the remaining tab continues receiving SSE events normally; pipeline is unaffected (SSE disconnect ≠ cancel, as of PR #74 P0.3).
- [ ] **Scenario D** — let the `vc_token` JWT cookie expire mid-stream (or set a short TTL in dev): the `auth_expiring` SSE event fires ≥60s before expiry; the frontend immediately redirects to `/login` (handled in `useAgentStream.js` `addEventListener('auth_expiring', ...)`).

## Remaining spec items by phase

| Item | Phase | Where | Status |
|------|-------|--------|--------|
| PR #74 merge + backend bump | gate | root | open |
| PR #152 merge + frontend bump | gate | root | open |
| E2E smoke Scenarios A–D | verification | root | blocked on bumps |
| P3.18 — checkJs for sseEvents.ts | P3.18 | frontend `feat/sse-checkjs` | not started |
| P4.21 — pipeline_events replay table | P4.21 (optional) | backend `feat/pipeline-events-replay` | not started |
