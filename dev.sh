#!/usr/bin/env bash
#
# dev.sh — spin up the full VerdictCouncil dev stack.
#
# Starts Docker infra (Postgres, Redis, Solace), runs migrations, and launches
# the backend (FastAPI + 9 Solace agents + web gateway via honcho) and the
# frontend (Vite). Ctrl+C stops backend + frontend; Docker infra stays up for
# fast restarts — run `make -C VerdictCouncil_Backend infra-down` to stop it.

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

# ----- infra up (idempotent) -----
info "Bringing up Docker infra (Postgres, Redis, Solace)"
make -C "$BACKEND_DIR" infra-up

# ----- backend bootstrap (first-run only) -----
if [[ ! -d "$BACKEND_DIR/.venv" ]]; then
  info "Backend .venv missing — running make install (one-time)"
  make -C "$BACKEND_DIR" install
else
  printf "%s    backend .venv present — skipping install%s\n" "$DIM" "$RST"
fi

info "Running backend migrations (alembic upgrade head)"
make -C "$BACKEND_DIR" migrate

# ----- frontend bootstrap (first-run only) -----
if [[ ! -d "$FRONTEND_DIR/node_modules" ]]; then
  info "Frontend node_modules missing — running npm install (one-time)"
  npm --prefix "$FRONTEND_DIR" install
else
  printf "%s    frontend node_modules present — skipping install%s\n" "$DIM" "$RST"
fi

# ----- start services -----
# Enable job control so each background job gets its own process group,
# letting us `kill -- -$PID` the whole tree (honcho → 12 children, Vite → node).
set -m

info "Starting backend (honcho: gateway + 9 agents + aggregator + API on :8001)"
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
  info "Stopped. To stop Docker infra: make -C VerdictCouncil_Backend infra-down"
}
trap shutdown INT TERM EXIT

info "Stack is up — backend :8001, frontend :5173. Ctrl+C to stop."
wait
