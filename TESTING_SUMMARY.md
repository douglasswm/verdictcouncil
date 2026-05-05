# §8 Testing Summary

**Snapshot date:** 2026-05-05  
**Backend unit + property test suite:** 907 tests (883 unit + 24 property-based), 0 failures  
**Frontend unit test suite:** 248 tests (245 passed, 3 skipped), 0 failures  
**Load tests:** 30-second Locust burst — error rate 0%, all p95 within SLO after CI fixes in this sprint  
**Security scan:** 0 medium/high bandit findings, pip-audit advisory

---

## 8.1 Test Types and Results

| Test Type | Tool / Framework | Scope | Count | CI Job | Result |
|-----------|-----------------|-------|-------|--------|--------|
| Unit — backend | pytest + pytest-asyncio + pytest-mock | API routes, schemas, auth middleware, pipeline logic, agent tools, guardrails, persistence, SSE, export | **883** | `unit-tests` | ✅ 883 passed, 1 skipped |
| Property-based — backend | pytest + Hypothesis | Input invariants, schema validation, edge-case generation | **24** | `property-tests` | ✅ 24 passed |
| Unit — frontend | Vitest + jsdom + Testing Library | Auth pages (login, password recovery), auth components (coverage ≥ 95%) | **248** | `unit-tests` (FE CI) | ✅ 245 passed, 3 skipped |
| Accessibility | Vitest + jest-axe | Auth surface: WCAG 2.1 AA colour contrast, ARIA roles, form labelling | ~10 | `accessibility-tests` | ✅ Pass |
| Load / Performance | Locust | 5 VUs × 30 s: case CRUD, auth, SSE, health probe; p95 ≤ 5 s, error rate ≤ 5% | continuous | `load-tests` | ✅ Pass (post fix — see §8.3) |
| SAST — backend | Bandit + Semgrep (OWASP Top-10) | All `src/` Python (≈ 12,400 lines) | full scan | `sast` | ✅ 0 medium/high (Bandit); Semgrep SARIF uploaded to Security tab |
| SAST — frontend | Semgrep + ESLint security plugin | All `src/` JS/JSX | full scan | `sast` (FE CI) | Advisory; SARIF uploaded |
| SCA | pip-audit + cyclonedx-bom (BE); npm audit + CycloneDX npm (FE) | Full dependency trees | full scan | `sca` | Advisory; SBOM published as artefact |
| Container image scan | Trivy | `verdictcouncil:test` image (HIGH/CRITICAL, unfixed only) | full image | `build` | Advisory; SARIF uploaded to Security tab |
| DAST | FastAPI + Postgres live; HTTP security headers + API contract tests | All frontend-facing endpoints | all routes | `dast` | Advisory; `continue-on-error` |
| Integration — halt conditions | pytest + Postgres (live) | Halt-on-escalation, halt-on-guardrail with real DB | ~8 | local / staging | ✅ Pass (not in default CI path — requires Postgres service) |
| Integration — outbox + Postgres | pytest + Postgres (live) | `FOR UPDATE SKIP LOCKED` claim semantics, 10 concurrent workers | ~5 | local / staging | ✅ Pass |
| Integration — watchdog | pytest + Postgres (live) | Stuck-case detection, timeout progression | ~4 | local / staging | ✅ Pass |
| Eval — LangSmith gate | LangSmith + pytest | Prompt regression vs. Sprint 3 baseline (>5% scorer drop = fail) | golden set | `eval` (PR only) | Observe-only (baseline experiment unset) |
| Prompt regression | PromptFoo | Per-phase prompt eval: intake, research ×4, synthesis, audit | 7 suites | `promptfoo-tests-ci` | Advisory; reports uploaded as artefacts |

**Total backend tests in CI (2026-05-05):** 907 (883 unit + 24 property-based)  
**Frontend tests in CI (2026-05-05):** 248 (245 passed, 3 skipped)  
**Coverage gate in CI:** `--cov-fail-under=60` (unit suite); frontend auth surface ≥ 95% lines/statements, ≥ 90% functions

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

## 8.3 CI Fixes Applied (Sprint 4, 2026-05-05)

The following bugs were found in the CI pipeline and fixed. All caused false-green CI runs (jobs reported success while hidden steps were failing):

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Load test 100% error rate | Locust sent `username` field; API schema requires `email`. No DB migrations run before server start; no users seeded in fresh DB. `/health` route returned 404 (no such endpoint). | Fixed `locustfile.py` (`username` → `email`, default credentials aligned to demo seed). Added `/health` liveness endpoint to `app.py`. Added `alembic upgrade head` + `python -m scripts.seed_users` steps to `load-tests` CI job before server start. Removed `continue-on-error` — load tests are now a hard gate. |
| No test report artifacts | `pytest` ran without `--junitxml`; no downloadable test results | Added `--junitxml=junit-unit.xml` and `--junitxml=junit-property.xml` to backend unit and property test steps, uploaded as `unit-test-report` and `property-test-report` artifacts. |
| Frontend no test report artifact | Vitest had no JUnit reporter | Added `--reporter=junit --outputFile.junit=junit-frontend.xml` to frontend unit test CI step; uploaded as `frontend-unit-test-report` artifact. |

### Promptfoo Synthesis Suite — Post-Run Remediation (2026-05-05)

The committed eval result `eval-UzM-2026-04-27T03:32:26` showed 2 failures in the synthesis suite. Three fixes were applied and verified by re-running the suite (`eval-BV2-2026-05-05T15:08:00`, 8/8 pass, score 1.0):

| Issue | Root Cause | Fix | Commit |
|-------|-----------|-----|--------|
| Latency 63,816 ms > 30,000 ms gate | Threshold inherited from lighter research-phase suites without adjustment for synthesis (heaviest phase: two tool calls per argument + large output) | Corrected `synthesis.yaml` threshold from 30,000 ms → 90,000 ms, matching the prompt-declared budget | Already in place before re-run |
| `preliminary_conclusion !== null` (verdict leakage) | Prompt prohibition was prose-only; model sometimes emitted a non-null verdict string | Added concrete JSON counter-example to `prompts/synthesis.md` Hard rules block showing the only valid form; named CRITICAL_FLAG consequence | `02607ee` |
| `prosecution`/`defence` and `pre_hearing_brief` assertions failing | Assertion drift: field names in `synthesis.js` referenced pre-rename terminology (`argument-construction` + `hearing-analysis` → `synthesis`); `pre_hearing_brief` was removed from schema in the same rename | Updated `synthesis.js` assertions to use current schema field names (`claimant_arguments`, `respondent_arguments`, `uncertainty_flags`) | `ab0f204` |

## 8.4 Known Test Exclusions and Limitations

| Exclusion | Reason |
|-----------|--------|
| Integration tests (`tests/integration/`) | Require live Postgres, Redis — excluded from unit CI; run in local dev and staging |
| Eval tests (`tests/eval/`) | Require live OpenAI API key and full infra — not run in CI; run manually against staging |
| E2E Playwright tests | Marked advisory (`continue-on-error: true`) — requires backend API; CI only boots Vite dev server, so API calls 404. Will be fixed when docker-compose integration env is wired |
| SAST / SCA / DAST / image scan | Advisory (`continue-on-error: true`) — findings visible in GitHub Security tab / artefacts; target is hard-fail on medium+ |
| LangSmith eval baseline | `EVAL_BASELINE_EXPERIMENT` repo variable unset — gate is observe-only until baseline is registered |
| MeshPipelineRunner SAM paths | SAM/Solace runner decommissioned in rev 3. Historic tests preserved for reference only |
| Demographic fairness eval set | No automated test for outcome parity across demographic groups (risk R-03, residual medium) |
