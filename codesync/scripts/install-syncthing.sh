#!/usr/bin/env bash
# install-syncthing.sh — Install Syncthing and register ~/contracts as a shared folder.
# Idempotent: safe to re-run. Exits non-zero on any failure.

set -euo pipefail

CONTRACTS_DIR="${CODESYNC_CONTRACTS_DIR:-$HOME/contracts}"
CONFIG_XML="$HOME/Library/Application Support/Syncthing/config.xml"
API="http://127.0.0.1:8384"
FOLDER_ID="codesync-contracts"
CFG_DIR="$HOME/.config/codesync"
CFG_FILE="$CFG_DIR/config.json"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Prerequisites
command -v brew    >/dev/null 2>&1 || err "Homebrew required. Install from https://brew.sh and re-run."
command -v python3 >/dev/null 2>&1 || err "python3 required (ships with macOS)."
command -v curl    >/dev/null 2>&1 || err "curl required."

# 2. Install Syncthing if missing
if ! command -v syncthing >/dev/null 2>&1; then
  log "Installing syncthing via Homebrew..."
  brew install syncthing >/dev/null
else
  log "syncthing already installed"
fi

# 3. Start the brew service if not running
if brew services list | awk '$1=="syncthing"{print $2}' | grep -qx started; then
  log "syncthing service already running"
else
  log "Starting syncthing service..."
  brew services start syncthing >/dev/null
fi

# 4. Wait for config.xml (Syncthing creates it on first run)
log "Waiting for Syncthing to initialise..."
for _ in $(seq 1 30); do
  [ -f "$CONFIG_XML" ] && break
  sleep 1
done
[ -f "$CONFIG_XML" ] || err "Syncthing config not found at $CONFIG_XML after 30s. Try: brew services restart syncthing"

# 5. Extract API key from config.xml
API_KEY=$(python3 - "$CONFIG_XML" <<'PY' || true
import sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse(sys.argv[1])
    gui = tree.getroot().find("gui")
    if gui is None: sys.exit("no <gui> element in config.xml")
    key = gui.findtext("apikey")
    if not key: sys.exit("no <apikey> element in config.xml")
    print(key)
except Exception as e:
    sys.exit(f"failed to parse config: {e}")
PY
)
[ -n "${API_KEY:-}" ] || err "Could not read API key from $CONFIG_XML"

# 6. Wait for REST API to respond
for _ in $(seq 1 30); do
  curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 \
  || err "Syncthing REST API at $API did not respond. Check 'brew services list' and ~/Library/Logs/syncthing.log."

# 7. Read this machine's Device ID
DEVICE_ID=$(curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["myID"])') \
  || err "Could not read Device ID from Syncthing"

# 8. Create contracts directory and _roles/ subdirectory
mkdir -p "$CONTRACTS_DIR" "$CONTRACTS_DIR/_roles"

# Seed _roles/README.md so the convention is documented for anyone browsing the folder
ROLES_README="$CONTRACTS_DIR/_roles/README.md"
if [ ! -f "$ROLES_README" ]; then
  cat > "$ROLES_README" <<'README'
# Role profiles

Each machine paired with this CodeSync setup writes a markdown file here describing what role it plays. Claude agents read these files to route API contracts correctly.

Files in this directory are written by `/install-codesync`. You can edit them by hand, but the safer way to update your role is to re-run `/install-codesync` on the corresponding machine.
README
fi

# 9. Register folder with Syncthing (skip if already present)
status=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "X-API-Key: $API_KEY" "$API/rest/config/folders/$FOLDER_ID")
if [ "$status" = "200" ]; then
  log "Folder '$FOLDER_ID' already registered with Syncthing"
else
  log "Registering '$FOLDER_ID' with Syncthing..."
  payload=$(python3 - "$FOLDER_ID" "$CONTRACTS_DIR" <<'PY'
import json, sys
print(json.dumps({
    "id": sys.argv[1],
    "label": "CodeSync contracts",
    "path": sys.argv[2],
    "type": "sendreceive",
    "versioning": {"type": "simple", "params": {"keep": "10"}}
}))
PY
)
  curl -sf -X PUT -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
    --data-binary "$payload" \
    "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
    || err "Failed to register folder with Syncthing"
fi

# 10. Persist config for slash commands (merge with existing if any)
mkdir -p "$CFG_DIR"
python3 - "$CFG_FILE" "$CONTRACTS_DIR" "$API_KEY" "$FOLDER_ID" "$DEVICE_ID" <<'PY'
import json, os, sys
cfg_path = sys.argv[1]
new = {
    "contracts_dir":      sys.argv[2],
    "syncthing_api_key":  sys.argv[3],
    "syncthing_folder_id": sys.argv[4],
    "device_id":          sys.argv[5],
}
existing = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            existing = json.load(f)
    except Exception:
        existing = {}
existing.update(new)
with open(cfg_path, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"
log "Wrote $CFG_FILE"

# 11. Machine-parseable output for the slash command
printf '\n'
printf 'DEVICE_ID=%s\n' "$DEVICE_ID"
printf 'CONTRACTS_DIR=%s\n' "$CONTRACTS_DIR"
