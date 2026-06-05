#!/usr/bin/env bash
# status.sh — Print health of the active CodeSync project on this machine.
# Read-only: never mutates Syncthing or config.
# Hard-errors if CODESYNC_PROJECT is not set or the named project isn't registered.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("syncthing_api_key", ""))' "$CFG_FILE")
[ -n "$API_KEY" ] || err "syncthing_api_key missing in $CFG_FILE. Re-run /install-codesync."

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

ACTIVE_PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$ACTIVE_PROJECT" ] || err "No project active in this terminal. Set CODESYNC_PROJECT or attach this directory with /codesync-project-attach. Run /codesync-project-list to see what's registered."

# Confirm the project exists in config
PROJECT_EXISTS=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in cfg.get("projects", {}) else "no")
' "$CFG_FILE" "$ACTIVE_PROJECT")
[ "$PROJECT_EXISTS" = "yes" ] || err "CODESYNC_PROJECT='$ACTIVE_PROJECT' is set but no project by that name is registered. Run /codesync-project-list."

# Probe Syncthing
STATUS_OK=no
if curl -sf -H "X-API-Key: $API_KEY" --max-time 5 "$API/rest/system/status" >/dev/null 2>&1; then
  STATUS_OK=yes
fi

python3 - "$CFG_FILE" "$API" "$API_KEY" "$STATUS_OK" "$ACTIVE_PROJECT" <<'PY'
import json, os, sys, urllib.request, urllib.error

cfg_path, api, api_key, status_ok, project_name = sys.argv[1:6]

with open(cfg_path) as f:
    cfg = json.load(f)

project   = cfg["projects"][project_name]
folder_id = project["folder_id"]
proj_path = project["path"]
device_id = cfg.get("device_id", "")
active_role = os.environ.get("CODESYNC_ROLE", "").strip()

def get(path, timeout=5):
    req = urllib.request.Request(f"{api}{path}", headers={"X-API-Key": api_key})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def fmt(v): return v if v else "(not set)"

print()
print("CodeSync status")
print("───────────────")
print(f"  Active project:               {project_name}")
print(f"  Active role (this terminal):  {fmt(active_role)}" if active_role else
      "  Active role (this terminal):  (none — set CODESYNC_ROLE in your shell)")
print(f"  Project path:                 {proj_path}")
print(f"  Device ID:                    {fmt(device_id)}")
print()
print(f"  Syncthing API:                {'reachable' if status_ok == 'yes' else 'NOT REACHABLE'}")

if status_ok != "yes":
    print()
    print("Syncthing isn't responding. Try: brew services restart syncthing")
    print()
    sys.exit(0)

# Peers attached to THIS PROJECT's folder
print()
print(f"  Peers on project '{project_name}':")
try:
    folder = get(f"/rest/config/folders/{folder_id}")
    folder_devices = {d.get("deviceID") for d in folder.get("devices", []) if d.get("deviceID") != device_id}
    conns_doc = get("/rest/system/connections")
    conns = conns_doc.get("connections", {})
    all_devices = {d["deviceID"]: d for d in get("/rest/config/devices")}

    if not folder_devices:
        print("    (none — run /codesync-pair --peer <id> or /codesync-project-invite to add one)")
    else:
        for pid in sorted(folder_devices):
            d = all_devices.get(pid, {})
            name = d.get("name") or "(unnamed)"
            c = conns.get(pid, {})
            connected = bool(c.get("connected"))
            addr = c.get("address", "") or ""
            tag = "connected" if connected else "DISCONNECTED"
            suffix = f"  {addr}" if connected and addr else ""
            print(f"    {name}  ({pid[:7]}…)  →  {tag}{suffix}")
except urllib.error.URLError as e:
    print(f"    (failed to fetch peer info: {e})")

# Folder sync status
print()
print(f"  Folder '{folder_id}':")
try:
    fstat = get(f"/rest/db/status?folder={folder_id}")
    state = fstat.get("state", "?")
    local = fstat.get("localFiles", 0)
    glob  = fstat.get("globalFiles", 0)
    need  = fstat.get("needFiles", 0)
    print(f"    state:        {state}")
    print(f"    local files:  {local}")
    print(f"    global files: {glob}")
    print(f"    pending:      {need} files to sync" if need else "    pending:      up to date")
except urllib.error.URLError as e:
    print(f"    (failed to fetch folder status: {e})")

# Roles in this project
print()
print(f"  Roles in project '{project_name}':")
roles_dir = os.path.join(proj_path, "_roles")
if os.path.isdir(roles_dir):
    files = sorted(f for f in os.listdir(roles_dir) if f.endswith(".md") and f != "README.md")
    if not files:
        print("    (none registered yet — run /codesync-role-new)")
    else:
        for rf in files:
            name = rf[:-3]
            tag = "  ← active here" if name == active_role else ""
            print(f"    {name}{tag}")
else:
    print("    (_roles/ directory not found inside the project path)")
print()
PY
