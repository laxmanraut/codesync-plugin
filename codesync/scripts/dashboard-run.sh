#!/usr/bin/env bash
# dashboard-run.sh — launch (or reuse, or stop) the local codesync dashboard.
#
#   dashboard-run.sh           start it (or reopen the browser if already up)
#   dashboard-run.sh --stop    stop a running instance
#
# Single-instance (eng-review R2): if a live server is recorded in
# dashboard.json, we just reopen the browser at it instead of spawning a
# second one. The server's idle auto-shutdown reaps orphans regardless.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
[ -n "${PY_BIN:-}" ] || { printf 'ERROR: no usable Python found.\n' >&2; exit 1; }

STATE_FILE="$HOME/.config/codesync/dashboard.json"
LOG_FILE="$HOME/.config/codesync/dashboard.log"
SERVER="$SCRIPT_DIR/dashboard-server.py"
API="http://127.0.0.1"

log() { printf '  %s\n' "$*"; }

read_state() { # field -> value (port|token|pid), empty if missing
  [ -f "$STATE_FILE" ] || return 0
  $PY_BIN -c '
import json,sys
try:
    d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))
except Exception: pass
' "$STATE_FILE" "$1" 2>/dev/null || true
}

ping() { # port token -> 0 if a live dashboard answers with that token
  local port="$1" token="$2"
  [ -n "$port" ] && [ -n "$token" ] || return 1
  curl -sf --max-time 2 -H "X-CSDash-Token: $token" \
    "$API:$port/api/overview" >/dev/null 2>&1
}

# ── --stop ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--stop" ]; then
  PID=$(read_state pid)
  if [ -n "$PID" ]; then
    kill "$PID" 2>/dev/null || { [ "$CODESYNC_OS" = "windows" ] && taskkill //PID "$PID" //F >/dev/null 2>&1; } || true
    rm -f "$STATE_FILE" 2>/dev/null || true
    log "Dashboard stopped (pid $PID)."
  else
    log "No running dashboard recorded."
  fi
  exit 0
fi

# ── single-instance reuse ─────────────────────────────────────────────────────
PORT=$(read_state port); TOKEN=$(read_state token)
if ping "$PORT" "$TOKEN"; then
  URL="$API:$PORT/?t=$TOKEN"
  codesync_open_url "$URL"
  log "Dashboard already running — reopened $URL"
  printf 'DASHBOARD_URL=%s\n' "$URL"
  exit 0
fi

# ── spawn a fresh detached server ──────────────────────────────────────────────
rm -f "$STATE_FILE" 2>/dev/null || true
mkdir -p "$(dirname "$STATE_FILE")"
# shellcheck disable=SC2086
nohup $PY_BIN "$SERVER" --config "$HOME/.config/codesync/config.json" \
  >"$LOG_FILE" 2>&1 &
SPAWNED=$!
disown 2>/dev/null || true

# Wait (≤10s) for the server to write its state + come up.
for _ in $(seq 1 50); do
  PORT=$(read_state port); TOKEN=$(read_state token)
  if ping "$PORT" "$TOKEN"; then break; fi
  sleep 0.2
done

if ! ping "$PORT" "$TOKEN"; then
  printf 'ERROR: dashboard server did not start. See %s\n' "$LOG_FILE" >&2
  tail -5 "$LOG_FILE" 2>/dev/null >&2 || true
  exit 1
fi

URL="$API:$PORT/?t=$TOKEN"
codesync_open_url "$URL"
log "Dashboard started (pid $SPAWNED) — opened $URL"
log "Read-only; auto-stops after 30 min idle, or run /codesync-dashboard --stop."
printf 'DASHBOARD_URL=%s\n' "$URL"
