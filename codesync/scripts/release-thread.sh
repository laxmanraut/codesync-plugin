#!/usr/bin/env bash
# release-thread.sh — Clear the `owner` field on a thread.
#
# Args:
#   --slug <slug>   (required) filename without .md
#
# Removes the `owner` line from frontmatter, returning the thread to the
# unclaimed pool. Refuses to release a thread owned by someone else.
#
# Outputs FILE=<path> on success.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ] || err "Usage: release-thread.sh --slug <slug>"

. "$SCRIPT_DIR/lib/load-env.sh"
PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set (and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

IDENTITY=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get("identity", ""))
' "$CFG_FILE")

[ -n "$IDENTITY" ] || err "No identity set on this machine. Run /install-codesync first."

PROJECT_PATH=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

python3 - "$SCRIPT_DIR/lib" "$PROJECT_PATH" "$SLUG" "$IDENTITY" <<'PY'
import os, re, sys

lib_dir, project_path, slug, identity = sys.argv[1:5]
sys.path.insert(0, lib_dir)
from frontmatter import read_frontmatter_from_file

inbox_root = os.path.join(project_path, "_inbox")
if not os.path.isdir(inbox_root):
    sys.exit(f"No _inbox/ in project at {project_path}.")

target = None
for d in sorted(os.listdir(inbox_root)):
    candidate = os.path.join(inbox_root, d, slug + ".md")
    if os.path.isfile(candidate):
        target = candidate
        break

if not target:
    sys.exit(f"Thread '{slug}' not found in any _inbox/<role>/ under the project.")

fm = read_frontmatter_from_file(target)
if not fm:
    sys.exit(f"File '{target}' has no codesync frontmatter.")

current_owner = fm.get("owner", "")
if not current_owner:
    print(f"Thread is already unclaimed — no change.")
    print(f"FILE={target}")
    sys.exit(0)

if current_owner != identity:
    sys.exit(
        f"Thread is owned by '{current_owner}', not you ('{identity}'). "
        f"Have them release it themselves, or claim it explicitly with "
        f"/codesync-thread-claim {slug}."
    )

with open(target) as f:
    content = f.read()

fm_match = re.match(r'\A(---\s*\n)(.*?\n)(---\s*\n)', content, re.DOTALL)
if not fm_match:
    sys.exit(f"Couldn't locate frontmatter block in '{target}'.")

start, block, end = fm_match.groups()
new_block = re.sub(r'^  owner: [^\n]*\n', '', block, count=1, flags=re.MULTILINE)

new_content = start + new_block + end + content[fm_match.end():]

tmp_path = target + ".tmp"
with open(tmp_path, "w") as f:
    f.write(new_content)
os.replace(tmp_path, target)

print(f"Released. Thread no longer owned by '{identity}'.")
print(f"FILE={target}")
PY
