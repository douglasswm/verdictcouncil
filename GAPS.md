# GAPS.md — Grading Requirement vs Implementation

**Reviewed against:** `GRADING_REQUIREMENTS.md`
**Date:** 2026-04-21
**Reviewer:** Opus 4.7 (initial pass) + Codex adversarial challenge (2026-04-21)

> **Codex challenge corrections incorporated below.** Several initial claims were wrong — see `§3`, `§6`, `§7`, `§8` corrections, and the new **§ Internal Contradictions** section at the bottom. Codex session: `019dabdd-37be-77b0-8200-468b88aecf32`.

---

## Legend

| Status | Meaning |
|---|---|
| ✅ Present | Implementation AND report-ready documentation both exist |
| 🟡 Partial | Code/content exists but not compiled into a deliverable report section |
| ❌ Missing | Neither implementation nor report content found |

> **Critical distinction enforced throughout:** a pipeline that runs is NOT a report section. A markdown doc in `docs/architecture/` is NOT a compiled group report. Graders will read a submitted document — not grep a repo.

---

## 2026-04-22 Story-Aligned Integration Update

This gap review now has supporting implementation traceability:
- [TRACEABILITY_MATRIX.md](TRACEABILITY_MATRIX.md) maps current backend routes, frontend surfaces, verification artifacts, and grading sections back to the user stories and `AGENT_ARCHITECTURE.md`.
- [GRADING_EVIDENCE_CHECKLIST.md](GRADING_EVIDENCE_CHECKLIST.md) separates what is already implemented from what still needs report packaging.
- [SDK_ADOPTION_DECISION.md](SDK_ADOPTION_DECISION.md) records the current recommendation for `Streamdown`, `AI SDK`, `AI Elements`, `Workflow SDK`, and `Chat SDK`.

Important scope correction:
- The source of truth is `VerdictCouncil_Backend/docs/architecture/01-user-stories.md` plus `AGENT_ARCHITECTURE.md`, not the pre-existing frontend.
- The latest implementation pass improved intake metadata, case summary/detail contracts, pipeline ordering, dossier adapters, hearing-pack composition, escalation/reopen workflow normalization, dashboard truthfulness, and schema-aware frontend contract tests.
- Several workflow stories are still only partial and should remain described as such in any report: `US-001`, `US-002`, `US-003`, `US-010`, `US-015`, `US-020`, `US-021`, `US-026`, `US-027`, `US-029`, `US-031`, `US-033`, `US-035`, `US-037`, and `US-040`.
- Major unresolved gaps remain around rejection override (`US-004`), selective stage re-processing after supplementary uploads (`US-005`), source drill-down richness (`US-008`), traffic-only testimony details (`US-012`), suggested-question workflow completeness (`US-013`), live precedent search maturity (`US-016`), full admin ops (`US-032`, `US-034`), and amendment-of-record (`US-036`).

---

## Part A — Group Project Report

---

### §1 Executive Summary

**Status: ❌ Missing**

**Evidence found:** None. No file in either repo contains an executive summary, a project objective paragraph, key highlights, or constraints/assumptions in one place.

**Gap:** No compiled introductory section exists. The closest content is scattered across `README.md` (operational setup) and `docs/architecture_draft.md` (technical design). Neither is written as an executive summary for non-technical reviewers.

**Action required:** Write a 1–2 page executive summary stating the project objective (AI decision-support for Singapore lower courts), what was built, key architectural choices, and explicit constraints/assumptions (semester project scope, prototype vs production, OpenAI API dependency, Solace SAM not fully wired end-to-end).

---

### §2 System Overview

**Status: 🟡 Partial**

**Evidence found:**
- `docs/architecture/02-system-architecture.md` — 553-line architecture doc with agent pipeline description
- `docs/architecture/05-diagrams.md` — full sequence/data-flow diagram embedded as Mermaid in Markdown (not just raw source)
- `diagrams/verdictcouncil_use_case.svg` — use case diagram exists

> **Codex correction:** Initial claim that "the workflow diagram exists only as Mermaid source not embedded in any report" was wrong. `05-diagrams.md` embeds it in Markdown. The real gap is that it is still buried in a 553-line engineering doc, not surfaced as a standalone overview for a grader.

**Gap:** No single "description of how agents work together" narrative written for a lay/academic reader. The overview is buried in 553 lines of engineering detail — a grader should not need to hunt for it.

**Action required:** Extract the 9-agent pipeline summary and the sequence diagram from `05-diagrams.md` into a standalone 1-page system overview section of the group report.

---

### §3 System Architecture

**Status: 🟡 Partial**

**Evidence found:**
- `docs/architecture/02-system-architecture.md` — logical architecture (SAM layers, event broker, CaseState)
- `docs/architecture/04-tech-stack.md` — tech choices and justifications
- `docs/architecture/05-diagrams.md` — physical architecture diagram AND full sequence/data-flow diagram both present
- `k8s/` — K8s manifests defining physical infrastructure (DOKS, DOCR, Solace HA)
- `docs/architecture/06-cicd-pipeline.md` — deployment strategy and services
- `docker-compose.infra.yml` and `Dockerfile` — containerization

> **Codex correction:** Initial claim of "no physical architecture diagram" and "no data-flow diagram" was wrong. Both exist in `docs/architecture/05-diagrams.md`. However, Codex found the physical diagram is **internally inconsistent**: it shows PostgreSQL and Redis as in-cluster StatefulSets, while `06-cicd-pipeline.md` and `08-infrastructure-setup.md` correctly describe them as managed services outside the cluster. It also references an undefined `JUD` node. A grader reading both will notice.

**Gap:**
1. **Physical diagram is factually wrong** — contradicts the deployment docs on managed vs in-cluster services; contains undefined node `JUD`
2. **Content not compiled** into one document — split across 4+ files
3. **Internal contradiction in model names** — `architecture_draft.md` specifies `o3/o4-mini/gpt-4.1`; `04-tech-stack.md` and `config.py` specify `gpt-5.4/gpt-5/gpt-5.4-nano`. A grader will read this as sloppy documentation or fabricated specs.

**Action required:** Fix the physical architecture diagram (managed services outside cluster, remove undefined nodes). Reconcile model names across all documents. Consolidate into one section.

---

### §4 Agent Roles and Design

**Status: 🟡 Partial**

**Evidence found:**
- `docs/architecture_draft.md` — 9 agent specifications each with: purpose, system prompt, tools, state I/O, guardrails (strong content)
- `docs/architecture/03-agent-configurations.md` — production agent configs
- `configs/agents/*.yaml` — 9 YAML files, one per agent, with actual system prompts

**Gap:** This is the best-documented section in the codebase. However:
1. **Communication protocols and coordination mechanisms** — SAM topic structure is mentioned in `02-system-architecture.md` but not covered per-agent in the design docs
2. **Memory mechanisms** — "Planning and memory mechanisms" per rubric: CaseState shared state is described structurally but there is no per-agent explanation of what state each agent retains vs passes on
3. **Format:** Not presented as a report section with clear per-agent headers readable by a grader

**Action required:** Minor lift — reorganize agent specs from `architecture_draft.md` into §4 of the group report. Add 1–2 sentences per agent covering coordination mechanism (which topic it publishes to, what it triggers next).

---

### §5 Explainable and Responsible AI Practices

**Status: 🟡 Partial (weak partial)**

**Evidence found:**
- `docs/architecture/02-system-architecture.md §2.7` — Human-in-the-Loop design, audit trail, pipeline traceability
- `src/pipeline/guardrails.py` — fairness audit in governance-verdict agent, bias flag logic
- `src/components/analysis/FairnessAuditPanel.jsx` — frontend fairness audit UI
- `docs/architecture_draft.md` line 21 — "Preserve the explainable decision pipeline... traceable for the Responsible AI assessment criteria"

**Gap (critical):**
1. **IMDA Model AI Governance Framework** — explicitly named in the rubric — is **not referenced anywhere** in the codebase. Not a single file mentions IMDA, PDPC, or any Singapore-specific AI governance framework.
2. **Fairness, bias mitigation, explainability** — the *code* has a fairness audit agent, but there is no *written section* explaining the approach to fairness and bias mitigation as an AI practice
3. **Explainability** — the pipeline traceability is a design feature, but it is never framed as an explainability mechanism aligned to responsible AI principles
4. No document maps VerdictCouncil's features to specific responsible AI principles

**Action required:** Write a dedicated §5 section. Map the governance-verdict agent's fairness audit, the HITL requirement, the audit_log, and the confidence scoring to IMDA's Model AI Governance Framework principles explicitly. This is non-optional — IMDA is named in the rubric, and the NUS ISS context makes this a Singapore-specific expectation.

---

### §6 AI Security Risk Register

**Status: ❌ Missing (downgraded from Partial)**

**Evidence found:**
- `docs/architecture/02-system-architecture.md §2.7` — defense table and narrative covering 6+ mitigations (plan-then-execute, privilege separation, content isolation, input sanitization, output schema validation, SAM audit trail)
- `src/pipeline/guardrails.py` — 2-layer injection detection (regex + LLM)
- `src/shared/sanitization.py` — prompt injection pattern stripping

> **Codex correction:** Initial claim of "no table" was wrong — a defense table exists at `02-system-architecture.md:541`. However, Codex is correct that a **security-defense narrative is not an AI Security Risk Register**. The rubric asks for a formal risk register artifact with Risk ID, likelihood, impact, owner, and status columns. No such artifact exists anywhere. Downgraded to Missing.
>
> Additional Codex finding: The docs claim "payload hash broker auditability" (`02-system-architecture.md:531`) but `_solace_a2a_client.py` and `audit.py` contain no payload hashing or replay protection. This is a false security claim — a grader who reads both will flag it.

**Gap (critical):**
1. **No formal risk register table** — defenses exist in code and prose, but no artifact with Risk ID / Likelihood / Impact / Owner / Status
2. **Claimed audit trail not implemented** — payload hashing documented but absent from actual code; credibility risk
3. **Risks beyond injection not enumerated** — hallucination, adversarial evidence crafting, confidence score manipulation, session hijack absent from any register

**Action required:** Build a formal risk register table: `| Risk ID | Risk | Impact | Likelihood | Mitigation | Implementation Status |`. Minimum 8–10 AI-specific risks. Reconcile or remove the payload-hash claim if not implemented.

---

### §7 MLSecOps / LLMSecOps Pipeline

**Status: 🟡 Partial (very weak)**

**Evidence found:**
- `docs/architecture/06-cicd-pipeline.md` — CI/CD pipeline documented with GitHub Actions, DOKS deployment
- `.github/workflows/ci.yml` — lint, unit tests, OpenAPI snapshot, `bandit` SAST, `pip-audit` dependency scan, Docker build
- `.github/workflows/staging-deploy.yml` and `production-deploy.yml` — staging and production deploy
- `docs/architecture/08-infrastructure-setup.md` — monitoring and alerting documented
- `src/api/middleware/metrics.py` — Prometheus-style `/metrics` endpoint implemented
- K8s manifests — deployment, HPA, ingress, Solace HA

> **Codex correction:** Initial claim of "no monitoring/alerting documented" was wrong. `08-infrastructure-setup.md` documents monitoring and alerts, and `metrics.py` exposes a `/metrics` endpoint. However, Codex found a more serious problem: **the CI/CD documentation does not match the real workflows**. `06-cicd-pipeline.md` says CI only runs on `feat/*`, staging on `release/*`, mypy enforced, release creation, canary. The actual `.github/workflows/ci.yml`, `staging-deploy.yml`, and `production-deploy.yml` say otherwise. A grader comparing the doc to the repo will see the mismatch.

**Gap (critical):**
1. **CI/CD doc is materially inaccurate** — triggers, branches, steps, and canary described in `06-cicd-pipeline.md` do not match the actual workflow files. This makes the "partial" evidence unreliable.
2. **No AI-specific security tests in CI** — `bandit`/`pip-audit` are traditional SAST. No adversarial input, prompt injection resistance, or model output integrity tests exist in the CI pipeline
3. **No MLSecOps framing** — "MLSecOps"/"LLMSecOps" does not appear in any documentation
4. **Logging/auditability gap** — `audit_log` in CaseState exists but the claimed payload-hash broker audit trail is not implemented (see §6)

**Action required:** (1) Sync `06-cicd-pipeline.md` to match actual workflow files — do not describe CI gates that don't exist. (2) Add adversarial input tests to the actual CI pipeline. (3) Write a diagram framed explicitly as LLMSecOps, mapping each stage to its AI security function. (4) Point the monitoring section at the live `/metrics` endpoint.

---

### §8 Testing Summary

**Status: 🟡 Partial**

**Evidence found:**
- `tests/unit/` — 40+ unit tests across all tools, agents, pipeline, sanitization, rate limiting, circuit breaker, etc.
- `tests/unit/test_sanitization.py` — prompt-injection handling tests (weak but real — not zero)
- `tests/integration/` — 3 integration tests
- `tests/eval/` — eval runner with gold-set fixtures
- `VerdictCouncil_Frontend/src/__tests__/` — 17 frontend tests
- CI runs `pytest --cov=src --cov-report=term-missing`

> **Codex correction:** Initial claim of "no AI security tests" was wrong. `test_sanitization.py` is explicitly prompt-injection coverage. Coverage is weak but not zero. However, Codex found the integration tests are weaker than stated: one test in `test_halt_conditions.py` is a placeholder skip, and the SAM mesh smoke test (`test_sam_mesh_smoke.py`) is explicitly excluded from default CI. The "3 integration tests" claim overstates what actually runs.

**Gap:**
1. **No compiled testing summary document** — results not summarized anywhere
2. **AI security test coverage is thin** — `test_sanitization.py` exists but covers only the sanitization layer; no tests for adversarial inputs flowing through full agent pipeline, malformed tool responses, or fairness check bypass
3. **Integration tests don't run in CI** — halt conditions test is a placeholder skip; mesh smoke test requires live Solace broker and is explicitly excluded
4. **Frontend test results** — `.vitest-coverage.json` exists but not summarized

**Action required:** Write a testing summary covering: all test types, count, coverage %, and honest statement of what runs in CI vs what is excluded. Expand AI security tests beyond sanitization layer to cover the full pipeline boundary.

---

### §9 Reflection

**Status: ❌ Missing**

**Evidence found:** Nothing. No reflection content anywhere in the repo.

**Gap:** The rubric requires a team-level reflection. Not a word exists.

**Action required:** Write a reflection covering: what went well, what was harder than expected (SAM not fully wired, frontend-backend integration gap noted in `specs/cross-repo-gap-2026-04.md`), what the team would do differently, and lessons learned from building a multi-agent system for a high-stakes domain.

---

## Part B — Individual Project Reports

> The Individual Report is **per person per agent**. With 9 agents, the team needs to assign ownership. Each individual writes about the specific agent they built.

---

### Individual §1 Introduction

**Status: ❌ Missing (downgraded from Partial)**

> **Codex correction:** Shared architecture notes in `architecture_draft.md` are not individual reports. The rubric is per-person deliverables. Downgraded.

---

### Individual §2 Agent Design

**Status: ❌ Missing (downgraded from Partial)**

> **Codex correction:** Same reasoning — shared YAML configs and architecture docs are not an individual's report section.

`architecture_draft.md` covers: role, system prompt, tools, state I/O, guardrails. Missing per individual report:
- **Fallback strategies** — the YAML configs define agents but fallback logic (what happens if the agent fails or produces unexpected output) is handled by the runner generically, not documented per-agent
- **Prompt engineering patterns** — system prompts exist in YAML but the design rationale (why this prompt structure, what alternatives were tried) is absent

---

### Individual §3 Implementation Details

**Status: ❌ Missing**

**Gap:** No individual has written a per-agent implementation writeup. Code exists (`src/pipeline/runner.py`, `configs/agents/*.yaml`, `src/tools/`) but no individual document covers:
- Summary of implementation approach (per agent)
- Code structure overview (per agent)
- Tech stack decision rationale (why o3 vs gpt-5.4 for that agent, why that specific tool)

---

### Individual §4 Testing and Validation

**Status: ❌ Missing (downgraded from Partial)**

> **Codex correction:** No per-individual test writeup exists. Shared unit tests in `tests/unit/` are not an individual's testing section. `test_sanitization.py` exists for the sanitization layer but is not attributed to an individual and doesn't cover the full agent-level test story the rubric requires.

---

### Individual §5 Explainable and Responsible AI Considerations

**Status: ❌ Missing**

**Gap:** No per-agent explainability documentation exists. The rubric requires:
- How this specific agent addresses explainability
- Bias mitigation strategies for this agent
- Handling sensitive content and governance alignment

The governance-verdict agent has the most content here (fairness audit), but even for that agent, no individual report section exists.

---

### Individual §6 Security Practices

**Status: ❌ Missing (downgraded from Partial)**

> **Codex correction:** `guardrails.py` is shared pipeline infrastructure, not an individual's agent-specific security writeup. Downgraded.

---

### Individual §7 Reflection

**Status: ❌ Missing**

Nothing. Per rubric: personal learning + suggestions for improvement per agent.

---

## Summary Scorecard

*Codex challenge corrections applied 2026-04-21. Downgrades marked with ▼.*

| Section | Status | Severity |
|---|---|---|
| Group §1 Executive Summary | ❌ Missing | High — grader sees nothing without this |
| Group §2 System Overview | 🟡 Partial | Medium — content buried in 553-line doc |
| Group §3 System Architecture | 🟡 Partial | **High — diagram exists but is factually wrong; model name contradiction** |
| Group §4 Agent Roles and Design | 🟡 Partial | Low — strongest section, needs reformatting |
| Group §5 Responsible AI | 🟡 Partial (weak) | **Critical — IMDA not mentioned; privacy/retention/access controls absent** |
| Group §6 AI Security Risk Register | ❌ Missing ▼ | **Critical — no formal register; false payload-hash claim in docs** |
| Group §7 MLSecOps/LLMSecOps | 🟡 Partial (very weak) | **Critical — CI/CD doc contradicts real workflows; no AI security tests in CI** |
| Group §8 Testing Summary | 🟡 Partial | High — integration tests don't actually run in CI; no compiled summary |
| Group §9 Reflection | ❌ Missing | High — nothing exists |
| Individual §1 Introduction | ❌ Missing ▼ | High — shared docs are not individual reports |
| Individual §2 Agent Design | ❌ Missing ▼ | High — shared docs are not individual reports |
| Individual §3 Implementation Details | ❌ Missing | High — zero individual writeups |
| Individual §4 Testing & Validation | ❌ Missing ▼ | High — no per-individual test section |
| Individual §5 Explainable AI | ❌ Missing | **Critical — zero content per agent** |
| Individual §6 Security Practices | ❌ Missing ▼ | High — shared guardrails ≠ individual section |
| Individual §7 Reflection | ❌ Missing | High — nothing exists |

---

---

## Internal Contradictions — New Section from Codex Challenge

These were not identified in the initial gap analysis. A grader who reads the repo carefully will find them. Each one is a credibility risk independent of the report format.

| Contradiction | File A (claim) | File B (reality) | Risk |
|---|---|---|---|
| **Model names** | `architecture_draft.md` specifies `o3`, `o4-mini`, `gpt-4.1` | `04-tech-stack.md` and `config.py` specify `gpt-5.4`, `gpt-5-mini`, `gpt-5.4-nano` | Grader reads as fabricated or stale specs |
| **CI/CD triggers** | `06-cicd-pipeline.md` says CI only on `feat/*`, staging on `release/*`, mypy enforced, canary | Actual `.github/workflows/ci.yml`, `staging-deploy.yml`, `production-deploy.yml` say otherwise | Documented pipeline ≠ actual pipeline |
| **Physical infra diagram** | `05-diagrams.md` shows PostgreSQL/Redis as in-cluster StatefulSets; contains undefined `JUD` node | `06-cicd-pipeline.md` and `08-infrastructure-setup.md` describe them as DO managed services | Wrong diagram presented as physical architecture |
| **Payload-hash audit trail** | `02-system-architecture.md:531` claims "payload hash" broker auditability | `_solace_a2a_client.py` and `audit.py` contain no payload hashing or replay protection | False security claim |
| **Legal source coverage** | Project claims to support Singapore lower courts (SCT + Traffic) | `04-tech-stack.md` admits live precedent source does not cover SCT or lower State Courts | Undercuts the entire project premise |

**Action required:** Resolve each contradiction before submitting. Either fix the docs to match reality, fix the code to match the docs, or explicitly acknowledge the gap as a known limitation.

---

## Priority Order for Remediation

1. **Fix internal contradictions first** — model names, CI/CD doc vs actual workflows, physical diagram errors, payload-hash claim, legal source coverage. These are credibility killers that undermine everything else.
2. **Write the group report document** — a single compiled document (not a collection of engineering notes) that a grader can read cover-to-cover
3. **IMDA alignment (§5)** — mention by name, map 3–5 principles explicitly to system features; also address privacy, retention, access controls (broader than just IMDA)
4. **AI Security Risk Register (§6)** — build the formal table, minimum 8 risks; remove or implement the payload-hash claim
5. **Sync CI/CD doc to reality (§7)** — then add adversarial input tests; frame as LLMSecOps
6. **Reflection sections (§9 + Individual §7)** — completely absent, zero-effort fix
7. **Individual reports** — every individual section is now Missing; each team member writes one per their assigned agent
8. **Testing summary (§8)** — compile numbers honestly, including what does NOT run in CI

---

## MLflow & Tooling Research (§7 / §8)

A full investigation into whether MLflow and related tools can close the §7 MLSecOps and §8 Testing gaps has been documented separately.

**See: [MLFLOW_RESEARCH.md](./MLFLOW_RESEARCH.md)**

### Summary of findings

| Tool | §7 MLSecOps | §8 Testing | Effort |
|---|---|---|---|
| `mlflow.openai.autolog()` | Auditability + versioning | — | **1 line, ~1 hour** |
| `mlflow.evaluate()` in CI | Automated quality tests | Adds LLM eval category | 4–6 hours |
| Pytest adversarial tests (no new tooling) | AI security tests | Injection coverage | 2–3 hours |
| Giskard (OSS) | OWASP LLM Top 10 scans | Auto-generates injection payloads | 4–6 hours |

**Recommended minimum (Tier 1, ~3 hours):**
1. Add `mlflow.openai.autolog()` to `runner.py` — real audit trail in 1 line
2. Write 3–5 pytest adversarial tests against `guardrails.py` / `sanitization.py`
3. Reframe `docs/architecture/06-cicd-pipeline.md` as an LLMSecOps pipeline document

**Critical caveat:** MLflow does not close §5 (IMDA mapping), §6 (risk register table), §9 (reflection), or the individual reports. Those remain documentation tasks. Spend remaining time on report writing first; MLflow tooling second.

---

*This document was generated by reviewing all files in `VerdictCouncil_Backend/` and `VerdictCouncil_Frontend/` as of 2026-04-21. The cross-repo gap spec dated 2026-04-09 (`specs/cross-repo-gap-2026-04.md`) was treated as potentially stale for implementation claims (commits landed since); documentation gaps were verified against current file state.*
