#!/usr/bin/env bash
# autonomy-review.sh — server entrypoint for approve/reject of a review entry.
# The dashboard server validates the write gate AND that the id is a real review
# (state.review_path) BEFORE calling this; here we only act. Prints a one-line
# result: APPROVED… / REJECTED… / BLOCKED… / CONFLICT… / FAILED…
#
# Two-gate approve (eng-review A3): approve lands the rebased branch in the LOCAL
# repo only; codesync never writes the synced folder or live tree and never
# reaches a peer — the human merges + syncs it themselves.
# Args: --project P --id ID --action approve|reject
set -euo pipefail

CONFIG_DIR="$HOME/.config/codesync"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/autonomy.sh"
LIB="$SCRIPT_DIR/lib"

PROJECT="" ID="" ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --id)      ID="$2";      shift 2 ;;
    --action)  ACTION="$2";  shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$ID" ] && [ -n "$ACTION" ] || { echo "ERROR: --project --id --action required" >&2; exit 2; }
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
_field() { printf '%s' "$ENTRY" | codesync_python -c "import json,sys;print(json.load(sys.stdin).get('$1',''))"; }
BRANCH="$(_field branch)"; BASEBR="$(_field base_branch)"; CLONE="$(_field clone_dir)"; STATUS="$(_field status)"

_set_status() {
  codesync_python - "$LIB" "$CONFIG_DIR" "$PROJECT" "$ID" "$1" <<'PY'
import sys
lib, cd, proj, rid, st = sys.argv[1:6]
sys.path.insert(0, lib)
import state
state.set_review_status(cd, proj, rid, st)
PY
}

case "$ACTION" in
  approve)
    [ "$STATUS" = "blocked" ] && { echo "BLOCKED entry touches a secret-denylisted file — approve refused"; exit 1; }
    [ "$STATUS" = "pending" ] || { echo "FAILED not pending (status=$STATUS)"; exit 1; }
    set +e; codesync_autonomy_approve "$CLONE" "$BRANCH" "$BASEBR"; rc=$?; set -e
    case "$rc" in
      0) _set_status approved; echo "APPROVED $BRANCH landed in your local repo — merge + sync it yourself" ;;
      2) echo "CONFLICT rebase against current base failed — resolve manually"; exit 1 ;;
      *) echo "FAILED could not approve $BRANCH"; exit 1 ;;
    esac
    ;;
  reject)
    codesync_autonomy_reject "$CLONE" "$BRANCH"
    _set_status rejected
    echo "REJECTED $BRANCH dropped"
    ;;
  *)
    echo "ERROR: unknown action '$ACTION'" >&2; exit 2 ;;
esac
