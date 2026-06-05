#!/usr/bin/env bash
# pair-peer.sh — Device-level pairing with a peer.
# Args: --peer <device-id>
#
# Adds the peer to Syncthing's known devices. If $CODESYNC_PROJECT is set
# and refers to a registered project, ALSO invites the peer to that
# project's folder (this is the "first pair + active-project invite" UX
# from v0.5.0 design pick 4-B).
#
# Idempotent. Refuses to pair with own device.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Args
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

# 2. Load machine-level config
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["syncthing_api_key"])' "$CFG_FILE")
DEVICE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device_id"])' "$CFG_FILE")
[ -n "$API_KEY"   ] || err "syncthing_api_key missing in $CFG_FILE."
[ -n "$DEVICE_ID" ] || err "device_id missing in $CFG_FILE."

# 3. Refuse self-pair
[ "$PEER_ID" = "$DEVICE_ID" ] && err "Refusing to pair with own device id ($DEVICE_ID)."

api() { curl -sf -H "X-API-Key: $API_KEY" "$@"; }

api "$API/rest/system/status" >/dev/null \
  || err "Syncthing REST API at $API is not responding. Try: brew services restart syncthing"

# 4. Add peer to known devices (idempotent)
SHORT_NAME="codesync-peer-${PEER_ID:0:7}"
log "Adding peer to Syncthing's known devices as '$SHORT_NAME'..."
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
  || err "Failed to add peer device to Syncthing"

# 5. If CODESYNC_PROJECT is set, also invite peer to that project's folder
PROJECT="${CODESYNC_PROJECT:-}"
INVITED_TO=""
if [ -n "$PROJECT" ]; then
  PROJECT_FOUND=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
projects = cfg.get("projects", {})
print("yes" if sys.argv[2] in projects else "no")
' "$CFG_FILE" "$PROJECT")

  if [ "$PROJECT_FOUND" = "yes" ]; then
    log "Inviting peer to active project '$PROJECT'..."
    if bash "$SCRIPT_DIR/invite-peer-to-project.sh" --peer "$PEER_ID" --project "$PROJECT" >/dev/null 2>&1; then
      INVITED_TO="$PROJECT"
    else
      log "WARNING: device pair succeeded but project invite failed. Run /codesync-project-invite --peer $PEER_ID manually."
    fi
  else
    log "CODESYNC_PROJECT='$PROJECT' is set but no project by that name is registered — skipping project invite."
  fi
fi

# 6. Output
printf '\n'
printf 'PAIRED_WITH=%s\n' "$PEER_ID"
printf 'PEER_SHORT_NAME=%s\n' "$SHORT_NAME"
printf 'INVITED_TO=%s\n' "$INVITED_TO"
