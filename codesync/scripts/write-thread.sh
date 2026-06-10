#!/usr/bin/env bash
# write-thread.sh — Create a new thread file in the active project's inbox.
#
# Args:
#   --to <role>           (required) role this thread is addressed to
#   --title "<text>"      (required) human-readable thread title
#   --from <role>         (optional) sender role; defaults to $CODESYNC_ROLE
#   --status <status>     (optional) todo|wip|done|blocked|note; defaults to "note"
#   --replies-to <path>   (optional) relative path from project root to the parent thread
#   --body-file <path>    (optional) path to a file whose content goes after the frontmatter
#                         pass "-" to read body from stdin (useful for heredoc piping)
#
# Writes the file to: <project-path>/_inbox/<to>/<sluggified-title>.md
# Refuses to overwrite an existing file.
# Outputs THREAD_FILE=<absolute path>.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

# Parse args
TO=""
TITLE=""
FROM="${CODESYNC_ROLE:-}"
STATUS="note"
REPLIES_TO=""
BODY_FILE=""
PROJECT="${CODESYNC_PROJECT:-}"
GENERATED_BY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --to)           [ $# -ge 2 ] || err "--to requires a value"; TO="$2"; shift 2 ;;
    --title)        [ $# -ge 2 ] || err "--title requires a value"; TITLE="$2"; shift 2 ;;
    --from)         [ $# -ge 2 ] || err "--from requires a value"; FROM="$2"; shift 2 ;;
    --status)       [ $# -ge 2 ] || err "--status requires a value"; STATUS="$2"; shift 2 ;;
    --replies-to)   [ $# -ge 2 ] || err "--replies-to requires a value"; REPLIES_TO="$2"; shift 2 ;;
    --body-file)    [ $# -ge 2 ] || err "--body-file requires a value"; BODY_FILE="$2"; shift 2 ;;
    --project)      [ $# -ge 2 ] || err "--project requires a value"; PROJECT="$2"; shift 2 ;;
    --generated-by) [ $# -ge 2 ] || err "--generated-by requires a value"; GENERATED_BY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$TO" ]      || err "--to <role> is required"
[ -n "$TITLE" ]   || err "--title <text> is required"
[ -n "$FROM" ]    || err "--from <role> is required (or set CODESYNC_ROLE in the environment)"
[ -n "$PROJECT" ] || err "--project <name> is required (or set CODESYNC_PROJECT in the environment)"

# Validate status
case "$STATUS" in
  todo|wip|done|blocked|note) ;;
  *) err "--status must be one of: todo, wip, done, blocked, note (got: $STATUS)" ;;
esac

# Resolve project path
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_PATH=$($PY_BIN -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
project = cfg.get("projects", {}).get(sys.argv[2])
print(project["path"] if project else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in $CFG_FILE."
[ -d "$PROJECT_PATH" ] || err "Project path $PROJECT_PATH does not exist."

# Sluggify title for the filename
SLUG=$($PY_BIN - "$TITLE" <<'PY'
import re, sys
title = sys.argv[1].lower().strip()
slug = re.sub(r'[^a-z0-9]+', '-', title).strip('-')
if not slug:
    sys.exit("Title produced empty slug")
print(slug[:80])  # cap length
PY
)

TARGET_DIR="$PROJECT_PATH/_inbox/$TO"
mkdir -p "$TARGET_DIR"
TARGET_FILE="$TARGET_DIR/$SLUG.md"

[ -e "$TARGET_FILE" ] && err "File already exists: $TARGET_FILE. Pick a different title or edit the existing file."

# Build content
CREATED=$($PY_BIN -c 'import datetime; print(datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))')

# Look up this machine's identity (top-level field in config). Empty string if
# unset — older configs from before v0.15 won't have it; we omit the
# from-identity field rather than erroring, so existing flows still work.
IDENTITY=$($PY_BIN -c '
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(cfg.get("identity", ""))
except Exception:
    print("")
' "$CFG_FILE")

FRONTMATTER=$($PY_BIN - "$FROM" "$TO" "$STATUS" "$TITLE" "$CREATED" "$REPLIES_TO" "$IDENTITY" "$GENERATED_BY" <<'PY'
import sys
frm, to, status, title, created, replies_to, identity, generated_by = sys.argv[1:9]
lines = ["---", "codesync:"]
lines.append(f"  from: {frm}")
if identity:
    lines.append(f"  from-identity: {identity}")
lines.append(f"  to: {to}")
lines.append(f"  status: {status}")
title_esc = title.replace('"', '\\"')
lines.append(f'  title: "{title_esc}"')
lines.append(f"  created: {created}")
if replies_to:
    lines.append(f"  replies-to: {replies_to}")
if generated_by:
    lines.append(f"  generated-by: {generated_by}")
lines.append("---")
print("\n".join(lines))
PY
)

if [ "$BODY_FILE" = "-" ]; then
  BODY=$(cat -)
elif [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; then
  BODY=$(cat "$BODY_FILE")
else
  BODY="
# $TITLE

(write the thread body here)
"
fi

{
  printf '%s\n\n' "$FRONTMATTER"
  printf '%s\n' "$BODY"
} > "$TARGET_FILE"

log "Wrote thread to $TARGET_FILE"
printf '\n'
printf 'THREAD_FILE=%s\n' "$TARGET_FILE"
printf 'SLUG=%s\n' "$SLUG"
