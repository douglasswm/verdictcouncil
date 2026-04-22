# VerdictCouncil Grading Evidence Checklist

Updated: 2026-04-22 (second pass)

This checklist is meant to keep the grading package honest. It distinguishes between:
- implementation evidence that already exists in the repos
- report packaging that still needs to be written for submission

Primary implementation traceability lives in [TRACEABILITY_MATRIX.md](TRACEABILITY_MATRIX.md).

## Group Report

| Section | Current status | Repo evidence already available | What still needs to be packaged for grading |
|---|---|---|---|
| `§1 Executive Summary` | ✅ Done | `EXECUTIVE_SUMMARY.md` | — |
| `§2 System Overview` | Partial | `AGENT_ARCHITECTURE.md`, `VerdictCouncil_Backend/docs/architecture/01-user-stories.md`, `TRACEABILITY_MATRIX.md` | create a short grader-facing workflow overview and include the 9-agent pipeline diagram |
| `§3 System Architecture` | Partial | `VerdictCouncil_Backend/docs/architecture/02-system-architecture.md`, `05-diagrams.md`, `06-cicd-pipeline.md` | reconcile physical diagram/doc mismatches and extract one clean architecture section |
| `§4 Agent Roles and Design` | Partial | `VerdictCouncil_Backend/docs/architecture_draft.md`, `VerdictCouncil_Backend/configs/agents/*.yaml`, `AGENT_ARCHITECTURE.md` | reorganize into report-ready per-agent subsections with coordination/memory notes |
| `§5 Explainable and Responsible AI Practices` | ✅ Done | `RESPONSIBLE_AI_SECTION.md` — maps to all 4 IMDA pillars with code citations | — |
| `§6 AI Security Risk Register` | ✅ Done | `SECURITY_RISK_REGISTER.md` — 16 risks, 9-column table with evidence and residual risk | — |
| `§7 MLSecOps / LLMSecOps Pipeline` | ✅ Done | `MLSECOPS_SECTION.md` — CI/CD structure, LLM security gates, MLflow tracing, audit trail | — |
| `§8 Testing Summary` | ✅ Done | `TESTING_SUMMARY.md` — 385 tests, 71% coverage, security test detail, exclusions | — |
| `§9 Reflection` | ✅ Done | `REFLECTION_SECTION.md` — 5 learnings, 6 challenges, 3-tier future improvements | — |

## Individual Report

| Section | Current status | Repo evidence already available | What still needs to be packaged for grading |
|---|---|---|---|
| `§1 Introduction` | Missing | shared agent docs only | each owner needs a per-agent introduction |
| `§2 Agent Design` | Missing | shared YAML prompts and architecture notes | convert shared material into agent-specific design writeups |
| `§3 Implementation Details` | Missing | code under `VerdictCouncil_Backend/src/` and `configs/agents/` | each owner needs a code-structure and stack rationale section |
| `§4 Testing and Validation` | Missing | unit and integration tests exist at repo level | each owner needs to claim and explain the tests relevant to their agent |
| `§5 Explainable and Responsible AI Considerations` | Missing | governance-verdict and audit features exist in shared code | each owner needs agent-specific explainability / bias / sensitive-content notes |
| `§6 Security Practices` | Missing | sanitization, guardrails, RBAC, audit logs exist | each owner needs agent-specific risk and mitigation content |
| `§7 Reflection` | Missing | no individual reflection artifact yet | each owner needs a personal reflection |

## Verification Snapshot For This Remediation Pass

- Backend: `./.venv/bin/ruff check src tests`
- Backend: `./.venv/bin/pytest tests/unit/test_cases.py tests/unit/test_persist_case_results.py tests/unit/test_decisions.py tests/unit/test_escalation.py -q`
- Frontend: `npm run lint`
- Frontend: `npm test`
- Frontend: `npm run build`
- Frontend: `npm run check:contract`

## Submission Risks To Keep Visible

- Do not present partial workflow coverage as full story completion; use the status labels from `TRACEABILITY_MATRIX.md`.
- Do not let the frontend become the implied source of truth in the report; cite the user stories and the 9-agent architecture first.
- Do not claim amendment-of-record support (`US-036`) or full senior-inbox action coverage until the backend exposes those workflows end-to-end.
