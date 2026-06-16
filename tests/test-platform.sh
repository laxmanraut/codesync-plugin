#!/usr/bin/env bash
# Platform layer: OS detection, Python resolution, mtime helper.
. "$(dirname "$0")/lib.sh"
t_setup

. "$SCRIPTS/lib/platform.sh"

case "$(uname -s)" in
  Darwin)              WANT="macos" ;;
  MINGW*|MSYS*|CYGWIN*) WANT="windows" ;;
  *)                   WANT="$CODESYNC_OS" ;;  # unknown platforms: just non-empty
esac
t_eq "CODESYNC_OS detected" "$WANT" "$CODESYNC_OS"

t_assert "PY_BIN resolved" test -n "$PY_BIN"
t_assert "PY_BIN runs -c (Store-stub filter)" $PY_BIN -c 'import sys'

F="$T_TMP/mtime-probe"
touch "$F"
M=$(codesync_mtime "$F")
t_assert "codesync_mtime returns integer" test "$M" -gt 0

codesync_notify "title" "body"
t_contains "codesync_notify uses test hook" "title|body" "$(cat "$CODESYNC_TEST_NOTIFY_LOG")"

# codesync_ps_lit — neutralizes single quotes so a peer-controlled thread title
# can't break out of the Windows PowerShell single-quoted toast literal (RCE).
t_eq "ps_lit doubles a single quote"            "a''b"            "$(codesync_ps_lit "a'b")"
t_eq "ps_lit passes benign text untouched"      "Wire the gateway" "$(codesync_ps_lit "Wire the gateway")"
t_eq "ps_lit neutralizes a breakout payload"    "x''; calc; ''"   "$(codesync_ps_lit "x'; calc; '")"

t_done
