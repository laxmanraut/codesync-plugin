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

# Test hook: capture what WOULD be registered instead of touching the OS.
_sched_log() {
  [ -n "${CODESYNC_TEST_SCHED_LOG:-}" ] || return 1
  printf '%s\n' "$*" >> "$CODESYNC_TEST_SCHED_LOG" 2>/dev/null || true
  return 0
}

# ── macOS: launchd ───────────────────────────────────────────────────────────
LABEL="com.codesync.watch.$PROJECT"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

macos_install() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$WATCH_SCRIPT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODESYNC_PROJECT</key>
    <string>$PROJECT</string>
  </dict>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
PLIST_EOF
  if _sched_log "MACOS_LOAD label=$LABEL interval=$INTERVAL plist=$PLIST"; then return 0; fi
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
}

macos_teardown() {
  if _sched_log "MACOS_UNLOAD label=$LABEL plist=$PLIST"; then rm -f "$PLIST"; return 0; fi
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
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
  # The .cmd carries CODESYNC_PROJECT (schtasks has no env dict) and invokes
  # Git Bash to run the watcher. Written in native Windows form so cmd.exe and
  # schtasks understand it.
  # bash.exe (native Windows path) runs the watcher script directly; the .cmd's
  # `set` puts CODESYNC_PROJECT in the environment bash.exe inherits (env vars
  # are NOT MSYS path-translated, and a project NAME needs none — platform.sh
  # rule). Forward-slash the script path so bash accepts it unambiguously.
  local bash_win watch_fwd
  bash_win="$(cygpath -w "$(command -v bash)" 2>/dev/null || echo bash.exe)"
  watch_fwd="$(cygpath -m "$WATCH_SCRIPT" 2>/dev/null || echo "$WATCH_SCRIPT")"
  {
    printf '@echo off\r\n'
    printf 'set CODESYNC_PROJECT=%s\r\n' "$PROJECT"
    printf '"%s" "%s"\r\n' "$bash_win" "$watch_fwd"
  } > "$LAUNCHER"

  # Hidden-window wrapper so the 2-min poll never flashes a console; /IT keeps
  # the task interactive (logged-on) so toasts display. /sc MINUTE /mo in min.
  local launcher_win every_min tr
  launcher_win="$(cygpath -w "$LAUNCHER" 2>/dev/null || echo "$LAUNCHER")"
  every_min=$(( INTERVAL / 60 )); [ "$every_min" -ge 1 ] || every_min=1
  tr="powershell -WindowStyle Hidden -NonInteractive -Command \"Start-Process -WindowStyle Hidden -FilePath '$launcher_win'\""

  if _sched_log "WIN_SCHTASKS task=$TASK every_min=$every_min launcher=$launcher_win"; then
    _sched_log "WIN_LAUNCHER $(tr -d '\r' < "$LAUNCHER" | tr '\n' '|')"
    return 0
  fi
  schtasks //Create //TN "$TASK" //SC MINUTE //MO "$every_min" //IT //F \
    //TR "$tr" >/dev/null
}

windows_teardown() {
  if _sched_log "WIN_DELETE task=$TASK"; then rm -f "$LAUNCHER"; return 0; fi
  schtasks //Delete //TN "$TASK" //F >/dev/null 2>&1 || log "No watcher task '$TASK' — nothing to remove."
  rm -f "$LAUNCHER"
}

windows_status() {
  if _sched_log "WIN_QUERY task=$TASK"; then return 0; fi
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
