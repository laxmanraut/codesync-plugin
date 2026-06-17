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

# Make the launch-agent endpoint hermetic: the server inherits this to the
# launch-agent.sh subprocess, so codesync_launch_terminal records the would-run
# launcher here instead of spawning a real terminal.
export CODESYNC_TEST_LAUNCH_LOG="$HOME/.config/codesync/launch.log"

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
J='Content-Type: application/json'   # defined early so every block below can use it

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

# accept-pairing now uses the strong write gate (header-only token + Host + Origin),
# same as launch-agent. The shipped frontend already sends the token as a header.
t_eq "accept with ?t= but no header → 403" "403" \
  "$(code -X POST -H 'Content-Type: application/json' -d '{"device_id":"x"}' "$B/api/accept-pairing?t=$TOKEN")"
t_eq "accept with bad Host → 403" "403" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H 'Host: evil.example' -H 'Content-Type: application/json' -d '{"device_id":"x"}' "$B/api/accept-pairing")"
t_eq "accept cross-Origin → 403" "403" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H 'Origin: http://evil.example' -H 'Content-Type: application/json' -d '{"device_id":"x"}' "$B/api/accept-pairing")"

# /api/activity (v0.25): full payload, token-gated, key never leaked
t_eq "activity WITHOUT token → 403" "403" "$(code "$B/api/activity?project=testproj")"
ACT=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/activity?project=testproj")
t_contains "activity returns a feed" '"feed"' "$ACT"
t_contains "activity returns attention" '"attention"' "$ACT"
t_contains "activity returns autopilot" '"autopilot"' "$ACT"
t_contains "activity returns metrics" '"metrics"' "$ACT"
case "$ACT" in *test-key*|*_processed*) t_fail "activity leaked api key or internal field" ;; *) t_pass "activity payload clean (no key, no _processed)" ;; esac
# sync-conflict surfacing (launch-agents T1)
t_contains "activity payload carries a conflicts list" '"conflicts"' "$ACT"
printf 'loser copy\n' > "$PROJ/_inbox/qa/thread.sync-conflict-20260101-120000-AAAAAAA.md"
ACTC=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/activity?project=testproj")
t_contains "a Syncthing conflict file is surfaced" "sync-conflict-20260101" "$ACTC"
rm -f "$PROJ/_inbox/qa/thread.sync-conflict-20260101-120000-AAAAAAA.md"
# live agent sessions (launch-agents #2): token-gated; a live-pid session lists
t_eq "sessions WITHOUT token → 403" "403" "$(code "$B/api/sessions?project=testproj")"
mkdir -p "$HOME/.config/codesync/sessions"
# The server checks liveness by the WINDOWS pid; in Git Bash $$ is the MSYS pid,
# so use /proc/$$/winpid where present (falls back to $$ on macOS).
TPID=$$; [ -r "/proc/$$/winpid" ] && TPID=$(cat "/proc/$$/winpid")
printf 'testproj\tqa\t%s\t2026-01-01T00:00:00Z\n' "$TPID" > "$HOME/.config/codesync/sessions/$TPID.session"
SESS=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/sessions?project=testproj")
t_contains "sessions endpoint lists the live session" '"role": "qa"' "$SESS"
rm -f "$HOME/.config/codesync/sessions/$TPID.session"

# stop-session: kills OUR session, refuses a non-session pid, token-gated.
SDIR="$HOME/.config/codesync/sessions"; mkdir -p "$SDIR"
t_eq "stop WITHOUT token → 403" "403" \
  "$(code -X POST -H "$J" -d '{"project":"testproj","pid":1}' "$B/api/stop-session")"
# a real process that IS one of our sessions → stopped + file removed.
# Use the WINDOWS pid (winpid) so taskkill actually targets it on Git Bash —
# otherwise it gets the MSYS pid, never kills, and `wait` blocks the full 60s.
sleep 60 & SPID=$!
SWPID=$SPID; [ -r "/proc/$SPID/winpid" ] && SWPID=$(cat "/proc/$SPID/winpid")
printf 'testproj\tqa\t%s\t2026-01-01T00:00:00Z\n' "$SWPID" > "$SDIR/$SWPID.session"
SR=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d "{\"project\":\"testproj\",\"pid\":$SWPID}" "$B/api/stop-session")
t_contains "stop reports stopped" '"stopped": true' "$SR"
t_refute "stopped session file removed" test -f "$SDIR/$SWPID.session"
wait "$SPID" 2>/dev/null || true
# SECURITY: a pid with NO session file is refused and NOT killed
sleep 60 & OPID=$!
SR2=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d "{\"project\":\"testproj\",\"pid\":$OPID}" "$B/api/stop-session")
t_eq "stop a non-session pid → 404" "404" "$SR2"
t_assert "non-session process was NOT killed" kill -0 "$OPID"
kill "$OPID" 2>/dev/null || true

# unknown path → 404 (with token)
t_eq "unknown path → 404" "404" "$(code -H "X-CSDash-Token: $TOKEN" "$B/api/nope")"

# ── launch-agent (T3/T4): stronger write gate + allowlist ───────────────────
LB='{"project":"testproj","role":"qa"}'
J='Content-Type: application/json'
# header-only token: a query token must NOT authorize a write/spawn endpoint
t_eq "launch with ?t= but no header → 403" "403" \
  "$(code -X POST -H "$J" -d "$LB" "$B/api/launch-agent?t=$TOKEN")"
t_eq "launch without token → 403" "403" \
  "$(code -X POST -H "$J" -d "$LB" "$B/api/launch-agent")"
t_eq "launch with bad Host → 403 (anti DNS-rebind)" "403" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H 'Host: evil.example' -H "$J" -d "$LB" "$B/api/launch-agent")"
t_eq "launch cross-Origin → 403 (anti cross-site POST)" "403" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H 'Origin: http://evil.example' -H "$J" -d "$LB" "$B/api/launch-agent")"
# valid launch (hermetic): allowlist passes, hook records the launcher
LR=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d "$LB" "$B/api/launch-agent")
t_contains "valid launch reports launched" '"launched": true' "$LR"
t_contains "launch wrote a self-deleting launcher" 'rm -f -- "$0"' \
  "$(cat "$HOME/.config/codesync/launch.log" 2>/dev/null)"
# allowlist rejections
t_eq "launch unknown project → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"nope","role":"qa"}' "$B/api/launch-agent")"
t_eq "launch unregistered role → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"testproj","role":"designer"}' "$B/api/launch-agent")"

# ── capability presets (control-panel Layer 2): the preset table is authority ──
LOG="$HOME/.config/codesync/launch.log"
# GET /api/launch-options is token-gated and lists the fixed presets.
t_eq "launch-options WITHOUT token → 403" "403" "$(code "$B/api/launch-options?project=testproj")"
LO=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/launch-options?project=testproj")
t_contains "launch-options lists the reviewer preset" '"key": "reviewer"' "$LO"
t_contains "launch-options exposes the preset tool string" "Read,Glob,Grep" "$LO"
# a valid capability resolves to its FIXED preset string in the launcher
LRC=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"qa","capability":"reviewer"}' "$B/api/launch-agent")
t_contains "capability launch reports launched" '"launched": true' "$LRC"
# %q escapes commas on some bash builds (Read\,Glob\,Grep) and not others, so
# strip backslashes before matching the read-only scope; the escaping ITSELF is
# proven by the reply-only check below (parens/glob escape in every bash).
CLEAN=$(tr -d '\\' < "$LOG")
t_contains "reviewer launcher scopes claude to read-only tools" '--allowedTools Read,Glob,Grep' "$CLEAN"
# reply-only carries shell metacharacters — they must be %q-escaped, not raw
curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"qa","capability":"reply-only"}' "$B/api/launch-agent" >/dev/null
t_assert "reply-only tool spec is %q-escaped in the launcher (parens/glob neutralised)" \
  grep -Fq -- 'Bash\(write-thread.sh:\*\)' "$LOG"
# SECURITY REGRESSION #1 — over-privilege refusal: a capability that is not a
# known preset KEY (here an attempt to grant broad shell) → 400, never launched.
t_eq "over-privilege capability refused → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
     -d '{"project":"testproj","role":"qa","capability":"Bash(:*)"}' "$B/api/launch-agent")"
# SECURITY REGRESSION #2 — injection refusal: a raw tool string with shell
# metacharacters as the capability is rejected (membership in the preset table
# IS the allowlist), so it can never reach claude verbatim.
t_eq "injection-y capability string refused → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
     -d '{"project":"testproj","role":"qa","capability":"editor; rm -rf /"}' "$B/api/launch-agent")"
# the advisory role file only SEEDS the UI default — an editor-matching codesync
# block makes launch-options seed qa→editor (display only; authority unchanged).
printf -- '---\ncodesync:\n  title: qa\n  allowed-tools: [Read, Glob, Grep, Edit, Write]\n  autonomy: notify\n---\n# qa\n' > "$PROJ/_roles/qa.md"
LO2=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/launch-options?project=testproj")
t_contains "advisory role tools seed the UI default (qa→editor)" '"qa": "editor"' "$LO2"
rm -f "$PROJ/_roles/qa.md"

# ── create-role (T5/T6): gate + collision + overlap-confirm + atomic write ──
mkdir -p "$PROJ/_roles"
printf '# backend\n\n## Owns\n- REST/GraphQL APIs\n\n## Does not own\n- UI\n' > "$PROJ/_roles/backend.md"
# (J / launch-section vars defined near the top now)
t_eq "create-role without token → 403" "403" \
  "$(code -X POST -H "$J" -d '{"project":"testproj","role":"newrole"}' "$B/api/create-role")"
t_eq "create-role bad role name → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"testproj","role":"Bad Name"}' "$B/api/create-role")"
t_eq "create-role reserved Windows name (con) → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"testproj","role":"con","owns":["x"]}' "$B/api/create-role")"
COL=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"backend","owns":["x"]}' "$B/api/create-role")
t_contains "name collision refused (no clobber)" "already exists" "$COL"
# overlapping Owns without confirm → 409 needs_confirm, nothing written
OV=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"api2","owns":["REST/GraphQL APIs"]}' "$B/api/create-role")
t_contains "overlapping Owns asks for confirm" '"needs_confirm": true' "$OV"
t_contains "overlap names the conflicting role" '"role": "backend"' "$OV"
t_refute "overlap did NOT write the role file" test -f "$PROJ/_roles/api2.md"
# confirm=true → created + registered + written
CRR=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"api2","owns":["REST/GraphQL APIs"],"confirm":true}' "$B/api/create-role")
t_contains "confirmed create reports created" '"created": true' "$CRR"
t_assert "confirmed create wrote the role file" test -f "$PROJ/_roles/api2.md"
t_contains "new role registered in local config" "api2" "$(cat "$HOME/.config/codesync/config.json")"
# distinct role needs no confirm
DR=$(curl -s -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" \
  -d '{"project":"testproj","role":"writer","owns":["Documentation and tutorials"]}' "$B/api/create-role")
t_contains "distinct role creates without confirm" '"created": true' "$DR"
# GET /api/roles serves the catalog (token-gated read)
t_eq "roles catalog WITHOUT token → 403" "403" "$(code "$B/api/roles")"
RC=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/roles")
t_contains "roles catalog serves predefined roles" "backend" "$RC"

# ── autonomy review queue (Layer 3 T7): read gated; action gated + allowlisted ─
t_eq "reviews WITHOUT token → 403" "403" "$(code "$B/api/reviews?project=testproj")"
RVQ=$(curl -s -H "X-CSDash-Token: $TOKEN" "$B/api/reviews?project=testproj")
t_contains "reviews endpoint returns a list" '"reviews"' "$RVQ"
RAB='{"project":"testproj","id":"backend-20260101-000000","action":"approve"}'
t_eq "review-action with ?t= but no header → 403" "403" \
  "$(code -X POST -H "$J" -d "$RAB" "$B/api/review-action?t=$TOKEN")"
t_eq "review-action cross-Origin → 403" "403" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H 'Origin: http://evil.example' -H "$J" -d "$RAB" "$B/api/review-action")"
t_eq "review-action bad action → 400" "400" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"testproj","id":"x","action":"nuke"}' "$B/api/review-action")"
t_eq "review-action unknown id → 404" "404" \
  "$(code -X POST -H "X-CSDash-Token: $TOKEN" -H "$J" -d '{"project":"testproj","id":"ghost-20260101-000000","action":"reject"}' "$B/api/review-action")"
t_eq "review-diff WITHOUT token → 403" "403" "$(code "$B/api/review-diff?project=testproj&id=backend-20260101-000000")"
t_eq "review-diff unknown id → 404" "404" \
  "$(code -H "X-CSDash-Token: $TOKEN" "$B/api/review-diff?project=testproj&id=ghost-20260101-000000")"

cleanup
rm -f "$STATE"
t_done
