#!/usr/bin/env bash
# list-threads.sh — List thread files in the active project's inbox for the active role.
# Reads frontmatter to enrich each entry with status, from, title.
#
# Optional args:
#   --status <s>          filter to threads with that status (todo|wip|done|blocked|note)
#   --all | --all-inboxes list threads in every role's inbox (default: just the active role's)
#   --archive             list only archived threads (from _archive/) instead of _inbox/
#   --include-archive     list BOTH inbox and archive; archive entries get an [archived] label

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

FILTER_STATUS=""
ALL_INBOXES="no"
SOURCE_MODE="inbox"   # inbox | archive | both
while [ $# -gt 0 ]; do
  case "$1" in
    --status)              [ $# -ge 2 ] || err "--status requires a value"; FILTER_STATUS="$2"; shift 2 ;;
    --all|--all-inboxes)   ALL_INBOXES="yes"; shift ;;
    --archive)             SOURCE_MODE="archive"; shift ;;
    --include-archive)     SOURCE_MODE="both"; shift ;;
    *)                     shift ;;
  esac
done

. "$SCRIPT_DIR/lib/load-env.sh"
PROJECT="${CODESYNC_PROJECT:-}"
ROLE="${CODESYNC_ROLE:-}"

[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set (and no .codesync/project.json marker found in the current directory or its parents)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

python3 - "$SCRIPT_DIR/lib" "$CFG_FILE" "$PROJECT" "$ROLE" "$FILTER_STATUS" "$ALL_INBOXES" "$SOURCE_MODE" <<'PY'
import json, os, sys, time

lib_dir, cfg_path, project, role, filter_status, all_inboxes, source_mode = sys.argv[1:8]
sys.path.insert(0, lib_dir)
from frontmatter import read_frontmatter_from_file

all_inboxes = (all_inboxes == "yes")

with open(cfg_path) as f:
    cfg = json.load(f)

proj = cfg.get("projects", {}).get(project)
if not proj:
    sys.exit(f"Project '{project}' not found in config.")

proj_path = proj["path"]

# Build (source_root, is_archive) pairs based on mode
sources = []
if source_mode in ("inbox", "both"):
    sources.append((os.path.join(proj_path, "_inbox"), False))
if source_mode in ("archive", "both"):
    sources.append((os.path.join(proj_path, "_archive"), True))

# Decide which role-subdirs to scan under each source
scan_dirs = []   # list of (path, is_archive)
for root, is_arch in sources:
    if not os.path.isdir(root):
        continue
    if all_inboxes:
        for d in sorted(os.listdir(root)):
            full = os.path.join(root, d)
            if os.path.isdir(full):
                scan_dirs.append((full, is_arch))
    elif role:
        candidate = os.path.join(root, role)
        if os.path.isdir(candidate):
            scan_dirs.append((candidate, is_arch))
    else:
        sys.exit("CODESYNC_ROLE not set and --all not given. Set CODESYNC_ROLE or pass --all.")

# Build header
parts = []
if source_mode == "inbox":   parts.append("inbox")
if source_mode == "archive": parts.append("archive")
if source_mode == "both":    parts.append("inbox + archive")
scope = "all role inboxes" if all_inboxes else f"_inbox/{role}/" if role else "?"
header = f"Threads in project '{project}' ({', '.join(parts)}):"


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
for d, is_arch in scan_dirs:
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
            "fromIdentity": fm.get("from-identity", ""),
            "owner":  fm.get("owner", ""),
            "toRole":   fm.get("to", os.path.basename(d)),
            "title":  fm.get("title", "") or fn[:-3],
            "age":    short_age(mtime),
            "is_archive": is_arch,
            "has_fm": bool(fm),
        })

print()
print(header)
if filter_status:
    print(f"(filtered by status={filter_status})")
print()

if not entries:
    if source_mode == "archive":
        print("  (no archived threads yet)")
    else:
        print("  (no threads here yet — run /codesync-thread-new)")
    print()
    sys.exit(0)

STATUS_ORDER = {"todo": 0, "wip": 1, "blocked": 2, "note": 3, "done": 4, "": 5}
entries.sort(key=lambda e: (
    1 if e["is_archive"] else 0,                # inbox before archive
    STATUS_ORDER.get(e["status"], 5),
    -os.path.getmtime(e["path"]),
))

for e in entries:
    status = e["status"] or "no-fm"
    tag = f"[{status}]".ljust(10)
    title = e["title"]
    arch_prefix = "[archived] " if e["is_archive"] else ""
    # owner label: [owned by X] if claimed, [unclaimed] otherwise (only shown
    # when listing all roles, so the user isn't drowning in [unclaimed] labels
    # when they're already looking at one role's inbox)
    owner_label = ""
    if all_inboxes:
        if e["owner"]:
            owner_label = f"[owned by {e['owner']}] "
        elif e["status"] in ("todo", "wip"):
            owner_label = "[unclaimed] "
    else:
        if e["owner"]:
            owner_label = f"[owned by {e['owner']}] "
    if len(title) > 50:
        title = title[:47] + "..."
    title = (arch_prefix + owner_label + title).ljust(60)
    # Build "from" string — show role/identity if both present
    if e['fromRole'] and e['fromIdentity']:
        fr = f"from {e['fromRole']}/{e['fromIdentity']}"
    elif e['fromRole']:
        fr = f"from {e['fromRole']}"
    else:
        fr = "(no from)"
    age = e['age']
    print(f"  {tag} {title} {fr.ljust(22)} {age}")
    print(f"             {e['rel']}")

print()
print(f"{len(entries)} thread(s).")
print()
PY
