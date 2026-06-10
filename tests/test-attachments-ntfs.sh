#!/usr/bin/env bash
# NTFS sanitizer: names illegal on Windows must be rejected BEFORE any copy.
. "$(dirname "$0")/lib.sh"
t_setup

t_thread qa demo-thread "Demo thread"

mk() { printf 'x\n' > "$1"; }

mk "$T_TMP/has:colon.png"
t_refute "illegal char (colon) rejected" \
  bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/has:colon.png"

mk "$T_TMP/trailing-dot."
t_refute "trailing dot rejected" \
  bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/trailing-dot."

mk "$T_TMP/CON.txt"
t_refute "reserved device name rejected" \
  bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/CON.txt"

mk "$T_TMP/has,comma.txt"
t_refute "comma rejected (frontmatter separator)" \
  bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/has,comma.txt"

# Case collision: attach logo.png, then LOGO.png from a DIFFERENT dir
# (mac /tmp is itself case-insensitive, so the variants can't share a dir).
mkdir -p "$T_TMP/a" "$T_TMP/b"
mk "$T_TMP/a/logo.png"
mk "$T_TMP/b/LOGO.png"
bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/a/logo.png" >/dev/null 2>&1
t_refute "case-variant of existing attachment rejected" \
  bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/b/LOGO.png"

# Nothing illegal made it to disk
t_refute "no partial copies from rejected names" test -e "$PROJ/_inbox/qa/demo-thread.attachments/CON.txt"

t_done
