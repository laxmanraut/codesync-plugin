#!/usr/bin/env bash
# claim-thread.sh — Manage the `owner` field on a thread.
#
# Default mode: claim. Sets `owner: <your-identity>`. If current status is
# `todo`, also flips it to `wip` (claiming = starting work).
#
# With --release: clears `owner`. Refuses if you're not the current owner.
#
# Args:
#   --slug <slug>          (required) filename without .md
#   --release              (optional) release mode — clears owner instead
#   --no-status-change     (optional, claim mode only) skip the todo→wip promotion
#
# Refuses to overwrite an existing `owner` set by someone else (best-effort
# race protection — same-instant claims still possible due to Syncthing's
# last-write-wins, with conflict copies preserved in .stversions/).
#
# Outputs FILE=<path> on success.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SLUG=""
NO_STATUS_CHANGE="no"
RELEASE_MODE="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)              [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    --no-status-change)  NO_STATUS_CHANGE="yes"; shift ;;
    --release)           RELEASE_MODE="yes"; shift ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ] || err "Usage: claim-thread.sh --slug <slug> [--release] [--no-status-change]"

# Populate env from resolver
. "$SCRIPT_DIR/lib/load-env.sh"
PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set (and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

# Read identity from config
IDENTITY=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
print(cfg.get("identity", ""))
' "$CFG_FILE")

[ -n "$IDENTITY" ] || err "No identity set on this machine. Run /install-codesync to register one (auto-captured from your git config user.name)."

PROJECT_PATH=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

python3 - "$SCRIPT_DIR/lib" "$PROJECT_PATH" "$SLUG" "$IDENTITY" "$NO_STATUS_CHANGE" "$RELEASE_MODE" <<'PY'
import os, re, sys

lib_dir, project_path, slug, identity, no_status_change, release_mode = sys.argv[1:7]
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
    sys.exit(f"File '{target}' has no codesync frontmatter — can't claim/release.")

current_owner  = fm.get("owner", "")
current_status = fm.get("status", "")

# ── RELEASE MODE ────────────────────────────────────────────────
if release_mode == "yes":
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
    # Atomic remove of the owner line
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
    sys.exit(0)

# ── CLAIM MODE (default) ────────────────────────────────────────
if current_owner and current_owner != identity:
    sys.exit(
        f"Already claimed by '{current_owner}'. If they've stepped away, "
        f"have them release it (/codesync-thread-claim {slug} --release)."
    )

if current_owner == identity:
    print(f"You ({identity}) already own this thread — no change needed.")
    print(f"FILE={target}")
    sys.exit(0)

# Decide whether to also promote status todo→wip
new_status = current_status
status_promoted = False
if no_status_change != "yes" and current_status == "todo":
    new_status = "wip"
    status_promoted = True

# Atomic rewrite of frontmatter block
with open(target) as f:
    content = f.read()

fm_match = re.match(r'\A(---\s*\n)(.*?\n)(---\s*\n)', content, re.DOTALL)
if not fm_match:
    sys.exit(f"Couldn't locate frontmatter block in '{target}'.")

start, block, end = fm_match.groups()

# Set owner: insert after `codesync:` if missing, otherwise replace
if re.search(r'^  owner:', block, re.MULTILINE):
    new_block = re.sub(r'^  owner: [^\n]*', f'  owner: {identity}', block, count=1, flags=re.MULTILINE)
else:
    if re.search(r'^  status:', block, re.MULTILINE):
        new_block = re.sub(r'^(  status: [^\n]*\n)', rf'\1  owner: {identity}\n', block, count=1, flags=re.MULTILINE)
    else:
        new_block = re.sub(r'^(codesync:\s*\n)', rf'\1  owner: {identity}\n', block, count=1, flags=re.MULTILINE)

# Update status if promoting
if status_promoted:
    if re.search(r'^  status:', new_block, re.MULTILINE):
        new_block = re.sub(r'^  status: [^\n]*', f'  status: {new_status}', new_block, count=1, flags=re.MULTILINE)

new_content = start + new_block + end + content[fm_match.end():]

tmp_path = target + ".tmp"
with open(tmp_path, "w") as f:
    f.write(new_content)
os.replace(tmp_path, target)

if status_promoted:
    print(f"Claimed by '{identity}' (status: {current_status} → {new_status}).")
else:
    print(f"Claimed by '{identity}'.")
print(f"FILE={target}")
PY
