#!/usr/bin/env bash
# statusline-setup.sh — Install codesync's status-line segment into
# ~/.claude/settings.json, composing safely with any existing statusLine.
#
# Steps:
# 1. Back up settings.json to settings.json.codesync-bak-<timestamp>.
# 2. Capture the current statusLine.command (if any) into
#    ~/.config/codesync/statusline-prior.txt — used by the wrap script
#    to keep the existing statusline running.
# 3. Rewrite statusLine to point at our wrap script.
#
# Idempotent: if already installed (settings.json already points at our
# wrap), it's a no-op.

set -euo pipefail

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
CFG_DIR="$HOME/.config/codesync"
PRIOR_FILE="$CFG_DIR/statusline-prior.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAP_PATH="$SCRIPT_DIR/statusline-wrap.sh"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -d "$SETTINGS_DIR" ] || err "$SETTINGS_DIR does not exist. Is Claude Code installed?"
[ -f "$WRAP_PATH" ]    || err "Wrap script not found at $WRAP_PATH"

mkdir -p "$CFG_DIR"

# Capture current state (or {} if no settings file)
EXISTING_CMD=$(python3 - "$SETTINGS_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
sl = cfg.get("statusLine") or {}
print(sl.get("command", ""))
PY
)

# Idempotency: if already pointing at our wrap, just refresh prior file (no-op otherwise)
if [ "$EXISTING_CMD" = "$WRAP_PATH" ]; then
  log "statusLine already points at codesync's wrap script — nothing to do."
  printf '\n'
  printf 'STATUS=already_installed\n'
  printf 'WRAP=%s\n' "$WRAP_PATH"
  exit 0
fi

# Back up settings.json (if it exists)
if [ -f "$SETTINGS_FILE" ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  BACKUP="$SETTINGS_FILE.codesync-bak-$TS"
  cp "$SETTINGS_FILE" "$BACKUP"
  log "Backed up settings.json to $BACKUP"
fi

# Save the prior command for later restoration / for the wrap to invoke
if [ -n "$EXISTING_CMD" ]; then
  printf '%s' "$EXISTING_CMD" > "$PRIOR_FILE"
  log "Saved prior statusLine command to $PRIOR_FILE"
else
  # No prior — make sure no stale prior file remains
  rm -f "$PRIOR_FILE"
fi

# Write new settings.json with our wrap as statusLine.command
python3 - "$SETTINGS_FILE" "$WRAP_PATH" <<'PY'
import json, os, sys
path, wrap = sys.argv[1:3]
try:
    with open(path) as f: cfg = json.load(f)
except Exception:
    cfg = {}
cfg["statusLine"] = {"type": "command", "command": wrap}
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

log "statusLine now points at codesync's wrap script."

printf '\n'
printf 'STATUS=installed\n'
printf 'WRAP=%s\n' "$WRAP_PATH"
[ -n "$EXISTING_CMD" ] && printf 'PRIOR_SAVED_TO=%s\n' "$PRIOR_FILE" || true
