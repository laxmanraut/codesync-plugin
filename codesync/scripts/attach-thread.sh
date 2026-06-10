#!/usr/bin/env bash
# attach-thread.sh — Attach one or more files to an existing thread.
#
# Copies each file into <inbox-or-archive>/<role>/<slug>.attachments/ and
# updates the thread's frontmatter `attachments:` field (comma-separated,
# deduplicated). Overwrites a same-name attachment if one exists already
# (Syncthing preserves the previous version under .stversions/).
#
# Args:
#   --slug <slug>    (required) the thread to attach to (search _inbox/* and _archive/*)
#   --file <path>    (required, repeatable) absolute or relative path to a file
#
# Outputs THREAD_FILE=<path> and ATTACHMENTS=<comma-separated final list>.
#
# Constraint: attachment filenames must not contain commas (the frontmatter
# field is comma-separated). Filenames containing commas are rejected with
# a clear error.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

SLUG=""
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) [ $# -ge 2 ] || err "--slug requires a value"; SLUG="$2"; shift 2 ;;
    --file) [ $# -ge 2 ] || err "--file requires a value"; FILES+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$SLUG" ]      || err "Usage: attach-thread.sh --slug <slug> --file <path> [--file <path> ...]"
[ ${#FILES[@]} -gt 0 ] || err "At least one --file is required"

# Populate env from resolver
. "$SCRIPT_DIR/lib/load-env.sh"
PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "CODESYNC_PROJECT not set (and no .codesync/project.json marker found)."

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

PROJECT_PATH=$($PY_BIN -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
proj = cfg.get("projects", {}).get(sys.argv[2])
print(proj["path"] if proj else "")
' "$CFG_FILE" "$PROJECT")

[ -n "$PROJECT_PATH" ] || err "Project '$PROJECT' not found in config."

# Find the thread file (search _inbox/ first, then _archive/)
TARGET=""
ATTACH_DIR=""
for ROOT in "$PROJECT_PATH/_inbox" "$PROJECT_PATH/_archive"; do
  [ -d "$ROOT" ] || continue
  for role_dir in "$ROOT"/*/; do
    [ -d "$role_dir" ] || continue
    candidate="${role_dir}${SLUG}.md"
    if [ -f "$candidate" ]; then
      TARGET="$candidate"
      ATTACH_DIR="${role_dir}${SLUG}.attachments"
      break 2
    fi
  done
done

[ -n "$TARGET" ] || err "Thread '$SLUG' not found in any _inbox/ or _archive/ role subdir of project '$PROJECT'. Run /codesync-thread-list to see what's there."

# Validate each file: exists, readable, and the basename is safe on every
# platform the attachment will sync to. Beyond the original no-comma rule
# (frontmatter is comma-separated), enforce the NTFS-illegal set — a Mac-side
# name like 'mockup: v2.png' is legal on APFS but Syncthing CANNOT create it
# on a Windows peer, silently breaking delivery (design OQ6).
for f in "${FILES[@]}"; do
  [ -f "$f" ] || err "File not found: $f"
  [ -r "$f" ] || err "File not readable: $f"
  bn=$(basename "$f")
  case "$bn" in
    *,*) err "Attachment basename '$bn' contains a comma — the frontmatter field is comma-separated so this would break parsing. Rename the file." ;;
    *[':?|*"<>\\']*) err "Attachment basename '$bn' contains a character that is illegal on Windows filesystems (one of : ? | * \" < > \\) — it would silently fail to sync to any Windows collaborator. Rename the file." ;;
    *.|*' ') err "Attachment basename '$bn' ends with a dot or space — illegal on Windows filesystems. Rename the file." ;;
  esac
  # Windows reserved device names (case-insensitive, with or without extension)
  bn_stem=$(printf '%s' "${bn%%.*}" | tr '[:lower:]' '[:upper:]')
  case "$bn_stem" in
    CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
      err "Attachment basename '$bn' is a reserved device name on Windows ($bn_stem) — it cannot exist on a Windows peer. Rename the file." ;;
  esac
  # Case-collision check: NTFS is case-insensitive — 'Logo.png' and 'logo.png'
  # cannot coexist in one directory on a Windows peer.
  if [ -d "$ATTACH_DIR" ]; then
    bn_lower=$(printf '%s' "$bn" | tr '[:upper:]' '[:lower:]')
    for existing in "$ATTACH_DIR"/*; do
      [ -e "$existing" ] || continue
      ex_bn=$(basename "$existing")
      ex_lower=$(printf '%s' "$ex_bn" | tr '[:upper:]' '[:lower:]')
      if [ "$bn_lower" = "$ex_lower" ] && [ "$bn" != "$ex_bn" ]; then
        err "Attachment '$bn' differs only by case from existing attachment '$ex_bn' — case-insensitive Windows filesystems cannot hold both. Rename the file (same-name overwrite is fine; case-variant is not)."
      fi
    done
  fi
done

# Pre-flight: confirm the target file has a codesync frontmatter block we can
# update. Failing here means NO files have been copied yet, so the user's
# filesystem state stays clean (no orphan files in .attachments/).
HAS_FM=$($PY_BIN - "$TARGET" <<'PY'
import re, sys
content = open(sys.argv[1]).read()
print("yes" if re.match(r'\A---\s*\n.*?\n---\s*\n', content, re.DOTALL) else "no")
PY
)
if [ "$HAS_FM" != "yes" ]; then
  err "Thread file '$TARGET' has no codesync frontmatter block — can't record the attachments list. Either add a '---\\ncodesync:\\n  ...\\n---' block at the top of the file, or use /codesync-thread-new to create the thread with the right shape."
fi

mkdir -p "$ATTACH_DIR"

ADDED=()
for f in "${FILES[@]}"; do
  bn=$(basename "$f")
  cp -f "$f" "$ATTACH_DIR/$bn"
  ADDED+=("$bn")
  log "Attached: $bn"
done

# Update frontmatter: append new filenames (comma-separated, deduped)
$PY_BIN - "$TARGET" "${ADDED[@]}" <<'PY'
import os, re, sys
target = sys.argv[1]
added = sys.argv[2:]

with open(target) as f:
    content = f.read()

fm_match = re.match(r'\A(---\s*\n)(.*?\n)(---\s*\n)', content, re.DOTALL)
if not fm_match:
    sys.exit(f"Couldn't locate frontmatter block in '{target}'.")

start, block, end = fm_match.groups()

# Parse existing attachments value (if any)
existing = []
m = re.search(r'^  attachments: ([^\n]*)', block, re.MULTILINE)
if m:
    raw = m.group(1).strip()
    if raw:
        existing = [p.strip() for p in raw.split(',') if p.strip()]

merged = list(existing)
for a in added:
    if a not in merged:
        merged.append(a)

new_value = ", ".join(merged)

if re.search(r'^  attachments:', block, re.MULTILINE):
    new_block = re.sub(
        r'^  attachments: [^\n]*',
        f'  attachments: {new_value}',
        block, count=1, flags=re.MULTILINE,
    )
else:
    # Insert just before the closing of the codesync: block (right after
    # the last  : line). Simplest: append after created: or at end of block.
    if re.search(r'^  created:', block, re.MULTILINE):
        new_block = re.sub(
            r'^(  created: [^\n]*\n)',
            rf'\1  attachments: {new_value}\n',
            block, count=1, flags=re.MULTILINE,
        )
    else:
        # Fallback: append before end of block
        new_block = block.rstrip() + f'\n  attachments: {new_value}\n'

new_content = start + new_block + end + content[fm_match.end():]

tmp = target + ".tmp"
with open(tmp, "w") as f:
    f.write(new_content)
os.replace(tmp, target)

print(f"ATTACHMENTS_FINAL={new_value}")
PY

printf '\n'
printf 'THREAD_FILE=%s\n' "$TARGET"
printf 'ATTACH_DIR=%s\n' "$ATTACH_DIR"
