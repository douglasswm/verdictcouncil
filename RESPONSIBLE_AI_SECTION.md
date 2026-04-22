# §5 Explainable and Responsible AI Practices

**For group report §5 — maps to IMDA Model AI Governance Framework v2 (2020)**

---

## 5.1 Governance Framework Alignment — IMDA Model AI Governance Framework

VerdictCouncil is designed around the four pillars of Singapore's **IMDA Model AI Governance Framework v2 (2020)**. Each pillar is addressed by concrete implementation decisions described below.

---

### Pillar 1 — Internal Governance Structures and Measures

**Framework requirement:** Organizations should establish clear accountability structures, define human oversight responsibilities, and implement appropriate checks before deploying AI systems.

| Control | Implementation | Evidence |
|---|---|---|
| Defined accountability roles | Single role: `judge` with explicit RBAC via `require_role()` | `src/api/deps.py:92` |
| 4-gate HITL approval | Pipeline pauses at 4 review gates; judge must explicitly advance or re-run each gate — no autonomous pipeline completion | `src/pipeline/runner.py:41-46` (`GATE_AGENTS`); `src/api/routes/cases.py` (`/gates/{gate}/advance`) |
| Governance advisory gate | `hearing-governance` + `GovernanceHaltHook` logs critical fairness findings as uncertainty flags visible to judge; does NOT halt | `src/pipeline/hooks.py` — `GovernanceHaltHook` |
| Append-only audit trail | Every agent action, guardrail decision, and gate transition is appended to `CaseState.audit_log` and persisted to PostgreSQL | `src/shared/validation.py:25` (`APPEND_ONLY_FIELDS`); `src/models/audit.py:17-38` |
| Schema versioning | `pipeline_checkpoints` table includes a schema version gate to prevent corrupt replays | `src/db/pipeline_state.py:39` |

---

### Pillar 2 — Determining the Level of Human Involvement in AI-Augmented Decision Making

**Framework requirement:** AI involvement should be calibrated to risk. High-stakes decisions require meaningful human oversight, not rubber-stamping.

VerdictCouncil treats AI as **advisory only**. No AI output is binding without a judge's recorded decision.

| Decision point | AI role | Human role | Code |
|---|---|---|---|
| Gate 1 review | `case-processing` + `complexity-routing` produce domain classification | Judge reviews intake output; approves, re-runs with instructions, or overrides | `POST /cases/{id}/gates/gate1/advance` |
| Gate 2 review | `evidence-analysis`, `fact-reconstruction`, `witness-analysis`, `legal-knowledge` build dossier | Judge reviews each artifact tab; disputes facts if needed | `POST /cases/{id}/gates/gate2/advance` |
| Gate 3 review | `argument-construction` + `hearing-analysis` synthesise reasoning chain with fairness flags | Judge reviews arguments and uncertainty flags in dossier | `POST /cases/{id}/gates/gate3/advance` |
| Gate 4 + decision | `hearing-governance` produces final hearing analysis | Judge must record `judicial_decision` with per-conclusion `ai_engagements` (agree/disagree + reasoning); this artifact is the §5 HITL proof | `POST /cases/{id}/decision`; `cases.judicial_decision` JSONB |
| Fact dispute | — | Judge marks any extracted fact as `disputed` with a reason | `PATCH /cases/{id}/facts/{fid}/dispute` |
| What-If contestability | `WhatIfController` re-runs pipeline from modified assumptions | Judge sees how analysis changes when evidence is excluded or facts are toggled | `src/services/whatif_controller/controller.py` |

**Risk calibration rationale:** Singapore lower-court cases (SCT + Traffic) involve legal rights and financial obligations. The system is explicitly designed so the AI is a structured reasoning aid, not a decision-maker. The judge's recorded decision (with reason) is the authoritative legal act.

---

### Pillar 3 — Operations Management

**Framework requirement:** AI systems should be monitored, tested, and their data inputs managed to maintain quality and safety over time.

| Control | Implementation | Evidence |
|---|---|---|
| Input sanitization | Two-layer injection defense: regex (known ChatML/Llama/system tokens) + LLM classifier for ambiguous cases | `src/shared/sanitization.py:4-42`; `src/pipeline/guardrails.py:29-96` |
| Output integrity check | `governance-verdict` output validated for confidence range, required fields, and fairness audit presence | `src/pipeline/guardrails.py:99-129` |
| Field ownership enforcement | Each agent may only write its declared fields; unauthorized writes are detected and stripped before state is persisted | `src/shared/validation.py:4-22`; enforced in both `runner.py` and `mesh_runner.py` |
| Pipeline resilience | Redis Lua atomic barrier for L2 parallel fan-out; 120s timeout with cleanup; stuck-case watchdog CronJob | `src/services/layer2_aggregator/aggregator.py:29-53, 171-220`; `k8s/base/kustomization.yaml` |
| External API resilience | PAIR API wrapped with rate-limit (2 req/s), Redis cache (TTL 86400s), circuit breaker (threshold=3, recovery=60s), vector-store fallback | `src/tools/search_precedents.py`; `src/shared/circuit_breaker.py` |
| Checkpoint replay | Full `CaseState` JSONB snapshot written to `pipeline_checkpoints` after every agent hop; enables What-If replay without reprocessing from scratch | `src/db/pipeline_state.py`; `src/pipeline/mesh_runner.py:612-632` |
| Dependency CVE scanning | `pip-audit` runs in CI on every push (advisory mode — tracked as a gap to make blocking) | `.github/workflows/ci.yml` — `security` job |

**Known gap:** Distributed LLM call tracing (MLflow/OpenTelemetry) is not yet wired in source code. The per-agent audit log provides individual-hop traceability; end-to-end latency and token-usage trends are not yet aggregated. Remediation: `mlflow.openai.autolog()` in `runner.py` and `mesh_runner.py` (~1 hour of work).

---

### Pillar 4 — Stakeholder Interaction and Communication

**Framework requirement:** Affected parties should be able to understand AI-assisted decisions and have meaningful recourse.

| Control | Implementation | Evidence |
|---|---|---|
| Explainable deliberation | `deliberation` agent produces an **8-step reasoning chain** where every step cites which upstream agent and evidence item it draws from | `configs/agents/deliberation.yaml` — system prompt requires step-by-step chain with agent+evidence citations |
| Fairness audit disclosure | `governance-verdict` Phase 1 output includes `fairness_check.issues_found[]` listing any bias concerns; visible in case dossier | `configs/agents/governance-verdict.yaml:35-52` |
| Verdict alternatives | Recommendation includes alternative outcomes and their confidence scores, not just a single answer | `governance-verdict.yaml:59-68` |
| PAIR API source disclosure | When precedent fallback is used, results are tagged `source: "vector_store_fallback"` so judges know which legal sources were used | `src/tools/vector_store_fallback.py` — `source` field |
| Legal citation integrity | `legal-knowledge` system prompt explicitly forbids hallucinated citations; only verbatim statutory text from tool results is used | `configs/agents/legal-knowledge.yaml` — tool-grounded citation instruction |
| Judge dossier | Full deliberation trace, evidence analysis, fact timeline, witness credibility, and precedents compiled into judge-facing dossier | `VerdictCouncil_Frontend/src/components/CaseDossier.jsx` |
| Decision audit | All judge decisions (accept/modify/reject + reason) permanently recorded with timestamp | `src/api/routes/decisions.py` |

---

## 5.2 Fairness and Bias Mitigation

### Structural controls

1. **Mandatory fairness audit** — The `governance-verdict` agent performs Phase 1 bias checking before producing any verdict recommendation. The system prompt instructs it to check for: balance between parties, unsupported claims, logical fallacies, demographic bias, evidence completeness, and precedent cherry-picking.

2. **Aggressive false-positive tolerance** — The YAML instruction reads: *"Be AGGRESSIVE in flagging bias. False positives are acceptable — it is better to escalate unnecessarily than to issue a biased verdict."* (`governance-verdict.yaml:52`). This is a deliberate design choice: in a judicial system, the cost of a biased verdict exceeds the cost of unnecessary human review.

3. **Fact dispute mechanism** — Any judge can flag any AI-extracted fact as disputed. This prevents the pipeline from building downstream reasoning on unchallenged AI inferences.

4. **No direct demographic input** — Agents receive document text and structured case metadata. No demographic fields (race, religion, nationality) are included in `CaseState`. This is a structural exclusion: bias that enters must come from document content, which the governance-verdict agent is specifically tasked to detect.

### Known limitations

- No automated demographic bias eval set exists yet. The current eval suite (`tests/eval/`) uses 3 domain-specific gold fixtures but does not rotate demographic attributes to measure differential treatment.
- The fairness audit is LLM-based (Frontier model) — it can itself reflect training data biases. Mitigation: ESCALATE_HUMAN output means human judge reviews flagged cases; the AI does not self-clear.

---

## 5.3 Explainability Architecture

### What is explained, and where

| Output | Explanation provided | Consumer |
|---|---|---|
| Evidence analysis | Contradiction/corroboration reasoning per evidence pair | Judge dossier |
| Fact timeline | Sourced chronological timeline; disputed vs. agreed status per fact | Judge dossier |
| Witness credibility | Credibility score 0–100 with generated judicial questions | Judge dossier |
| Legal precedents | Verbatim statutory text + PAIR API source attribution | Judge dossier |
| Arguments | Balanced prosecution/defence arguments with confidence weights | Judge dossier |
| Deliberation | 8-step reasoning chain citing agents and evidence | Judge dossier |
| Verdict | Recommended outcome + confidence score + alternatives + fairness audit | Judge dossier + decision workflow |
| Audit trail | Per-agent inputs, outputs, model used, token counts, tool calls | Admin/senior judge audit view |

### Explainability limitations

- Tool calls from SAM-based agents are not yet propagated back to the orchestrator's audit log (`mesh_runner.py:552-554` sets `tool_calls=None` for mesh-path agents). The tool call record exists inside each SAM agent process but is not surfaced in the PostgreSQL audit trail. This is flagged in RESEARCH_DEEP_DIVE.md §5.2 and is tracked for remediation.

---

## 5.4 Responsible AI in Development Practices

| Practice | Implementation |
|---|---|
| Separation of test and production runners | `PipelineRunner` (in-process) for unit tests; `MeshPipelineRunner` (distributed SAM) for production. Same hooks, same field ownership, same audit — only the transport differs. |
| Injection testing in CI | `tests/unit/test_guardrails_activation.py` tests known injection patterns and asserts they are blocked and audited. Runs on every CI push. |
| No hardcoded credentials | All secrets (API keys, DB credentials, JWT secret) are environment variables; a startup warning fires if `JWT_SECRET` is the default value. |
| Non-root container | Dockerfile runs as `vcagent` user (`Dockerfile:23`). |
| Static security analysis | `bandit` Python SAST tool runs in CI on every push (advisory; tracked gap to make blocking). |
| Dependency auditing | `pip-audit` checks for known CVEs in all installed packages on every CI push. |
