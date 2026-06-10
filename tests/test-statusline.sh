#!/usr/bin/env bash
# Status line: segment output, REGRESSION notification-fires-once, seen-log
# dedup across "sessions", and the pure-bash mtime fast path.
. "$(dirname "$0")/lib.sh"
t_setup

SL="$SCRIPTS/status-line.sh"
NLOG="$CODESYNC_TEST_NOTIFY_LOG"
nlines() { [ -f "$NLOG" ] && wc -l < "$NLOG" | tr -d ' ' || echo 0; }

t_thread qa first-thread "First thread"

OUT=$(bash "$SL")
t_contains "segment shows 1 new" "codesync ▴ 1 new" "$OUT"
t_eq "first run notifies exactly once" "1" "$(nlines)"
t_contains "seen log records the thread" "_inbox/qa/first-thread.md" \
  "$(cat "$HOME/.config/codesync/seen-testproj.log")"

# Immediate re-run: fast path — cached segment, NO second notification
OUT=$(bash "$SL")
t_contains "fast path returns cached segment" "codesync ▴ 1 new" "$OUT"
t_eq "no re-notification on re-run" "1" "$(nlines)"

# Simulated second session: wipe scan marker (forces full Python scan) —
# seen-log must still suppress the toast (OV12 cross-session dedup).
rm -f "$HOME/.config/codesync/.statusline-scan-testproj"
bash "$SL" >/dev/null
t_eq "second session does not re-notify (seen-log dedup)" "1" "$(nlines)"

# New arrival → exactly one more notification
sleep 1
t_thread qa second-thread "Second thread"
OUT=$(bash "$SL")
t_contains "segment counts both" "codesync ▴ 2 new" "$OUT"
t_eq "new arrival notifies once more" "2" "$(nlines)"
t_contains "notification body names the project" "1 new thread in testproj" "$(tail -1 "$NLOG")"

# No project active → silent, exit 0
OUT=$(env -u CODESYNC_PROJECT -u CODESYNC_ROLE HOME="$HOME" bash -c "cd '$T_TMP' && bash '$SL'")
t_eq "silent without active project" "" "$OUT"

t_done
