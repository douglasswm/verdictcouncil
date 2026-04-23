#!/usr/bin/env bash
#
# dev.sh — spin up the full VerdictCouncil dev stack.
#
# Starts Docker infra (Postgres, Redis, Solace), runs migrations, and launches
# the backend (web gateway + 9 Solace agents + layer2-aggregator + FastAPI via
# honcho) and the frontend (Vite). Ctrl+C stops backend + frontend; Docker
# infra stays up for fast restarts. To stop everything (including infra) run
# `./stop.sh --infra`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$REPO_ROOT/VerdictCouncil_Backend"
FRONTEND_DIR="$REPO_ROOT/VerdictCouncil_Frontend"

# ----- output helpers -----
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; RST=""
fi
info() { printf "%s==>%s %s\n" "$GRN$BOLD" "$RST" "$*"; }
warn() { printf "%swarn:%s %s\n" "$YEL$BOLD" "$RST" "$*" >&2; }
die()  { printf "%serror:%s %s\n" "$RED$BOLD" "$RST" "$*" >&2; exit 1; }

# ----- pre-flight checks -----
info "Pre-flight checks"
for cmd in docker python3.12 node npm make; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found on PATH: $cmd"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable — start Docker Desktop and retry"

# ----- .env check (fail fast if missing) -----
missing_env=0
for pair in "$BACKEND_DIR/.env:$BACKEND_DIR/.env.example" "$FRONTEND_DIR/.env:$FRONTEND_DIR/.env.example"; do
  env_file="${pair%%:*}"
  example_file="${pair##*:}"
  if [[ ! -f "$env_file" ]]; then
    if [[ -f "$example_file" ]]; then
      cp "$example_file" "$env_file"
      warn "created $env_file from $(basename "$example_file") — fill in real values before running again"
      missing_env=1
    else
      die "missing $env_file and no $example_file to copy from"
    fi
  fi
done
if (( missing_env )); then
  die ".env file(s) were just created from examples — edit them (OPENAI_API_KEY, SOLACE_BROKER_URL, DATABASE_URL, REDIS_URL, JWT_SECRET, etc.) then re-run ./dev.sh"
fi

# ----- infra up (idempotent, with stale-container recovery) -----
info "Bringing up Docker infra (Postgres, Redis, Solace)"
if ! make -C "$BACKEND_DIR" infra-up 2>&1; then
  warn "infra-up failed — removing stale containers and retrying (named volumes are preserved)"
  make -C "$BACKEND_DIR" infra-down 2>/dev/null || true
  make -C "$BACKEND_DIR" infra-up || die "infra-up failed after recovery — restart Docker Desktop and retry"
fi

# ----- solace bootstrap (idempotent; creates VPN + vc-agent user) -----
# The SAM agents and web-gateway authenticate against a custom VPN that the
# vanilla Solace container does not ship with. This mirrors the K8s bootstrap
# Job so local startup matches staging/prod.
info "Bootstrapping Solace (VPN + vc-agent client)"
make -C "$BACKEND_DIR" solace-bootstrap || die "solace-bootstrap failed — check vc-solace logs (docker logs vc-solace)"

# ----- backend bootstrap (first-run only, plus missing-tool recovery) -----
if [[ ! -d "$BACKEND_DIR/.venv" ]]; then
  info "Backend .venv missing — running make install (one-time)"
  make -C "$BACKEND_DIR" install
elif [[ ! -x "$BACKEND_DIR/.venv/bin/honcho" ]]; then
  info "Backend .venv is missing honcho — refreshing backend install"
  make -C "$BACKEND_DIR" install
else
  printf "%s    backend .venv present — skipping install%s\n" "$DIM" "$RST"
fi

info "Running backend migrations"
# On a fresh DB (no tables yet), use reset-db which creates schema from models
# and stamps alembic to head — avoids SQLAlchemy 2.x enum double-create bug.
# On an existing DB, alembic upgrade head applies any pending incremental migrations.
TABLE_COUNT=$(docker exec vc-postgres psql -U vc_dev -d verdictcouncil -tAq \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename!='alembic_version'" \
  2>/dev/null || echo 0)
if [[ "${TABLE_COUNT:-0}" -eq 0 ]]; then
  info "Fresh database — seeding schema from models"
  make -C "$BACKEND_DIR" reset-db
else
  make -C "$BACKEND_DIR" migrate
fi

# ----- frontend bootstrap (first-run only) -----
if [[ ! -d "$FRONTEND_DIR/node_modules" ]]; then
  info "Frontend node_modules missing — running npm install (one-time)"
  npm --prefix "$FRONTEND_DIR" install
else
  printf "%s    frontend node_modules present — skipping install%s\n" "$DIM" "$RST"
fi

# ----- demo seed (idempotent; skips if users already exist) -----
info "Seeding demo users and sample data"
(cd "$BACKEND_DIR" && .venv/bin/python -m scripts.seed_data)

# ----- ADK session schema (must run before agents to avoid race on fresh DB) -----
info "Initialising ADK session schema"
(cd "$BACKEND_DIR" && .venv/bin/python -m scripts.init_adk_db)

# ----- start services -----
# Enable job control so each background job gets its own process group,
# letting us `kill -- -$PID` the whole tree (honcho → 12 backend processes,
# Vite → node).
set -m

info "Starting backend (honcho: web-gateway + 9 agents + layer2-aggregator + API on :8001)"
make -C "$BACKEND_DIR" dev &
BACKEND_PID=$!

info "Starting frontend (Vite on :5173)"
npm --prefix "$FRONTEND_DIR" run dev &
FRONTEND_PID=$!

# ----- shutdown trap -----
shutdown() {
  trap - INT TERM EXIT
  printf "\n"
  info "Shutting down backend + frontend (infra stays up)"
  for pid in "${BACKEND_PID:-}" "${FRONTEND_PID:-}"; do
    [[ -z "$pid" ]] && continue
    # kill the whole process group; ignore errors if already gone
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  # give children a moment to exit cleanly, then SIGKILL any stragglers
  sleep 2
  for pid in "${BACKEND_PID:-}" "${FRONTEND_PID:-}"; do
    [[ -z "$pid" ]] && continue
    kill -KILL -- "-$pid" 2>/dev/null || true
  done
  info "Stopped. To stop Docker infra too: ./stop.sh --infra"
}
trap shutdown INT TERM EXIT

info "Stack is up — backend :8001, frontend :5173. Ctrl+C to stop."
wait
