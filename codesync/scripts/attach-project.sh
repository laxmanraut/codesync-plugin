#!/usr/bin/env bash
# attach-project.sh — Write .codesync/project.json in the current directory
# so that future terminals launched from this dir (or any subdirectory) auto-
# detect this project, without needing CODESYNC_PROJECT in the shell.
#
# Args:
#   --project <name>      (required) must exist in ~/.config/codesync/config.json
#   --role <name>         (optional) default role for terminals starting from here;
#                          still overrideable per-terminal via CODESYNC_ROLE.
#   --link-claude-md      (optional) also symlink the project's CLAUDE.md into cwd
#                          so Claude Code's native CLAUDE.md mechanism auto-loads
#                          project context. No-op if cwd already has CLAUDE.md.
#   --force               overwrite existing marker (and the CLAUDE.md symlink
#                          if --link-claude-md is also passed).
#
# Refuses to overwrite an existing marker without --force.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"

CFG_FILE="$HOME/.config/codesync/config.json"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT=""
ROLE=""
FORCE="no"
LINK_CLAUDE_MD="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)         [ $# -ge 2 ] || err "--project requires a value"; PROJECT="$2"; shift 2 ;;
    --role)            [ $# -ge 2 ] || err "--role requires a value";    ROLE="$2";    shift 2 ;;
    --force)           FORCE="yes"; shift ;;
    --link-claude-md)  LINK_CLAUDE_MD="yes"; shift ;;
    *) shift ;;
  esac
done

[ -n "$PROJECT" ] || err "Usage: attach-project.sh --project <name> [--role <name>] [--force]"

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

EXISTS=$($PY_BIN -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in cfg.get("projects", {}) else "no")
' "$CFG_FILE" "$PROJECT")

if [ "$EXISTS" != "yes" ] && [ "$FORCE" != "yes" ]; then
  err "Project '$PROJECT' is not registered on this machine. Run /codesync-status (in a terminal without CODESYNC_PROJECT) to see what's available, or /codesync-project-new to create it. Use --force to attach to a project you'll register later."
fi

MARKER_DIR="$(pwd)/.codesync"
MARKER_FILE="$MARKER_DIR/project.json"

if [ -f "$MARKER_FILE" ] && [ "$FORCE" != "yes" ]; then
  EXISTING=$(cat "$MARKER_FILE")
  err "$MARKER_FILE already exists with content:\n$EXISTING\n\nPass --force to overwrite."
fi

mkdir -p "$MARKER_DIR"

$PY_BIN - "$MARKER_FILE" "$PROJECT" "$ROLE" <<'PY'
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

# Optionally symlink the synced project's CLAUDE.md into cwd so Claude Code's
# native CLAUDE.md mechanism picks it up automatically.
#
# Windows (OV6): `ln -s` under Git Bash silently degrades to a COPY unless
# Developer Mode is enabled — and a copy goes permanently stale as
# collaborators update the synced file, with no error ever shown. Stale
# instructions actively mislead, so on Windows we skip the link entirely:
# the SessionStart hook already injects the synced CLAUDE.md content when
# the cwd is outside the project folder, which covers this exact case.
LINKED_CLAUDE_MD=""
if [ "$LINK_CLAUDE_MD" = "yes" ] && [ "${CODESYNC_OS:-}" = "windows" ]; then
  log "Skipped CLAUDE.md symlink on Windows: symlinks silently degrade to stale copies under Git Bash. The SessionStart hook injects the synced CLAUDE.md automatically instead — no action needed."
  LINK_CLAUDE_MD="no"
fi
if [ "$LINK_CLAUDE_MD" = "yes" ]; then
  # Look up the project path from config
  PROJ_PATH=$($PY_BIN -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
p = cfg.get("projects", {}).get(sys.argv[2])
print(p["path"] if p else "")
' "$CFG_FILE" "$PROJECT")
  SRC_CLAUDE_MD="$PROJ_PATH/CLAUDE.md"
  DST_CLAUDE_MD="$(pwd)/CLAUDE.md"

  if [ -z "$PROJ_PATH" ] || [ ! -f "$SRC_CLAUDE_MD" ]; then
    log "Skipped CLAUDE.md symlink: project has no CLAUDE.md yet at $SRC_CLAUDE_MD (re-run /install-codesync to scaffold)."
  elif [ -e "$DST_CLAUDE_MD" ] && [ "$FORCE" != "yes" ]; then
    # Already a CLAUDE.md here — don't clobber user's own
    if [ -L "$DST_CLAUDE_MD" ]; then
      log "Skipped CLAUDE.md symlink: $DST_CLAUDE_MD already exists as a symlink (leave alone, or pass --force to refresh)."
    else
      log "Skipped CLAUDE.md symlink: $DST_CLAUDE_MD already exists (user file, not touched)."
    fi
  else
    # Safe to create / refresh symlink
    [ -e "$DST_CLAUDE_MD" ] && rm -f "$DST_CLAUDE_MD"
    ln -s "$SRC_CLAUDE_MD" "$DST_CLAUDE_MD"
    LINKED_CLAUDE_MD="$DST_CLAUDE_MD"
    log "Symlinked $DST_CLAUDE_MD -> $SRC_CLAUDE_MD"
  fi
fi

printf '\n'
printf 'ATTACHED=%s\n' "$MARKER_FILE"
printf 'PROJECT=%s\n' "$PROJECT"
[ -n "$ROLE" ] && printf 'DEFAULT_ROLE=%s\n' "$ROLE" || printf 'DEFAULT_ROLE=\n'
printf 'LINKED_CLAUDE_MD=%s\n' "$LINKED_CLAUDE_MD"
