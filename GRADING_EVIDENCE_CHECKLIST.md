# VerdictCouncil Grading Evidence Checklist

Updated: 2026-04-22

This checklist is meant to keep the grading package honest. It distinguishes between:
- implementation evidence that already exists in the repos
- report packaging that still needs to be written for submission

Primary implementation traceability lives in [TRACEABILITY_MATRIX.md](TRACEABILITY_MATRIX.md).

## Group Report

| Section | Current status | Repo evidence already available | What still needs to be packaged for grading |
|---|---|---|---|
| `§1 Executive Summary` | Missing | product intent in `VerdictCouncil_Backend/README.md` and architecture docs | write a 1-2 page executive summary with scope, outcomes, and constraints |
| `§2 System Overview` | Partial | `AGENT_ARCHITECTURE.md`, `VerdictCouncil_Backend/docs/architecture/01-user-stories.md`, `TRACEABILITY_MATRIX.md` | create a short grader-facing workflow overview and include the 9-agent pipeline diagram |
| `§3 System Architecture` | Partial | `VerdictCouncil_Backend/docs/architecture/02-system-architecture.md`, `05-diagrams.md`, `06-cicd-pipeline.md` | reconcile physical diagram/doc mismatches and extract one clean architecture section |
| `§4 Agent Roles and Design` | Partial | `VerdictCouncil_Backend/docs/architecture_draft.md`, `VerdictCouncil_Backend/configs/agents/*.yaml`, `AGENT_ARCHITECTURE.md` | reorganize into report-ready per-agent subsections with coordination/memory notes |
| `§5 Explainable and Responsible AI Practices` | Partial | fairness audit surfaces in verdict/dossier flow, `VerdictCouncil_Backend/src/pipeline/guardrails.py`, `US-023` traceability rows | explicitly map current explainability/fairness controls to an AI governance framework such as IMDA |
| `§6 AI Security Risk Register` | Missing | sanitization and guardrail code exists, but no formal register artifact | write the risk register table with likelihood, impact, mitigation, owner, and implementation status |
| `§7 MLSecOps / LLMSecOps Pipeline` | Partial | `.github/workflows/*`, backend metrics middleware, deployment docs | sync CI/CD docs to reality and add AI-specific testing / auditability framing |
| `§8 Testing Summary` | Partial | backend tests, frontend tests, `npm run check:contract`, current verification results in task trackers | compile one testing summary with scope, counts, pass/fail status, and excluded tests |
| `§9 Reflection` | Missing | lessons and review notes exist in task trackers | write the team reflection narrative |

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
