# §7 MLSecOps / LLMSecOps Pipeline

## 7.1 Overview

VerdictCouncil's MLSecOps pipeline enforces quality, security, and observability gates on every commit. The pipeline treats LLM-specific risks as first-class citizens: adversarial injection tests run as unit tests in CI, static security analysis is hard-blocking, and every production pipeline execution emits structured traces to MLflow.

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
           ┌─────────────┼──────────────┐
           ▼             ▼              ▼
  ┌──────────────┐ ┌──────────────┐ ┌───────────────────────────────┐
  │ Job: test    │ │ Job: openapi │ │ Job: security                 │
  │ pytest 385   │ │ snapshot     │ │ pip-audit  (advisory)         │
  │ tests        │ │ diff check   │ │ bandit -ll (BLOCKING)         │
  │ --cov-fail   │ │              │ │ 0 medium/high issues          │
  │ -under=65    │ │              │ │                               │
  └──────┬───────┘ └──────────────┘ └───────────────────────────────┘
         │
         ▼
  ┌──────────────┐
  │ Job: docker  │
  │ build (push  │
  │ false)       │
  └──────────────┘
```

**File:** `.github/workflows/ci.yml`

| Job | Trigger | Gate type | Blocks merge? |
|-----|---------|-----------|--------------|
| `lint` | every push | style | Yes |
| `test` | needs: lint | quality (coverage ≥ 65%) | Yes |
| `openapi` | needs: lint | contract drift | Yes |
| `security` | needs: lint | static analysis | Yes (`bandit`); advisory (`pip-audit`) |
| `docker` | needs: test | build integrity | Yes |

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

## 7.4 MLflow Observability (LLM Tracing)

### Architecture

```
FastAPI startup
  └─ configure_mlflow()                 # idempotent; no-op if MLFLOW_ENABLED=false
       ├─ mlflow.set_tracking_uri()
       ├─ mlflow.set_experiment()
       └─ mlflow.openai.autolog()       # captures AsyncOpenAI.chat.completions.create()

PipelineRunner.run()
  └─ pipeline_run(case_id, run_id, mode="in_process")   # wraps full pipeline as MLflow run
       └─ per-agent LLM calls          # captured automatically by autolog

PipelineRunner._execute_tool_call()
  ├─ tool_span("tool.parse_document")  # manual span for local tool execution
  └─ tool_span("tool.search_precedents") # manual span for precedent search
```

**Key design choice:** `configure_mlflow()` is never called at module scope — it is activated only in the FastAPI `lifespan` hook (`src/api/app.py`). This prevents MLflow autolog from firing during `pytest` collection or in SAM agent subprocesses.

### What is traced per pipeline run

| Trace source | Data captured |
|---|---|
| `mlflow.openai.autolog()` | Prompt, completion, model, token usage, latency per OpenAI API call |
| `pipeline_run()` | `case_id`, `run_id`, `pipeline_mode` tags on the parent MLflow run |
| `tool_span("tool.parse_document")` | Tool name, input argument keys |
| `tool_span("tool.search_precedents")` | Tool name, input argument keys |

### Limitation: mesh path

On the `MeshPipelineRunner` path (production distributed mode), individual agent LLM calls happen inside SAM subprocess workers — they cannot be captured by autolog running in the API process. Each SAM agent would need to call `configure_mlflow()` locally. This is documented as a known limitation (see §9 Future Improvements).

### MLflow Server Setup

```yaml
# docker-compose.infra.yml
mlflow:
  image: ghcr.io/mlflow/mlflow:v2.18.0
  ports:
    - "5000:5000"
  command: >
    mlflow server --host 0.0.0.0 --port 5000
    --backend-store-uri sqlite:////mlflow/mlflow.db
    --default-artifact-root /mlflow/artifacts
```

Access the trace viewer at `http://localhost:5000` after `docker compose -f docker-compose.infra.yml up -d`.

### MLflow Configuration

Controlled via environment variables, with safe defaults:

```python
# src/shared/config.py
mlflow_enabled: bool = False                         # opt-in; off by default
mlflow_tracking_uri: str = "http://localhost:5000"
mlflow_experiment: str = "verdictcouncil-pipeline"
```

Set `MLFLOW_ENABLED=true` to activate tracing in any environment.

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
| FastAPI API | `verdictcouncil:latest` | 8000 | REST API + SSE pipeline events |
| PostgreSQL 16 | `vc-postgres` | 5432 | Case records, audit entries, deliberations |
| Redis 7 | `vc-redis` | 6379 | L2 fan-out barrier, rate limiting |
| Solace PubSub+ | `vc-solace` | 55556/8080 | A2A pub/sub transport for SAM agents |
| MLflow | `vc-mlflow` | 5000 | LLM trace storage and viewer |

### CI → Staging → Production flow

```
feat/*  →  development  →  staging-deploy.yml  →  release/*  →  main  →  production-deploy.yml
```

The `staging-deploy.yml` workflow triggers on push to `development` (live) / `release/**` (target). The `production-deploy.yml` triggers on push to `main`. The gap between live and target state is documented in `docs/architecture/06-cicd-pipeline.md` (Reality vs. Target State table).

### Container build

A single multi-stage `Dockerfile` at the repo root builds the API image. SAM agents are registered via YAML configuration (`configs/agents/*.yaml`) and loaded by the Solace Agent Mesh runtime — no per-agent Docker image is required.
