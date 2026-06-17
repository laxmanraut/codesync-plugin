#!/usr/bin/env bash
# autonomy-diff.sh — print a review entry's diff (base..head) from its isolation
# clone, size-capped. Read-only. The dashboard server validates the id first
# (state.review_path) and calls this for the "View diff" panel.
# Args: --project P --id ID
set -euo pipefail

CONFIG_DIR="$HOME/.config/codesync"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
LIB="$SCRIPT_DIR/lib"

PROJECT="" ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --id)      ID="$2";      shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$ID" ] || { echo "ERROR: --project --id required" >&2; exit 2; }
[ -n "${PY_BIN:-}" ] || { echo "ERROR: no usable python" >&2; exit 2; }

ENTRY=$(codesync_python - "$LIB" "$CONFIG_DIR" "$PROJECT" "$ID" <<'PY'
import sys, json
lib, cd, proj, rid = sys.argv[1:5]
sys.path.insert(0, lib)
import state
e = state.load_review(cd, proj, rid)
print(json.dumps(e) if e else "")
PY
)
[ -n "$ENTRY" ] || { echo "ERROR: unknown review id" >&2; exit 1; }
_f() { printf '%s' "$ENTRY" | codesync_python -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }
CLONE="$(_f clone_dir)"; BASE="$(_f base)"; HEAD="$(_f head)"
[ -n "$CLONE" ] && [ -n "$BASE" ] && [ -n "$HEAD" ] || { echo "ERROR: entry missing diff refs" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 1; }

# Cap the response so a huge diff can't bloat the dashboard; the full change is
# always available in the clone/branch for anyone who wants it.
git -C "$CLONE" diff "$BASE" "$HEAD" 2>/dev/null | head -c 200000
