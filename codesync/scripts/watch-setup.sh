#!/usr/bin/env bash
# watch-setup.sh — install / remove / inspect the codesync always-on inbox
# watcher for the active project, on macOS (launchd) and Windows (Task
# Scheduler). The watcher (watch-inbox.sh) fires a notification when a thread
# arrives even with Claude Code closed — the fix for "handoffs only get noticed
# when a session is open" (measured time-to-notice was 22h before this).
#
# Modes:
#   (default)     install the scheduled job (polls every ~2 min, 24/7)
#   --teardown    remove the scheduled job
#   --status      show whether the job is registered + recent watcher log
#
# One job per project:
#   macOS:   launchd label  com.codesync.watch.<project>
#   Windows: Task Scheduler  codesync-watch-<project>
#
# schtasks footguns handled (Windows port design, review 2A / OV8):
#   - no EnvironmentVariables dict → a per-project .cmd launcher carries the env
#   - a bare .cmd flashes a console every poll → hidden-window powershell wrapper
#   - toasts never display from a non-interactive task → registered /IT
#     (interactive, runs only when the user is logged on)
#
# Test hook: with CODESYNC_TEST_SCHED_LOG set, the scheduler command (and the
# Windows launcher contents) are written there INSTEAD of calling
# launchctl/schtasks, so artifact generation is verifiable hermetically. The
# live OS registration is validated manually (launchctl/schtasks can't run in CI).

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Platform layer first (CODESYNC_OS, PY_BIN); then env resolution for the project.
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/load-env.sh"

MODE="install"
INTERVAL="${CODESYNC_WATCH_INTERVAL:-120}"   # seconds; 2 min (notice latency IS the metric)
while [ $# -gt 0 ]; do
  case "$1" in
    --teardown) MODE="teardown"; shift ;;
    --status)   MODE="status"; shift ;;
    --interval) [ $# -ge 2 ] || err "--interval needs a value"; INTERVAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active. Set CODESYNC_PROJECT (or attach this directory) first — the watcher is per project."
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_EXISTS=$($PY_BIN -c '
import json, sys
print("yes" if sys.argv[2] in json.load(open(sys.argv[1])).get("projects", {}) else "no")
' "$CFG_FILE" "$PROJECT")
[ "$PROJECT_EXISTS" = "yes" ] || err "Project '$PROJECT' is not registered on this machine."

CONFIG_DIR="$HOME/.config/codesync"
WATCH_SCRIPT="$SCRIPT_DIR/watch-inbox.sh"
LOG_FILE="$CONFIG_DIR/watch-$PROJECT.log"

# The scheduled-job artifacts (launchd plist / schtasks command + .cmd launcher)
# and the CODESYNC_TEST_SCHED_LOG hook now live in platform.sh
# (codesync_install_scheduled_job / codesync_remove_scheduled_job /
# _codesync_sched_log) so the autonomy runner can reuse the same path (CQ2).
# This script supplies the watcher-specific names, interval, and env, and keeps
# the --status display, which is watcher-specific.

# ── macOS: launchd ───────────────────────────────────────────────────────────
LABEL="com.codesync.watch.$PROJECT"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

macos_install() {
  codesync_install_scheduled_job "$LABEL" "$TASK" "$WATCH_SCRIPT" "$INTERVAL" \
    "$LOG_FILE" "$LAUNCHER" "CODESYNC_PROJECT=$PROJECT"
}

macos_teardown() {
  local existed=no; [ -f "$PLIST" ] && existed=yes
  codesync_remove_scheduled_job "$LABEL" "$TASK" "$LAUNCHER"
  if [ "$existed" = yes ]; then
    log "Unloaded and removed $PLIST"
  else
    log "No watcher installed for '$PROJECT' — nothing to remove."
  fi
}

macos_status() {
  if [ -f "$PLIST" ]; then
    log "Plist:  $PLIST (installed)"
    if launchctl list "$LABEL" >/dev/null 2>&1; then
      log "Job:    loaded (polls every ${INTERVAL}s)"
    else
      log "Job:    NOT loaded — try: launchctl load \"$PLIST\""
    fi
  else
    log "Plist:  (not installed — run /codesync-watch on)"
  fi
}

# ── Windows: Task Scheduler ──────────────────────────────────────────────────
TASK="codesync-watch-$PROJECT"
LAUNCHER="$CONFIG_DIR/watch-$PROJECT.cmd"

windows_install() {
  codesync_install_scheduled_job "$LABEL" "$TASK" "$WATCH_SCRIPT" "$INTERVAL" \
    "$LOG_FILE" "$LAUNCHER" "CODESYNC_PROJECT=$PROJECT"
}

windows_teardown() {
  codesync_remove_scheduled_job "$LABEL" "$TASK" "$LAUNCHER"
}

windows_status() {
  if _codesync_sched_log "WIN_QUERY task=$TASK"; then return 0; fi
  if schtasks //Query //TN "$TASK" >/dev/null 2>&1; then
    log "Task:   $TASK (registered, every $(( INTERVAL / 60 )) min)"
  else
    log "Task:   (not installed — run /codesync-watch on)"
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
printf '\nInbox watcher — project %s (%s)\n' "$PROJECT" "$CODESYNC_OS"
printf '─────────────────────────────\n'
case "$CODESYNC_OS:$MODE" in
  macos:install)    macos_install;   log "Installed watcher (polls every ${INTERVAL}s, 24/7)"; INSTALLED=yes ;;
  macos:teardown)   macos_teardown;  INSTALLED=no ;;
  macos:status)     macos_status;    INSTALLED=$([ -f "$PLIST" ] && echo yes || echo no) ;;
  windows:install)  windows_install; log "Installed watcher task (every $(( INTERVAL / 60 )) min)"; INSTALLED=yes ;;
  windows:teardown) windows_teardown; INSTALLED=no ;;
  windows:status)   windows_status;  INSTALLED=unknown ;;
  *) err "Unsupported OS '$CODESYNC_OS' for the watcher (macOS + Windows only)." ;;
esac

if [ -f "$LOG_FILE" ] && [ "$MODE" = "status" ]; then
  log "Recent watcher log:"; tail -5 "$LOG_FILE" | sed 's/^/    /'
fi
printf '\nWATCHER_INSTALLED=%s\n' "${INSTALLED:-unknown}"
