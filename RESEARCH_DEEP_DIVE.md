# VerdictCouncil — Deep Research: Agent Architecture, Design Patterns & Grading Evidence

**Date:** 2026-04-22
**Scope:** Backend + Frontend + orchestration root
**Purpose:** Respond to prof's grading feedback. Justifies design decisions with code citations. Maps to grading rubric §1–§8.

---

> ## ⚠️ Phase 1 Architecture (Decommissioned) — Historical Record
>
> Most of this document describes the **Phase 1** design built around Solace Agent Mesh (SAM) and the Google ADK: nine per-agent containers, A2A pub/sub over a Solace broker, a `Layer2Aggregator` service for the L2 fan-in barrier, Redis Lua scripts for idempotency, and a separate `MeshPipelineRunner` that called agents over the broker.
>
> **That topology was decommissioned in the responsible-AI refactor (April 2026).** The live system runs as a single multi-stage Docker image deployed on DOKS as two K8s Deployments — `api-service` (uvicorn) and `arq-worker` (arq) — with all agent reasoning happening **in-process** inside a LangGraph `StateGraph` (`src/pipeline/graph/builder.py`). State persists to the Postgres `langgraph_checkpoint` table; the L2 barrier is `asyncio.gather` + the typed `_merge_case` reducer; idempotency comes from the graph checkpointer; there is no broker, no aggregator service, no `/invoke` HTTP, no `AGENT_HMAC_SECRET`.
>
> The Phase 1 narrative below is preserved because (a) it documents what was actually implemented in the SAM-era code that pre-dated git tag `v0.3.0`, (b) it explains the rationale that drove the team toward distributed reasoning before the responsible-AI rework forced consolidation, and (c) it remains useful grading evidence that the team did design and implement non-trivial agent-platform plumbing — even though that code no longer ships.
>
> See **Phase 2** at the bottom of this document for the live architecture, and `VerdictCouncil_Backend/docs/architecture/02-system-architecture.md` for the canonical reference.

---

## Professor's Grading Criteria — Response Summary

The prof asked:
- Why is the platform used? What role does it play?
- Is key logic designed by the team (not just platform config)?
- Can you justify design decisions?
- Assessed on: system architecture, agent design/coordination, component interaction, CI/CD, course topics.

**Short answer:** Solace Agent Mesh (SAM) is the transport/runtime layer only — all agent reasoning, orchestration topology, field ownership, guardrails, and domain logic are written by the team in Python. The team designed a 9-agent fixed-topology pipeline with L2 parallel fan-out, Redis Lua barrier, field ownership enforcement, two-layer injection detection, governance halts, and a checkpoint-replay system. SAM is one of six infrastructure dependencies; the system is not a SAM configuration.

---

## 1. Platform Role — Why SAM, What It Does and Doesn't Do

### What SAM is

Solace Agent Mesh (OSS, not Solace Enterprise) is a Python framework that:
- Provides an `app_module` host that loads a YAML-configured agent as a standalone process.
- Gives each agent a Solace pub/sub broker channel (A2A JSON-RPC 2.0 messages).
- Defines the `supports_streaming`, `agent_card_publishing`, and `inter_agent_communication` plumbing.

Evidence: `configs/agents/case-processing.yaml:6` — `app_module: solace_agent_mesh.agent.sac.app`.  
Evidence: `configs/shared_config.yaml:61-74` — broker anchor, agent_card interval 10s, allow_list `["*"]`, timeout 30s.

### What SAM does NOT do

- SAM does **not** determine which agent runs next. That is `MeshPipelineRunner` (`src/pipeline/mesh_runner.py`), a custom programmatic orchestrator.
- SAM does **not** enforce field ownership. That is `validate_field_ownership` in `src/shared/validation.py:4-51`, called by both runners.
- SAM does **not** implement guardrails. That is `src/pipeline/guardrails.py` and `src/pipeline/hooks.py`.
- SAM does **not** manage the Redis barrier. That is `src/services/layer2_aggregator/aggregator.py`.
- SAM does **not** run the tool-use loop. The local `PipelineRunner` (`src/pipeline/runner.py:538-569`) implements its own OpenAI function-call loop.
- SAM does **not** provide checkpointing, What-If branching, judge KB retrieval, or the audit trail.

### Why SAM was chosen (justifiable to prof)

1. **Decoupled agent processes for independent deployment.** Each of the 9 agents runs as a separate Kubernetes pod (`k8s/base/`). SAM's pub/sub runtime lets them scale independently and fail without taking down the whole pipeline.
2. **Protocol alignment.** SAM implements the emerging A2A (agent-to-agent) JSON-RPC 2.0 standard. This is industry practice (comparable to LangGraph's actor-message approach or Google A2A protocol).
3. **Validates local + distributed symmetry.** `PipelineRunner` runs all agents in-process for unit testing; `MeshPipelineRunner` runs the same agents over SAM for production. Same `CaseState`, same hooks, same field ownership — two execution paths over a shared interface.

---

## 2. System Architecture — What Was Actually Built

### 2.1 Physical topology

| Component | Runtime | Location |
|---|---|---|
| FastAPI app | Python 3.12 / uvicorn | DOKS pod |
| 9 SAM agent processes | Python / SAM | DOKS — one Deployment per agent |
| Layer 2 aggregator | Python / SAM | DOKS pod |
| Solace event broker | HA StatefulSet | `k8s/base/solace-ha.yaml` |
| PostgreSQL | DO Managed DB | Outside cluster |
| Redis | DO Managed Redis | Outside cluster |
| OpenAI API | Managed SaaS | External |
| PAIR API | Singapore govt | External |

Source: `k8s/base/kustomization.yaml:4-25` (12 Deployments), `docs/architecture/06-cicd-pipeline.md`.

### 2.2 Logical architecture (3 layers)

```
L1 (Sequential):     case-processing → complexity-routing
                           ↓ HALT if escalated
L2 (Parallel fan-out): evidence-analysis
                        fact-reconstruction    ← Redis Lua barrier (all 3 must complete)
                        witness-analysis
                           ↓
L3 (Sequential):     legal-knowledge → argument-construction → deliberation → governance-verdict
                                                                              ↓ HALT if fairness fail
```

Source: `src/pipeline/mesh_runner.py:68-79` (L1/L2/L3 agent lists).  
L2 fan-out: `mesh_runner.py:394-464`, barrier: `src/services/layer2_aggregator/aggregator.py:29-53`.

### 2.3 Two orchestrator implementations (key design decision)

| Orchestrator | Path | Execution model | Use |
|---|---|---|---|
| `PipelineRunner` | `src/pipeline/runner.py` | In-process OpenAI tool-use loop | Unit tests, local validation |
| `MeshPipelineRunner` | `src/pipeline/mesh_runner.py` | Distributed SAM A2A pub/sub | Production Kubernetes |

**Why two?** Enables fast unit-test iteration without requiring a running Solace broker, while the mesh runner exercises the real distributed topology. This is a recognized pattern in distributed systems testing (analogous to testcontainers vs. in-memory stubs).

**API runner selection** (`src/api/routes/cases.py:892-900`): the live API conditionally selects the runner at process-time via `settings.use_mesh_runner`. When `True` (production), it calls `get_mesh_runner()` which returns a singleton `MeshPipelineRunner`; when `False` (local/test), it instantiates `PipelineRunner()` inline. The architecture diagram reflects the production path.

The orchestrators are **programmatic (no LLM)**. Control flow is deterministic Python — no LLM is making routing decisions. This is intentional for a judicial system: auditability over adaptability.

Source: `runner.py:28-38` (`AGENT_ORDER`), `mesh_runner.py:68-79` (topology constants).

---

## 3. Agent Design and Coordination

### 3.1 Agentic design pattern

**Pattern: Orchestrator-Worker with DAG + Parallel Scatter/Gather**

This is NOT:
- ReAct (no cross-agent reflection/replanning loop)
- Planner-Executor (no LLM planner; the Python orchestrator is the planner)
- Dynamic routing (topology is fixed at design time)

This IS:
- Anthropic "orchestrator-subagents" building block — one conductor, N workers.
- Anthropic "parallelization" building block — L2 three-way fan-out with barrier aggregation.
- Each agent internally runs a bounded ReAct tool-use loop (while `finish_reason == "tool_calls"`) — `runner.py:538-569`.
- Terminal gate (governance-verdict as evaluator) — Anthropic "evaluator" building block.

**Why fixed topology for a legal system:**  
Deterministic ordering means the audit trail is reproducible. A judge or appeals court reviewing the AI recommendation can trace exactly which agent wrote which field, in which order, with which inputs. A dynamic planner would make that traceability far harder.

### 3.2 Nine-agent inventory with design rationale

| # | Agent | Model tier | Tools | Design rationale |
|---|---|---|---|---|
| 1 | `case-processing` | Lightweight (`gpt-5.4-nano`) | `parse_document` | Cheap intake: parse PDFs, normalize schema, classify domain (SCT/Traffic), validate Singapore jurisdiction |
| 2 | `complexity-routing` | Lightweight | none | Binary routing decision — cheap model sufficient; HALT point if escalated |
| 3 | `evidence-analysis` | Strong (`gpt-5`) | `parse_document`, `cross_reference` | Multi-document contradiction/corroboration requires strong reasoning |
| 4 | `fact-reconstruction` | Strong | `timeline_construct` | Sourced chronological timeline; disputed vs agreed facts |
| 5 | `witness-analysis` | Efficient (`gpt-5-mini`) | `generate_questions` | Credibility scoring (0–100); cheaper model appropriate for witness profiling |
| 6 | `legal-knowledge` | Strong | `SearchPrecedentsTool` (dynamic) | Two-tier retrieval: curated vector store + live PAIR API; verbatim statutory text, no hallucinated citations |
| 7 | `argument-construction` | Frontier (`gpt-5.4`) | `confidence_calc` | Balanced prosecution/defense construction; highest reasoning demand |
| 8 | `deliberation` | Frontier | none | 8-step reasoning chain; every step cites upstream agent+evidence; pure reasoning, no tools |
| 9 | `governance-verdict` | Frontier | `confidence_calc` | Phase 1: fairness audit (HALT if critical); Phase 2: verdict + confidence + alternatives |

Source: `configs/agents/*.yaml` (model anchors at line `:15` in each file).  
Model tier mapping: `src/shared/config.py:70-73`, `configs/shared_config.yaml:20-39`.

### 3.3 Coordination mechanism — CaseState as shared blackboard

`CaseState` is a Pydantic v2 model with 80+ fields (`src/shared/case_state.py:101-150`). Every agent receives the full CaseState as JSON input and writes back ONLY its owned fields. This is a **blackboard architecture** pattern:
- Blackboard = `CaseState`
- Knowledge sources = the 9 agents
- Controller = `MeshPipelineRunner`

**Field ownership enforcement** (`src/shared/validation.py:4-22`): the `FIELD_OWNERSHIP` dict maps each agent name to its allowed write fields. Any unauthorized write is detected, logged, and stripped — `runner.py:590-605`, `mesh_runner.py:525-538`. The audit log is declared `APPEND_ONLY_FIELDS = {"audit_log"}` (`validation.py:25`).

**Why this matters for justification:** a grader may ask "how do you prevent one agent from corrupting another's output?" — the answer is field ownership enforcement with per-agent allowlists, enforced at the orchestrator layer before state is persisted.

### 3.4 L2 parallel fan-out barrier — the Redis Lua aggregator

Evidence, fact, and witness analysis run in parallel (`asyncio.gather`, `mesh_runner.py:431`). The barrier is a Redis hash + Lua script:

```
Key: vc:aggregator:{case_id}:{run_id}
Fields: evidence_analysis_ts, extracted_facts_ts, witnesses_ts, _original_case_state, _published
```

Lua script (`aggregator.py:29-53`): atomically counts non-meta fields, sets `_published=1` and returns `1` when all 3 agents have written. This is an atomic scatter/gather — no polling, no race condition. TIMEOUT = 120s; stale runs are cleaned up by `check_timeouts` which fails the case and deletes state (`aggregator.py:171-220`).

**Why Redis Lua?** The atomicity guarantee is critical — without it, two agents completing nearly simultaneously could both think they are the last to finish and publish twice, or miss each other. The Lua script runs atomically in Redis (single-threaded command execution).

### 3.5 Memory mechanisms (for rubric §4)

| Agent | Memory type | Mechanism |
|---|---|---|
| All agents | Short-term in-context | Receives full `CaseState` as JSON in every prompt |
| All agents | Long-term persisted | PostgreSQL `pipeline_checkpoints` table (JSONB, per-hop) |
| `legal-knowledge` | External retrieval | PAIR API + OpenAI vector store (curated + per-judge) |
| All (forensic) | Append-only audit log | `CaseState.audit_log: list[AuditEntry]` |

There is NO per-agent stateful memory between cases. Agents are stateless by design — all state flows through `CaseState`.

### 3.6 What-If branching (topology-aware resume)

`run_from(case_state, start_agent)` in `mesh_runner.py:218-306` provides topology-aware re-entry:
- L3 start → only remaining L3 agents.
- L2 start → full 3-way L2 fan-out (aggregator requires all 3) + L3.
- L1 start → remaining L1 + full L2 + L3.

The `WhatIfController` (`src/services/whatif_controller/controller.py`) deep-clones a completed `CaseState` via `copy.deepcopy(case_state.model_dump())` (`controller.py:64`), applies a judge modification (fact toggle / evidence exclusion / witness credibility / legal interpretation), determines re-entry via impact map, then calls `self._mesh_runner.run_from(cloned, start_agent)` (`controller.py:87`). This provides "Contestable Judgment Mode" — judges toggle evidence admissibility and see how the verdict changes.

**Dependency note:** `WhatIfController.create_scenario` takes a fully populated `CaseState` as its argument. The API route calling it must load the checkpoint from the `pipeline_checkpoints` table (where per-hop CaseState JSONB is stored) — if the caller supplies an empty or partial state, the what-if runs on incomplete data. Verify the calling route (`src/api/routes/cases.py`) loads from `pipeline_checkpoints` before invoking `WhatIfController`.

---

## 4. Models Used

All models are OpenAI GPT-family. Config: `src/shared/config.py:70-73`, env-var overrideable.

**Important caveat:** The model IDs in `config.py` (`gpt-5.4-nano`, `gpt-5-mini`, `gpt-5`, `gpt-5.4`) are **placeholder defaults** used for local development. In production they are overridden at runtime by environment variables `OPENAI_MODEL_LIGHTWEIGHT`, `OPENAI_MODEL_EFFICIENT`, `OPENAI_MODEL_STRONG`, and `OPENAI_MODEL_FRONTIER`. The four-tier architecture and the rationale for each tier are what matters for grading — the specific model string is a deployment parameter, not a design decision.

| Tier | Default model ID (config.py) | Agents using it | Rationale |
|---|---|---|---|
| Lightweight | `gpt-5.4-nano` | case-processing, complexity-routing, guardrail LLM check | Fast/cheap for triage and routing decisions |
| Efficient | `gpt-5-mini` | witness-analysis | Moderate reasoning for credibility scoring |
| Strong | `gpt-5` | evidence-analysis, fact-reconstruction, legal-knowledge | Multi-document reasoning; legal statute parsing |
| Frontier | `gpt-5.4` | argument-construction, deliberation, governance-verdict | Highest-stakes judicial reasoning; fairness audit |

**Note for grading:** The GAPS.md §3 and AGENT_ARCHITECTURE.md flag a known internal contradiction — `architecture_draft.md` references `o3/o4-mini/gpt-4.1` while `config.py` uses `gpt-5.4/gpt-5/gpt-5-mini/gpt-5.4-nano`. This must be reconciled in the report. Use `config.py` tier names as the authoritative source; the exact model string is runtime-configured.

Embedding model: implicit (OpenAI vector stores handle embedding server-side — `src/tools/vector_store_fallback.py:42-47`). No client-side embedding model is declared.

---

## 5. Tool Use

### 5.1 Six tools — all custom implementations

Every tool is team-authored Python, not a platform-provided capability.

| Tool | File | Used by | Implementation |
|---|---|---|---|
| `parse_document` | `src/tools/parse_document.py` | case-processing, evidence-analysis | OpenAI Files API text extraction → `sanitize_document_content` → JSON; retry 2x on transport/rate errors |
| `cross_reference` | `src/tools/cross_reference.py` | evidence-analysis | LLM contradiction/corroboration over document segments; strong model; retry decorator |
| `timeline_construct` | `src/tools/timeline_construct.py` | fact-reconstruction | Pure Python date parser + sorter; no LLM; deterministic |
| `generate_questions` | `src/tools/generate_questions.py` | witness-analysis | LLM judicial question generation; retry decorator |
| `search_precedents` | `src/tools/search_precedents.py` | legal-knowledge | PAIR API + Redis cache + circuit breaker + vector store fallback (see §6) |
| `confidence_calc` | `src/tools/confidence_calc.py` | argument-construction, governance-verdict | Pure Python weighted scoring; no LLM; deterministic |

### 5.2 Tool registration — two paths

**Local runner** (`PipelineRunner`): `AGENT_TOOLS` map (`runner.py:41-51`) + `TOOL_SCHEMAS` OpenAI function-call shapes (`runner.py:62-256`). `_build_tools(agent)` emits only schemas for that agent's tools (`runner.py:443-451`). `_execute_tool_call` imports and calls directly in-process (`runner.py:453-499`).

**SAM runner** (`MeshPipelineRunner`): each agent YAML declares `tools:` with `tool_type: python` + `component_module` + `function_name` (e.g. `configs/agents/case-processing.yaml:57-61`). `legal-knowledge` uses `tool_type: dynamic` with `class_name` (`configs/agents/legal-knowledge.yaml:156-160`) — the SAM `DynamicTool` shell is `src/tools/sam/search_precedents_tool.py:62-80`.

**Tool call logging:** Local runner accumulates `tool_calls_log` per turn (`runner.py:537-552`), attaches to audit entry (`runner.py:625`). SAM runner sets `tool_calls=None` in audit entry (`mesh_runner.py:552-554`) — tool loops run inside SAM agent processes and are not yet propagated back to the orchestrator's audit log.

---

## 6. RAG Pipeline and Knowledge Base Stores

### 6.1 Two distinct retrieval systems

| Store | Purpose | Scope | Code |
|---|---|---|---|
| **Judge KB** (per-judge vector store) | Judge's personal reference materials | Private per-judge | `src/services/knowledge_base.py` |
| **Curated fallback store** | Case law and statutes | Global (all judges) | `src/tools/vector_store_fallback.py` |
| **PAIR API** | Live Singapore court rulings search | External government service | `src/tools/search_precedents.py` |

### 6.2 Judge Knowledge Base — per-judge OpenAI vector store

- **Provisioning**: one OpenAI vector store per judge (`src/services/knowledge_base.py:24-32`). Store ID persisted in `users.knowledge_base_vector_store_id` (`src/models/user.py:32`). Provisioned lazily under `SELECT ... FOR UPDATE` row lock (`knowledge_base.py:35-60`).
- **Upload**: file bytes → OpenAI Files API with `purpose="assistants"` → `vector_stores.files.create_and_poll` (blocks until indexed, `knowledge_base.py:63-87`). OpenAI handles chunking and embedding server-side. Max upload: 25 MB (`src/shared/config.py:35`).
- **Search**: `client.vector_stores.search(vector_store_id, query, max_num_results)` (`knowledge_base.py:90-108`). Returns `score`, `filename`, `content[0].text`. No client-side reranking.
- **API endpoints** (`src/api/routes/knowledge_base.py`): GET /status, POST /initialize, POST /documents, GET /documents, DELETE /documents/{file_id}, POST /search. All require `judge` role; judge can only access their own store.
- **Gap**: the judge KB is exposed only through the REST API. There is NO pipeline hook that injects judge-KB content into agent prompts mid-pipeline. `MeshPipelineRunner._apply_judge_kb_hook` does not exist — `default_hooks` (`src/pipeline/hooks.py:169-175`) registers only InputGuardrail, ComplexityEscalation, and GovernanceHalt hooks.

### 6.3 PAIR API + fallback with circuit breaker

Precedent search (`src/tools/search_precedents.py`) implements a resilient 3-layer retrieval:
1. **Rate limit**: Redis-distributed, 2 req/sec (`search_precedents.py:61-72`).
2. **Cache**: SHA256(query+domain+max_results) → Redis, TTL 86400s (`search_precedents.py:44-50`).
3. **PAIR call**: POST to `https://search.pair.gov.sg/api/v1/search`, 30s httpx timeout, retry 2x on transport/timeout (`search_precedents.py:75-126`).
4. **Circuit breaker**: Redis-backed, Lua-atomic failure counting (`src/shared/circuit_breaker.py:16-33`). Threshold=3 failures, recovery timeout=60s. States: CLOSED/HALF_OPEN/OPEN.
5. **Fallback**: when circuit OPEN or PAIR fails, calls `vector_store_search` using OpenAI Responses API `file_search` tool against the global curated vector store (`src/tools/vector_store_fallback.py:21-62`). Results tagged `source: "vector_store_fallback"`.
6. **Governance integration**: `governance-verdict.yaml:59` instructs the agent to flag `source_failed: true` as a confidence limitation.

---

## 7. Guardrails

### 7.1 Input guardrails — two-layer injection defense

**Layer 1 — Regex** (`src/shared/sanitization.py:4-42`):
- `_INJECTION_PATTERNS`: OpenAI/ChatML tokens (`<|im_start|>`), Llama delimiters, `<<SYS>>` blocks, markdown system headings.
- XML tag patterns matched separately.
- `sanitize_document_content` substitutes `[CONTENT_REMOVED]`/`[TAG_REMOVED]`.
- Also called inside `parse_document.py:137-149` on all extracted file text.

**Layer 2 — LLM classifier** (`src/pipeline/guardrails.py:29-96`):
- Only triggers if text >500 chars AND contains trigger words (instruction/system/ignore/override/pretend/role).
- Uses `gpt-5.4-nano`, max 100 tokens, `json_object` mode.
- LLM failure is best-effort (logged, non-blocking).

**Hook wiring**: `InputGuardrailHook.before_run` (`src/pipeline/hooks.py:47-81`):
- Skipped on pipeline resume (What-If re-entry).
- On block: sanitizes `case_metadata["description"]`, appends `input_injection_blocked` audit entry.
- Registered in `default_hooks` (`hooks.py:169-175`), invoked by `MeshPipelineRunner._run_before_run_hooks` (`mesh_runner.py:312-325`).

### 7.2 Output guardrails — field ownership + output integrity

- **Field ownership** (see §3.3): every agent's output is validated before merging into state.
- **Output integrity check** (`src/pipeline/guardrails.py:99-129`): `validate_output_integrity` verifies `confidence` in [0,100], `recommended_outcome`, `reasoning`, `audit_passed` present. Called by `GovernanceHaltHook.after_agent` (`hooks.py:126-163`).
- **JSON mode**: all LLM calls use `response_format={"type": "json_object"}` (`runner.py:522`). No strict JSON schema (`json_schema` mode) — this is a known gap.

### 7.3 Fairness / bias checkpoint — governance-verdict as terminal gate

The `governance-verdict` agent (Frontier model) performs a mandatory Phase 1 fairness audit before producing a verdict:
- Checks: balance, unsupported claims, logical fallacies, demographic bias, evidence completeness, precedent cherry-picking.
- Instruction from YAML (`governance-verdict.yaml:35`): "If ANY critical issue found: set recommendation to 'ESCALATE_HUMAN' and STOP."
- Instruction (`governance-verdict.yaml:52`): "Be AGGRESSIVE in flagging bias. False positives are acceptable."
- Halt mechanism: `GovernanceHaltHook.after_agent` halts pipeline when `fairness_check.critical_issues_found == True` and sets status to `escalated` (`hooks.py:151-162`; mirrored at `runner.py:659-670`).

### 7.4 Escalation triggers (two hard halts)

| Halt point | Trigger | Code |
|---|---|---|
| After `complexity-routing` | `state.status == CaseStatusEnum.escalated` | `hooks.py:92-114`, `runner.py:650-656` |
| After `governance-verdict` | `fairness_check.critical_issues_found` OR output integrity failure | `hooks.py:126-162`, `runner.py:659-670` |

Both halts emit a terminal SSE event (`agent="pipeline", phase="terminal"`) — `mesh_runner.py:580-606`.

### 7.5 Human-in-the-loop controls

- **Fact dispute**: `POST /cases/{case_id}/facts/{fact_id}/dispute` sets fact `status=disputed`, records actor + reason (`src/api/routes/judge.py:48-104`). Judge role required.
- **Reopen**: judge/senior judge files reopen request; approval re-enters pipeline at `evidence-analysis` (`src/api/routes/reopen_requests.py:104-141`).
- **Decision amendment**: amendments from junior judge route to senior-judge inbox as `pending_senior_review`; two-person rule enforced — cannot approve your own referral (`src/api/routes/senior_inbox.py:378-383, 419-422`).
- **Verdict recording**: `POST /cases/{case_id}/decision` records judge accept/modify/reject decision (`src/api/routes/decisions.py`).

### 7.6 Auth and rate limiting

- **JWT cookie auth**: HS256 token; session validated by hashing token against `Session.jwt_token_hash` (`src/api/deps.py:45-51`). Role guard: `require_role(*roles)` dependency (`deps.py:92`).
- **Rate limiting**: in-memory sliding window, 60 req/min per client IP, 429 + `Retry-After` (`src/api/middleware/rate_limit.py:16-72`). Note: in-memory = not shared across worker replicas.
- **Default JWT secret warning** at startup (`src/shared/config.py:model_post_init`).

---

## 8. Audit Trail and Tracing

### 8.1 CaseState append-only audit log

Every agent, every orchestrator action, every guardrail decision appends to `CaseState.audit_log: list[AuditEntry]`.

`AuditEntry` fields (`case_state.py:87-98`):
- `agent`, `timestamp`, `action`, `input_payload`, `output_payload`
- `system_prompt` (truncated), `llm_response`, `tool_calls`, `model`, `token_usage`
- `solace_message_id` (A2A correlation)

`APPEND_ONLY_FIELDS = {"audit_log"}` enforced at validation layer (`validation.py:25`).

Writers:
- `append_audit_entry` helper (`src/shared/audit.py:7-35`) using `model_copy`.
- Called at: `hooks.py:74, :138`; `runner.py:615`; `mesh_runner.py:375, :433, :546`.

### 8.2 PostgreSQL persistence

`AuditLog` ORM model (`src/models/audit.py:17-38`) — table `audit_logs`, JSONB columns for input/output/llm_response/tool_calls/token_usage, FK to cases with CASCADE.

Persisted by `_insert_audit_log` iterating `state.audit_log` (`src/db/persist_case_results.py:342-356`).

**Checkpoint replay**: `pipeline_checkpoints` table PK `(case_id, run_id)` with full `CaseState` JSONB (`src/db/pipeline_state.py:53-62`). Written per-agent-hop by `MeshPipelineRunner._checkpoint` (`mesh_runner.py:612-632`). Schema version gate prevents corrupt replays (`pipeline_state.py:39`).

### 8.3 Audit API

`GET /cases/{case_id}/audit` — filters by agent_name, from/to time, requires judge|admin role (`src/api/routes/audit.py:21-52`). Consumed by escalation, senior-inbox, decisions, and case-data routes.

### 8.4 Structured logging

`src/shared/logging.py:1-36` — `ContextVars` `case_id_var`, `run_id_var`; `CorrelationFilter` injects them into every log record. Solace message correlation via `solace_message_id` on `AuditEntry`.

### 8.5 Distributed tracing — CURRENT GAP

**No OpenTelemetry, no MLflow, no LangSmith, no Logfire instrumentation exists in any source file.** `MLFLOW_RESEARCH.md` at repo root documents the research but nothing is wired in `src/`.

**To close this gap (per MLFLOW_RESEARCH.md):**
1. Add `mlflow.openai.autolog()` to `runner.py` and `mesh_runner.py` (~1 hour). Captures all OpenAI API calls with inputs, outputs, latency, token usage.
2. Add `mlflow.start_span()` manual spans around custom tool calls for complete traces (~2–3 hours).
3. For CI audit evidence, add MLflow server to `docker-compose.infra.yml`.

This is the single highest-ROI technical gap for §7 MLSecOps grading.

---

## 9. Agent Tests

### 9.1 Backend test inventory

| Category | Key files | Notes |
|---|---|---|
| Agent behaviour | `test_judge_fairness_audit.py`, `test_decisions.py`, `test_escalation.py` | Core judicial domain tests |
| Pipeline orchestrator | `test_mesh_runner.py`, `test_pipeline_runner.py`, `test_layer2_aggregator.py` | Both runners + Redis barrier |
| Tools | `test_confidence_calc.py`, `test_cross_reference.py`, `test_timeline_construct.py`, `test_generate_questions.py`, `test_parse_document.py`, `test_search_precedents.py`, `test_vector_store_fallback.py` | One file per tool |
| Guardrails | `test_guardrails_activation.py`, `test_sanitization.py`, `test_validation.py` | Injection patterns, field ownership |
| Reliability | `test_circuit_breaker.py`, `test_retry.py`, `test_rate_limit.py`, `test_stuck_case_watchdog.py` | Infrastructure resilience |
| What-If | `test_what_if_controller.py`, `test_diff_engine.py`, `test_stability_score.py` | Scenario branching |
| API routes | `test_auth.py`, `test_cases.py`, `test_knowledge_base_routes.py`, `test_precedent_search.py` | HTTP layer |
| Integration | `test_sam_mesh_smoke.py` (requires live Solace, `-m mesh_smoke`, excluded from default CI) | SAM A2A round-trip |
| Eval / gold-set | `tests/eval/eval_runner.py` — 3 gold fixtures (REFUND_DISPUTE, SERVICE_COMPLAINT, TRAFFIC_APPEAL) | Requires real OpenAI API; excluded from CI |

**Guardrail test coverage** (`test_guardrails_activation.py:60-131`): tests regex injection patterns (`<|im_start|>`, `<system>`, `[INST]`), asserts `input_injection_blocked` appears in audit log.

### 9.2 Test harness design

- pytest-asyncio with `asyncio_mode = "auto"` (`pyproject.toml:71-73`).
- Mock LLM via `AsyncMock()` for OpenAI client (e.g. `test_guardrails_activation.py:47`, `test_mesh_runner.py:80-101`).
- `FakeA2AClient` for A2A tests (`test_guardrails_activation.py:15`).
- `_fake_session_factory` pattern for DB bypass.

### 9.3 Frontend tests

- 19 test files in `VerdictCouncil_Frontend/src/__tests__/`.
- Vitest (`vitest.config.js:6-22`), jsdom env, v8 coverage.
- Auth modules have 98% line/statement threshold; no global gate.
- Key tests: `backendSchemaContract.test.js` (contract testing), `caseWorkspace.test.js`, `escalationActions.test.jsx`, `KnowledgeBase.test.jsx`.
- Contract checker: `npm run check:contract` runs `scripts/check-api-contract.mjs`.

### 9.4 Test gaps (honest for presentation)

- No LLM-as-judge evaluator — `_score_output` in `eval_runner.py:18-64` is field-presence only, not semantic quality.
- No golden trajectory comparison (no tool-call sequence snapshots).
- No demographic bias eval set (no cases with race/gender attribute rotation).
- Eval suite excluded from CI (requires real OpenAI key, not run in `ci.yml`).
- Frontend CI (`Frontend/.github/workflows/ci.yml:31-35`) does NOT invoke Vitest — only lint + build.
- No backend coverage threshold gate in CI despite `--cov` in the test command.

---

## 10. CI/CD Pipeline

### 10.1 Backend CI (`VerdictCouncil_Backend/.github/workflows/ci.yml`)

| Job | What it does | Gate? |
|---|---|---|
| `lint` | ruff check + ruff format --check | Yes |
| `test` | pytest all unit tests with coverage report | Yes (but no threshold) |
| `openapi` | regenerate + diff `docs/openapi.json` | Yes |
| `security` | pip-audit + bandit | No (`continue-on-error: true`) |
| `docker` | build image (no push) | Yes |

MISSING from CI: mypy type-check (in Makefile but not CI), integration tests, eval suite, test coverage gate, container vuln scan (trivy/snyk), pre-commit hooks.

### 10.2 Backend CD

- `staging-deploy.yml` — triggers on push to `development`; builds `verdictcouncil:rc-${SHA}`, deploys to 12 DOKS deployments via `kubectl set image`, waits 300s for rollout.
- `production-deploy.yml` — triggers on push to `main`; `kubectl apply -k k8s/overlays/production/` + `kubectl set image deployment --all`.
- **No CI→CD gating** — deploys fire on branch push regardless of CI outcome.

### 10.3 Kubernetes manifests

`k8s/base/kustomization.yaml:4-25`: 12 Deployments (API + web-gateway + layer2 aggregator + 9 agents), Solace HA StatefulSet, HPA for web-gateway, Ingress, secrets, bootstrap job, stuck-case-watchdog CronJob.

Overlays: `staging` patches Ingress host; `production` namespace only.

Dockerfile: multi-stage (`Dockerfile:1-31`), Python 3.12-slim + pango/cairo/harfbuzz for PDF; non-root `vcagent` user; ENTRYPOINT is SAM CLI.

### 10.4 Frontend CI/CD

- `ci.yml`: Node 22, npm ci, lint, build — **Vitest NOT invoked**.
- `cd.yml`: GitHub Pages deploy (main only).
- Also deploys to DigitalOcean App Platform via `staging-deploy.yml` / `production-deploy.yml`.

### 10.5 For grading — framing as LLMSecOps

Current CI maps to these LLMSecOps stages:
- **Source**: gitflow in submodules (`feat/*` → `development` → `release/*` → `main`).
- **Build**: Docker multi-stage with non-root user.
- **Test**: 40+ unit tests including guardrail/injection tests; schema contract test.
- **SAST**: bandit (Python security linter), pip-audit (dependency CVEs) — both non-blocking today.
- **Deploy**: DOKS with staging/production overlays.
- **Monitor**: `/metrics` endpoint (`src/api/middleware/metrics.py`) for Prometheus-style metrics.

Missing for full LLMSecOps framing: adversarial input tests in CI, prompt version tracking (MLflow Prompt Registry), image vulnerability scan, AI quality gate (mlflow.evaluate()).

---

## 11. Component Interaction Summary

```
Judge (browser)
    │ HTTPS + JWT cookie
    ↓
FastAPI app (src/api/)
    │ POST /cases/{id}/process
    │ BackgroundTask spawns:
    ↓
MeshPipelineRunner (src/pipeline/mesh_runner.py)
    │ _run_before_run_hooks → InputGuardrailHook
    │
    │ L1 sequential:
    │   publish → Solace broker → case-processing SAM agent → response
    │   publish → Solace broker → complexity-routing SAM agent → response [HALT?]
    │
    │ L2 parallel asyncio.gather:
    │   publish → evidence-analysis
    │   publish → fact-reconstruction    All 3 write to Redis hash
    │   publish → witness-analysis       Lua barrier merges when complete
    │   ← aggregator publishes merged CaseState fragment
    │
    │ L3 sequential:
    │   → legal-knowledge [queries PAIR API + circuit breaker + vector store fallback]
    │   → argument-construction
    │   → deliberation
    │   → governance-verdict [fairness audit → HALT if critical]
    │
    │ per-agent: _checkpoint → PostgreSQL pipeline_checkpoints
    │ per-agent: SSE event → Redis pub/sub → frontend EventSource
    ↓
CaseState persisted → PostgreSQL (audit_logs, cases, verdicts, ...)
    ↓
Judge reviews dossier (CaseDossier.jsx)
    │ Can: record decision, dispute fact, create what-if scenario, flag bias
    ↓
What-If: WhatIfController deep-clones CaseState → run_from(re-entry agent)
```

---

## 12. Gaps vs Grading Requirements (Priority Order)

These are the gaps that matter most for the prof's assessment:

| # | Gap | Impact | Fix effort |
|---|---|---|---|
| 1 | No compiled group report document | Cannot be graded without it | Report-writing |
| 2 | IMDA Model AI Governance Framework not mentioned anywhere | §5 Responsible AI is a named requirement | ~2 hours writing |
| 3 | No formal AI Security Risk Register (table format) | §6 is explicitly Missing | ~2 hours writing |
| 4 | No distributed tracing (MLflow/OTel) | §7 "auditability" claim is unverified in code | ~1–3 hours coding |
| 5 | CI/CD doc (`06-cicd-pipeline.md`) contradicts actual workflow files | Credibility risk when grader compares docs to code | ~1 hour doc fix |
| 6 | Eval suite excluded from CI; no LLM quality gate | §7 "automated AI security tests" not present | 4–6 hours |
| 7 | Judge KB not injected into pipeline (no hook) | RAG pipeline claim is partial | Documented as gap |
| 8 | `MeshPipelineRunner` wired conditionally via `settings.use_mesh_runner` | Production uses mesh runner; `PipelineRunner` is local/test fallback — document which flag is set in each environment | Verify env var set correctly in k8s overlays |
| 9 | No reflection sections | §9 group + §7 individual are entirely missing | 1–2 hours writing |
| 10 | Individual report sections are all Missing | Per-person deliverables required | Each team member writes |

---

## 13. Justification Cheat-Sheet for Presentation Q&A

**Q: Why Solace Agent Mesh?**  
A: SAM provides the A2A pub/sub transport so each of 9 agents can be an independent process deployable as a separate Kubernetes pod. It handles the message format and broker connection — our team wrote all orchestration logic, routing, field ownership, and guardrails in Python. SAM is our messaging infrastructure, not our agent logic.

**Q: Why fixed topology, not a dynamic planner?**  
A: For a judicial AI system, deterministic ordering is a requirement, not a limitation. Every agent writes exactly its assigned fields; the audit log records every step in order; the pipeline can be replayed from any checkpoint. A dynamic planner would make the audit trail non-reproducible and the system harder to certify.

**Q: How do you prevent an agent from hallucinating legal citations?**  
A: The `legal-knowledge` agent system prompt explicitly says "never hallucinate citations; only use verbatim statutory text returned by your tools." The tools use either live PAIR API results or vector store file_search, both returning source-attributed content. The governance-verdict agent is instructed to check for unsupported citations in its Phase 1 fairness audit.

**Q: How do you handle adversarial document injection?**  
A: Two layers — regex patterns strip known ChatML/Llama/system-prompt tokens from all document content before LLM processing (`sanitization.py`); an LLM classifier catches subtler injection attempts (`guardrails.py`). Both layers run via `InputGuardrailHook` before the pipeline starts.

**Q: What's your observability story?**  
A: The `CaseState.audit_log` provides append-only per-agent tracing persisted to PostgreSQL. We have structured logging with correlation IDs. What we're missing is distributed trace export (OTel/MLflow) — we documented this gap and have a concrete 1-hour remediation (`mlflow.openai.autolog()`).

**Q: Why not use a higher-level framework like LangChain or AutoGen?**  
A: *(Phase 1 answer)* We chose programmatic orchestration because (a) the pipeline topology is fixed — a graph framework adds ceremony with no value for a fixed DAG; (b) field ownership enforcement and audit-trail requirements are easier to implement and verify in explicit Python than behind framework abstractions; (c) SAM's A2A protocol aligns with emerging industry standards for multi-agent systems.

> *(Phase 2 update)* The Phase 2 architecture **does** use a graph framework — LangGraph. The Phase 1 reasoning was wrong about "ceremony with no value": for a fixed DAG with parallel fan-out, four HITL gates, and durable replay, LangGraph's typed shared state, conditional edges, `Send`/`asyncio.gather` fan-out, and Postgres checkpointer earn their keep. The team rebuilt the pipeline as a `StateGraph` after the responsible-AI refactor; the field ownership invariants now live in the typed reducers (`_merge_case`) instead of an external allowlist.

---

## Phase 2: In-process LangGraph (Current Architecture)

The post-refactor system is intentionally smaller than the Phase 1 design. Each Phase 1 capability has a Phase 2 replacement; the diff explains *why* the team consolidated.

| Phase 1 (decommissioned) | Phase 2 (live) | Why the change |
|---|---|---|
| 9 per-agent SAM containers | 7 phase nodes inside one LangGraph `StateGraph` (`intake`, `research_{evidence,facts,witnesses,law}`, `synthesis`, `auditor`) | Per-agent containers were never load-bearing for a single-tenant judicial workload. The cost (per-agent Deployments, ClusterIP Services, NetworkPolicies, HMAC headers, mTLS, per-agent observability wiring) outweighed the benefit (independent scaling, blast radius). |
| Solace broker (3-node HA) for A2A pub/sub | In-process Python function calls | No broker means no broker outage class of bugs, no `solace-bootstrap` Job, no SMF TLS roadmap, no SEMPv2 ACL hardening. The graph is the bus. |
| `Layer2Aggregator` standalone service for the L2 fan-in barrier | `asyncio.gather` + the typed `_merge_case` reducer | The aggregator existed to re-implement state merge across processes. Once everything is in one process, the merge is the reducer. |
| Redis Lua barrier for idempotency on retries | LangGraph `AsyncPostgresSaver` checkpointer | Idempotency is now durable graph state keyed by `thread_id` (= `run_id`). Retries replay from checkpoint; there is no "did this message already arrive?" question to answer. |
| `MeshPipelineRunner` calling agents over Solace | `GraphPipelineRunner` invoking the compiled graph | Removed: broker timeout handling, `await_response` retry wrapper, per-agent HMAC signing, `DISPATCH_MODE=local|remote` toggle. Added: graph compilation, `interrupt(...)` / `Command(resume=...)` HITL gates. |
| Field ownership allowlist in `src/shared/validation.py` | Pydantic model boundaries + the typed `_merge_case` reducer | Each phase node returns a typed partial state with only its owned fields populated; the reducer merges without clobbering. The invariant lives in the type system, not in a runtime allowlist. |
| What-If: separate controller that deep-cloned `CaseState` | What-If: same LangGraph fork mechanism via a new `thread_id` derived from the parent run | One code path, not two. The fork is a graph operation, not a bespoke clone. |
| `governance-verdict` terminal agent producing a verdict recommendation | `auditor` node producing a fairness audit + governance summary, no recommendation | Aligned with the responsible-AI requirement that the system never recommend a verdict — it surfaces evidence and reasoning for the judge. |
| Custom UPSERT inside `pipeline_state.py` | Postgres `langgraph_checkpoint` table managed by LangGraph | Less code to maintain. The checkpointer is the source of truth; SQLAlchemy projections are derived. |

### What was kept

The judicial reasoning content — the agent prompts, the four-gate HITL flow, the model-tier strategy (`gpt-5.4-nano` for lightweight tasks → `gpt-5.4` for frontier reasoning), the LLM-guard prompt-injection defences (DeBERTa-v3 + regex), the audit log, the PAIR API circuit breaker, the curated vector store for SCT/State Court precedents — all carried over unchanged. The refactor was about transport and orchestration, not about the legal-reasoning surface.

### Deployment shape (Phase 2)

- **Backend**: DOKS, 2 Deployments (`api-service` + `arq-worker`), 1 CronJob (`stuck-case-watchdog`), 1 PRE_DEPLOY Job (`alembic-migrate`), NGINX Ingress + cert-manager. Same image for both Deployments; role selected by `command`/`args`. See `VerdictCouncil_Backend/k8s/`.
- **Frontend**: DO App Platform static site (`VerdictCouncil_Frontend/.do/`).
- **Managed services**: DO Managed Postgres 16 + Managed Redis 7 in the same VPC.
- **CI/CD**: GitHub Actions builds the image, pushes to DOCR, applies the kustomize overlay, renders runtime secrets, runs Alembic, rolls both Deployments. See `VerdictCouncil_Backend/.github/workflows/{staging,production}-deploy.yml`.

### What this means for grading

The Phase 1 narrative is still defensible *as Phase 1*: the team genuinely designed and implemented per-agent containers, a broker-backed A2A bus, a custom L2 aggregator, and a Redis Lua barrier. The grading question "is key logic designed by the team, not just platform config?" was true in Phase 1 (SAM was transport; agent reasoning, ownership, guardrails, halts were team code) and remains true in Phase 2 (LangGraph is the runtime; the seven phase nodes, four gates, fan-out routing, and reducer logic are team code). The shift was a deliberate scope-cut, not a capability loss.
