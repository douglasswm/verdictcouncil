# §1 Executive Summary

**For group report §1**

---

## Project Objective and Scope

VerdictCouncil is an AI-assisted judicial decision-support platform designed for Singapore's lower courts, specifically the Small Claims Tribunals (SCT) and Traffic Court. It addresses a concrete operational problem: judges in high-volume case environments must review lengthy documents, extract relevant facts, assess evidence credibility, apply legal precedents, and produce a reasoned recommendation — tasks that are time-consuming, repetitive, and subject to inconsistency across different judges.

The platform does **not** replace judicial decision-making. It acts as a structured reasoning aid: nine specialised AI agents process each case through a fixed pipeline, producing an explainable dossier of evidence analysis, reconstructed timelines, witness credibility assessments, applicable precedents, balanced arguments, and a deliberation chain. The judge then reviews the AI output, can challenge any part of it, and records a binding accept/modify/reject decision. The AI recommendation is never binding without the judge's recorded act.

**Scope boundaries:**
- Domain: Singapore lower courts — Small Claims Tribunal (SCT) and Traffic Court
- Language/jurisdiction: English; Singapore Statutes Online and PAIR (Public Access to Information Resources) API precedents
- Role: Decision support tool for seated judges; not a public-facing chatbot or autonomous adjudicator
- Deployment: DigitalOcean Kubernetes (DOKS) with managed PostgreSQL and Redis

---

## Key Highlights

### 1. Nine-Agent Fixed-Topology Pipeline

The system implements a three-layer Orchestrator-Worker pipeline:

- **Layer 1 (Sequential):** Case processing and complexity routing. If a case is too complex for AI-assisted review, the pipeline halts and routes directly to a senior judge. No AI analysis is issued.
- **Layer 2 (Parallel fan-out):** Evidence analysis, fact reconstruction, and witness analysis run concurrently. A Redis Lua atomic barrier ensures all three must complete before Layer 3 begins — eliminating race conditions in distributed execution.
- **Layer 3 (Sequential):** Legal knowledge retrieval (using Singapore's PAIR API with circuit-breaker resilience), argument construction, deliberation, and governance verdict. The governance-verdict agent performs a mandatory Phase 1 fairness audit before producing any recommendation. If critical bias is detected, the pipeline halts and escalates to human review.

Each agent runs as an independent process in Kubernetes, connected by Solace Agent Mesh (SAM) A2A pub/sub messaging. This enables independent deployment, independent scaling, and resilience — a failure in one agent does not bring down the others.

### 2. Contestable Judgment Mode (What-If Analysis)

Judges can challenge AI reasoning by creating what-if scenarios: toggle an evidence item as inadmissible, adjust a witness credibility score, or change the legal interpretation applied. The system deep-clones the case state, applies the modification, and re-runs the pipeline from the earliest affected agent — returning a new verdict for comparison. This makes AI reasoning transparent and falsifiable, not just a black box recommendation.

### 3. Built-in Explainability

The deliberation agent produces an 8-step reasoning chain where every step cites which upstream agent and which evidence item it draws from. The governance-verdict agent discloses its fairness audit findings — including any bias concerns — before producing its recommendation. Judges see alternative outcomes with confidence scores, not a single binary answer.

### 4. Two-Layer Security Architecture

All document uploads are processed through two injection-defence layers before reaching any LLM: a regex scanner strips known ChatML/Llama/system-prompt tokens, and an LLM classifier (lightweight model) catches subtler manipulation attempts. Field ownership enforcement prevents any agent from overwriting fields it does not own — protecting the integrity of the shared case state.

### 5. Human-Centred Controls

Every RBAC-controlled action is recorded in an append-only audit log persisted to PostgreSQL. Judges can dispute individual facts. A two-person rule prevents any judge from approving their own amendment referrals. The verdict is always a judge's recorded decision, never the AI's unilateral output.

---

## Constraints and Assumptions

| Constraint | Implication |
|---|---|
| AI is advisory only | All pipeline outputs are recommendations; judges must record an explicit accept/modify/reject decision |
| Singapore jurisdiction | Legal knowledge restricted to Singapore Statutes Online and PAIR API precedents; no cross-jurisdiction generalisation |
| English-only documents | Document parsing and LLM prompts assume English; non-English documents may produce degraded output |
| OpenAI API dependency | All nine agents use OpenAI GPT-family models; API unavailability halts pipeline execution |
| PAIR API availability | Legal precedent search degrades to a curated vector-store fallback when PAIR is unavailable; results are flagged accordingly |
| Kubernetes deployment | Local development uses a single-image Docker setup; the multi-agent distributed topology requires a running Kubernetes cluster and Solace broker |
| AI observability gap | Distributed LLM call tracing (MLflow/OpenTelemetry) is not yet wired into the production path; per-agent audit logs provide individual-hop traceability but not cross-agent latency aggregation |
| No demographic eval set | The fairness audit is LLM-based; no automated test suite exists that systematically rotates demographic attributes to measure differential AI treatment |
