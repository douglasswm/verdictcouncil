# §6 AI Security Risk Register

**For group report §6 — VerdictCouncil AI Security Risk Register**  
**Date:** 2026-04-22 | **Version:** 1.0 | **Owner:** VerdictCouncil Engineering Team

---

## Risk Classification Scale

**Likelihood:** Low (unlikely in normal operation) / Medium (possible under realistic conditions) / High (routinely attempted or structurally probable)

**Impact:** Low (recoverable, limited scope) / Medium (service degradation or data quality issue) / High (judicial outcome affected or data breach) / Critical (legal liability, systemic failure, or fundamental rights violation)

---

## Risk Register

| ID | Risk | Category | Likelihood | Impact | Mitigation Implemented | Implementation Evidence | Residual Risk | Owner |
|---|---|---|---|---|---|---|---|---|
| R-01 | **Prompt injection via uploaded documents** — malicious document instructs the AI to ignore its system prompt or override its role | Input Security | High | Critical | Two-layer defence: (1) regex scan strips known ChatML/Llama/system tokens before LLM processing; (2) LLM classifier (`gpt-5.4-nano`) checks ambiguous long-form content | `src/shared/sanitization.py:4-42`; `src/pipeline/guardrails.py:29-96`; `src/pipeline/hooks.py:47-81`; injection patterns tested in `tests/unit/test_guardrails_activation.py` | Low — regex covers known vectors; LLM check is best-effort (non-blocking on LLM failure) | Backend |
| R-02 | **Hallucinated legal citations** — LLM fabricates case names or statutory provisions not present in the retrieved sources | AI Quality | Medium | Critical | `legal-knowledge` system prompt explicitly forbids hallucination; all citations must be verbatim from tool outputs; `governance-verdict` Phase 1 checks for unsupported citations | `configs/agents/legal-knowledge.yaml` (tool-grounded citation instruction); `configs/agents/governance-verdict.yaml:35` (fairness audit step) | Low — LLM tool-grounding + terminal AI reviewer | Backend |
| R-03 | **Demographic bias in verdict recommendation** — AI produces recommendations that systematically disadvantage a protected group | AI Fairness | Medium | Critical | `governance-verdict` mandatory Phase 1 fairness audit with instruction to flag demographic bias; `ESCALATE_HUMAN` outcome if critical issues found; "false positives acceptable" policy | `configs/agents/governance-verdict.yaml:35-52`; `src/pipeline/hooks.py:126-162` | Medium — LLM fairness check is itself model-based; no automated demographic eval set exists | Backend |
| R-04 | **Unauthorized case access** — user reads or modifies a case belonging to another judge | Access Control | Low | High | JWT cookie auth (HS256) + server-side session hash validation; role-based `require_role()` dependency; judge ID embedded in case records | `src/api/deps.py:45-51, 92`; `src/api/routes/cases.py` (case ownership check) | Low | Backend |
| R-05 | **Audit log tampering** — an agent or API call overwrites or deletes audit entries | Data Integrity | Low | Critical | `APPEND_ONLY_FIELDS = {"audit_log"}` enforced at validation layer — unauthorized writes to audit_log are detected and stripped; PostgreSQL FK with CASCADE DELETE only on case deletion | `src/shared/validation.py:25`; `src/models/audit.py:17-38` | Low | Backend |
| R-06 | **Pipeline state corruption via unauthorized field writes** — one agent overwrites fields owned by another | Data Integrity | Low | High | `FIELD_OWNERSHIP` dict enforces per-agent write allowlists; violations stripped with `FieldOwnershipError` logged; enforced in both `PipelineRunner` and `MeshPipelineRunner` | `src/shared/validation.py:4-22`; `src/pipeline/runner.py:590-605`; `src/pipeline/mesh_runner.py:525-538` | Low | Backend |
| R-07 | **PAIR API unavailability → missing legal precedents** — circuit breaker open, no fallback, verdict lacks statutory grounding | Availability | Medium | High | 3-layer resilience: Redis cache (TTL 86400s) → PAIR API with retry (2x) → circuit breaker (threshold=3, recovery=60s) → OpenAI vector store fallback; fallback results tagged `source: "vector_store_fallback"` | `src/tools/search_precedents.py`; `src/shared/circuit_breaker.py`; `src/tools/vector_store_fallback.py` | Low | Backend |
| R-08 | **Session hijacking via JWT theft** — stolen token used to access judicial data | Authentication | Low | High | JWT stored as httpOnly cookie (not accessible to JS); server validates token by hashing against `Session.jwt_token_hash` in DB — stolen token alone is insufficient | `src/api/deps.py:45-51` | Low | Backend |
| R-09 | **Rate limit bypass via distributed clients** — attacker sends parallel requests to exhaust API resources | Availability | Medium | Medium | In-memory sliding window 60 req/min per client IP; 429 + `Retry-After` response | `src/api/middleware/rate_limit.py:16-72` | **Medium — in-memory limiter is not shared across API replicas (web-gateway HPA 2-5 pods); each pod has an independent counter** | Backend |
| R-10 | **What-If scenario leaking verdict data across cases** — modified scenario picks up wrong case state | Data Privacy | Low | High | `WhatIfController.create_scenario` deep-clones the passed `CaseState` via `copy.deepcopy`; new `run_id` assigned; no shared mutable state between cases | `src/services/whatif_controller/controller.py:64, 71` | Low | Backend |
| R-11 | **Dependency CVE exploitation** — known vulnerability in a Python package used by agents | Supply Chain | Medium | Medium | `pip-audit` runs on every CI push and reports known CVEs; currently advisory (`continue-on-error: true`) | `.github/workflows/ci.yml` — `security` job | **Medium — not a hard CI gate; fix requires making `pip-audit` blocking** | DevOps |
| R-12 | **Bandit-detected Python security issues** — SAST finds unsafe patterns (subprocess, hardcoded secrets, etc.) | Supply Chain | Low | Medium | `bandit -r src/ -ll` runs on every CI push; currently advisory | `.github/workflows/ci.yml` — `security` job | **Medium — not a hard CI gate; fix requires removing `continue-on-error`** | DevOps |
| R-13 | **Stuck pipeline / resource exhaustion** — case enters pipeline and never completes, holding DB resources | Availability | Low | Medium | `StuckCaseWatchdog` CronJob detects cases with `status=processing` beyond TTL and marks them failed | `k8s/base/kustomization.yaml`; `src/services/stuck_case_watchdog/` | Low | Backend |
| R-14 | **LLM output not schema-validated** — JSON mode used but no strict schema; missing or malformed fields propagate | AI Quality | Medium | Medium | `response_format={"type": "json_object"}` forces JSON output; field ownership validation strips unexpected fields; `validate_output_integrity` checks governance-verdict required fields | `src/pipeline/runner.py:522`; `src/pipeline/guardrails.py:99-129` | **Medium — no `json_schema` strict mode; malformed agent outputs may partially succeed** | Backend |
| R-15 | **No distributed LLM tracing** — LLM call inputs/outputs not exported to observability platform, limiting incident forensics | Observability | N/A | Medium | Per-agent audit log captures inputs, outputs, model, token counts; persisted to PostgreSQL | `src/shared/audit.py`; `CaseState.audit_log` | **Medium — no latency aggregation or cross-agent trace; MLflow autolog not wired (planned)** | Backend |
| R-16 | **Senior-judge inbox actions not fully implemented** — partial HITL workflow allows cases to stall | Process | Medium | Medium | Amendment routing and two-person rule implemented; reopen flow implemented; `US-036` (amendment-of-record) not fully implemented | `src/api/routes/senior_inbox.py`; `TRACEABILITY_MATRIX.md` | **Medium — partial story coverage; documented in TRACEABILITY_MATRIX.md** | Backend |

---

## Risk Summary

| Severity | Count | Status |
|---|---|---|
| Critical impact, mitigated | 5 (R-01, R-02, R-03, R-05, R-06) | Implemented controls in place |
| High impact, mitigated | 4 (R-04, R-07, R-08, R-10) | Implemented controls in place |
| **Residual Medium risk (gaps)** | 5 (R-09, R-11, R-12, R-14, R-15) | Tracked; planned remediation |
| Process gap | 2 (R-13, R-16) | R-13 mitigated; R-16 partially implemented |

---

## Planned Remediations (Priority Order)

| Remediation | Closes | Effort |
|---|---|---|
| Make `pip-audit` and `bandit` hard CI gates | R-11, R-12 | ~30 min |
| Add `--cov-fail-under=80` to pytest CI | (quality gate) | ~15 min |
| Wire `mlflow.openai.autolog()` in both runners | R-15 | ~1–3 hours |
| Migrate rate limiter to Redis (shared across replicas) | R-09 | ~2–4 hours |
| Add `json_schema` strict mode to governance-verdict | R-14 | ~1–2 hours |
| Implement US-036 amendment-of-record end-to-end | R-16 | ~8–16 hours |
| Add demographic bias eval set to eval suite | R-03 | ~4–8 hours |

---

## Notes

- This register covers AI-specific and application-layer risks. Infrastructure-layer risks (DOKS node compromise, DO Managed DB breach) are outside scope and covered by DigitalOcean's shared responsibility model.
- Risk ratings are as of 2026-04-22. Re-assess after any major model upgrade, new agent addition, or change to the Singapore court domain scope.
