# §7 MLSecOps / LLMSecOps Pipeline

## 7.1 Overview

VerdictCouncil's MLSecOps pipeline enforces quality, security, and observability gates on every commit. The pipeline treats LLM-specific risks as first-class citizens: adversarial injection tests run as unit tests in CI, static security analysis is hard-blocking, a LangSmith-backed evaluation gate catches prompt/pipeline regressions on every PR that touches `pipeline/`, `prompts/`, or `tools/`, and every production pipeline execution emits structured traces to LangSmith.

---

## 7.2 CI/CD Pipeline Structure

```
Push / PR
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Job: lint (ubuntu-latest)                                          │
│  • ruff check src/ tests/        — style + import hygiene          │
│  • ruff format --check src/ tests/ — consistent formatting         │
└────────────────────────┬────────────────────────────────────────────┘
                         │
           ┌─────────────┼──────────────┬────────────────────────────┐
           ▼             ▼              ▼                            ▼
  ┌──────────────┐ ┌──────────────┐ ┌───────────────────────────────┐ ┌──────────────┐
  │ Job: test    │ │ Job: openapi │ │ Job: security                 │ │ Job: docker  │
  │ pytest       │ │ snapshot     │ │ pip-audit  (advisory)         │ │ build + push │
  │ 10 adv.      │ │ diff check   │ │ bandit -ll (BLOCKING)         │ │ false; Trivy │
  │ guardrail    │ │              │ │ semgrep (advisory)            │ │ image scan   │
  │ tests; --cov │ │              │ │ 0 medium/high issues          │ │ → SARIF      │
  │ -fail-under  │ │              │ │                               │ │ (advisory)   │
  │ =100         │ │              │ │                               │ │ needs: test  │
  └──────┬───────┘ └──────────────┘ └───────────────────────────────┘ └──────────────┘
         │
         ▼
  ┌──────────────────────────────────────────────┐
  │ Job: eval (NEW — rev 3, Sprint 4.D3.1)       │
  │ needs: test                                  │
  │ Trigger: PRs touching pipeline/, prompts/,   │
  │          tools/                              │
  │ Runs: langsmith.evaluate() against the 15    │
  │       golden cases authored in Sprint 0.11b  │
  │ Gate : any scorer drops >5% vs the baseline  │
  │        LangSmith experiment → FAIL           │
  │ Override: `eval/skip-regression` label +     │
  │           CODEOWNERS reviewer                │
  └──────────────────────────────────────────────┘
```

**File:** `.github/workflows/ci.yml` (plus `.github/workflows/eval.yml` for the eval gate — 4.D3.1).

| Job | Trigger | Gate type | Blocks merge? |
|-----|---------|-----------|--------------|
| `lint` | every push | style | Yes |
| `test` | needs: lint | quality (coverage `--cov-fail-under=100`) + 10 adversarial guardrail tests | Yes |
| `property-tests` | needs: lint | Hypothesis property-based tests (`HYPOTHESIS_PROFILE=ci`) | Yes |
| `openapi` | needs: lint | contract drift | Yes |
| `sast` | needs: lint | `bandit -r src/` BLOCKING + `semgrep` (p/security-audit, p/owasp-top-ten) advisory → SARIF | Yes (`bandit`); advisory (`semgrep`) |
| `sca` | needs: lint | `pip-audit` + `safety` + `cyclonedx-bom` SBOM | advisory |
| `dast` | needs: lint | live FastAPI behind Postgres service, header check, contract tests | advisory |
| `load-tests` | needs: lint | Locust 30s smoke (5 users) | advisory |
| `docker` | needs: test | build integrity + **Trivy** image scan → SARIF (advisory) | Yes (build); advisory (Trivy) |
| **`eval`** | needs: test, PR-only, path-filtered (`src/pipeline/**`, `src/agents/**`, `tests/eval/**`, `**/prompts.py`, `src/tools/**`) | LangSmith `evaluate()` vs 15 golden cases; **>5% accuracy drop on any scorer → fail** | Yes |
| **`promptfoo-tests`** (separate workflow `promptfoo-tests-ci.yml`) | path-filtered + dispatch | per-phase prompt regression — deterministic JS asserts, llm-rubric groundedness, **cost/latency budgets**, baseline.json threshold gate | Yes |
| **`promptfoo-redteam`** (separate workflow `promptfoo-redteam-ci.yml`) | weekly cron + dispatch + on redteam-config changes | auto-generative red-team safety probes against the intake prompt (prompt injection, jailbreak, PII, hallucination, hijacking, harmful) | advisory |
| **`infra-bootstrap`** (separate workflow `infra-bootstrap.yml`) | `workflow_dispatch` only | one-off DOKS cluster + DOCR + Managed Postgres + Managed Valkey provisioning | n/a |

---

## 7.3 LLM-Specific Security Gates

### Adversarial Injection Testing in CI

Ten guardrail tests run as standard unit tests on every commit, covering both regex (L1) and LLM-classifier (L2) defences:

| File | Tests | What is asserted |
|------|-------|-----------------|
| `tests/unit/test_guardrails_activation.py` | 5 | OpenAI `<\|im_start\|>` delimiter blocked, `<system>` tag blocked, `InputGuardrailHook` sanitises + audits malicious description, benign text passes unchanged |
| `tests/unit/test_guardrails_adversarial.py` | 5 | LLM classifier blocks long-form override, classifier passes benign legal text, `<<SYS>>` Llama pattern caught by regex, null bytes + markdown system blocks stripped, `method` field present in result for forensic log |

These tests run with zero external API calls — the LLM layer is mocked. CI never touches the live OpenAI API.

### Static Security Analysis

```yaml
# .github/workflows/ci.yml — security job
- run: bandit -r src/ -ll      # medium and above severity, BLOCKING
```

Current findings: **0 medium, 0 high** issues. The only suppressed finding is `B104` (bind-all-interfaces on `fastapi_host: str = "0.0.0.0"`) — intentional for container networking, annotated `# nosec B104`.

### Dependency Vulnerability Scan

```yaml
- run: pip-audit
  continue-on-error: true      # advisory — third-party CVEs tracked but non-blocking
```

`pip-audit` scans the dependency tree on every CI run. Results are visible in the job log. Made advisory (not blocking) because third-party CVEs require investigation before suppression.

---

## 7.4 LangSmith Observability (LLM Tracing — rev 3)

Rev 3 replaces the in-house MLflow setup with **LangSmith** as the single tracing substrate. LangChain / LangGraph agents, tools, and retrievers are auto-instrumented; VerdictCouncil does not maintain a manual span helper (the prior `tool_span()` wrapper is removed in Sprint 2 task 2.C1.7).

### Architecture

```
FastAPI lifespan (src/api/app.py)
  └─ langsmith.Client() init              # opt-in via LANGSMITH_TRACING=true
       (no autolog call — LangChain hooks LangSmith automatically once the
        env var is set; the client is initialised at startup so SDK credentials
        are validated before the first request)

POST /cases  (FastAPI handler)
  └─ extract W3C `traceparent` header     # propagate trace_id end-to-end
       └─ GraphPipelineRunner.run(config={"metadata": {"trace_id": ..., "case_id": ..., "run_id": ..., "thread_id": ...}})
            └─ LangSmith experiment per case run (auto)
                 └─ per-phase span (auto — one per LangGraph node)
                      └─ per-tool span (auto — native LangSmith instrumentation)
                      └─ prompt commit hash on each LangChain agent run

SSE events  →  React  →  Sentry
  └─ backend_trace_id + backend_trace_url tagged on every frontend event
```

**Key design choices:**
- `langsmith.Client()` is initialised **only** in the FastAPI `lifespan` hook. No module-scope calls, so `pytest` collection and unit tests never touch the SaaS.
- Auto-tracing is driven by `LANGSMITH_TRACING=true` + `LANGSMITH_API_KEY` — LangChain's runtime hooks enable per-call spans for every agent, tool, and retriever without wrapper code.
- W3C `traceparent` propagation: FastAPI reads the inbound header (or mints one), stamps it onto `config["metadata"]["trace_id"]` for the LangGraph run, LangSmith records it as a searchable tag, the SSE event re-emits it, React forwards it into Sentry. One trace id joins the whole user journey.
- The client is **fail-open**: LangSmith vendor outage degrades observability but never breaks the pipeline (Risk R-18).

### What is traced per pipeline run

| Trace source | Data captured |
|---|---|
| LangSmith auto-tracing (LangChain hook) | Prompt, completion, model, token usage, latency per LangChain agent / tool call; per-tool spans are native — no manual helper |
| LangSmith metadata | `case_id`, `run_id`, `trace_id`, `thread_id`, LangSmith Prompts commit hash tagged on the parent run |
| W3C `traceparent` | FastAPI → LangGraph config metadata → LangSmith → SSE event → React → Sentry (single trace id across the stack) |
| `append_audit_entry()` (phase-keyed, post-4.C4.1) | Per-phase structured audit entries in `CaseState.audit_log` → persisted to PostgreSQL; gate transition events (`gate_advanced`, `gate_rerun_requested`, `suppressed_citation`) also appended; rows carry `trace_id` + `span_id` for LangSmith cross-link |

Two complementary axes preserved: **machine performance** (LangSmith — latency, cost, token usage) and **judicial workflow** (PostgreSQL `audit_log` — semantic gate decisions).

### LangSmith Configuration

Controlled via environment variables, with safe defaults:

```python
# src/shared/config.py
langsmith_tracing: bool = False                      # opt-in; off by default
langsmith_api_key: SecretStr | None = None
langsmith_project: str = "verdictcouncil-pipeline"
```

Set `LANGSMITH_TRACING=true` + `LANGSMITH_API_KEY=<...>` to activate tracing in any environment. The trace viewer is the hosted LangSmith dashboard — every gate review screen in the React UI renders a "View LangSmith trace" link built from the run's `trace_id`.

---

## 7.5 Audit Trail and Logging

### In-process audit log

Every agent action, tool call, guardrail event, and pipeline decision is appended to `CaseState.audit_log` — a list of `AuditEntry` records that travels with the case through the pipeline.

```python
# AuditEntry fields (src/shared/audit.py)
agent: str          # which agent wrote this entry
action: str         # event type (e.g. "input_injection_blocked")
input_payload: dict # what triggered the event
output_payload: dict # what was produced
timestamp: datetime  # UTC
```

The audit log is **append-only by convention** — no agent removes or overwrites prior entries. It is persisted to the database when `persist_case_results()` is called at pipeline completion.

### Structured logging

All application logging uses Python's standard `logging` module with structured key=value formatting. Log level is configurable via `settings.log_level`. In production containers, logs are written to stdout for collection by the container orchestrator.

---

## 7.6 Deployment Strategy

### Infrastructure

| Service | Container | Port | Purpose |
|---------|-----------|------|---------|
| FastAPI API | `verdictcouncil:latest` | 8001 | REST API + SSE pipeline events |
| arq worker | `verdictcouncil:latest` | — | LangGraph pipeline runner; drains the `pipeline_jobs` outbox (same image as API, different `command`/`args`) |
| Stuck-case watchdog | `verdictcouncil:latest` | — | CronJob (`*/5 * * * *`) — moves cases stuck > 30 min into `failed_retryable` |
| PostgreSQL 16 (DO Managed) | — | 5432 | Case records, audit entries, `PostgresSaver` checkpoints (replaces the prior custom checkpoint table) |
| Valkey 7 (DO Managed, Redis-compatible) | — | 6379 | SSE pub/sub, arq queue, PAIR precedent cache, PAIR rate-limit token bucket. Provisioned via `infra-bootstrap.yml` with `--engine valkey` |
| LangSmith (cloud) | — (SaaS) | HTTPS | Tracing, LangSmith Prompts (7 prompts), LangSmith Evaluations (CI eval gate). Replaces the prior MLflow and Solace services — the SAM mesh runner is no longer used in rev 3. |

### CI → Staging → Production flow

```
feat/*  →  development  →  staging-deploy.yml  →  release/*  →  main  →  production-deploy.yml
```

The `staging-deploy.yml` workflow triggers on push to `development` (live) / `release/**` (target). The `production-deploy.yml` triggers on push to `main`. The gap between live and target state is documented in `docs/architecture/06-cicd-pipeline.md` (Reality vs. Target State table).

### Container build

A single multi-stage `Dockerfile` at the repo root builds the API image. In rev 3 the 6-agent pipeline runs as a LangGraph `StateGraph` inside the API process (Sprint 1 task 1.A1) — no separate per-agent container, no message-bus runtime. Sprint 5 ships the same graph to **LangGraph Platform Cloud** via the **LangSmith Deployment SDK**; LangSmith tracing continues to flow from the hosted deployment automatically.

---

## 7.8 Indirect Prompt Injection Defence at RAG Corpus Ingest

### Threat

Indirect prompt injection via a RAG corpus (Greshake et al., 2023) embeds adversarial instructions in a document that is later retrieved and concatenated into a system prompt. Ranked **#1 in the OWASP Top 10 for LLM Applications (LLM01: Prompt Injection, 2025)**. In VerdictCouncil, the attack surface is the admin domain knowledge-base upload endpoint — a compromised document could influence judicial reasoning agents during case processing.

### Two-Layer Defence (Implemented — 2026-04-23)

| Layer | Mechanism | Latency | Coverage |
|-------|-----------|---------|----------|
| **L1 — Regex fast-path** | 9 compiled patterns strip model delimiter tokens (`<\|im_start\|>`, `[INST]`, `<<SYS>>`, `<system>` XML, Markdown system blocks) | < 1 ms | Delimiter-based injection |
| **L2 — DeBERTa-v3 semantic classifier** | `llm-guard==0.3.16` wrapping `protectai/deberta-v3-base-prompt-injection-v2` (Apache-2.0, 95.25% accuracy, 99.74% recall) | 0.2–2 s per page (MPS), ~80 ms CPU | Plain-English instruction overrides |

**Files:** `src/shared/sanitization.py`, `src/tools/parse_document.py`, `docs/security/rag-corpus-sanitization.md`

### Integration Design

- Sanitization runs **once per page** (single pass) — eliminated the prior double-scan bug that ran regex on both full text and each page separately.
- Classifier call is wrapped in `asyncio.to_thread()` — DeBERTa inference is synchronous; offloading prevents event-loop blocking.
- Classifier is **scoped to admin KB ingest only** via a `run_classifier` kwarg on `parse_document()` (default `False`). The case-processing pipeline retains regex-only sanitization until field evidence validates false-positive rate on legal corpora.
- When injection is detected, the page text is replaced with `[CONTENT_BLOCKED_BY_SCANNER]` before the sanitized artifact is indexed in the OpenAI vector store. The original file is stored separately for audit.
- Sanitization metrics (`regex_hits`, `classifier_hits`, `chunks_scanned`) are recorded in the `AdminEvent` audit trail on every upload.
- Model weights prefetched at install time via `scripts/prefetch_sanitizer_model.py` to prevent demo-time download failures.

### Ordering Limitation

OpenAI text extraction runs before sanitization — intrinsic to the pipeline (bytes cannot be semantically classified). The extraction model is not prompted to follow embedded instructions. Retrieval-time re-scanning and structural spotlighting (Hines et al., 2024) are documented as future work.

### Feature Flags

```
DOMAIN_UPLOADS_ENABLED=true       # default True — uploads enabled (sanitizer hardening complete)
CLASSIFIER_SANITIZER_ENABLED=true # default True — DeBERTa-v3 classifier active on ingest
```

Both override via `.env` for dev/test environments.

### References

- Greshake, K. et al. (2023). *Not what you've signed up for: Compromising Real-World LLM-Integrated Applications with Indirect Prompt Injection.* arXiv:2302.12173
- Liu, Y. et al. (2023). *Prompt Injection attack against LLM-integrated Applications.* arXiv:2306.05499
- Liu, Y. et al. (2023). *Formalizing and Benchmarking Prompt Injection Attacks and Defenses.* arXiv:2310.12815
- Hines, K. et al. (2024). *Defending Against Indirect Prompt Injection Attacks With Spotlighting.* arXiv:2403.14720
- Chen, S. et al. (2024). *StruQ: Defending Against Prompt Injection with Structured Queries.* arXiv:2402.06363
- OWASP Top 10 for LLM Applications (2025) — LLM01: Prompt Injection
- NIST AI 600-1 (2024) — Artificial Intelligence Risk Management Framework: Generative AI Profile
