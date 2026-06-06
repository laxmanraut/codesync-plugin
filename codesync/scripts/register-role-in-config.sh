#!/usr/bin/env bash
# register-role-in-config.sh — Add role name(s) to this machine's local config
# under projects.<name>.roles. The list is LOCAL to this device (not synced) —
# it tracks which roles this device has registered, so the Stop hook and
# SessionStart hook can iterate all of them when surfacing inboxes.
#
# Args:
#   --project <name>           (required) must exist in config.json
#   --role <role-name>         (required, repeatable) role(s) to register
#
# Idempotent. Deduplicates. Preserves existing roles in the list.

set -euo pipefail

CFG_FILE="$HOME/.config/codesync/config.json"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT=""
ROLES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || err "--project requires a value"
      PROJECT="$2"
      shift 2
      ;;
    --role)
      [ $# -ge 2 ] || err "--role requires a value"
      ROLES+=("$2")
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$PROJECT" ]   || err "Usage: register-role-in-config.sh --project <name> --role <r> [--role <r2> ...]"
[ ${#ROLES[@]} -gt 0 ] || err "At least one --role required"
[ -f "$CFG_FILE" ]  || err "Config not found at $CFG_FILE. Run /install-codesync first."

python3 - "$CFG_FILE" "$PROJECT" "${ROLES[@]}" <<'PY'
import json, sys
cfg_path = sys.argv[1]
project  = sys.argv[2]
new_roles = sys.argv[3:]
with open(cfg_path) as f:
    cfg = json.load(f)
projects = cfg.setdefault("projects", {})
if project not in projects:
    print(f"ERROR: project '{project}' not registered. Run /codesync-project-new first.", file=sys.stderr)
    sys.exit(1)
proj = projects[project]
existing = proj.get("roles", [])
merged = list(existing)
for r in new_roles:
    if r not in merged:
        merged.append(r)
proj["roles"] = merged
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"REGISTERED_ROLES={','.join(merged)}")
PY

chmod 600 "$CFG_FILE"
