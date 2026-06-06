#!/usr/bin/env bash
# status-line.sh — Output the codesync segment for Claude Code's status line.
#
# Fast (< 100ms): scans the active project's _inbox/<role>/ once and
# counts files not present in the per-project Stop-hook baseline (i.e.,
# arrived since the last Claude turn ended).
#
# Outputs:
#   codesync ▴ N new       when N >= 1 unseen items
#   (nothing)              when no project active, no role active and
#                          --all not present, or N == 0
#
# Silent on every error path so it never breaks the user's status line.

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh" 2>/dev/null

[ -n "${CODESYNC_PROJECT:-}" ] || exit 0

python3 - "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, sys

try:
    cfg_path, project, role = sys.argv[1:4]
    cfg = json.load(open(cfg_path))
    proj = cfg.get("projects", {}).get(project)
    if not proj:
        sys.exit(0)
    proj_path = proj.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    inbox_root = os.path.join(proj_path, "_inbox")
    if not os.path.isdir(inbox_root):
        sys.exit(0)

    baseline_path = os.path.expanduser(f"~/.config/codesync/baseline-{project}.json")
    baseline = {}
    if os.path.exists(baseline_path):
        try:
            with open(baseline_path) as f:
                baseline = json.load(f)
        except Exception:
            baseline = {}

    # Scan inboxes for: (1) all roles registered for this device in this
    # project (preferred), else (2) just CODESYNC_ROLE if set, else (3) all
    # inboxes under the project.
    registered = proj.get("roles", []) or []
    if registered:
        scan_dirs = [os.path.join(inbox_root, r) for r in registered]
    elif role:
        scan_dirs = [os.path.join(inbox_root, role)]
    else:
        scan_dirs = [
            os.path.join(inbox_root, d)
            for d in os.listdir(inbox_root)
            if os.path.isdir(os.path.join(inbox_root, d))
        ]

    new_count = 0
    for d in scan_dirs:
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(d, fn)
            rel = os.path.relpath(full, proj_path)
            try:
                mtime = os.path.getmtime(full)
            except OSError:
                continue
            base_mtime = baseline.get(rel)
            if base_mtime is None or mtime > base_mtime:
                new_count += 1

    if new_count <= 0:
        sys.exit(0)

    cap = min(new_count, 9)
    plus = "+" if new_count > 9 else ""
    print(f"codesync ▴ {cap}{plus} new")
except Exception:
    pass
PY
