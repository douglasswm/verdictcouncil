# VerdictCouncil

Orchestration root for the VerdictCouncil judicial decision-support system.
This repo pins the backend and frontend as git submodules and provides a
single command to spin up the full local dev stack.

**VerdictCouncil** is a judge's personal workspace — judges upload case
materials, run multi-agent AI analysis, build private knowledge bases, and
review verdict recommendations. It is *not* an institutional court system.

## Repository Structure

```
VER/
├── VerdictCouncil_Backend/    # submodule → ShashankBagda/VerdictCouncil_Backend
├── VerdictCouncil_Frontend/   # submodule → ShashankBagda/VerdictCouncil_Frontend
├── dev.sh                     # one-command local dev startup
├── CLAUDE.md                  # gitflow, PR, versioning, and workflow rules
└── findings.md                # systems and gap analysis
```

| Component | Stack | Port |
|-----------|-------|------|
| Backend | Python 3.12, FastAPI, Solace Agent Mesh (9 agents + gateway + aggregator) | 8001 (API), 8000 (gateway) |
| Frontend | React 18, Vite, TailwindCSS, React Router, ReactFlow, Pixi.js | 5173 |
| Infra | PostgreSQL 15, Redis 7, Solace broker (Docker) | 5432, 6379, 8080 |

## Quick Start

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/douglasswm/verdictcouncil.git
cd verdictcouncil
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 2. Configure env files

First run of `./dev.sh` will copy `.env.example` → `.env` in each submodule
and exit. Fill in the required secrets:

- `VerdictCouncil_Backend/.env` — `OPENAI_API_KEY`, `SOLACE_BROKER_URL`,
  `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET`
- `VerdictCouncil_Frontend/.env` — `VITE_API_URL` defaults to
  `http://127.0.0.1:8001` (usually fine)

### 3. Spin up the stack

```bash
./dev.sh
```

This will:

1. Pre-flight check (`docker`, `python3.12`, `node`, `npm`, `make`)
2. Start Docker infra (Postgres, Redis, Solace) — idempotent
3. Bootstrap backend `.venv` (first run only) and run Alembic migrations
4. Bootstrap frontend `node_modules` (first run only)
5. Launch backend (honcho → 12 processes) and frontend (Vite) in the foreground

Ctrl+C stops the backend + frontend. Docker infra stays running for fast
restarts — stop it with `make -C VerdictCouncil_Backend infra-down`.

## Prerequisites

- **Docker Desktop** (for Postgres, Redis, Solace broker)
- **Python 3.12** (matches backend pin)
- **Node.js 18+** and **npm**
- **`make`**

## Working with Submodules

### Pull the latest `development` on both submodules

```bash
git submodule update --remote --merge
```

This advances each submodule to the tip of `development` (the tracked
branch in `.gitmodules`). The pin bump shows up as a change in the root
repo — commit it when you want to lock in the update.

### Working inside a submodule

Submodules are full git repos. `cd` in and use git normally:

```bash
cd VerdictCouncil_Backend
git checkout -b feat/vc-123-some-change   # branch off development
# edit, commit, push
```

When you merge a PR in the submodule and want the root repo to point at
the new commit:

```bash
cd ..                          # back to VER root
git add VerdictCouncil_Backend # stages the new submodule pin
git commit -m "chore: bump backend submodule to latest development"
```

### Fresh clone on a new machine

```bash
git clone --recurse-submodules https://github.com/douglasswm/verdictcouncil.git
cd verdictcouncil
./dev.sh   # first run writes .env files and exits — fill them in and re-run
```

## Branching

This repo follows the gitflow defined in `CLAUDE.md`:

```
main → release/<context>/<tag> → development → feat/<issue-id>-<context>
```

- `main` — production-ready (tagged releases)
- `development` — integration branch
- `feat/*` — unit-of-work branches off `development`
- Never commit directly to `main`, `release`, or `development`

See `CLAUDE.md` for the full PR template, versioning rules, and commit
conventions.

## Related Docs

- `CLAUDE.md` — gitflow, PR template, versioning, workflow orchestration
- `findings.md` — systems analysis, architectural gaps, phase plan
- `VerdictCouncil_Backend/README.md` — backend setup and API details
- `VerdictCouncil_Frontend/README.md` — frontend setup and env vars
