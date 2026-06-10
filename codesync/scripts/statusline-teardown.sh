#!/usr/bin/env bash
# statusline-teardown.sh — Restore the user's pre-codesync statusLine.
#
# Reads ~/.config/codesync/statusline-prior.txt (saved by setup), and
# either restores it as the active statusLine command, or removes the
# statusLine entry entirely if there was no prior command.
#
# Backs up settings.json before mutating. Idempotent: silent if codesync's
# wrap isn't currently the active statusLine.

set -euo pipefail

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
CFG_DIR="$HOME/.config/codesync"
PRIOR_FILE="$CFG_DIR/statusline-prior.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Platform layer: CODESYNC_OS, PY_BIN, codesync_* helpers
. "$SCRIPT_DIR/lib/platform.sh"
WRAP_PATH="$SCRIPT_DIR/statusline-wrap.sh"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$SETTINGS_FILE" ] || err "$SETTINGS_FILE does not exist — nothing to tear down."

CURRENT_CMD=$($PY_BIN - "$SETTINGS_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f: cfg = json.load(f)
except Exception:
    cfg = {}
sl = cfg.get("statusLine") or {}
print(sl.get("command", ""))
PY
)

if [ "$CURRENT_CMD" != "$WRAP_PATH" ]; then
  log "statusLine isn't currently codesync's wrap (it's: $CURRENT_CMD). Nothing to do."
  printf '\n'
  printf 'STATUS=not_installed\n'
  exit 0
fi

# Back up before changing
TS=$(date +%Y%m%d-%H%M%S)
cp "$SETTINGS_FILE" "$SETTINGS_FILE.codesync-bak-$TS"
log "Backed up settings.json to $SETTINGS_FILE.codesync-bak-$TS"

# Read prior (if any)
PRIOR=""
if [ -f "$PRIOR_FILE" ]; then
  PRIOR=$(cat "$PRIOR_FILE")
fi

# Restore: either set statusLine.command back to prior, or remove the entry
$PY_BIN - "$SETTINGS_FILE" "$PRIOR" <<'PY'
import json, sys
path, prior = sys.argv[1:3]
with open(path) as f: cfg = json.load(f)
if prior:
    cfg["statusLine"] = {"type": "command", "command": prior}
else:
    cfg.pop("statusLine", None)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

# Clean up the prior file
rm -f "$PRIOR_FILE"

if [ -n "$PRIOR" ]; then
  log "Restored prior statusLine command: $PRIOR"
else
  log "Removed statusLine entry (there was no prior command to restore)."
fi

printf '\n'
printf 'STATUS=uninstalled\n'
