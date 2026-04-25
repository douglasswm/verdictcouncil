# §5 Explainable and Responsible AI Practices

**For group report §5 — maps to IMDA Model AI Governance Framework v2 (2020)**

**Architecture revision:** rev 3 — 6-agent LangGraph topology. See `tasks/architecture-2026-04-25.md` (canonical) and `tasks/plan-2026-04-25-pipeline-rag-observability-overhaul.md` §§4–5 for the source of truth.

---

## 5.1 Governance Framework Alignment — IMDA Model AI Governance Framework

VerdictCouncil is designed around the four pillars of Singapore's **IMDA Model AI Governance Framework v2 (2020)**. Each pillar is addressed by concrete implementation decisions described below.

The rev 3 topology collapses the previous 9-agent pipeline into **6 agents** orchestrated as a LangGraph `StateGraph`:

1. `intake` — triage, parties, domain, complexity, route
2. `research-evidence` — forensic evidence analysis (parallel subagent)
3. `research-facts` — fact extraction + timeline (parallel subagent)
4. `research-witnesses` — credibility assessment (parallel subagent)
5. `research-law` — statute + precedent retrieval (parallel subagent)
6. `synthesis` — IRAC arguments + pre-hearing brief
7. `auditor` — independent fairness, citation, and completeness audit (**never receives tools**)

The 4 research subagents fan out in parallel via LangGraph `Send`. The `auditor` is the new **independent fairness control** — it runs on the completed state without any tool access, which structurally prevents it from pulling new evidence that could bias its audit.

---

### Pillar 1 — Internal Governance Structures and Measures

**Framework requirement:** Organizations should establish clear accountability structures, define human oversight responsibilities, and implement appropriate checks before deploying AI systems.

| Control | Implementation | Evidence |
|---|---|---|
| Defined accountability roles | Single role: `judge` with explicit RBAC via `require_role()` | `src/api/deps.py:92` |
| 4-gate HITL approval | LangGraph pauses at 4 review gates via `interrupt()`; judge must explicitly `advance` / `rerun` / `halt` / `send_back` — no autonomous pipeline completion. Legacy `awaiting_review_gate{1..4}` status preserved for SSE compatibility | `src/pipeline/graph/nodes/gate{1,2,3,4}_review_*.py` (plan task 4.A3.3–4) |
| Independent audit control | `auditor` agent replaces the prior governance peer agent. Runs a 5-phase audit (fairness, citation provenance, completeness, coherence, risk) on the completed state. **Receives no tools** — cannot fetch new evidence — enforcing structural independence from the research subagents | `src/pipeline/graph/agents/factory.py` — `make_phase_node("audit")` (plan task 1.A1.4) |
| Append-only audit trail | Audit middleware UPSERTs an `AuditEntry` on every phase transition, tool call, gate action, and suppressed citation; `APPEND_ONLY_FIELDS = {"audit_log"}` validation preserved | `src/shared/validation.py:45`; audit middleware (plan task 1.A1.4) |
| Trace substrate (NEW) | LangSmith trace per case run; one click from React gate panel → full trace → individual tool span. Replaces per-hop-only audit for end-to-end latency and token visibility | `src/pipeline/graph/runner.py` (plan task 2.C1.4) |
| Schema versioning | `pipeline_checkpoints.schema_version` gate rejects corrupt replays (`CURRENT_SCHEMA_VERSION = 2`). Migrates to `PostgresSaver` at cutover (plan task 2.A2.10) | `src/db/pipeline_state.py:42` |

---

### Pillar 2 — Determining the Level of Human Involvement in AI-Augmented Decision Making

**Framework requirement:** AI involvement should be calibrated to risk. High-stakes decisions require meaningful human oversight, not rubber-stamping.

VerdictCouncil treats AI as **advisory only**. No AI output is binding without a judge's recorded decision. The 4 gates implement meaningful human oversight over the 6-agent pipeline.

| Decision point | AI role | Human role | Code |
|---|---|---|---|
| Gate 1 — Intake review | `intake` produces parties, domain, complexity score, route | Judge reviews intake output; advance / re-run with instructions / halt | `nodes/gate1_review_intake.py` (plan task 4.A3.3) |
| Gate 2 — Research review | 4 parallel research subagents (evidence / facts / witnesses / law) build dossier | Judge reviews each tab; can re-run a single subagent or all 4; can dispute any extracted fact | `nodes/gate2_review_research.py`; tabbed dossier (plan task 4.C5b.2) |
| Gate 3 — Synthesis review | `synthesis` produces IRAC arguments + pre-hearing questions + uncertainty flags | Judge reviews; can edit a question, dispute an argument, or re-run with notes | `nodes/gate3_review_synthesis.py` |
| Gate 4 + decision | `auditor` produces fairness / citation / completeness report | Judge approves & finalizes (records `judicial_decision` with per-conclusion `ai_engagements` = agree/disagree + reasoning); or sends back to a specific phase; or halts | `nodes/gate4_review_audit.py`; `cases.judicial_decision` JSONB |
| Fact dispute | — | Judge marks any extracted fact as `disputed` with a reason; dispute flows into `extra_instructions` for re-run | `PATCH /cases/{id}/facts/{fid}/dispute` |
| What-If contestability | LangGraph fork: `update_state(past_config, ...)` + `invoke(None, fork_config)` on `PostgresSaver` history | Judge sees how analysis changes when evidence excluded or facts toggled; thread_id segregation prevents cross-case leakage | `services/whatif_controller/controller.py` (reimplemented on checkpoint primitives) |

**Resume payload contract (all gates):**

```json
{
  "action": "advance" | "rerun" | "halt" | "send_back",
  "notes": "free-text → extra_instructions",
  "field_corrections": {},
  "subagent": "evidence|facts|witnesses|law",
  "to_phase": "intake|research|synthesis"
}
```

A backend validator on `Command(resume=...)` rejects unknown actions before any state mutation.

**Risk calibration rationale:** Singapore lower-court cases (SCT + Traffic) involve legal rights and financial obligations. The system is explicitly designed so the AI is a structured reasoning aid, not a decision-maker. The judge's recorded decision (with reason) is the authoritative legal act.

---

### Pillar 3 — Operations Management

**Framework requirement:** AI systems should be monitored, tested, and their data inputs managed to maintain quality and safety over time.

| Control | Implementation | Evidence |
|---|---|---|
| Input sanitization | Two-layer injection defense at admin RAG ingest: regex L1 (9 compiled patterns, <1ms/page) + DeBERTa-v3 L2 via `llm-guard==0.3.16` (95.25% accuracy / 99.74% recall) | `src/shared/sanitization.py`; verified by plan task 1.A1.SEC1 |
| Strict output validation | Pydantic schemas with `extra="forbid"` per phase output, passed as `response_format` to LangChain `create_agent`; `ToolStrategy.handle_errors=True` retries on validation failure. Unauthorized keys raise `ValidationError` at parse time — the schema itself is the authoritative field-ownership contract (superseding the rev 2 allowlist, see footnote) | Per-phase schemas in `src/pipeline/agent_schemas.py` (plan task 1.A1.SEC3) |
| Pipeline resilience | LangGraph `RetryPolicy` on each node + semantic-incompleteness routers + PAIR circuit-breaker. Parallel research fan-out via `Send` replaces the Redis Lua barrier | `src/pipeline/graph/builder.py`; `src/shared/circuit_breaker.py:42` |
| External API resilience | PAIR API wrapped with rate-limit (2 req/s), Redis cache (TTL 86400s), circuit breaker (threshold=3, recovery=60s), vector-store fallback tagged `source: "vector_store_fallback"` | `src/tools/search_precedents.py`; `src/tools/vector_store_fallback.py:95` |
| Checkpoint replay | `PostgresSaver` enables `get_state_history`, `update_state`, `invoke(None, past_config)`; What-If reuses these primitives directly — no separate snapshot path | Post-cutover (plan task 2.A2.10); pre-cutover `src/db/pipeline_state.py` |
| Distributed LLM tracing | **Closed gap** — LangSmith natively traces every LangChain agent and tool call; `trace_id` flows FastAPI → LangGraph config metadata → LangSmith → SSE → React → Sentry via W3C `traceparent` header | `src/pipeline/observability.py` (plan task 2.C1.4) |
| Dependency CVE scanning | `pip-audit` runs in CI on every push (advisory; tracked as a gap to make blocking) | `.github/workflows/ci.yml` — `security` job |
| Adversarial injection tests | 10 guardrail unit tests (OpenAI ChatML, Llama `<<SYS>>`, long-form override, null bytes, markdown system strip, forensic-log `method` field) — preserved verbatim | `tests/unit/test_guardrails_activation.py` (5); `tests/unit/test_guardrails_adversarial.py` (5); verified by plan task 1.A1.SEC2 |

---

### Pillar 4 — Stakeholder Interaction and Communication

**Framework requirement:** Affected parties should be able to understand AI-assisted decisions and have meaningful recourse.

| Control | Implementation | Evidence |
|---|---|---|
| Explainable deliberation | `synthesis` agent's IRAC structure cites which research subagent's facts/evidence each step uses; inline `supporting_sources: list[str]` on every argument references `source_id` of the originating research output | Phase prompt `synthesis` in LangSmith prompt registry (plan task 1.C3a) |
| Citation provenance (NEW) | Every citation in `legal_rules` / `precedents` carries `supporting_sources: list[str]` referencing a `source_id`. Unmatched citations are not silently dropped — they are recorded in the `suppressed_citation` table with a reason ENUM (`no_source_match`, `low_similarity`, `retraction_detected`, ...) | `supporting_sources` field on agent output schemas; `suppressed_citation` table from migration 0025 (plan task 4.C4.1) |
| Fairness audit disclosure | `auditor.fairness_check.issues_found[]` visible in case dossier and surfaced at the Gate 4 review screen before the judge records a decision | Phase prompt `audit` in LangSmith prompt registry |
| Verdict alternatives | `synthesis.uncertainty_flags` lists alternative outcomes with confidence scores; `auditor` independently flags imbalance | Schema in `src/pipeline/agent_schemas.py` |
| PAIR API source disclosure | When precedent fallback is used, results are tagged `source: "vector_store_fallback"` so judges know which legal sources were consulted | `src/tools/vector_store_fallback.py:95` |
| Legal citation integrity | `research-law` prompt forbids unsupported citations; a post-hoc `output_validator.py` (plan task 3.B.5) moves unmatched citations into `suppressed_citation` rather than allowing them to flow to synthesis | Phase prompt `research-law` |
| Judge dossier | Gate 2 review screen renders all 4 research subagent outputs in a tabbed view; Gate 3 shows synthesis + inline citation tooltips; Gate 4 shows auditor findings alongside the full synthesis | `<GateReviewPanel>` shared component (plan task 4.C5b.1) |
| Decision audit | All judge decisions (approve / modify / send-back / reject + reason) permanently recorded with timestamp; per-conclusion `ai_engagements` stored as JSONB on `cases.judicial_decision` | `src/api/routes/decisions.py` |
| Trace link | Every gate review screen shows a "View LangSmith trace" link; one click from the judge's UI to the full LangSmith trace for that case run | Frontend Sentry → LangSmith link (plan task 4.C5) |

---

## 5.2 Fairness and Bias Mitigation

### Structural controls

1. **Independent auditor as fairness control** — The `auditor` agent performs Phase 1 bias checking before producing any approval recommendation. It is structurally isolated: it receives the completed case state but **no tools** — it cannot fetch new evidence, search precedents, or otherwise reach outside the record. This separation prevents the auditor from rationalising around findings it doesn't like.

2. **Aggressive false-positive tolerance** — The auditor's system prompt instructs: *"Be AGGRESSIVE in flagging bias. False positives are acceptable — it is better to escalate unnecessarily than to issue a biased verdict."* This is a deliberate design choice preserved from the prior topology: in a judicial system, the cost of a biased verdict exceeds the cost of unnecessary human review. The prompt lives as a pinned commit in the LangSmith prompt registry (plan task 1.C3a).

3. **Fact dispute mechanism** — Any judge can flag any AI-extracted fact as disputed at Gate 2. This prevents the pipeline from building downstream synthesis on unchallenged AI inferences; the dispute enters `extra_instructions` for a research re-run.

4. **No direct demographic input** — Agents receive document text and structured case metadata. No demographic fields (race, religion, nationality) are included in `CaseState`. This is a structural exclusion: any bias that enters must come from document content, which the auditor is specifically tasked to detect.

### Known limitations

- No automated demographic bias eval set exists yet. The current eval suite uses 3 domain-specific gold fixtures but does not rotate demographic attributes to measure differential treatment. Gap tracked; remediation is eligible for the LangSmith evaluator extension (plan task 3.D1) once labelled data exists.
- The fairness audit is LLM-based (`gpt-5` family) — it can itself reflect training-data biases. Mitigation: `ESCALATE_HUMAN` output means the judge reviews flagged cases; the AI does not self-clear.

---

## 5.3 Explainability Architecture

### What is explained, and where

| Output | Explanation provided | Consumer |
|---|---|---|
| Evidence analysis | Contradiction / corroboration reasoning per evidence pair; `supporting_sources` per finding | Judge dossier (Gate 2) |
| Fact timeline | Sourced chronological timeline; disputed vs. agreed status per fact | Judge dossier (Gate 2) |
| Witness credibility | Credibility score 0–100 with generated judicial questions | Judge dossier (Gate 2) |
| Legal precedents | Verbatim statutory text + PAIR / vector-store source attribution; suppressed citations surfaced with reason | Judge dossier (Gate 2) |
| IRAC arguments | Balanced prosecution/defence arguments with inline `supporting_sources` | Judge dossier (Gate 3) |
| Uncertainty flags | Alternative outcomes with confidence weights | Judge dossier (Gate 3) |
| Audit report | Fairness, citation provenance, completeness, coherence, risk findings | Judge dossier (Gate 4) |
| Audit trail (semantic) | Per-phase inputs, outputs, gate actions, suppressed citations, judge corrections, `trace_id` / `span_id` | Admin / senior-judge audit view |
| Audit trail (machine) | LangSmith trace: prompt, completion, model, token usage, latency per agent / tool call | Developer + senior-judge observability |

### Explainability completeness (rev 3)

Unlike the prior mesh architecture, every tool call is now first-class in LangSmith (`gpt-5` and `gpt-5-mini` agent calls are auto-traced, tool spans are auto-captured). The two complementary axes — **judicial workflow** (PostgreSQL `audit_log`) and **machine performance** (LangSmith) — are reconciled by the shared `trace_id` column added to `audit_log` in plan task 4.C4.1.

---

## 5.4 Responsible AI in Development Practices

| Practice | Implementation |
|---|---|
| Unified runner (no test/prod split) | Single `GraphPipelineRunner` built on LangGraph `StateGraph` for both in-process tests and production. Same middleware, same schemas, same audit trail — the prior test/prod divergence is eliminated. |
| Prompt registry + version pinning | All 7 phase prompts (`intake`, `research-evidence`, `research-facts`, `research-witnesses`, `research-law`, `synthesis`, `audit`) live as versioned commits in LangSmith Prompts; each agent run records the commit hash (plan task 1.C3a). |
| Injection testing in CI | 10 adversarial guardrail unit tests assert known injection patterns are blocked and audited. Runs on every CI push. |
| LangSmith evaluation gate | CI `eval` job runs LangSmith evaluators on PRs touching `pipeline/`, `prompts/`, or `tools/`; a >5% regression on any scorer fails the build (plan task 4.D3.1). |
| No hardcoded credentials | All secrets (API keys, DB credentials, JWT secret, `LANGSMITH_API_KEY`) are environment variables; a startup warning fires if `JWT_SECRET` is the default value. |
| Non-root container | Dockerfile runs as `vcagent` user. |
| Static security analysis | `bandit` Python SAST tool runs in CI on every push (BLOCKING at `-ll`). |
| Dependency auditing | `pip-audit` checks for known CVEs in all installed packages on every CI push (advisory). |

---

## 5.5 Citation Provenance (Sprint 4 migration 0025)

Citation integrity is treated as a first-class data-model concern under rev 3, not a prompt-time instruction:

- **`supporting_sources: list[str]`** — every agent output that produces a citation (evidence findings, legal rules, precedents, IRAC arguments) carries a `supporting_sources` field referencing `source_id` values of the documents / tool results that substantiate the claim. The Pydantic schema (`extra="forbid"`) rejects outputs that omit this field.
- **`suppressed_citation` table** — introduced in migration `0025` (plan task 4.C4.1). Rows are phase-keyed (`intake` / `research-*` / `synthesis` / `audit`) and carry a reason ENUM: `no_source_match`, `low_similarity`, `retraction_detected`, `fabricated_citation`, `duplicate_of_suppressed`. Populated by `output_validator.py` (plan task 3.B.5) during post-hoc citation matching.
- **Trace linkage** — every suppressed-citation row carries `trace_id` + `span_id`, so a senior judge auditing a suppressed citation can one-click to the LangSmith trace where it was produced.
- **Surfacing to judge** — the Gate 4 review screen renders a "Suppressed citations" panel so the judge can see what the auditor filtered before approving.

This replaces the prior reliance on a system-prompt instruction that *"only verbatim statutory text from tool results is used"* — rev 3 enforces it at the schema and storage layer.

---

## Archived terminology (historical reference only)

The following identifiers appeared in the rev 2 topology and are retained here only to aid reviewers comparing older group-report drafts:

- `MeshPipelineRunner` — SAM / Solace distributed runner. Replaced by `GraphPipelineRunner` on LangGraph. No longer referenced in rev 3 source.
- `governance-verdict` (9-agent / 4-gate peer-agent language) — replaced by the independent `auditor` (see §5.1 Pillar 1).
- SAM / Solace PubSub+ — removed from the deployment topology.
- MLflow — replaced by LangSmith for tracing, prompt registry, and evaluations.
- `FIELD_OWNERSHIP` allowlist — replaced by Pydantic `extra="forbid"` schemas per phase.
