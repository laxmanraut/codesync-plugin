#!/usr/bin/env bash
# Stop hook: baseline behavior, role filtering, and seen-log marking (OV7/OV12).
. "$(dirname "$0")/lib.sh"
t_setup

SC="$SCRIPTS/stop-check.sh"

# First run establishes baseline silently
OUT=$(bash "$SC")
t_eq "first run is silent (baseline)" "" "$OUT"

# New thread for the registered role surfaces
t_thread qa hook-thread "Hook thread"
OUT=$(bash "$SC")
t_contains "new thread surfaced" "hook-thread" "$OUT"
t_contains "header names project+role" "project=testproj" "$OUT"

# ...and is recorded in the shared first-seen log (wedge instrumentation)
t_contains "stop-check marks thread seen" "_inbox/qa/hook-thread.md" \
  "$(cat "$HOME/.config/codesync/seen-testproj.log")"

# Status line afterwards must NOT toast for it (cross-hook dedup)
bash "$SCRIPTS/status-line.sh" >/dev/null
N=$([ -f "$CODESYNC_TEST_NOTIFY_LOG" ] && wc -l < "$CODESYNC_TEST_NOTIFY_LOG" | tr -d ' ' || echo 0)
t_eq "no toast after stop-check already surfaced it" "0" "$N"

# Thread for an UNregistered role is suppressed (role filter)
t_thread backend other-role-thread "Not for qa"
OUT=$(bash "$SC")
case "$OUT" in
  *other-role-thread*) t_fail "unregistered-role thread should be filtered" ;;
  *) t_pass "unregistered-role thread filtered out" ;;
esac

t_done
