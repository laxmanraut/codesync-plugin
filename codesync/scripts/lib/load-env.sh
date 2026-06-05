# load-env.sh — Source this to populate CODESYNC_PROJECT and CODESYNC_ROLE
# from env (wins) or from a .codesync/project.json marker walk-up.
#
# Caller must have SCRIPT_DIR set to the scripts/ directory before sourcing.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/lib/load-env.sh"
#
# After sourcing, $CODESYNC_PROJECT and $CODESYNC_ROLE are set (possibly to
# empty strings) and exported, so subsequent child processes (including
# Python heredocs) see them.

__codesync_resolved=$(python3 "$SCRIPT_DIR/lib/resolve.py" 2>/dev/null) || __codesync_resolved=""
eval "$__codesync_resolved"
export CODESYNC_PROJECT CODESYNC_ROLE
unset __codesync_resolved
