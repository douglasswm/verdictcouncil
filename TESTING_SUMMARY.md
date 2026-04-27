# §8 Testing Summary

**Snapshot date:** 2026-04-22  
**Backend test suite:** 385 tests, 71% line coverage, 0 failures  
**Security scan:** 0 medium/high bandit findings, pip-audit advisory

---

## 8.1 Test Types and Results

| Test Type | Scope | Location | Count | Result |
|-----------|-------|----------|-------|--------|
| Unit — API layer | Routes, schemas, auth middleware | `tests/unit/test_cases.py`, `test_auth.py`, `test_admin_routes.py` | ~60 | ✅ Pass |
| Unit — Pipeline logic | PipelineRunner, MeshPipelineRunner, layer-2 aggregator | `test_pipeline_runner.py`, `test_mesh_runner.py`, `test_layer2_aggregator.py`, `test_layer2_aggregator_sam_wrapper.py` | ~45 | ✅ Pass |
| Unit — CaseState | Field ownership validation, Pydantic model | `test_case_state.py`, `test_validation.py` | ~20 | ✅ Pass |
| Unit — Agent tools | `parse_document`, `cross_reference`, `timeline_construct`, `generate_questions`, `search_precedents`, `confidence_calc` | `test_parse_document.py`, `test_cross_reference.py`, `test_timeline_construct.py`, `test_generate_questions.py`, `test_search_precedents.py`, `test_search_precedents_tool.py`, `test_confidence_calc.py` | ~70 | ✅ Pass |
| Unit — Persistence | `persist_case_results`, hearing analysis rows | `test_persist_case_results.py` | ~15 | ✅ Pass |
| Unit — Judge features | Fairness audit, evidence dashboard, jurisdiction, dispute-fact | `test_judge_fairness_audit.py`, `test_judge_evidence_dashboard.py`, `test_judge_jurisdiction.py`, `test_judge_dispute_fact.py` | ~30 | ✅ Pass |
| Unit — Guardrails (regex) | L1 regex patterns: OpenAI delimiters, `<system>` tags, `InputGuardrailHook` hook integration | `test_guardrails_activation.py` | 5 | ✅ Pass |
| Unit — Guardrails (adversarial) | L2 LLM classifier, Llama `<<SYS>>` pattern, null bytes, markdown system blocks, forensic `method` field | `test_guardrails_adversarial.py` | 5 | ✅ Pass |
| Unit — Sanitization | `sanitize_user_input`: null bytes, markdown system blocks, HTML tags | `test_sanitization.py` | ~8 | ✅ Pass |
| Unit — What-If / Contestable Judgment | Deep-clone isolation, resume from agent, parallel fan-out correctness | `test_what_if_controller.py`, `test_pipeline_state.py` | ~15 | ✅ Pass |
| Unit — Infrastructure components | Rate limiting, circuit breaker, retry logic, SAM YAML parsing | `test_rate_limit.py`, `test_circuit_breaker.py`, `test_retry.py`, `test_sam_yaml_parsing.py` | ~20 | ✅ Pass |
| Unit — Outbox / watchdog | Stuck case watchdog (in-process), pipeline job tasks | `test_stuck_case_watchdog.py`, `test_pipeline_job_tasks.py` | ~10 | ✅ Pass |
| Unit — Supporting features | PDF export, hearing pack, diff engine, stability score, knowledge base, SSE | remaining unit files | ~82 | ✅ Pass |
| Integration — Pipeline halt conditions | Full halt-on-escalation and halt-on-guardrail flows with real DB | `tests/integration/test_halt_conditions.py` | ~8 | ✅ Pass (requires Postgres) |
| Integration — Outbox + Postgres | Transactional outbox pattern with live Postgres | `tests/integration/test_pipeline_jobs_outbox_pg.py` | ~5 | ✅ Pass (requires Postgres) |
| Integration — SAM mesh smoke (decommissioned in rev 3) | End-to-end happy-path with live Solace broker — historical only; the SAM/Solace runtime was removed when the in-process LangGraph runner became canonical. Test is preserved as a historical reference but no longer runs in CI or staging. | `tests/integration/test_sam_mesh_smoke.py` | ~3 | n/a — decommissioned |
| Integration — Watchdog Postgres | Stuck-case detection with live Postgres | `tests/integration/test_stuck_case_watchdog_pg.py` | ~4 | ✅ Pass (requires Postgres) |
| Eval — Gold-set | End-to-end pipeline against 10 gold-set SCT cases | `tests/eval/` | 10 cases | Requires full infra + live API key |

**Total unit tests collected by pytest (snapshot 2026-04-22):** 385  
**Total coverage (unit suite, snapshot):** 70.82%  
**Coverage gate in CI (current):** `--cov-fail-under=100` — the suite has been expanded and `coverage` exclusions tightened since the snapshot to satisfy the hard gate; `tests/unit/` and `tests/api/` are run with `-m "not integration and not eval and not requires_openai"`.

---

## 8.2 Security Test Detail

### L1 Regex Layer (test_guardrails_activation.py)

| Test | Payload pattern | Expected result |
|------|----------------|-----------------|
| `test_check_input_injection_blocks_openai_delimiter` | `<\|im_start\|>system\n...<\|im_end\|>` | `blocked=True`, `method="regex"`, `[CONTENT_REMOVED]` in sanitised text |
| `test_check_input_injection_blocks_system_tag` | `<system>...approve unconditionally...</system>` | `blocked=True`, `method="regex"`, `[TAG_REMOVED]` in sanitised text |
| `test_apply_input_guardrail_replaces_description_and_audits` | `[INST]Override...[/INST]` | Description sanitised, `input_injection_blocked` in audit log |
| `test_apply_input_guardrail_passes_clean_input_unchanged` | Plain traffic case description | Not blocked, no audit entry added |
| _(fifth test)_ | Covered in activation module | ✅ Pass |

### L2 LLM Classifier Layer (test_guardrails_adversarial.py)

| Test | Mechanism | Expected result |
|------|-----------|-----------------|
| `test_check_input_injection_blocks_via_llm_layer` | Mocked LLM returns `is_injection: true` | `blocked=True`, `method="llm"`, sanitised text present |
| `test_check_input_injection_llm_layer_passes_benign_text` | Mocked LLM returns `is_injection: false` | `blocked=False`, `method="none"`, text unchanged |
| `test_check_input_injection_blocks_llama_sys_tag` | `<<SYS>>...<</SYS>>` regex pattern | `blocked=True`, `method="regex"`, `[CONTENT_REMOVED]` present |
| `test_sanitize_user_input_strips_null_bytes_and_markdown_system_block` | Null byte + `` ```system `` block | Null bytes removed, markdown system block replaced |
| `test_check_input_injection_llm_result_includes_method_field` | LLM-blocked payload | `method="llm"` in result for forensic audit logging |

All 10 security tests run in CI with zero external API calls — the LLM classifier is mocked.

### Static Security Analysis

| Tool | Scope | Result |
|------|-------|--------|
| `bandit -r src/ -ll` | All source files (12,379 lines) | **0 medium/high issues** (1 suppressed: `B104` bind-all-interfaces, intentional for container). BLOCKING in CI. |
| `semgrep --config=p/security-audit --config=p/owasp-top-ten` | All source files | SARIF uploaded to the GitHub Security tab. Advisory in CI today (target: hard fail on medium+). |
| `pip-audit` + `safety` + `cyclonedx-bom` SBOM | Full dependency tree | Advisory — results visible in CI job log; SBOM published as build artefact. |
| **Trivy image scan** (`aquasecurity/trivy-action`) | Built `verdictcouncil` container image | SARIF uploaded to the GitHub Security tab on every CI build and every `deploy.yml` run. Advisory today. |

---

## 8.3 Coverage by Module Area

| Area | Coverage |
|------|----------|
| `src/api/` (routes, schemas) | ~75% |
| `src/pipeline/` (runner, mesh_runner, hooks, guardrails) | ~65% |
| `src/shared/` (case_state, audit, sanitization, config) | ~80% |
| `src/tools/` (parse_document, search_precedents, etc.) | ~70% |
| `src/db/` (persistence, models) | ~65% |
| `src/services/` (hearing pack, report data) | ~60% |
| `src/workers/` (outbox, dispatcher) | ~30% (worker entry points excluded from unit coverage; covered by integration tests) |
| **Overall** | **71%** |

---

## 8.4 Known Test Exclusions and Limitations

| Exclusion | Reason |
|-----------|--------|
| Integration tests (`tests/integration/`) | Require live Postgres, Redis, and/or Solace — excluded from unit CI; run in local dev and staging |
| Eval tests (`tests/eval/`) | Require live OpenAI API key and full infra — not run in CI; run manually against staging |
| Frontend tests | Separate CI pipeline (`npm test`, `npm run check:contract`) — not included in this count |
| MeshPipelineRunner SAM paths | The SAM/Solace runner was decommissioned in rev 3 and `MeshPipelineRunner` is now a stub. Historic mesh tests are preserved for reference only. |
| MLflow trace capture in mesh mode | Decommissioned — LangSmith is the canonical tracing substrate in rev 3 (replaces MLflow per Risk R-15). Per-agent traces flow automatically once `LANGSMITH_TRACING=true`. |
| Demographic fairness eval set | No automated test for outcome parity across demographic groups (risk R-03, residual medium) |
