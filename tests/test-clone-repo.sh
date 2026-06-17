#!/usr/bin/env bash
# Test clone-repo.sh: clones a project's repo_url locally + records repo_path,
# refuses a clone dir inside a synced folder, and reuses an existing clone.
# Uses a local file:// repo so the real `git clone` path runs hermetically.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
CD="$HOME/.config/codesync"

command -v git >/dev/null 2>&1 || { t_pass "git unavailable — skipping clone test"; t_done; exit 0; }

SRC="$T_TMP/src"
mkdir -p "$SRC"
( cd "$SRC" && git -c init.defaultBranch=main init -q && git config user.email t@t && git config user.name t \
  && echo hi > a.txt && git add a.txt && git commit -q -m init )
URL="file://$SRC"
CLONE="$T_TMP/clone"

OUT=$(bash "$SCRIPTS/clone-repo.sh" --project testproj --url "$URL" --dir "$CLONE" 2>&1)
t_contains "clone-repo reports CLONED"          "CLONED"     "$OUT"
t_assert  "clone is a real git repo"            test -d "$CLONE/.git"
t_assert  "cloned content is present"           test -f "$CLONE/a.txt"
RP=$($PY_BIN - "$SCRIPTS/lib" "$CD" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import state
print((state.load_autonomy(sys.argv[2]).get("projects",{}).get("testproj",{}) or {}).get("repo_path",""))
PY
)
t_assert "repo_path was recorded as a git repo" test -d "$RP/.git"

# SECURITY: a clone dir inside the synced project folder is refused.
OUT2=$(bash "$SCRIPTS/clone-repo.sh" --project testproj --url "$URL" --dir "$PROJ/sub/clone" 2>&1)
t_contains "clone into a synced folder is refused" "OUTSIDE every synced" "$OUT2"
t_refute  "nothing was cloned inside the synced folder" test -d "$PROJ/sub/clone/.git"

# Re-running reuses the existing clone (idempotent).
OUT3=$(bash "$SCRIPTS/clone-repo.sh" --project testproj --url "$URL" --dir "$CLONE" 2>&1)
t_contains "re-run reuses the existing clone" "reusing existing clone" "$OUT3"

t_done
