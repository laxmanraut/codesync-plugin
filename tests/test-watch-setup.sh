#!/usr/bin/env bash
# Hermetic test for watch-setup.sh — verifies the SCHEDULED-JOB ARTIFACT it
# generates (launchd plist on macOS, schtasks command + .cmd launcher on
# Windows) without touching the real OS scheduler. The CODESYNC_TEST_SCHED_LOG
# hook short-circuits launchctl/schtasks and records what WOULD be registered;
# the live registration is validated manually (it can't run in CI).
#
# Branches on uname so the macOS runner checks the plist and the Windows runner
# checks the schtasks/.cmd path — matching CI's two-runner matrix.
. "$(dirname "$0")/lib.sh"
t_setup

export CODESYNC_TEST_SCHED_LOG="$T_TMP/sched.log"
: > "$CODESYNC_TEST_SCHED_LOG"
run() { bash "$SCRIPTS/watch-setup.sh" "$@" >/dev/null 2>&1; }

case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.codesync.watch.testproj.plist"
    run                                   # install
    SCHED="$(cat "$CODESYNC_TEST_SCHED_LOG")"
    t_contains "macOS: launchd load recorded" "MACOS_LOAD label=com.codesync.watch.testproj" "$SCHED"
    t_contains "macOS: interval is 120s"      "interval=120" "$SCHED"
    t_assert   "macOS: plist written"         test -f "$PLIST"
    PL="$(cat "$PLIST" 2>/dev/null)"
    t_contains "plist bakes the project"      "<string>testproj</string>" "$PL"
    t_contains "plist runs watch-inbox.sh"    "watch-inbox.sh" "$PL"
    t_contains "plist polls on interval"      "<integer>120</integer>" "$PL"
    t_contains "plist surfaces pending on login (RunAtLoad)" "<key>RunAtLoad</key>" "$PL"
    : > "$CODESYNC_TEST_SCHED_LOG"
    run --teardown
    t_contains "macOS: teardown recorded" "MACOS_UNLOAD" "$(cat "$CODESYNC_TEST_SCHED_LOG")"
    t_refute  "macOS: plist removed on teardown" test -f "$PLIST"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    LAUNCHER="$HOME/.config/codesync/watch-testproj.cmd"
    run                                   # install
    SCHED="$(cat "$CODESYNC_TEST_SCHED_LOG")"
    t_contains "windows: schtasks task name" "WIN_SCHTASKS task=codesync-watch-testproj" "$SCHED"
    t_contains "windows: launcher captured"  "WIN_LAUNCHER" "$SCHED"
    t_assert   "windows: .cmd launcher written" test -f "$LAUNCHER"
    CMD="$(cat "$LAUNCHER" 2>/dev/null)"
    t_contains "launcher bakes the project (no env dict)" "set CODESYNC_PROJECT=testproj" "$CMD"
    t_contains "launcher invokes watch-inbox.sh" "watch-inbox.sh" "$CMD"
    : > "$CODESYNC_TEST_SCHED_LOG"
    run --teardown
    t_contains "windows: delete recorded" "WIN_DELETE task=codesync-watch-testproj" "$(cat "$CODESYNC_TEST_SCHED_LOG")"
    ;;
  *)
    t_pass "watcher scheduling not supported on this OS — nothing to test"
    ;;
esac

t_done
