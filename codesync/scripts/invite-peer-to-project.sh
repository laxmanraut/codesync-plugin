#!/usr/bin/env bash
# invite-peer-to-project.sh — Add a peer to one specific project's Syncthing folder.
# Args: --peer <device-id> --project <project-name>
#
# Idempotent. Adds the peer to known devices if not already there, then adds
# the peer to the project's folder devices list. Refuses to invite own device.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Parse args
PEER_ID=""
PROJECT_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --peer)
      [ $# -ge 2 ] || err "--peer requires a value"
      PEER_ID="$2"
      shift 2
      ;;
    --project)
      [ $# -ge 2 ] || err "--project requires a value"
      PROJECT_NAME="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$PEER_ID" ]      || err "Usage: invite-peer-to-project.sh --peer <device-id> --project <name>"
[ -n "$PROJECT_NAME" ] || err "Usage: invite-peer-to-project.sh --peer <device-id> --project <name>"

# 2. Load config
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["syncthing_api_key"])' "$CFG_FILE")
DEVICE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device_id"])' "$CFG_FILE")
FOLDER_ID=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
projects = cfg.get("projects", {})
proj = projects.get(sys.argv[2])
print(proj["folder_id"] if proj else "")
' "$CFG_FILE" "$PROJECT_NAME")

[ -n "$API_KEY"   ] || err "syncthing_api_key missing in $CFG_FILE."
[ -n "$DEVICE_ID" ] || err "device_id missing in $CFG_FILE."
[ -n "$FOLDER_ID" ] || err "Project '$PROJECT_NAME' not found in $CFG_FILE. Run /codesync-project-list to see what's registered."

# 3. Refuse to invite self
[ "$PEER_ID" = "$DEVICE_ID" ] && err "Refusing to invite own device id ($DEVICE_ID)."

api() { curl -sf -H "X-API-Key: $API_KEY" "$@"; }

api "$API/rest/system/status" >/dev/null \
  || err "Syncthing REST API not responding."

# 4. Add peer to known devices (idempotent; PUT replaces)
SHORT_NAME="codesync-peer-${PEER_ID:0:7}"
log "Ensuring peer '$SHORT_NAME' is in Syncthing's known devices..."
DEVICE_PAYLOAD=$(python3 - "$PEER_ID" "$SHORT_NAME" <<'PY'
import json, sys
print(json.dumps({
    "deviceID":          sys.argv[1],
    "name":              sys.argv[2],
    "addresses":         ["dynamic"],
    "compression":       "metadata",
    "introducer":        False,
    "autoAcceptFolders": False,
}))
PY
)
api -X PUT -H "Content-Type: application/json" --data-binary "$DEVICE_PAYLOAD" \
  "$API/rest/config/devices/$PEER_ID" >/dev/null \
  || err "Failed to register peer device with Syncthing"

# 5. Add peer to the project's folder devices list (read-modify-write)
log "Adding peer to project '$PROJECT_NAME' (folder $FOLDER_ID)..."
FOLDER_JSON=$(api "$API/rest/config/folders/$FOLDER_ID") \
  || err "Folder '$FOLDER_ID' not found in Syncthing. Project may be misregistered."

UPDATED=$(python3 - "$FOLDER_JSON" "$PEER_ID" <<'PY'
import json, sys
folder = json.loads(sys.argv[1])
peer = sys.argv[2]
devices = folder.get("devices", [])
if not any(d.get("deviceID") == peer for d in devices):
    devices.append({"deviceID": peer, "introducedBy": "", "encryptionPassword": ""})
folder["devices"] = devices
print(json.dumps(folder))
PY
)
api -X PUT -H "Content-Type: application/json" --data-binary "$UPDATED" \
  "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
  || err "Failed to update folder devices list"

# 6. Output
printf '\n'
printf 'PROJECT=%s\n' "$PROJECT_NAME"
printf 'FOLDER_ID=%s\n' "$FOLDER_ID"
printf 'INVITED=%s\n' "$PEER_ID"
printf 'PEER_SHORT_NAME=%s\n' "$SHORT_NAME"
