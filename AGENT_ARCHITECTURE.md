# VerdictCouncil Agent Architecture

Analysis date: 2026-04-21. Reviewed by Claude Code + Codex (OpenAI).

---

## Architecture Overview

A fixed-topology 9-agent sequential pipeline grouped into four human-review gates.

| Gate | Agents | Pause status |
|---|---|---|
| Gate 1 — Intake | `case-processing` → `complexity-routing` | `awaiting_review_gate1` |
| Gate 2 — Dossier | `evidence-analysis` → `fact-reconstruction` → `witness-analysis` → `legal-knowledge` | `awaiting_review_gate2` |
| Gate 3 — Arguments | `argument-construction` → `hearing-analysis` | `awaiting_review_gate3` |
| Gate 4 — Verdict | `hearing-governance` | `awaiting_review_gate4` |

Agent configs: `VerdictCouncil_Backend/configs/agents/*.yaml`

Gate state written atomically to `cases.gate_state` JSONB inside `persist_case_results()` — same DB transaction as all other case updates. Per-gate checkpoints written to `pipeline_checkpoints` keyed `(case_id, run_id={case_id}-{gate_name})`.

---

## Invocation

1. Client: `POST /api/v1/cases/{case_id}/process`
2. FastAPI returns 202 Accepted, spawns BackgroundTask
3. `_run_case_pipeline()` in `src/api/routes/cases.py:267` runs asynchronously

---

## Agentic Pattern

**Orchestrator-Worker + Fixed Pipeline.** Not ReAct, not dynamic routing.

Two orchestrator implementations:

| Runner | Path | Use |
|--------|------|-----|
| `PipelineRunner` | `src/pipeline/runner.py` | Demo — all 9 agents in-process via OpenAI tool-use loops, 4-gate HITL |
| `MeshPipelineRunner` | `src/pipeline/mesh_runner.py` | Production — agents as separate SAM processes over JSON-RPC 2.0 A2A pub/sub |

Orchestrator responsibilities:
- Sequential dispatch within each gate via `run_gate()`
- Escalation guardrail: `ComplexityEscalationHook` forces `escalated → processing` — no halt
- Governance advisory: `GovernanceHaltHook` logs critical fairness findings but does NOT halt — judge reviews at Gate 4
- Gate pause: after each gate, `state.status = awaiting_review_{gate}`, written to DB atomically

---

## Orchestrator

`MeshPipelineRunner` is a programmatic orchestrator — no LLM calls of its own. Key methods:

- `run(case_state, judge_vector_store_id)` — main entry
- `run_from(case_state, start_agent)` — mid-pipeline resume (What-If)
- `_invoke_agent_sequential()` — publish request, await response, merge state
- `_invoke_l2_fanout()` — parallel publish to 3 L2 agents, await aggregator barrier
- `_apply_input_guardrail()` — prompt injection check
- `_apply_judge_kb_hook()` — query judge's personal vector store after legal-knowledge
- `_apply_governance_halts()` — validate output integrity and fairness flags

---

## Context Passing

**Primary: `CaseState` Pydantic model** (`src/shared/case_state.py`)

- 80+ fields: documents, evidence, facts, witnesses, legal rules, verdict, audit log
- Each agent receives the full `CaseState` as JSON
- Each agent writes back only its owned fields (enforced by `FIELD_OWNERSHIP` in `src/shared/validation.py`)
- Violations logged and stripped; state re-validated after every agent

### Field Ownership Map

| Agent | Owned Fields |
|-------|-------------|
| `case-processing` | `case_id`, `run_id`, `domain`, `status`, `parties`, `case_metadata`, `raw_documents` |
| `complexity-routing` | `status`, `case_metadata` |
| `evidence-analysis` | `evidence_analysis` |
| `fact-reconstruction` | `extracted_facts` |
| `witness-analysis` | `witnesses` |
| `legal-knowledge` | `legal_rules`, `precedents`, `precedent_source_metadata` |
| `argument-construction` | `arguments` |
| `deliberation` | `deliberation` |
| `governance-verdict` | `fairness_check`, `verdict_recommendation`, `status` |

### Supporting Mechanisms

| Mechanism | Purpose |
|-----------|---------|
| `audit_log` (append-only) | Every agent appends inputs, outputs, token usage, tool calls |
| PostgreSQL checkpoints | State persisted after each agent — enables replay and What-If |
| Redis Lua barrier | L2 agents write to Redis hash; Lua script atomically merges when all 3 complete |
| Judge KB hook | After `legal-knowledge`, orchestrator queries judge's personal vector store |
| SSE via Redis pub/sub | Progress events streamed to frontend per `case_id` |

### What-If Branching

`src/services/whatif_controller/controller.py`:
- Deep-clone completed `CaseState`
- Apply judge modification (fact toggle, evidence exclusion, witness credibility, legal interpretation)
- Determine re-entry agent via impact map
- Call `runner.run_from(modified_state, start_agent)` with new `run_id` linked via `parent_run_id`

---

## Pattern Assessment

**Acceptable industry-practiced pattern.** Maps to Anthropic's "orchestrator-subagents" + "parallelization" building blocks. Comparable to LangGraph state machine approach, Google Gemini agent pipelines, and the A2A protocol standard.

For a judicial AI system, the programmatic (non-LLM) orchestrator is the correct choice — deterministic topology is auditable and testable, which matters more than adaptability when the output is a legal verdict.

---

## Codex Second-Opinion Review

Independent review by OpenAI Codex (400,620 tokens). Codex read the source files directly.

### Critical Findings

**C1 — API wired to wrong runner** (`cases.py:267`, `mesh_runner.py:125`)
The live API endpoint runs `PipelineRunner()`, not `MeshPipelineRunner()`. Production requests bypass Solace A2A, Redis barrier fan-in, and checkpoint replay entirely. The SSE progress stream is also disconnected from the runner actually used.

**C2 — Field ownership not enforced in mesh path** (`runner.py:581`, `validation.py:32`, `mesh_runner.py:460`)
`PipelineRunner` validates writes and strips unauthorized fields. `MeshPipelineRunner._parse_agent_response()` accepts a full `CaseState` or arbitrary fragment and validates only against the broad Pydantic model — no field ownership enforcement. An agent can overwrite unrelated fields, status, or prior analysis without being blocked.

**C3 — What-If loads empty state, not checkpoint** (`what_if.py:72`, `controller.py:60`, `pipeline_state.py:42`)
`_run_whatif_scenario()` constructs `CaseState(case_id, run_id)` only. `create_scenario()` deep-copies this almost-empty shell and reruns downstream agents. It does not load the original completed state. Original evidence/facts/witness/legal outputs are discarded; modification handlers are mostly no-ops.

### High-Severity Findings

**H1 — What-If bypasses topology-aware re-entry** (`controller.py:82`, `mesh_runner.py:176`)
Calls private `_run_agent()` sequentially from an `AGENT_ORDER` index instead of `run_from()`. For L2-triggering changes, loses the parallel fan-out/barrier semantics. Bypasses mesh runner checkpointing and orchestration hooks for all changes.

**H2 — No durable job execution** (`cases.py:337`, `pipeline_state.py:50`)
Pipeline launched via FastAPI `BackgroundTasks` — a worker restart drops in-flight jobs. Checkpoint writes are explicitly non-fatal and swallowed on DB failure. Silent checkpoint loss is not acceptable in a legal system.

**H3 — SSE can hang indefinitely** (`pipeline_events.py:40`, `mesh_runner.py:400`)
SSE closes only on `governance-verdict` with `completed` or `failed`. Earlier failures, L2 barrier timeouts, orphaned pub/sub messages, or app crashes do not produce a terminal event. Subscribers hang.

**H4 — `CaseState` too weakly typed** (`case_state.py:41`)
Most substantive fields are `dict[str, Any]` or `list[dict[str, Any]]`. Almost no schema-level protection for evidence, facts, witnesses, arguments, fairness outputs, or verdict structure. Makes replay, audit, and downstream guarantees fragile for a legal system.

### Medium-Severity Findings

**M1 — Race-prone deduplication** (`cases.py:356`, `cases.py:288`)
`process_case()` checks `case.status != processing` before enqueueing, but the status flip happens later inside the background worker. Two concurrent requests can both enqueue.

**M2 — Orchestrator is not a pure conductor** (`mesh_runner.py:103`, `mesh_runner.py:137`, `mesh_runner.py:262`)
`MeshPipelineRunner` instantiates `AsyncOpenAI` and performs input-injection checking and a judge-KB hook. Hidden business logic and external dependencies inside the conductor layer.

**M3 — Schema drift** (`mesh_runner.py:273`, `case_state.py:41`)
`_apply_judge_kb_hook()` writes `judge_kb_results` to state, but `CaseState` does not declare that field. Undeclared state is a provenance problem in regulated systems.

---

## Verdict

**Not production-ready for a legal AI system.**

The 9-agent fixed-topology pipeline is a sound architectural choice. The L2 parallel barrier, field ownership model, and checkpoint-based replay are the right ideas. But the implementation has hard gaps:

1. Live API runs the local runner, not the mesh architecture
2. Field ownership not enforced in the mesh path
3. What-If branches from empty state, not completed checkpoints
4. No durable job queue — in-flight work is lost on restart
5. `CaseState` lacks domain-typed schemas for evidence and verdict fields

These are launch blockers for a court-adjacent system, not polish items.

**Fix priority order:**
1. Wire `cases.py:267` to `MeshPipelineRunner` (or document that `PipelineRunner` is the intended production path and remove the mesh runner claim)
2. Port field ownership validation into `mesh_runner._parse_agent_response()`
3. Fix What-If to load from PostgreSQL checkpoint before cloning
4. Replace `BackgroundTasks` with a durable job queue (Celery, ARQ, or similar)
5. Type `CaseState` substantive fields with proper Pydantic models
