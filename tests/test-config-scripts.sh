#!/usr/bin/env bash
# Config-touching scripts (sandboxed HOME): set-thread-status, list-docs,
# register-identity, register-role-in-config, seed-project-docs.
. "$(dirname "$0")/lib.sh"
t_setup

# write a thread to operate on
OUT=$(bash "$SCRIPTS/write-thread.sh" --to qa --title "Smoke target" 2>&1)
SLUG=$(printf '%s\n' "$OUT" | sed -n 's/^SLUG=//p')

OUT=$(bash "$SCRIPTS/set-thread-status.sh" --slug "$SLUG" --status done 2>&1)
t_eq "set-thread-status exits 0" "0" "$?"
t_contains "status updated" "status: done" "$(cat "$PROJ/_inbox/qa/$SLUG.md")"

# Non-ASCII regression (PYTHONUTF8): German umlauts in the title must survive
# the read-modify-write cycle — native Windows Python defaults to cp1252 for
# stdout AND open(), which crashed set-thread-status (it prints a → glyph).
OUT=$(bash "$SCRIPTS/write-thread.sh" --to qa --title "Übergabe prüfen: Ärger mit März-Daten" 2>&1)
t_eq "umlaut thread write exits 0" "0" "$?"
USLUG=$(printf '%s\n' "$OUT" | sed -n 's/^SLUG=//p')
OUT=$(bash "$SCRIPTS/set-thread-status.sh" --slug "$USLUG" --status wip 2>&1)
t_eq "umlaut set-thread-status exits 0" "0" "$?"
t_contains "umlauts intact after rewrite" "Übergabe prüfen" "$(cat "$PROJ/_inbox/qa/$USLUG.md")"

printf '# Doc A\ncontent\n' > "$PROJ/_docs/doc-a.md"
OUT=$(bash "$SCRIPTS/list-docs.sh" 2>&1)
t_eq "list-docs exits 0" "0" "$?"
t_contains "doc listed" "doc-a" "$OUT"

OUT=$(bash "$SCRIPTS/register-identity.sh" --suggest 2>&1)
t_eq "register-identity --suggest exits 0" "0" "$?"
t_contains "suggest output shape" "GIT_FOUND=" "$OUT"

OUT=$(bash "$SCRIPTS/register-identity.sh" --set smoketester 2>&1)
t_eq "register-identity --set exits 0" "0" "$?"
t_contains "identity saved in sandbox config" '"identity": "smoketester"' "$(cat "$HOME/.config/codesync/config.json")"

OUT=$(bash "$SCRIPTS/register-role-in-config.sh" --project testproj --role designer 2>&1)
t_eq "register-role exits 0" "0" "$?"
t_contains "role appended" "designer" "$(cat "$HOME/.config/codesync/config.json")"

OUT=$(bash "$SCRIPTS/seed-project-docs.sh" --project testproj --path "$PROJ" 2>&1)
t_eq "seed-project-docs exits 0" "0" "$?"
t_assert "CLAUDE.md scaffolded" test -f "$PROJ/CLAUDE.md"

t_done
