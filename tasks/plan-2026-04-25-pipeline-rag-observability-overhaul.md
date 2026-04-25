# VerdictCouncil Pipeline & Architecture Overhaul — Implementation Plan

**Plan date:** 2026-04-25 (rev 3 — agent architecture simplified)
**Status:** Ready to execute pending Sprint 0 approvals.
**Skills consulted:** `framework-selection`, `langchain-fundamentals`, `langchain-middleware`, `langgraph-fundamentals`, `langgraph-persistence`, `langgraph-human-in-the-loop`.

## Scope Revision Log

**rev 1 → rev 2 (vendor cuts):** dropped Chroma + Cohere + RAGAS + MLflow + feature-flag system. Kept OpenAI vector stores. Switched all observability to LangSmith.

**rev 2 → rev 3 (agent architecture, this revision):** collapsed **9 agents → 6 agents** (Option 2: phased agent + parallel research subagents + separate auditor). Dropped 4 "fake" reasoning tools. Sprint 0 expanded to also formalize the architecture and audit tool implementations.

| Removed | Replaced with / Rationale |
|---|---|
| 9 distinct agent prompts | **6 prompts**: 4 phase prompts (intake, research-orchestrator dispatcher [no LLM], synthesis, audit) + 4 research subagent prompts (evidence, facts, witnesses, law) — total 7 LLM-backed prompts. (One re-counted: there's no "research orchestrator" LLM; just Python fan-out.) |
| `cross_reference`, `timeline_construct`, `confidence_calc`, `generate_questions` | Dropped — folded into agent native reasoning + structured output. |
| `case-processing` + `complexity-routing` separate agents | **Merged** → single `intake` phase. |
| `argument-construction` + `hearing-analysis` separate agents | **Merged** → single `synthesis` phase. |
| `evidence-analysis`, `fact-reconstruction`, `witness-analysis`, `legal-knowledge` as Gate-2 peer agents | Reframed as **4 parallel research subagents** dispatched via `Send` in the research phase; outputs merged programmatically. |
| `hearing-governance` | **Kept as separate `auditor` agent** — independence preserved. |

---

## Overview

Rewrite the agent pipeline around a small set of **phased agents** with native LangChain/LangGraph primitives. Replace ~400 lines of bespoke orchestration with `create_agent`, `interrupt()`, `PostgresSaver`, and `Send`-based parallel dispatch. Drop in-house observability for LangSmith natively. Add file-level citation provenance on top of the existing OpenAI vector store retrieval. Gate regressions with LangSmith Evaluations in CI.

**Architectural philosophy (Claude-Code-style):** one capable agent + a small set of real tools + HITL checkpoints between phases. Parallelism only where it pays off (Gate 2 research). An independent auditor at the end.

## Target Agent Architecture (Option 2)

```
START
  │
  ▼
[ intake ]  (LLM: lightweight model, system_prompt=intake)
  │  outputs: parties, case_metadata, complexity_score, route, vulnerability_assessment
  ▼
gate1_pause → interrupt() → gate1_apply  (HITL: judge reviews intake)
  │
  ▼
research_dispatch  (Python; Send to 4 parallel subagents)
  │     │     │     │
  ▼     ▼     ▼     ▼
[ev]  [fct]  [wit]  [law]      (4 parallel LLM calls, frontier model)
  │     │     │     │
  └──┬──┴──┬──┴─────┘
     ▼     ▼
   research_join  (Python; merges 4 structured outputs into ResearchOutput)
  │
  ▼
gate2_pause → interrupt() → gate2_apply  (HITL: judge reviews research)
  │
  ▼
[ synthesis ]  (LLM: frontier model, system_prompt=synthesis)
  │  outputs: arguments (IRAC, both-sides), pre-hearing brief, judicial questions, uncertainty flags
  ▼
gate3_pause → interrupt() → gate3_apply  (HITL: judge reviews synthesis)
  │
  ▼
[ auditor ]  (LLM: frontier model, system_prompt=audit, INDEPENDENT — reads finished case state)
  │  outputs: fairness_check, citation_audit, completeness_flags, integrity_flags
  ▼
gate4_pause → interrupt() → gate4_apply  (HITL: judge approves or HALT)
  │
  ▼
END
```

**Agents:** 6 total (1 intake + 4 research subagents + 1 synthesis + 1 auditor — re-counting, that's 7 distinct LLM personas, plus a separate `auditor` agent's prompt. Adjusted: **7 LLM-backed prompts** in LangSmith Prompts.)

**Tools** (real, not LLM-wrappers): `parse_document`, `search_legal_rules`, `search_precedents`. Plus utility plumbing tools added by Sprint 0 audit if needed.

## What stays the same

- OpenAI Responses API + `vector_stores.search` (retrieval engine — already per-judge / per-domain)
- Redis pub/sub for SSE
- Worker queue + outbox pattern
- React frontend (only minimal SSE schema additions)
- 4 HITL gates (gate boundaries unchanged — still aligned with judge review checkpoints)

## What we are NOT doing

- Not adding Chroma, Cohere, RAGAS, MLflow, or any new vendor.
- Not changing the retrieval engine.
- Not running LLM-as-judge evals until labeled outcome data exists.
- Not implementing E (Deep Agents Judge Assistant) in this overhaul.
- Not single-agent-only (rejected Option 1 — we keep Gate 2 parallelism for the ~30s/case speedup).
- Not full conservation of 9 agents (rejected Option 3 — collapse genuine duplicates).
- Not adding PII/PHI redaction logic in this overhaul (`redaction_applied BOOLEAN` column reserved for future use).
- Not changing `tools/search_precedents.py` PAIR + circuit-breaker resilience (preserved verbatim).

---

## §4. Per-Agent Design

Six agents post-rev 3. Each agent's spec follows the lightweight template below; full Pydantic schemas land in `tasks/agent-design-2026-04-25.md` (Sprint 0 §0.11).

**Model tier mapping (decided 2026-04-25):**
- `intake` → `gpt-5.4-nano` (lightweight)
- `research-evidence`, `research-facts`, `research-witnesses`, `research-law` → `gpt-5.4` (frontier)
- `synthesis` → `gpt-5.4` (frontier)
- `auditor` → `gpt-5.4` (frontier)

### 4.1 `intake` — Triage and routing

- **Purpose:** Read raw case documents, extract parties and metadata, classify domain (traffic-court / small-claims), score complexity, decide route (standard / escalated / halt). Lightweight first-pass before expensive research.
- **Reasoning pattern:** Rule-based triage + LLM extraction. Hard-coded escalation triggers (9 rules: missing party, ambiguous jurisdiction, unverifiable identity, etc.) → unconditional `escalated` route. Otherwise multi-dimensional complexity scoring (7 weighted dimensions: parties / evidence-volume / legal-complexity / vulnerability / time-sensitivity / jurisdiction-clarity / completeness).
- **Tools:** `parse_document` (only).
- **`response_format`:** `IntakeOutput` (parties, domain, complexity_score, complexity_factors, route, vulnerability_assessment, red_flags, intake_completeness).
- **Model tier:** `gpt-5.4-nano`.
- **GraphState reads:** `case.raw_documents`. **Writes:** `case.parties`, `case.case_metadata`, `case.domain`, `case.intake_completeness_score`.
- **Coordination:** No direct comm with other agents. Output flows through `gate1_pause` → `gate1_apply` → `research_dispatch`.

### 4.2 `research-evidence` — Forensic evidence analysis (parallel subagent)

- **Purpose:** Classify each evidence item (5 dimensions: classification / strength / admissibility / probative-vs-prejudicial / claim-linkage). Build cross-evidence weight matrix. Detect contradictions and corroborations. Run impartiality check.
- **Reasoning pattern:** Per-item 5-dimensional assessment → cross-evidence synthesis → weight matrix → impartiality check.
- **Tools:** `parse_document`.
- **`response_format`:** `EvidenceResearch` (evidence_items, contradictions, corroborations, gaps, weight_matrix, impartiality_check, digital_flags).
- **Model tier:** frontier.
- **GraphState reads:** `case.raw_documents`, `case.case_metadata`, `case.domain`. **Writes:** part of merged `ResearchOutput`.
- **Coordination:** Dispatched via `Send`; runs in parallel with the other 3 research subagents; `research_join` merges.

### 4.3 `research-facts` — Fact extraction and timeline

- **Purpose:** Systematic fact extraction with confidence bands; dispute mapping (dual versions); timeline construction; critical fact identification; causal chain analysis.
- **Reasoning pattern:** Sequential fact-by-fact extraction → 6-band confidence assignment → dual-version dispute mapping → temporal ordering → causal-chain trace.
- **Tools:** `parse_document` (re-reads documents independently from evidence subagent — explicitly redundant for parallelism).
- **`response_format`:** `FactsResearch` (facts, disputed_facts, critical_facts, causal_chain, broken_causal_chains, timeline, undated_facts).
- **Model tier:** frontier.
- **GraphState reads:** `case.raw_documents`. **Writes:** part of merged `ResearchOutput`.
- **Coordination:** Same as research-evidence.

### 4.4 `research-witnesses` — Credibility assessment

- **Purpose:** Witness identification + classification. Apply PEAR framework (Prior consistency / Evidence consistency / specificity / reliability) per witness. Score 6-dim credibility. Generate judicial question bank.
- **Reasoning pattern:** PEAR framework + 6-dimensional credibility scoring + question generation.
- **Tools:** `parse_document`.
- **`response_format`:** `WitnessesResearch` (witnesses, credibility_disclaimer, assessment_summary).
- **Model tier:** frontier.
- **GraphState reads:** `case.raw_documents`. **Writes:** part of merged `ResearchOutput`.
- **Coordination:** Same as research-evidence.

### 4.5 `research-law` — Statute and precedent retrieval

- **Purpose:** Identify applicable statutes (e.g., SCTA s.5/10/13/23, RTA s.63/65/67). Retrieve relevant precedents from per-judge OpenAI vector store + PAIR fallback. Build legal elements checklist. Anti-hallucination citation provenance via `source_id = f"{file_id}:{sha256(content)[:12]}"`.
- **Reasoning pattern:** Authority hierarchy framework → statutory retrieval → two-tier precedent search → citation grounding (every citation must reference a `source_id` from the run's tool artifacts).
- **Tools:** `parse_document` (case-side context), `search_legal_rules` (statutes), `search_precedents` (case-law).
- **`response_format`:** `LawResearch` (legal_rules, precedents, precedent_source_metadata, legal_elements_checklist, suppressed_citations).
- **Model tier:** frontier.
- **GraphState reads:** `case.case_metadata`, `case.domain`. **Writes:** part of merged `ResearchOutput`.
- **Coordination:** Same as research-evidence. **Special:** consumed by `output_validator.py` (3.B.5) to enforce citation provenance.

### 4.6 `synthesis` — IRAC arguments + pre-hearing brief

- **Purpose:** Construct both-sides IRAC arguments per charge (Issue → Rule → Application → Conclusion). Identify contested issues, agreed facts, comparative strength. Produce pre-hearing brief (≤500 words) and judicial questions. Flag uncertainty.
- **Reasoning pattern:** IRAC per charge/element → mandatory weakness analysis (each side) → contested-issue extraction → 10-step hearing analysis (established facts → law synthesis → element-by-element → strength eval → witness summary → precedent alignment → key issues → quantum/sentencing → uncertainty → brief).
- **Tools:** `search_precedents` (occasional follow-up), otherwise none.
- **`response_format`:** `SynthesisOutput` (arguments, hearing_analysis, pre_hearing_brief, judicial_questions, uncertainty_flags, contested_issues, agreed_facts, burden_status).
- **Model tier:** frontier.
- **GraphState reads:** merged `ResearchOutput` (extracted_facts, evidence_analysis, witnesses, legal_rules, precedents). **Writes:** `case.arguments`, `case.hearing_analysis`.
- **Coordination:** Sequential after gate2_apply. Output gates at gate3.

### 4.7 `auditor` — Independent fairness and integrity audit

- **Purpose:** Run a 5-phase independent audit on completed case state: (1) impartiality check across all phases, (2) citation verification (every citation has matching `source_id`), (3) completeness audit (no critical gaps), (4) fairness audit (both-sides balance), (5) integrity audit (guardrails honored, disclaimers present).
- **Reasoning pattern:** Independent reviewer stance — assumes no upstream agent is correct. Aggressive false-positive tolerance: "false positives acceptable; better to escalate than to issue a biased verdict" (preserves the design choice from `RESPONSIBLE_AI_SECTION.md` §5.2).
- **Tools:** none (reads finished GraphState; does not retrieve).
- **`response_format`:** `AuditOutput` (fairness_check, citation_audit, completeness_flags, integrity_flags, recommend_send_back, cost_summary).
- **Model tier:** frontier.
- **GraphState reads:** entire `case`. **Writes:** `case.fairness_check`, `case.audit_findings`.
- **Coordination:** Sequential after gate3_apply. Independence preserved by running last on completed state — no upstream agent influences its prompt.

### 4.8 Coordination Protocol

- **State-passing only.** No agent-to-agent direct comm. All inter-agent data flows through GraphState (`case` field with custom merger).
- **Field ownership** is now enforced via Pydantic `response_format` schemas (each phase output has `model_config = ConfigDict(extra="forbid")`). Replaces the old `FIELD_OWNERSHIP` allowlist in `src/shared/validation.py`.
- **Append-only audit_log** preserved; every middleware-driven action UPSERTs an entry.
- **Parallel research subagents** dispatched via `Send`; programmatic `research_join` merges 4 outputs into one `ResearchOutput`.
- **Auditor independence** structural: reads completed state only; cannot influence upstream agents.

---

## §5. Responsible AI Practices (IMDA Framework Alignment, rev 3)

This section re-anchors `RESPONSIBLE_AI_SECTION.md` to the rev 3 architecture. Sprint 0 task 0.7 propagates these changes to the live doc.

### 5.1 IMDA Pillar 1 — Internal Governance Structures and Measures

| Control | Implementation under rev 3 | Evidence |
|---|---|---|
| Defined accountability roles | Single role: `judge` with RBAC via `require_role()` (unchanged) | `src/api/deps.py:92` |
| 4-gate HITL approval | Pipeline pauses at 4 review gates via `interrupt()`; legacy `awaiting_review_gate*` status preserved for compatibility | `src/pipeline/graph/nodes/gate{1,2,3,4}_review_*.py` (4.A3.3-4) |
| Independent audit | `auditor` agent (replaces `governance-verdict`) runs 5-phase audit on completed state; structural independence | `src/pipeline/graph/agents/factory.py:make_phase_node("audit")` (1.A1.4) |
| Append-only audit trail | Every middleware-driven action UPSERTs an entry; `APPEND_ONLY_FIELDS` validation preserved | `src/shared/validation.py:25`; audit middleware (1.A1.4) |
| Trace substrate | LangSmith trace per case; one click from React → trace → tool span; replaces MLflow | `src/pipeline/graph/runner.py` (2.C1.4) |
| Schema versioning | `pipeline_checkpoints` schema version gate (until 2.A2.10 cutover); `PostgresSaver` after | `src/db/pipeline_state.py:39` |

### 5.2 IMDA Pillar 2 — Determining Level of Human Involvement

VerdictCouncil treats AI as **advisory only**. No AI output is binding without a judge's recorded decision. The 4 gates implement meaningful human oversight.

| Decision point | AI role | Human role |
|---|---|---|
| Gate 1 review | `intake` produces parties/domain/complexity/route | Judge reviews; advance / re-run / halt |
| Gate 2 review | 4 parallel research subagents produce dossier | Judge reviews each tab; can re-run a single subagent or all 4 |
| Gate 3 review | `synthesis` produces IRAC arguments + pre-hearing brief | Judge reviews; can edit a question, dispute an argument, or re-run with notes |
| Gate 4 + decision | `auditor` produces fairness/citation/completeness report | Judge approves & finalizes (records `judicial_decision` with `ai_engagements`), or sends back to a specific phase, or halts |
| Fact dispute | — | Judge marks any extracted fact as `disputed` |
| What-If contestability | LangGraph fork: `update_state(past_config, ...)` + `invoke(None, fork_config)` | Judge sees how analysis changes when evidence excluded or facts toggled |

### 5.3 IMDA Pillar 3 — Operations Management

| Control | rev 3 status |
|---|---|
| Input sanitization (regex L1 + DeBERTa-v3 L2) | **Preserved** — `src/shared/sanitization.py`, scoped to admin RAG ingest. Verified by 1.A1.SEC1. |
| Output integrity check | **Strengthened** — Pydantic `response_format=Schema` with `extra="forbid"` replaces best-effort JSON mode; LangChain's `ToolStrategy.handle_errors=True` retries on validation failure |
| Field ownership | **Replaced** — Pydantic schemas with `extra="forbid"` per phase (1.A1.SEC3); deletes `FIELD_OWNERSHIP` dict |
| Pipeline resilience | **Preserved + extended** — LangGraph `RetryPolicy` + semantic-incompleteness routers + PAIR circuit-breaker; replaces Redis Lua barrier with `Send` fan-out |
| External API resilience | **Preserved** — PAIR rate-limit, Redis cache, circuit-breaker, vector-store fallback in `tools/search_precedents.py` |
| Checkpoint replay | **Strengthened** — `PostgresSaver` enables `get_state_history`, `update_state`, `invoke(None, past_config)`; What-If reuses these primitives |
| Distributed LLM tracing | **Closed (was R-15 gap)** — LangSmith natively traces every LangChain call |
| Dependency CVE scanning | **Preserved** — `pip-audit` advisory in CI |
| Adversarial CI tests | **Preserved** — 10 guardrail unit tests (verified by 1.A1.SEC2) |

### 5.4 IMDA Pillar 4 — Stakeholder Interaction and Communication

| Control | rev 3 implementation |
|---|---|
| Explainable deliberation | `synthesis` agent's IRAC structure cites which research subagent's facts/evidence each step uses |
| Citation provenance | Every citation in `legal_rules`/`precedents` carries `supporting_sources: list[str]` referencing `source_id`; unmatched citations enter `suppressed_citation` table with reason ENUM |
| Fairness audit disclosure | `auditor.fairness_check.issues_found[]` visible in case dossier; surfaced at gate4 review screen |
| Verdict alternatives | `synthesis.uncertainty_flags` lists alternative outcomes with confidence; `auditor` flags imbalance |
| PAIR API source disclosure | Vector-store-fallback results tagged `source: "vector_store_fallback"` |
| Legal citation integrity | `research-law` prompt forbids unsupported citations; `output_validator.py` (3.B.5) enforces post-hoc |
| Judge dossier | Gate 2 review screen renders all 4 research subagent outputs in tabbed view (4.C5b.2) |
| Decision audit | `judicial_decision` JSONB on `cases` table preserved; per-conclusion `ai_engagements` (agree/disagree + reasoning) |
| Trace link | Every gate review screen shows a "View LangSmith trace" link; one click to full trace |

### 5.5 Fairness and Bias Mitigation (re-anchored)

1. **Mandatory fairness audit** — `auditor` agent runs Phase 1 bias check before producing any approval recommendation. System prompt instructs aggressive false-positive flagging.
2. **Aggressive false-positive tolerance** — preserved verbatim from prior `governance-verdict` design choice.
3. **Fact dispute mechanism** — Judge can flag any AI-extracted fact at gate2 review. Disputes flow into `extra_instructions` for re-run.
4. **No direct demographic input** — agents receive document text + structured metadata. No demographic fields (race, religion, nationality) in `CaseState`. Structural exclusion preserved.

**Known limitation:** No automated demographic bias eval set yet. Gap tracked; remediation (~4-8h per existing register) deferred but eligible for D1 evaluator extension once labeled data exists.

---

## §6. AI Security Risk Register (rev 3)

This section re-validates the 16 risks from `SECURITY_RISK_REGISTER.md` against rev 3 architecture and adds 3 new architecture-related risks. Sprint 0 task 0.8 propagates to the live doc.

### 6.1 Existing risks re-validated

| ID | Risk | Status under rev 3 | Notes |
|---|---|---|---|
| R-01 | Prompt injection via uploaded documents | ✓ unchanged | DeBERTa-v3 + regex preserved at admin RAG ingest |
| R-02 | Hallucinated legal citations | **strengthened** | `supporting_sources` enforcement + auditor `no_source_match` reason + `suppressed_citation` table |
| R-03 | Demographic bias in recommendation | ✓ unchanged | Auditor's fairness-audit prompt distilled into LangSmith `audit` prompt commit; structural exclusion preserved |
| R-04 | Unauthorized case access | ✓ unchanged | RBAC + JWT cookie unchanged |
| R-05 | Audit log tampering | ✓ unchanged | APPEND_ONLY enforced via audit middleware (1.A1.2) |
| R-06 | Pipeline state corruption (field ownership) | **replaced** | `FIELD_OWNERSHIP` allowlist → Pydantic `response_format` schemas with `extra="forbid"`; native validation; 1.A1.SEC3 deletes legacy code |
| R-07 | PAIR API unavailability | ✓ unchanged | Circuit-breaker preserved in `tools/search_precedents.py` |
| R-08 | Session hijacking via JWT theft | ✓ unchanged | Out of scope of overhaul |
| R-09 | Rate limit bypass via distributed clients | ⚠ open | In-memory limiter not Redis-shared; tracked separately, not addressed in this overhaul |
| R-10 | What-If scenario leaking verdict data | **reimplemented** | LangGraph `update_state(past_config, ...)` + `invoke(None, fork_config)`; thread_id segregation; integration test 4.A5.4 |
| R-11 | Dependency CVE exploitation | ⚠ open | `pip-audit` advisory; tracked separately |
| R-12 | Bandit-detected security issues | ⚠ open | `bandit` advisory; tracked separately |
| R-13 | Stuck pipeline / resource exhaustion | ✓ unchanged | StuckCaseWatchdog preserved |
| R-14 | LLM output not schema-validated | **strengthened** | `response_format=PydanticModel` strict by default; `ToolStrategy.handle_errors=True` retries; LangChain native validation replaces best-effort JSON mode |
| R-15 | No distributed LLM tracing | **closed** | LangSmith natively traces; `trace_id` flows FastAPI → LangSmith → SSE; closes the gap |
| R-16 | Senior judge inbox not fully implemented | ⚠ open | Out of scope of overhaul |

### 6.2 New risks introduced by rev 3

| ID | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R-17 | Topology rewrite (1.A1.7) regresses behavior we don't notice | Med | High | Replay-N-cases test (1.A1.10) asserts terminal-state semantic equivalence; LangSmith eval baseline (3.D1.4) catches scorer regression at CI gate (4.D3.1) |
| R-18 | LangSmith vendor outage breaks observability | Low | Low | LangSmith client fail-open; pipeline keeps running; degraded observability only |
| R-19 | `Send` parallel research without idempotency safeguards re-runs subagent on resume | Low | Med | Subagent nodes idempotent by design (no DB writes; produce structured output); audit middleware UPSERTs only; integration test 4.A3.12 covers idempotency |

### 6.3 Risk Summary

| Severity | Count | Status |
|---|---|---|
| Critical impact, mitigated (rev 3) | 5 (R-01, R-02, R-03, R-05, R-06) | ✓ controls in place |
| High impact, mitigated (rev 3) | 5 (R-04, R-07, R-08, R-10, R-17) | ✓ controls in place |
| Med-residual gaps (unchanged) | 4 (R-09, R-11, R-12, R-16) | Tracked separately |
| Closed by rev 3 | 1 (R-15) | LangSmith |
| New rev-3 risks | 3 (R-17, R-18, R-19) | Mitigated |

---

## §7. MLSecOps / LLMSecOps Pipeline (rev 3)

This section replaces `MLSECOPS_SECTION.md` content. Sprint 0 task 0.9 propagates.

### 7.1 CI/CD Pipeline (rev 3)

```
Push / PR
    │
    ▼
┌──────────────────────────────┐
│ lint (ruff)                  │  style + import hygiene; BLOCKING
└────────┬─────────────────────┘
         │
   ┌─────┼──────┬──────────┬───────────┐
   ▼     ▼      ▼          ▼           ▼
test   openapi security  eval (NEW)  docker
pytest snapshot pip-audit langsmith  build
≥65%   diff    bandit -ll evaluate
covg.   check   BLOCKING  >5% drop
                          fails
```

| Job | Trigger | Gate type | Blocks merge? |
|---|---|---|---|
| `lint` | every push | style | Yes |
| `test` | needs: lint | quality (coverage ≥ 65%) + 10 adversarial guardrail tests | Yes |
| `openapi` | needs: lint | contract drift | Yes |
| `security` | needs: lint | static analysis (`bandit` BLOCKING; `pip-audit` advisory) | Yes (`bandit`) |
| **`eval`** (NEW) | needs: test, on PRs touching `pipeline/`, `prompts/`, `tools/` | LangSmith eval >5% drop fails (4.D3.1) | Yes |
| `docker` | needs: test | build integrity | Yes |

### 7.2 LLM-Specific Security Gates (preserved from existing)

#### Adversarial injection testing (10 unit tests — preserved verbatim)

| File | Tests | Coverage |
|---|---|---|
| `tests/unit/test_guardrails_activation.py` | 5 | OpenAI `<\|im_start\|>`, `<system>` tag, `InputGuardrailHook` audit, benign passes |
| `tests/unit/test_guardrails_adversarial.py` | 5 | LLM classifier blocks long-form override, benign passes, `<<SYS>>` Llama caught, null bytes / markdown system stripped, `method` field for forensic log |

Verified to still pass post-architecture by 1.A1.SEC2.

#### DeBERTa-v3 RAG corpus sanitizer (preserved verbatim — see existing §7.8)

Two-layer defence at admin upload:
- **L1** — Regex (9 compiled patterns; <1ms/page; delimiter-based injection)
- **L2** — `llm-guard==0.3.16` wrapping `protectai/deberta-v3-base-prompt-injection-v2` (95.25% accuracy; 99.74% recall; 0.2-2s MPS / ~80ms CPU)

Scope: **admin RAG upload only** (`run_classifier` kwarg on `parse_document` defaults False for case-processing pipeline).

Verified to still wire post-architecture by 1.A1.SEC1.

### 7.3 Tracing Pipeline (rev 3 — LangSmith replaces MLflow)

```
FastAPI lifespan
  └─ langsmith.Client() init      # opt-in via LANGSMITH_TRACING=true
       (no autolog call needed — LangChain hooks LangSmith automatically)

GraphPipelineRunner.run()
  └─ langsmith experiment per case run (auto)
       └─ per-phase span (auto)
            └─ per-tool span (auto, no tool_span() helper)
            └─ prompt commit hash on each LangChain agent run

Frontend (Sentry)
  └─ tagSession(trace_id, traceUrl) on each SSE event
```

#### What is traced (rev 3)

| Trace source | Data captured |
|---|---|
| LangSmith auto-tracing | Prompt, completion, model, token usage, latency per LangChain agent / tool call |
| LangSmith metadata | `case_id`, `run_id`, `trace_id`, `thread_id` tags on the parent run |
| Audit middleware | `AuditEntry` rows in PostgreSQL — semantic events (gate_advanced, gate_rerun_requested, suppressed_citation, etc.) |
| W3C `traceparent` | FastAPI → LangGraph config metadata → LangSmith → SSE event → React → Sentry |

Two complementary axes preserved: machine performance (LangSmith) + judicial workflow (PostgreSQL audit).

### 7.4 Audit Trail and Logging (preserved + extended)

`audit_log` table gains 6 new columns post-4.C4.1: `trace_id`, `span_id`, `retrieved_source_ids JSONB`, `cost_usd NUMERIC`, `redaction_applied BOOLEAN`, `judge_correction_id BIGINT FK`. APPEND_ONLY contract preserved.

New tables (4.C4.1): `judge_corrections` (phase-keyed, replaces agent-keyed), `suppressed_citation` (phase-keyed, with reason ENUM).

### 7.5 Deployment (preserved)

| Service | Purpose |
|---|---|
| FastAPI API | REST + SSE pipeline events (unchanged) |
| PostgreSQL 16 | Cases, audit, `PostgresSaver` checkpoints (replaces custom checkpoint table) |
| Redis 7 | SSE pub/sub, rate limiting (preserved) |
| ~~Solace PubSub+~~ | **Removed** — SAM mesh runner no longer used |
| ~~MLflow~~ | **Removed** — LangSmith replaces |
| LangSmith (cloud) | Tracing + Prompts + Evaluations (replaces MLflow) |

### 7.6 Branch / Release Flow (preserved)

```
feat/* → development → staging-deploy.yml → release/* → main → production-deploy.yml
```

CI / staging / production unchanged in shape; only the eval gate is new (4.D3.1).

---

## §8. Human-in-the-Loop UX Design

This section specifies what the judge actually sees and does at each of the 4 gates. Per the `langgraph-human-in-the-loop` skill, all `interrupt()` payloads are JSON-serializable, all pause-node side effects are idempotent UPSERTs, and parallel-branch resume uses ID-keyed maps where applicable.

### 8.1 Common pattern — `<GateReviewPanel>`

Shared React component (4.C5b.1) used by all 4 gates with a per-gate body slot.

**Props:** `{ gate: 1..4, phaseOutput: object, traceId: string, onAction: (payload) => void }`

**Resume payload contract:**
```json
{
  "action": "advance" | "rerun" | "halt" | "send_back",
  "notes": "optional free-text → goes into extra_instructions",
  "field_corrections": {},
  "subagent": "evidence|facts|witnesses|law",
  "to_phase": "intake|research|synthesis"
}
```

A backend validator on `Command(resume=...)` rejects unknown actions before any state mutation.

### 8.2 Gate 1 — Intake Review

**`interrupt()` payload (the snapshot):**
```python
interrupt({
    "gate": "gate1",
    "case_id": ...,
    "phase_output": IntakeOutput(...),  # parties, domain, complexity_score, route, ...
    "trace_id": ...,
    "actions": ["advance", "rerun", "halt"],
})
```

**Wireframe:**
```
┌──────────────────────────────────────────────────────────────┐
│ Case 0xABC — Gate 1: Intake Review                            │
├──────────────────────────────────────────────────────────────┤
│ Domain: TRAFFIC-COURT      Complexity: 0.42 (Standard)        │
│ Parties: J. Smith (claimant) v. Singapore Police Force         │
│                                                                │
│ ► Red flags (0):       (none)                                  │
│ ► Vulnerability:       None detected                           │
│ ► Completeness:        0.92  ⚠ missing: hearing transcript     │
│                                                                │
│ ┌─ Documents (3) ────────────────────────────────────────┐    │
│ │ • Charge sheet (parsed, sanitized)                      │    │
│ │ • Police report (parsed, sanitized)                     │    │
│ │ • Driver licence excerpt (parsed, sanitized)            │    │
│ └────────────────────────────────────────────────────────┘    │
│                                                                │
│ Notes for AI (optional, free text):                            │
│ ┌──────────────────────────────────────────────────────────┐  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                │
│   [ Advance to Research ]  [ Re-run Intake ]  [ Halt Case ]   │
│                                                                │
│ [Trace: smith.langchain.com/...] [Audit log] [What-If]        │
└──────────────────────────────────────────────────────────────┘
```

**Body component:** `<Gate1IntakeReview>` (4.C5b.2). Renders parties / domain / complexity / route / red flags / completeness / sanitized documents.

### 8.3 Gate 2 — Research Review (most complex)

The 4 parallel research subagents produce one merged `ResearchOutput`. `research_join` runs once and emits a single `interrupt()` — the judge's resume map can target a single subagent or the whole research phase.

**`interrupt()` payload:**
```python
interrupt({
    "gate": "gate2",
    "case_id": ...,
    "phase_output": ResearchOutput(
        evidence_analysis=...,
        extracted_facts=...,
        witnesses=...,
        legal_rules=...,
        precedents=...,
    ),
    "trace_id": ...,
    "actions": ["advance", "rerun", "halt"],
    "subagents_available_for_rerun": ["evidence", "facts", "witnesses", "law"],
})
```

**Wireframe:**
```
┌──────────────────────────────────────────────────────────────┐
│ Case 0xABC — Gate 2: Research Review                          │
├──────────────────────────────────────────────────────────────┤
│ ┌─Tabs─────────────────────────────────────────────────────┐  │
│ │ Evidence | Facts | Witnesses | Law                        │  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                │
│ [active: Evidence]                                             │
│ Evidence weight matrix: ▓▓▓▓▓▓▓░░░ 7 items, 1 contradiction   │
│ Items:                                                         │
│   1. Police body cam (digital)  — strong (0.86)  [✓ accept]   │
│   2. Witness statement A — moderate (0.65)        [⚠ dispute] │
│   ...                                                          │
│                                                                │
│ Re-run options (multi-select):                                 │
│   ☐ Re-run Evidence subagent only                             │
│   ☐ Re-run all research                                       │
│                                                                │
│ Notes:                                                         │
│ ┌──────────────────────────────────────────────────────────┐  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                │
│   [ Advance to Synthesis ]  [ Re-run ]  [ Halt ]              │
└──────────────────────────────────────────────────────────────┘
```

**Body component:** `<Gate2ResearchReview>` (4.C5b.2). Tabbed dossier; per-subagent rerun checkboxes; fact-dispute interactions.

**Resume payload extends** with `subagent` field when targeting a single research lane.

### 8.4 Gate 3 — Synthesis Review

```
┌──────────────────────────────────────────────────────────────┐
│ Case 0xABC — Gate 3: Synthesis Review                         │
├──────────────────────────────────────────────────────────────┤
│ ┌─ Arguments ─────────────────────────────────────────────┐   │
│ │  Claimant (strength 0.71)  │  Respondent (strength 0.62) │   │
│ │  • Issue: speed >50kph     │  • Issue: speed mis-recorded│   │
│ │    Rule: RTA s.63(1)       │    Rule: same               │   │
│ │    Application: ...        │    Application: contests... │   │
│ │    Conclusion: liable      │    Conclusion: not liable   │   │
│ └────────────────────────────────────────────────────────┘    │
│                                                                │
│ Pre-hearing brief (480 words): [expand]                        │
│ Judicial questions (5):  [expand]                              │
│ Uncertainty flags (2):   [expand]                              │
│                                                                │
│ Notes (optional):                                              │
│ ┌──────────────────────────────────────────────────────────┐  │
│ └──────────────────────────────────────────────────────────┘  │
│                                                                │
│   [ Advance to Audit ]  [ Re-run Synthesis ]  [ Halt ]        │
└──────────────────────────────────────────────────────────────┘
```

Body component: `<Gate3SynthesisReview>` (4.C5b.2). Side-by-side argument comparison; collapse-by-default for brief/questions/uncertainty.

### 8.5 Gate 4 — Auditor Review (final approval)

```
┌──────────────────────────────────────────────────────────────┐
│ Case 0xABC — Gate 4: Auditor Review                           │
├──────────────────────────────────────────────────────────────┤
│ Fairness audit:    ⚠ 1 finding                                │
│   • Argument balance: respondent 2 weaknesses, claimant 4.    │
│                                                                │
│ Citation audit:    ✓ all 12 citations grounded                │
│   • 0 hallucinated                                            │
│   • 1 suppressed (no_source_match)                            │
│                                                                │
│ Completeness:      ✓ all required fields present              │
│ Integrity:         ✓ all guardrails honored                   │
│                                                                │
│ Cost: $0.42  |  Tokens: 38,210  |  Duration: 4m 12s           │
│                                                                │
│   [ Approve & finalize ]  [ Send back to: ▼ ]  [ Halt ]       │
└──────────────────────────────────────────────────────────────┘
```

Body component: `<Gate4AuditorReview>` (4.C5b.2). Findings list with severity icons; `Send back to ▼` dropdown lets judge pick `intake | research | synthesis`. Approve records `judicial_decision` JSONB with per-conclusion `ai_engagements`.

**Resume `send_back` flow:** `Command(resume={"action": "send_back", "to_phase": "synthesis", "notes": "..."})` triggers backend rewind via `update_state(past_config_for_phase, ...)` + `invoke(None, ...)`. Implementation in 4.A3.14.

### 8.6 HITL Implementation Constraints (per langgraph-human-in-the-loop skill)

1. **Pause-node body must be cheap and idempotent.** No LLM calls in the pause node — the phase output was already produced upstream. The pause node only packages the snapshot for the interrupt payload.
2. **All side-effects before `interrupt()` are UPSERTs.** Compatibility writes to `awaiting_review_gate*` and `gate_state` JSONB use UPSERT to be safe under resume re-execution.
3. **Resume re-runs the node from the top.** If the gate-pause node had any pre-interrupt code that changed state non-idempotently, it would corrupt on resume. Audited by 4.A3.1, fixed by 4.A3.2.
4. **Single-interrupt-per-gate.** Even Gate 2 (4 parallel subagents) emits ONE interrupt at `research_join`, not 4. Avoids the multi-interrupt resume-map complexity for the common path.
5. **Audit middleware UPSERTs only.** Any audit row written before the gate interrupt must be safe to re-write on resume; 1.A1.4 enforces.

---

## Current State (audited 2026-04-25 against submodule HEAD)

- LangGraph StateGraph at `pipeline/graph/builder.py:151–244` — **9 agents** across 4 gates.
- Manual tool-call loop at `nodes/common.py:189–263` reinvents `ToolNode`.
- Custom Postgres checkpoint via `db/pipeline_state.py:53–62`; no LangGraph checkpointer.
- HITL is `awaiting_review_gate{1..4}` status string + Redis cancel-flag polling; no `interrupt()`.
- Retrieval: OpenAI `vector_stores.search` (`services/knowledge_base.py:24–206`, `pipeline/graph/tools.py:264–313`); per-judge + per-domain stores already isolated.
- Tools registered: `parse_document`, `cross_reference`, `timeline_construct`, `generate_questions`, `confidence_calc`, `search_precedents`, `search_domain_guidance`. **Sprint 0 will verify which are real vs LLM-wrappers.**
- `mlflow.langchain.autolog()` wired (to be removed); per-agent spans + unused `tool_span()`. No LangSmith. No CI eval gate.
- No `judge_corrections` table. No `cost_usd` columns. Latest Alembic migration: `0024_pipeline_events_replay.py`.

## Desired End State

- **6-agent topology** (intake / 4 research subagents / synthesis / auditor) compiled with `PostgresSaver`; `thread_id = case_id`. `get_state_history`, `update_state`, replay, fork all work.
- Each phase node built via `make_phase_node(phase)` factory using `create_agent(model, tools, system_prompt, response_format=Schema, middleware=[...])`. Native `response_format` handles structured output — custom output parsers deleted.
- Research phase uses LangGraph `Send` to fan out 4 subagents in parallel; programmatic join produces a single `ResearchOutput`.
- Gate review uses `interrupt()`; `Command(resume={...})` advances/reruns. Compatibility nodes still write legacy `awaiting_review_gate*` and `gate_state` JSONB.
- Search tools return `(formatted_string, list[Document])` via `@tool(response_format="content_and_artifact")`. Citation provenance: `supporting_sources: list[str]` referencing `f"{file_id}:{sha256(content)[:12]}"`.
- LangSmith is primary observability: per-case trace, per-phase span, per-tool span, prompt commit hash, cost rollup. Sentry session links to LangSmith trace URL.
- W3C `traceparent` flows FastAPI → LangGraph config metadata → LangSmith → SSE → React → Sentry.
- LangSmith Prompts holds 7 prompts; judge corrections create new commits.
- CI runs `langsmith.evaluate(...)` on every PR touching `pipeline/`, `prompts/`, `tools/`; fails on >5% regression.
- Audit table gains `trace_id`, `span_id`, `retrieved_source_ids JSONB`, `cost_usd`, `redaction_applied`, `judge_correction_id`. New tables: `judge_corrections`, `suppressed_citation`. **No `prompt_version` column** — LangSmith owns it.

### Verification Smoke Test

1. POST a new case → backend emits real `traceparent`.
2. SSE timeline shows `intake_started` → `intake_complete` → `gate1_interrupt` → `research_started` (with 4 parallel subagent events) → `research_complete` → `gate2_interrupt` → `synthesis_*` → `gate3_interrupt` → `audit_*` → `gate4_interrupt`. Every event carries `trace_id`.
3. React UI links each event to its LangSmith span.
4. `legal` research subagent returns sources with `file_id`. The merged `legal_rules` field carries `supporting_sources` referencing those IDs.
5. `auditor` flags an injected hallucinated citation → `suppressed_citation` row with `reason=no_source_match`.
6. Judge clicks Advance at gate1 → graph reaches gate2; rerun synthesis with extra_instructions → only synthesis re-runs and a new LangSmith prompt commit is registered.
7. CI on a PR that breaks the synthesis prompt fails the eval suite.

---

## Implementation Approach

```
Sprint 0  Schema + output-model + tool + architecture audit  (prereq, blocks Sprint 1)
Sprint 1  A1 (phased create_agent + middleware + SSE bridge + Send fan-out)
          + C3a (LangSmith Prompts — 7 prompts)
          + DEP1 (langgraph.json + `langgraph dev` local validation)
Sprint 2  A2 (PostgresSaver hard cut — local dev; cloud uses LangGraph-managed checkpointer)
          + C1 (OTEL → LangSmith metadata)
Sprint 3  B  (citation provenance on existing OpenAI vector store)
          + D1 (LangSmith evaluate)
Sprint 4  A3 (interrupt + status compatibility)
          + A4 (retry router cleanup)
          + C4 (audit schema + suppressed_citation + judge_corrections)
          + C5 (Sentry → LangSmith trace URL)
          + D3 (CI eval gate on LangSmith)
Sprint 5  DEP (Cloud deployment via LangGraph Platform + LangSmith Deployment SDK)
          — graph runs on LangGraph Cloud; FastAPI is BFF; frontend on Vercel
Sprint 6+ E  (Deep Agents Judge Assistant — deferred indefinitely)
```

---

## Phase 0 — Schema, Output-Model, Tool & Architecture Audit Spike

### 0.1 DB schema inventory

Document current shape of every pipeline-touching table. Output: `tasks/schema-audit-2026-04-25.md`.

### 0.2 Output-model inventory

For each of the 9 current agent output schemas, document field count, required/optional ratio, fields that frequently retry, duplicates. Identify which fields collapse under the new 6-agent topology (e.g., `evidence_analysis` + `extracted_facts` + `witnesses` + `legal_rules` + `precedents` all live under a single `ResearchOutput` Pydantic model). Output: `tasks/output-model-audit-2026-04-25.md`.

### 0.3 Tool implementation audit (NEW)

For each registered tool (`parse_document`, `cross_reference`, `timeline_construct`, `generate_questions`, `confidence_calc`, `search_precedents`, `search_domain_guidance`), inspect the implementation. Categorize each as:

- **Real tool** — calls external API, runs deterministic code, or wraps domain-specific logic that isn't just an LLM call. Keep.
- **LLM-wrapper** — internally an LLM call dressed up as a tool. Drop; fold into agent reasoning.
- **Redundant** — duplicates work that the agent does natively in structured output. Drop.

Output: `tasks/tool-audit-2026-04-25.md` with per-tool verdict.

### 0.4 Architecture proposal (NEW)

Formalize the Option 2 architecture as concrete deliverables:
- Final agent topology (6 agents + their boundaries)
- 7 LangSmith prompt names + one-line role per prompt
- `Send` fan-out pattern for research phase + Python join function signature
- Tool roster post-0.3 (likely 3 real tools)
- State schema deltas (which CaseState fields are populated by which phase)

Output: `tasks/architecture-2026-04-25.md`.

### 0.5 Target schema doc

Combine 0.1–0.4 into a unified target-state proposal:
- Final DB shape (single `audit_log` vs split, `judge_corrections`, `suppressed_citation`)
- Final Pydantic output schemas per phase (IntakeOutput, EvidenceResearch / FactsResearch / WitnessesResearch / LawResearch, ResearchOutput, SynthesisOutput, AuditOutput)
- Migration sequence across Sprints 1–4

Output: `tasks/schema-target-2026-04-25.md`.

### 0.6 Approval gate

User reviews 0.4 + 0.5. Sprint 1 cleared to start only after approval.

---

## Phase 1 — Sprint 1: A1 + C3a

### 1.A1 — Phased `create_agent` + middleware + SSE bridge + Send fan-out

Replace 9 separate agent nodes with a small set of phased nodes wired around `create_agent(...)`. Topology per Sprint 0 §0.4.

**Key code changes:**

- **New:** `pipeline/graph/middleware/{sse_bridge,cancellation,audit}.py` — four hooks: `sse_tool_emitter`, `token_usage_emitter`, `cancel_check`, `audit_tool_call`.
- **New:** `pipeline/graph/runner_stream_adapter.py` — bridges `astream(stream_mode="custom")` chunks to existing Redis `publish_progress`.
- **New:** `pipeline/graph/agents/factory.py` — single `make_phase_node(phase)` factory + `make_research_subagent(scope)` factory. Both wrap `create_agent` with phase-appropriate `system_prompt`, `response_format`, `middleware`, and model tier.
- **New:** `pipeline/graph/research_dispatch.py` — Python function returning `Send` calls to 4 parallel research subagents. Plus `research_join` Python function that takes the four `ToolMessage`-equivalent outputs and merges into a single `ResearchOutput`.
- **Rewrite:** `nodes/common.py` — replace `_run_agent_node` (290 lines) with the factory. Delete: manual tool loop (189–263), `_token_usage` (72–80), inline cancel polling (163, 257), runtime prompt concat (121–135), custom output parser. ~70% size reduction.
- **Rewrite:** `builder.py:151–244` — wire phased topology: intake → gate1 → research_dispatch (Send) → 4 subagents → research_join → gate2 → synthesis → gate3 → auditor → gate4 → END. Preserve `RetryPolicy` (`:148`) and semantic-incompleteness routers (`:64–117`).
- **Update:** `runner.py` — call `stream_to_sse` instead of `ainvoke`.
- **Drop:** the 4 fake reasoning tools per Sprint 0 §0.3 verdict.

### 1.C3a — LangSmith Prompts (7 prompts)

Move agent prompts from `pipeline/graph/prompts.py` literals to LangSmith Prompts. `prompts.py` becomes a cached `client.pull_prompt(name)` lookup. Judge corrections push a new prompt commit instead of runtime concatenation.

**Prompt inventory** (per Sprint 0 §0.4 outcome):

| LangSmith name | Used by | Role one-liner |
|---|---|---|
| `verdict-council/intake` | intake node | Triage + complexity + route |
| `verdict-council/research-evidence` | research subagent (evidence) | Classify evidence; weight matrix; impartiality |
| `verdict-council/research-facts` | research subagent (facts) | Fact ledger + timeline + causal chain |
| `verdict-council/research-witnesses` | research subagent (witnesses) | Credibility (PEAR) + question bank |
| `verdict-council/research-law` | research subagent (law) | Statutes + precedents + citation provenance |
| `verdict-council/synthesis` | synthesis node | IRAC arguments + pre-hearing brief + judicial questions |
| `verdict-council/audit` | auditor node | Independent fairness audit; flag violations |

**Key code changes:**
- **New:** `scripts/migrate_prompts_to_langsmith.py` — idempotent push of the 7 prompts.
- **Rewrite:** `pipeline/graph/prompts.py` → `get_prompt(name, judge_corrections=None) -> tuple[str, str]` (template + commit hash), `lru_cache(maxsize=64)`.
- **Update:** `nodes/common.py:121–135` removed; `factory.py` calls `get_prompt(...)`.
- **Env:** `LANGSMITH_API_KEY`, `LANGSMITH_PROJECT`, `LANGSMITH_TRACING=true`.

---

## Phase 2 — Sprint 2: A2 + C1

### 2.A2 — Hard-cut migration to `PostgresSaver`

Unchanged from rev 2. Replace `db/pipeline_state.py` with `langgraph.checkpoint.postgres.PostgresSaver`. `thread_id = case_id`. Pre-cutover serialization round-trip blocker (`scripts/check_casestate_serialization.py`). Maintenance-window cutover with `migrate_in_flight_cases.py`.

### 2.C1 — OTEL → LangSmith metadata

W3C `traceparent` flows FastAPI → LangGraph config `metadata.trace_id` → LangSmith → SSE → React → Sentry. **All MLflow code deleted in 2.C1.7** (autolog, prompt_version tag, `tool_span()`, `agent_run`, `pipeline/observability.py` module trimmed or deleted).

---

## Phase 3 — Sprint 3: B + D1

### 3.B — Citation provenance on existing OpenAI vector store

No retrieval engine change. Wrap `search_precedents` and `search_legal_rules` (renamed from `search_domain_guidance`) tools as `@tool(response_format="content_and_artifact")` returning `(formatted_string, list[Document])` with `Document.metadata["source_id"] = f"{file_id}:{sha256(content)[:12]}"`. Audit middleware persists `retrieved_source_ids`. The **research-law subagent** is the primary consumer; output schema's `legal_rules` and `precedents` items carry `supporting_sources: list[str]`. The **auditor agent** validates each citation's `source_id` exists in the run's tool-artifact chain; unmatched → `suppressed_citation` row with reason ENUM.

### 3.D1 — LangSmith evaluations

`langsmith.evaluate(target_fn, data=dataset_name, evaluators=[...])`. Custom evaluators: `CitationAccuracy`, `LegalElementCoverage`. Dataset = ~5–10 hand-curated golden cases per demo domain (traffic court + small claims), curator = user.

---

## Phase 4 — Sprint 4: A3 + A4 + C4 + C5 + D3

### 4.A3 — `interrupt()` for judge gating + status compatibility

Each gate's last step calls `interrupt({...})`. Compatibility node after the interrupt (idempotent UPSERT) writes legacy `awaiting_review_gate*` + `gate_state` JSONB so case-list filters, watchdogs, the rerun conflict-check, the SSE terminal-signal logic, and the React UI keep working unchanged.

**Drift note:** `/advance` endpoint is at `cases.py:~1640` (`advance_gate` function), not `1275–1445`. Rerun is at `~1700–1758`.

**Coordination:** since the synthesis phase merged two old agents (argument-construction + hearing-analysis), the rerun endpoint must accept a phase-level rerun (not an agent-level one) — the request body changes from `{"agent": "evidence-analysis"}` to `{"phase": "synthesis"}`. Confirm UI compatibility in Sprint 0.

### 4.A4 — Retry router cleanup (NOT replacement)

Keep semantic-incompleteness routers at `builder.py:64–117`. Move `retry_counts` increment into reducer-only update. Separate conditional edge for routing. ~30 lines removed. Routers now key on **phase name** (intake / research / synthesis / audit), not the old 9 agent names.

### 4.C4 — Audit schema + `suppressed_citation` + `judge_corrections`

Per Sprint 0 §0.5 approved target. Baseline assumption (Sprint 0 may amend):

```sql
-- Per codex P1 finding 6: case_id is UUID + FK to cases(id) ON DELETE CASCADE.
-- Phase and subagent constrained at db level. Indexes on case_id, run_id, trace_id.

CREATE TABLE judge_corrections (
    id BIGSERIAL PRIMARY KEY,
    case_id UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL,
    phase TEXT NOT NULL CHECK (phase IN ('intake','research','synthesis','audit')),
    subagent TEXT CHECK (subagent IS NULL OR subagent IN ('evidence','facts','witnesses','law')),
    CHECK (subagent IS NULL OR phase = 'research'),
    correction_text TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX judge_corrections_case_idx ON judge_corrections (case_id);
CREATE INDEX judge_corrections_run_idx  ON judge_corrections (run_id);

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

**No `prompt_version` column** — LangSmith prompt commit hashes live on the trace metadata.

- `api/routes/cost.py` — `/cost/summary?case_id=...&from=...&to=...`
- Per-model price table + `calc_cost(model_id, usage)` helper
- Prometheus gauge: `verdict_council_case_cost_usd`

### 4.C5 — Frontend Sentry → LangSmith link

`@sentry/react` + `src/sentry.ts`. Tag every event with `backend_trace_id` + `backend_trace_url` (LangSmith). Frontend has no `sseClient.ts` — locator grep finds the actual SSE consumer (likely a hook or page-level effect).

### 4.D3 — CI eval gate

`.github/workflows/eval.yml` runs `tests/eval/run_eval.py` on every PR touching `pipeline/`, `prompts/`, `tools/`. Compares to baseline LangSmith experiment; fails if any scorer drops >5%. Override via `eval/skip-regression` label + CODEOWNERS reviewer.

---

## Phase 5 — Sprint 5: Cloud Deployment via LangGraph Platform + LangSmith Deployment SDK

Project assessment requires a live cloud-deployed demo. Sprint 5 takes the rev-3 6-agent topology built in Sprints 0–4 and ships it to **LangGraph Platform Cloud** using the **LangGraph CLI** for build artifacts and the **LangSmith Deployment SDK** for programmatic deployment management.

### 9.1 Deployment topology

```
                    React Frontend
                  (Vercel or Netlify)
                          │
                          │ HTTPS
                          ▼
                  FastAPI BFF (DigitalOcean App Platform / fly.io / Railway)
                  • auth, JWT, RBAC
                  • case CRUD, admin uploads
                  • DeBERTa-v3 RAG sanitizer (per-request scope)
                  • SSE proxy → Redis pub/sub
                  │
                  │ HTTPS (LANGSMITH_API_KEY)
                  ▼
                  LangGraph Platform Cloud  (managed by LangChain)
                  • runs the 6-agent graph compiled from langgraph.json
                  • managed Postgres for graph checkpoints (replaces in-process PostgresSaver in prod)
                  • horizontal scaling, run queue, streaming endpoints
                  │
                  │ (LangSmith trace flows back automatically)
                  ▼
                  LangSmith Cloud  (tracing + Prompts + Evals)

External:
  Managed PostgreSQL (DigitalOcean / Supabase / RDS) — our own DB for cases, audit_log, judge_corrections, etc.
  Managed Redis (Upstash / DigitalOcean) — SSE pub/sub
  OpenAI API — LLMs + per-judge vector stores (unchanged)
```

**Key principle:** the **graph runtime** runs on LangGraph Cloud; the **application logic** (auth, case CRUD, admin uploads, audit_log writes) stays in our FastAPI BFF on a separate deploy target. Two databases now exist:
- LangGraph-managed Postgres → graph state checkpoints (transparent to us)
- Our own managed Postgres → cases, audit_log, judge_corrections, suppressed_citation, pipeline_jobs

### 9.2 LangGraph CLI workflow

```bash
# Local dev (Sprint 1 task DEP1.2)
langgraph dev          # starts local LangGraph server on :2024 backed by local Postgres
                       # FastAPI dev server points runner.py at http://localhost:2024

# Build deployable artifact (Sprint 5 task DEP.4)
langgraph build        # builds Docker image of the graph; output: gcr.io/.../verdictcouncil:<sha>

# Deploy to LangGraph Cloud (Sprint 5 task DEP.5 — via LangSmith Deployment SDK, not raw CLI)
# (see §9.3 below)
```

`langgraph.json` (committed at repo root, Sprint 1 task DEP1.1):

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

`build_graph` already exists and is the same factory used in-process by Sprints 1–4 — the cloud and local paths share one graph definition.

### 9.3 LangSmith Deployment SDK

Programmatic deployment management (rather than clicking through LangSmith UI) lives in `scripts/deploy/`:

```python
# scripts/deploy/cloud_deploy.py
from langsmith import Client
from langsmith.deployment import Deployment   # LangSmith Deployment SDK

client = Client()  # uses LANGSMITH_API_KEY

# Idempotent: create or update the deployment
deployment = Deployment(
    name="verdictcouncil",
    project_name="verdictcouncil",                        # confirmed user 2026-04-25
    graph_id="verdictcouncil",                            # matches langgraph.json
    image="gcr.io/.../verdictcouncil:<sha>",              # output of langgraph build
    env={
        "OPENAI_API_KEY": os.environ["OPENAI_API_KEY"],
        "DATABASE_URL": os.environ["APP_DATABASE_URL"],   # our own DB, not LangGraph's
        # LangGraph Cloud auto-injects LANGGRAPH_DATABASE_URL for graph checkpoints
    },
    instance_size="medium",                               # autoscaling profile
)
deployment.deploy()  # idempotent — creates new revision if image changed, else no-op

print(f"Deployed: {deployment.url}")
```

This script is the authoritative deploy path. CI invokes it on `main` merge after `langgraph build` produces a tagged image.

### 9.4 What changes in code paths

**Sprints 1–4 are unchanged.** They build the graph using LangGraph SDK in-process — that's the canonical pattern that works both locally (`langgraph dev`) and on LangGraph Cloud.

The **only Sprint 5 code change** is in `runner.py`: in production, instead of compiling the graph in-process and calling `astream` on it, FastAPI calls the LangGraph Cloud HTTP API:

```python
# pipeline/graph/runner.py (Sprint 5 task DEP.6)

class GraphPipelineRunner:
    def __init__(self):
        if settings.app_env == "dev":
            # in-process graph for local dev
            self._graph = build_graph(checkpointer=PostgresSaver.from_conn_string(settings.database_url))
            self._mode = "in_process"
        else:
            # cloud mode: HTTP client to LangGraph Cloud
            self._client = LangGraphCloudClient(api_key=settings.langsmith_api_key, deployment_url=settings.langgraph_deployment_url)
            self._mode = "cloud"

    async def run(self, case_state, trace_id=None):
        config = {"configurable": {"thread_id": case_state.case_id}, "metadata": {"trace_id": trace_id, "env": settings.app_env}}
        if self._mode == "in_process":
            async for chunk in self._graph.astream({"case": case_state}, config=config, stream_mode="custom"):
                await publish_progress(case_state.case_id, chunk)
        else:
            # cloud: open SSE to the deployment, proxy chunks into our Redis bridge
            async for chunk in self._client.stream(graph_id="verdictcouncil", input={"case": case_state}, config=config):
                await publish_progress(case_state.case_id, chunk)
```

SSE bridge to React keeps working unchanged — it's still Redis pub/sub backed. The graph just runs somewhere else.

### 9.5 What does NOT change

- The 6-agent topology, prompts, schemas, response_format, middleware
- Auth + JWT (BFF concern, lives on FastAPI side)
- DeBERTa-v3 RAG sanitizer (runs at admin upload — BFF concern)
- Audit_log + judge_corrections + suppressed_citation tables (our DB)
- Case CRUD, document parsing (BFF concerns)
- LangSmith tracing (now flows from LangGraph Cloud automatically)
- Citation provenance, suppression validation (graph-internal)

### 9.6 Deployment targets per component

| Component | Target | Why |
|---|---|---|
| React frontend | **Vercel** (or Netlify) | Static hosting; preview deploys per PR; cheap |
| FastAPI BFF | **DigitalOcean App Platform** (or fly.io / Railway) | Single Docker image; managed runtime; SGT region for latency; existing repo `Dockerfile` works |
| LangGraph runtime | **LangGraph Platform Cloud** | Managed by LangChain; `langgraph build` + Deployment SDK |
| Postgres (our app data) | **DigitalOcean Managed Postgres** (or Supabase) | Cases, audit_log, etc. |
| Postgres (graph state) | **Auto-provisioned by LangGraph Cloud** | Transparent; not our concern |
| Redis (SSE pub/sub) | **Upstash** (or DO Managed Redis) | Cheap, low-traffic |
| LangSmith tracing | **LangSmith Cloud** | Already in plan |

### 9.7 CI/CD changes

`.github/workflows/production-deploy.yml` extends:
- `langgraph build --tag verdictcouncil:${{ github.sha }}` — produces image artifact
- Push image to GCR (LangGraph Cloud's registry) or GHCR
- `python scripts/deploy/cloud_deploy.py` — invokes Deployment SDK to update the deployment
- Deploy frontend to Vercel via `vercel --prod`
- Deploy FastAPI BFF to chosen platform

### 9.8 Open question deferred to Sprint 5 implementation

Whether the FastAPI BFF talks to LangGraph Cloud over its HTTP API (current plan), OR whether we host the graph as **LangGraph Self-Hosted Standalone Server** in our own k8s (decoupled from LangChain SaaS but still using `langgraph build` artifacts). User picked "LangGraph and LangSmith deployment" — interpreted as Cloud; revisit if data-residency review later requires self-hosted.

---

## Phase 6 — Sprint 6+: E (separate product bet)

Deferred indefinitely. Per `deep-agents-core`, `deep-agents-orchestration`, `deep-agents-memory`. Requires Sprint 6.E.0 scoping spike before any implementation.

---

## Testing Strategy

### Unit Tests
- Middleware hooks in isolation
- Prompt registry resolver (cold, cache hit, judge correction → new commit)
- `@tool(response_format="content_and_artifact")` shape
- Research-join function: 4 subagent outputs → merged `ResearchOutput`
- Phase factory: same factory, different phases produce correct prompt + tool set + model tier

### Integration Tests
- SSE wire-format byte-equality vs frozen golden fixtures (Sprint 1)
- Replay-N-cases regression — N reduced from 10 to 5 since baseline cases go through fewer agent boundaries (Sprint 1)
- Trace propagation FastAPI → LangSmith → SSE (Sprint 2)
- Checkpointer: `get_state_history`, `update_state` with `Overwrite`, replay, fork (Sprint 2)
- `Send` parallel research dispatch + join (Sprint 1, expanded in Sprint 3)
- Citation provenance enforcement (Sprint 3)
- Interrupt → resume → status compatibility (Sprint 4)
- Idempotent gate-end nodes (Sprint 4)
- Cost rollup (Sprint 4)
- Phase-level rerun (4.A3) — rerun synthesis with extra_instructions affects only synthesis

### Manual
1. Submit fresh case → SSE timeline → click event → opens LangSmith trace → tool span
2. Fictitious citation → `suppressed_citation` with `reason=no_source_match`
3. Gate1 advance → gate2; rerun synthesis with extra_instructions → only synthesis re-runs; new LangSmith commit
4. Cancel mid-pipeline → halt ≤1 super-step
5. `/cost/summary` returns non-zero
6. Auditor catches a deliberately-injected impartiality issue

## Performance Considerations

- **Research phase parallelism preserved** — 4 subagents via `Send`. Roughly 4× research-phase wall time vs sequential. Net case duration similar to current 9-agent design.
- **OpenAI vector store latency** — unchanged.
- **`PostgresSaver`** — write amplification ≈ 1× per super-step; ~8 saver writes per case run (vs ~9 today).
- **LangSmith Prompts** — `lru_cache(maxsize=64)` on `get_prompt`; near 100% hit rate.
- **LangSmith tracing** — sampled at 100% in staging; configurable in prod.

## Migration Notes

- **Agent topology cutover (Sprint 1):** ships behind a runtime flag for one release? **No** — too much code to dual-maintain. Hard cut after Sprint 0 schema lock and replay-test green. `pre-architecture-cutover` git tag is the rollback anchor.
- **PostgresSaver cutover (Sprint 2):** maintenance window + `pause_intake` + migration driver + tagged rollback release.
- **LangSmith Prompts migration (Sprint 1):** idempotent push; second run no-op.
- **Audit schema (Sprint 4):** nullable column adds; old rows untouched.
- **Frontend SSE (Sprint 4):** additive `InterruptEvent` type; existing handlers keep working.

## References

- LangChain `create_agent` + `response_format=Schema` native structured output
- LangChain `@tool(response_format="content_and_artifact")` for citation provenance
- LangGraph `Send` for parallel fan-out (research subagents)
- LangSmith Prompts: `Client.push_prompt` / `pull_prompt` with commit versioning
- LangSmith Evaluations: `langsmith.evaluate(target, data, evaluators)`
- `langgraph-human-in-the-loop` skill — idempotency-on-resume
- `langgraph-persistence` skill — `Overwrite` for reducer fields under `update_state`

---

*End of plan. Companion task breakdown at `tasks-breakdown-2026-04-25-pipeline-rag-observability.md`.*
