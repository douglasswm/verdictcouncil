#!/usr/bin/env bash
#
# stop.sh — cleanly stop the VerdictCouncil dev stack.
#
# By default, stops the backend (honcho → 12 processes) and frontend (Vite)
# that `./dev.sh` leaves running. Docker infra (Postgres, Redis, Solace)
# stays up so the next `./dev.sh` is fast.
#
# Usage:
#   ./stop.sh              # stop backend + frontend only
#   ./stop.sh --infra      # also bring Docker infra down
#   ./stop.sh --all        # alias for --infra
#   ./stop.sh --help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$REPO_ROOT/VerdictCouncil_Backend"

# ----- output helpers -----
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; RST=""
fi
info() { printf "%s==>%s %s\n" "$GRN$BOLD" "$RST" "$*"; }
warn() { printf "%swarn:%s %s\n" "$YEL$BOLD" "$RST" "$*" >&2; }

STOP_INFRA=0
case "${1:-}" in
  --infra|--all)
    STOP_INFRA=1
    ;;
  --help|-h)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "")
    ;;
  *)
    warn "unknown argument: $1 (use --help)"
    exit 2
    ;;
esac

# ----- kill honcho + vite by command signature -----
# pgrep -f matches across the whole command line, which is what we need to
# catch honcho workers (python -m solace_agent_mesh ...) and uvicorn.
kill_pattern() {
  local label="$1"
  local pattern="$2"
  local pids
  pids=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [[ -z "$pids" ]]; then
    printf "%s    no %s processes found%s\n" "$DIM" "$label" "$RST"
    return 0
  fi
  info "Stopping $label ($(echo "$pids" | wc -w | tr -d ' ') process(es))"
  # shellcheck disable=SC2086
  kill -TERM $pids 2>/dev/null || true
  # give them a moment, then SIGKILL stragglers
  sleep 2
  local leftover
  leftover=$(pgrep -f "$pattern" 2>/dev/null || true)
  if [[ -n "$leftover" ]]; then
    warn "$label did not exit on SIGTERM — sending SIGKILL"
    # shellcheck disable=SC2086
    kill -KILL $leftover 2>/dev/null || true
  fi
}

info "Stopping VerdictCouncil dev stack"
kill_pattern "honcho (backend)"      'honcho -f Procfile\.dev'
kill_pattern "uvicorn (API :8001)"   'uvicorn src\.api\.app:app'
kill_pattern "SAM agents"            'solace_agent_mesh\.cli\.main'
kill_pattern "Vite (frontend :5173)" 'vite'

if (( STOP_INFRA )); then
  info "Bringing Docker infra down (Postgres, Redis, Solace)"
  make -C "$BACKEND_DIR" infra-down
else
  printf "%s    Docker infra left running — use './stop.sh --infra' to stop it%s\n" "$DIM" "$RST"
fi

info "Done."
