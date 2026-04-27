# §6 AI Security Risk Register

**For group report §6 — VerdictCouncil AI Security Risk Register**  
**Date:** 2026-04-25 | **Version:** 3.0 (rev 3 — 6-agent topology) | **Owner:** VerdictCouncil Engineering Team

Rev 3 re-validates the 16 original risks against the Option 2 6-agent topology (`intake` → research fan-out of 4 subagents via `Send` → `synthesis` → `auditor`), adds 3 architecture-specific risks (R-17, R-18, R-19), and closes R-15 via LangSmith tracing. See `tasks/plan-2026-04-25-pipeline-rag-observability-overhaul.md` §6 (canonical source) and `tasks/architecture-2026-04-25.md` §4 (Send fan-out + dict-keyed accumulator).

---

## Risk Classification Scale

**Likelihood:** Low (unlikely in normal operation) / Medium (possible under realistic conditions) / High (routinely attempted or structurally probable)

**Impact:** Low (recoverable, limited scope) / Medium (service degradation or data quality issue) / High (judicial outcome affected or data breach) / Critical (legal liability, systemic failure, or fundamental rights violation)

**Status (rev 3):** `unchanged` (rev 3 preserves the existing control) / `strengthened` (control hardened by rev 3) / `replaced` (control reimplemented on a new mechanism — includes R-15 closed by LangSmith) / `open` (gap acknowledged, tracked outside this overhaul)

---

## Risk Register

| ID | Risk | Category | Likelihood | Impact | Status (rev 3) | Mitigation Implemented | Implementation Evidence | Residual Risk | Owner |
|---|---|---|---|---|---|---|---|---|---|
| R-01 | **Prompt injection via uploaded documents** — malicious document instructs the AI to ignore its system prompt or override its role | Input Security | High | Critical | unchanged | Two-layer defence: (1) regex scan strips known ChatML/Llama/system tokens before LLM processing; (2) LLM classifier (`gpt-5-mini`) checks ambiguous long-form content. Rev 3 preserves DeBERTa-v3 corpus sanitizer at admin RAG ingest (plan §7.2). | `src/shared/sanitization.py:4-42`; `src/pipeline/guardrails.py:29-96`; `src/pipeline/hooks.py:47-81`; `tests/unit/test_guardrails_activation.py` | Low — regex covers known vectors; LLM check is best-effort (non-blocking on LLM failure) | Backend |
| R-02 | **Hallucinated legal citations** — LLM fabricates case names or statutory provisions not present in the retrieved sources | AI Quality | Medium | Critical | strengthened | Tool-grounded citation instruction preserved; rev 3 adds `supporting_sources` enforcement in the Pydantic `response_format`, auditor `no_source_match` rejection reason, and a `suppressed_citation` table that persists every dropped citation for forensic review. | `configs/agents/legal-knowledge.yaml`; `configs/agents/governance-verdict.yaml:35`; plan §6.1 R-02; architecture §4 auditor contract | Low — three-stage defence (prompt → structured output → auditor) | Backend |
| R-03 | **Demographic bias in verdict recommendation** — AI produces recommendations that systematically disadvantage a protected group | AI Fairness | Medium | Critical | unchanged | Auditor's Phase 1 fairness-audit prompt distilled into LangSmith `audit` prompt commit; `ESCALATE_HUMAN` outcome preserved; structural exclusion of demographic fields from synthesis context preserved. | `configs/agents/governance-verdict.yaml:35-52`; `src/pipeline/hooks.py:126-162`; plan §6.1 R-03 | Medium — LLM fairness check is itself model-based; no automated demographic eval set exists (see Remediation #5) | Backend |
| R-04 | **Unauthorized case access** — user reads or modifies a case belonging to another judge | Access Control | Low | High | unchanged | JWT cookie auth (HS256) + server-side session hash validation; role-based `require_role()` dependency; judge ID embedded in case records. | `src/api/deps.py:45-51, 92`; `src/api/routes/cases.py` | Low | Backend |
| R-05 | **Audit log tampering** — an agent or API call overwrites or deletes audit entries | Data Integrity | Low | Critical | unchanged | `APPEND_ONLY_FIELDS = {"audit_log"}` enforced at validation layer (rev 3 lifts this into the audit middleware per 1.A1.2); PostgreSQL FK with CASCADE DELETE only on case deletion. | `src/shared/validation.py:25`; `src/models/audit.py:17-38`; plan §6.1 R-05 | Low | Backend |
| R-06 | **Pipeline state corruption via unauthorized field writes** — one agent overwrites fields owned by another | Data Integrity | Low | High | replaced | `FIELD_OWNERSHIP` dict and `FieldOwnershipError` retired. Replaced with per-agent Pydantic `response_format` schemas declared `extra="forbid"` — unexpected fields raise at LangChain parse time, before they ever enter state. Task 1.A1.SEC3 deletes the legacy allowlist code. | `src/shared/validation.py` (scheduled for deletion); plan §6.1 R-06; architecture §4 per-agent output models | Low — moved from post-hoc stripping to compile-time schema enforcement | Backend |
| R-07 | **PAIR API unavailability → missing legal precedents** — circuit breaker open, no fallback, verdict lacks statutory grounding | Availability | Medium | High | unchanged | 3-layer resilience preserved: Redis cache (TTL 86400s) → PAIR API with retry (2x) → circuit breaker (threshold=3, recovery=60s) → OpenAI vector store fallback tagged `source: "vector_store_fallback"`. | `src/tools/search_precedents.py`; `src/shared/circuit_breaker.py`; `src/tools/vector_store_fallback.py` | Low | Backend |
| R-08 | **Session hijacking via JWT theft** — stolen token used to access judicial data | Authentication | Low | High | unchanged | JWT stored as httpOnly cookie; server validates token by hashing against `Session.jwt_token_hash` in DB. Out of scope of the rev 3 overhaul. | `src/api/deps.py:45-51` | Low | Backend |
| R-09 | **Rate limit bypass via distributed clients** — attacker sends parallel requests to exhaust API resources | Availability | Medium | Medium | open | `RateLimitMiddleware` implements an in-memory sliding window (60 req/min per client IP, 429 + `Retry-After`), but as of commit `dae5047` the middleware is **disabled by default** (`rate_limit_enabled = False` in `src/shared/config.py`); operators opt in via `RATE_LIMIT_ENABLED=true`. **Rev 3 does not address this** — tracked separately. | `src/api/middleware/rate_limit.py:16-72`; `src/shared/config.py:95`; `src/api/app.py:178-180` | Medium-to-High — limiter ships off; even when enabled, the in-memory counter is per-pod (not shared across API replicas) | Backend |
| R-10 | **What-If scenario leaking verdict data across cases** — modified scenario picks up wrong case state | Data Privacy | Low | High | replaced | Deep-copy approach retired. Rev 3 uses LangGraph's native `graph.update_state(past_config, ...)` + `graph.invoke(None, fork_config)` with segregated `thread_id`; fork isolation is a checkpointer invariant, not a copy discipline. Integration test 4.A5.4 asserts no cross-thread leakage. | plan §6.1 R-10; architecture §4 What-If fork pattern; `tasks-breakdown-2026-04-25-pipeline-rag-observability.md` 4.A5.4 | Low | Backend |
| R-11 | **Dependency CVE exploitation** — known vulnerability in a Python package used by agents | Supply Chain | Medium | Medium | open | `pip-audit` runs on every CI push; currently advisory (`continue-on-error: true`). Rev 3 does not change this — tracked separately. | `.github/workflows/ci.yml` — `security` job | Medium — not a hard CI gate; fix requires making `pip-audit` blocking | DevOps |
| R-12 | **Bandit-detected Python security issues** — SAST finds unsafe patterns (subprocess, hardcoded secrets, etc.) | Supply Chain | Low | Medium | open | `bandit -r src/ -ll` runs on every CI push; currently advisory. Rev 3 does not change this — tracked separately. | `.github/workflows/ci.yml` — `security` job | Medium — not a hard CI gate; fix requires removing `continue-on-error` | DevOps |
| R-13 | **Stuck pipeline / resource exhaustion** — case enters pipeline and never completes, holding DB resources | Availability | Low | Medium | unchanged | `StuckCaseWatchdog` CronJob detects cases with `status=processing` beyond TTL and marks them failed. Preserved verbatim under rev 3. | `k8s/base/kustomization.yaml`; `src/services/stuck_case_watchdog/` | Low | Backend |
| R-14 | **LLM output not schema-validated** — JSON mode used but no strict schema; missing or malformed fields propagate | AI Quality | Medium | Medium | strengthened | Best-effort `response_format={"type": "json_object"}` replaced with `response_format=PydanticModel` strict-by-default; `ToolStrategy.handle_errors=True` retries on validation failure; LangChain native parse rejects malformed outputs before they enter state. | plan §6.1 R-14; architecture §4 per-agent `response_format`; 1.A1.7 | Low — moved from "best-effort JSON" to typed Pydantic contracts | Backend |
| R-15 | **No distributed LLM tracing** — LLM call inputs/outputs not exported to observability platform, limiting incident forensics | Observability | Low | Medium | replaced | Closed by LangSmith. Native tracing captures every LLM call (inputs, outputs, latency, token counts, tool calls, nested subagent Sends); `trace_id` flows FastAPI → LangSmith → SSE. The planned `mlflow.openai.autolog()` remediation is retired — LangSmith supersedes it. | plan §6.1 R-15; plan §7.3 Tracing Pipeline (rev 3); 3.B.* LangSmith integration tasks | Low — full distributed trace with cross-agent latency aggregation | Backend |
| R-16 | **Senior-judge inbox actions not fully implemented** — partial HITL workflow allows cases to stall | Process | Medium | Medium | open | Amendment routing and two-person rule implemented; reopen flow implemented; `US-036` (amendment-of-record) not fully implemented. Rev 3 does not address this — tracked separately. | `src/api/routes/senior_inbox.py`; `TRACEABILITY_MATRIX.md` | Medium — partial story coverage | Backend |
| R-17 | **Topology cutover regression** — the 9-agent → 6-agent switch lands in a single big-bang release, giving no rollback surface if terminal-state semantics or HITL behaviour regress in production | Architecture Migration | Medium | High | open | **Staged cutover, not big-bang.** (1) Sprint 1 lands the new topology behind an InMemorySaver + real `interrupt()` from day one (1.A1.7) with the replay-N-cases regression harness (1.A1.10) asserting terminal-state semantic equivalence against golden cases before merge. (2) Sprint 2 migrates the checkpointer to `PostgresSaver` (2.A2.*) with in-flight case migration + maintenance-window cutover (2.A2.7, 2.A2.10), keeping the legacy `upsert_pipeline_state` path read-only/shadow-write until drop (2.A2.11). (3) Sprint 4 upgrades the audit/HITL UX (4.A3.*) on top of the already-stable topology. Each sprint is revertible independently; LangSmith eval baseline (3.D1.4) gates the merge at CI (4.D3.1) on any scorer regression. | Sprint 1 (code) / Sprint 2 (checkpointer) / Sprint 4 (audit) | Low — three independently revertible stages with regression + eval gates | Backend |
| R-18 | **LangSmith outage** — observability + prompt registry is a hard dependency of the runtime; a LangSmith region outage could block prompt fetches or drop traces at the worst possible moment | Observability / Supply Chain | Low | Low | open | **LangSmith tracing is non-load-bearing for runtime correctness** — it is observability only; the LangSmith client is configured fail-open so the pipeline keeps running when tracing is degraded (plan §6.1 R-18, §7.3). **Prompt registry cold-start risk is bounded** by `lru_cache(maxsize=64)` on the prompt fetch, so after the first warm-up each worker serves prompts from memory and a LangSmith outage only affects new prompt revisions, not cached runtime traffic. | plan §6.1 R-18; plan §7.3; 3.C3a.* prompt registry tasks (lru_cache) | Low — degraded observability only; no correctness impact | Backend |
| R-19 | **`Send`-without-idempotency** — the 4 research subagents are fanned out in parallel via `Send` under `add_conditional_edges`; if a subagent is re-run on resume (gate2 rerun, checkpointer replay, transient retry), non-idempotent side effects could produce duplicate rows, retry storms, or corrupted aggregation | Concurrency / Data Integrity | Low | Medium | open | **Idempotent-by-design convention enforced by the graph state shape.** The join accumulator is `Annotated[dict[str, ResearchPart], merge_dict]` (architecture §4 / SA F-2) — each subagent writes under its own scope key (`evidence` / `facts` / `witnesses` / `law`), so `merge_dict` per-key overwrite means a re-run replaces that scope's entry rather than appending a duplicate. Subagent nodes produce structured Pydantic output and perform **no direct DB writes**; persistence is done only by the audit middleware's UPSERT path, which is keyed on `(case_id, agent, trace_id)` and is idempotent under replay. `research_dispatch_node` returning `{}` under `merge_dict` preserves existing keys; external reruns use `Overwrite({})` (SA V-3) to reset the accumulator before re-dispatch. Integration test 4.A3.12 asserts idempotency under replay. | architecture §4.2 `merge_dict` + dict-keyed accumulator; plan §6.2 R-19; 4.A3.12 | Low — per-key overwrite + no-DB-writes + idempotent audit UPSERT | Backend |

---

## Risk Summary

| Severity | Count | Status |
|---|---|---|
| Critical impact, mitigated (rev 3) | 5 (R-01, R-02, R-03, R-05, R-06) | Controls in place |
| High impact, mitigated (rev 3) | 5 (R-04, R-07, R-08, R-10, R-17) | Controls in place |
| Medium residual gaps (unchanged) | 4 (R-09, R-11, R-12, R-16) | Tracked separately |
| Closed / reimplemented by rev 3 | 1 (R-15 — replaced by LangSmith) | Closed |
| New rev-3 risks, mitigated | 3 (R-17, R-18, R-19) | Mitigated by staged cutover / fail-open tracing / dict-keyed accumulator |
| **Total risks tracked** | **19** | |

---

## Planned Remediations (Priority Order)

| Remediation | Closes | Effort |
|---|---|---|
| Make `pip-audit` and `bandit` hard CI gates | R-11, R-12 | ~30 min |
| Add `--cov-fail-under=80` to pytest CI | (quality gate) | ~15 min |
| Migrate rate limiter to Redis (shared across replicas) | R-09 | ~2–4 hours |
| Implement US-036 amendment-of-record end-to-end | R-16 | ~8–16 hours |
| Add demographic bias eval set to eval suite | R-03 | ~4–8 hours |

*Retired from the remediation backlog under rev 3:*
- ~~Wire `mlflow.openai.autolog()` in both runners~~ — **closed by R-15 replacement (LangSmith)**.
- ~~Add `json_schema` strict mode to governance-verdict~~ — **closed by R-14 strengthening (Pydantic `response_format` strict-by-default in 1.A1.7)**.

---

## Notes

- This register covers AI-specific and application-layer risks. Infrastructure-layer risks (DOKS node compromise, DO Managed DB breach) are outside scope and covered by DigitalOcean's shared responsibility model.
- Rev 3 ratings are as of 2026-04-25. Re-assess after any major model upgrade, new agent addition, or change to the Singapore court domain scope.
- Model references in this register use the `gpt-5` / `gpt-5-mini` family; the GPT-4 family is deprecated for VerdictCouncil runtime use.
