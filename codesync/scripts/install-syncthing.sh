#!/usr/bin/env bash
# install-syncthing.sh — Machine-level CodeSync setup (v0.5.0+).
# - Installs Syncthing via Homebrew if missing.
# - Starts it as a brew service if not running.
# - Reads the Syncthing API key + Device ID and persists them to
#   ~/.config/codesync/config.json, alongside an (initially empty)
#   projects map. Project folders are created by create-project.sh.
# Idempotent: safe to re-run.

set -euo pipefail

CONFIG_XML="$HOME/Library/Application Support/Syncthing/config.xml"
API="http://127.0.0.1:8384"
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

# 5. Extract API key
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

# 6. Wait for REST API
for _ in $(seq 1 30); do
  curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 \
  || err "Syncthing REST API at $API did not respond. Check 'brew services list' and ~/Library/Logs/syncthing.log."

# 7. Read Device ID
DEVICE_ID=$(curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["myID"])') \
  || err "Could not read Device ID from Syncthing"

# 8. Persist machine-level config — preserve any existing projects map
mkdir -p "$CFG_DIR"
python3 - "$CFG_FILE" "$API_KEY" "$DEVICE_ID" <<'PY'
import json, os, sys
cfg_path, api_key, device_id = sys.argv[1:4]
cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
cfg["syncthing_api_key"] = api_key
cfg["device_id"]         = device_id
# Preserve existing projects map, or create empty
if not isinstance(cfg.get("projects"), dict):
    cfg["projects"] = {}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"
log "Wrote $CFG_FILE"

# 9. Machine-parseable output
printf '\n'
printf 'DEVICE_ID=%s\n' "$DEVICE_ID"
