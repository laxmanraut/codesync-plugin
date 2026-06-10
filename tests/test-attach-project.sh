#!/usr/bin/env bash
# attach-project: marker write, overwrite refusal, Windows symlink skip.
. "$(dirname "$0")/lib.sh"
t_setup

WORK="$T_TMP/work"
mkdir -p "$WORK"
printf '# project claude md\n' > "$PROJ/CLAUDE.md"

OUT=$(cd "$WORK" && bash "$SCRIPTS/attach-project.sh" --project testproj --role qa 2>&1)
t_eq "attach exits 0" "0" "$?"
t_assert "marker written" test -f "$WORK/.codesync/project.json"
t_contains "marker carries role" '"default_role": "qa"' "$(cat "$WORK/.codesync/project.json")"

t_refute "second attach without --force refused" \
  bash -c "cd '$WORK' && bash '$SCRIPTS/attach-project.sh' --project testproj"

OUT=$(cd "$WORK" && bash "$SCRIPTS/attach-project.sh" --project testproj --force --link-claude-md 2>&1)
t_eq "force re-attach with link exits 0" "0" "$?"
if [ "$(uname -s)" = "Darwin" ] || [ "$(uname -s)" = "Linux" ]; then
  t_assert "CLAUDE.md symlinked on POSIX" test -L "$WORK/CLAUDE.md"
else
  # Windows (Git Bash): symlink silently degrades to a stale copy → must skip
  t_refute "CLAUDE.md link skipped on Windows" test -e "$WORK/CLAUDE.md"
  t_contains "skip message explains why" "Skipped CLAUDE.md symlink on Windows" "$OUT"
fi

FRESH="$T_TMP/fresh"
mkdir -p "$FRESH"
t_refute "unregistered project refused" \
  bash -c "cd '$FRESH' && bash '$SCRIPTS/attach-project.sh' --project nosuch"

t_done
