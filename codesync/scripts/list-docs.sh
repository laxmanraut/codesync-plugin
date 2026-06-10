#!/usr/bin/env bash
# list-docs.sh — List files in the active project's _docs/ directory.
# Reads CODESYNC_PROJECT from the env (resolver-populated upstream).
# Output is human-readable; one line per doc with filename + first heading.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

# Populate CODESYNC_PROJECT from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

[ -n "${CODESYNC_PROJECT:-}" ] \
  || err "No project active. Set CODESYNC_PROJECT in your shell or attach this directory with /codesync-project-attach <project>."

$PY_BIN - "$CFG_FILE" "$CODESYNC_PROJECT" <<'PY'
import json, os, sys, re

cfg_path, project = sys.argv[1:3]
cfg = json.load(open(cfg_path))
proj = cfg.get("projects", {}).get(project)
if not proj:
    print(f"ERROR: project '{project}' is not registered.", file=sys.stderr)
    sys.exit(1)
proj_path = proj["path"]
docs_dir = os.path.join(proj_path, "_docs")

if not os.path.isdir(docs_dir):
    print(f"No _docs/ directory exists in project '{project}' yet.")
    print(f"Create one at:  {docs_dir}")
    print(f"Or re-run /install-codesync (pick this project) to scaffold it.")
    sys.exit(0)

def first_heading(path):
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r'^#\s+(.*)', line.rstrip())
                if m:
                    return m.group(1).strip()
                if line.strip() and not line.startswith('#'):
                    break  # ran past the leading-comment area
    except OSError:
        pass
    return None

entries = []
for fn in sorted(os.listdir(docs_dir)):
    if not fn.endswith(".md") or fn == "README.md":
        continue
    full = os.path.join(docs_dir, fn)
    if not os.path.isfile(full):
        continue
    heading = first_heading(full) or "(no heading)"
    try:
        size = os.path.getsize(full)
    except OSError:
        size = 0
    entries.append((fn, heading, size))

print(f"Docs in project '{project}'  ({len(entries)} file{'s' if len(entries) != 1 else ''}):")
print(f"  Location: {docs_dir}")
print()

if not entries:
    print("  (no markdown docs yet — drop any .md file in _docs/ and it'll appear here)")
    print()
    print("  README.md in _docs/ explains the convention.")
    sys.exit(0)

# Determine column widths
name_w = max(8, max(len(e[0]) for e in entries))
for fn, heading, size in entries:
    kb = size / 1024 if size > 0 else 0
    size_str = f"{int(size)}B" if size < 1024 else f"{kb:.1f}KB"
    print(f"  {fn:<{name_w}}   {heading}    ({size_str})")

print()
print("Read any of them with Claude (no slash command needed — just ask Claude to read it).")
PY
