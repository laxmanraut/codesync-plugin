#!/usr/bin/env bash
# Incoming-pairing-request banner (session-start + status): when Syncthing's
# pending-devices API reports a waiting peer, surface it with the exact
# accept command. curl is stubbed via PATH so no live Syncthing is needed.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

PEER="ABCD123-XXXXXXX-YYYYYYY-ZZZZZZZ-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD"

# config needs an api key or the check is skipped entirely
$PY_BIN - "$HOME/.config/codesync/config.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["syncthing_api_key"] = "test-key"
cfg["device_id"] = "SELF111-XXXXXXX-YYYYYYY-ZZZZZZZ-AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD"
json.dump(cfg, open(p, "w"), indent=2)
PYEOF

# curl stub: pending-devices returns one waiting peer; everything else OK-empty
STUB="$T_TMP/stub"
mkdir -p "$STUB"
cat > "$STUB/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    */rest/cluster/pending/devices)
      printf '{"$PEER": {"time": "2026-06-11T14:30:00Z", "name": "colleague-win11", "address": "192.168.1.50:22000"}}'
      exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$STUB/curl"

OUT=$(PATH="$STUB:$PATH" bash "$SCRIPTS/session-start.sh" 2>&1)
t_contains "session-start shows pairing banner" "incoming pairing request" "$OUT"
t_contains "banner names the device" "colleague-win11" "$OUT"
t_contains "banner gives the accept command" "/codesync-pair --peer $PEER" "$OUT"

OUT=$(PATH="$STUB:$PATH" bash "$SCRIPTS/status.sh" 2>&1)
t_contains "status shows pending pairings" "Incoming pairing requests" "$OUT"
t_contains "status gives the accept command" "/codesync-pair --peer $PEER" "$OUT"

# No pending → silent (empty-object response)
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */rest/cluster/pending/devices) printf '{}'; exit 0 ;;
  esac
done
exit 0
EOF
OUT=$(PATH="$STUB:$PATH" bash "$SCRIPTS/session-start.sh" 2>&1)
case "$OUT" in
  *pairing*) t_fail "no banner expected when pending is empty" ;;
  *) t_pass "silent when no pending requests" ;;
esac

t_done
