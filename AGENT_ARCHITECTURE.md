# VerdictCouncil Agent Architecture

Analysis date: 2026-04-21 (rev 3 refactor 2026-04-25). Reviewed by Claude Code + Codex (OpenAI).

Canonical references:
- Architecture proposal: `/Users/douglasswm/Project/AAS/VER/tasks/architecture-2026-04-25.md`
- Schema target (canonical Pydantic + DDL): `/Users/douglasswm/Project/AAS/VER/tasks/schema-target-2026-04-25.md`
- Sprint plan: `/Users/douglasswm/Project/AAS/VER/tasks/plan-2026-04-25-pipeline-rag-observability-overhaul.md`

---

## Architecture Overview

Fixed-topology **6-agent LangGraph** `StateGraph` pipeline with a parallel research phase dispatched via `Send` fan-out, four HITL gates (`interrupt()` + `Command(resume=...)`), and per-phase Pydantic output schemas enforced with `extra="forbid"`. One orchestration implementation: `src/pipeline/graph/builder.py` compiled into a single `graph` entered by `src/pipeline/runner.py`.

### Topology

```
START
  │
  ▼
┌─────────┐
│ intake  │  (lightweight: gpt-5-mini)
└────┬────┘
     ▼
┌─────────────┐   ┌─────────────┐
│ gate1_pause │──▶│ gate1_apply │   HITL: advance | rerun | halt
└─────────────┘   └──────┬──────┘
                         ▼
                  ┌───────────────────┐
                  │ research_dispatch │  plain node, resets research_parts={}
                  └────────┬──────────┘
                           │ add_conditional_edges(node, router, [destinations])
                           │ router returns list[Send]            (SA V-4)
       ┌─────────────┬─────┴─────┬──────────────┐
       ▼             ▼           ▼              ▼
 ┌───────────┐ ┌──────────┐ ┌───────────┐ ┌──────────┐
 │ research_ │ │ research_│ │ research_ │ │ research_│
 │ evidence  │ │ facts    │ │ witnesses │ │ law      │
 └─────┬─────┘ └─────┬────┘ └─────┬─────┘ └────┬─────┘
       └────────┬────┴────────────┴────────────┘
                ▼
         ┌───────────────┐
         │ research_join │  ResearchOutput.from_parts(dict[str, ResearchPart])
         └───────┬───────┘
                 ▼
         ┌─────────────┐   ┌─────────────┐
         │ gate2_pause │──▶│ gate2_apply │
         └─────────────┘   └──────┬──────┘
                                  ▼
                          ┌─────────────┐
                          │  synthesis  │  (frontier: gpt-5)
                          └──────┬──────┘
                                 ▼
                         ┌─────────────┐   ┌─────────────┐
                         │ gate3_pause │──▶│ gate3_apply │
                         └─────────────┘   └──────┬──────┘
                                                  ▼
                                          ┌─────────────┐
                                          │   auditor   │  (frontier, ZERO tools)
                                          └──────┬──────┘
                                                 ▼
                                 ┌─────────────┐   ┌─────────────┐
                                 │ gate4_pause │──▶│ gate4_apply │──▶ END
                                 └─────────────┘   └─────────────┘
```

**Send fan-out (SA V-4):** the router is wired via
`g.add_conditional_edges("research_dispatch", route_to_research_subagents, ["research_evidence","research_facts","research_witnesses","research_law"])`.
The router function returns `list[Send]`; the plain dispatch node only resets `research_parts`. Subagents each return `{"research_parts": {scope: ResearchPart}}` and the `merge_dict` reducer key-merges them.

**HITL:** every gate pair writes `case.status = awaiting_review_gate{n}` via an idempotent UPSERT **before** `interrupt()` (SA V-7). Resume is `Command(resume={"decision": "advance|rerun|halt"})`-only (SA V-6).

**Durability:** `PostgresSaver` checkpointer keyed by `thread_id = str(case_id)`. Rerun / What-If forks call `graph.update_state(past_config, {...})` and re-enter via `graph.ainvoke(None, past_config)` (SA V-9).

Models: `gpt-5-mini` (intake); `gpt-5` (research subagents, synthesis, auditor). No GPT-4 family references.

---

## Invocation

1. Client: `POST /api/v1/cases/{case_id}/process`
2. FastAPI returns 202 Accepted and enqueues a durable worker job (transitional: same API surface as today; full durable queue tracked under H2 follow-up).
3. Worker invokes `runner.run(case_id)` which streams `graph.astream(...)` chunks. There is a single runner path.
4. SSE bridges directly from `astream` chunks; terminal events (`completed`, `failed`, `halted`, `cancelled`) are emitted on every termination branch so subscribers cannot hang.

---

## Agentic Pattern

**LangGraph `StateGraph`, six phase nodes, parallel research via `Send`.**

The graph itself is the orchestrator — there is no separate conductor class doing LLM calls. `runner.py` is a pure conductor: builds the compiled graph, starts the stream, bridges events. Input-guardrails, judge-KB retrieval, and prompt-commit stamping live in **middleware** attached to the compiled graph, not inside the runner (resolves M2).

Gate decisions flow through `_pending_action` between `gate*_pause` and `gate*_apply` nodes. Phase rerun (judge-initiated) and the auditor's `should_rerun` / `target_phase` / `reason` path both re-enter the graph through the same fork mechanism.

---

## Per-phase Pydantic schema map

Replaces the old logical field-ownership allowlist. Ownership is now enforced structurally: each phase returns exactly one `extra="forbid"` Pydantic model; undeclared keys raise `ValidationError` uniformly across every phase (1.A1.SEC3). Canonical shapes live in `schema-target-2026-04-25.md` §2.

| Phase | Output schema | Writes into | Summary of fields |
|---|---|---|---|
| `intake` | `IntakeOutput` | `case.intake` | `domain: CaseDomain`, `parties`, `case_metadata`, `raw_documents`, `routing_decision` (complexity, score, route, factors, vulnerability, halt flag). |
| `research-evidence` | `EvidenceResearch` (→ `ResearchPart{scope="evidence"}`) | `research_parts["evidence"]` | `evidence_items: list[EvidenceItem]`, `credibility_scores: dict[str, CredibilityScore]`. |
| `research-facts` | `FactsResearch` (→ `ResearchPart{scope="facts"}`) | `research_parts["facts"]` | `facts: list[ExtractedFactItem]` (`confidence: ConfidenceLevel`), `timeline: list[TimelineEvent]`. |
| `research-witnesses` | `WitnessesResearch` (→ `ResearchPart{scope="witnesses"}`) | `research_parts["witnesses"]` | `witnesses: list[Witness]` with nested `statements` + `credibility`, plus witness-keyed `credibility` map. |
| `research-law` | `LawResearch` (→ `ResearchPart{scope="law"}`) | `research_parts["law"]` | `legal_rules`, `precedents`, `precedent_source_metadata: PrecedentProvenance`, `legal_elements_checklist`, `suppressed_citations`. |
| research join | `ResearchOutput` (dict-keyed merge) | `case.research_output` | `ResearchOutput.from_parts(dict[str, ResearchPart])`; sets `partial=True` when any scope is missing. Reducer: `merge_dict`. |
| `synthesis` | `SynthesisOutput` | `case.synthesis` | `arguments: ArgumentSet`, `preliminary_conclusion`, `confidence: ConfidenceLevel`, `reasoning_chain: list[ReasoningStep]`, `uncertainty_flags`. |
| `auditor` | `AuditOutput` (strict JSON schema mode) | `case.audit` | `fairness_check`, `status: CaseStatus`, **new** `should_rerun: bool`, **new** `target_phase: Literal["intake","research","synthesis"] \| None`, **new** `reason: str \| None` (per 0.5 D-9). |

State accumulator for the fan-out: `research_parts: Annotated[dict[str, ResearchPart], merge_dict]` (SA F-2 option 2). Full reset from outside is done via `graph.update_state(cfg, {"research_parts": Overwrite({})})` (SA V-3).

---

## Tool roster (summary)

Three registered `@tool`s, least-privilege per phase:

| Tool | Phases |
|---|---|
| `parse_document` | `intake`, `research-evidence`, `research-facts`, `research-witnesses` |
| `search_precedents` | `research-law`, `synthesis` |
| `search_legal_rules` | `research-law` only |

Auditor has **zero tools** — independence guarantee. `confidence_calc` is demoted to an internal utility; `cross_reference`, `timeline_construct`, `generate_questions` are dropped. Full rationale: `tasks/schema-target-2026-04-25.md` §3.

---

## What-If / rerun semantics

What-If and judge-initiated phase reruns use the **same LangGraph fork mechanism** — no bespoke cloning, no separate controller:

1. Locate the historical state via `graph.get_state_history(config)` whose `next == (entry_node_for(phase),)`.
2. `graph.update_state(past_config, {...})` to inject judge modifications or reset the research accumulator (`{"research_parts": Overwrite({})}` when re-running research).
3. `await graph.ainvoke(None, past_config)` re-enters the real graph, preserving gates, middleware, and checkpointing.

The auditor's `should_rerun=true` path writes a `judge_corrections` row with `correction_source='auditor'` and re-invokes the same rerun endpoint judges use (`/cases/{id}/rerun?phase=...`).

---

## Codex second-opinion review — rev 3 status

Independent review by OpenAI Codex. This table tracks how each finding is resolved in the rev 3 design.

| Codex finding | rev 3 status |
|---|---|
| C1 — API wired to wrong runner | resolved — single `runner.py` path; mesh runner deleted |
| C2 — Field ownership not enforced in mesh path | resolved — Pydantic `extra="forbid"` enforces uniformly |
| C3 — What-If empty state | resolved — LangGraph fork via `update_state(past_config, ...)` |
| H1 — What-If bypass topology | resolved — same fork mechanism uses real graph |
| H2 — No durable job execution | partial — `PostgresSaver` checkpoints survive worker restart; full durable queue still tracked separately |
| H3 — SSE can hang | resolved — SSE bridges from `astream` chunks; terminal events emitted on every termination path |
| H4 — `CaseState` weakly typed | resolved — Pydantic schemas per phase output |
| M1 — Race-prone dedup | unchanged — out of scope |
| M2 — Orchestrator not pure | resolved — middleware separates concerns; runner is pure conductor |
| M3 — Schema drift (judge_kb_results undeclared) | resolved — Pydantic schemas declare every field |

---

## Verdict

The rev 3 design replaces the prior 2-runner, logical-ownership, empty-shell-What-If architecture with one LangGraph `StateGraph`, structurally enforced per-phase schemas, and a single fork-based rerun path. Remaining production-readiness work tracked separately: durable job queue beyond `PostgresSaver` (H2 residual), race-free request dedup (M1), and the Sprint 2+ migration sequence in `schema-target-2026-04-25.md` §1.

---

### Archived footnotes

The pre-rev-3 design — two runner implementations (local + mesh), 9-agent roster across 4 HITL gates, logical `FIELD_OWNERSHIP` allowlist in `src/shared/validation.py`, SAM/Solace A2A pub-sub transport, Redis Lua barrier for L2 fan-in, `governance-verdict` terminal agent, custom UPSERT inside `pipeline_state.py`, and a separate What-If controller that deep-cloned a fresh `CaseState` — is retained only in git history for audit. No current code path depends on it.
