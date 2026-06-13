#!/usr/bin/env bash
# dashboard-server.py — the local monitoring server. Hermetic: sandbox $HOME,
# no Syncthing. Launches the real server on its random port, drives it over
# HTTP, asserts the token gate, the read endpoints, and the accept-pairing
# validation + token re-check. No browser needed.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

SERVER="$SCRIPTS/dashboard-server.py"
STATE="$HOME/.config/codesync/dashboard.json"
t_thread qa demo "Demo thread"

# Launch detached, short idle timeout so a leaked instance reaps itself fast.
$PY_BIN "$SERVER" --config "$HOME/.config/codesync/config.json" --idle-timeout 60 \
  >"$HOME/.config/codesync/dash.log" 2>&1 &
SRV=$!
cleanup() { kill "$SRV" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the server to write its state + come up.
PORT=""; TOKEN=""
for _ in $(seq 1 50); do
  if [ -f "$STATE" ]; then
    PORT=$($PY_BIN -c 'import json,sys;print(json.load(open(sys.argv[1])).get("port",""))' "$STATE" 2>/dev/null)
    TOKEN=$($PY_BIN -c 'import json,sys;print(json.load(open(sys.argv[1])).get("token",""))' "$STATE" 2>/dev/null)
    [ -n "$PORT" ] && curl -sf --max-time 2 -H "X-CSDash-Token: $TOKEN" "http://127.0.0.1:$PORT/api/overview" >/dev/null 2>&1 && break
  fi
  sleep 0.2
done
t_assert "server came up (state file written)" test -n "$PORT"
B="http://127.0.0.1:$PORT"

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# token gate
t_eq "overview WITHOUT token → 403" "403" "$(code "$B/api/overview")"
t_eq "overview WITH token → 200" "200" "$(code -H "X-CSDash-Token: $TOKEN" "$B/api/overview")"
t_eq "index WITH token → 200" "200" "$(code "$B/?t=$TOKEN")"
t_eq "wrong token → 403" "403" "$(code -H "X-CSDash-Token: nope" "$B/api/overview")"

# read endpoints carry real data
OV=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/overview")
t_contains "overview names sandbox project" "testproj" "$OV"
TH=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/threads?project=testproj")
t_contains "threads endpoint returns the demo thread" "Demo thread" "$TH"
PE=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/peers?project=testproj")
t_contains "peers endpoint reports syncthing offline (sandbox)" '"syncthing_ok": false' "$PE"

# API key must NEVER be exposed to the browser
case "$OV$TH$PE" in
  *test-key*|*syncthing_api_key*) t_fail "Syncthing API key leaked in a response" ;;
  *) t_pass "API key never appears in any response" ;;
esac

# accept-pairing: token gate + ID validation BEFORE any shell-out
t_eq "accept WITHOUT token → 403" "403" "$(code -X POST "$B/api/accept-pairing")"
BADCODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "X-CSDash-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"device_id":"not-a-valid-id"}' "$B/api/accept-pairing")
t_eq "accept with malformed id → 400" "400" "$BADCODE"
BADBODY=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "Content-Type: application/json" \
  -d '{"device_id":"not-a-valid-id"}' "$B/api/accept-pairing")
t_contains "malformed-id error names the format" "invalid device id format" "$BADBODY"

# unknown path → 404 (with token)
t_eq "unknown path → 404" "404" "$(code -H "X-CSDash-Token: $TOKEN" "$B/api/nope")"

cleanup
rm -f "$STATE"
t_done
