#!/usr/bin/env bash
# list-threads.sh — List thread files in the active project's inbox for the active role.
# Reads frontmatter to enrich each entry with status, from, title.
#
# Optional args:
#   --status <s>   filter to threads with that status (todo|wip|done|blocked|note)
#   --all-inboxes  list threads in every role's inbox (default: just the active role's)

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

FILTER_STATUS=""
ALL_INBOXES="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --status)              [ $# -ge 2 ] || err "--status requires a value"; FILTER_STATUS="$2"; shift 2 ;;
    --all|--all-inboxes)   ALL_INBOXES="yes"; shift ;;
    *)                     shift ;;
  esac
done

PROJECT="${CODESYNC_PROJECT:-}"
ROLE="${CODESYNC_ROLE:-}"

[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 - "$SCRIPT_DIR/lib" "$CFG_FILE" "$PROJECT" "$ROLE" "$FILTER_STATUS" "$ALL_INBOXES" <<'PY'
import json, os, sys, time

lib_dir, cfg_path, project, role, filter_status, all_inboxes = sys.argv[1:7]
sys.path.insert(0, lib_dir)
from frontmatter import read_frontmatter_from_file

all_inboxes = (all_inboxes == "yes")

with open(cfg_path) as f:
    cfg = json.load(f)

proj = cfg.get("projects", {}).get(project)
if not proj:
    sys.exit(f"Project '{project}' not found in config.")

proj_path = proj["path"]
inbox_root = os.path.join(proj_path, "_inbox")

if not os.path.isdir(inbox_root):
    print(f"No _inbox/ directory in project '{project}'.")
    sys.exit(0)

# Decide which subfolders to scan
if all_inboxes:
    inbox_dirs = [
        os.path.join(inbox_root, d)
        for d in sorted(os.listdir(inbox_root))
        if os.path.isdir(os.path.join(inbox_root, d))
    ]
    header = f"Threads in all inboxes of project '{project}':"
elif role:
    inbox_dirs = [os.path.join(inbox_root, role)]
    header = f"Threads in _inbox/{role}/ of project '{project}':"
else:
    sys.exit("CODESYNC_ROLE not set and --all-inboxes not given. Set CODESYNC_ROLE or pass --all-inboxes.")

def short_age(ts):
    try:
        age = time.time() - ts
        if age < 60: return f"{int(age)}s ago"
        if age < 3600: return f"{int(age // 60)}m ago"
        if age < 86400: return f"{int(age // 3600)}h ago"
        return f"{int(age // 86400)}d ago"
    except Exception:
        return "?"

entries = []
for d in inbox_dirs:
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".md"):
            continue
        path = os.path.join(d, fn)
        fm = read_frontmatter_from_file(path) or {}
        if filter_status and fm.get("status", "") != filter_status:
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0
        entries.append({
            "path":   path,
            "rel":    os.path.relpath(path, proj_path),
            "status": fm.get("status", ""),
            "fromRole": fm.get("from", ""),
            "toRole":   fm.get("to", os.path.basename(d)),
            "title":  fm.get("title", "") or fn[:-3],
            "age":    short_age(mtime),
            "has_fm": bool(fm),
        })

print()
print(header)
if filter_status:
    print(f"(filtered by status={filter_status})")
print()

if not entries:
    print("  (no threads here yet — run /codesync-thread-new)")
    print()
    sys.exit(0)

# Sort: status order (todo, wip, blocked, note, done) then by recency
STATUS_ORDER = {"todo": 0, "wip": 1, "blocked": 2, "note": 3, "done": 4, "": 5}
entries.sort(key=lambda e: (STATUS_ORDER.get(e["status"], 5), -os.path.getmtime(e["path"])))

for e in entries:
    status = e["status"] or "no-fm"
    tag = f"[{status}]".ljust(10)
    title = e["title"]
    if len(title) > 50:
        title = title[:47] + "..."
    title = title.ljust(50)
    fr = f"from {e['fromRole']}" if e['fromRole'] else "(no from)"
    age = e['age']
    print(f"  {tag} {title} {fr.ljust(18)} {age}")
    print(f"             {e['rel']}")

print()
print(f"{len(entries)} thread(s).")
print()
PY
