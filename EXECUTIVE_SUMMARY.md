# §1 Executive Summary

**For group report §1**

---

## Project Objective and Scope

VerdictCouncil is an AI-assisted hearing preparation platform designed for Singapore's lower courts, specifically the Small Claims Tribunals (SCT) and Traffic Court. It addresses a concrete operational problem: judges in high-volume case environments must review lengthy documents, extract relevant facts, assess evidence credibility, apply legal precedents, and understand the key issues before a hearing — tasks that are time-consuming, repetitive, and subject to inconsistency across different judges.

The platform does **not** replace judicial decision-making and does **not** produce verdict recommendations. As a core Responsible AI principle, the system never records, recommends, or influences the judicial outcome. It acts as a structured hearing preparation aid: nine specialised AI agents process each case through a fixed pipeline, producing an explainable dossier of evidence analysis, reconstructed timelines, witness credibility assessments, applicable precedents, balanced arguments, and a deliberation chain. The judge reviews this material independently before the hearing and decides at the hearing — the AI output is preparation support only.

**Scope boundaries:**
- Domain: Singapore lower courts — Small Claims Tribunal (SCT) and Traffic Court
- Language/jurisdiction: English; Singapore Statutes Online and PAIR (Public Access to Information Resources) API precedents
- Role: Hearing preparation tool for seated judges; not a public-facing chatbot or autonomous adjudicator
- Deployment: DigitalOcean Kubernetes (DOKS) with managed PostgreSQL and Redis

---

## Key Highlights

### 1. Nine-Agent Fixed-Topology Pipeline with 4-Gate HITL Review

The system implements a sequential 9-agent pipeline grouped into four review gates. The judge approves, rejects, or re-runs any individual agent between gates — the pipeline never advances without explicit judicial approval.

| Gate | Agents | Judge action available |
|---|---|---|
| Gate 1 — Intake | case-processing, complexity-routing | Approve or re-run agent with custom instructions |
| Gate 2 — Dossier | evidence-analysis, fact-reconstruction, witness-analysis, legal-knowledge | Approve or re-run agent |
| Gate 3 — Arguments | argument-construction, hearing-analysis | Approve or re-run agent |
| Gate 4 — Verdict | hearing-governance | Record judicial decision before proceeding |

The pipeline runs as an in-process LangGraph `StateGraph` inside the `arq-worker` Deployment (`src/pipeline/graph/builder.py`). Each agent node writes a structured audit entry via `append_audit_entry()` — providing a complete per-gate, per-agent trace for §7 MLSecOps. State persists to the Postgres `langgraph_checkpoint` table after every node, keyed by `thread_id` (= case `run_id`), so a paused run resumes cleanly across worker restarts.

The same image deploys as two K8s Deployments (`api-service` + `arq-worker`) on DOKS — the rubric rewards a Kubernetes deploy. An earlier draft of this architecture proposed nine per-agent containers connected by Solace Agent Mesh (SAM) A2A pub/sub; that topology was decommissioned in the responsible-AI refactor.

### 2. Contestable Judgment Mode (What-If Analysis)

Judges can challenge AI reasoning by creating what-if scenarios: toggle an evidence item as inadmissible, adjust a witness credibility score, or change the legal interpretation applied. The system deep-clones the case state, applies the modification, and re-runs the pipeline from the earliest affected agent — returning a revised analysis for comparison. This makes AI reasoning transparent and falsifiable, not just a black box output.

### 3. Built-in Explainability

The deliberation agent produces an 8-step reasoning chain where every step cites which upstream agent and which evidence item it draws from. The hearing-governance agent discloses its fairness audit findings — including any bias concerns — before completing its analysis. Judges see the full reasoning with confidence scores across different legal interpretations, supporting informed preparation rather than directing an outcome.

### 4. Two-Layer Security Architecture

All document uploads are processed through two injection-defence layers before reaching any LLM: a regex scanner strips known ChatML/Llama/system-prompt tokens, and an LLM classifier (lightweight model) catches subtler manipulation attempts. Field ownership enforcement prevents any agent from overwriting fields it does not own — protecting the integrity of the shared case state.

### 5. Human-Centred Controls

Every RBAC-controlled action is recorded in an append-only audit log persisted to PostgreSQL. Judges can dispute individual facts. The judge records an explicit `judicial_decision` with per-conclusion agree/disagree engagements — this `ai_engagements` artifact is the primary §5 Responsible AI proof that every AI conclusion was reviewed by a human before the decision was finalised.

---

## Constraints and Assumptions

| Constraint | Implication |
|---|---|
| AI is hearing preparation only | All pipeline outputs are analysis for hearing preparation; the judge decides independently at the hearing — the system never records or recommends a verdict |
| Singapore jurisdiction | Legal knowledge restricted to Singapore Statutes Online and PAIR API precedents; no cross-jurisdiction generalisation |
| English-only documents | Document parsing and LLM prompts assume English; non-English documents may produce degraded output |
| OpenAI API dependency | All agents use OpenAI GPT-family models; API unavailability halts pipeline execution |
| PAIR API availability | Legal precedent search degrades to a curated vector-store fallback when PAIR is unavailable; results are flagged accordingly |
| Kubernetes deployment | Local development uses `docker-compose.infra.yml` (Postgres + Redis) + honcho; production deploys two K8s Deployments (`api-service`, `arq-worker`) to DOKS, with managed Postgres + Redis in the same VPC. Frontend is a static site on DO App Platform |
| AI observability gap | Distributed LLM call tracing (MLflow/OpenTelemetry) is not yet wired into the production path; per-agent audit logs provide individual-hop traceability but not cross-agent latency aggregation |
| No demographic eval set | The fairness audit is LLM-based; no automated test suite exists that systematically rotates demographic attributes to measure differential AI treatment |
