#!/usr/bin/env bash
# REGRESSION: a perfectly legal attachment name must still attach cleanly
# (guards against the NTFS sanitizer over-rejecting).
. "$(dirname "$0")/lib.sh"
t_setup

t_thread qa demo-thread "Demo thread"
printf 'fake png bytes\n' > "$T_TMP/legal-name_v2.png"

OUT=$(bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/legal-name_v2.png" 2>&1)
RC=$?
t_eq "attach exits 0" "0" "$RC"
t_assert "file copied into .attachments/" test -f "$PROJ/_inbox/qa/demo-thread.attachments/legal-name_v2.png"
t_contains "frontmatter updated" "attachments: legal-name_v2.png" "$(cat "$PROJ/_inbox/qa/demo-thread.md")"

# Same-name overwrite stays allowed (Syncthing versioning covers history)
OUT=$(bash "$SCRIPTS/attach-thread.sh" --slug demo-thread --file "$T_TMP/legal-name_v2.png" 2>&1)
t_eq "same-name re-attach exits 0" "0" "$?"

t_done
