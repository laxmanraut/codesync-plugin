#!/usr/bin/env bash
# set-thread-status.sh — Update the `status` field of a thread's frontmatter.
#
# Args:
#   --slug <slug>      (required) filename without .md, e.g. owner-inbox
#   --status <status>  (required) one of todo|wip|done|blocked|note
#
# Searches all of <project>/_inbox/*/<slug>.md to find the thread (user
# might be marking a thread done that's in their own outbound inbox, i.e.
# in the recipient's inbox folder). Atomically rewrites the file with the
# new status. Errors if the file has no codesync frontmatter.
#
# Outputs FILE=<path> on success.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SLUG=""
NEW_STATUS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)   [ $# -ge 2 ] || err "--slug requires a value";   SLUG="$2"; shift 2 ;;
    --status) [ $# -ge 2 ] || err "--status requires a value"; NEW_STATUS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ]       || err "Usage: set-thread-status.sh --slug <slug> --status <status>"
[ -n "$NEW_STATUS" ] || err "Usage: set-thread-status.sh --slug <slug> --status <status>"

case "$NEW_STATUS" in
  todo|wip|done|blocked|note) ;;
  *) err "--status must be one of: todo, wip, done, blocked, note (got: $NEW_STATUS)" ;;
esac

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"
PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set (and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_PATH=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

python3 - "$SCRIPT_DIR/lib" "$PROJECT_PATH" "$SLUG" "$NEW_STATUS" <<'PY'
import os, re, sys

lib_dir, project_path, slug, new_status = sys.argv[1:5]
sys.path.insert(0, lib_dir)
from frontmatter import read_frontmatter_from_file

# Find the file across all _inbox/<role>/ subdirs
inbox_root = os.path.join(project_path, "_inbox")
if not os.path.isdir(inbox_root):
    sys.exit(f"No _inbox/ directory in project at {project_path}.")

target = None
for d in sorted(os.listdir(inbox_root)):
    candidate = os.path.join(inbox_root, d, slug + ".md")
    if os.path.isfile(candidate):
        target = candidate
        break

if not target:
    sys.exit(f"Thread '{slug}' not found in any _inbox/<role>/ under the project. Run /codesync-thread-list to see what's there.")

fm = read_frontmatter_from_file(target)
if not fm:
    sys.exit(f"File '{target}' has no codesync frontmatter — can't update status. Edit the file by hand if it predates the structured-thread format.")

current_status = fm.get("status", "")
if current_status == new_status:
    print(f"Status already '{new_status}' — no change.")
    print(f"FILE={target}")
    sys.exit(0)

with open(target) as f:
    content = f.read()

fm_match = re.match(r'\A(---\s*\n)(.*?\n)(---\s*\n)', content, re.DOTALL)
if not fm_match:
    sys.exit(f"Couldn't locate frontmatter block in '{target}'.")

start, block, end = fm_match.groups()

if re.search(r'^  status:', block, re.MULTILINE):
    new_block = re.sub(r'^  status: [^\n]*', f'  status: {new_status}', block, count=1, flags=re.MULTILINE)
else:
    # No existing status field — insert it just after the `codesync:` line
    new_block = re.sub(r'^(codesync:\s*\n)', rf'\1  status: {new_status}\n', block, count=1, flags=re.MULTILINE)

new_content = start + new_block + end + content[fm_match.end():]

# Atomic write via temp file + rename
tmp_path = target + ".tmp"
with open(tmp_path, "w") as f:
    f.write(new_content)
os.replace(tmp_path, target)

print(f"Updated status: {current_status or '(none)'} → {new_status}")
print(f"FILE={target}")
PY
