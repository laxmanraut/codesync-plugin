#!/usr/bin/env bash
# status.sh — Print the health of the local CodeSync setup.
# Read-only: never mutates Syncthing or config.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("syncthing_api_key", ""))' "$CFG_FILE")
[ -n "$API_KEY" ] || err "syncthing_api_key missing in $CFG_FILE. Re-run /install-codesync."

# Probe Syncthing once so the python below knows whether to attempt API calls
STATUS_OK=no
if curl -sf -H "X-API-Key: $API_KEY" --max-time 5 "$API/rest/system/status" >/dev/null 2>&1; then
  STATUS_OK=yes
fi

python3 - "$CFG_FILE" "$API" "$API_KEY" "$STATUS_OK" <<'PY'
import json, os, sys, urllib.request, urllib.error

cfg_path, api, api_key, status_ok = sys.argv[1:5]

with open(cfg_path) as f:
    cfg = json.load(f)

role         = cfg.get("role", "")
role_file    = cfg.get("role_file", "")
contracts    = cfg.get("contracts_dir", "")
device_id    = cfg.get("device_id", "")
folder_id    = cfg.get("syncthing_folder_id", "")

def get(path, timeout=5):
    req = urllib.request.Request(f"{api}{path}", headers={"X-API-Key": api_key})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def fmt(v): return v if v else "(not set)"

print()
print("CodeSync status")
print("───────────────")
print(f"  Role:           {fmt(role)}")
print(f"  Role profile:   {fmt(role_file)}")
print(f"  Contracts dir:  {fmt(contracts)}")
print(f"  Device ID:      {fmt(device_id)}")
print()
print(f"  Syncthing API:  {'reachable' if status_ok == 'yes' else 'NOT REACHABLE'}")

if status_ok != "yes":
    print()
    print("Syncthing isn't responding. Try: brew services restart syncthing")
    print()
    sys.exit(0)

# Peers
print()
print("  Peers:")
try:
    devices = get("/rest/config/devices")
    conns_doc = get("/rest/system/connections")
    conns = conns_doc.get("connections", {})
    peers = [d for d in devices if d.get("deviceID") != device_id]
    if not peers:
        print("    (none — run /codesync-pair --peer <id> to add one)")
    else:
        for p in peers:
            pid = p["deviceID"]
            name = p.get("name") or "(unnamed)"
            c = conns.get(pid, {})
            connected = bool(c.get("connected"))
            addr = c.get("address", "") or ""
            tag = "connected" if connected else "DISCONNECTED"
            suffix = f"  {addr}" if connected and addr else ""
            print(f"    {name}  ({pid[:7]}…)  →  {tag}{suffix}")
except urllib.error.URLError as e:
    print(f"    (failed to fetch peer info: {e})")

# Folder
print()
print(f"  Folder '{folder_id}':")
try:
    fstat = get(f"/rest/db/status?folder={folder_id}")
    state    = fstat.get("state", "?")
    local    = fstat.get("localFiles", 0)
    glob     = fstat.get("globalFiles", 0)
    need     = fstat.get("needFiles", 0)
    print(f"    state:        {state}")
    print(f"    local files:  {local}")
    print(f"    global files: {glob}")
    print(f"    pending:      {need} files to sync" if need else "    pending:      up to date")
except urllib.error.URLError as e:
    print(f"    (failed to fetch folder status: {e})")

# Role profiles
print()
print("  Known roles (across all paired machines):")
roles_dir = os.path.join(contracts, "_roles") if contracts else None
if roles_dir and os.path.isdir(roles_dir):
    files = sorted(
        f for f in os.listdir(roles_dir)
        if f.endswith(".md") and f != "README.md"
    )
    if not files:
        print("    (none registered yet — run /install-codesync on this machine)")
    else:
        own = os.path.abspath(role_file) if role_file else ""
        for rf in files:
            full = os.path.abspath(os.path.join(roles_dir, rf))
            tag = "  ← this machine" if full == own else ""
            print(f"    {rf[:-3]}{tag}")
else:
    print("    (contracts directory or _roles/ not found)")

print()
PY
