#!/usr/bin/env bash
# Hermetic test for watch-inbox.sh — the always-on inbox watcher (one poll
# cycle). Proves the notification contract that makes the watcher safe to run
# alongside the in-session hooks:
#   - a never-seen thread in a REGISTERED role inbox fires exactly one toast
#   - a second poll does NOT re-notify (shared seen-log dedup) — the property
#     that stops watcher + statusline double-toasting the same arrival
#   - a thread in an UNregistered role is ignored (matches status-line.sh scope)
#   - the seen-log gets the entry (so time-to-notice reflects the fast notice)
#   - a quiet inbox fires nothing
#
# Notifications are captured via CODESYNC_TEST_NOTIFY_LOG (one line per toast).
. "$(dirname "$0")/lib.sh"
t_setup

SEEN_LOG="$HOME/.config/codesync/seen-testproj.log"
NLOG="$CODESYNC_TEST_NOTIFY_LOG"
run_watch() { bash "$SCRIPTS/watch-inbox.sh" >/dev/null 2>&1; }
ncount() { [ -f "$NLOG" ] && grep -c . "$NLOG" 2>/dev/null || echo 0; }

# ── quiet inbox → zero notifications ────────────────────────────────────────
run_watch
t_eq "quiet inbox fires nothing" "0" "$(ncount)"

# ── first arrival in a registered role (qa) → exactly one toast ─────────────
t_thread qa wire-gateway "Wire the gateway"
run_watch
t_eq "one new thread → one notification" "1" "$(ncount)"
t_contains "toast names the project" "testproj" "$(cat "$NLOG")"
t_contains "single-thread toast carries the title" "Wire the gateway" "$(cat "$NLOG")"
t_contains "seen-log recorded the thread" "_inbox/qa/wire-gateway.md" "$(cat "$SEEN_LOG" 2>/dev/null)"

# ── second poll, nothing new → NO re-notification (the key property) ────────
run_watch
t_eq "second poll does not re-notify (seen-log dedup)" "1" "$(ncount)"

# ── thread in an UNregistered role (backend) → ignored ──────────────────────
t_thread backend secret-build "Backend only"
run_watch
t_eq "unregistered-role thread is not notified" "1" "$(ncount)"

# ── a genuinely new registered-role thread → one more toast ─────────────────
t_thread qa parser-refactor "Refactor the parser"
run_watch
t_eq "new registered thread → one more notification" "2" "$(ncount)"
t_contains "multi-history seen-log has both qa threads" "_inbox/qa/parser-refactor.md" "$(cat "$SEEN_LOG" 2>/dev/null)"

# ── missing project env → clean non-zero exit, no toast ─────────────────────
BEFORE=$(ncount)
env -u CODESYNC_PROJECT bash "$SCRIPTS/watch-inbox.sh" >/dev/null 2>&1 \
  && t_fail "no-project run should exit non-zero" \
  || t_pass "no-project run exits non-zero"
t_eq "no-project run fires no toast" "$BEFORE" "$(ncount)"

t_done
