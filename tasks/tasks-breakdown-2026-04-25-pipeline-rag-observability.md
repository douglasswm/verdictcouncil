# Tasks Breakdown — Pipeline & Architecture Overhaul (rev 3)

**Derived from:** [`plan-2026-04-25-pipeline-rag-observability-overhaul.md`](./plan-2026-04-25-pipeline-rag-observability-overhaul.md) (rev 3 — agent architecture simplified)
**Revised:** 2026-04-25
- rev 1: initial breakdown
- rev 2: vendor cuts (drop Chroma/Cohere/RAGAS/MLflow; LangSmith native)
- rev 3 (this): **9 agents → 6 agents** (Option 2 architecture), drop fake reasoning tools, expand Sprint 0

All paths relative to `/Users/douglasswm/Project/AAS/VER/`. Backend paths under `VerdictCouncil_Backend/`, frontend under `VerdictCouncil_Frontend/`.

---

## Scope Revision Summary (rev 3)

| Dropped (rev 2) | Replaced with |
|---|---|
| Chroma + tsvector + RRF hybrid retrieval | Keep OpenAI vector stores; wrap with `@tool(response_format="content_and_artifact")` |
| Cohere rerank, `langchain-cohere` | Nothing (defer local cross-encoder) |
| RAGAS retrieval evals (D2) | Dropped — no retrieval engine swap |
| Feature-flag system | Not needed |
| MLflow surface (autolog, Prompt Registry, evaluate) | LangSmith natively |
| `prompt_version` audit column | LangSmith commit hash on trace |
| Per-tool MLflow spans (C3b) | LangSmith native |

| Dropped (rev 3) | Replaced with |
|---|---|
| 9 distinct agent prompts | 7 LangSmith prompts (intake, 4 research subagents, synthesis, audit) |
| `cross_reference`, `timeline_construct`, `confidence_calc`, `generate_questions` | Folded into agent native reasoning + structured output (subject to Sprint 0 §0.3 audit verdict) |
| `case-processing` + `complexity-routing` peer agents | Merged → single `intake` phase |
| `argument-construction` + `hearing-analysis` peer agents | Merged → single `synthesis` phase |
| 4 Gate-2 peer agents | Reframed as 4 parallel research subagents dispatched via `Send`; programmatic join |
| Agent-level rerun semantics | Phase-level rerun (`{"phase": "synthesis"}` instead of `{"agent": "evidence-analysis"}`) |

**Sprint 0 expanded:** now produces 4 deliverables (DB audit + output-model audit + tool audit + architecture proposal) gated by a single user approval before Sprint 1 starts.

## Parallelization Map

```
Sprint 0   Schema + output-model + tool + architecture audit + 4 governance-doc rewrites
           + per-agent design + golden cases + setup doc (14 tasks; serial; blocks Sprint 1)
Sprint 1   A1 (13 tasks: A1.0 deps + A1.PG saver + A1.1-A1.11 + 3 SEC)  ∥  C3a (5 tasks)
           ∥  DEP1 (3 tasks: langgraph.json + langgraph dev + runner mode plumbing)
Sprint 2   A2 (8 active tasks; A2.1, A2.4, A2.5 placeholders folded into Sprint 1)  ∥  C1 (8 tasks)
Sprint 3   B (7 tasks)  →  D1 (4 tasks)
Sprint 4   A3 (15)  ∥  A4 (3)  ∥  A5 What-If (4)  ∥  C4 (5)  ∥  C5 Sentry (3)  ∥  C5b HITL UX (5);  D3 (4) waits on D1
Sprint 5   DEP cloud deployment (11 tasks): provision services → LangGraph Platform deploy → BFF deploy → Vercel → smoke
Sprint 6+  E (7 tasks, deferred indefinitely)
```

**Codex adversarial review (rev 4 → rev 5) findings applied:**
- P0-1 dep migration: new task **1.A1.0** added at top of Sprint 1
- P0-2 gate stubs: new task **1.A1.PG** added; gate stubs in 1.A1.7 now call real `interrupt()` from day one
- P1-3 Send wiring: 1.A1.5 rewritten with proper `add_conditional_edges → list[Send]` pattern + reducer-backed accumulator
- P1-4 trace across worker boundary: 2.C1.4 expanded; persists `traceparent` in `pipeline_jobs` table
- P1-5 unified respond endpoint: new task **4.A3.15**; C5b.3 depends on it
- P1-6 audit table FK integrity: 4.C4.1 DDL rewritten with UUID + FK + CHECK + indexes
- P2-7 tool scoping: 1.A1.4 explicit `PHASE_TOOLS` / `RESEARCH_TOOLS` dicts + scoping tests
- Hygiene: `0.6` → `0.12` (10 sites), `npm run typecheck` → `npm run type-check` (4 sites), `settings.db_url` → `settings.database_url`, `settings.env` → new `settings.app_env`, "9 prompts" in Checkpoint 1b → "7 prompts"

**Target topology** (per Sprint 0 §0.4 architecture proposal):

```
START → intake → gate1
      → research_dispatch (Send to 4 subagents)
      → [evidence] [facts] [witnesses] [law]  (parallel)
      → research_join → gate2
      → synthesis → gate3
      → auditor → gate4 → END
```

6 agents (1 intake + 4 research subagents + 1 synthesis + 1 auditor); 7 LangSmith prompts; 3 real tools (`parse_document`, `search_legal_rules`, `search_precedents`).

## Drift Findings (from 2026-04-25 audit against submodule HEAD)

| Anchor | Status |
|---|---|
| `builder.py:148` `RetryPolicy`, `:64–117` retry routers | ✓ |
| `nodes/common.py:189–263, 163, 257, 121–135, 72–80, 364–375` | ✓ |
| `observability.py:24–40, 82–119, 122–137` | ✓ `tool_span()` unused |
| `db/pipeline_state.py:53–62` `_UPSERT_SQL` | ✓ |
| `runner.py` `graph.ainvoke(...)` | ✓ line 62 |
| `cases.py:1121–1272` SSE stream | ✓ |
| `cases.py:1275–1445` `/advance` | ✗ **drifted** — endpoint is `advance_gate` near line 1640 |
| `cases.py:1640–1758` rerun | ~ rerun 1700–1758; 1640–1700 is `advance_gate` |
| `services/knowledge_base.py:24–206` OpenAI vector store | ✓ |
| `pipeline/graph/tools.py:264–313` search tools | ✓ |
| Alembic latest | `0024_pipeline_events_replay.py` — new migrations start at **0025** |
| `judge_corrections` table | ✗ missing — Sprint 0 decides shape |
| `cost_usd` column | ✗ net-new |
| Frontend `sseClient.ts` | ✗ does not exist — C5.3 grep locator |
| Frontend `@sentry/react`, `src/sentry.ts` | ✗ net-new |
| `.github/workflows/eval.yml` | ✗ net-new (CODEOWNERS skipped per 2026-04-25 user decision) |

---

# Sprint 0 — Schema + Output-Model + Tool + Architecture Audit Spike

### Task 0.1: DB schema inventory

**Description:** Document current shape of every pipeline-touching table: `audit_log`, `pipeline_checkpoint`, `pipeline_event`, `pipeline_job`, `case`, `calibration`, `domain`, `user`, `admin_event`, `what_if`, `system_config`. For each: columns, writers, readers, observed cruft.

**Acceptance criteria:**
- [ ] `tasks/schema-audit-2026-04-25.md` with per-table sections
- [ ] Writers traced via grep (function names + file:line)
- [ ] Readers identified
- [ ] Cruft flagged (unused columns, duplicated intent, missing indexes on filter columns)

**Verification:**
- [ ] Self-review

**Dependencies:** None
**Files:**
- `tasks/schema-audit-2026-04-25.md` (new)

**Size:** M

### Task 0.2: Pydantic output-model inventory

**Description:** For each of the 9 current agents, find its output schema. Document: field count, required vs optional ratio, fields that trigger frequent retries, duplicate models, fields that could be `Literal`/`ge=/le=` instead of custom validators. Identify which fields collapse under the new 6-agent topology (e.g., the 4 Gate-2 outputs → one merged `ResearchOutput`).

**Acceptance criteria:**
- [ ] `tasks/output-model-audit-2026-04-25.md` per-agent sections
- [ ] Per-schema simplification proposal
- [ ] Mapping table: which existing fields land in which new phase output (IntakeOutput, EvidenceResearch / FactsResearch / WitnessesResearch / LawResearch, ResearchOutput, SynthesisOutput, AuditOutput)
- [ ] Flag schemas that should move to `create_agent(response_format=Schema)` unchanged vs need simplification first

**Verification:**
- [ ] Self-review

**Dependencies:** None
**Files:**
- `tasks/output-model-audit-2026-04-25.md` (new)

**Size:** M

### Task 0.3: Tool implementation audit (NEW in rev 3)

**Description:** Inspect each registered tool's implementation: `parse_document`, `cross_reference`, `timeline_construct`, `generate_questions`, `confidence_calc`, `search_precedents`, `search_domain_guidance`. Categorize each:
- **Real tool** — calls external API / runs deterministic code / wraps domain logic that isn't just an LLM call → keep
- **LLM-wrapper** — internally an LLM call dressed as a tool → drop
- **Redundant** — duplicates work the agent does natively in structured output → drop

**Acceptance criteria:**
- [ ] `tasks/tool-audit-2026-04-25.md` with per-tool verdict (real / LLM-wrapper / redundant) and one-line evidence (file:line of implementation)
- [ ] Final tool roster proposed (expected: ~3 real tools — `parse_document`, `search_legal_rules` (renamed from `search_domain_guidance`), `search_precedents`)
- [ ] If any tool is "real but worth simplifying," note the proposed change

**Verification:**
- [ ] Self-review

**Dependencies:** None
**Files:**
- `tasks/tool-audit-2026-04-25.md` (new)

**Size:** M

### Task 0.4: Architecture proposal (NEW in rev 3)

**Description:** Formalize the Option 2 6-agent architecture as a concrete spec for Sprint 1.

**Acceptance criteria:**
- [ ] `tasks/architecture-2026-04-25.md` covers:
  - Final agent topology (intake / 4 research subagents / synthesis / auditor) with one-line role per agent
  - 7 LangSmith prompt names + role one-liner each
  - `Send` fan-out signature for `research_dispatch` and merge function signature for `research_join`
  - Tool roster (post-0.3)
  - Per-phase model tier (e.g., intake = lightweight; research subagents = frontier; synthesis = frontier; auditor = frontier)
  - Per-phase response_format Pydantic models (high-level shape)
  - State schema deltas: which CaseState fields are populated by which phase
  - Phase-level rerun semantics (replaces agent-level rerun in `cases.py`)
- [ ] One-paragraph rationale for each agent boundary (why kept separate / why merged)

**Verification:**
- [ ] Self-review; key questions answered

**Dependencies:** 0.2, 0.3
**Files:**
- `tasks/architecture-2026-04-25.md` (new)

**Size:** L

### Task 0.5: Target schema doc (combines 0.1–0.4)

**Description:** Single proposal doc folding DB + Pydantic + tools + architecture into a unified target state. Migration sequence: which Sprint owns which migration.

**Acceptance criteria:**
- [ ] `tasks/schema-target-2026-04-25.md` covers:
  - Final DDL (all new/changed tables and columns)
  - Final Pydantic phase output models (referencing 0.4)
  - Final tool roster (referencing 0.3)
  - Migration sequence (which Sprint adds which migration; numbered 0025+)
- [ ] Explicit decisions recorded one-line each: single audit_log vs split, judge_corrections shape, output-model simplifications

**Verification:**
- [ ] 0.6 approval gate

**Dependencies:** 0.1, 0.2, 0.3, 0.4
**Files:**
- `tasks/schema-target-2026-04-25.md` (new)

**Size:** M

### Task 0.7: Update `RESPONSIBLE_AI_SECTION.md` for rev 3

**Description:** Rewrite the existing repo doc to reflect the 6-agent topology + LangSmith. Re-anchor all 4 IMDA pillar evidence pointers to rev 3 file:line locations. Replace references to mesh runner, governance-verdict, SAM, MLflow, FIELD_OWNERSHIP allowlist. Reuse §5 of the plan as the source of truth.

**Acceptance criteria:**
- [ ] All 4 pillar tables updated with rev 3 evidence
- [ ] No references to: `MeshPipelineRunner`, `governance-verdict`, SAM/Solace, MLflow, `FIELD_OWNERSHIP`
- [ ] Auditor agent referenced as the new independent fairness control
- [ ] Citation provenance section references `supporting_sources` + `suppressed_citation` table

**Verification:**
- [ ] Self-review against §5 of plan
- [ ] `grep -i "mesh\|governance-verdict\|mlflow\|FIELD_OWNERSHIP" RESPONSIBLE_AI_SECTION.md` returns zero (or only in archived footnotes)

**Dependencies:** 0.12
**Files:**
- `RESPONSIBLE_AI_SECTION.md` (update in place)

**Size:** M

### Task 0.8: Update `SECURITY_RISK_REGISTER.md` for rev 3

**Description:** Walk each of the 16 existing risks. Mark status: ✓ unchanged | strengthened | replaced | open. Add 3 new risks (R-17 topology cutover, R-18 LangSmith outage, R-19 Send-without-idempotency). Update the planned remediations list (drop "wire mlflow autolog" — closed by LangSmith).

**Acceptance criteria:**
- [ ] All 16 existing risks have rev-3 status column populated
- [ ] R-17, R-18, R-19 added with mitigation
- [ ] Risk Summary table recounted
- [ ] Planned Remediations list updated (mlflow item removed; bias eval set still open)

**Verification:**
- [ ] Self-review against §6 of plan

**Dependencies:** 0.12
**Files:**
- `SECURITY_RISK_REGISTER.md` (update in place)

**Size:** M

### Task 0.9: Update `MLSECOPS_SECTION.md` for rev 3

**Description:** Replace MLflow tracing sections (§7.4) with LangSmith. Add the new eval CI gate to the pipeline diagram (§7.2). Preserve §7.3 (10 adversarial CI tests) and §7.8 (DeBERTa-v3 RAG sanitizer) verbatim — those mitigations stay. Update the deployment table (drop Solace + MLflow rows).

**Acceptance criteria:**
- [ ] §7.4 rewritten for LangSmith (Client init at lifespan; auto-tracing via LangChain hooks; W3C trace_id propagation; per-tool spans native)
- [ ] §7.2 CI diagram includes `eval` job (LangSmith evaluate; >5% drop fails)
- [ ] §7.3 + §7.8 unchanged
- [ ] §7.6 deployment table: rows for Solace + MLflow removed; LangSmith (cloud) row added
- [ ] No `tool_span()` references (deleted helper)

**Verification:**
- [ ] Self-review against §7 of plan
- [ ] `grep -i "mlflow\|tool_span\|solace" MLSECOPS_SECTION.md` returns only archived footnotes

**Dependencies:** 0.12
**Files:**
- `MLSECOPS_SECTION.md` (update in place)

**Size:** M

### Task 0.10: Rewrite `AGENT_ARCHITECTURE.md` for rev 3

**Description:** Replace the 9-agent table + 4-gate diagram with the 6-agent topology + Send fan-out. Replace the FIELD_OWNERSHIP map with a per-phase Pydantic schema map. Acknowledge codex's findings (C1 wrong runner, C2 mesh field-ownership gap, C3 What-If empty state, H1-H4, M1-M3) and mark which are resolved by rev 3:

| Codex finding | rev 3 status |
|---|---|
| C1 — API wired to wrong runner | **resolved** — single `runner.py` path; mesh runner deleted |
| C2 — Field ownership not enforced in mesh path | **resolved** — Pydantic `extra="forbid"` enforces uniformly |
| C3 — What-If empty state | **resolved** — LangGraph fork via `update_state(past_config, ...)` |
| H1 — What-If bypass topology | **resolved** — same fork mechanism uses real graph |
| H2 — No durable job execution | **partial** — `PostgresSaver` checkpoints survive worker restart; full durable queue still tracked separately |
| H3 — SSE can hang | **resolved** — SSE bridges from `astream` chunks; terminal events emitted on every termination path |
| H4 — `CaseState` weakly typed | **resolved** — Pydantic schemas per phase output |
| M1 — Race-prone dedup | unchanged — out of scope |
| M2 — Orchestrator not pure | **resolved** — middleware separates concerns; runner is pure conductor |
| M3 — Schema drift (judge_kb_results undeclared) | **resolved** — Pydantic schemas declare every field |

**Acceptance criteria:**
- [ ] 6-agent topology diagram + per-phase table
- [ ] Codex findings table updated
- [ ] No references to mesh runner / SAM / governance-verdict / FIELD_OWNERSHIP / pipeline_state custom upsert

**Verification:**
- [ ] Self-review against §4 of plan and AGENT_ARCHITECTURE.md prior version

**Dependencies:** 0.12
**Files:**
- `AGENT_ARCHITECTURE.md` (update in place)

**Size:** M

### Task 0.11a: Author `tasks/agent-design-2026-04-25.md`

**Description:** Lightweight per-agent design doc covering all 7 agent prompts (1 intake + 4 research subagents + 1 synthesis + 1 auditor). For each: purpose, reasoning pattern, tools, response_format Pydantic schema (full shape with `extra="forbid"`), model tier, GraphState reads/writes, coordination protocol. Mirrors the lightweight template from §4 of the plan.

**Model tier mapping (decided 2026-04-25):**
- `intake` → `gpt-5.4-nano` (lightweight triage)
- `research-evidence`, `research-facts`, `research-witnesses`, `research-law` → `gpt-5.4` (frontier)
- `synthesis` → `gpt-5.4` (frontier)
- `auditor` → `gpt-5.4` (frontier)

**Acceptance criteria:**
- [ ] 7 agent specs
- [ ] Each spec has: purpose paragraph, reasoning pattern, tools list, full Pydantic schema (with field types + descriptions + `model_config = ConfigDict(extra="forbid")`), model tier per the mapping above, GraphState reads/writes, coordination notes
- [ ] Pydantic schemas align with Sprint 0 §0.2 output-model audit recommendations

**Verification:**
- [ ] Self-review for completeness; ~6-7 pages

**Dependencies:** 0.2, 0.3, 0.4, 0.12
**Files:**
- `tasks/agent-design-2026-04-25.md` (new)

**Size:** L

### Task 0.11b: Author golden eval cases (NEW — per Sprint 0 expansion decision)

**Description:** Hand-curate 5–10 realistic golden cases per demo domain (traffic court + small claims tribunal). Each case includes: input documents (synthetic), expected outputs per phase (intake / research / synthesis / audit), expected `source_id`s for citations. Stored as JSON fixtures under `VerdictCouncil_Backend/tests/eval/data/golden_cases/`.

This unblocks Sprint 3 D1.1 (LangSmith dataset sync) which would otherwise be a Sprint-3 blocker.

**Acceptance criteria:**
- [ ] 10–20 golden cases total (5–10 per domain)
- [ ] Each case has expected outputs for at least intake + research phases (synthesis/audit expected outputs optional but encouraged)
- [ ] Expected `source_id`s reference real chunks in the demo OpenAI vector stores
- [ ] Author attribution + date in each fixture file header

**Verification:**
- [ ] `wc -l VerdictCouncil_Backend/tests/eval/data/golden_cases/*.json` shows 10–20 files
- [ ] Manual: each case is realistic (not LLM-slop)

**Dependencies:** 0.11a (schemas must be defined before expected outputs can be authored)
**Files:**
- `VerdictCouncil_Backend/tests/eval/data/golden_cases/traffic-{1..N}.json` (new)
- `VerdictCouncil_Backend/tests/eval/data/golden_cases/small-claims-{1..N}.json` (new)

**Size:** L

### Task 0.11c: Author `docs/setup-2026-04-25.md` (NEW — per user request)

**Description:** Single setup doc listing every env var, every external account, every GitHub secret, every CLI tool the project depends on post-overhaul. Avoids surprises later. Sections:

1. **External accounts**:
   - LangSmith — org-id `7ac65285-8e05-408b-9c0e-c3939ca2cc7e`, workspace name to confirm, project name `verdictcouncil` (single project; env via metadata tag, not project name)
   - OpenAI — existing API key
2. **Required env vars** (split into `.env.example` for backend, `.env.example` for frontend):
   - Backend: `LANGSMITH_API_KEY`, `LANGSMITH_PROJECT=verdictcouncil`, `LANGSMITH_TRACING=true`, `OPENAI_API_KEY`, `DATABASE_URL`, `REDIS_URL`, etc.
   - Frontend: `VITE_SENTRY_DSN`, `VITE_API_URL`, etc.
3. **GitHub repo secrets** (configured by user in repo settings):
   - `LANGSMITH_API_KEY` — for eval CI gate (4.D3.1)
   - `OPENAI_API_KEY` — for eval CI gate (4.D3.1)
4. **CLI tools required for development**:
   - `uv` (Python deps)
   - `node` 20+ (frontend)
   - `docker` (local infra: Postgres, Redis)
5. **Branch protection rule** (user configures in GitHub):
   - Require PR review
   - Require status checks: lint, test, security, eval, docker

**Acceptance criteria:**
- [ ] Doc covers all env vars / secrets / accounts referenced anywhere in the codebase post-overhaul
- [ ] Each item marked: required-for-dev / required-for-prod / required-for-CI
- [ ] User can hand this doc to a teammate and they can boot the project end-to-end

**Verification:**
- [ ] Self-review against pyproject.toml + .env.example + .github/workflows/

**Dependencies:** 0.12
**Files:**
- `docs/setup-2026-04-25.md` (new)

**Size:** M

### Task 0.12: User approval gate

**Description:** Present 0.4 + 0.5 + 0.7–0.11c to user. Record approval inline. Nothing in Sprint 1 starts without this.

**Acceptance criteria:**
- [ ] Approval noted with date
- [ ] Sprint 1 cleared to start

**Verification:**
- [ ] Manual

**Dependencies:** 0.4, 0.5, 0.7, 0.8, 0.9, 0.10, 0.11a, 0.11b, 0.11c
**Files:** none
**Size:** XS

### Checkpoint 0 — Audit complete

- [ ] DB target schema approved
- [ ] Output-model simplifications approved
- [ ] Tool roster approved (final ~3 real tools)
- [ ] Agent topology approved (6 agents, 7 prompts)
- [ ] Migration sequence locked

---

# Sprint 1 — A1 (phased agents) + C3a (LangSmith Prompts)

## Workstream A1 — Phased `create_agent` + Send fan-out + middleware

**Architectural target (per Sprint 0 §0.4):** 6-agent topology with `make_phase_node(phase)` and `make_research_subagent(scope)` factories. Research phase fans out 4 parallel subagents via `Send`; programmatic join.

### Task 1.A1.0: Dependency migration to LangChain 1.x ecosystem (P0 — codex finding 1)

**Description:** Sprint 1 depends on `langchain.agents.create_agent`, structured `response_format`, and middleware decorators (`@wrap_tool_call`, `@wrap_model_call`, `@before_model`). The current `pyproject.toml` declares `langgraph>=0.2.0`, `langchain-core>=0.3.0`, `langchain-openai>=0.2.0`, and **no `langchain` package** — `create_agent` ships in `langchain>=1.0`. Without this upgrade, every A1 task fails at import time.

Required upgrades:
- `langchain>=1.0` (NEW)
- `langgraph>=0.4` (was `>=0.2.0`; `Send`, modern checkpointer protocol)
- `langchain-core>=0.3` (compatibility check)
- `langchain-openai>=0.3` (`response_format` Pydantic native handling)
- `langgraph-checkpoint-postgres>=2.0` (was implicit in 2.A2.1; promoted earlier — see 1.A1.PG)
- `langsmith>=0.3` (was 1.C3a.1)

**Acceptance criteria:**
- [ ] All listed deps installed; `uv sync` clean
- [ ] Import smoke test: `from langchain.agents import create_agent`, `from langchain.agents.middleware import wrap_tool_call, wrap_model_call`, `from langgraph.types import Send, interrupt, Command`, `from langgraph.checkpoint.postgres import PostgresSaver`, `from langsmith import Client` — all succeed
- [ ] API smoke test: minimal `agent = create_agent(model="gpt-5.4-nano", tools=[], system_prompt="echo")` invokes successfully against a mock model
- [ ] Pydantic v2 `response_format=Schema` returns validated instance (per the structured-output doc semantics)
- [ ] No deprecation warnings from langchain-core or langgraph during smoke test

**Verification:**
- [ ] `cd VerdictCouncil_Backend && uv sync`
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_dep_smoke.py`

**Dependencies:** None (precedes everything else in Sprint 1)
**Files:**
- `VerdictCouncil_Backend/pyproject.toml`
- `VerdictCouncil_Backend/uv.lock`
- `VerdictCouncil_Backend/tests/unit/test_dep_smoke.py` (new)

**Size:** S (mostly mechanical; possible dep-conflict resolution)

### Task 1.A1.PG: PostgresSaver wired at compile-time (P0 — codex finding 2)

**Description:** Codex flagged that Sprint 1's gate stubs break the HITL invariant: real `interrupt()`/resume needs a checkpointer at compile time, but full `PostgresSaver` cutover is deferred to Sprint 2. Fix: bring the **compile-time** checkpointer wiring into Sprint 1 (was 2.A2.4 + 2.A2.5).

Sprint 1 outcome: `build_graph(checkpointer=...)` accepts a checkpointer; `runner.py` instantiates `PostgresSaver` from `settings.database_url`, calls `.setup()` (idempotent), and passes it. Gate stubs (1.A1.7) call real `interrupt()` from day one — judge oversight is preserved across all of Sprint 1's intermediate landings.

Sprint 2 still owns: worker rewire (2.A2.6), in-flight migration (2.A2.7), prod cutover with maintenance window (2.A2.10), drop legacy table (2.A2.11). Renumber those if needed.

**Acceptance criteria:**
- [ ] `build_graph(checkpointer=None)` signature change with `None` default for tests
- [ ] `runner.py` instantiates `PostgresSaver.from_conn_string(settings.database_url)` once at startup; `setup()` called (idempotent)
- [ ] Tests use `InMemorySaver` via fixture; production uses `PostgresSaver`
- [ ] Custom `pipeline_state.upsert_pipeline_state` path retained until Sprint 2 cutover (read-only / shadow writes only — no removal yet)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_runner_checkpointed.py`
- [ ] Smoke: dev server boots, hits a single-phase test case → `pipeline_checkpoints` table receives writes via `PostgresSaver`

**Dependencies:** 1.A1.0
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/builder.py`
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py`
- `VerdictCouncil_Backend/tests/integration/test_runner_checkpointed.py` (new — covers fixture wiring)

**Size:** S

### Task 1.A1.1: Capture SSE wire-format golden fixtures

**Description:** Record byte-exact `AgentEvent`, `ToolEvent`, `ProgressEvent`, `HeartbeatEvent`, plus phase-level events (`phase_started`, `phase_complete`, `subagent_dispatched`, `subagent_complete`) from the current implementation as the regression oracle.

**Acceptance criteria:**
- [ ] ≥1 fixture per event type
- [ ] Includes a multi-tool-call run AND a Gate 2 (4 parallel agents) run for fan-out coverage

**Verification:**
- [ ] `ls VerdictCouncil_Backend/tests/fixtures/sse_wire_format/*.json` ≥ 5 files

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/tests/fixtures/sse_wire_format/*.json` (new)
- `VerdictCouncil_Backend/scripts/capture_sse_goldens.py` (new)

**Size:** S

### Task 1.A1.2: Middleware — SSE bridge + token usage + cancellation + audit

**Description:** Create `pipeline/graph/middleware/` with four hooks: `sse_tool_emitter` + `token_usage_emitter` in `sse_bridge.py`; `cancel_check` in `cancellation.py` (ports `check_cancel_flag`); `audit_tool_call` in `audit.py` (calls `append_audit_entry`).

**Acceptance criteria:**
- [ ] Four hooks; unit tests stub the writer
- [ ] `ruff check` clean

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_middleware.py`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/middleware/{__init__,sse_bridge,cancellation,audit}.py` (new)
- `VerdictCouncil_Backend/tests/unit/test_middleware.py` (new)

**Size:** M

### Task 1.A1.3: Runner stream adapter

**Description:** Bridge `graph.astream(stream_mode="custom")` → existing `publish_progress()` Redis publisher.

**Acceptance criteria:**
- [ ] `stream_to_sse(graph, initial_state, config, case_id)` drains and publishes
- [ ] Cancellation-safe; doesn't swallow graph exceptions

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_runner_stream_adapter.py`

**Dependencies:** 1.A1.2
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/runner_stream_adapter.py` (new)

**Size:** S

### Task 1.A1.4: Phase factory + research subagent factory + explicit PHASE_TOOLS scoping (P2 — codex finding 7)

**Description:** New `pipeline/graph/agents/factory.py`. Two factories:

- `make_phase_node(phase: str) -> Callable` — returns an async node that builds `create_agent(model=resolve_model(phase), tools=PHASE_TOOLS[phase], system_prompt=get_prompt(f"verdict-council/{phase}"), response_format=PHASE_SCHEMAS[phase], middleware=[cancel_check, sse_tool_emitter, audit_tool_call, token_usage_emitter])` and invokes it.
- `make_research_subagent(scope: str) -> Callable` — same pattern but pulls `verdict-council/research-{scope}` prompt and `RESEARCH_SCHEMAS[scope]`. Used by 4 parallel subagents (evidence, facts, witnesses, law).

**Tool scoping is least-privilege by design** (codex P2 finding). The previous draft said "likely all 3 tools across the board" — that's wrong. Auditor independence requires it has NO tools (it audits completed state, doesn't retrieve new evidence). Intake gets only `parse_document`. Search tools restricted to research-law and synthesis.

```python
# pipeline/graph/agents/factory.py

PHASE_TOOLS: dict[str, list[Tool]] = {
    "intake":    [parse_document],                                       # triage only
    "synthesis": [search_precedents],                                    # may need targeted follow-up
    "audit":     [],                                                     # ZERO tools — independence
}

RESEARCH_TOOLS: dict[str, list[Tool]] = {
    "evidence":  [parse_document],                                       # reads case docs
    "facts":     [parse_document],                                       # reads case docs
    "witnesses": [parse_document],                                       # reads case docs
    "law":       [search_legal_rules, search_precedents],                # only law subagent retrieves
}

def make_phase_node(phase: str) -> Callable: ...
def make_research_subagent(scope: str) -> Callable: ...
```

Native `response_format=Schema` handles structured output (LangChain's `ToolStrategy`/`ProviderStrategy` per the structured-output doc) — no custom parser.

**Acceptance criteria:**
- [ ] Two factories implemented
- [ ] `PHASE_TOOLS` and `RESEARCH_TOOLS` are explicit dicts (not `tools=ALL_TOOLS`)
- [ ] `PHASE_TOOLS["audit"] == []` enforced; auditor cannot retrieve
- [ ] `PHASE_TOOLS["intake"] == [parse_document]` enforced
- [ ] `RESEARCH_TOOLS["law"]` is the only entry containing `search_legal_rules` or `search_precedents`
- [ ] Native `response_format=Schema` handles structured output — no custom parser

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_agent_factory.py` — asserts each phase/scope's tool list explicitly
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_tool_scoping.py` — auditor invocation cannot reach search_*; intake invocation cannot reach search_*

**Dependencies:** 1.A1.0, 1.A1.2, 1.C3a.3, 0.12
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/agents/__init__.py` (new)
- `VerdictCouncil_Backend/src/pipeline/graph/agents/factory.py` (new)
- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (new — phase output Pydantic models per 0.4)
- `VerdictCouncil_Backend/tests/unit/test_tool_scoping.py` (new)

**Size:** M

### Task 1.A1.5: Research dispatch + join — proper LangGraph wiring (P1 — codex finding 3)

**Description:** Implement parallel research using LangGraph's canonical `Send`-via-conditional-edge pattern (NOT a "node returning list[Send]"). Three pieces:

**1) Reducer-backed accumulator on `GraphState`:**
```python
from typing import Annotated
import operator

class GraphState(TypedDict):
    # ... existing fields ...
    research_parts: Annotated[list[ResearchPart], operator.add]   # subagents append; reducer concatenates
```
`ResearchPart` is a discriminated union: `EvidenceResearch | FactsResearch | WitnessesResearch | LawResearch`.

**2) Dispatch as a regular node + conditional-edge router:**
```python
# pipeline/graph/research.py

def research_dispatch_node(state: GraphState) -> dict:
    """Plain node — produces a state update (no LLM call). Resets accumulator for re-entry safety."""
    return {"research_parts": []}  # empty list overwrites under add reducer (idempotent re-entry)

def route_to_research_subagents(state: GraphState) -> list[Send]:
    """Conditional-edge router. Returns one Send per subagent."""
    payload = {"case": state["case"], "extra_instructions": state.get("extra_instructions", {})}
    return [
        Send("research_evidence", payload),
        Send("research_facts", payload),
        Send("research_witnesses", payload),
        Send("research_law", payload),
    ]

def research_join_node(state: GraphState) -> dict:
    """Plain node — reads accumulated `research_parts` from state and merges into ResearchOutput."""
    parts = state["research_parts"]
    merged = ResearchOutput.from_parts(parts)  # classmethod handles partial/missing parts
    return {"case": {"research_output": merged}}
```

**3) Wire in `builder.py`:**
```python
g.add_node("research_dispatch", research_dispatch_node)
g.add_node("research_evidence", make_research_subagent("evidence"))
g.add_node("research_facts", make_research_subagent("facts"))
g.add_node("research_witnesses", make_research_subagent("witnesses"))
g.add_node("research_law", make_research_subagent("law"))
g.add_node("research_join", research_join_node)

g.add_edge("gate1_apply", "research_dispatch")
g.add_conditional_edges("research_dispatch", route_to_research_subagents,
                        ["research_evidence","research_facts","research_witnesses","research_law"])
# Each subagent → research_join (LangGraph fan-in via reducer accumulation)
g.add_edge("research_evidence", "research_join")
g.add_edge("research_facts", "research_join")
g.add_edge("research_witnesses", "research_join")
g.add_edge("research_law", "research_join")
g.add_edge("research_join", "gate2_pause")
```

Each research subagent's node returns `{"research_parts": [<their_output>]}` — the `operator.add` reducer concatenates across parallel branches.

**Acceptance criteria:**
- [ ] `GraphState.research_parts` reducer-backed (`Annotated[list[...], operator.add]`)
- [ ] Dispatch is a plain node + `add_conditional_edges` with `Send` factory; NOT a node returning `list[Send]`
- [ ] Join reads `state["research_parts"]` and merges via `ResearchOutput.from_parts(...)` classmethod
- [ ] Partial-output handling: if a subagent returns empty/error, `from_parts` includes a flag in the merged output (judge sees it at gate2)
- [ ] Subagent output schema (`EvidenceResearch` etc) declared as a discriminated union member of `ResearchPart`
- [ ] Re-entry safety: dispatch node resets accumulator (empty list under `add` is a no-op only on first entry; on re-run from gate2 with new instructions, the accumulator must be cleared via `Overwrite` semantics or explicit reset path — covered by 4.A3.x idempotency tests)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_research_fanout.py` — asserts: 4 subagents run; LangSmith trace shows overlapping spans (parallel); `research_parts` accumulates 4 entries; `from_parts` produces the expected merged shape
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_research_partial_output.py` — 1-3 of 4 subagents return empty; merge still produces a valid `ResearchOutput` with failure flags

**Dependencies:** 1.A1.4, 1.A1.PG
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/research.py` (new)
- `VerdictCouncil_Backend/src/pipeline/graph/state.py` (add `research_parts` reducer field)
- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (`ResearchPart` discriminated union; `ResearchOutput.from_parts` classmethod)

**Size:** M

### Task 1.A1.6: Rewrite `nodes/common.py` (delete legacy `_run_agent_node`)

**Description:** Delete the 290-line `_run_agent_node` (manual tool loop 189–263, `_token_usage` 72–80, cancel polling 163/257, prompt concat 121–135, custom output parser). The factory in 1.A1.4 replaces it. Keep small utility functions as needed.

**Acceptance criteria:**
- [ ] `nodes/common.py` ≤100 lines (was ~400)
- [ ] No references to deleted helpers anywhere in the codebase

**Verification:**
- [ ] `grep -r "_run_agent_node\|_token_usage\|check_cancel_flag" VerdictCouncil_Backend/src` returns zero (or only in scheduled-for-deletion paths)

**Dependencies:** 1.A1.4, 1.A1.5
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/common.py` (large delete)

**Size:** S

### Task 1.A1.7: Rewrite `builder.py` topology

**Description:** Replace 9-agent topology with the 6-agent phased topology:

```python
g.add_node("intake", make_phase_node("intake"), retry_policy=RetryPolicy(...))
g.add_node("gate1_pause", gate1_pause)
g.add_node("gate1_apply", gate1_apply)
g.add_node("research_dispatch", research_dispatch)
g.add_node("research_evidence", make_research_subagent("evidence"))
g.add_node("research_facts", make_research_subagent("facts"))
g.add_node("research_witnesses", make_research_subagent("witnesses"))
g.add_node("research_law", make_research_subagent("law"))
g.add_node("research_join", research_join)
g.add_node("gate2_pause", gate2_pause)
g.add_node("gate2_apply", gate2_apply)
g.add_node("synthesis", make_phase_node("synthesis"))
g.add_node("gate3_pause", gate3_pause)
g.add_node("gate3_apply", gate3_apply)
g.add_node("auditor", make_phase_node("audit"))
g.add_node("gate4_pause", gate4_pause)
g.add_node("gate4_apply", gate4_apply)
# edges + Send fan-out + conditional retry routers (existing semantic-incomplete logic, phase-keyed)
```

Retry routers (`builder.py:64–117`) update to key on **phase name**, not the old 9 agent names.

**Gate nodes call real `interrupt()` from day one** (P0 — codex finding 2). Stubs ≠ no-op auto-advance. The Sprint 1 minimal version:

```python
# pipeline/graph/nodes/gates.py — minimal real HITL (full UX in 4.A3)

from langgraph.types import interrupt, Command

def make_gate_pause(gate: str):
    async def pause(state: GraphState) -> dict:
        # Idempotent UPSERT for legacy compatibility (preserves existing case-list filters)
        await upsert_case_status(state["case"].case_id, f"awaiting_review_{gate}")
        # Real interrupt — judge oversight is preserved across all of Sprint 1
        decision = interrupt({
            "gate": gate,
            "case_id": state["case"].case_id,
            "phase_output": state["case"].snapshot_for_gate(gate),
            "trace_id": state.get("trace_id"),
            "actions": ["advance", "rerun", "halt"],
        })
        return {"_pending_action": decision}
    return pause

def make_gate_apply(gate: str, next_node: str):
    async def apply(state: GraphState) -> Command:
        action = state["_pending_action"]["action"]
        if action == "advance":
            await upsert_case_status(state["case"].case_id, f"advancing_to_{next_node}")
            return Command(update={"_pending_action": None}, goto=next_node)
        if action == "rerun":
            return Command(update={"extra_instructions": state["_pending_action"].get("notes")}, goto="<rerun_target_per_gate>")
        return Command(update={"halt": {"reason": "judge_halt"}}, goto=END)
    return apply
```

This minimal version supports the contract (advance/rerun/halt) but with rough payloads. **Full payloads, send-back, frontend wiring, idempotency-audit-of-INSERTs** are 4.A3's job. Sprint 1 lands HITL semantics and InMemorySaver/PostgresSaver compile-time wiring (1.A1.PG); Sprint 4 polishes everything around it.

**Acceptance criteria:**
- [ ] Graph compiles with `PostgresSaver` (or `InMemorySaver` in tests)
- [ ] `interrupt()` fires at every gate; `Command(resume={...})` resumes correctly
- [ ] Retry routers behave per-phase (not per-old-agent)
- [ ] Existing `RetryPolicy` (`:148`) preserved
- [ ] Sprint 1 manual smoke: full case run pauses at gate1, judge calls `/cases/{id}/advance` (existing endpoint), graph resumes through to gate2

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_graph_topology.py`
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_minimal_hitl.py` — full pause/resume cycle through all 4 gates with stub UX

**Dependencies:** 1.A1.0, 1.A1.4, 1.A1.5, 1.A1.PG
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/builder.py` (rewrite of `:151–244` and `:64–117`)
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/gates.py` (new — minimal real HITL pause/apply factories)

**Size:** M

### Task 1.A1.8: `runner.py` uses `stream_to_sse`

**Description:** Replace `graph.ainvoke(...)` at `runner.py:62` with `stream_to_sse(graph, ...)`.

**Acceptance criteria:**
- [ ] `ainvoke` not called in runner; terminal state shape unchanged

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_pipeline_smoke.py`

**Dependencies:** 1.A1.3, 1.A1.7
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py`

**Size:** XS

### Task 1.A1.9: SSE wire-format byte-equality test

**Description:** Run a canned case through the new graph; diff every SSE payload against 1.A1.1 goldens. Note: with the topology change, some events change semantics (new phase-level events, new fan-out events) — update goldens with explicit notes about which fields are expected to differ.

**Acceptance criteria:**
- [ ] Covers all event types
- [ ] Byte-equal where compatibility is contractual; documented diffs where new events appear

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_sse_wire_format.py`

**Dependencies:** 1.A1.1, 1.A1.8
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_sse_wire_format.py` (new)

**Size:** M (more nuanced than rev 2 because topology shifts SSE shape)

### Task 1.A1.10: Replay-N-cases regression harness

**Description:** 5 historical `CaseState` fixtures (reduced from 10 in rev 2 — fewer cases needed since the topology change makes precise replay-equality harder; focus on terminal state semantic equivalence). Diff terminal `case` field excluding nondeterministic fields. **Expect non-trivial differences** in intermediate state (we're collapsing 9 agents → 6); the test asserts terminal-state semantic equivalence (e.g. complexity_score within ±0.05, same `route` decision, same suppressed_citation count).

**Acceptance criteria:**
- [ ] 5 fixtures
- [ ] Test asserts semantic equivalence, not byte-equality, on the merged `case` field

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_pipeline_replay.py`

**Dependencies:** 1.A1.7
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_pipeline_replay.py` (new)
- `VerdictCouncil_Backend/tests/fixtures/replay_cases/*.json` (new)

**Size:** M

### Task 1.A1.11: Verify + manual UI smoke

**Description:** Full pytest + ruff + mypy; manual UI: React shows phase-level events (`intake_started`, `research_started`, 4 parallel `subagent_*` events, `synthesis_started`, `audit_started`); cancel halts ≤1 model turn; token usage visible in LangSmith UI per phase + per subagent.

**Acceptance criteria:**
- [ ] `pytest`, `ruff check`, `mypy` clean
- [ ] Manual smoke confirmed

**Verification:**
- [ ] Full suite

**Dependencies:** 1.A1.9, 1.A1.10
**Files:** none
**Size:** XS

### Task 1.A1.SEC1: Verify DeBERTa-v3 RAG sanitizer still wired

**Description:** Existing two-layer prompt-injection defence (regex L1 + DeBERTa-v3 L2 via `llm-guard`) at `src/shared/sanitization.py` is scoped to admin RAG ingest (`run_classifier=True` on `parse_document`). Verify it still fires after the architecture refactor — admin upload path is independent of the agent topology, but the smoke test is cheap insurance.

**Acceptance criteria:**
- [ ] Inject a known-malicious ChatML token in a test PDF; upload via admin endpoint
- [ ] Confirm `[CONTENT_BLOCKED_BY_SCANNER]` replacement happened
- [ ] Confirm `AdminEvent.regex_hits` and `classifier_hits` columns populated

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_rag_sanitizer.py`

**Dependencies:** 1.A1.7
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_rag_sanitizer.py` (new)

**Size:** S

### Task 1.A1.SEC2: Verify 10 adversarial guardrail tests still pass

**Description:** `tests/unit/test_guardrails_activation.py` (5 tests) and `tests/unit/test_guardrails_adversarial.py` (5 tests) test `InputGuardrailHook` / regex sanitizer behavior. After middleware refactor (1.A1.2), the test harness must adapt to the new wiring — the hooks themselves stay in `src/pipeline/guardrails.py`.

**Acceptance criteria:**
- [ ] All 10 tests pass
- [ ] If any required harness rewrite, document in test file

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_guardrails_*.py`

**Dependencies:** 1.A1.2, 1.A1.6
**Files:**
- `VerdictCouncil_Backend/tests/unit/test_guardrails_activation.py` (potential harness updates)
- `VerdictCouncil_Backend/tests/unit/test_guardrails_adversarial.py` (potential harness updates)

**Size:** S

### Task 1.A1.SEC3: Formalize FIELD_OWNERSHIP → Pydantic transition

**Description:** Per Sprint 0 §0.4 architecture proposal, the `FIELD_OWNERSHIP` allowlist in `src/shared/validation.py:4-22` is replaced by per-phase Pydantic `response_format` schemas with `model_config = ConfigDict(extra="forbid")`. This task: (a) ensure each phase output schema (`IntakeOutput`, `EvidenceResearch`, `FactsResearch`, `WitnessesResearch`, `LawResearch`, `SynthesisOutput`, `AuditOutput`) has `extra="forbid"`; (b) delete `FIELD_OWNERSHIP` dict and the `validate_*` strip-and-log code path; (c) add a regression test that an agent attempting to write an undeclared field raises `ValidationError`.

**Acceptance criteria:**
- [ ] Every phase Pydantic schema has `extra="forbid"`
- [ ] `FIELD_OWNERSHIP`, `validate_field_ownership`, `FieldOwnershipError` deleted from `src/shared/validation.py`
- [ ] No callers reference deleted symbols (`grep -r "FIELD_OWNERSHIP\|FieldOwnershipError" VerdictCouncil_Backend/src` returns zero)
- [ ] Regression test: agent that tries to emit `{"unknown_field": "x"}` raises Pydantic ValidationError; LangChain `ToolStrategy.handle_errors=True` retries once with corrective feedback

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_pydantic_field_enforcement.py`

**Dependencies:** 1.A1.4, 0.12
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (add `extra="forbid"`)
- `VerdictCouncil_Backend/src/shared/validation.py` (delete FIELD_OWNERSHIP)
- `VerdictCouncil_Backend/tests/unit/test_pydantic_field_enforcement.py` (new)

**Size:** M

### Checkpoint 1a — A1 complete

- [ ] 6-agent topology runs end-to-end on test cases
- [ ] LangSmith trace visible per run with: 1 intake span + 4 parallel research subagent spans + 1 synthesis span + 1 audit span
- [ ] Replay test green (semantic equivalence)
- [ ] React UI shows phase-level + subagent events
- [ ] Security checkpoints: DeBERTa sanitizer wired (1.A1.SEC1); 10 guardrail tests green (1.A1.SEC2); FIELD_OWNERSHIP fully replaced (1.A1.SEC3)

## Workstream C3a — LangSmith Prompts

### Task 1.C3a.1: Add LangSmith deps + env

**Description:** Add `langsmith>=0.3.0` to `pyproject.toml`. Set in `.env.example`:
- `LANGSMITH_API_KEY=` (user provides per `docs/setup-2026-04-25.md`)
- `LANGSMITH_PROJECT=verdictcouncil` (single project across envs; per user 2026-04-25)
- `LANGSMITH_TRACING=true`

Tag environment via run metadata (`config.metadata["env"] = os.getenv("APP_ENV", "dev")` — `Settings` does not currently expose an `env` field; this task adds `app_env: str = "dev"` to `src/shared/config.py`). Org id `7ac65285-8e05-408b-9c0e-c3939ca2cc7e` is implicit from the API key.

No custom code needed for tracing — LangSmith hooks LangChain automatically when `LANGSMITH_TRACING=true`.

**Acceptance criteria:**
- [ ] `from langsmith import Client` works
- [ ] `LANGSMITH_*` vars in `.env.example` (with placeholder values)
- [ ] Per-env metadata tag set in `runner.py:run` (e.g., `metadata={"env": "dev"|"staging"|"prod", ...}`)

**Verification:**
- [ ] `cd VerdictCouncil_Backend && uv sync`
- [ ] Boot dev server with vars set → trace appears in `verdictcouncil` project with `env: dev` tag

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/pyproject.toml`, `uv.lock`
- `VerdictCouncil_Backend/.env.example`

**Size:** XS

### Task 1.C3a.2: Author 7 new prompts + push to LangSmith

**Description:** **NOT** a 1:1 migration of the 9 existing prompts. Per Sprint 0 §0.4, author 7 new prompts targeting the new topology:

| LangSmith name | Role |
|---|---|
| `verdict-council/intake` | Triage + complexity + route (lightweight model) |
| `verdict-council/research-evidence` | Classify evidence; weight matrix; impartiality |
| `verdict-council/research-facts` | Fact ledger + timeline + causal chain |
| `verdict-council/research-witnesses` | Credibility (PEAR) + question bank |
| `verdict-council/research-law` | Statutes + precedents + citation provenance |
| `verdict-council/synthesis` | IRAC arguments + pre-hearing brief + judicial questions |
| `verdict-council/audit` | Independent fairness audit |

Each prompt distills the relevant slice of the existing 9-agent prompts. `scripts/migrate_prompts_to_langsmith.py` pushes them idempotently.

**Acceptance criteria:**
- [ ] 7 prompt files committed under `VerdictCouncil_Backend/prompts/` (markdown for review; pushed via script)
- [ ] Script idempotent (second run no-op)
- [ ] Each prompt explicitly references the relevant Pydantic response schema (so the agent knows the output contract)

**Verification:**
- [ ] `python VerdictCouncil_Backend/scripts/migrate_prompts_to_langsmith.py` twice
- [ ] All 7 visible in LangSmith UI as v1 commits

**Dependencies:** 1.C3a.1, 0.12
**Files:**
- `VerdictCouncil_Backend/prompts/{intake,research-evidence,research-facts,research-witnesses,research-law,synthesis,audit}.md` (new)
- `VerdictCouncil_Backend/scripts/migrate_prompts_to_langsmith.py` (new)

**Size:** L (the prompt-authoring work itself is substantial — distilling 9 prompts into 7 cohesive ones takes care)

### Task 1.C3a.3: Rewrite `prompts.py` as LangSmith lookup

**Description:** Replace `AGENT_PROMPTS` literal with `get_prompt(agent_name, judge_corrections=None) -> tuple[str, str]` (template, commit_hash). `lru_cache(maxsize=64)`. Judge corrections call `client.push_prompt(name, ...)` with a new commit instead of runtime concat.

**Acceptance criteria:**
- [ ] Literal dict removed (or kept as fallback only)
- [ ] Judge correction → new commit registered; cache key includes corrections
- [ ] Returns both template and commit hash

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_prompt_registry.py`

**Dependencies:** 1.C3a.2
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/prompts.py`

**Size:** S

### Task 1.C3a.4: Remove runtime concat at `nodes/common.py:121–135`

**Description:** Lands with 1.A1.4. Call `get_prompt(...)` instead of stitching corrections. Commit hash flows into LangSmith trace metadata automatically via LangChain's prompt tracing.

**Acceptance criteria:**
- [ ] Runtime concat removed
- [ ] LangSmith trace shows prompt commit

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_agent_node_factory.py`
- [ ] Manual: trigger judge correction; confirm new commit in LangSmith UI; agent run trace shows new commit hash

**Dependencies:** 1.A1.4, 1.C3a.3
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/common.py`

**Size:** XS

### Task 1.C3a.5: Unit test prompt resolver

**Description:** Cold lookup, cache hit, judge-correction-creates-new-commit paths. Mock `langsmith.Client`.

**Acceptance criteria:**
- [ ] 3 test cases pass
- [ ] Mock verifies `push_prompt` called exactly once on judge-correction path

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_prompt_registry.py`

**Dependencies:** 1.C3a.3
**Files:**
- `VerdictCouncil_Backend/tests/unit/test_prompt_registry.py` (new)

**Size:** S

### Checkpoint 1b — C3a complete

- [ ] 7 prompts visible as v1 commits in LangSmith UI (intake, research-{evidence,facts,witnesses,law}, synthesis, audit)
- [ ] Judge correction → new commit visible
- [ ] Agent run trace shows current prompt commit hash

## Workstream DEP1 — LangGraph CLI scaffolding (deployment readiness)

Lands `langgraph.json` and validates the graph loads via the LangGraph CLI. Same graph code runs locally via `langgraph dev` and on LangGraph Cloud via `langgraph build` (Sprint 5).

### Task 1.DEP1.1: Author `langgraph.json` at repo root

**Description:** Create the LangGraph CLI config file. Defines graph entry point, dependencies, env file. Single source of truth for `langgraph dev`, `langgraph build`, and LangGraph Cloud deployment.

```json
{
  "dependencies": ["./VerdictCouncil_Backend"],
  "graphs": {
    "verdictcouncil": "./VerdictCouncil_Backend/src/pipeline/graph/builder.py:build_graph"
  },
  "env": "./VerdictCouncil_Backend/.env",
  "python_version": "3.11"
}
```

**Acceptance criteria:**
- [ ] `langgraph.json` at repo root
- [ ] Graph entry resolvable: `python -c "from VerdictCouncil_Backend.src.pipeline.graph.builder import build_graph; print(build_graph())"` works
- [ ] LangGraph CLI installed in dev deps (`langgraph-cli`)

**Verification:**
- [ ] `langgraph --help` runs
- [ ] `langgraph dev --help` runs

**Dependencies:** 1.A1.7 (builder.py topology), 1.A1.0 (deps)
**Files:**
- `langgraph.json` (new — repo root)
- `VerdictCouncil_Backend/pyproject.toml` (add `langgraph-cli` to dev deps)

**Size:** XS

### Task 1.DEP1.2: Validate via `langgraph dev` locally

**Description:** Run `langgraph dev` and confirm the graph compiles, accepts a test invocation, and renders correctly in the LangGraph Studio dev UI (auto-launched at port 2024).

**Acceptance criteria:**
- [ ] `langgraph dev` starts; UI accessible at `localhost:2024`
- [ ] All 6 agents + research_dispatch + research_join + 4 gate pause/apply pairs visible in the topology view
- [ ] Test invocation against a synthesized case fixture runs to first interrupt; resume via Studio UI advances correctly
- [ ] Local LangSmith trace appears for the test run

**Verification:**
- [ ] `langgraph dev` followed by smoke test in browser

**Dependencies:** 1.DEP1.1, 1.A1.PG, 1.A1.7
**Files:** none (validation)
**Size:** XS

### Task 1.DEP1.3: Decide local-vs-cloud runtime selection in `runner.py`

**Description:** `runner.py` gains a runtime selector based on `settings.app_env` (or new `settings.graph_runtime`). Local dev uses in-process graph compiled with `PostgresSaver`. Production (Sprint 5) calls LangGraph Cloud HTTP API. Sprint 1 lands the in-process branch and a placeholder cloud branch (raises `NotImplementedError`); Sprint 5 task 5.DEP.6 fills in the cloud branch.

**Acceptance criteria:**
- [ ] `GraphPipelineRunner._mode` set from settings ("in_process" | "cloud")
- [ ] In-process branch fully wired; calls `astream` on local graph
- [ ] Cloud branch stub with TODO comment referencing 5.DEP.6
- [ ] Existing tests pass (default `app_env=dev` → in_process)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_runner_mode.py`

**Dependencies:** 1.A1.PG, 1.A1.8
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py`
- `VerdictCouncil_Backend/tests/integration/test_runner_mode.py` (new)

**Size:** S

### Checkpoint 1c — DEP1 complete

- [ ] `langgraph.json` committed; `langgraph dev` works locally
- [ ] LangGraph Studio renders the 6-agent topology
- [ ] Runner.py has runtime-selection plumbing ready for Sprint 5

---

# Sprint 2 — A2 + C1

## Workstream A2 — `PostgresSaver` hard cut

### Task 2.A2.1: ~~Add `langgraph-checkpoint-postgres`~~ (FOLDED INTO 1.A1.0)

**Status:** Subsumed by Sprint 1's `1.A1.0` dependency migration (added per codex P0 finding 1). Keep this slot as a numbered placeholder so downstream task numbers (2.A2.2 through 2.A2.11) are stable; do no work here.

### Task 2.A2.2: `scripts/check_casestate_serialization.py`

**Description:** Round-trip CaseState rows through `PostgresSaver.put`/`.get` and assert byte-equal. `CaseState` has tz-aware datetimes, custom Pydantic types, enums — msgpack may drop fields silently.

**Constraint (per user 2026-04-25): no staging DB available.** The script falls back to a curated suite of edge-case fixtures plus the 5 synthesized replay cases from 1.A1.10:

1. Synthesized cases (5, from 1.A1.10) — realistic but limited variety
2. **Edge-case stress fixtures (NEW, ~5 cases):** explicitly construct CaseStates with adversarial-for-msgpack fields:
   - tz-aware `datetime` (UTC and SGT)
   - Custom Pydantic `BaseModel` instances with custom validators
   - `Enum` and `IntEnum` values
   - Deeply-nested dict (5+ levels)
   - `extra_instructions` with multi-line strings, unicode, escape characters

**Acceptance criteria:**
- [ ] Diffs any lost field; exits non-zero on mismatch
- [ ] Human-readable report to `tasks/serialization-audit-<date>.md`
- [ ] Edge-case fixtures committed as test data
- [ ] Synthesized + edge-case suites both run

**Verification:**
- [ ] `python VerdictCouncil_Backend/scripts/check_casestate_serialization.py`

**Dependencies:** 2.A2.1, 1.A1.10
**Files:**
- `VerdictCouncil_Backend/scripts/check_casestate_serialization.py` (new)
- `VerdictCouncil_Backend/tests/fixtures/serialization_edge_cases/*.json` (new, ~5 fixtures)

**Size:** M (was S; bumped because fixtures are net-new with no staging-DB shortcut)

### Task 2.A2.3: Run serialization check — DEPLOY BLOCKER

**Description:** Run 2.A2.2 against the synthesized + edge-case fixture suite. **Stop and add custom msgpack encoders if any field is silently dropped.** No staging-DB dependency.

**Acceptance criteria:**
- [ ] Exit code 0 on the full fixture suite
- [ ] Report committed showing per-fixture pass/fail

**Verification:**
- [ ] Script return code 0
- [ ] `tasks/serialization-audit-<date>.md` exists with all fixtures green

**Dependencies:** 2.A2.2
**Files:** none (ops)
**Size:** XS (ops)

### Task 2.A2.4: ~~`build_graph(checkpointer=None)`~~ (FOLDED INTO 1.A1.PG)

**Status:** Compile-time checkpointer wiring moved to Sprint 1 per codex P0 finding 2 (gates need real `interrupt()` from day one). Keep slot for numbering stability.

### Task 2.A2.5: ~~`PostgresSaver` in `runner.py`~~ (FOLDED INTO 1.A1.PG)

**Status:** Same as 2.A2.4 — moved to Sprint 1. Keep slot for numbering stability.

### Task 2.A2.6: Rewire `workers/tasks.py:gate_run`

**Description:** Replace `pipeline_state.upsert_pipeline_state` reads/writes in `gate_run` (128–~251) with saver-based access. Keep outbox pattern.

**Acceptance criteria:**
- [ ] `upsert_pipeline_state` removed from `gate_run`
- [ ] State reads use `graph.get_state(config)`

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_worker_gate_run.py`

**Dependencies:** 2.A2.5
**Files:**
- `VerdictCouncil_Backend/src/workers/tasks.py`

**Size:** M

### Task 2.A2.7: `scripts/migrate_in_flight_cases.py`

**Description:** Seeds saver threads from `pipeline_checkpoints` rows. Supports `--dry-run`. Idempotent.

**Acceptance criteria:**
- [ ] `--dry-run` reports case count
- [ ] Real run idempotent

**Verification:**
- [ ] `python VerdictCouncil_Backend/scripts/migrate_in_flight_cases.py --dry-run`

**Dependencies:** 2.A2.3, 2.A2.5
**Files:**
- `VerdictCouncil_Backend/scripts/migrate_in_flight_cases.py` (new)

**Size:** S

### Task 2.A2.8: Checkpointer API integration test

**Description:** Exercise `get_state_history`, `update_state` with `Overwrite` for reducer-backed fields, `invoke(None, past_config)` replay, fork via `update_state(past, ...)`.

**Acceptance criteria:**
- [ ] All four APIs covered

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_checkpointer.py`

**Dependencies:** 2.A2.5
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_checkpointer.py` (new)

**Size:** M

### Task 2.A2.9: Cutover runbook

**Description:** Maintenance-window procedure: set `pause_intake` → drain workers → run `migrate_in_flight_cases.py` → deploy runner with saver → verify smoke → flip `pause_intake` off. Rollback: restore backup + revert to tagged pre-cutover release.

**Acceptance criteria:**
- [ ] Runbook at `VerdictCouncil_Backend/docs/runbooks/postgressaver-cutover.md`
- [ ] Rollback covered

**Verification:**
- [ ] Peer review

**Dependencies:** 2.A2.7
**Files:**
- `VerdictCouncil_Backend/docs/runbooks/postgressaver-cutover.md` (new)

**Size:** S

### Task 2.A2.10: Tag + execute cutover

**Description:** Tag `pre-postgres-saver-cutover` on `main`. Execute runbook.

**Acceptance criteria:**
- [ ] Tag pushed; cutover complete; in-flight cases resumed

**Verification:**
- [ ] Manual smoke during window

**Dependencies:** 2.A2.6, 2.A2.8, 2.A2.9
**Files:** none (ops)
**Size:** XS (ops)

### Task 2.A2.11: Post-burn-in cleanup

**Description:** After one release cycle of stable operation, Alembic drop migration for `pipeline_checkpoints`; delete `db/pipeline_state.py`.

**Acceptance criteria:**
- [ ] Migration clean
- [ ] No imports of `pipeline_state`

**Verification:**
- [ ] `grep -r "pipeline_state" VerdictCouncil_Backend/src` clean

**Dependencies:** 2.A2.10 + one release cycle
**Files:**
- `VerdictCouncil_Backend/alembic/versions/<next>_drop_pipeline_checkpoints.py` (new)
- `VerdictCouncil_Backend/src/db/pipeline_state.py` (delete)

**Size:** XS

### Checkpoint 2a — A2 complete

- [ ] Kill worker mid-pipeline → resume works
- [ ] `update_state(past, {"case": Overwrite(...)})` + replay preserves history
- [ ] Rollback validated in staging

## Workstream C1 — OTEL → LangSmith metadata

### Task 2.C1.1: Add OTEL deps

**Description:** `opentelemetry-instrumentation-fastapi`, `opentelemetry-exporter-otlp`. (`langsmith` already added in 1.C3a.1.)

**Acceptance criteria:**
- [ ] `uv sync` clean

**Verification:**
- [ ] `cd VerdictCouncil_Backend && uv sync`

**Dependencies:** 1.C3a.1
**Files:**
- `VerdictCouncil_Backend/pyproject.toml`, `uv.lock`

**Size:** XS

### Task 2.C1.2: Install `FastAPIInstrumentor`

**Description:** In `api/app.py:create_app` (130–208), `FastAPIInstrumentor.instrument_app(app)` early.

**Acceptance criteria:**
- [ ] Instrumentor called once
- [ ] OTEL spans emitted on requests

**Verification:**
- [ ] Dev boot → hit `/health` → OTEL span present

**Dependencies:** 2.C1.1
**Files:**
- `VerdictCouncil_Backend/src/api/app.py`

**Size:** XS

### Task 2.C1.3: `api/middleware/trace_context.py`

**Description:** Middleware reads active OTEL span (honoring inbound `traceparent`), stashes `trace_id` on `request.state`.

**Acceptance criteria:**
- [ ] Extracts hex `trace_id`
- [ ] Honors inbound header (no forced new trace)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_trace_context_middleware.py`

**Dependencies:** 2.C1.2
**Files:**
- `VerdictCouncil_Backend/src/api/middleware/trace_context.py` (new)

**Size:** S

### Task 2.C1.4: Pass `trace_id` in LangGraph config metadata — across the worker boundary (P1 — codex finding 4)

**Description:** Cases are processed asynchronously: the API endpoint enqueues into `pipeline_jobs`; a worker (`workers/tasks.py:gate_run`) picks up the job and runs `runner.py`. `request.state.trace_id` lives only in the API request context — it does NOT survive into the worker. The original draft (`runner.py reads request.state.trace_id`) only worked for direct-call tests.

**Fix:** Persist `traceparent` (W3C header form) in the job row at enqueue time; re-establish trace context in the worker.

**Required changes:**

1. **Schema:** new Alembic migration adds `pipeline_jobs.traceparent TEXT` column (nullable for backwards-compat with legacy queued jobs).
2. **API enqueue path** (`api/routes/cases.py:process_case`): build `traceparent = format_w3c_traceparent(current_span)` and store on the job row.
3. **Worker pickup** (`workers/tasks.py:gate_run`): read `job.traceparent`, parse into trace_id/span_id, set as the current OTEL span's parent, AND pass `trace_id` into LangGraph `config.metadata`.
4. **Runner** (`pipeline/graph/runner.py:run`): accept an explicit `trace_id: str | None` argument (decoupled from request state).

**Acceptance criteria:**
- [ ] `pipeline_jobs.traceparent TEXT` column added; migration clean up/down
- [ ] API endpoint stores traceparent at enqueue time
- [ ] Worker re-establishes trace context from the persisted traceparent (verify span parentage in OTEL exporter)
- [ ] `runner.py:run(case_state, trace_id: str | None = None)` signature; `config.metadata.trace_id` set
- [ ] Graceful fallback if `traceparent` is null (legacy queued jobs): worker logs warning and runs without trace continuity

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_trace_propagation.py::test_direct_call` — direct path
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_trace_propagation.py::test_worker_path` — enqueue → worker pickup → assert `trace_id` matches original API span across LangSmith metadata, SSE event, and worker's OTEL span parent

**Dependencies:** 2.C1.3
**Files:**
- `VerdictCouncil_Backend/alembic/versions/<next>_pipeline_jobs_traceparent.py` (new)
- `VerdictCouncil_Backend/src/models/pipeline_job.py`
- `VerdictCouncil_Backend/src/api/routes/cases.py` (enqueue path stores traceparent)
- `VerdictCouncil_Backend/src/workers/tasks.py` (`gate_run` extracts and re-establishes context)
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py` (signature change)

**Size:** M (was XS — outbox boundary handling is real work)

### Task 2.C1.5: Add `trace_id` to SSE payloads

**Description:** Every payload in `services/pipeline_events.py` gains `trace_id` (backward-compatible — consumers tolerate absence). Update 1.A1.1 goldens.

**Acceptance criteria:**
- [ ] Field on AgentEvent/ToolEvent/ProgressEvent/HeartbeatEvent
- [ ] Goldens updated

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_sse_wire_format.py`

**Dependencies:** 2.C1.4, 1.A1.1
**Files:**
- `VerdictCouncil_Backend/src/services/pipeline_events.py`
- `VerdictCouncil_Backend/tests/fixtures/sse_wire_format/*.json`

**Size:** S

### Task 2.C1.6: Frontend SSE type

**Description:** Add `trace_id?: string` to `VerdictCouncil_Frontend/src/lib/sseEvents.ts:5–45`.

**Acceptance criteria:**
- [ ] Typecheck green

**Verification:**
- [ ] `cd VerdictCouncil_Frontend && npm run type-check`

**Dependencies:** 2.C1.5
**Files:**
- `VerdictCouncil_Frontend/src/lib/sseEvents.ts`

**Size:** XS

### Task 2.C1.7: Delete MLflow surface

**Description:** Scrub MLflow from the codebase. Delete `mlflow.*` imports, autolog calls, tool_span helper, `agent_run` MLflow tags. Keep `pipeline/observability.py` as a thin file (or delete if empty). Remove `mlflow` from pyproject.

**Acceptance criteria:**
- [ ] `grep -r "mlflow" VerdictCouncil_Backend/src` returns zero
- [ ] `mlflow` absent from pyproject.toml and uv.lock

**Verification:**
- [ ] grep + `uv sync` clean
- [ ] `pytest VerdictCouncil_Backend/` clean

**Dependencies:** 1.C3a.1 (LangSmith live first)
**Files:**
- `VerdictCouncil_Backend/src/pipeline/observability.py` (large trim or delete)
- `VerdictCouncil_Backend/pyproject.toml`, `uv.lock`

**Size:** S

### Task 2.C1.8: End-to-end trace integration test

**Description:** POST to API with inbound `traceparent`. Assert `trace_id` in LangSmith metadata, SSE payload, OTEL span id — all equal.

**Acceptance criteria:**
- [ ] Three assertions in one test

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_trace_propagation.py`

**Dependencies:** 2.C1.4, 2.C1.5, 2.C1.7
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_trace_propagation.py` (new)

**Size:** S

### Checkpoint 2b — C1 complete

- [ ] React UI click → LangSmith trace for that case
- [ ] No MLflow anywhere in backend
- [ ] LangSmith trace carries `trace_id`, `thread_id`, prompt commit, per-tool spans — all native

---

# Sprint 3 — B (citation provenance) + D1 (LangSmith evals)

## Workstream B — Citation provenance on OpenAI vector store

### Task 3.B.1: Wrap `search_precedents_tool` with `content_and_artifact`

**Description:** Rewrite `pipeline/graph/tools.py:264–286`. Call existing `search_kb` / PAIR path; wrap result in `@tool(response_format="content_and_artifact")` returning `(formatted_string, list[Document])`. Each `Document.metadata = {"source_id": f"{file_id}:{sha256(content)[:12]}", "file_id": ..., "filename": ..., "score": ...}`.

**Acceptance criteria:**
- [ ] Tool returns content + artifact
- [ ] `ToolMessage.artifact` populated on tool call
- [ ] `source_id` stable (same content → same id across runs)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_tool_artifact.py::test_search_precedents`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/tools.py`

**Size:** S

### Task 3.B.2: Wrap `search_domain_guidance_tool` same pattern

**Description:** `tools.py:291–313`. Same pattern as 3.B.1.

**Acceptance criteria:**
- [ ] Identical shape

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_tool_artifact.py::test_search_domain_guidance`

**Dependencies:** 3.B.1
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/tools.py`

**Size:** S

### Task 3.B.3: Audit middleware persists `source_id`s

**Description:** Extend `middleware/audit.py` (1.A1.2) to extract source_ids from `ToolMessage.artifact` and write them (stash in `tool_calls` JSONB; 4.C4.1 adds proper column).

**Acceptance criteria:**
- [ ] Every search tool call → audit row carries source_ids
- [ ] Empty artifact handled

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_audit_source_ids.py`

**Dependencies:** 3.B.1
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/middleware/audit.py`

**Size:** S

### Task 3.B.4: Agent schemas add `supporting_sources`

**Description:** Per Sprint 0 §0.3 approved simplified schemas, add `supporting_sources: list[str]` to `legal_rules` and `precedents` items. Push new prompt commits via LangSmith that mandate the field.

**Acceptance criteria:**
- [ ] Pydantic schemas updated
- [ ] Prompts updated (new LangSmith commits)
- [ ] Legacy outputs without field still parse (optional with validator fallback)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_output_schema.py`

**Dependencies:** 1.A1.4, 0.4
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (or wherever output models live)
- LangSmith Prompts (new commits via `push_prompt`)

**Size:** S

### Task 3.B.5: Citation validation + suppression

**Description:** New `pipeline/graph/output_validator.py`. For every citation in agent structured output, check `source_id` exists in the run's aggregated `ToolMessage.artifact` chain. Unmatched → suppress + record with reason ENUM (`no_source_match`, `low_score`, `expired_statute`, `out_of_jurisdiction`). Until 4.C4.1 adds `suppressed_citation` table, log + stash in audit row.

**Acceptance criteria:**
- [ ] Hallucinated citation suppressed with reason
- [ ] Valid citation passes through

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_citation_provenance.py`

**Dependencies:** 3.B.3, 3.B.4
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/output_validator.py` (new)
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/common.py` (call site)

**Size:** M

### Task 3.B.6: Per-tenant access test

**Description:** OpenAI vector stores are per-judge (confirmed in `knowledge_base.py` — `vc-judge-{judge_id}`). Verify judge B cannot search judge A's store. This is a regression test, not new code.

**Acceptance criteria:**
- [ ] Test passes; zero cross-tenant leakage

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_vector_store_isolation.py`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_vector_store_isolation.py` (new)

**Size:** S

### Task 3.B.7: End-to-end citation provenance smoke

**Description:** Run a real case; every kept citation has a `source_id`; at least one citation deliberately hallucinated → ends up in suppressed list.

**Acceptance criteria:**
- [ ] Manual smoke passes

**Verification:**
- [ ] Manual

**Dependencies:** 3.B.5, 3.B.6
**Files:** none
**Size:** XS

### Checkpoint 3a — B complete

- [ ] Every cited source in agent output traces back to a retrieved `file_id`
- [ ] Fictitious citation → suppressed with reason
- [ ] Per-judge isolation intact

## Workstream D1 — LangSmith evaluations

### Task 3.D1.1: Sync golden dataset to LangSmith

**Description:** `tests/eval/dataset_sync.py` uploads local golden case fixtures to a LangSmith dataset (`verdict-council-golden`). Small (~5 cases per demo domain per Q3 answer). Idempotent.

**Acceptance criteria:**
- [ ] Dataset created in LangSmith UI
- [ ] Re-run does not duplicate examples

**Verification:**
- [ ] `python VerdictCouncil_Backend/tests/eval/dataset_sync.py`

**Dependencies:** 1.C3a.1
**Files:**
- `VerdictCouncil_Backend/tests/eval/dataset_sync.py` (new)
- `VerdictCouncil_Backend/tests/eval/data/golden_cases/*.json` (existing or new)

**Size:** S

### Task 3.D1.2: Custom evaluators

**Description:** `tests/eval/evaluators.py` with `CitationAccuracy` (every cited `source_id` appears in run's tool-artifact chain) and `LegalElementCoverage` (statutory elements addressed in `legal_rules`).

**Acceptance criteria:**
- [ ] Two evaluators follow LangSmith evaluator protocol (callable returning score + feedback)
- [ ] Unit tests cover pass + fail paths

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/eval/test_evaluators.py`

**Dependencies:** 3.B.5
**Files:**
- `VerdictCouncil_Backend/tests/eval/evaluators.py` (new)
- `VerdictCouncil_Backend/tests/eval/test_evaluators.py` (new)

**Size:** M

### Task 3.D1.3: `tests/eval/run_eval.py`

**Description:** `langsmith.evaluate(run_pipeline_for_eval, data="verdict-council-golden", evaluators=[CitationAccuracy(), LegalElementCoverage(), ...built-ins...])`. Logs experiment to LangSmith.

**Acceptance criteria:**
- [ ] Completes end-to-end
- [ ] Experiment appears in LangSmith UI with per-example feedback

**Verification:**
- [ ] `python VerdictCouncil_Backend/tests/eval/run_eval.py`

**Dependencies:** 3.D1.1, 3.D1.2
**Files:**
- `VerdictCouncil_Backend/tests/eval/run_eval.py` (new)

**Size:** S

### Task 3.D1.4: Capture baseline experiment

**Description:** Run `run_eval.py` against `main` post-B; tag the resulting LangSmith experiment as baseline. 4.D3.1 CI gate compares to this tag.

**Acceptance criteria:**
- [ ] Experiment exists and is named `baseline-<git-sha>`

**Verification:**
- [ ] LangSmith UI check

**Dependencies:** 3.D1.3
**Files:** none (LangSmith artifact)
**Size:** XS

### Checkpoint 3b — D1 complete

- [ ] LangSmith experiment visible with CitationAccuracy + LegalElementCoverage + built-ins on ~10 golden cases
- [ ] Baseline experiment tagged for CI comparison

---

# Sprint 4 — A3 + A4 + C4 + C5 + D3

## Workstream A3 — `interrupt()` + status compatibility

### Task 4.A3.1: Audit gate-end nodes for non-idempotent writes

**Description:** `interrupt()` re-runs the entire node on resume. Audit `case_processing.py`, `complexity_routing.py`, `gate2_join.py`, `argument_construction.py`, `hearing_analysis.py`, `hearing_governance.py` for INSERTs / external side-effects that double on re-run.

**Acceptance criteria:**
- [ ] `tasks/gate-node-idempotency-audit.md` per-file list

**Verification:**
- [ ] Self-review

**Dependencies:** None
**Files:**
- `tasks/gate-node-idempotency-audit.md` (new)

**Size:** S

### Task 4.A3.2: Convert INSERTs to UPSERTs

**Description:** For each non-idempotent write in 4.A3.1, UPSERT or move after `interrupt()`.

**Acceptance criteria:**
- [ ] Zero INSERTs / external side-effects before `interrupt()`

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_node_idempotency.py`

**Dependencies:** 4.A3.1
**Files:**
- ≤6 files under `VerdictCouncil_Backend/src/pipeline/graph/nodes/`

**Size:** M

### Task 4.A3.3: Gate review pause/apply pairs

**Description:** New per-gate node pairs: `gate{1,2,3,4}_review_pause.py` calls `interrupt({...})`; `gate{1,2,3,4}_review_apply.py` reads `_pending_action`, upserts legacy `awaiting_review_gateN` status (compatibility), emits `Command(goto=...)` per action.

**Acceptance criteria:**
- [ ] 8 new files (4 pause + 4 apply)
- [ ] Apply nodes idempotent (UPSERT only)
- [ ] Compatibility: `awaiting_review_gateN` + `gate_state` JSONB still written

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_interrupt_resume.py`

**Dependencies:** 4.A3.2, 2.A2.5
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/nodes/gate{1,2,3,4}_review_{pause,apply}.py` (8 new)

**Size:** L

### Task 4.A3.4: Wire into `builder.py`

**Description:** Insert pause→apply pair after each gate's final node. Edges: pause → apply → (dispatch | retry agent | END).

**Acceptance criteria:**
- [ ] Graph compiles
- [ ] Existing edges preserved

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_graph_topology.py`

**Dependencies:** 4.A3.3
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/builder.py`

**Size:** S

### Task 4.A3.5: `advance_gate` endpoint refactor

**Description:** **At `cases.py:~1640` (NOT 1275–1445 — plan reference is stale).** Replace state-manipulation with `await graph.ainvoke(Command(resume={"action":"advance"}), config)`.

**Acceptance criteria:**
- [ ] 200 on happy path
- [ ] Response schema preserved

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_advance_endpoint.py`

**Dependencies:** 4.A3.4
**Files:**
- `VerdictCouncil_Backend/src/api/routes/cases.py`

**Size:** S

### Task 4.A3.6: Rerun endpoint refactor — phase-level (NOT agent-level)

**Description:** `cases.py:~1700–1758`. Replace with `update_state(config, {"extra_instructions": ...})` + `Command(resume={"action":"rerun","phase":...})`. **Request body changes from `{"agent": "evidence-analysis"}` to `{"phase": "research"}` or `{"phase": "research", "subagent": "evidence"}` for finer-grained research re-runs.** This is a coordinated BE+FE change — confirm the React rerun UI was updated per Sprint 0 §0.4 architecture proposal.

**Acceptance criteria:**
- [ ] `phase` field in resume payload (not `agent`)
- [ ] Optional `subagent` field allows per-research-subagent rerun
- [ ] Synthesis rerun re-runs only synthesis (not the whole pipeline)
- [ ] Frontend rerun UI updated to send `phase`

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_rerun_endpoint.py`
- [ ] Manual: rerun synthesis from React UI

**Dependencies:** 4.A3.4
**Files:**
- `VerdictCouncil_Backend/src/api/routes/cases.py`
- `VerdictCouncil_Frontend/src/...` (rerun UI — locator from Sprint 0)

**Size:** M (BE+FE coordination)

### Task 4.A3.7: `InterruptEvent` in pipeline_events

**Description:** New event shape on each `interrupt()`. Legacy `awaiting_review` events stay.

**Acceptance criteria:**
- [ ] New type defined; existing consumers unchanged

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_pipeline_events.py`

**Dependencies:** 4.A3.3
**Files:**
- `VerdictCouncil_Backend/src/services/pipeline_events.py`

**Size:** S

### Task 4.A3.8: Frontend `InterruptEvent` type

**Description:** Add union case in `sseEvents.ts:5–45`.

**Acceptance criteria:**
- [ ] Typecheck green

**Verification:**
- [ ] `cd VerdictCouncil_Frontend && npm run type-check`

**Dependencies:** 4.A3.7
**Files:**
- `VerdictCouncil_Frontend/src/lib/sseEvents.ts`

**Size:** XS

### Task 4.A3.9: Cancellation via saver-halt

**Description:** Replace Redis cancel-flag with `graph.update_state(config, {"halt": ...})` + resume. `cancellation` middleware (1.A1.2) reads from saver state.

**Acceptance criteria:**
- [ ] Cancel halts ≤1 super-step
- [ ] Redis cancel-flag code path retired or neutralized

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_cancellation.py`

**Dependencies:** 4.A3.4
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/middleware/cancellation.py`
- `VerdictCouncil_Backend/src/api/routes/cases.py` (cancel endpoint)

**Size:** S

### Task 4.A3.10–12: Integration tests

**Description:** Three integration tests:
- `test_interrupt_resume.py` — gate1 → interrupt → advance → gate2
- `test_node_idempotency.py` — every gate-end node 2× → zero net DB change
- `test_cancellation.py` — halt → resume → END within 1 super-step

**Acceptance criteria:**
- [ ] All three pass

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_{interrupt_resume,node_idempotency,cancellation}.py`

**Dependencies:** 4.A3.5, 4.A3.6, 4.A3.9
**Files:**
- 3 test files (new)

**Size:** M

### Task 4.A3.13: Manual gate flow smoke

**Description:** Real case: gate1 advance → gate2; gate2 rerun `evidence-analysis` with extra_instructions → only that agent re-runs + new LangSmith prompt commit; cancel mid-pipeline halts ≤1 super-step.

**Acceptance criteria:**
- [ ] All three flows work

**Verification:**
- [ ] Manual

**Dependencies:** 4.A3.10–12
**Files:** none
**Size:** XS

### Task 4.A3.14: Auditor "send back to phase" mechanic

**Description:** `AuditOutput` schema gains optional `recommend_send_back: {to_phase: "intake|research|synthesis", reason: str}`. Gate4 review UI surfaces this recommendation. If judge selects "Send back to ▼ <phase>", backend handles `Command(resume={"action": "send_back", "to_phase": ..., "notes": ...})` by:
1. Resolving the phase's checkpoint config from `graph.get_state_history(case_config)`
2. `update_state(target_phase_config, {"extra_instructions": {target_phase: notes}})`
3. `invoke(None, target_phase_config)` to re-run from that phase forward

**Decision (per plan deferred Q):** the rewind does NOT clear later work; later state remains in the saver history. The new fork is a separate thread? **No** — same thread_id; later checkpoints become "stale" and accessible via `get_state_history` for audit. The current head moves to the rewound point.

**Acceptance criteria:**
- [ ] `AuditOutput` includes `recommend_send_back` (optional)
- [ ] Backend `cases.py:advance_gate` handles `action=send_back` correctly
- [ ] Stale checkpoints visible in `get_state_history` for audit
- [ ] Gate4 frontend (4.C5b.2) renders the recommendation when present

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_auditor_send_back.py`
- [ ] Manual: auditor flags an issue; judge sends back to synthesis; synthesis re-runs

**Dependencies:** 4.A3.5, 4.A3.6, 1.A1.4
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/schemas.py` (AuditOutput)
- `VerdictCouncil_Backend/src/api/routes/cases.py`
- `VerdictCouncil_Backend/tests/integration/test_auditor_send_back.py` (new)

**Size:** M

### Task 4.A3.15: Unified `POST /cases/{case_id}/respond` endpoint (P1 — codex finding 5)

**Description:** Frontend (C5b.3) posts gate-resume payloads to `/cases/{id}/respond`, but no backend task currently creates this endpoint. Codex flagged the gap. Fix: add a single unified endpoint that handles all four `action` types in one place, with shared authorization and validation. Existing `/advance` and `/rerun` routes can become thin wrappers that delegate to `/respond`, or be deprecated post-migration.

**Endpoint contract:**

```python
# api/routes/cases.py

@router.post("/cases/{case_id}/respond")
async def respond_to_gate(
    case_id: UUID,
    payload: ResumePayload,
    user: User = Depends(require_role("judge")),
    db: AsyncSession = Depends(get_db),
):
    """Unified gate response handler. Routes by payload.action."""
    config = {"configurable": {"thread_id": str(case_id)}}

    # Authorization: judge owns the case
    case = await db.get(Case, case_id)
    if case is None or case.judge_id != user.id:
        raise HTTPException(404, "Case not found")

    # Validate action against current gate state
    if not _is_resume_valid_for_current_gate(case, payload):
        raise HTTPException(409, "Action not valid for current gate")

    if payload.action == "advance":
        return await graph.ainvoke(Command(resume={"action": "advance", "notes": payload.notes}), config=config)
    if payload.action == "rerun":
        if payload.field_corrections:
            graph.update_state(config, payload.field_corrections)
        return await graph.ainvoke(Command(resume={"action": "rerun", "phase": payload.phase, "subagent": payload.subagent, "notes": payload.notes}), config=config)
    if payload.action == "halt":
        return await graph.ainvoke(Command(resume={"action": "halt", "reason": payload.notes or "judge_halt"}), config=config)
    if payload.action == "send_back":
        target_config = _resolve_phase_checkpoint_config(case_id, payload.to_phase)
        graph.update_state(target_config, {"extra_instructions": {payload.to_phase: payload.notes}})
        return await graph.ainvoke(None, config=target_config)
    raise HTTPException(422, f"Unknown action {payload.action}")

class ResumePayload(BaseModel):
    action: Literal["advance", "rerun", "halt", "send_back"]
    notes: str | None = None
    field_corrections: dict[str, Any] | None = None  # for gate3 inline edits → state mutation
    phase: Literal["intake", "research", "synthesis", "audit"] | None = None  # for rerun
    subagent: Literal["evidence", "facts", "witnesses", "law"] | None = None  # for research-phase rerun
    to_phase: Literal["intake", "research", "synthesis"] | None = None  # for send_back

    model_config = ConfigDict(extra="forbid")
```

Existing `/advance` and `/rerun` endpoints (4.A3.5, 4.A3.6) become thin wrappers that build the equivalent `ResumePayload` and call this handler internally. Frontend (C5b.3) targets `/respond` directly.

**Acceptance criteria:**
- [ ] `POST /cases/{case_id}/respond` endpoint with the exact contract above
- [ ] Authorization: judge owns the case (404 if not, no enumeration)
- [ ] Action validation against current gate state (409 if mismatch)
- [ ] All 4 action paths exercised by tests
- [ ] `ResumePayload` Pydantic model with `extra="forbid"` (regression test)
- [ ] Existing `/advance` and `/rerun` either deprecated or thin wrappers (decide during impl)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_respond_endpoint.py` — covers advance, rerun(phase=research, subagent=evidence), rerun(phase=synthesis with field_corrections), halt, send_back, and 409 for action-vs-current-gate mismatch
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_resume_payload.py` — validates extra="forbid", required-field combos by action

**Dependencies:** 4.A3.5, 4.A3.6, 4.A3.14
**Files:**
- `VerdictCouncil_Backend/src/api/routes/cases.py` (new endpoint)
- `VerdictCouncil_Backend/src/api/schemas/resume.py` (new — `ResumePayload`)
- `VerdictCouncil_Backend/tests/integration/test_respond_endpoint.py` (new)
- `VerdictCouncil_Backend/tests/unit/test_resume_payload.py` (new)

**Size:** M

### Checkpoint 4a — A3 complete

- [ ] All A3 tests + manual smoke green
- [ ] Case-list filters + watchdogs unchanged (compatibility layer wrote legacy status)
- [ ] Auditor send-back works end-to-end (4.A3.14)
- [ ] `/cases/{id}/respond` endpoint live (4.A3.15)

## Workstream A5 — What-If contestability (LangGraph fork)

R-10 in the security register; preserves IMDA Pillar 2 contestability under the new architecture. Replaces the legacy `WhatIfController` deep-clone path with native LangGraph fork primitives.

### Task 4.A5.1: Implement What-If via LangGraph fork

**Description:** Replace `services/whatif_controller/controller.py:create_scenario` deep-clone logic with `update_state(past_config, {"case": Overwrite(modified)})` + `invoke(None, fork_config)`. Use a separate `thread_id` for the fork (e.g., `f"{case_id}-whatif-{uuid}"`) to enforce R-10 isolation. The `parent_run_id` link is preserved in metadata.

**Acceptance criteria:**
- [ ] New `services/whatif/fork.py` with `create_whatif_fork(case_id, modifications)` returning `fork_thread_id`
- [ ] Uses `Overwrite` reducer for fields under custom `_merge_case` reducer
- [ ] R-10 isolation: judge B's fork cannot read judge A's case (thread_id includes judge_id)
- [ ] Fork's `parent_run_id` set in LangSmith metadata for traceability

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_whatif_fork.py`

**Dependencies:** 2.A2.5, 2.A2.8
**Files:**
- `VerdictCouncil_Backend/src/services/whatif/__init__.py` (new)
- `VerdictCouncil_Backend/src/services/whatif/fork.py` (new)

**Size:** M

### Task 4.A5.2: Delete legacy `WhatIfController`

**Description:** After 4.A5.1 verified at parity, delete `src/services/whatif_controller/`. Update `src/api/routes/what_if.py` to call new `services/whatif/fork.py` instead.

**Acceptance criteria:**
- [ ] `src/services/whatif_controller/` removed
- [ ] `what_if.py` updated; existing `/what-if/*` endpoints behave identically

**Verification:**
- [ ] `grep -r "whatif_controller\|WhatIfController" VerdictCouncil_Backend/src` returns zero
- [ ] Existing What-If integration tests pass

**Dependencies:** 4.A5.1
**Files:**
- `VerdictCouncil_Backend/src/services/whatif_controller/` (delete)
- `VerdictCouncil_Backend/src/api/routes/what_if.py`

**Size:** XS

### Task 4.A5.3: What-If frontend integration

**Description:** Add a "What if..." link in each gate review panel (4.C5b.1). Click opens a side-panel modal with quick toggles (e.g., "exclude evidence X", "treat fact Y as disputed"). Submitting calls `/what-if/create` which triggers 4.A5.1's fork. The fork's results stream into a side-by-side comparison view.

**Acceptance criteria:**
- [ ] "What if..." button on `<GateReviewPanel>` for gates 2, 3, 4 (not 1 — too early)
- [ ] Modal supports common modifications (evidence-exclude, fact-toggle, witness-credibility-override)
- [ ] Side-by-side compare view (current case vs fork)
- [ ] Both threads visible in LangSmith UI

**Verification:**
- [ ] Manual: open gate 3, click "What if we excluded the police body cam?", confirm fork launches and renders comparison

**Dependencies:** 4.A5.1, 4.C5b.1
**Files:**
- `VerdictCouncil_Frontend/src/features/whatif/*` (new)
- `VerdictCouncil_Frontend/src/components/GateReviewPanel.tsx` (extend)

**Size:** M

### Task 4.A5.4: Fork isolation integration test

**Description:** Two-part test: (a) fork preserves original case state — original thread untouched; (b) modifications applied to fork only — running both forward produces different terminal states; (c) cross-judge isolation — judge A creates fork; judge B querying with A's fork thread_id is rejected.

**Acceptance criteria:**
- [ ] (a) (b) (c) all pass
- [ ] Fork's LangSmith trace links back to parent

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_whatif_isolation.py`

**Dependencies:** 4.A5.1
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_whatif_isolation.py` (new)

**Size:** S

### Checkpoint 4a-bis — What-If complete

- [ ] What-If fork works via LangGraph primitives
- [ ] Legacy controller deleted
- [ ] R-10 cross-judge isolation verified
- [ ] Frontend side-by-side comparison renders

## Workstream C5b — HITL UX (frontend gate review panels)

Per plan §8 wireframes. Implements the judge-facing UX for the 4 gates.

### Task 4.C5b.1: `<GateReviewPanel>` shared component

**Description:** New React component in `VerdictCouncil_Frontend/src/components/GateReviewPanel.tsx`. Props: `{ gate: 1|2|3|4, phaseOutput: PhaseOutput, traceId: string, traceUrl: string, onAction: (payload: ResumePayload) => void }`. Renders: header (case_id + gate label), body slot (per-gate component), free-text notes textarea, action buttons (advance / re-run / halt; gate4 also gets send-back-to-phase dropdown), trace link, audit-log link.

**Acceptance criteria:**
- [ ] Component file with TypeScript types matching the `Command(resume=...)` payload contract
- [ ] Renders correctly with mock interrupt payloads for all 4 gates
- [ ] `onAction` called with valid payload on button click
- [ ] Tailwind/shadcn styling consistent with existing UI

**Verification:**
- [ ] `cd VerdictCouncil_Frontend && npm run type-check`
- [ ] `cd VerdictCouncil_Frontend && npx vitest run src/components/GateReviewPanel.test.tsx`

**Dependencies:** 4.A3.7, 4.A3.8 (InterruptEvent type lands)
**Files:**
- `VerdictCouncil_Frontend/src/components/GateReviewPanel.tsx` (new)
- `VerdictCouncil_Frontend/src/components/GateReviewPanel.test.tsx` (new)
- `VerdictCouncil_Frontend/src/types/resumePayload.ts` (new — typed contract)

**Size:** M

### Task 4.C5b.2: Per-gate body components

**Description:** Four body components rendered inside `<GateReviewPanel>`:

- `<Gate1IntakeReview phaseOutput={IntakeOutput}>` — domain / parties / complexity / route / red flags / completeness; document list (sanitized); free-text notes
- `<Gate2ResearchReview phaseOutput={ResearchOutput}>` — tabbed (Evidence / Facts / Witnesses / Law); evidence weight matrix viz; per-subagent rerun checkboxes; fact dispute markers
- `<Gate3SynthesisReview phaseOutput={SynthesisOutput}>` — claimant/respondent IRAC side-by-side; collapsible pre-hearing brief; collapsible judicial questions; uncertainty flags
- `<Gate4AuditorReview phaseOutput={AuditOutput}>` — fairness findings list with severity icons; citation audit summary; cost/tokens/duration footer; "Send back to ▼ <phase>" dropdown surfacing `recommend_send_back` if present

**Acceptance criteria:**
- [ ] All 4 body components render against fixture data
- [ ] Gate2 multi-select rerun emits resume payload with `subagent: "evidence" | "facts" | ...`
- [ ] Gate3 supports inline edit of judicial questions (state local; included in resume payload as `field_corrections`)
- [ ] Gate4 send-back dropdown surfaces auditor recommendation when present

**Verification:**
- [ ] Storybook (or equivalent) renders all 4 with realistic fixtures
- [ ] `npx vitest run src/components/Gate*Review.test.tsx`

**Dependencies:** 4.C5b.1
**Files:**
- `VerdictCouncil_Frontend/src/components/Gate1IntakeReview.tsx` (new)
- `VerdictCouncil_Frontend/src/components/Gate2ResearchReview.tsx` (new)
- `VerdictCouncil_Frontend/src/components/Gate3SynthesisReview.tsx` (new)
- `VerdictCouncil_Frontend/src/components/Gate4AuditorReview.tsx` (new)
- `VerdictCouncil_Frontend/src/components/Gate*Review.test.tsx` (new each)

**Size:** L

### Task 4.C5b.3: SSE consumer mounts panel on InterruptEvent

**Description:** When the SSE stream emits an `InterruptEvent` (added by 4.A3.7), the case detail page mounts the appropriate `<GateReviewPanel gate=N>` with the interrupt payload. On action click, POST the resume payload to `POST /cases/{id}/respond` — the unified backend endpoint defined by **4.A3.15**. (No fallback to legacy `/advance`; that path is retained only for any non-frontend caller and is a thin wrapper around `/respond` internally.)

**Acceptance criteria:**
- [ ] InterruptEvent triggers panel mount
- [ ] Action click POSTs correct payload; UI shows loading; SSE resumes after backend response
- [ ] Halt action correctly terminates the SSE stream

**Verification:**
- [ ] Manual: full case → click through gate1 advance, gate2 advance, gate3 rerun, gate4 send-back
- [ ] No console errors

**Dependencies:** 4.C5b.2, 4.A3.7, **4.A3.15** (backend `/respond` endpoint)
**Files:**
- `VerdictCouncil_Frontend/src/features/cases/CaseDetailPage.tsx` (or equivalent — locator from earlier)

**Size:** M

### Task 4.C5b.4: Frontend tests for gate panels

**Description:** Vitest unit tests for each panel rendering and action emission. Mock `onAction` callback; click each button; assert payload shape.

**Acceptance criteria:**
- [ ] One test file per gate panel
- [ ] All passing

**Verification:**
- [ ] `npx vitest run src/components/`

**Dependencies:** 4.C5b.2
**Files:**
- `VerdictCouncil_Frontend/src/components/Gate*Review.test.tsx`

**Size:** S

### Task 4.C5b.5: End-to-end manual smoke

**Description:** Full case run with judge clicking through all 4 gates via real React UI → final `judicial_decision` recorded in DB.

**Acceptance criteria:**
- [ ] Real case completes; gate1 → gate2 (rerun evidence with notes) → gate3 (advance) → gate4 (send-back to synthesis, then approve) → END
- [ ] `judicial_decision` JSONB populated with `ai_engagements` per conclusion
- [ ] LangSmith trace shows all phases + subagents + send-back rewind

**Verification:**
- [ ] Manual

**Dependencies:** 4.C5b.3, 4.A3.14, 4.A5.3
**Files:** none
**Size:** XS

## Workstream A4 — Retry router cleanup

### Task 4.A4.1: Move `retry_counts` increment into reducer (phase-keyed)

**Description:** Data/control separation in `builder.py:64–117`. `retry_counts` updated only via reducer. **Note:** the routers were rewritten in 1.A1.7 to key on phase names (intake / research / synthesis / audit), not the legacy 9 agent names. This task verifies the reducer matches.

**Acceptance criteria:**
- [ ] No direct mutation outside reducer
- [ ] Behavior unchanged

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_retry_router.py`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/builder.py`
- `VerdictCouncil_Backend/src/pipeline/graph/state.py`

**Size:** S

### Task 4.A4.2: Separate conditional edge for retry routing

**Description:** Extract route logic into a pure-function `add_conditional_edges` call. ~30 lines net reduction.

**Acceptance criteria:**
- [ ] Routers pure (no side effects)
- [ ] Behavior unchanged

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_pipeline_smoke.py`

**Dependencies:** 4.A4.1
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/builder.py`

**Size:** S

### Task 4.A4.3: Retry router unit test

**Description:** Semantic-incomplete output retries up to `max_attempts`, then escalates.

**Acceptance criteria:**
- [ ] Passes

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_retry_router.py`

**Dependencies:** 4.A4.2
**Files:**
- `VerdictCouncil_Backend/tests/unit/test_retry_router.py` (new)

**Size:** S

## Workstream C4 — Audit schema + `suppressed_citation` + `judge_corrections`

### Task 4.C4.1: Alembic 0025 — full audit upgrade with proper FK integrity (P1 — codex finding 6)

**Description:** Per Sprint 0 §0.5 approved target. Adds: `audit_log.{trace_id, span_id, retrieved_source_ids, cost_usd, redaction_applied, judge_correction_id}`. Creates: `judge_corrections`, `suppressed_citation`. **Both new tables key on `phase` (not `agent_name`)** to match the new topology. **No `prompt_version` column** (LangSmith owns it).

**Codex flagged P1 integrity issue:** the prior draft used `case_id TEXT NOT NULL` with no foreign key. Existing case-linked tables in the codebase use `UUID` FKs to `cases.id`. The fix below uses proper `UUID` + `FK` + `ON DELETE CASCADE` + indexes + check constraints so records can't become orphaned or cross-tenant ambiguous.

```sql
CREATE TABLE judge_corrections (
    id BIGSERIAL PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('intake','research','synthesis','audit')),
    subagent TEXT CHECK (subagent IS NULL OR subagent IN ('evidence','facts','witnesses','law')),
    -- subagent only meaningful when phase = 'research'
    CHECK (subagent IS NULL OR phase = 'research'),
    correction_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX judge_corrections_case_idx   ON judge_corrections (case_id);
CREATE INDEX judge_corrections_run_idx    ON judge_corrections (run_id);

CREATE TABLE suppressed_citation (
    id BIGSERIAL PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('intake','research','synthesis','audit')),
    subagent TEXT CHECK (subagent IS NULL OR subagent IN ('evidence','facts','witnesses','law')),
    CHECK (subagent IS NULL OR phase = 'research'),
    citation_text TEXT NOT NULL,
    reason TEXT NOT NULL CHECK (reason IN ('no_source_match','low_score','expired_statute','out_of_jurisdiction')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX suppressed_citation_case_idx ON suppressed_citation (case_id);
CREATE INDEX suppressed_citation_run_idx  ON suppressed_citation (run_id);

ALTER TABLE audit_log
    ADD COLUMN trace_id              TEXT,
    ADD COLUMN span_id               TEXT,
    ADD COLUMN retrieved_source_ids  JSONB,
    ADD COLUMN cost_usd              NUMERIC(10, 6),
    ADD COLUMN redaction_applied     BOOLEAN DEFAULT FALSE,
    ADD COLUMN judge_correction_id   BIGINT REFERENCES judge_corrections(id) ON DELETE SET NULL;
CREATE INDEX audit_log_trace_idx ON audit_log (trace_id);
```

**Acceptance criteria:**
- [ ] Migration clean up + down
- [ ] `case_id` is `UUID` with `FK → cases(id) ON DELETE CASCADE` on both new tables
- [ ] Phase + subagent CHECK constraints enforced (db-level)
- [ ] Indexes on `case_id`, `run_id`, and `audit_log.trace_id`
- [ ] Pydantic SQLAlchemy models declare `ForeignKey` matching the DDL

**Verification:**
- [ ] `alembic upgrade head && alembic downgrade -1 && alembic upgrade head`
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_audit_schema.py` — INSERT with non-existent `case_id` is rejected; phase+subagent invariant enforced; cascade delete clears child rows when parent case deleted

**Dependencies:** 0.12
**Files:**
- `VerdictCouncil_Backend/alembic/versions/0025_audit_schema_upgrade.py` (new)
- `VerdictCouncil_Backend/src/models/audit.py`
- `VerdictCouncil_Backend/src/models/judge_corrections.py` (new)
- `VerdictCouncil_Backend/src/models/suppressed_citation.py` (new)
- `VerdictCouncil_Backend/tests/integration/test_audit_schema.py` (new)

**Size:** M

### Task 4.C4.2: `append_audit_entry` populates new columns

**Description:** Update `shared/audit.py:7–33`. Accept and persist `trace_id`, `span_id`, `retrieved_source_ids`, `cost_usd`, `redaction_applied`. Sources from middleware state.

**Acceptance criteria:**
- [ ] All new columns populated for new rows
- [ ] Legacy callers still work (kwargs optional)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_audit_columns.py`

**Dependencies:** 4.C4.1
**Files:**
- `VerdictCouncil_Backend/src/shared/audit.py`

**Size:** S

### Task 4.C4.3: Per-model price table + `calc_cost`

**Description:** YAML or Python dict mapping `model_id` → per-1k-input/output-token price. Helper `calc_cost(model_id, usage) -> Decimal`.

**Acceptance criteria:**
- [ ] Covers models in use
- [ ] Returns `Decimal`

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/unit/test_cost_calc.py`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Backend/src/config/model_prices.yaml` (new)
- `VerdictCouncil_Backend/src/shared/cost.py` (new)

**Size:** S

### Task 4.C4.4: `/cost/summary` endpoint

**Description:** New `api/routes/cost.py` with `/cost/summary?case_id=&from=&to=` aggregating audit table.

**Acceptance criteria:**
- [ ] Sum across audit rows
- [ ] Filter by case_id + date

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_cost_endpoint.py`

**Dependencies:** 4.C4.2
**Files:**
- `VerdictCouncil_Backend/src/api/routes/cost.py` (new)

**Size:** S

### Task 4.C4.5: Prometheus gauge + integration test

**Description:** `verdict_council_case_cost_usd` gauge. Test that 10 rows sum to endpoint response.

**Acceptance criteria:**
- [ ] Gauge in scrape output
- [ ] Test passes

**Verification:**
- [ ] `curl -sf localhost:9090/metrics | grep verdict_council_case_cost_usd`
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_cost_rollup.py`

**Dependencies:** 4.C4.3, 4.C4.4
**Files:**
- `VerdictCouncil_Backend/tests/integration/test_cost_rollup.py` (new)

**Size:** S

## Workstream C5 — Frontend Sentry → LangSmith

### Task 4.C5.1: `@sentry/react` + init

**Description:** Add dep; create `src/sentry.ts`. Init Sentry with `VITE_SENTRY_DSN`; export `tagSession(trace_id, project)` that builds the LangSmith trace URL.

**Acceptance criteria:**
- [ ] Sentry initialized
- [ ] `tagSession` sets `backend_trace_id` tag and `backend_trace_url` (LangSmith link)

**Verification:**
- [ ] `cd VerdictCouncil_Frontend && npm run type-check`

**Dependencies:** None
**Files:**
- `VerdictCouncil_Frontend/package.json`, `package-lock.json`
- `VerdictCouncil_Frontend/src/sentry.ts` (new)

**Size:** S

### Task 4.C5.2: Locate SSE consumer + tag session

**Description:** Frontend has no `sseClient.ts`. Grep `VerdictCouncil_Frontend/src` for imports of `sseEvents` types. Call `tagSession(event.trace_id, ...)` on each event arrival. Guard for undefined `trace_id`.

**Acceptance criteria:**
- [ ] Real consumer file identified
- [ ] `tagSession` wired

**Verification:**
- [ ] Manual: trigger frontend error → Sentry event tagged with `backend_trace_id` + `backend_trace_url`

**Dependencies:** 4.C5.1, 2.C1.5
**Files:**
- TBD (locator output of grep — likely a `useCaseStream` hook or page-level effect)

**Size:** S

### Task 4.C5.3: Manual link verification

**Description:** Trigger frontend error → Sentry event has `backend_trace_url` linking to LangSmith trace → click opens trace.

**Acceptance criteria:**
- [ ] Link works

**Verification:**
- [ ] Manual

**Dependencies:** 4.C5.2
**Files:** none
**Size:** XS

## Workstream D3 — CI eval gate

### Task 4.D3.1: `.github/workflows/eval.yml`

**Description:** Triggers on PR touching `pipeline/`, `prompts/`, `tools/`. Runs `python tests/eval/run_eval.py`. Compares experiment scorers to the LangSmith baseline experiment (3.D1.4); fails if any drops >5%. Comments on PR with deltas.

**Acceptance criteria:**
- [ ] <5 min runtime on PR-sized change
- [ ] PR comment renders deltas

**Verification:**
- [ ] Test PR exercises workflow

**Dependencies:** 3.D1.3, 3.D1.4
**Files:**
- `VerdictCouncil_Backend/.github/workflows/eval.yml` (new)

**Size:** M

### Task 4.D3.2: Repo secrets

**Description:** GitHub repo secrets: `LANGSMITH_API_KEY`, `OPENAI_API_KEY`. (No more `MLFLOW_TRACKING_URI`, no `COHERE_API_KEY`.)

**Acceptance criteria:**
- [ ] Secrets exist; workflow accesses

**Verification:**
- [ ] Workflow run past auth

**Dependencies:** None
**Files:** none (GitHub UI)
**Size:** XS (ops)

### Task 4.D3.3: Branch protection for eval gate (no CODEOWNERS)

**Description:** Per user 2026-04-25 decision: **skip CODEOWNERS** for now (solo project). Use simpler branch-protection rule: PRs need standard review, and the `eval/skip-regression` label simply tells the eval workflow to skip the >5%-drop comparison (label check is in `eval.yml` itself). Branch-protection rule the user configures in GitHub: require PR review + require status checks (lint, test, security, eval, docker) — documented in `docs/setup-2026-04-25.md` (0.11c).

**Acceptance criteria:**
- [ ] `eval.yml` workflow checks for `eval/skip-regression` label and short-circuits the drop comparison if present
- [ ] `docs/setup-2026-04-25.md` includes a "Branch protection" section listing the required GitHub config
- [ ] No CODEOWNERS file created

**Verification:**
- [ ] Manual: PR with broken prompt + label merges; PR without label fails

**Dependencies:** 4.D3.1, 0.11c
**Files:**
- `VerdictCouncil_Backend/.github/workflows/eval.yml` (label-aware skip)
- `docs/setup-2026-04-25.md` (branch-protection section)

**Size:** S

### Task 4.D3.4: Meta-test CI gate

**Description:** Test PR with deliberately broken prompt → workflow fails. Same PR with label + approval → merges.

**Acceptance criteria:**
- [ ] Both scenarios exercised; documented

**Verification:**
- [ ] Manual

**Dependencies:** 4.D3.1
**Files:** none
**Size:** XS

### Checkpoint 4b — Sprint 4 complete

- [ ] CI gate catches prompt regressions on LangSmith
- [ ] Sentry → LangSmith trace link works end-to-end
- [ ] `/cost/summary` returns non-zero
- [ ] `suppressed_citation` populated by provenance path
- [ ] All Sprint 0–4 checkpoints still green

---

# Sprint 5 — Cloud Deployment (LangGraph Platform + LangSmith Deployment SDK)

Project assessment requires a live cloud-deployed demo. This sprint takes the Sprint-0–4 in-process build and ships it to **LangGraph Platform Cloud** using:
- **LangGraph CLI** (`langgraph build`) — produces deployable Docker artifact from `langgraph.json` (Sprint 1 task 1.DEP1.1)
- **LangSmith Deployment SDK** (`langsmith.deployment`) — programmatic deploy/update from CI

See plan §9 for the topology diagram and architectural rationale.

## Workstream DEP — Cloud deployment

### Task 5.DEP.1: Provision external managed services

**Description:** Stand up the four managed services the cloud setup needs (none of which are LangGraph Cloud):
- **Managed Postgres** for our app data (cases, audit_log, judge_corrections, suppressed_citation, pipeline_jobs) — DigitalOcean Managed Postgres, Supabase, or RDS
- **Managed Redis** for SSE pub/sub — Upstash or DO Managed Redis
- **Object storage** for raw uploaded PDFs (if not already provisioned)
- **Domain + SSL cert** for the BFF API endpoint

LangGraph Cloud auto-provisions its own Postgres for graph checkpoints — that is NOT this task.

**Acceptance criteria:**
- [ ] All four services running with credentials stored in deploy-target secret manager
- [ ] Health checks pass
- [ ] SGT region preferred for latency to demo audience

**Verification:**
- [ ] `psql $APP_DATABASE_URL -c "SELECT 1"` works
- [ ] `redis-cli -u $REDIS_URL PING` returns PONG

**Dependencies:** 0.12 approved
**Files:** none (ops + IaC if used)
**Size:** S (ops; ~1 day end-to-end with provisioning lag)

### Task 5.DEP.2: Run `alembic upgrade head` on cloud Postgres

**Description:** Migrate the cloud app DB to head schema (includes Alembic 0025 audit upgrade from 4.C4.1 + any later migrations).

**Acceptance criteria:**
- [ ] All Sprint 0–4 migrations applied; `alembic current` matches `head`
- [ ] Smoke: `INSERT` into `judge_corrections` with valid `case_id` succeeds; with non-existent `case_id` rejected (FK enforcement live)

**Verification:**
- [ ] `alembic upgrade head` exit 0
- [ ] Manual smoke INSERT/REJECT

**Dependencies:** 5.DEP.1, 4.C4.1
**Files:** none (ops)
**Size:** XS

### Task 5.DEP.3: Configure LangGraph Platform project

**Description:** In LangSmith UI, create a deployment for the `verdictcouncil` project (org `7ac65285-8e05-408b-9c0e-c3939ca2cc7e`). Link to GitHub repo. Configure:
- Source: `langgraph.json` at repo root
- Branch: `main`
- Env vars (set as deployment secrets):
  - `OPENAI_API_KEY`
  - `APP_DATABASE_URL` (our Postgres URL — for tools that need it)
  - `LANGSMITH_API_KEY` (auto-injected)
  - `LANGSMITH_PROJECT=verdictcouncil`
  - `APP_ENV=production`

LangGraph Cloud auto-provisions and injects `LANGGRAPH_DATABASE_URL` for graph checkpoints.

**Acceptance criteria:**
- [ ] Deployment configured; visible in LangSmith UI
- [ ] All env vars set
- [ ] First-time auto-build from `main` succeeds

**Verification:**
- [ ] LangSmith UI deployment status: "Healthy"
- [ ] Deployment URL responds to OPTIONS

**Dependencies:** 5.DEP.1, 1.DEP1.1
**Files:** none (LangSmith UI configuration)
**Size:** S (ops)

### Task 5.DEP.4: `langgraph build` produces deployable artifact in CI

**Description:** Add a CI job that runs `langgraph build --tag verdictcouncil:${{ github.sha }}` on every `main` merge. Output image pushed to GHCR (or LangGraph Cloud's registry — confirm during impl). The image bundles the graph + dependencies + configurable runtime.

**Acceptance criteria:**
- [ ] CI job exists in `.github/workflows/`
- [ ] Image successfully built and pushed
- [ ] Image tag visible in registry

**Verification:**
- [ ] PR check passes; `docker pull ghcr.io/.../verdictcouncil:<sha>` works

**Dependencies:** 1.DEP1.1, 1.DEP1.2
**Files:**
- `.github/workflows/langgraph-build.yml` (new)

**Size:** S

### Task 5.DEP.5: `scripts/deploy/cloud_deploy.py` via LangSmith Deployment SDK

**Description:** Idempotent script that takes a built image SHA and updates the LangGraph Cloud deployment programmatically using the LangSmith Deployment SDK. Replaces clicking through the UI for every deploy.

```python
# scripts/deploy/cloud_deploy.py
import os
import sys
from langsmith import Client
from langsmith.deployment import Deployment

def main(image_tag: str) -> None:
    client = Client()  # uses LANGSMITH_API_KEY
    deployment = Deployment(
        name="verdictcouncil",
        project_name="verdictcouncil",
        graph_id="verdictcouncil",
        image=f"ghcr.io/<org>/verdictcouncil:{image_tag}",
        env={
            "OPENAI_API_KEY": os.environ["OPENAI_API_KEY"],
            "APP_DATABASE_URL": os.environ["APP_DATABASE_URL"],
            "APP_ENV": "production",
        },
        instance_size="medium",
    )
    deployment.deploy()
    print(f"Deployed: {deployment.url}")

if __name__ == "__main__":
    main(sys.argv[1])
```

**Acceptance criteria:**
- [ ] Script idempotent (second run with same image is a no-op)
- [ ] On image change, new revision deployed; old revision retained for rollback
- [ ] Returns exit 0 on success; non-zero with diagnostic on failure

**Verification:**
- [ ] `python scripts/deploy/cloud_deploy.py <sha>` deploys
- [ ] Re-running same SHA: no churn

**Dependencies:** 5.DEP.4, 5.DEP.3
**Files:**
- `VerdictCouncil_Backend/scripts/deploy/cloud_deploy.py` (new)

**Size:** S

### Task 5.DEP.6: Wire `runner.py` cloud branch to LangGraph Cloud HTTP API

**Description:** Sprint 1's 1.DEP1.3 stubbed the cloud branch. This task fills it in: when `settings.app_env != "dev"`, the runner uses the LangGraph Cloud SDK client to start a graph run and stream chunks.

```python
# pipeline/graph/runner.py — cloud branch
from langgraph_sdk import get_client  # LangGraph Cloud SDK

class GraphPipelineRunner:
    def __init__(self):
        if settings.app_env == "dev":
            self._graph = build_graph(checkpointer=PostgresSaver.from_conn_string(settings.database_url))
            self._mode = "in_process"
        else:
            self._client = get_client(url=settings.langgraph_deployment_url, api_key=settings.langsmith_api_key)
            self._mode = "cloud"

    async def run(self, case_state, trace_id=None):
        config = {"configurable": {"thread_id": case_state.case_id},
                  "metadata": {"trace_id": trace_id, "env": settings.app_env}}
        if self._mode == "in_process":
            async for chunk in self._graph.astream({"case": case_state}, config=config, stream_mode="custom"):
                await publish_progress(case_state.case_id, chunk)
        else:
            thread = await self._client.threads.create(thread_id=case_state.case_id)
            async for chunk in self._client.runs.stream(
                thread_id=thread["thread_id"],
                assistant_id="verdictcouncil",
                input={"case": case_state},
                config=config,
                stream_mode="custom",
            ):
                await publish_progress(case_state.case_id, chunk.data)
```

`Command(resume=...)` from gate review goes via the same client (`client.runs.update_state` and `client.runs.stream(input=Command(...))`).

**Acceptance criteria:**
- [ ] `langgraph_sdk` added to deps
- [ ] Cloud branch fully wired; passes integration test against staging deployment
- [ ] HITL `interrupt()` + `Command(resume=...)` works end-to-end through the cloud path
- [ ] SSE progress events still appear in our React frontend (proxied via Redis)

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/integration/test_cloud_runner.py` (uses staging deployment URL)
- [ ] Manual: case run via deployed FastAPI BFF → LangGraph Cloud → response

**Dependencies:** 5.DEP.5, 1.DEP1.3
**Files:**
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py`
- `VerdictCouncil_Backend/pyproject.toml` (add `langgraph-sdk`)
- `VerdictCouncil_Backend/tests/integration/test_cloud_runner.py` (new)

**Size:** M

### Task 5.DEP.7: Deploy FastAPI BFF to cloud platform

**Description:** Pick a target (DigitalOcean App Platform recommended for SGT region) and deploy the existing FastAPI app. The Dockerfile at repo root continues to work; only env vars change. Configure the deploy target to:
- Pull from `main` branch
- Build the existing Dockerfile
- Inject env vars (`APP_DATABASE_URL`, `REDIS_URL`, `LANGSMITH_API_KEY`, `LANGGRAPH_DEPLOYMENT_URL`, `OPENAI_API_KEY`, `JWT_SECRET`, etc.)
- Auto-deploy on `main` merge
- Map custom domain with HTTPS

**Acceptance criteria:**
- [ ] BFF reachable at custom domain over HTTPS
- [ ] Health endpoint returns 200
- [ ] Logs flow to platform's log viewer
- [ ] `app_env=production` set; runner uses cloud branch
- [ ] Smoke: real user logs in via JWT, hits `/cases`, gets list

**Verification:**
- [ ] `curl https://<domain>/health` returns 200
- [ ] Manual login via React frontend (5.DEP.8)

**Dependencies:** 5.DEP.1, 5.DEP.2, 5.DEP.6
**Files:**
- (cloud platform config — managed via UI or IaC, not committed in repo)
- `VerdictCouncil_Backend/Dockerfile` (light cleanup if SAM/MLflow refs remain)

**Size:** S (ops)

### Task 5.DEP.8: Deploy frontend to Vercel

**Description:** Vercel deploys the React app. Connect repo, set `VITE_API_URL` to BFF domain, `VITE_SENTRY_DSN`, `VITE_LANGSMITH_PROJECT=verdictcouncil`. Auto-deploy on `main`; preview URLs per PR.

**Acceptance criteria:**
- [ ] Frontend reachable at `*.vercel.app` (or custom domain)
- [ ] Logs into deployed BFF; sees demo cases
- [ ] LangSmith trace links from React → cloud trace work

**Verification:**
- [ ] Manual: real demo case end-to-end on the deployed stack

**Dependencies:** 5.DEP.7
**Files:** none (Vercel UI / `vercel.json` if used)
**Size:** S (ops)

### Task 5.DEP.9: Production deploy workflow

**Description:** GitHub Actions `production-deploy.yml` orchestrates: (1) `langgraph build` → push image (5.DEP.4); (2) `python scripts/deploy/cloud_deploy.py <sha>` (5.DEP.5); (3) trigger DO App Platform redeploy of BFF; (4) Vercel auto-deploys frontend on its own. Deploy gates: all green CI checks (`lint`, `test`, `security`, `eval`, `docker`).

**Acceptance criteria:**
- [ ] Single workflow on `main` push deploys all three components
- [ ] If any step fails, subsequent steps are skipped
- [ ] Workflow takes <10 minutes end-to-end on a typical PR

**Verification:**
- [ ] PR merge to main → workflow runs → all three deploys complete
- [ ] Manual rollback documented in `docs/setup-2026-04-25.md`

**Dependencies:** 5.DEP.5, 5.DEP.7, 5.DEP.8
**Files:**
- `.github/workflows/production-deploy.yml` (extend existing)

**Size:** M

### Task 5.DEP.10: End-to-end cloud smoke test

**Description:** Full demo case run on the deployed stack. User logs in via deployed React → submits case → SSE timeline shows phases → judge advances through 4 gates → final judicial_decision recorded → LangSmith trace visible end-to-end.

**Acceptance criteria:**
- [ ] Complete case flow on deployed stack
- [ ] LangSmith trace clickable from React UI; shows all spans
- [ ] No console errors; <2s p95 latency for state transitions (excluding LLM time)
- [ ] Cost rollup `/cost/summary` returns non-zero from cloud DB

**Verification:**
- [ ] Manual smoke per the above sequence
- [ ] Recorded as the demo video for project assessment

**Dependencies:** 5.DEP.7, 5.DEP.8, 5.DEP.9
**Files:** none
**Size:** XS (manual)

### Task 5.DEP.11: Update governance docs for cloud topology

**Description:** Update `MLSECOPS_SECTION.md §7.5–7.6` to reflect rev-3 cloud deployment topology: drop SAM/Solace + MLflow rows, add LangGraph Platform Cloud row, add separate "graph state Postgres (managed by LangGraph)" vs "app data Postgres (our Managed DB)" distinction. Update `RESPONSIBLE_AI_SECTION.md` Pillar 3 (Operations) evidence pointers.

**Acceptance criteria:**
- [ ] Both docs reflect cloud topology
- [ ] Deployment table at §7.5 lists: BFF (DO App Platform), Frontend (Vercel), LangGraph Cloud, App Postgres (DO Managed), Graph Postgres (LangGraph-managed), Redis (Upstash), LangSmith (cloud), OpenAI (cloud)

**Verification:**
- [ ] Self-review

**Dependencies:** 5.DEP.10
**Files:**
- `MLSECOPS_SECTION.md`
- `RESPONSIBLE_AI_SECTION.md`

**Size:** S

### Checkpoint 5 — Cloud live

- [ ] All Sprint 5 tasks green
- [ ] Live demo URL working on every component
- [ ] Production-deploy workflow runs in <10 min per `main` merge
- [ ] LangSmith trace links work cross-component
- [ ] Cost-summary + suppressed-citation populated from real cloud runs

---

# Sprint 6+ — E (Deep Agents Judge Assistant) — separate product bet (deferred indefinitely)

### Task 6.E.0: Scoping spike

**Description:** Product brief + staffing plan + security threat model. Owner: TBD.

**Acceptance criteria:**
- [ ] Brief signed off by product
- [ ] Threat model covers cross-judge memory leakage

**Verification:**
- [ ] Stakeholder review

**Dependencies:** Sprint 5 complete
**Files:**
- `tasks/judge-assistant-scoping.md` (new)

**Size:** L

### Task 6.E.1: Cross-tenant `/memories/` security test

**Description:** Deploy-blocker. Judge B cannot read judge A's `/memories/` by guessing `thread_id`.

**Acceptance criteria:**
- [ ] Access denied

**Verification:**
- [ ] `pytest VerdictCouncil_Backend/tests/security/test_judge_memory_isolation.py`

**Dependencies:** 6.E.3
**Files:**
- `VerdictCouncil_Backend/tests/security/test_judge_memory_isolation.py` (new)

**Size:** M

### Tasks 6.E.2–6.E.6

Per `deep-agents-core` / `-orchestration` / `-memory` skills: judge_assistant service skeleton, `create_deep_agent` with `CompositeBackend`, `HumanInTheLoopMiddleware`, `SkillsMiddleware`, subagents (`precedent-researcher`, `policy-checker`).

Each: M-sized; do not decompose further until 6.E.0 lands.

---

## Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | `CaseState` msgpack drops fields silently | Med | High | 2.A2.2 blocker gate; keep `pipeline_checkpoints` for one release |
| R2 | `interrupt()` re-runs corrupt non-idempotent writes | Med | High | 4.A3.1 audit + 4.A3.2 UPSERT before wiring |
| R3 | OpenAI vector store latency drift | Low | Med | Track p95 in LangSmith; circuit-breaker in `tools/search_precedents.py` |
| R4 | `content_and_artifact` incompat with existing parsers | Low | Med | 3.B unit tests; Sprint 0 simplifies schemas first |
| R5 | LangSmith outage breaks tracing in prod | Low | Low | Fail-open; pipeline keeps running |
| R6 | Sprint 0 surfaces schema rework exceeding Sprint 4 C4 scope | Med | Med | Hold C4 and rescope rather than stack onto drift |
| R7 | Drift accumulates between plan anchors and code during execution | Med | Low | Re-audit at each sprint boundary |
| R8 | **Topology rewrite (1.A1.7) breaks behavior we don't notice** | Med | High | Replay test 1.A1.10 asserts semantic equivalence on terminal state across 5 cases; manual smoke 1.A1.11 |
| R9 | **7 new prompts (1.C3a.2) underperform vs 9 distilled-from prompts** | Med | High | LangSmith eval baseline (3.D1.4) compares pre- and post-architecture scorers; CI gate (4.D3.1) catches regressions |
| R10 | **Lost Gate-2 parallelism if `Send` not configured correctly** | Low | Med | Integration test 1.A1.5 explicitly verifies parallelism (timing or LangSmith span overlap) |
| R11 | **Auditor agent surfaces issues invisible in current 9-agent flow** | Low | Med | This is good — better signal. Configure default behavior so auditor flags don't auto-HALT; judge sees them at gate4 |

## Open Questions (resolved)

- ~~Q1 Feature flag design~~ — **dropped** (no flag needed; OpenAI vector store stays)
- ~~Q2 Cohere pricing~~ — **dropped** (no Cohere)
- ~~Q3 Golden dataset curator~~ — **answered:** ~5–10 cases per demo domain (traffic court + small claims), curator = user
- ~~Q4 MLflow version~~ — **dropped** (no MLflow; LangSmith native)
- Q5 Frontend SSE consumer location — handled inline in 4.C5.2 via grep
- ~~Q6 `judge_corrections` table~~ — **answered by Sprint 0** (defines target shape)

## Verification of this Tasks File

- [x] Task count: 0.x (6) + 1.x (16) + 2.x (19) + 3.x (11) + 4.x (28) + 5.x (7) ≈ **87 tasks**
- [x] Every task has acceptance criteria, verification, dependencies, files, size
- [x] Checkpoints between sprint phases (0, 1a, 1b, 2a, 2b, 3a, 3b, 4a, 4b)
- [x] Drift audit table at top
- [x] Parallelization map + target topology diagram at top
- [x] Risks + Open Questions at end
- [x] Cross-references to plan file

## Architecture summary

**6 agents** (1 intake + 4 research subagents + 1 synthesis + 1 auditor) with **7 LangSmith prompts** and **3 real tools** (`parse_document`, `search_legal_rules`, `search_precedents`).

**Model tiers:** `intake` = `gpt-5.4-nano`; everything else = `gpt-5.4`.

**Tool scoping (least-privilege, post-codex P2 finding):**
- `intake` → `parse_document` only
- `research-evidence/facts/witnesses` → `parse_document` only
- `research-law` → `search_legal_rules`, `search_precedents`
- `synthesis` → `search_precedents` (targeted follow-up)
- `auditor` → no tools (independence)

**Deployment topology (Sprint 5):**
- Frontend → Vercel
- FastAPI BFF → DigitalOcean App Platform (or fly.io / Railway)
- Graph runtime → **LangGraph Platform Cloud** (built via `langgraph build`, deployed via LangSmith Deployment SDK)
- App Postgres (cases, audit_log, etc.) → DO Managed Postgres
- Graph state Postgres → auto-managed by LangGraph Cloud
- Redis (SSE pub/sub) → Upstash
- LangSmith Cloud → tracing + Prompts + Evals (org `7ac65285-8e05-408b-9c0e-c3939ca2cc7e`, project `verdictcouncil`)

vs current: 9 agents, 9 prompts, 7 tools (3 real + 4 fake), self-hosted SAM mesh.

## Governance & Security additions (rev 4)

Sprint 0 now includes 5 doc deliverables:
- `RESPONSIBLE_AI_SECTION.md` updated for rev 3 (0.7)
- `SECURITY_RISK_REGISTER.md` updated for rev 3 + 3 new risks R-17/18/19 (0.8)
- `MLSECOPS_SECTION.md` updated for rev 3 (LangSmith replaces MLflow; preserves DeBERTa + 10 adversarial CI tests) (0.9)
- `AGENT_ARCHITECTURE.md` rewritten for 6-agent topology + codex findings table (0.10)
- `tasks/agent-design-2026-04-25.md` lightweight per-agent design (0.11)

Sprint 1 adds 3 security-preservation tasks:
- DeBERTa-v3 sanitizer still wired (1.A1.SEC1)
- 10 adversarial CI tests still pass (1.A1.SEC2)
- FIELD_OWNERSHIP → Pydantic `extra="forbid"` (1.A1.SEC3)

Sprint 4 adds:
- A3.14 — auditor send-back-to-phase mechanic
- A5 What-If reimplementation via LangGraph fork (4 tasks)
- C5b HITL UX frontend (5 tasks): `<GateReviewPanel>` + 4 per-gate body components + SSE consumer wiring + tests + smoke

**3 net new risks tracked (R-17 topology cutover, R-18 LangSmith outage, R-19 Send-without-idempotency).** All mitigated.

**4 IMDA pillars re-anchored** to rev 3 evidence pointers.

Net change since plan rev 1: 25 vendor/scope tasks dropped (Chroma/Cohere/RAGAS/MLflow/feature-flag), 12 governance/security/UX tasks added across Sprints 0/1/4.

*End of tasks. Sprint 0 is the next concrete action — kicks off as soon as you say go.*
