#!/usr/bin/env bash
# migrate-v0.5.0.sh — One-time migration from v0.4.x to v0.5.0.
#
# v0.4.x: single ~/contracts/ folder. config.json has contracts_dir +
#         syncthing_folder_id at top level. Role was a single per-machine
#         field (later moved to env var; the field is now obsolete).
#
# v0.5.0: ~/codesync/<project>/ per project. config.json has a projects
#         map keyed by project name; machine-level fields stay at top.
#
# Idempotent: silent no-op if already migrated to the new schema.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"
API="http://127.0.0.1:8384"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."
command -v python3 >/dev/null 2>&1 || err "python3 required."
command -v curl    >/dev/null 2>&1 || err "curl required."

# 1. Detect schema. Skip if already migrated.
SCHEMA=$(python3 - "$CFG_FILE" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
if isinstance(cfg.get("projects"), dict):
    print("new")
elif "contracts_dir" in cfg:
    print("old")
else:
    print("unknown")
PY
)

if [ "$SCHEMA" = "new" ]; then
  log "Config already in v0.5.0 schema — nothing to migrate."
  exit 0
elif [ "$SCHEMA" != "old" ]; then
  err "Cannot detect config schema. Bailing out."
fi

# 2. Project name: positional arg, env var, or default
PROJECT_NAME="${1:-${CODESYNC_MIGRATE_PROJECT:-lead_inbox}}"

# 3. Read v0.4.x fields
API_KEY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["syncthing_api_key"])' "$CFG_FILE")
FOLDER_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["syncthing_folder_id"])' "$CFG_FILE")
OLD_PATH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contracts_dir"])' "$CFG_FILE")
DEVICE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device_id"])' "$CFG_FILE")

[ -n "$API_KEY"   ] || err "syncthing_api_key missing in $CFG_FILE."
[ -n "$FOLDER_ID" ] || err "syncthing_folder_id missing in $CFG_FILE."
[ -n "$OLD_PATH"  ] || err "contracts_dir missing in $CFG_FILE."
[ -n "$DEVICE_ID" ] || err "device_id missing in $CFG_FILE."

NEW_PATH="$HOME/codesync/$PROJECT_NAME"

[ -d "$OLD_PATH" ] || err "Old contracts dir $OLD_PATH not found. Did migration partially run? Check $NEW_PATH and the config file."
[ -e "$NEW_PATH" ] && err "New path $NEW_PATH already exists. Aborting to avoid clobbering."

# 4. Back up config.json
BACKUP="$CFG_FILE.v0.4.bak"
cp "$CFG_FILE" "$BACKUP"
log "Backed up config to $BACKUP"

api() { curl -sf -H "X-API-Key: $API_KEY" "$@"; }

# 5. Confirm Syncthing is alive
api "$API/rest/system/status" >/dev/null \
  || err "Syncthing REST API not responding. Start it: brew services start syncthing"

# 6. Pause the folder via PUT (Syncthing 2.x: paused flag is in folder config, no /rest/db/pause endpoint).
#    Pausing first so Syncthing doesn't notice the file shuffle and propagate deletions to peer.
log "Pausing Syncthing folder '$FOLDER_ID'..."
FOLDER_JSON=$(api "$API/rest/config/folders/$FOLDER_ID") || err "Failed to GET folder config"
PAUSED_JSON=$(python3 - "$FOLDER_JSON" <<'PY'
import json, sys
folder = json.loads(sys.argv[1])
folder["paused"] = True
print(json.dumps(folder))
PY
)
api -X PUT -H "Content-Type: application/json" --data-binary "$PAUSED_JSON" \
  "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
  || err "Failed to pause Syncthing folder"

# Give Syncthing a moment to actually quiesce the watcher
sleep 1

# 7. Move files
log "Moving $OLD_PATH → $NEW_PATH..."
mkdir -p "$HOME/codesync"
mv "$OLD_PATH" "$NEW_PATH" || err "Failed to move folder (Syncthing is paused; you can manually move back and re-run)"

# 8. Update Syncthing folder path AND resume in one PUT
log "Updating Syncthing folder path and resuming..."
FOLDER_JSON=$(api "$API/rest/config/folders/$FOLDER_ID") || err "Failed to GET folder config after move"
UPDATED=$(python3 - "$FOLDER_JSON" "$NEW_PATH" <<'PY'
import json, sys
folder = json.loads(sys.argv[1])
folder["path"]   = sys.argv[2]
folder["paused"] = False
print(json.dumps(folder))
PY
)
api -X PUT -H "Content-Type: application/json" --data-binary "$UPDATED" \
  "$API/rest/config/folders/$FOLDER_ID" >/dev/null \
  || err "Failed to PUT updated folder config. Files are at $NEW_PATH; fix Syncthing path manually at http://127.0.0.1:8384"

# 10. Rewrite config.json to v0.5.0 schema
log "Rewriting config to v0.5.0 schema..."
python3 - "$CFG_FILE" "$PROJECT_NAME" "$NEW_PATH" "$FOLDER_ID" "$API_KEY" "$DEVICE_ID" <<'PY'
import json, sys
cfg_path, project, new_path, folder_id, api_key, device_id = sys.argv[1:7]
new_cfg = {
    "syncthing_api_key": api_key,
    "device_id":         device_id,
    "projects": {
        project: {
            "path":      new_path,
            "folder_id": folder_id,
        }
    },
}
with open(cfg_path, "w") as f:
    json.dump(new_cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"

log "Migration complete."
printf '\n'
printf 'MIGRATED_PROJECT=%s\n' "$PROJECT_NAME"
printf 'PROJECT_PATH=%s\n' "$NEW_PATH"
printf 'FOLDER_ID=%s\n' "$FOLDER_ID"
