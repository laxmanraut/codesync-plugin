#!/usr/bin/env bash
# End-to-end thread lifecycle: write → claim → release → archive → unarchive.
. "$(dirname "$0")/lib.sh"
t_setup

OUT=$(bash "$SCRIPTS/write-thread.sh" --to backend --title "Lifecycle test" 2>&1)
t_eq "write-thread exits 0" "0" "$?"
SLUG=$(printf '%s\n' "$OUT" | sed -n 's/^SLUG=//p')
t_assert "slug emitted" test -n "$SLUG"
t_assert "thread file created" test -f "$PROJ/_inbox/backend/$SLUG.md"
t_contains "from-identity stamped" "from-identity: tester" "$(cat "$PROJ/_inbox/backend/$SLUG.md")"

OUT=$(bash "$SCRIPTS/claim-thread.sh" --slug "$SLUG" 2>&1)
t_eq "claim exits 0" "0" "$?"
t_contains "owner recorded" "owner: tester" "$(cat "$PROJ/_inbox/backend/$SLUG.md")"

OUT=$(bash "$SCRIPTS/claim-thread.sh" --slug "$SLUG" --release 2>&1)
t_eq "release exits 0" "0" "$?"

OUT=$(bash "$SCRIPTS/archive-thread.sh" --slug "$SLUG" 2>&1)
t_eq "archive exits 0" "0" "$?"
t_assert "moved to _archive" test -f "$PROJ/_archive/backend/$SLUG.md"

OUT=$(bash "$SCRIPTS/archive-thread.sh" --slug "$SLUG" --unarchive 2>&1)
t_eq "unarchive exits 0" "0" "$?"
t_assert "back in _inbox" test -f "$PROJ/_inbox/backend/$SLUG.md"

t_done
