# VerdictCouncil: Systems & Gap Analysis

**Date:** 2026-04-14  
**Scope:** Full codebase review — architecture spec, backend, frontend  
**Repos reviewed:** `VerdictCouncil_Backend` (development), `VerdictCouncil_Frontend` (development)

---

## Product Understanding

**VerdictCouncil is a judge's personal workspace** — not an institutional court system. Judges self-serve: they upload their own case materials, run AI analysis, build personal knowledge bases, and review verdict recommendations. No clerks, no CMS integration, no multi-role workflows.

**Confirmed decisions:**
- 9 consolidated agents (intentional, not deferred)
- Solace Agent Mesh (OSS framework only, not Solace platform)
- Per-judge private knowledge base via OpenAI vector store + retrieval API
- PAIR API for live Singapore rulings access
- DigitalOcean DOKS (managed Kubernetes) for deployment
- Frontend is production-bound, not a throwaway demo

---

## What Exists

### Architecture Spec (49K words)
18-agent design across two legal domains (SCT inquisitorial, Traffic adversarial). Shared CaseState TypedDict. Tool registry. Fairness/bias checkpoint. Human-in-the-loop at verdict. Comprehensive security model for adversarial document ingestion.

### Backend (Python 3.12 / FastAPI)
- **9 agents** configured via YAML + Solace Agent Mesh + `PipelineRunner` for local validation
- **11 API route modules:** auth, cases, decisions, what-if scenarios, judge tools (fact disputes, evidence gaps, fairness audit), audit, dashboard, health, precedent search, knowledge base, escalation
- **Full ORM:** Cases, Parties, Documents, Evidence, Facts, Witnesses, LegalRules, Precedents, Arguments, Deliberation, Verdicts, AuditLogs, WhatIfScenarios
- **Tools:** document parsing (OpenAI Files API), cross-reference, timeline construction, question generation, precedent search (PAIR API + vector fallback), confidence calculation
- **Infrastructure:** Layer2 fan-in aggregator for parallel agents, circuit breaker on PAIR API, Redis, PostgreSQL (async via asyncpg)
- **Deployment:** Dockerfile (multi-stage), docker-compose (Postgres/Redis/Solace), K8s manifests (9 agent deployments + API + infra), staging/prod overlays
- **Testing:** 37 test files (unit + integration), factory fixtures, pytest-asyncio
- **Auth:** JWT in httpOnly cookies, bcrypt, 3 roles (clerk/judge/admin)
- **Version:** 0.1.0

### Frontend (React 18.3.1 / Vite)
- **11+ pages:** Dashboard, Case Intake, Case List, Case Detail, Case Dossier, Graph Mesh, Building Simulation, What-If Mode, Senior Judge Inbox, Admin Panel, Hearing Pack, NotFound
- **3 context providers:** AuthContext, APIContext, CaseContext — global auth, API access, and case state
- **Full API client** (`src/lib/api.js`): 30+ endpoints covering auth, cases, pipeline, SSE streaming, decisions, what-if, audit, judge tools, knowledge base, precedent search
- **Real backend integration:** login/session management, case creation via POST, SSE for pipeline progress, all active pages call real endpoints
- **Auth flow:** JWT httpOnly cookie, login page, protected routes, 401 auto-redirect
- **Pixel art building simulation** (Pixi.js, `FloorPixelMap.jsx`) — complete but orphaned from router (wiring is Phase 2)
- **Legacy pages** from original demo still present (root of `pages/`) — to be ported and deleted in Phase 6

---

## Architectural Gaps

### 1. Auth Model — Single-Judge Workspace

**Decision made (2026-04-14):** Simplify to single-judge workspace. Remove multi-role scaffolding (clerk/admin), keep escalation endpoints (they handle pipeline-triggered halts, not institutional hierarchy).

**Remaining gaps (Phase 3):**
- Session token revocation not enforced — revoked sessions remain valid until JWT expiry (P1 fix)
- Ownership checks inconsistent — `get_case` blocks wrong roles but decision/dispute/escalation handlers do no tenant check
- Route prefix `/escalated-cases/` should be renamed to `/cases/escalated/`
- Frontend: AdminPanel and SeniorJudgeInbox pages need to be removed/renamed

**Impact:** Auth simplification unblocks per-judge data isolation implementation.

---

### 2. Judge's Personal Knowledge Base Has Zero Implementation

**Finding:** The feature that differentiates VerdictCouncil from a generic legal AI tool — a per-judge private knowledge base using OpenAI vector store + retrieval API — does not exist in any layer.

**What's needed:**
- Backend service with API endpoints for KB management (upload, list, search, delete documents)
- OpenAI vector store integration (one store per judge)
- CRUD for the judge to manage their corpus (add/remove documents, search, tag)
- Integration with the `legal-knowledge` agent so it queries both PAIR API and the judge's personal store
- Frontend UI for knowledge base management

**Current state:** The backend has a `/knowledge-base/status` health endpoint and a `vector_store_fallback.py` file, but no actual vector store, no per-judge storage, no document ingestion pipeline for the KB.

**Impact:** Missing core differentiator. Without this, VerdictCouncil is just a pipeline that calls PAIR — no personalization, no accumulated judicial knowledge.

---

### 3. Frontend ↔ Backend Integration

**Status: CORRECTED (2026-04-14)** — The original finding was based on the legacy `development` branch. The refactored frontend (`feat/dev-run-experience`) has full API integration.

**What exists now:**
- `src/lib/api.js`: 30+ endpoint wrappers using `fetch`, covering auth, cases, pipeline, decisions, what-if, audit, knowledge base, precedent search
- Auth flow: login → JWT httpOnly cookie → authenticated requests, 401 auto-redirect
- Case creation, list, and detail all call real backend endpoints
- SSE streaming via `api.streamPipelineStatus()` for real-time pipeline updates

**Remaining gaps (as of Phase 0):**
- `GET /api/v1/cases/:caseId/status` does not exist in backend — frontend calls it and gets 404 (Phase 1)
- `POST /cases/{case_id}/run` (pipeline trigger) does not exist — no way to start pipeline on a submitted case (Phase 1)
- Building simulation page (`/case/:caseId/building`) not wired into router (Phase 2)

**Impact:** Core integration exists. Unblocking execution requires Phase 1 backend endpoints.

---

### 4. Domain Routing (SCT vs Traffic) Not Implemented

**Finding:** The spec's key architectural feature — SCT uses Balanced Assessment (one impartial analysis) while Traffic uses parallel Claim/Defense Advocates with fan-out/fan-in — is not reflected in the pipeline.

**Current state:** The `argument-construction` agent is a single agent that doesn't branch by domain. The Layer2 aggregator handles fan-in for evidence/fact/witness but not for prosecution/defense advocates. The `case-processing` agent sets the domain field but nothing downstream uses it to alter pipeline topology.

**Impact:** One of the two legal domains gets incorrect reasoning structure. SCT cases would get adversarial analysis where they should get balanced, or Traffic cases would get balanced analysis where they should get adversarial.

---

### 5. Document Ingestion Pipeline Missing End-to-End

**Finding:** `parse_document` tool wraps OpenAI Files API for text extraction. But there's no end-to-end flow: judge uploads PDF → backend receives file → parses text → creates structured Evidence/Fact/Witness records → links to Case.

**Current state:** The frontend generates file metadata and folder structures (`buildCasePackage()`) but never sends files to the backend. The backend has file-related models (Document, Evidence) but no upload endpoint that processes files into these models.

**Impact:** Can't process real cases. The pipeline has no input.

---

### 6. LLM Model Names

**Status: RESOLVED (2026-04-14)** — Updated to real OpenAI model IDs.

| Config Tier | Previous (hypothetical) | Updated |
|---|---|---|
| `openai_model_lightweight` | `gpt-5.4-nano` | `gpt-4.1-nano` |
| `openai_model_efficient_reasoning` | `gpt-5-mini` | `gpt-4.1-mini` |
| `openai_model_strong_reasoning` | `gpt-5` | `gpt-4.1` |
| `openai_model_frontier_reasoning` | `gpt-5.4` | `gpt-4.1` |

Updated in `src/shared/config.py` defaults. YAML anchors in `configs/shared_config.yaml` use `${OPENAI_MODEL_*}` env vars and inherit the new defaults.

---

### 7. Real-Time Pipeline Updates

**Status: PARTIALLY CORRECTED (2026-04-14)** — The original finding was based on the legacy frontend. The refactored frontend has SSE client infrastructure.

**What exists now:**
- `api.js` includes `streamPipelineStatus(caseId)` using `EventSource` / SSE
- `BuildingSimulation.jsx` (refactored) designed to consume this stream with polling fallback

**Remaining gap:**
- Backend `GET /cases/{case_id}/status/stream` SSE endpoint does not exist yet (Phase 1)
- No Redis pub/sub fan-out channel yet (Phase 1)

**Impact:** SSE plumbing is in place on the frontend. Unblocked once Phase 1 backend endpoint ships.

---

### 8. Adversarial Document Injection Risk

**Finding:** Judges upload documents from opposing parties (claimant submissions, defense filings). A party could craft PDF content with prompt injection that flows into LLM context via `parse_document`. The spec describes defenses:
- Plan-then-execute pattern (orchestrator determines plan before processing untrusted content)
- Privilege separation (agents processing untrusted content have no write access to execution plan)
- Content isolation (raw documents never passed directly into system prompts)
- Output validation (all agent outputs validated against JSON schema)

**Current state:** None of these defenses are implemented. The `sanitization.py` utility exists but does basic text cleaning, not prompt injection defense.

**Impact:** A manipulated verdict recommendation in a judicial system could cause real harm. This must be addressed before production.

---

### 9. Frontend Architecture

**Status: CORRECTED (2026-04-14)** — The original finding was based on the legacy `development` branch. The refactored frontend has resolved this.

**What exists now:**
- `App.jsx` is 113 lines — routing scaffold only
- 3 context providers: `AuthContext`, `APIContext`, `CaseContext`
- Custom hooks in `src/hooks/index.js`
- Domain logic distributed across page components and contexts

**Remaining gaps:**
- Legacy `App.jsx` (850-line version) still exists on `development` branch — to be replaced when `feat/dev-run-experience` merges
- Some page components are stubs (e.g., `HearingPack.jsx`) pending backend endpoints

---

### 10. What-If System: Backend Built, No Frontend

**Finding:** The `WhatIfController` in the backend implements:
- Deep-cloning CaseState for scenario branching
- Re-entry point logic (fact toggle → agent 7, evidence exclusion → agent 3, etc.)
- Diff engine comparing original vs modified outcomes
- Stability scoring

But the frontend has no UI for creating scenarios, viewing diffs, or comparing outcomes side-by-side.

**Impact:** Half-built differentiator. The spec calls this "Contestable Judgment Mode" — judges toggle evidence admissibility and see how the verdict changes. Compelling feature sitting unused.

---

### 11. Post-Decision Calibration Not Built

**Finding:** US-011 describes: compare AI recommendation vs actual judge decision → generate divergence report → identify where AI reasoning differed → judge provides feedback → logged for model/prompt tuning.

**Current state:** The `decisions.py` route records judge decisions (accept/modify/reject), but there's no divergence analysis, no feedback mechanism, and no loop back into agent prompt tuning.

**Impact:** No learning loop. The system doesn't improve from judge corrections over time.

---

### 12. No CI/CD for DOKS Deployment

**Finding:** K8s manifests exist (base + staging/prod overlays) but there's no:
- GitHub Actions workflow
- Container registry configuration (DOCR or other)
- Secrets management for DigitalOcean
- Automated build → test → deploy pipeline
- Frontend build/deploy configuration

**Impact:** Can't ship. Deployment is manual-only.

---

### 13. Zero Frontend Tests

**Finding:** No test files exist in the frontend codebase. No component tests, no integration tests, no E2E tests. No testing framework configured.

**Impact:** No quality gate for a production-bound application. Regressions will be caught by humans, if at all.

---

## Summary Table

| # | Gap | Category | Impact Level | Status |
|---|-----|----------|-------------|--------|
| 1 | Auth model: institutional RBAC on single-judge workspace | Architecture | **Critical** | Decision made → Phase 3 |
| 2 | Judge's personal KB: zero implementation | Core Feature | **Critical** | Phase 4 |
| 3 | Frontend ↔ Backend: no API calls | Integration | **Critical** | **CORRECTED** — full api.js exists |
| 4 | Domain routing: SCT vs Traffic pipeline split absent | Pipeline | **High** | Phase 7.1 |
| 5 | Document ingestion: files never reach backend | Pipeline | **High** | Phase 7.2 |
| 6 | Hypothetical LLM model names | Pipeline | **Medium** | **RESOLVED** — updated to gpt-4.1 family |
| 7 | No real-time pipeline updates | UX | **Medium** | **CORRECTED** — SSE client exists; backend endpoint Phase 1 |
| 8 | Adversarial document injection undefended | Security | **High** | Phase 5.2 |
| 9 | Monolithic frontend state (850-line App.jsx) | Frontend | **Medium** | **CORRECTED** — 113-line App.jsx + 3 contexts |
| 10 | What-If UI missing (backend exists) | Feature | **Medium** | WhatIfMode.jsx exists in refactored frontend |
| 11 | Post-decision calibration unbuilt | Feature | **Medium** | Phase 7.3 |
| 12 | No CI/CD for DOKS | DevOps | **High** | Out of scope (already exists per plan) |
| 13 | Zero frontend tests | Quality | **Medium** | Phase 7.5 |

---

## Verified Remaining Gaps (2026-04-14)

These are the gaps confirmed as genuinely unimplemented after the frontend refactor:

1. **Pipeline trigger endpoint missing** — `POST /cases/{id}/run` does not exist; no way to start a pipeline on a case (Phase 1)
2. **Pipeline status endpoint missing** — `GET /cases/{id}/status` returns 404; frontend calls it on every case detail load (Phase 1)
3. **SSE stream endpoint missing** — `GET /cases/{id}/status/stream` does not exist in backend (Phase 1)
4. **Building simulation orphaned** — `FloorPixelMap.jsx` exists but no route `/case/:id/building` in App.jsx (Phase 2)
5. **Per-judge knowledge base** — no vector store per judge, no KB CRUD endpoints, no pipeline integration (Phase 4)
6. **Session revocation not enforced** — revoked JWT tokens remain valid until expiry (Phase 3, P1)
7. **Ownership checks incomplete** — decision/dispute/escalation routes do no tenant check (Phase 3)
8. **CORS blocks local dev** — backend allows `localhost:3000`, Vite runs on `localhost:5173` (**RESOLVED in this PR**)
9. **Intake contract mismatch** — frontend may send `SCT`/`Traffic` field names not matching backend enum (to verify after `feat/dev-run-experience` merge)
10. **Structured outputs not enabled** — pipeline uses `json_object` mode, not strict schema (Phase 5)
11. **No guardrails for prompt injection** — `sanitization.py` does basic cleaning only (Phase 5.2)
