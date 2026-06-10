# load-env.sh — Source this to populate CODESYNC_PROJECT and CODESYNC_ROLE
# from env (wins) or from a .codesync/project.json marker walk-up.
# Also loads the platform layer (CODESYNC_OS, PY_BIN, codesync_* helpers).
#
# Caller must have SCRIPT_DIR set to the scripts/ directory before sourcing.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/lib/load-env.sh"
#
# After sourcing: $CODESYNC_PROJECT / $CODESYNC_ROLE are set (possibly empty)
# and exported, and $PY_BIN points at a working Python (empty if none found —
# callers that need Python should use codesync_python which errors clearly).

. "$SCRIPT_DIR/lib/platform.sh"

if [ -n "$PY_BIN" ]; then
  # shellcheck disable=SC2086
  __codesync_resolved=$($PY_BIN "$SCRIPT_DIR/lib/resolve.py" 2>/dev/null) || __codesync_resolved=""
else
  __codesync_resolved=""
fi
eval "$__codesync_resolved"
export CODESYNC_PROJECT CODESYNC_ROLE
unset __codesync_resolved
