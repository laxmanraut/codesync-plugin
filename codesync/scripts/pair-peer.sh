#!/usr/bin/env bash
# pair-peer.sh — Device-level pairing with a peer.
# Args: --peer <device-id> [--as-introducer]
#
# Adds the peer to Syncthing's known devices. If $CODESYNC_PROJECT is set
# and refers to a registered project, ALSO invites the peer to that
# project's folder (this is the "first pair + active-project invite" UX
# from v0.5.0 design pick 4-B). The optional --as-introducer flag marks
# this peer as an introducer ON THIS MACHINE — Syncthing's flag is one-way
# and set on the receiver's side.
#
# Idempotent. Refuses to pair with own device. Never silently downgrades
# an existing introducer=true flag (re-pair without --as-introducer is a
# no-op for the introducer field).

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

# 1. Args
PEER_ID=""
AS_INTRODUCER="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --peer)
      [ $# -ge 2 ] || err "--peer requires a value"
      PEER_ID="$2"
      shift 2
      ;;
    --as-introducer)
      AS_INTRODUCER="yes"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$PEER_ID" ] || err "Usage: pair-peer.sh --peer <peer-device-id> [--as-introducer]"

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

# 4. Add peer to known devices (idempotent; PUT replaces).
#    Read existing device first so we don't clobber the introducer flag if it
#    was set by an earlier call. --as-introducer always upgrades to true.
SHORT_NAME="codesync-peer-${PEER_ID:0:7}"
log "Adding peer to Syncthing's known devices as '$SHORT_NAME'..."
EXISTING_DEVICE=$(api "$API/rest/config/devices/$PEER_ID" 2>/dev/null || echo "")
DEVICE_PAYLOAD=$(python3 - "$PEER_ID" "$SHORT_NAME" "$AS_INTRODUCER" "$EXISTING_DEVICE" <<'PY'
import json, sys
peer, name, asintro, existing = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
introducer = asintro == "yes"
if not introducer and existing:
    try:
        introducer = bool(json.loads(existing).get("introducer", False))
    except Exception:
        introducer = False
print(json.dumps({
    "deviceID":          peer,
    "name":              name,
    "addresses":         ["dynamic"],
    "compression":       "metadata",
    "introducer":        introducer,
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
    INVITE_ARGS=(--peer "$PEER_ID" --project "$PROJECT")
    [ "$AS_INTRODUCER" = "yes" ] && INVITE_ARGS+=(--as-introducer)
    if bash "$SCRIPT_DIR/invite-peer-to-project.sh" "${INVITE_ARGS[@]}" >/dev/null 2>&1; then
      INVITED_TO="$PROJECT"
    else
      log "WARNING: device pair succeeded but project invite failed. Re-run /codesync-pair --peer $PEER_ID manually (with CODESYNC_PROJECT set to this project)."
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
printf 'AS_INTRODUCER=%s\n' "$AS_INTRODUCER"
