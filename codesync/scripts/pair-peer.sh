#!/usr/bin/env bash
# pair-peer.sh — Pair this machine with a peer Syncthing device and share
# the codesync-contracts folder. Symmetric: each side runs this once; sync
# starts automatically when both have done so. Idempotent.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Args — accept --peer <id>; other args are tolerated and ignored
PEER_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --peer)
      [ $# -ge 2 ] || err "--peer requires a value"
      PEER_ID="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$PEER_ID" ] || err "Usage: pair-peer.sh --peer <peer-device-id>"

# 2. Load our config (install must have run first)
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

read_cfg() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$CFG_FILE" "$1"
}

API_KEY=$(read_cfg syncthing_api_key)
FOLDER_ID=$(read_cfg syncthing_folder_id)
DEVICE_ID=$(read_cfg device_id)

[ -n "$API_KEY"   ] || err "syncthing_api_key missing in $CFG_FILE. Re-run /install-codesync."
[ -n "$FOLDER_ID" ] || err "syncthing_folder_id missing in $CFG_FILE. Re-run /install-codesync."
[ -n "$DEVICE_ID" ] || err "device_id missing in $CFG_FILE. Re-run /install-codesync."

# 3. Refuse to pair with self
if [ "$PEER_ID" = "$DEVICE_ID" ]; then
  err "Refusing to pair with own device id ($DEVICE_ID)."
fi

api() { curl -sf -H "X-API-Key: $API_KEY" "$@"; }

# 4. Sanity-check Syncthing is up
api "$API/rest/system/status" >/dev/null \
  || err "Syncthing REST API at $API is not responding. Try: brew services restart syncthing"

# 5. Add peer to known devices (idempotent — PUT replaces)
SHORT_NAME="codesync-peer-${PEER_ID:0:7}"
log "Adding peer device to Syncthing as '$SHORT_NAME'..."
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
api -X PUT -H "Content-Type: application/json" \
  --data-binary "$DEVICE_PAYLOAD" \
  "$API/rest/config/devices/$PEER_ID" >/dev/null \
  || err "Failed to add peer device to Syncthing"

# 6. Share our folder with the peer (read folder config, merge, write back)
log "Sharing folder '$FOLDER_ID' with peer..."
FOLDER_JSON=$(api "$API/rest/config/folders/$FOLDER_ID") \
  || err "Folder '$FOLDER_ID' not found. Run /install-codesync first."

UPDATED_FOLDER=$(python3 - "$FOLDER_JSON" "$PEER_ID" <<'PY'
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
api -X PUT -H "Content-Type: application/json" \
  --data-binary "$UPDATED_FOLDER" \
  "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
  || err "Failed to update folder devices list"

# 7. Report any pending folder share from this peer (informational — already covered by step 6)
PENDING_JSON=$(api "$API/rest/cluster/pending/folders" 2>/dev/null || echo '{}')
PENDING_HIT=$(python3 - "$PENDING_JSON" "$PEER_ID" "$FOLDER_ID" <<'PY'
import json, sys
try:
    pending = json.loads(sys.argv[1] or "{}")
except Exception:
    pending = {}
peer, folder_id = sys.argv[2], sys.argv[3]
hit = pending.get(folder_id, {}).get("offeredBy", {}).get(peer)
print("yes" if hit else "no")
PY
)
if [ "$PENDING_HIT" = "yes" ]; then
  log "Peer had a pending folder share — accepted as part of step 6."
fi

# 8. Output for the slash command to parse
printf '\n'
printf 'PAIRED_WITH=%s\n' "$PEER_ID"
printf 'PEER_SHORT_NAME=%s\n' "$SHORT_NAME"
