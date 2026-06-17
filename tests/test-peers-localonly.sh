#!/usr/bin/env bash
# Regression: gather_peers / gather_folder_status must not crash for a LOCAL-ONLY
# project (no Syncthing folder_id). With a REACHABLE daemon, an empty folder_id
# hit /rest/config/folders/ (the collection) which returns a LIST, and the code
# did folder.get(...) → "'list' object has no attribute 'get'". The hermetic
# sandbox is offline (so _syncthing_get returns None and the old code returned
# early), which is exactly why this slipped through — so here we STUB a reachable
# daemon that returns lists.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

OUT=$($PY_BIN - "$SCRIPTS/lib" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import state
# Reachable daemon; folders/devices collection endpoints return LISTS.
state.syncthing_reachable = lambda cfg: True
state._syncthing_get = lambda cfg, path, timeout=4: [] if ("folders" in path or "devices" in path) else {}
# (a) local-only project: no folder_id at all
cfg = {"device_id": "AAA", "projects": {"local": {"path": "/tmp/x"}}}
print("PEERS_LOCAL", json.dumps(state.gather_peers(cfg, "local")))
print("FOLDER_LOCAL", json.dumps(state.gather_folder_status(cfg, "local")))
# (b) has a folder_id but the daemon hands back a list anyway (isinstance guard)
cfg2 = {"device_id": "AAA", "projects": {"shared": {"path": "/tmp/y", "folder_id": "fid"}}}
print("PEERS_GUARD", json.dumps(state.gather_peers(cfg2, "shared")))
PY
)

t_contains "gather_peers: local-only project does not crash"   '"syncthing_ok": true' "$OUT"
t_contains "gather_peers: local-only returns no peers"          'PEERS_LOCAL {"syncthing_ok": true, "peers": []}' "$OUT"
t_contains "gather_folder_status: local-only reports a state"   'local only' "$OUT"
t_contains "gather_peers: list-shaped folder is guarded"        'PEERS_GUARD {"syncthing_ok": true, "peers": []}' "$OUT"

t_done
