#!/usr/bin/env bash
# Hermetic test for codesync_launch_terminal (launch-agents T1 + T2).
# The visible GUI window can't be unit-tested; CODESYNC_TEST_LAUNCH_LOG captures
# the launcher script that WOULD run so we can assert its construction and,
# critically, EXECUTE it to prove the path-injection class is closed (Finding 1A).
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

LOG="$T_TMP/launch.log"
export CODESYNC_TEST_LAUNCH_LOG="$LOG"

# ── 1. Construction: valid bash; self-delete first; session file write+remove;
#       fixed exports; runs claude (not exec, so cleanup runs on exit) ─────────
codesync_launch_terminal testproj qa "$PROJ" >/dev/null
SCRIPT="$(cat "$LOG")"
t_assert "generated launcher is valid bash" bash -n "$LOG"
t_contains "launcher self-deletes (rm -f -- \$0)" 'rm -f -- "$0"' "$SCRIPT"
t_contains "launcher registers a live-session file" '.session' "$SCRIPT"
t_contains "launcher runs claude" "claude" "$SCRIPT"
t_contains "launcher removes the session file on exit" 'rm -f "$__sf"' "$SCRIPT"
t_contains "launcher exports the project" "export CODESYNC_PROJECT='testproj'" "$SCRIPT"
t_contains "launcher exports the role" "export CODESYNC_ROLE='qa'" "$SCRIPT"
# self-delete must come BEFORE claude (no lingering secret-bearing temp file).
RM_LINE=$(grep -n 'rm -f -- "$0"' "$LOG" | head -1 | cut -d: -f1)
CL_LINE=$(grep -nx 'claude' "$LOG" | head -1 | cut -d: -f1)
if [ -n "$RM_LINE" ] && [ -n "$CL_LINE" ] && [ "$RM_LINE" -lt "$CL_LINE" ]; then
  t_pass "self-delete precedes the claude run (no disposal race)"
else
  t_fail "self-delete must precede claude (rm@$RM_LINE claude@$CL_LINE)"
fi

# ── 2. CRITICAL injection regression: evil project path cannot execute ──────
# A path containing a space, a double-quote, and a $(...) command substitution.
# Built literally (single-quoted) so it is NOT executed when we create it.
EVIL_NAME='proj "x" $(touch '"$T_TMP"'/PWNED)'
EVIL_DIR="$T_TMP/$EVIL_NAME"
mkdir -p "$EVIL_DIR"

codesync_launch_terminal testproj qa "$EVIL_DIR" >/dev/null   # regenerate launcher for the evil path

# Stub claude on PATH: record cwd + the exported vars, then exit (the launcher
# `exec claude`s into this). Run a COPY of the launcher so its self-delete
# doesn't remove the captured log.
STUB="$T_TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/claude" <<EOF
#!/usr/bin/env bash
{ pwd; echo "P=\$CODESYNC_PROJECT"; echo "R=\$CODESYNC_ROLE"; } > "$T_TMP/claude-ran"
EOF
chmod +x "$STUB/claude"
cp "$LOG" "$T_TMP/run.sh"
( PATH="$STUB:$PATH" bash "$T_TMP/run.sh" ) >/dev/null 2>&1

t_refute "injection did NOT fire (no PWNED file created)" test -f "$T_TMP/PWNED"
t_assert "stubbed claude actually ran (launcher executed end-to-end)" test -f "$T_TMP/claude-ran"
RAN="$(cat "$T_TMP/claude-ran" 2>/dev/null)"
t_contains "claude ran in the literal evil dir (path treated as data)" 'proj "x" $(touch' "$RAN"
t_contains "exported project survived the launcher" "P=testproj" "$RAN"

# ── 3. Copy fallback on an unknown terminal/OS ──────────────────────────────
CODESYNC_OS=unknown codesync_launch_terminal testproj qa "$PROJ" >/dev/null
FALLBACK="$(cat "$LOG")"
t_contains "unknown OS returns a COPY fallback" "COPY	" "$FALLBACK"
t_contains "copy command sets the project" "CODESYNC_PROJECT=testproj" "$FALLBACK"
t_contains "copy command runs claude" "&& claude" "$FALLBACK"

t_done
