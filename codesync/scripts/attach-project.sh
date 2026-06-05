#!/usr/bin/env bash
# attach-project.sh — Write .codesync/project.json in the current directory
# so that future terminals launched from this dir (or any subdirectory) auto-
# detect this project, without needing CODESYNC_PROJECT in the shell.
#
# Args:
#   --project <name>   (required) must exist in ~/.config/codesync/config.json
#   --role <name>      (optional) default role for terminals starting from here;
#                       still overrideable per-terminal via CODESYNC_ROLE.
#
# Refuses to overwrite an existing marker without --force.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT=""
ROLE=""
FORCE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || err "--project requires a value"; PROJECT="$2"; shift 2 ;;
    --role)    [ $# -ge 2 ] || err "--role requires a value";    ROLE="$2";    shift 2 ;;
    --force)   FORCE="yes"; shift ;;
    *) shift ;;
  esac
done

[ -n "$PROJECT" ] || err "Usage: attach-project.sh --project <name> [--role <name>] [--force]"

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

EXISTS=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in cfg.get("projects", {}) else "no")
' "$CFG_FILE" "$PROJECT")

if [ "$EXISTS" != "yes" ] && [ "$FORCE" != "yes" ]; then
  err "Project '$PROJECT' is not registered on this machine. Run /codesync-project-list to see what's available, or /codesync-project-new to create it. Use --force to attach to a project you'll register later."
fi

MARKER_DIR="$(pwd)/.codesync"
MARKER_FILE="$MARKER_DIR/project.json"

if [ -f "$MARKER_FILE" ] && [ "$FORCE" != "yes" ]; then
  EXISTING=$(cat "$MARKER_FILE")
  err "$MARKER_FILE already exists with content:\n$EXISTING\n\nPass --force to overwrite."
fi

mkdir -p "$MARKER_DIR"

python3 - "$MARKER_FILE" "$PROJECT" "$ROLE" <<'PY'
import json, sys
path, project, role = sys.argv[1:4]
data = {"project": project}
if role:
    data["default_role"] = role
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

log "Wrote $MARKER_FILE"

printf '\n'
printf 'ATTACHED=%s\n' "$MARKER_FILE"
printf 'PROJECT=%s\n' "$PROJECT"
[ -n "$ROLE" ] && printf 'DEFAULT_ROLE=%s\n' "$ROLE" || printf 'DEFAULT_ROLE=\n'
