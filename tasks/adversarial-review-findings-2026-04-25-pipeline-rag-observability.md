# Adversarial Review Findings - Pipeline RAG Observability Overhaul

**Review date:** 2026-04-25
**Reviewed files:**
- `tasks/plan-2026-04-25-pipeline-rag-observability-overhaul.md`
- `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md`

## Findings

### 1. [P0] A1 is missing the dependency migration it relies on

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:452`

Sprint 1 builds around `langchain.agents.create_agent`, middleware, and structured `response_format`, but the backend currently declares `langgraph>=0.2.0`, `langchain-core>=0.3.0`, `langchain-openai>=0.2.0`, and no `langchain` package; 1.C3a.1 only adds `langsmith`. As written, A1 can fail before implementation with missing or incompatible APIs.

**Required fix:** Add an early dependency-upgrade task for `langchain`, `langgraph`, `langchain-core`, `langchain-openai`, `langsmith`, and checkpoint packages, with import/API smoke tests before 1.A1.4.

### 2. [P0] Gate stubs break the stated HITL invariant

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:542`

The plan says all four gates remain HITL `interrupt()` checkpoints, but Sprint 1 rewrites the topology with stub gate nodes while real `interrupt()` implementation and PostgresSaver wiring do not land until later sprints. That creates a dangerous intermediate state: either gates silently auto-advance, removing judge oversight, or the graph cannot really resume.

**Required fix:** Move the minimal checkpointer + interrupt/resume path before topology cutover, or keep the old gate runner active until A3 is complete.

### 3. [P1] Send fan-out is specified in a non-LangGraph shape

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:475`

`research_dispatch(state) -> list[Send]` is listed as a node, and `research_join(state, subagent_outputs)` is not a standard node signature. LangGraph's Send examples route from conditional edges, while fan-in data must be accumulated through state keys with reducers.

**Required fix:** Specify the exact graph wiring: dispatch node/state update, `add_conditional_edges(..., route_to_sends)`, per-lane output channels or a reducer-backed list, then a join node that reads state.

### 4. [P1] Trace IDs do not survive the outbox boundary

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:1062`

C1.4 assumes `runner.py` can read `request.state.trace_id`, but case processing is enqueued into `pipeline_jobs` and later run by a worker; the current process endpoint enqueues without any trace payload. Otherwise the promised API -> LangSmith -> SSE -> Sentry trace equality will only work in direct-call tests.

**Required fix:** Persist `traceparent`/`trace_id` into the job payload, thread it through worker execution into LangGraph config metadata, and test the worker path specifically.

### 5. [P1] Frontend posts to an endpoint no backend task creates

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:1727`

C5b.3 tells the UI to POST resume payloads to `/cases/{id}/respond`, but A3 only refactors the existing advance/rerun routes and no backend task defines this unified endpoint.

**Required fix:** Add a backend `respond` task with the full `advance | rerun | halt | send_back` contract, authorization, validation, and tests; then make the frontend depend on that task instead of relying on an ambiguous fallback.

### 6. [P1] New audit tables lose case integrity

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:1839`

The proposed DDL uses `case_id TEXT NOT NULL` for `judge_corrections` and `suppressed_citation`, while existing case-linked tables use UUID foreign keys to `cases.id`; the acceptance criteria also says FK constraints must be valid, but the DDL declares none.

**Required fix:** Use `UUID` plus `ForeignKey('cases.id', ondelete='CASCADE')`, add indexes, and add phase/subagent check constraints so these records cannot become orphaned or cross-tenant ambiguous.

### 7. [P2] Tool scoping regresses auditor independence

**Location:** `tasks/tasks-breakdown-2026-04-25-pipeline-rag-observability.md:455`

The plan's per-agent design says intake only gets `parse_document` and auditor gets no tools, but 1.A1.4 allows "likely all 3 real tools available across the board." That weakens least privilege, increases cost, and lets the independent auditor retrieve new evidence instead of auditing completed state.

**Required fix:** Make `PHASE_TOOLS` explicit and test that auditor has zero tools, intake has only `parse_document`, and only law/synthesis can call legal search.

## Additional Hygiene Issues

- Task `0.6` is referenced as a dependency/approval gate, but no Task 0.6 exists.
- Checkpoint 1b says 9 prompts after the plan repeatedly settles on 7.
- Several frontend verifications use `npm run typecheck`, while the package script is `type-check`.
- Task text references `settings.db_url` and `settings.env`, while the current backend config exposes `database_url` and no `env`.

## Review Result

The plan is directionally sound but should not proceed into Sprint 1 until the two P0 findings are resolved. Findings 3-6 should be fixed before implementation tasks are assigned, because they affect graph topology, trace propagation, API contract, and database integrity. Finding 7 can be handled during the architecture/spec cleanup but should still be made explicit before agent factories are written.
