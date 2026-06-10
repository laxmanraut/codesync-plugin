#!/usr/bin/env bash
# autopilot-setup.sh — Install / remove / inspect the codesync autopilot
# launchd job for the active project.
#
# Modes:
#   (default)     install the launchd job (polls every 15 min, 24/7)
#   --teardown    unload + remove the launchd job
#   --status      show whether the job is loaded, last log lines, pending state
#
# The job runs autopilot-run.sh with CODESYNC_PROJECT baked into the plist.
# One job per project: label com.codesync.autopilot.<project>.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

. "$SCRIPT_DIR/lib/load-env.sh"

MODE="install"
while [ $# -gt 0 ]; do
  case "$1" in
    --teardown) MODE="teardown"; shift ;;
    --status)   MODE="status"; shift ;;
    *) shift ;;
  esac
done

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active. Set CODESYNC_PROJECT (or attach this directory) first — the autopilot is configured per project."
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_EXISTS=$($PY_BIN -c '
import json, sys
print("yes" if sys.argv[2] in json.load(open(sys.argv[1])).get("projects", {}) else "no")
' "$CFG_FILE" "$PROJECT")
[ "$PROJECT_EXISTS" = "yes" ] || err "Project '$PROJECT' is not registered on this machine."

LABEL="com.codesync.autopilot.$PROJECT"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_FILE="$HOME/.config/codesync/autopilot-$PROJECT.json"
LOG_FILE="$HOME/.config/codesync/autopilot-$PROJECT.log"

case "$MODE" in

  status)
    printf '\n'
    printf 'Autopilot status — project %s\n' "$PROJECT"
    printf '─────────────────────────────\n'
    if [ -f "$PLIST" ]; then
      printf '  Plist:    %s (installed)\n' "$PLIST"
      if launchctl list "$LABEL" >/dev/null 2>&1; then
        printf '  Job:      loaded (polls every 15 min)\n'
      else
        printf '  Job:      NOT loaded — try: launchctl load "%s"\n' "$PLIST"
      fi
    else
      printf '  Plist:    (not installed — run /codesync-autopilot on)\n'
    fi
    if [ -f "$STATE_FILE" ]; then
      $PY_BIN - "$STATE_FILE" <<'PY'
import json, sys, time
state = json.load(open(sys.argv[1]))
runs = state.get("runs", [])
proc = state.get("processed", {})
now = time.time()
recent = [t for t in runs if now - t < 3600]
print(f"  Runs (last hour): {len(recent)}")
print(f"  Threads processed (all time): {len(proc)}")
PY
    else
      printf '  State:    (no runs yet)\n'
    fi
    if [ -f "$LOG_FILE" ]; then
      printf '  Recent log:\n'
      tail -5 "$LOG_FILE" | sed 's/^/    /'
    fi
    printf '\n'
    printf 'AUTOPILOT_INSTALLED=%s\n' "$([ -f "$PLIST" ] && echo yes || echo no)"
    ;;

  teardown)
    if [ -f "$PLIST" ]; then
      launchctl unload "$PLIST" 2>/dev/null || true
      rm -f "$PLIST"
      log "Unloaded and removed $PLIST"
    else
      log "No autopilot installed for project '$PROJECT' — nothing to remove."
    fi
    printf '\n'
    printf 'AUTOPILOT_INSTALLED=no\n'
    ;;

  install)
    # Resolve the claude binary now so the launchd job (minimal PATH) finds it.
    CLAUDE_PATH=$(command -v claude || true)
    [ -n "$CLAUDE_PATH" ] || err "claude binary not found on PATH. The autopilot needs the Claude Code CLI."

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
    <string>$SCRIPT_DIR/autopilot-run.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODESYNC_PROJECT</key>
    <string>$PROJECT</string>
    <key>CODESYNC_AUTOPILOT_CLAUDE_BIN</key>
    <string>$CLAUDE_PATH</string>
  </dict>
  <key>StartInterval</key>
  <integer>900</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
PLIST_EOF

    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    log "Installed and loaded $LABEL (polls every 15 minutes, 24/7)"
    printf '\n'
    printf 'AUTOPILOT_INSTALLED=yes\n'
    printf 'PLIST=%s\n' "$PLIST"
    printf 'LOG=%s\n' "$LOG_FILE"
    ;;
esac
