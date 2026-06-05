#!/usr/bin/env bash
# unarchive-thread.sh — Reverse of archive-thread.sh.
# Move _archive/<role>/<slug>.md → _inbox/<role>/<slug>.md.
#
# Searches across every role's archive under the active project. Refuses
# if the destination inbox path already exists.
#
# Args:
#   --slug <slug>   (required) the filename without .md
#
# Output: UNARCHIVED=<destination> and FROM=<source>.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

. "$SCRIPT_DIR/lib/load-env.sh"

SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ] || err "Usage: unarchive-thread.sh --slug <slug>"

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active (CODESYNC_PROJECT unset and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_PATH=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

ARCHIVE_ROOT="$PROJECT_PATH/_archive"
INBOX_ROOT="$PROJECT_PATH/_inbox"

[ -d "$ARCHIVE_ROOT" ] || err "No _archive/ directory in project at $PROJECT_PATH (nothing has been archived yet)."

TARGET=""
ROLE=""
for role_dir in "$ARCHIVE_ROOT"/*/; do
  [ -d "$role_dir" ] || continue
  candidate="${role_dir}${SLUG}.md"
  if [ -f "$candidate" ]; then
    TARGET="$candidate"
    ROLE="$(basename "$role_dir")"
    break
  fi
done

[ -n "$TARGET" ] || err "Thread '$SLUG' not found in any archive of project '$PROJECT'. Run /codesync-thread-list --archive to see what's there."

DEST_DIR="$INBOX_ROOT/$ROLE"
DEST_PATH="$DEST_DIR/$SLUG.md"

[ ! -e "$DEST_PATH" ] || err "Inbox destination already exists: $DEST_PATH. Won't overwrite."

mkdir -p "$DEST_DIR"
mv "$TARGET" "$DEST_PATH"

log "Unarchived $TARGET → $DEST_PATH"
printf '\n'
printf 'UNARCHIVED=%s\n' "$DEST_PATH"
printf 'FROM=%s\n' "$TARGET"
printf 'ROLE=%s\n' "$ROLE"
