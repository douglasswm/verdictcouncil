# VerdictCouncil Story Traceability Matrix

Updated: 2026-04-22

Source of truth for this matrix:
- `VerdictCouncil_Backend/docs/architecture/01-user-stories.md`
- `/Users/douglasswm/Project/AAS/VER/AGENT_ARCHITECTURE.md`

Status legend:
- `Implemented`: routed through the current backend contract, surfaced in the frontend, and covered by at least one concrete verification artifact.
- `Partial`: some story-critical behavior is present, but one or more acceptance criteria still depend on missing backend workflow, richer agent output, or additional UI work.

Stories not listed below remain outside the current implementation pass or are still materially incomplete: `US-004`, `US-005`, `US-008`, `US-012`, `US-013`, `US-016`, `US-032`, `US-034`, `US-036`.

## Intake And Pipeline

| Story | Status | Backend contract | Frontend surface | Verification artifact | Grading section |
|---|---|---|---|---|---|
| `US-001 Upload New Case` | Partial | `POST /api/v1/cases/`, `POST /api/v1/cases/{case_id}/process` | `VerdictCouncil_Frontend/src/pages/cases/CaseIntake.jsx` | `VerdictCouncil_Backend/tests/unit/test_cases.py`, `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js` | `§2`, `§8` |
| `US-002 View Document Processing Status` | Partial | `GET /api/v1/cases/{case_id}/status`, `GET /api/v1/cases/{case_id}/status/stream` | `VerdictCouncil_Frontend/src/pages/cases/CaseDetail.jsx`, `VerdictCouncil_Frontend/src/lib/pipelineStatus.js` | `VerdictCouncil_Frontend/src/__tests__/pipelineStatus.test.js`, `VerdictCouncil_Frontend/src/__tests__/api.test.js` | `§2`, `§8` |
| `US-003 Receive Jurisdiction Validation Result` | Partial | `GET /api/v1/cases/`, `GET /api/v1/cases/{id}` | `VerdictCouncil_Frontend/src/pages/cases/CaseList.jsx`, `VerdictCouncil_Frontend/src/pages/cases/CaseDetail.jsx` | `VerdictCouncil_Backend/tests/unit/test_cases.py`, `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§4`, `§8` |
| `US-028 Search and Filter Cases` | Implemented | `GET /api/v1/cases/` | `VerdictCouncil_Frontend/src/pages/cases/CaseList.jsx` | `VerdictCouncil_Frontend/src/__tests__/api.test.js`, `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js` | `§2`, `§8` |
| `US-029 View Dashboard Overview` | Partial | `GET /api/v1/dashboard/stats` | `VerdictCouncil_Frontend/src/pages/Dashboard.jsx` | `VerdictCouncil_Frontend/src/__tests__/api.test.js`, `npm run build` | `§2`, `§3`, `§8` |
| `US-030 Manage Session and Authentication` | Implemented | `/api/v1/auth/*` session, login, logout, extend, reset routes | `VerdictCouncil_Frontend/src/contexts/AuthContext.jsx`, guarded routes in `src/App.jsx` | `VerdictCouncil_Frontend/src/__tests__/api.test.js` | `§3`, `§8` |

## Dossier And Decision Support

| Story | Status | Backend contract | Frontend surface | Verification artifact | Grading section |
|---|---|---|---|---|---|
| `US-006 Review Evidence Analysis Dashboard` | Implemented | `GET /api/v1/cases/{case_id}/evidence` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-007 View Fact Timeline` | Implemented | `GET /api/v1/cases/{case_id}/timeline` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-009 Flag Disputed Facts` | Partial | `GET /api/v1/cases/{case_id}/timeline`, `GET /api/v1/cases/{id}` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-010 Review Evidence Gaps` | Partial | `GET /api/v1/cases/{case_id}/evidence-gaps`, `GET /api/v1/cases/{case_id}/hearing-pack` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx`, `VerdictCouncil_Frontend/src/pages/judge/HearingPack.jsx` | `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js` | `§2`, `§8` |
| `US-011 Review Witness Profiles and Credibility Scores` | Implemented | `GET /api/v1/cases/{case_id}/witnesses` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-014 Review Applicable Statutes` | Implemented | `GET /api/v1/cases/{case_id}/statutes` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-015 Review Precedent Cases` | Partial | `GET /api/v1/cases/{case_id}/precedents` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js`, `npm run build` | `§2`, `§8` |
| `US-017 View Knowledge Base Status` | Implemented | `GET /api/v1/knowledge-base/status` | `VerdictCouncil_Frontend/src/pages/judge/KnowledgeBase.jsx` | `VerdictCouncil_Frontend/src/__tests__/KnowledgeBase.test.jsx`, `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js` | `§3`, `§8` |
| `US-018 Review Both Sides' Arguments` | Implemented | `GET /api/v1/cases/{case_id}/arguments` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§8` |
| `US-019 Review Deliberation Reasoning Chain` | Implemented | `GET /api/v1/cases/{case_id}/deliberation` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§5`, `§8` |
| `US-020 Prepare Hearing Pack` | Partial | `GET /api/v1/cases/{case_id}/hearing-pack`, `GET /api/v1/cases/{case_id}/hearing-pack/export` | `VerdictCouncil_Frontend/src/pages/judge/HearingPack.jsx` | `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js`, `npm run build` | `§2`, `§8` |
| `US-021 Compare Alternative Outcomes` | Partial | `GET /api/v1/cases/{case_id}/verdict` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§5`, `§8` |
| `US-022 Review Verdict Recommendation` | Implemented | `GET /api/v1/cases/{case_id}/verdict` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Backend/tests/unit/test_decisions.py`, `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§2`, `§5`, `§8` |
| `US-023 Review Fairness and Bias Audit` | Implemented | `GET /api/v1/cases/{case_id}/fairness-audit`, verdict payload fairness fields | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Frontend/src/__tests__/caseWorkspace.test.js` | `§5`, `§8` |
| `US-025 Record Judicial Decision` | Implemented | `POST /api/v1/cases/{case_id}/decision` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Backend/tests/unit/test_decisions.py`, `VerdictCouncil_Frontend/src/__tests__/api.test.js` | `§2`, `§8` |
| `US-026 View Full Audit Trail` | Partial | audit-log data embedded in `GET /api/v1/cases/{id}` | `VerdictCouncil_Frontend/src/pages/analysis/CaseDossier.jsx` | `VerdictCouncil_Backend/tests/unit/test_cases.py` | `§5`, `§8` |
| `US-027 Export Case Report` | Partial | `GET /api/v1/cases/{case_id}/export`, `GET /api/v1/cases/{case_id}/hearing-pack/export` | export actions from dossier / hearing pack | `npm run build`, backend export route smoke during local review | `§2`, `§8` |
| `US-035 Take In-Hearing Notes` | Partial | hearing-pack response plus hearing-note endpoints | `VerdictCouncil_Frontend/src/pages/judge/HearingPack.jsx` | `npm run build` | `§2`, `§8` |

## Workflow And Ops

| Story | Status | Backend contract | Frontend surface | Verification artifact | Grading section |
|---|---|---|---|---|---|
| `US-024 Handle Escalated Cases` | Implemented | `GET /api/v1/escalated-cases/`, `POST /api/v1/escalated-cases/{case_id}/action` | `VerdictCouncil_Frontend/src/pages/escalation/EscalatedCases.jsx`, `src/components/escalation/EscalationDetailView.jsx` | `VerdictCouncil_Backend/tests/unit/test_escalation.py`, `VerdictCouncil_Frontend/src/__tests__/escalationActions.test.jsx` | `§2`, `§8` |
| `US-031 Refresh / Re-index Vector Stores` | Partial | admin vector-store refresh routes plus judge-visible status route | `VerdictCouncil_Frontend/src/pages/judge/KnowledgeBase.jsx` | `VerdictCouncil_Frontend/src/__tests__/api.test.js`, `VerdictCouncil_Frontend/src/__tests__/KnowledgeBase.test.jsx` | `§3`, `§7`, `§8` |
| `US-033 Manage User Accounts and Roles` | Partial | admin user-management routes | admin settings surfaces | `VerdictCouncil_Frontend/src/__tests__/api.test.js` | `§3`, `§7`, `§8` |
| `US-037 Reopen a Closed Case` | Partial | reopen-request list/create/review routes | `VerdictCouncil_Frontend/src/components/cases/CaseExceptionPanel.jsx`, `VerdictCouncil_Frontend/src/pages/senior/SeniorJudgeInbox.jsx` | `VerdictCouncil_Frontend/src/__tests__/escalationActions.test.jsx` | `§2`, `§8` |
| `US-040 Senior Judge - Review Referred Cases` | Partial | `GET /api/v1/senior-inbox`, reopen review routes, escalation actions | `VerdictCouncil_Frontend/src/pages/senior/SeniorJudgeInbox.jsx` | `VerdictCouncil_Frontend/src/__tests__/escalationActions.test.jsx`, `VerdictCouncil_Frontend/src/__tests__/backendSchemaContract.test.js` | `§2`, `§8` |

## Current High-Risk Residual Gaps

- `US-001` still lacks fully automatic "upload-and-immediately-run" behavior in one confirmed end-to-end flow.
- `US-003` jurisdiction logic does not yet prove all date-based limitation checks described in the story.
- `US-004`, `US-005`, and `US-036` remain major workflow gaps and should not be represented as complete.
- `US-040` inbox metadata is now standardized, but reassign / request-more-info actions are still missing.
- `AGENT_ARCHITECTURE.md` still identifies larger orchestration risks outside this UI-contract pass, especially durable job execution and full replay / resume semantics.
