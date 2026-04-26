# Sprint 5 — Cloud Deployment Plan

Authored 2026-04-26 after Sprint 4 close-out (PRs #88–#96 backend, #152–#160 frontend, root commits through `fb49882`).

Source of truth for tasks: [`tasks-breakdown-2026-04-25-pipeline-rag-observability.md` §Sprint 5](./tasks-breakdown-2026-04-25-pipeline-rag-observability.md). This document **does not redefine** any task — it sequences them, splits responsibilities, and flags critical-path dependencies so we don't do work that has to be redone.

---

## Goal

Take the in-process Sprint-0–4 build and ship it to a live demo stack:

- **LangGraph Platform Cloud** runs the compiled graph (auto-provisioned Postgres for checkpoints).
- **FastAPI BFF** runs on a managed app platform (DigitalOcean App Platform recommended, SGT region for latency).
- **React frontend** runs on Vercel.
- **App data** (cases, audit_log, judge_corrections, suppressed_citation, pipeline_jobs) lives on managed Postgres separate from LangGraph's checkpoint store.
- **SSE pub/sub** runs on managed Redis (Upstash).

Plus: production-deploy CI workflow that fires on `main` merge, end-to-end smoke recorded as the demo video, governance docs updated.

---

## Responsibility split

Five tasks I can drive end-to-end (code + tests). One hybrid (I write the runbook, you run it). Five pure-ops tasks that need you in cloud consoles + secret manager.

| Task | Owner | Description | Size |
|------|-------|-------------|------|
| **5.DEP.1** | **You** | Provision Postgres / Redis / object storage / domain + SSL | S (~1 day mostly waiting) |
| **5.DEP.2** | Hybrid | Alembic upgrade head on cloud Postgres | XS |
| **5.DEP.3** | **You** | Configure LangGraph Platform deployment in LangSmith UI | S |
| **5.DEP.4** | **Claude** | `langgraph-build.yml` CI workflow → push image to GHCR | S |
| **5.DEP.5** | **Claude** | `scripts/deploy/cloud_deploy.py` via LangSmith Deployment SDK | S |
| **5.DEP.6** | **Claude** | Cloud branch in `runner.py` + `langgraph-sdk` dep + integration test | M |
| **5.DEP.7** | **You** | Deploy FastAPI BFF to chosen managed app platform | S |
| **5.DEP.8** | **You** | Deploy frontend to Vercel | S |
| **5.DEP.9** | **Claude** | `production-deploy.yml` orchestrator (build → deploy graph → trigger BFF redeploy) | M |
| **5.DEP.10** | **You** | End-to-end manual smoke + demo recording | XS (manual) |
| **5.DEP.11** | **Claude** | Update `MLSECOPS_SECTION.md` + `RESPONSIBLE_AI_SECTION.md` for cloud topology | S |

---

## Critical-path ordering

The order matters because some code can't be tested without cloud, and some cloud config can't be exercised without code. Sequence:

```
1. You      5.DEP.1   Provision (Postgres + Redis + storage + domain)
              ↓
2. You      5.DEP.3   Configure LangGraph Platform shell (no image yet)
              ↓
3. Claude   5.DEP.4 + 5.DEP.5   Build pipeline + deploy script (offline-buildable)
              ↓
4. You      Trigger first deploy via 5.DEP.4 → 5.DEP.5
              ↓ (real deployment URL exists)
5. You      5.DEP.2   alembic upgrade head against cloud Postgres
              ↓
6. Claude   5.DEP.6   Wire cloud runner branch — now testable against real URL
              ↓
7. You      5.DEP.7 + 5.DEP.8   Deploy BFF + frontend
              ↓
8. Claude   5.DEP.9   Production-deploy workflow stitches everything
              ↓
9. You      5.DEP.10  End-to-end smoke; record demo
              + Sprint-4 parked manual smokes (4.C5.3, 4.C5b.5, 4.A5.3, 4.D3.4)
              ↓
10. Claude  5.DEP.11  Update governance docs to reflect deployed topology
```

Two reasons this order matters:

1. **5.DEP.6 (cloud runner branch) cannot be merged until 5.DEP.5 produces a working LangGraph deployment.** The integration test in 5.DEP.6 hits a live deployment URL. Land the build/deploy machinery first so the test target exists.
2. **5.DEP.11 docs come last.** Decisions made during 5.DEP.7 / 5.DEP.10 (final domain, final region, exact Postgres tier) need to flow into the governance topology table. Writing the doc earlier means rewriting it.

---

## Pre-flight: information I need from you before any cloud-touching code lands

Before 5.DEP.4 / 5.DEP.5 / 5.DEP.6 land, decide and tell me:

- [ ] **Container registry**: GHCR (default — works with the existing GitHub setup), or the LangGraph Cloud-managed registry?
- [ ] **Managed Postgres provider**: DigitalOcean Managed Postgres / Supabase / RDS / other?
- [ ] **Managed Redis provider**: Upstash (recommended — serverless, SGT region) / DO Managed Redis / other?
- [ ] **BFF deploy target**: DigitalOcean App Platform / Fly.io / Railway / other?
- [ ] **Domain**: what's the production hostname for the BFF? (`api.verdictcouncil.<TLD>`?)
- [ ] **GitHub org for image push**: confirm `ghcr.io/<github-username>/verdictcouncil` is the canonical image path?

If any of these are deferred ("you decide, Claude"), I'll default to: **GHCR + DigitalOcean Postgres + Upstash + DO App Platform**, all SGT region, and we revisit if the choice surfaces a real cost / latency issue.

---

## Pre-flight: secrets I need staged before 5.DEP.5 can run

These need to exist in **GitHub Actions secrets** (for CI deploys) and the **chosen platform's secret manager** (for runtime). I won't see the values; you populate them.

- `LANGSMITH_API_KEY` — for both CI (deploy SDK) and runtime (auto-injected by LangGraph Cloud)
- `OPENAI_API_KEY` — runtime
- `APP_DATABASE_URL` — runtime; from 5.DEP.1
- `REDIS_URL` — runtime; from 5.DEP.1
- `JWT_SECRET` — runtime; reuse the existing prod value or generate fresh
- `GHCR_PAT` (or equivalent) — CI; needs `write:packages` if pushing to GHCR

LangGraph Cloud auto-injects `LANGGRAPH_DATABASE_URL` for graph checkpoints — **do not set this manually**.

---

## What lands in each PR

To keep PRs reviewable and the gitflow clean (`feat/*` → `development` → `release/*` → `main`):

### PR #1 — `feat/sprint5-dep4-langgraph-build`
- `.github/workflows/langgraph-build.yml`
- Manual verification: trigger workflow on a throwaway PR, confirm image lands in registry.
- **Blocked by**: 5.DEP.1 partly (need GHCR / registry decision); fully unblocked once registry is chosen.

### PR #2 — `feat/sprint5-dep5-cloud-deploy-script`
- `VerdictCouncil_Backend/scripts/deploy/cloud_deploy.py`
- `VerdictCouncil_Backend/pyproject.toml` adds `langsmith` deployment extras
- Unit tests for the script (mock the SDK)
- Manual verification (post-merge): you run `python scripts/deploy/cloud_deploy.py <sha>` against a staging deployment.
- **Blocked by**: 5.DEP.3 (needs the LangGraph deployment to exist before the script can target it).

### PR #3 — `feat/sprint5-dep6-cloud-runner-branch`
- `VerdictCouncil_Backend/src/pipeline/graph/runner.py` cloud branch
- `VerdictCouncil_Backend/pyproject.toml` adds `langgraph-sdk`
- `VerdictCouncil_Backend/tests/integration/test_cloud_runner.py` (gated by `CLOUD_RUNNER_URL` env — skipped locally, runs in cloud-CI)
- **Blocked by**: 5.DEP.5 producing a real deployment URL.

### PR #4 — `feat/sprint5-dep9-production-deploy`
- `.github/workflows/production-deploy.yml`
- Documents rollback procedure in `docs/setup-2026-04-25.md` (or new `docs/runbook-deploy.md` if that doc has grown)
- **Blocked by**: 5.DEP.5, 5.DEP.7, 5.DEP.8 all live.

### PR #5 — `feat/sprint5-dep11-governance-docs`
- `MLSECOPS_SECTION.md` §7.5–7.6 cloud topology
- `RESPONSIBLE_AI_SECTION.md` Pillar 3 evidence pointers
- **Blocked by**: 5.DEP.10 (need the deployed reality to document).

### Hybrid — 5.DEP.2 alembic runbook
- I draft `docs/runbook-cloud-postgres-migration.md` with: connection string format, `alembic current` smoke, `alembic upgrade head`, the `judge_corrections` FK enforcement test from the task acceptance criteria.
- You run it.
- Lives on the `feat/sprint5-dep5-cloud-deploy-script` branch (close enough scope) or its own tiny PR — flip a coin.

---

## Risks I'm watching

1. **LangGraph Platform pricing / quota surprises.** First deploy may hit a free-tier quota that the demo case run exceeds. Mitigation: 5.DEP.1 includes a "confirm quota allowance" item; if we hit a wall, swap the cloud target for self-hosted LangGraph in a Docker container on DO App Platform (the build artifact is the same).
2. **SSE pub/sub across cloud boundary.** The BFF on DO App Platform talks to LangGraph Cloud; SSE events need to flow back through Redis to the React client. The 5.DEP.6 integration test must verify SSE end-to-end, not just the Python ainvoke path.
3. **Trace propagation across cloud hops.** Sprint 2's `traceparent` header propagation was tested in-process. Cloud hop adds a network boundary that may strip or rewrite headers. 5.DEP.10 smoke must check that one trace_id flows from React → BFF → LangGraph Cloud → LangSmith.
4. **Secret rotation post-demo.** The `JWT_SECRET` and `LANGSMITH_API_KEY` provisioned for the demo will live in GitHub Actions logs (sanitised, but still). Plan a rotation immediately after 5.DEP.10 if the demo is recorded against production credentials.
5. **CI image cache cold-start.** First `langgraph-build.yml` run may take 10+ min uncached. If 5.DEP.9 needs to be <10 min end-to-end, factor in BuildKit caching (`actions/cache` for Docker layers).

---

## What this plan deliberately does NOT cover

- **Sprint-4 manual smokes** (4.C5.3, 4.C5b.5, 4.A5.3, 4.D3.4) are referenced in the close-out section of `tasks/sprint4-deferral-2026-04-25.md`. Those are run after 5.DEP.10, not as part of Sprint 5 tasks.
- **Sprint 6+ (Deep Agents Judge Assistant)** is deferred indefinitely per the original task plan. This document is silent on it.
- **Cost optimisation, autoscaling, multi-region failover** — out of scope for the demo. Add to `tasks/post-demo-followups.md` if anything surfaces.

---

## Approval gate

Before PR #1 lands, confirm:

- [ ] Plan reviewed
- [ ] Pre-flight decisions captured (registry, providers, domain, GitHub org)
- [ ] Secrets staged in GitHub Actions
- [ ] We agree on the PR-by-PR breakdown

If any of those is "not yet," tell me and I park 5.DEP.4 until they're ready.
