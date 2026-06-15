#!/usr/bin/env bash
# watch-inbox.sh — always-on inbox watcher (one poll cycle).
#
# The fix for "a handoff only gets noticed when Claude Code is open." Invoked by
# the OS scheduler (launchd on macOS / Task Scheduler on Windows, installed via
# watch-setup.sh) every ~2 minutes, 24/7, with NO Claude session required. It is
# the notification path of status-line.sh, decoupled from the session:
#
#   1. Scan this machine's registered-role inboxes for never-seen threads
#      (state.find_unseen_threads) — the SAME scan and the SAME shared
#      seen-<project>.log the statusline uses.
#   2. Mark them seen (state.mark_threads_seen) and fire ONE codesync_notify.
#   3. Quiet inbox → exit silently, zero notifications.
#
# Because it writes the shared seen-log: opening Claude later does NOT re-notify
# (already seen), and time-to-notice (tools/time-to-notice.py) reflects this
# faster notice. Unlike autopilot it runs no claude, makes no headless reply,
# and writes nothing outside the seen-log.
#
# Env:  CODESYNC_PROJECT          (required; baked into the scheduled job)
#       CODESYNC_WATCH_INTERVAL   (informational only; the scheduler owns timing)
# Log:  ~/.config/codesync/watch-<project>.log   (errors + fires; quiet otherwise)

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scheduled jobs inherit a minimal PATH; extend BEFORE loading platform.sh,
# because PY_BIN resolution probes PATH (same ordering rule as autopilot-run.sh).
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local:$PATH"

# Platform layer: CODESYNC_OS, PY_BIN, codesync_python, codesync_notify.
. "$SCRIPT_DIR/lib/platform.sh"

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || { echo "watch-inbox: CODESYNC_PROJECT not set" >&2; exit 1; }
[ -f "$CFG_FILE" ] || exit 0
[ -n "${PY_BIN:-}" ] || exit 0

CONFIG_DIR="$HOME/.config/codesync"
LOG_FILE="$CONFIG_DIR/watch-$PROJECT.log"
logln() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE" 2>/dev/null || true; }

# Scan + mark in ONE Python process (state.py is the single source). Emits a
# tab line "<count>\t<title-if-exactly-one>". All paths cross as argv, never
# env — MSYS converts argv for native python.exe but not environment values.
OUT=$(codesync_python - "$SCRIPT_DIR/lib" "$CFG_FILE" "$PROJECT" "$CONFIG_DIR" <<'PY' 2>/dev/null
import sys
lib_dir, cfg_path, project, config_dir = sys.argv[1:5]
sys.path.insert(0, lib_dir)
import state
cfg = state.load_config(cfg_path)
unseen = state.find_unseen_threads(cfg, project, config_dir)
n = state.mark_threads_seen(config_dir, project, [u["rel"] for u in unseen])
title = unseen[0]["title"] if len(unseen) == 1 else ""
print(f"{n}\t{title}")
PY
)

COUNT=$(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print $1}')
ONLY_TITLE=$(printf '%s\n' "$OUT" | awk -F'\t' 'NR==1{print $2}')

# Quiet inbox (or a failed scan) → nothing to do, zero cost.
{ [ -n "${COUNT:-}" ] && [ "$COUNT" -gt 0 ] 2>/dev/null; } || exit 0

if [ "$COUNT" = "1" ]; then
  codesync_notify "codesync" "${ONLY_TITLE:-1 new thread} · $PROJECT"
else
  codesync_notify "codesync" "$COUNT new threads in $PROJECT"
fi
logln "notified $COUNT"
exit 0
