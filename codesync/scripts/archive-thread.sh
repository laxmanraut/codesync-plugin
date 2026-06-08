#!/usr/bin/env bash
# archive-thread.sh — Move a thread from _inbox/<role>/<slug>.md to
# _archive/<role>/<slug>.md, preserving role + file contents.
#
# Searches across every role's inbox under the active project. Refuses
# if the destination archive path already exists (collision).
#
# Args:
#   --slug <slug>   (required) the filename without .md
#
# Output: ARCHIVED=<destination> and FROM=<source>.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ] || err "Usage: archive-thread.sh --slug <slug>"

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

INBOX_ROOT="$PROJECT_PATH/_inbox"
ARCHIVE_ROOT="$PROJECT_PATH/_archive"

[ -d "$INBOX_ROOT" ] || err "No _inbox/ directory in project at $PROJECT_PATH."

# Find <slug>.md across all role inboxes
TARGET=""
ROLE=""
for role_dir in "$INBOX_ROOT"/*/; do
  [ -d "$role_dir" ] || continue
  candidate="${role_dir}${SLUG}.md"
  if [ -f "$candidate" ]; then
    TARGET="$candidate"
    ROLE="$(basename "$role_dir")"
    break
  fi
done

[ -n "$TARGET" ] || err "Thread '$SLUG' not found in any inbox of project '$PROJECT'. Run /codesync-thread-list to see what's there."

DEST_DIR="$ARCHIVE_ROOT/$ROLE"
DEST_PATH="$DEST_DIR/$SLUG.md"

[ ! -e "$DEST_PATH" ] || err "Archive destination already exists: $DEST_PATH. Won't overwrite."

mkdir -p "$DEST_DIR"
mv "$TARGET" "$DEST_PATH"

# Move the thread's .attachments/ directory along with it, if it exists
SRC_ATTACH_DIR="${TARGET%.md}.attachments"
DEST_ATTACH_DIR="${DEST_PATH%.md}.attachments"
MOVED_ATTACHMENTS=""
if [ -d "$SRC_ATTACH_DIR" ]; then
  if [ -e "$DEST_ATTACH_DIR" ]; then
    log "WARNING: $DEST_ATTACH_DIR already exists; leaving attachments at source ($SRC_ATTACH_DIR)."
  else
    mv "$SRC_ATTACH_DIR" "$DEST_ATTACH_DIR"
    MOVED_ATTACHMENTS="$DEST_ATTACH_DIR"
    log "Moved attachments: $SRC_ATTACH_DIR → $DEST_ATTACH_DIR"
  fi
fi

log "Archived $TARGET → $DEST_PATH"
printf '\n'
printf 'ARCHIVED=%s\n' "$DEST_PATH"
printf 'FROM=%s\n' "$TARGET"
printf 'ROLE=%s\n' "$ROLE"
printf 'MOVED_ATTACHMENTS=%s\n' "$MOVED_ATTACHMENTS"
