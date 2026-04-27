# Plan: Natural-Language Streaming + Document-Ingestion Fix

**Spec**: `/Users/douglasswm/.claude/plans/use-the-langchain-and-quirky-cook.md`
**Date**: 2026-04-26
**Scope**: Two independent work streams — Q1 (streaming UX redesign) and Q2 (ingestion bug fix). Risk #3 (gate-2 per-agent rerun) is explicitly out of scope and tracked as a separate ticket.

---

## Overview

Two questions resolve to overlapping touch points in `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py` and the SSE bridge:

1. **Q1 — Streaming**: Pivot from JSON-token streaming to ChatGPT-style prose + tool-call chips + final structured artifact. Two-pass per phase: conversational stream, then a structuring call. Gated by feature flag, intake first, audit unchanged.
2. **Q2 — Ingestion bug**: Pre-parse documents into `CaseState.raw_documents.parsed_text` at runner hydration; bridge `case.intake_extraction` as defense-in-depth; harden `/process` preconditions. Fixes the silent halt on uploaded PDFs.

**Q2 is independent and lands first** — smaller blast radius, no feature-flag plumbing, restores broken functionality. Q1 builds on a stabilized intake path.

---

## Architecture decisions

### A1. Q2 ships before Q1

Q2 fixes a broken user flow (uploaded PDFs ignored, intake halts). Q1 is a UX upgrade. Shipping Q2 first means the fixed intake path is the baseline against which Q1's streaming is verified. Reverse order risks attributing Q1 streaming bugs to a still-broken intake.

### A2. Two-pass per phase, not single-pass with parser

LangGraph idiom for "prose + structured artifact" is **conversational `create_agent` → `model.with_structured_output(schema).ainvoke(history)`**. Single-pass alternatives (parsing prose into the schema, or streaming JSON and rendering it as prose) are rejected: parsing is brittle, JSON-as-prose is what we have today.

### A3. Audit phase stays JSON-only

Audit has strict-correctness requirements (`response_format=schema, strict=True`) and tight latency expectations. The conversational pivot does not apply. Per spec line 56-58.

### A4. Per-token publish is decoupled from persistence

Hard constraint from Risk #2. The new `llm_token` SSE event MUST NOT take the same path as `llm_response` (Redis write + `pipeline_events` row insert). Coalesce → fire-and-forget Redis publish; `pipeline_events` rolls one consolidated `llm_response` row at message-end (existing behavior).

### A5. Stream failure ≠ retry from zero

Hard constraint from Risk #1. Once any chunk has been emitted, the broad `except` → `agent.ainvoke` fallback at `factory.py:286-292` is unsafe (double tool calls, double charges, double audit rows). Replace with `streaming_started` flag and propagate failure or emit terminal SSE.

### A6. Feature flag rollout for Q1

Q1 behavior change is large. Roll out behind a per-phase flag (`PIPELINE_CONVERSATIONAL_STREAMING_PHASES=intake`). Default OFF on `development`, flip ON in staging after intake lands, expand phase list incrementally. Audit phase never enrolls.

### A7. Per-submodule branching

Backend changes go to `feat/*` branches off `development` in `VerdictCouncil_Backend`; frontend to `feat/*` off `development` in `VerdictCouncil_Frontend`. Root commits only bump submodule SHAs. PRs follow the gitflow template in submodule CLAUDE.md.

---

## Dependency graph

```
Q2 — Ingestion fix (independent, ships first)
  Q2.1 Cache parsed text on Document.parsed_text at upload
        │
        ▼
  Q2.2 Hydrate parsed_text into CaseState.raw_documents
  Q2.3 Bridge case.intake_extraction into CaseState (parallel-safe with Q2.2)
  Q2.4 Intake-prompt guard rail (force parse_document when raw_documents non-empty + parties empty)
  Q2.5 Fail-fast 409 in /process when no parties + no intake_extraction
        │
        ▼
  Q2.6 Integration tests (happy path + skip-confirm path)
        │
        ▼
  ── CHECKPOINT A: Q2 merged to development; staging verified

Q1 — Streaming (depends on Q2 merged)
  Phase 1: Foundation (no UX change)
    Q1.1 Token coalescer + fire-and-forget publisher
    Q1.2 streaming_started flag; remove ainvoke fallback after first chunk
    Q1.3 New SSE event types llm_token + tool_call_delta (gated, OFF)
        │
        ▼
  ── CHECKPOINT B: Foundation merged; existing UX unchanged in production

  Phase 2: Dual-mode factory
    Q1.4 conversational flag in _make_node
    Q1.5 Structuring-pass node
    Q1.6 Wire intake to conversational=True behind feature flag
        │
        ▼
  ── CHECKPOINT C: Backend dual-mode behind flag; staging verified with flag ON

  Phase 3: Frontend rendering
    Q1.7 SSE event-union extension
    Q1.8 Prose accumulator
    Q1.9 Tool-call chip
    Q1.10 Result-artifact panel
        │
        ▼
  ── CHECKPOINT D: Frontend ships behind same flag; intake-phase end-to-end verified

  Phase 4: Rollout
    Q1.11 Regression test for Risk #1 (no-double-call on stream failure)
    Q1.12 Load test for Risk #2 (Redis backpressure independence)
    Q1.13 Expand flag to triage + other phases (audit excluded)
        │
        ▼
  ── CHECKPOINT E: Rollout complete

Risk #3 — separate ticket, NOT in this plan
```

---

## Task list — Q2 (Ingestion fix)

### Task Q2.1: Cache parsed text on `Document.parsed_text` at upload

**Description**: Add a nullable `parsed_text JSONB` column to `documents` and populate it in the upload handler. Stores the same shape `parse_document` returns (text + pages + tables). Foundation for Q2.2's hydration step. Upload becomes slightly slower; pipeline start becomes much faster and deterministic.

**Acceptance criteria**:
- [ ] Alembic migration adds `documents.parsed_text JSONB NULL` (default NULL).
- [ ] Upload handler enqueues a new outbox job (e.g. `PipelineJobType.document_parse`) via the existing `enqueue_outbox_job` pattern (matches `intake_extraction` at `cases.py:714-717`). The arq worker calls `parse_document(file_id)` and persists the result.
- [ ] Background job persists the parse result to `Document.parsed_text` on success.
- [ ] Failures in `parse_document` at worker time **do not surface as upload failures** — column stays NULL, log a warning, and the runner-side fallback (Q2.2's tool-call path) kicks in.
- [ ] Existing documents (NULL `parsed_text`) still work via the runner-side fallback.

**Verification**:
- [ ] Migration applies cleanly: `alembic upgrade head` then `alembic downgrade -1` then `alembic upgrade head`.
- [ ] Unit test: upload PDF → assert `Document.parsed_text` is non-NULL with `text` key populated.
- [ ] Unit test: upload corrupted PDF → assert upload still succeeds, `parsed_text` is NULL, warning logged.
- [ ] Manual: upload `notice_of_traffic_offence.pdf`, query DB, confirm `parsed_text->>'text'` contains the offence text.

**Dependencies**: None.

**Files likely touched**:
- `VerdictCouncil_Backend/alembic/versions/<new>_add_document_parsed_text.py`
- `VerdictCouncil_Backend/src/models/document.py`
- `VerdictCouncil_Backend/src/api/routes/cases.py` (upload handler)
- `VerdictCouncil_Backend/tests/api/test_document_upload.py`

**Estimated scope**: M (4 files)

---

### Task Q2.2: Hydrate `parsed_text` into `CaseState.raw_documents`

**Description**: At runner hydration (`cases.py:1316-1325`) include `parsed_text`, `pages`, and a `parsed_text_chars` count in each `raw_documents` entry. Read from `Document.parsed_text` (Q2.1's cache); if NULL, fall back to a runtime `parse_document` call before pipeline start so the agent always sees text. Eliminates the agent's dependency on tool-calling just to read its own attached files.

**Acceptance criteria**:
- [ ] `raw_documents[i]` includes `parsed_text: str` and `pages: list[dict]` when `Document.parsed_text` is populated.
- [ ] When `Document.parsed_text` is NULL, runner calls `parse_document(file_id)` and back-fills the column (writes back so subsequent runs hit cache).
- [ ] `parse_document` failure at runner time does NOT halt the run — entry gets `parsed_text=""`, agent still has tool fallback, log a warning with `case_id` + `document_id`.
- [ ] Add structured log line at runner start: `intake_phase_start case_id=X documents=N parties=N parsed_text_chars=M` (per spec verification line 225).

**Verification**:
- [ ] Unit test: hydrate a case with one Document where `parsed_text` is populated → assert `raw_documents[0]["parsed_text"]` matches.
- [ ] Unit test: hydrate with `parsed_text=NULL` → assert `parse_document` is called, column is back-filled.
- [ ] Integration test: run intake on a case with two pre-parsed PDFs → assert `IntakeOutput.raw_documents` length 2 with non-empty `key_facts`.

**Dependencies**: Q2.1.

**Files likely touched**:
- `VerdictCouncil_Backend/src/api/routes/cases.py` (lines 1316-1325)
- `VerdictCouncil_Backend/src/shared/case_state.py` (no schema change — `raw_documents` is already `list[dict]`; document the new keys)
- `VerdictCouncil_Backend/tests/pipeline/test_runner_hydration.py`

**Estimated scope**: S (3 files)

---

### Task Q2.3a: Reader-side compat for `intake_extraction` field (no writer change)

**Description**: First half of the schema_version 2→3 transition. `CaseState` gains the optional `intake_extraction` field; the deserializer accepts both v2 (no field) and v3 (field present) checkpoints. Writer keeps stamping `schema_version=2`. Ships and bakes for at least one release before Q2.3b flips the writer. Prevents in-flight runs from crashing on a checkpoint mismatch.

**Acceptance criteria**:
- [ ] `CaseState.intake_extraction: dict | None = None` added to Pydantic model.
- [ ] `schema_version` field default stays at `2` (no writer change yet).
- [ ] `src/db/pipeline_state.py` reader accepts checkpoints with `schema_version` in `{2, 3}`; defaults `intake_extraction` to None when missing.
- [ ] Runner does NOT yet populate the new field (deferred to Q2.3b) — keeps the diff minimal in this task.

**Verification**:
- [ ] Unit test: load a v2 checkpoint → `intake_extraction is None`, `schema_version == 2`.
- [ ] Unit test: load a v3 checkpoint synthesised in test → `intake_extraction` round-trips, `schema_version == 3`.
- [ ] Backwards-compat test: a v3 checkpoint loaded → re-serialised with current writer (still v2) → loads cleanly.

**Dependencies**: None.

**Files likely touched**:
- `VerdictCouncil_Backend/src/shared/case_state.py`
- `VerdictCouncil_Backend/src/db/pipeline_state.py`
- `VerdictCouncil_Backend/tests/shared/test_case_state.py`

**Estimated scope**: S (3 files)

---

### Task Q2.3b: Writer flips to v3 + bridge `case.intake_extraction` into runner

**Description**: Second half. After Q2.3a has merged and at least one staging deploy has rolled, flip the writer (`schema_version=3`), populate `intake_extraction` from `case.intake_extraction`, and merge fields into `parties` / `case_metadata` when Case columns are empty.

**Acceptance criteria**:
- [ ] `CaseState.schema_version` default bumped to `3`.
- [ ] Runner populates `intake_extraction` from `case.intake_extraction` regardless of confirm-step state.
- [ ] If Case columns are empty AND `intake_extraction.fields` has values, merge fields → `parties` / `case_metadata` (do NOT overwrite non-empty Case columns — see open question Q-B).
- [ ] Intake prompt mentions `intake_extraction` as authoritative pre-parse data when present.
- [ ] Pre-flip safety: at least one full release cycle elapsed since Q2.3a merged to `release/*` (gate kept manual; document in PR description).

**Verification**:
- [ ] Unit test: case with empty parties + populated `intake_extraction.fields.parties` → `CaseState.parties` filled from extraction.
- [ ] Unit test: case with both populated → Case columns win (no overwrite).
- [ ] Round-trip test: write checkpoint → assert `schema_version == 3` and `intake_extraction` survives a load.
- [ ] No in-flight checkpoint test fails (manual: drain a staging run started pre-bump and verify it completes after the bump deploys).

**Dependencies**: Q2.3a merged AND at least one staging release cycle elapsed.

**Files likely touched**:
- `VerdictCouncil_Backend/src/shared/case_state.py`
- `VerdictCouncil_Backend/src/api/routes/cases.py` (lines 1333-1354)
- `VerdictCouncil_Backend/src/pipeline/graph/prompts.py` (intake prompt text)
- `VerdictCouncil_Backend/src/db/pipeline_state.py` (schema-version compat check)
- `VerdictCouncil_Backend/tests/shared/test_case_state.py`

**Estimated scope**: M (5 files)

---

### Task Q2.4: Intake-prompt guard rail

**Description**: Strengthen `prompts.py:90-150` so the intake agent cannot route `halt` while `raw_documents` is non-empty AND `parties` is empty. Force a `parse_document` call on every entry first. Targets the actual failure mode observed: agent saw two file_ids and gave up without calling its tool.

**Acceptance criteria**:
- [ ] Intake system prompt includes explicit rule: "If `raw_documents` has any entries AND `parties` is empty, you MUST call `parse_document(file_id)` on every entry before deciding `route`."
- [ ] Prompt also notes: "After parsing, if extraction is still ambiguous, prefer `route=clarify` over `route=halt`."
- [ ] Prompt change does not break existing intake snapshot tests (update fixtures if any pin exact prompt text).

**Verification**:
- [ ] Unit test (prompt assertion): assert the new sentence appears in the rendered prompt.
- [ ] Replay test: run intake with the failing case payload (`raw_documents` set, `parties` empty) → assert `parse_document` is called and `route != "halt"`.

**Dependencies**: Q2.2 (so `raw_documents` actually contains parseable data the agent can confirm against).

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/prompts.py`
- `VerdictCouncil_Backend/tests/pipeline/test_prompts.py`
- `VerdictCouncil_Backend/tests/pipeline/test_intake_replay.py`

**Estimated scope**: S (3 files)

---

### Task Q2.5: Fail-fast 409 in `/process`

**Description**: Tighten preconditions in `process_case` (`cases.py:1493`). Today it only checks `case.documents` non-empty and status `STARTABLE_STATUSES`. Add: if `parties` is empty AND `intake_extraction` is empty/null, return 409 with a message directing the user to complete intake-confirm. Prevents wasted runs that are guaranteed to halt.

**Acceptance criteria**:
- [ ] `/process` returns 409 with `detail="Intake confirmation incomplete: complete the intake review before processing"` when both `case.parties` and `case.intake_extraction.fields` are empty.
- [ ] `/process` still 202s when either parties OR intake_extraction has content.
- [ ] Existing 400 (no documents) and 409 (not in startable status) responses unchanged.

**Verification**:
- [ ] API test: `/process` on a case with documents but no parties + no extraction → 409.
- [ ] API test: `/process` on a case with documents + populated intake_extraction (parties still empty) → 202.
- [ ] API test: existing happy-path test still passes.

**Dependencies**: None. (Independent of Q2.1-Q2.4 but ships in the same PR for cohesion.)

**Files likely touched**:
- `VerdictCouncil_Backend/src/api/routes/cases.py` (lines 1493-1531)
- `VerdictCouncil_Backend/tests/api/test_process_case.py`

**Estimated scope**: S (2 files)

---

### Task Q2.6: Integration tests (end-to-end)

**Description**: Two integration tests exercising the full upload → process → SSE flow. Locks in the fix so a regression is caught.

**Acceptance criteria**:
- [ ] Test A (happy): upload `notice_of_traffic_offence.pdf` + `witness_statement.pdf` → confirm intake → `/process` → assert SSE stream contains `IntakeOutput` with `domain` set, `parties` length ≥ 1, `raw_documents` length 2, each with non-empty `key_facts`.
- [ ] Test B (skip-confirm): same uploads → call `/process` directly → assert either 409 (Q2.5 path) OR a successful run that triggers `parse_document` and produces a non-empty `IntakeOutput` (Q2.2/Q2.4 path).
- [ ] Tests use real fixtures from `tests/fixtures/sample_pdfs/` (or create them — keep <100KB each).

**Verification**:
- [ ] Both tests pass on `development` after Q2.1-Q2.5 land.
- [ ] Tests fail cleanly if any of Q2.1-Q2.5 is reverted.

**Dependencies**: Q2.1, Q2.2, Q2.3, Q2.4, Q2.5.

**Files likely touched**:
- `VerdictCouncil_Backend/tests/integration/test_intake_e2e.py`
- `VerdictCouncil_Backend/tests/fixtures/sample_pdfs/` (if not present)

**Estimated scope**: M (2 files + fixtures)

---

### Checkpoint A (after Q2.1-Q2.6)

- [ ] All Q2 unit + integration tests pass on `development`.
- [ ] Manual reproduction case (the original failing run) now produces a populated `IntakeOutput`.
- [ ] PR opened against `development` from `feat/intake-document-hydration`; CI green.
- [ ] Merged to `development`; submodule SHA bump committed to root `main`.
- [ ] Promoted to `release/*` and validated in staging.
- [ ] **Human review before starting Q1.**

---

## Task list — Q1 (Streaming)

### Phase 1 — Foundation (no UX change)

#### Task Q1.1: Token coalescer + fire-and-forget publisher

**Description**: Build a server-side coalescer used by Q1.6+ when streaming prose tokens. Buffer `AIMessageChunk.text` deltas with a window of `(50ms || 64 chars || tool-call boundary)` and emit one batched event per window. Publish via `asyncio.create_task` with a bounded queue (size 256, drop-on-overflow with a counter metric) — agent loop is never awaited on Redis. Today's `llm_chunk` path stays untouched.

**Acceptance criteria**:
- [ ] New module `src/pipeline/graph/agents/stream_coalescer.py` with `class StreamCoalescer` exposing `feed(delta: str)`, `flush()`, `close()`.
- [ ] Publisher path uses `asyncio.create_task(publish_agent_event(...))` with a bounded `asyncio.Queue` (size 256).
- [ ] Overflow drop is counted and exposed via a Prometheus metric `pipeline_stream_publish_dropped_total{phase=...}`. **No alert rule introduced in this PR** (per Q-H). The metric is observable; paging is deferred to a future ops pass.
- [ ] Coalescer is module-private; nothing wired into the pipeline yet.

**Verification**:
- [ ] Unit test: feed 2000 single-char deltas → assert ≤ 50 emitted batches.
- [ ] Unit test: feed deltas around a tool-call boundary marker → assert flush before tool call.
- [ ] Unit test: simulate Redis publish stall (200ms p99) → assert `feed()` returns under 5ms (publisher is fire-and-forget).
- [ ] Metric increments under bounded-queue overflow.

**Dependencies**: None.

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/stream_coalescer.py`
- `VerdictCouncil_Backend/src/services/pipeline_events.py` (expose fire-and-forget variant)
- `VerdictCouncil_Backend/tests/pipeline/test_stream_coalescer.py`

**Estimated scope**: M (3 files)

---

#### Task Q1.2: `streaming_started` flag — remove broad `ainvoke` fallback

**Description**: Replace the broad `except: result = await agent.ainvoke(...)` at `factory.py:286-292`. Track `streaming_started` set to True on first `messages` chunk OR first `values` payload OR first tool call. If exception raised after `streaming_started`, propagate (do NOT call `ainvoke`). If exception raised before any chunk, the existing `ainvoke` fallback is still safe.

**Acceptance criteria**:
- [ ] `_make_node._node` tracks `streaming_started` and only falls back to `ainvoke` when `streaming_started is False`.
- [ ] After-chunk exceptions emit a terminal `agent_failed` SSE event with `phase`, `case_id`, error class name (no PII), then re-raise so the orchestrator's existing failure handling runs.
- [ ] No silent retry — log line includes `streaming_started=True` so post-mortem is clear.

**Verification**:
- [ ] Regression test (Risk #1, spec line 98): mock `astream` to raise after one tool call → assert `parse_document` audit row count is 1, NOT 2; assert `agent_failed` SSE was emitted.
- [ ] Regression test: `astream` raises before any chunk → assert `ainvoke` IS called (back-compat preserved).
- [ ] Existing happy-path tests pass.

**Dependencies**: None. (Independent of Q1.1; can land same PR.)

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py` (lines 263-292)
- `VerdictCouncil_Backend/src/api/schemas/pipeline_events.py` (new `agent_failed` event type)
- `VerdictCouncil_Backend/tests/pipeline/test_factory_streaming.py`

**Estimated scope**: M (3 files)

---

#### Task Q1.3: New SSE event types `llm_token` + `tool_call_delta` (gated, OFF)

**Description**: Define backend SSE schemas. `llm_token` carries `(case_id, agent, phase, message_id, delta)`; `tool_call_delta` carries `(case_id, agent, phase, tool_call_id, name, args_delta)`. Wire them through the existing publish path BUT keep them gated by feature flag. The flag is OFF in this task — types are added so frontend (Q1.7) can build against them.

**Acceptance criteria**:
- [ ] Pydantic models in `src/api/schemas/pipeline_events.py` for both events with `event` discriminator values.
- [ ] Single feature flag `settings.pipeline_conversational_streaming_phases: list[str]` (env: `PIPELINE_CONVERSATIONAL_STREAMING_PHASES`, comma-separated, default empty). Events emit only when the current phase is in this list. (Q1.6 reads the same flag — there is exactly one knob.)
- [ ] `llm_token` does NOT tee-write to `pipeline_events` table (per A4); `tool_call_delta` likewise OFF for persistence.
- [ ] Existing `llm_chunk`/`tool_call`/`tool_result` events untouched.

**Verification**:
- [ ] Unit test: schema round-trips JSON cleanly.
- [ ] Integration test: with flag OFF, asserting these event types are NEVER emitted; existing event types still flow.

**Dependencies**: Q1.1 (uses coalescer-batched payload shape).

**Files likely touched**:
- `VerdictCouncil_Backend/src/api/schemas/pipeline_events.py`
- `VerdictCouncil_Backend/src/shared/config.py` (new flag)
- `VerdictCouncil_Backend/tests/api/test_pipeline_events_schema.py`

**Estimated scope**: S (3 files)

---

### Checkpoint B (after Q1.1-Q1.3)

- [ ] All Phase 1 tests pass; no behavior change in production with flag OFF.
- [ ] Risk #1 regression test green.
- [ ] PR merged to `development`; staging unchanged from user's perspective.
- [ ] Submodule bump on root `main`.

---

### Phase 2 — Dual-mode factory

#### Task Q1.4: `conversational` flag in `_make_node`

**Description**: Add a `conversational: bool = False` parameter to `_make_node`. When True, build the agent without `response_format` (no `ToolStrategy`, no strict schema). Keep the existing `streaming_started` / coalescer wiring; add a dedicated path that emits `llm_token` events instead of `llm_chunk` when the flag is True.

**Acceptance criteria**:
- [ ] `_make_node(conversational=True)` produces an agent without bound `response_format`.
- [ ] When `conversational=True`, prose deltas go through `Q1.1` coalescer → `llm_token` events.
- [ ] `tool_call_chunks` from `messages` mode are extracted and emitted as `tool_call_delta` events.
- [ ] When `conversational=False` (default), behavior is byte-identical to today.

**Verification**:
- [ ] Unit test: `make_phase_node("intake")` with `conversational=False` (current default) → behavior unchanged.
- [ ] Unit test: build `_make_node(conversational=True, ...)` against a mock model that yields prose chunks + a tool call → assert `llm_token` events with prose, `tool_call_delta` events with args, no `llm_chunk` events.

**Dependencies**: Q1.1, Q1.2, Q1.3.

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py`
- `VerdictCouncil_Backend/tests/pipeline/test_factory_conversational.py`

**Estimated scope**: M (2 files, complex logic in factory)

---

#### Task Q1.5: Structuring-pass node

**Description**: After the conversational pass completes, run a single non-streaming `model.with_structured_output(schema, strict=True).ainvoke(messages_history)` to produce the schema-bound artifact. Append the structured result to state under `f"{phase}_output"` exactly as today. Emits a final SSE event `structured_artifact` with the artifact (one frame, not streamed) so the frontend can render the result panel.

**Acceptance criteria**:
- [ ] When `conversational=True`, after the `astream` loop ends successfully, structuring pass runs and writes `result["structured_response"]`.
- [ ] Structuring pass uses the SAME schema today's path uses (`PHASE_SCHEMAS[phase]`).
- [ ] Structuring pass failure raises (no fallback) — already covered by Q1.2's policy.
- [ ] New SSE event `structured_artifact` emitted with the artifact JSON. Tee-writes to `pipeline_events` (one row, not per-token).

**Verification**:
- [ ] Unit test: conversational intake flow on a mock model → assert `IntakeOutput` is produced and matches schema.
- [ ] Unit test: structuring pass receives the same `messages` history the conversational agent saw.
- [ ] Schema-validation failure in structuring → `agent_failed` emitted, exception propagates.

**Dependencies**: Q1.4.

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py`
- `VerdictCouncil_Backend/src/api/schemas/pipeline_events.py` (`structured_artifact` event)
- `VerdictCouncil_Backend/tests/pipeline/test_factory_conversational.py`

**Estimated scope**: M (3 files)

---

#### Task Q1.6: Wire intake to `conversational=True` behind flag

**Description**: `make_phase_node("intake")` reads `settings.pipeline_conversational_streaming_phases` (comma-list of phase names) and passes `conversational=True` only when `intake` is in the list. Default empty (no phases enrolled). Update intake prompt to encourage natural-language reasoning before tool calls and a short summary.

**Acceptance criteria**:
- [ ] `make_phase_node("intake")` reads `settings.pipeline_conversational_streaming_phases` (the same flag introduced in Q1.3) and passes `conversational=True` only when `"intake"` is in the list.
- [ ] With env unset (default), intake remains JSON-mode (today's behavior).
- [ ] Intake prompt has a new "When in conversational mode: explain your reasoning step by step in plain prose, call tools as needed, finish with a one-paragraph summary" section. Existing JSON-mode prompt path untouched.
- [ ] **Fidelity gate**: structured-output equivalence on a fixture set of 20 historical intake cases. Run today's JSON path and the new conversational path on each; require ≥95% field-level match (per-field exact for scalars, set-equal for parties) before flag is flipped in any environment beyond local dev. Documented in PR description with the 20-case run table.

**Verification**:
- [ ] With flag set, intake phase against a real (smoke) case → SSE stream shows prose tokens, then tool calls, then `structured_artifact`.
- [ ] With flag unset, behavior identical to today (snapshot test on event sequence).
- [ ] No change to non-intake phases under either flag setting.

**Dependencies**: Q1.4, Q1.5.

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py` (`make_phase_node`)
- `VerdictCouncil_Backend/src/pipeline/graph/prompts.py` (intake prompt — conversational variant)
- `VerdictCouncil_Backend/src/shared/config.py`
- `VerdictCouncil_Backend/tests/pipeline/test_intake_conversational.py`

**Estimated scope**: M (4 files)

---

### Checkpoint C (after Q1.4-Q1.6)

- [ ] All Phase 2 tests pass.
- [ ] PR merged to `development`; flag OFF in production.
- [ ] Staging deploy with flag ON for intake → backend SSE stream verified by curl/CLI inspection (prose tokens visible, tool-call deltas visible, structured artifact at end).
- [ ] No frontend changes yet — SSE stream visible only via raw inspection.

---

### Phase 3 — Frontend rendering

#### Task Q1.7: SSE event-union extension

**Description**: Add `llm_token`, `tool_call_delta`, `structured_artifact`, and `agent_failed` to `VerdictCouncil_Frontend/src/lib/sseEvents.ts`. Discriminated-union types so consumers narrow safely.

**Acceptance criteria**:
- [ ] Four new types added to the event-union with field names matching backend schemas exactly.
- [ ] TypeScript `tsc --noEmit` clean.
- [ ] Existing union members unchanged.

**Verification**:
- [ ] Compile-time: `npm run typecheck` (or equivalent) passes.
- [ ] Round-trip test: `JSON.parse` a sample of each event → discriminator narrows correctly.

**Dependencies**: Q1.3 (backend schema is the source of truth).

**Files likely touched**:
- `VerdictCouncil_Frontend/src/lib/sseEvents.ts`
- `VerdictCouncil_Frontend/src/lib/__tests__/sseEvents.test.ts`

**Estimated scope**: S (2 files)

---

#### Task Q1.8: Prose accumulator in `useAgentStream`

**Description**: Add a per-message accumulator keyed by `(agent, phase, message_id)`. On `llm_token`, concatenate `delta` into the matching message buffer; expose under `events[agent].prose[message_id]` (or a similar shape — pick the one that fits the existing render contract). On `structured_artifact`, store under `events[agent].artifact`. Existing `events[agent]` array of raw events stays for back-compat with code that already reads it.

**Precondition (do before writing code)**:
- [ ] **Inventory existing consumers**: `rg "events\\[" VerdictCouncil_Frontend/src` AND `rg "useAgentStream" VerdictCouncil_Frontend/src` — list every site that destructures the per-agent shape. Decide per site: (a) refactor in this PR, (b) keep working via a back-compat proxy. Record the inventory in the PR description before merging.

**Acceptance criteria**:
- [ ] New state shape per agent: `{ raw: Event[], prose: Record<message_id, string>, artifact: Artifact | null }`.
- [ ] `llm_token` deltas concatenate by `message_id`.
- [ ] `structured_artifact` overwrites the artifact (last-wins, normal pipeline emits one).
- [ ] Back-compat: every consumer found in the inventory above either (a) is migrated in this PR, or (b) reads through a documented proxy that yields today's behavior. No silent breakage.

**Verification**:
- [ ] Hook unit test: feed sequence of `llm_token` events with same message_id → assert prose grows.
- [ ] Hook unit test: feed `structured_artifact` → asserted on `events[agent].artifact`.
- [ ] Snapshot test: existing consumers (`AgentStreamPanel`) still render with no `llm_token` events present (back-compat).

**Dependencies**: Q1.7.

**Files likely touched**:
- `VerdictCouncil_Frontend/src/hooks/useAgentStream.js`
- `VerdictCouncil_Frontend/src/hooks/__tests__/useAgentStream.test.js`

**Estimated scope**: M (2 files, careful state-shape migration)

---

#### Task Q1.9: Tool-call chip component

**Description**: New collapsible component `<ToolCallChip>` rendering `{ name, args }` from `tool_call_delta` events. Animate "args streaming in" (text grows). On final `tool_result`, mark complete and show truncated result.

**Acceptance criteria**:
- [ ] Component accepts `{ name: string, argsDelta: string, status: "streaming" | "complete" | "error", result?: string }`.
- [ ] Renders inline within the prose flow at the position the tool was called (use a placeholder marker in the prose buffer).
- [ ] Accessibility: collapsible respects `aria-expanded`; default collapsed.
- [ ] Visual: matches existing `AgentStreamPanel` design tokens (no new color/spacing primitives).

**Verification**:
- [ ] Storybook (if present) or component test: streaming → complete state.
- [ ] Visual review with the user before Q1.10 lands.

**Dependencies**: Q1.8.

**Files likely touched**:
- `VerdictCouncil_Frontend/src/components/ToolCallChip.jsx`
- `VerdictCouncil_Frontend/src/components/ToolCallChip.module.css`
- `VerdictCouncil_Frontend/src/components/__tests__/ToolCallChip.test.jsx`

**Estimated scope**: M (3 files)

---

#### Task Q1.10: New chat-style conversation UI (build-from-scratch)

**Description**: Per Q-F: there is no chat UI in the frontend today. `AgentStreamPanel.jsx` is the only stream surface and it renders raw event objects, not a chat conversation. Q1.10 builds the chat UI as a **new component**, not a rewrite of the existing panel. The existing `AgentStreamPanel` remains for non-conversational phases; the new component takes over rendering for any phase enrolled in `PIPELINE_CONVERSATIONAL_STREAMING_PHASES`.

The new UI is a vertically-stacked, role-distinguished message list:
- **Agent message bubbles**: prose accumulated from `llm_token`s. Auto-scroll while streaming. Show agent name + phase as a header.
- **Inline tool-call chips**: rendered at the position the tool was called within the prose flow (use `Q1.9`'s `<ToolCallChip>`). Collapsible.
- **Result-artifact panel**: at the end of the message, a distinct "Result" card showing the `structured_artifact` payload, formatted to match the existing `formatLlmResponse` style for continuity.
- **Failure card**: `agent_failed` event renders a red error card with phase + error class, no PII.

**Acceptance criteria**:
- [ ] New component `<ConversationStream>` (or similarly named) at `VerdictCouncil_Frontend/src/components/ConversationStream.jsx`.
- [ ] Routing: parent component checks if the current phase is conversational-mode-enrolled (read from a backend-served flag or an SSE `phase_mode` event) and renders `<ConversationStream>` for those phases, `<AgentStreamPanel>` for the rest. NO regression for non-enrolled phases.
- [ ] Message-bubble layout with role distinction (agent vs. system vs. tool) — uses existing design tokens; no new color/spacing primitives unless reviewed.
- [ ] Auto-scroll to bottom while streaming; user scroll-up pauses auto-scroll until they scroll-back-to-bottom (standard chat behavior).
- [ ] Accessibility: each message bubble has `role="article"`; tool-call chips are keyboard-toggleable; live region announces new agent messages (`aria-live="polite"`).
- [ ] Empty state: while waiting for first token, show a typing-indicator (3-dot pulse) — not a full skeleton.
- [ ] `agent_failed` renders a clearly-styled error card with retry-or-back affordance (judge can decide to abort or trigger a rerun via the existing gate flow).

**Verification**:
- [ ] Manual: with backend flag ON in staging, run intake on a sample case → typing indicator → prose paints into a bubble → chips appear at tool calls → artifact card renders post-prose.
- [ ] Manual: with flag OFF, the case page renders exactly as today (no `<ConversationStream>` mounted for any phase).
- [ ] Visual regression check on ≥4 screenshots: typing-indicator, streaming-mid, streaming-with-toolcall, complete-with-artifact, agent-failed.
- [ ] Accessibility audit: keyboard navigation through chips works; `aria-live` region announces new agent turns.
- [ ] Visual review with the user (item 10's missing-feature concern — confirm the chat surface meets expectations) **before** the flag is flipped in staging.

**Dependencies**: Q1.8 (prose accumulator), Q1.9 (`ToolCallChip`).

**Files likely touched**:
- `VerdictCouncil_Frontend/src/components/ConversationStream.jsx` (new)
- `VerdictCouncil_Frontend/src/components/ConversationStream.module.css` (new)
- `VerdictCouncil_Frontend/src/components/__tests__/ConversationStream.test.jsx` (new)
- `VerdictCouncil_Frontend/src/components/MessageBubble.jsx` + `.module.css` (new — extracted for reuse)
- `VerdictCouncil_Frontend/src/components/TypingIndicator.jsx` + `.module.css` (new)
- Parent component (probably the case-detail page) that decides which renderer to mount per phase

**Estimated scope**: L (6-8 files — net new chat surface, justified because it's a missing feature, not a refactor).

---

### Checkpoint D (after Q1.7-Q1.10)

- [ ] Frontend type-check clean; component tests pass.
- [ ] Manual end-to-end on staging with backend flag ON for intake: prose streams, chips appear, artifact panel renders.
- [ ] Manual on staging with flag OFF: behavior identical to production today.
- [ ] PR merged to `development`; submodule bump.

---

### Phase 4 — Rollout

#### Task Q1.11: Risk #1 regression test (no double-call on stream failure)

**Description**: Already partially covered by Q1.2 unit test, but add an end-to-end version that exercises the real graph runner. Inject `astream` failure mid-tool-call via a mocked tool, assert audit-row count is 1 and the run terminates with `agent_failed`.

**Acceptance criteria**:
- [ ] E2E test in `tests/integration/test_streaming_failure.py` runs intake against a controlled fault-injecting model.
- [ ] Asserts `audit_log` rows count for the simulated tool call is 1.
- [ ] Asserts `pipeline_events` contains an `agent_failed` row with the expected phase + case_id.

**Verification**:
- [ ] Test passes after Q1.2 + Q1.4-Q1.6 land; fails if Q1.2's `streaming_started` flag is reverted.

**Dependencies**: Q1.6.

**Files likely touched**:
- `VerdictCouncil_Backend/tests/integration/test_streaming_failure.py`

**Estimated scope**: S (1 file)

---

#### Task Q1.12: Risk #2 load test (Redis-backpressure independence)

**Description**: Load test under controlled Redis latency. 4 concurrent cases × 6 agents × 2000-token responses (mocked model, deterministic output). Assert (a) `pipeline_events` rows-per-case stays ≤ 50 per agent (post-coalesce), (b) agent wall-clock unaffected when Redis p99 latency is injected at 200ms.

**Acceptance criteria**:
- [ ] Load harness in `tests/load/test_streaming_throughput.py` (skipped in default CI; run via `pytest -m load`).
- [ ] Toxiproxy or similar injects 200ms p99 latency on Redis publish channel.
- [ ] Assert: agent wall-clock at p95 with latency injection is within 5% of baseline.
- [ ] Assert: `pipeline_events` row count per (case, agent) ≤ 50 after a 2000-token response.

**Verification**:
- [ ] Load test passes locally with Toxiproxy; documented in `docs/load-testing.md` how to reproduce.
- [ ] If load test fails, Q1.1's coalescer/fire-and-forget design needs revisiting before flag enables production.

**Dependencies**: Q1.6.

**Files likely touched**:
- `VerdictCouncil_Backend/tests/load/test_streaming_throughput.py`
- `VerdictCouncil_Backend/docs/load-testing.md`

**Estimated scope**: M (2 files; load harness + docs)

---

#### Task Q1.13: Expand flag to triage + other phases

**Description**: With Q1.11 + Q1.12 green, enroll triage in conversational mode. Audit phase stays JSON-only (architecture decision A3). Update intake prompts for any other phases enrolled (currently: triage). Document the rollout in `docs/streaming-rollout.md`.

**Acceptance criteria**:
- [ ] `PIPELINE_CONVERSATIONAL_STREAMING_PHASES` accepts `intake,triage` and triage flips to conversational.
- [ ] Audit phase verified to still bind `response_format=schema, strict=True` regardless of flag.
- [ ] Rollout doc lists which phases are eligible, decision rationale, rollback procedure.

**Verification**:
- [ ] Staging: flag set to `intake,triage`; both phases stream prose.
- [ ] Staging: audit phase still emits JSON (snapshot test).
- [ ] Per-phase rollback verified: removing a phase from the list reverts that phase only.

**Dependencies**: Q1.11, Q1.12.

**Files likely touched**:
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py` (`make_phase_node` for triage)
- `VerdictCouncil_Backend/src/pipeline/graph/prompts.py` (triage conversational variant)
- `VerdictCouncil_Backend/docs/streaming-rollout.md`

**Estimated scope**: S (3 files)

---

### Checkpoint E (after Q1.11-Q1.13)

- [ ] Both regression tests green; load test green.
- [ ] Flag enabled for `intake,triage` in production.
- [ ] Audit phase verified untouched.
- [ ] Rollback procedure documented and tested in staging.
- [ ] **Sprint retro**: capture lessons in `tasks/lessons.md`.

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Q2.1 upload latency regression (parse_document on every upload) | Medium | Parse-on-upload runs after the file is already persisted; failures don't block. Worst-case: upload feels slower by ~2-5s on large PDFs. Acceptable since pipeline start becomes much faster. |
| Q2.3 schema_version bump breaks running pipelines | High | Phase deploy: ship the reader-side compat first (default v2 checkpoints to `intake_extraction=None`), then bump `schema_version=3`. Existing in-flight runs complete before bump. |
| Q1.1 coalescer drops tokens under sustained backpressure | Medium | Drop-on-overflow with metric `pipeline_stream_publish_dropped_total`. Alarm at >0 over 5min. The user sees a slightly "jumpy" stream, NOT a hung agent. Acceptable trade. |
| Q1.4 dual-mode factory adds complexity in a hot path | Medium | Keep both branches simple; add a unit test matrix exercising the cartesian (`conversational ∈ {True, False}`) × (`use_strict_response_format ∈ {True, False}`). |
| Q1.6 conversational prompt change degrades intake accuracy | High | Compare structured-output equivalence on a fixture set of 20 historical cases; require ≥95% field-match before flipping flag in staging. |
| Risk #1 regression resurfaces (someone re-adds broad `except`) | High | Q1.11's E2E test is the canary. Keep it in CI. |
| Risk #2 regression resurfaces (someone awaits the publish) | High | Lint rule or comment in `factory.py` warning against `await publish_agent_event` for `llm_token`. Q1.12's load test is the canary. |

## Open questions — resolved 2026-04-26

- **Q-A** ✅ **RATIFIED**: `Document.parsed_text` is JSONB. Revisit if size grows past ~10MB per row.
- **Q-B** ✅ **RATIFIED**: `intake_extraction` bridge fills only empty Case columns (option A). Case columns remain user-confirmed authority.
- **Q-C** ✅ **RATIFIED**: Emit both `structured_artifact` and `llm_response` during conversational mode. Gate panel keeps reading `llm_response` until Q1.10 migrates the renderer.
- **Q-D** ✅ **RATIFIED**: Risk #3 filed as standalone ticket (`tasks/ticket-2026-04-26-gate2-per-agent-rerun-targeting.md`).
- **Q-E** ✅ **RATIFIED** (item 5): Q2.1 background mechanism is `enqueue_outbox_job` (the same outbox/arq pattern the upload route already uses for `intake_extraction`). `parse_document` is invoked from the worker, not from the upload route directly.
- **Q-F** ✅ **NEW (item 10)**: There is no chat UI today — `AgentStreamPanel.jsx` is the only stream surface, and it has no message-bubble layout / role distinction / proper chat affordances. **Q1.10 is build-from-scratch, not a rewrite.** Scope expanded — see Q1.10 below.
- **Q-G** ✅ **RATIFIED** (item 17): Backfill ticket for `Document.parsed_text` filed (`tasks/ticket-2026-04-26-document-parsed-text-backfill.md`).
- **Q-H** ✅ **RATIFIED** (item 20): No alert rule introduced for `pipeline_stream_publish_dropped_total`. The metric still emits; alarming/paging deferred to a future ops pass.

---

## Out of scope

- Risk #3 (gate-2 per-agent rerun targeting). Separate ticket.
- Backfill of `Document.parsed_text` for already-uploaded files. Optional follow-up; runner-side fallback (Q2.2) covers it.
- Storybook setup if not already present.
- Migration of audit phase to conversational mode (architecture decision A3).
