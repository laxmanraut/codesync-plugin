#!/usr/bin/env bash
# Unit test for control-panel Layer 3 LOCAL-authority config (state.py):
# set_autonomy_repo / set_autonomy_role / resolve_autonomy_role / is_inside_synced.
# The load-bearing safety property: repo_path inside a synced project is REFUSED
# (agent code/diffs must not reach a peer pre-review), and autonomy authority is
# local — resolve reads ONLY autonomy.json, never the synced role file.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
CD="$HOME/.config/codesync"
CFG="$CD/config.json"

# A git repo OUTSIDE any synced project; and a git repo INSIDE the synced project.
OUTSIDE="$T_TMP/outside-repo"
mkdir -p "$OUTSIDE"; ( cd "$OUTSIDE" && git init -q && git config user.email t@t && git config user.name t )
INSIDE="$PROJ/sub"
mkdir -p "$INSIDE"; ( cd "$INSIDE" && git init -q )

OUT=$($PY_BIN - "$SCRIPTS/lib" "$CD" "$CFG" "$OUTSIDE" "$INSIDE" "$PROJ" <<'PY'
import sys, json
lib, cd, cfg, outside, inside, proj = sys.argv[1:7]
sys.path.insert(0, lib)
import state
c = state.load_config(cfg)
print("INSIDE_PROJ", state.is_inside_synced(proj, c))
print("INSIDE_SUB", state.is_inside_synced(inside, c))
print("OUTSIDE", state.is_inside_synced(outside, c))
ok, e = state.set_autonomy_repo(cd, "testproj", inside, c);        print("SET_INSIDE", ok, e)
ok, e = state.set_autonomy_repo(cd, "testproj", "/no/such/p", c);  print("SET_MISSING", ok)
ok, e = state.set_autonomy_repo(cd, "testproj", outside, c);       print("SET_OUTSIDE", ok)
state.set_autonomy_role(cd, "testproj", "backend", enabled=True, allowed_tools="Read,Edit")
print("RESOLVE_ON", json.dumps(state.resolve_autonomy_role(cd, "testproj", "backend"), sort_keys=True))
state.set_autonomy_role(cd, "testproj", "backend", enabled=False)
print("RESOLVE_OFF", state.resolve_autonomy_role(cd, "testproj", "backend"))
print("RESOLVE_GHOST", state.resolve_autonomy_role(cd, "testproj", "ghost"))
print("CLONE_OUTSIDE", not state.is_inside_synced(state.autonomy_clone_dir(cd, "testproj", "backend"), c))
PY
)

t_contains "synced project path is inside-synced"        "INSIDE_PROJ True" "$OUT"
t_contains "subdir of synced project is inside-synced"   "INSIDE_SUB True" "$OUT"
t_contains "a sibling repo is NOT inside-synced"         "OUTSIDE False" "$OUT"
t_contains "repo_path inside a synced folder is REFUSED" "SET_INSIDE False" "$OUT"
t_contains "refusal names the outside-synced rule"       "OUTSIDE every synced" "$OUT"
t_contains "missing repo_path refused"                   "SET_MISSING False" "$OUT"
t_contains "outside git repo accepted"                   "SET_OUTSIDE True" "$OUT"
t_contains "enabled role resolves with its local tools"  '"allowed_tools": "Read,Edit"' "$OUT"
t_contains "disabled role resolves to None"              "RESOLVE_OFF None" "$OUT"
t_contains "unknown role resolves to None"               "RESOLVE_GHOST None" "$OUT"
t_contains "clone dir is outside synced by construction" "CLONE_OUTSIDE True" "$OUT"

t_done
