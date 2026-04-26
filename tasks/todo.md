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

## Open PRs

_(none — see "Root submodule bumps" below for the merged history)_

### Merged on 2026-04-24

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
| PR #74 merge + backend bump | gate | root | done — merged 2026-04-24 |
| PR #152 merge + frontend bump | gate | root | done — merged 2026-04-24 |
| E2E smoke Scenarios A–D | verification | root | not run yet |
| P3.18 — checkJs for sseEvents.ts | P3.18 | frontend `feat/sse-checkjs` | not started |
| P4.21 — pipeline_events replay table | P4.21 (optional) | backend `feat/pipeline-events-replay` | done — merged via 2026-04-25 submodule bump |

---

# Pipeline + RAG + Observability Overhaul — Sprint 0 Complete

**Approval gate (Task 0.12) cleared 2026-04-25.** Sprint 1 cleared to start.

## Sprint 0 deliverables (committed to `main`)

- [x] 0.1 — `tasks/schema-audit-2026-04-25.md` (DB schema inventory, 12 tables)
- [x] 0.2 — `tasks/output-model-audit-2026-04-25.md` (Pydantic output-model inventory, 9 agents → 6-phase mapping)
- [x] 0.3 — `tasks/tool-audit-2026-04-25.md` (7 tools → 3 real tools)
- [x] 0.4 — `tasks/architecture-2026-04-25.md` (6-agent topology spec)
- [x] 0.5 — `tasks/schema-target-2026-04-25.md` (canonical target — final DDL, Pydantic models, migration sequence)
- [x] 0.7 — `RESPONSIBLE_AI_SECTION.md` rewritten for rev 3
- [x] 0.8 — `SECURITY_RISK_REGISTER.md` rewritten for rev 3 (R-17/R-18/R-19 added)
- [x] 0.9 — `MLSECOPS_SECTION.md` rewritten for rev 3 (LangSmith, eval CI gate)
- [x] 0.10 — `AGENT_ARCHITECTURE.md` rewritten for rev 3 (6-phase StateGraph diagram)
- [x] 0.11a — `tasks/agent-design-2026-04-25.md` (per-agent design doc, 7 prompts)
- [ ] 0.11b — 15 golden eval cases under `VerdictCouncil_Backend/tests/eval/data/golden_cases/` — **deferred past 0.12**; Sprint 3 D1.1 is the actual blocker, not Sprint 1
- [x] 0.11c — `docs/setup-2026-04-25.md` (env vars, accounts, GitHub secrets, CLI tools, branch protection)

## Sprint 0 user decisions (canonical record)

- Confidence: enum `{low, med, high}`
- `confidence_calc`: keep as in-node Python utility (no `@tool` wrapper)
- `judge_corrections`: phase-keyed, accept Task 4.C4.1 DDL with new `correction_source` discriminator (`'judge'` | `'auditor'`)
- Strict-mode JSON schema: auditor only (other phases use `ToolStrategy(Schema)` with `extra="forbid"`)
- `parse_document`: keep current OpenAI Responses impl through Sprint 1; deterministic-loader rewrite (PyMuPDF + splitter + content-hash cache key) lands in Sprint 2
- Models: OpenAI-only, no cost ceiling. `gpt-5-mini` (intake) / `gpt-5` (research/synthesis/auditor). GPT-4 family deprecated; no fallback.
- `calibration_records`: drop entirely in Sprint 2 migration 0026
- `cases.domain` enum: drop in Sprint 2 migration 0026; `domain_id` NOT NULL, coordinated with checkpointer cutover
- `admin_events`: keep writes; add `GET /admin/events` reader in Sprint 4
- `system_config`: wire reader in Sprint 2 alongside checkpointer cutover
- `pipeline_events.schema_version`: defer bump infrastructure
- Auditor "send back to phase": post-hoc via `AuditOutput.should_rerun` / `target_phase` / `reason`; reuses judge-rerun endpoint
- `audit_logs` (plural) — fix breakdown's singular spelling in Sprint 4 implementation
- Migration sequence Sprints 1–4: `{0025, 0026}`. Other deferrable migrations punted past Sprint 4.
- LangSmith API key is personal-scoped — `LANGSMITH_WORKSPACE_ID` not required.

## Sprint 1 starting state

Three parallel workstreams open after 0.12:
- **A1** — phased `create_agent` + Send fan-out + middleware. Begins with `1.A1.0` (dep migration to LangChain 1.x LTS, P0).
- **C3a** — LangSmith prompts. Push 7 prompts; rewrite `prompts.py` as registry lookup.
- **DEP1** — LangGraph CLI scaffolding (`langgraph.json`, `langgraph dev`, runtime selection in `runner.py`).

Sprint 1 code work happens in `VerdictCouncil_Backend/` submodule on `feat/*` branches per gitflow (CLAUDE.md). Root only records the resulting submodule SHA bumps.

---

# Streaming UX + Ingestion Fix — 2026-04-26

Spec: `/Users/douglasswm/.claude/plans/use-the-langchain-and-quirky-cook.md`
Plan: `tasks/plan-2026-04-26-streaming-and-ingestion.md`
**Master sequence (read this first)**: `tasks/sequence-2026-04-26-streaming-ingestion-rollout.md` — orders all four work streams (Q2, Q1, gate-2 rerun, prompt realignment) against Sprint 1 A1/C3a/DEP1.

Two independent work streams. Q2 ships first (smaller, restores broken upload-to-pipeline flow). Q1 follows (UX upgrade behind feature flag, intake-phase first, audit phase exempt). Gate-2 rerun and prompt-pack realignment land as standalone tickets per the sequence doc.

## Q2 — Document-ingestion fix (ships first)

Branch: `feat/intake-document-hydration` (off `development` in `VerdictCouncil_Backend`)

- [x] **Q2.1** — Cache parsed text on `Document.parsed_text` at upload (migration + upload handler) — M
      Branch `feat/intake-document-hydration-foundation`. Migration 0027 adds JSONB column + `document_parse` enum value. New `src/services/document_parse.py` + `run_document_parse_job` worker. Both upload paths in `case_data.py` enqueue per-document jobs. 7 new tests pass; 0026↔0027 migration round-trip verified locally.
- [x] **Q2.2** — Hydrate `parsed_text` into `CaseState.raw_documents` at runner start — S (depends Q2.1)
      Branch `feat/intake-document-hydration-runner`. New `_hydrate_raw_documents` helper reads `Document.parsed_text`, back-fills via `parse_and_persist_document` on cache miss, falls back to empty string on failure. New `_log_intake_phase_start` operator breadcrumb. 7 new tests.
- [x] **Q2.3a** — Reader-side compat for `intake_extraction` (accept v2 + v3 checkpoints, writer unchanged) — S
      Branch `feat/case-state-intake-extraction-reader`. CaseState gains `intake_extraction: dict | None = None`; CURRENT_SCHEMA_VERSION stays 2; new `SUPPORTED_READ_SCHEMA_VERSIONS = frozenset({2, 3})`. 8 new tests (model defaults + round-trip + reader compat). Q2.3b (writer flip + runner population) deferred per scope.
- [x] **Q2.3b** — Writer flips to v3 + runner populates `intake_extraction` (after one staging release) — M (depends Q2.3a + bake)
      Branch `feat/case-state-intake-extraction-writer`. CaseState default `schema_version` flipped 2→3. New `_build_initial_state_overrides` helper bridges `Case.intake_extraction` onto CaseState — populates `intake_extraction` always, fills empty `parties` / `case_metadata` from `extraction.fields` (Q-B option A: judge-confirmed Case columns win, no overwrite). Intake prompt gains a "PRE-PARSE EXTRACTION" section telling the agent how to ground itself. Reader still accepts {2, 3} so pre-flip in-flight checkpoints continue to load. 9 new bridge tests + 1 prompt-shape test; existing test_pipeline_state.py default-version test updated. User waived bake gate ("just proceed").
- [x] **Q2.4** — Intake-prompt guard rail: force `parse_document` when raw_documents non-empty + parties empty — S (depends Q2.2)
      Branch `feat/intake-prompt-guard-rail`. New "INTAKE GUARD RAIL" section in `case-processing` prompt forbids two failure modes: (1) status='failed' while raw_documents non-empty + parties empty + parse not exhausted, (2) status='failed' on ambiguous extraction (use status='processing' + completeness_gaps instead). 3 new tests. Behavioural replay test deferred to Q2.6 e2e.
- [x] **Q2.5** — Fail-fast 409 in `/process` when no parties + no extraction — S
      Branch `feat/process-fail-fast-no-intake`. Guard rail in `process_case` returns 409 ("Intake confirmation incomplete") when both `case.parties` is empty AND `case.intake_extraction.fields` is empty/None. Added `selectinload(Case.parties)` to the case query. 4 new tests, 4 existing tests touched-up to set `parties=[MagicMock()]`.
- [~] **Q2.6** — Integration tests (happy path + skip-confirm path) — M (depends Q2.1-Q2.5) — **PARTIAL**
      Branch `feat/intake-e2e-tests`. Three integration tests cover the schema/outbox/hydration layers with mocked OpenAI: 409 gate (Q2.5), document_parse outbox row (Q2.1), real-session hydration with back-fill (Q2.2). Each fails under a specific Q2.x revert. **Behavioural LLM-driven e2e** (real intake agent on failing-case payload, SSE → `IntakeOutput` shape) **deferred** — no LLM-replay infra in repo yet, no integration-test arq-worker fixture. Re-enable conditions in `tasks/q2.6-deferral-2026-04-26.md`. Known infra issue: tests pass individually but combined run hits pytest-asyncio + asyncpg event-loop teardown — also documented.
- [ ] **Checkpoint A** — PR merged → `development`; staging verified; submodule SHA bumped on root `main`

## Q1 — Conversational streaming (depends on Q2 merged)

Branch lineage: backend `feat/streaming-foundation` → `feat/streaming-dual-mode` → `feat/streaming-rollout`. Frontend `feat/streaming-renderer`.

### Phase 1 — Foundation (no UX change)

- [x] **Q1.1** — Token coalescer + fire-and-forget publisher (Risk #2 design) — M
      Branch `feat/streaming-foundation-coalescer`. New `src/pipeline/graph/agents/stream_coalescer.py` with `StreamCoalescer` (50ms||64ch||boundary flush) + `FireAndForgetPublisher` (bounded asyncio.Queue size 256, drain task, drops on overflow). New `pipeline_stream_publish_dropped_total{phase=...}` counter wired into the existing hand-rolled MetricsStore (no `prometheus_client` dep added). 10 new tests including the <5ms `submit()` latency assertion under stalled drain. Module-private — Q1.4 will wire it into the live pipeline.
- [x] **Q1.2** — `streaming_started` flag; remove `ainvoke` fallback after first chunk (Risk #1 design) — M
      Branch `feat/streaming-foundation-no-double-call`. Factory `_node` tracks `streaming_started`. Pre-chunk failures still get the safe `ainvoke` retry; post-chunk failures emit a new `agent_failed` SSE event (error CLASS only, no message — PII risk) and re-raise so the orchestrator's existing handling takes over. New `AgentFailedEvent` Pydantic model added to the discriminated union. 3 new tests including the Risk #1 regression (mock raises after one chunk → no `ainvoke`, `agent_failed` emitted).
- [x] **Q1.3** — New SSE event types `llm_token` + `tool_call_delta` (gated, OFF by default) — S (depends Q1.1)
      Branch `feat/streaming-foundation-sse-token-events`. New `LlmTokenEvent` + `ToolCallDeltaEvent` Pydantic models added to the `Event` union. Carries `phase` field for flag-based gating. Single feature flag exposed as `settings.pipeline_conversational_streaming_phases` (a list[str] property reading `os.environ` directly to sidestep pydantic-settings' JSON-decode-first behaviour for `list[str]` fields). 9 new tests. Discriminator on `Event` union dropped (multiple classes share `kind="agent"`); consumers narrow on `event` field instead.
- [ ] **Checkpoint B** — Foundation merged; production behavior unchanged with flag OFF

### Phase 2 — Dual-mode factory

- [x] **Q1.4** — `conversational` flag in `_make_node` — M (depends Q1.1, Q1.2, Q1.3)
      Branch `feat/streaming-dual-mode-factory`. Factory `_make_node` accepts `conversational: bool = False`. When True: builds the agent without `response_format` (no ToolStrategy/strict schema), prose flows through `StreamCoalescer` → `llm_token` events, tool-call chunks emit as `tool_call_delta` events, `message_id` minted per assistant turn (resets on `ToolMessage`), no `llm_chunk` events. When False: byte-identical to today's path. 4 new tests.
- [x] **Q1.5** — Structuring-pass node (`with_structured_output(...).ainvoke`) — M (depends Q1.4)
      Branch `feat/streaming-dual-mode-structuring`. After conversational `astream` completes, factory runs `model.with_structured_output(schema, strict=True).ainvoke(messages_history)` to produce the schema-bound artifact. Result lands at `result["structured_response"]` exactly like JSON-mode path. New `StructuredArtifactEvent` SSE type emitted (one per phase, NOT per token — tee-write to `pipeline_events` is safe). New `_init_structuring_model` helper using `langchain.chat_models.init_chat_model`. 3 new tests + structuring-mock helper retrofitted into the 3 existing conversational tests.
- [~] **Q1.6** — Wire intake to `conversational=True` behind `PIPELINE_CONVERSATIONAL_STREAMING_PHASES` env — M (depends Q1.5) — **PARTIAL**
      Branch `feat/streaming-dual-mode-intake-wire` (PR #118 merged). Q1.6a shipped: `make_phase_node` reads the flag via `_is_phase_conversational(phase)` helper; audit hard-excluded (A3 invariant); intake prompt gains "WHEN IN CONVERSATIONAL MODE" section. 5 new flag-wiring tests + 1 new prompt-shape test. **Q1.6b (fidelity gate — ≥95% field match on 20 historical cases) deferred** — same blocker as Q2.6's behavioural e2e (no LLM-replay infra). D4 manual-gate runbook captured in `tasks/q1.6-fidelity-gate-deferral-2026-04-26.md`.
- [x] **Q1.6 default-on** — Branch `feat/streaming-default-on-intake`. `PIPELINE_CONVERSATIONAL_STREAMING_PHASES` default flipped from `""` to `"intake"` per user directive. Streaming UX is the new default; legacy JSON mode reachable via `PIPELINE_CONVERSATIONAL_STREAMING_PHASES=` (explicit empty). User waived D4 fidelity gate. Test suites for `test_agent_factory` and `test_tool_scoping` retrofitted with autouse `_force_json_mode` fixtures so JSON-mode-specific assertions still hold. 707-test wider regression sweep clean.
- [ ] **Checkpoint C** — Backend dual-mode behind flag; staging SSE verified via raw inspection

### Phase 3 — Frontend rendering

- [ ] **Q1.7** — SSE event-union extension (`sseEvents.ts`) — S (depends Q1.3)
- [ ] **Q1.8** — Prose accumulator in `useAgentStream` — M (depends Q1.7)
- [ ] **Q1.9** — `<ToolCallChip>` component — M (depends Q1.8)
- [ ] **Q1.10** — Result-artifact panel + `AgentStreamPanel` rewrite — M (depends Q1.8, Q1.9)
- [ ] **Checkpoint D** — Frontend ships; intake end-to-end verified on staging with flag ON

### Phase 4 — Rollout

- [ ] **Q1.11** — Risk #1 E2E regression test (no double-call on stream failure) — S (depends Q1.6)
- [ ] **Q1.12** — Risk #2 load test (Redis-backpressure independence) — M (depends Q1.6)
- [ ] **Q1.13** — Expand flag to triage; audit stays JSON-only — S (depends Q1.11, Q1.12)
- [ ] **Checkpoint E** — Production rollout `intake,triage`; lessons captured in `tasks/lessons.md`

## Out of scope (separate tickets)

- **Risk #3** — gate-2 per-agent rerun is not actually targeted. Filed: `tasks/ticket-2026-04-26-gate2-per-agent-rerun-targeting.md`. Independent of the streaming/ingestion plan; lands on its own branch `feat/gate2-scoped-rerun`.
- Backfill of `Document.parsed_text` for already-uploaded files (runner-side fallback covers it).

---

# Open standalone tickets

## Gate-2 scoped rerun — 2026-04-26

Ticket: `tasks/ticket-2026-04-26-gate2-per-agent-rerun-targeting.md`
Branch: `feat/gate2-scoped-rerun` (off `development` in `VerdictCouncil_Backend`)

- [ ] Resume worker consumes `payload["subagent"]` independent of `payload["notes"]`.
- [ ] Scoped dispatch: only the named research subagent re-runs; the other three subagents' outputs are preserved.
- [ ] Legacy "rerun all" path (subagent unset) unchanged.
- [ ] Unit + integration tests for both scoped and full-fan-out paths.

## Prompt-pack realignment — 2026-04-26

Ticket: `tasks/ticket-2026-04-26-prompt-pack-realignment.md`
Branch: `feat/prompt-pack-realignment` (off `development` in `VerdictCouncil_Backend`)
**Verified 2026-04-26**: Sprint 1 C3a has not started → ships as standalone ticket (no fold-in). Best landed after Q2 + Q1.6.

- [ ] One-pass audit of the 7 untouched prompts (research subagents + synthesis + audit) against the checklist (tool match, state-schema match, `raw_documents` shape, `intake_extraction` awareness, output-schema match, citation contract).
- [ ] Conversational-mode placeholder added to research + synthesis prompts (gated OFF until phase enrolled).
- [ ] Audit prompt verified to NOT have a conversational-mode section (architecture decision A3).
- [ ] New contract test: rendered prompt mentions every tool in `PHASE_TOOL_NAMES[phase]` exactly once.
- [ ] Existing replay tests still pass byte-equal in JSON-mode path.

## Document.parsed_text backfill — 2026-04-26

Ticket: `tasks/ticket-2026-04-26-document-parsed-text-backfill.md`
Branch: `feat/backfill-document-parsed-text` (off `development` in `VerdictCouncil_Backend`)
Hard dependency: Q2.1 merged (column + worker code path exist).

- [ ] Idempotent backfill script for legacy documents with NULL `parsed_text`.
- [ ] Dry-run reports doc count + estimated OpenAI Files API cost; operator approves before real run.
- [ ] Reuses Q2.1's parse-and-persist helper (no duplication).
- [ ] Runbook in `docs/runbooks/`.
