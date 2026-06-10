#!/usr/bin/env bash
# archive-thread.sh — Archive (or unarchive) a thread file.
#
# Default mode: move from _inbox/<role>/<slug>.md to _archive/<role>/<slug>.md.
# With --unarchive: reverse — move from _archive/ back to _inbox/.
#
# Args:
#   --slug <slug>     (required) the filename without .md
#   --unarchive       (optional) unarchive mode — reverses the move
#
# Searches across every role's _inbox/ (or _archive/ in unarchive mode) under
# the active project. Refuses if the destination already exists.
#
# Output: ARCHIVED=<dest> + FROM=<src> + ROLE=<role> + MOVED_ATTACHMENTS=<dir>
# (or UNARCHIVED=<dest> in unarchive mode).

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

. "$SCRIPT_DIR/lib/load-env.sh"

SLUG=""
UNARCHIVE_MODE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)       [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    --unarchive)  UNARCHIVE_MODE="yes"; shift ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ] || err "Usage: archive-thread.sh --slug <slug> [--unarchive]"

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active (CODESYNC_PROJECT unset and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_PATH=$($PY_BIN -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

INBOX_ROOT="$PROJECT_PATH/_inbox"
ARCHIVE_ROOT="$PROJECT_PATH/_archive"

# Determine source + destination roots based on mode
if [ "$UNARCHIVE_MODE" = "yes" ]; then
  SRC_ROOT="$ARCHIVE_ROOT"
  DST_ROOT="$INBOX_ROOT"
  [ -d "$SRC_ROOT" ] || err "No _archive/ directory in project at $PROJECT_PATH (nothing has been archived yet)."
  OP_VERB="Unarchived"
  SRC_LABEL="archive"
  DST_LABEL="inbox"
else
  SRC_ROOT="$INBOX_ROOT"
  DST_ROOT="$ARCHIVE_ROOT"
  [ -d "$SRC_ROOT" ] || err "No _inbox/ directory in project at $PROJECT_PATH."
  OP_VERB="Archived"
  SRC_LABEL="inbox"
  DST_LABEL="archive"
fi

# Find <slug>.md under any role dir in SRC_ROOT
TARGET=""
ROLE=""
for role_dir in "$SRC_ROOT"/*/; do
  [ -d "$role_dir" ] || continue
  candidate="${role_dir}${SLUG}.md"
  if [ -f "$candidate" ]; then
    TARGET="$candidate"
    ROLE="$(basename "$role_dir")"
    break
  fi
done

[ -n "$TARGET" ] || err "Thread '$SLUG' not found in any $SRC_LABEL of project '$PROJECT'. Run /codesync-thread-list to see what's there."

DEST_DIR="$DST_ROOT/$ROLE"
DEST_PATH="$DEST_DIR/$SLUG.md"

[ ! -e "$DEST_PATH" ] || err "Destination already exists: $DEST_PATH. Won't overwrite."

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

log "$OP_VERB $TARGET → $DEST_PATH"
printf '\n'
if [ "$UNARCHIVE_MODE" = "yes" ]; then
  printf 'UNARCHIVED=%s\n' "$DEST_PATH"
else
  printf 'ARCHIVED=%s\n' "$DEST_PATH"
fi
printf 'FROM=%s\n' "$TARGET"
printf 'ROLE=%s\n' "$ROLE"
printf 'MOVED_ATTACHMENTS=%s\n' "$MOVED_ATTACHMENTS"
