#!/usr/bin/env bash
# create-project.sh — Create a new CodeSync project (v0.5.0+).
# Args: --name <project-name>
# - Creates ~/codesync/<name>/ with _roles/ and _inbox/ scaffolding.
# - Registers a new Syncthing folder with id codesync-<name> at that path.
# - Adds the project to ~/.config/codesync/config.json's projects map.
# Idempotent: safe to re-run (re-creating directories, re-registering folder).
# Refuses if a project with that name already exists in config.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. Args — accept --name <project>
PROJECT_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      [ $# -ge 2 ] || err "--name requires a value"
      PROJECT_NAME="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$PROJECT_NAME" ] || err "Usage: create-project.sh --name <project-name>"

# 2. Validate project name (lowercase, alphanumerics, dash, underscore only)
if ! printf '%s' "$PROJECT_NAME" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
  err "Project name must be lowercase letters/digits with optional - or _ (got: '$PROJECT_NAME')"
fi

# 3. Load machine-level config
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."
API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["syncthing_api_key"])' "$CFG_FILE")
DEVICE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device_id"])' "$CFG_FILE")
[ -n "$API_KEY"   ] || err "syncthing_api_key missing in $CFG_FILE."
[ -n "$DEVICE_ID" ] || err "device_id missing in $CFG_FILE."

# 4. Refuse if a project with this name already exists
EXISTING=$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
projects = cfg.get("projects", {})
print("yes" if sys.argv[2] in projects else "no")
' "$CFG_FILE" "$PROJECT_NAME")
if [ "$EXISTING" = "yes" ]; then
  err "Project '$PROJECT_NAME' already exists in $CFG_FILE. Pick a different name, or run /codesync-status (in a terminal without CODESYNC_PROJECT) to see what's there."
fi

PROJECT_PATH="$HOME/codesync/$PROJECT_NAME"
FOLDER_ID="codesync-$PROJECT_NAME"

# 5. Sanity-check Syncthing is up
api() { curl -sf -H "X-API-Key: $API_KEY" "$@"; }
api "$API/rest/system/status" >/dev/null \
  || err "Syncthing REST API not responding. Try: brew services restart syncthing"

# 6. Create directory scaffolding
log "Creating project directory at $PROJECT_PATH..."
mkdir -p "$PROJECT_PATH/_roles" "$PROJECT_PATH/_inbox"

ROLES_README="$PROJECT_PATH/_roles/README.md"
if [ ! -f "$ROLES_README" ]; then
  cat > "$ROLES_README" <<'README'
# Role profiles

Each machine paired into this CodeSync project writes a markdown file here describing what role it plays. Claude agents read these files to route content correctly.

Files in this directory are written by `/codesync-role-new` (or by `/install-codesync` on first setup). You can edit them by hand, but the safer way is to re-run the role command.
README
fi

# Scaffold _docs/ + CLAUDE.md via the shared seeder (idempotent).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/seed-project-docs.sh" --project "$PROJECT_NAME" --path "$PROJECT_PATH" >/dev/null

# 7. Refuse if a Syncthing folder with this ID already exists
STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "X-API-Key: $API_KEY" "$API/rest/config/folders/$FOLDER_ID")
if [ "$STATUS" = "200" ]; then
  err "Syncthing already has a folder with id '$FOLDER_ID'. Project name conflicts with existing Syncthing state."
fi

# 8. Register the folder with Syncthing
log "Registering Syncthing folder '$FOLDER_ID' at $PROJECT_PATH..."
PAYLOAD=$(python3 - "$FOLDER_ID" "$PROJECT_PATH" "$PROJECT_NAME" <<'PY'
import json, sys
fid, path, label = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "id": fid,
    "label": f"CodeSync — {label}",
    "path": path,
    "type": "sendreceive",
    "versioning": {"type": "simple", "params": {"keep": "10"}},
}))
PY
)
api -X PUT -H "Content-Type: application/json" --data-binary "$PAYLOAD" \
  "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
  || err "Failed to register folder with Syncthing"

# 9. Add the project to config.json's projects map
python3 - "$CFG_FILE" "$PROJECT_NAME" "$PROJECT_PATH" "$FOLDER_ID" <<'PY'
import json, sys
cfg_path, name, path, folder_id = sys.argv[1:5]
with open(cfg_path) as f:
    cfg = json.load(f)
if not isinstance(cfg.get("projects"), dict):
    cfg["projects"] = {}
cfg["projects"][name] = {
    "path":      path,
    "folder_id": folder_id,
}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"
log "Added project '$PROJECT_NAME' to $CFG_FILE"

# 10. Output
printf '\n'
printf 'PROJECT_NAME=%s\n' "$PROJECT_NAME"
printf 'PROJECT_PATH=%s\n' "$PROJECT_PATH"
printf 'FOLDER_ID=%s\n' "$FOLDER_ID"
