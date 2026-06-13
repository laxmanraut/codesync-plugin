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

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
# (also loads the platform layer that resolves PY_BIN — must precede any use)
. "$SCRIPT_DIR/lib/load-env.sh"
[ -n "${PY_BIN:-}" ] || err "No usable Python found (tried python3, python, py -3)."

API_KEY=$($PY_BIN -c 'import json,sys; print(json.load(open(sys.argv[1])).get("syncthing_api_key", ""))' "$CFG_FILE")
[ -n "$API_KEY" ] || err "syncthing_api_key missing in $CFG_FILE. Re-run /install-codesync."

ACTIVE_PROJECT="${CODESYNC_PROJECT:-}"

# Incoming pairing requests (machine-level — relevant in both modes).
# A peer that ran /codesync-pair with our device ID is waiting for us to
# accept; Syncthing parks the request in /rest/cluster/pending/devices.
show_pending_pairings() {
  PENDING=$(curl -s --max-time 2 -H "X-API-Key: $API_KEY" \
    "$API/rest/cluster/pending/devices" 2>/dev/null) || PENDING=""
  [ -n "$PENDING" ] && [ "$PENDING" != "{}" ] || return 0
  # JSON via argv, not a pipe — `python -` reads its program from stdin,
  # which the heredoc owns; piped data would be silently lost.
  $PY_BIN - "$PENDING" "$SCRIPT_DIR/lib" <<'PY' 2>/dev/null
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
try:
    # Validation + sanitisation from state.sanitize_pending (single source,
    # eng-review R1). Curl fetch stays in bash above; this only formats.
    sys.path.insert(0, sys.argv[2])
    import state
    entries = state.sanitize_pending(json.loads(sys.argv[1]))
    if not entries:
        sys.exit(0)
    print(f"  Incoming pairing requests ({len(entries)}):")
    for e in entries:
        print(f"    \"{e['name']}\"  {e['id']}  (first seen: {e['time']})")
        print(f"      Accept: /codesync-pair --peer {e['id']}")
    print("    Only accept devices you recognise — pairing shares the project folder.")
    print()
except Exception:
    pass
PY
  return 0
}

# If no project active in this terminal, fall into "summary" mode — list all
# registered projects, their roles, their paths. Then exit (skip the
# Syncthing health detail which is per-project).
if [ -z "$ACTIVE_PROJECT" ]; then
  $PY_BIN - "$CFG_FILE" "$SCRIPT_DIR/lib" <<'PY'
import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # cp1252 default on Windows
except Exception:
    pass
sys.path.insert(0, sys.argv[2])
import state  # single source of truth (eng-review R1)
o = state.gather_overview(state.load_config(sys.argv[1]))
identity = o["identity"]; device_id = o["device_id"]; projects = o["projects"]
print()
print("CodeSync status (no project active in this terminal)")
print("────────────────────────────────────────────────────")
print(f"  Identity:    {identity or '(not set — re-run /install-codesync)'}")
print(f"  Device ID:   {device_id or '(missing)'}")
print()
if not projects:
    print("  No projects registered yet. Run /install-codesync to create one.")
else:
    print(f"  Projects on this machine ({len(projects)}):")
    for p in projects:  # gather_overview already sorts by name
        path = p["path"] or "?"
        roles = p["roles"]
        roles_str = ", ".join(roles) if roles else "(no roles registered on this device)"
        print(f"    {p['name']}")
        print(f"      path:  {path}")
        print(f"      roles: {roles_str}")
print()
print("To activate one in this terminal:  export CODESYNC_PROJECT=<name> CODESYNC_ROLE=<role>")
print("(or use the `cs` wrapper if you've added it to your shell)")
print()
PY
  show_pending_pairings
  exit 0
fi

# Confirm the project exists in config
PROJECT_EXISTS=$($PY_BIN -c '
import json, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # cp1252 default on Windows
except Exception:
    pass
cfg = json.load(open(sys.argv[1]))
print("yes" if sys.argv[2] in cfg.get("projects", {}) else "no")
' "$CFG_FILE" "$ACTIVE_PROJECT")
[ "$PROJECT_EXISTS" = "yes" ] || err "CODESYNC_PROJECT='$ACTIVE_PROJECT' is set but no project by that name is registered. Run /codesync-status (in a terminal without CODESYNC_PROJECT) to list registered projects."

# Probe Syncthing
STATUS_OK=no
if curl -sf -H "X-API-Key: $API_KEY" --max-time 5 "$API/rest/system/status" >/dev/null 2>&1; then
  STATUS_OK=yes
fi

$PY_BIN - "$CFG_FILE" "$API" "$API_KEY" "$STATUS_OK" "$ACTIVE_PROJECT" "$SCRIPT_DIR/lib" <<'PY'
import json, os, sys
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # cp1252 default on Windows
except Exception:
    pass

cfg_path, api, api_key, status_ok, project_name, lib_dir = sys.argv[1:7]
sys.path.insert(0, lib_dir)
import state  # single source of truth (eng-review R1); peers/folder via gather_*

with open(cfg_path) as f:
    cfg = json.load(f)

project   = cfg["projects"][project_name]
folder_id = project["folder_id"]
proj_path = project["path"]
device_id = cfg.get("device_id", "")
identity = cfg.get("identity", "")
active_role = os.environ.get("CODESYNC_ROLE", "").strip()
registered_roles = project.get("roles", []) or []

def fmt(v): return v if v else "(not set)"

print()
print("CodeSync status")
print("───────────────")
print(f"  Active project:               {project_name}")
print(f"  Active role (this terminal):  {fmt(active_role)}" if active_role else
      "  Active role (this terminal):  (none — set CODESYNC_ROLE in your shell)")
if registered_roles:
    print(f"  Roles registered on device:   {', '.join(registered_roles)}")
else:
    print(f"  Roles registered on device:   (none — run /codesync-role-new)")
print(f"  Identity (for thread attribution): {fmt(identity)}" if identity else
      "  Identity (for thread attribution): (none — re-run /install-codesync to capture)")
print(f"  Project path:                 {proj_path}")
print(f"  Device ID:                    {fmt(device_id)}")
print()
print(f"  Syncthing API:                {'reachable' if status_ok == 'yes' else 'NOT REACHABLE'}")

if status_ok != "yes":
    print()
    print("Syncthing isn't responding. Try: brew services restart syncthing")
    print()
    sys.exit(0)

# Peers attached to THIS PROJECT's folder (via state.gather_peers — same
# Syncthing calls as before, one source). Self-excluded + pid-sorted inside.
print()
print(f"  Peers on project '{project_name}':")
pdata = state.gather_peers(cfg, project_name)
if not pdata["syncthing_ok"]:
    print("    (failed to fetch peer info)")
elif not pdata["peers"]:
    print("    (none — run /codesync-pair --peer <id> to add one)")
else:
    for p in pdata["peers"]:
        tag = "connected" if p["connected"] else "DISCONNECTED"
        suffix = f"  {p['address']}" if p["connected"] and p["address"] else ""
        print(f"    {p['name']}  ({p['id_short']}…)  →  {tag}{suffix}")

# Folder sync status (via state.gather_folder_status)
print()
print(f"  Folder '{folder_id}':")
fdata = state.gather_folder_status(cfg, project_name)
if not fdata["syncthing_ok"]:
    print("    (failed to fetch folder status)")
else:
    need = fdata["need_files"]
    print(f"    state:        {fdata['state']}")
    print(f"    local files:  {fdata['local_files']}")
    print(f"    global files: {fdata['global_files']}")
    print(f"    pending:      {need} files to sync" if need else "    pending:      up to date")

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
            tags = []
            if name == active_role:
                tags.append("← active here")
            if name in registered_roles:
                tags.append("← registered on this device")
            tag = "  " + ", ".join(tags) if tags else ""
            print(f"    {name}{tag}")
else:
    print("    (_roles/ directory not found inside the project path)")
print()
PY

show_pending_pairings
