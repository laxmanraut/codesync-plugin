#!/usr/bin/env bash
# autonomy-setup.sh — configure control-panel Layer 3 sandboxed autonomy for the
# active project. LOCAL authority only: nothing written here syncs to a peer, and
# enabling autonomy / setting tools is deliberately NOT read from the synced role
# file (A5 reversed — a peer can't arm an agent on your machine).
#
# Modes:
#   --repo-path PATH                  local git repo autonomy clones are made from
#                                     (must be OUTSIDE every synced project folder)
#   --model ID                        pin the model the runner passes to claude -p
#   --role R --enable [--tools STR]   enable autonomy for role R (+ effective tools)
#   --role R --disable                disable autonomy for role R
#   --status                          show the local autonomy config + clone state
set -euo pipefail

CONFIG_DIR="$HOME/.config/codesync"
CFG_FILE="$CONFIG_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/load-env.sh"
. "$SCRIPT_DIR/lib/autonomy.sh"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '  %s\n' "$*"; }

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active. Set CODESYNC_PROJECT first — autonomy is per project."
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."
[ -n "${PY_BIN:-}" ] || err "No usable Python found."

MODE="" REPO="" MODEL="" ROLE="" ENABLED="" TOOLS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-path) MODE="repo";  REPO="$2";  shift 2 ;;
    --model)     MODE="model"; MODEL="$2"; shift 2 ;;
    --role)      ROLE="$2";    shift 2 ;;
    --enable)    MODE="role";  ENABLED="1"; shift ;;
    --disable)   MODE="role";  ENABLED="0"; shift ;;
    --tools)     TOOLS="$2";   shift 2 ;;
    --status)    MODE="status"; shift ;;
    *) shift ;;
  esac
done
[ -n "$MODE" ] || err "nothing to do (try --status)"

printf '\nAutonomy setup — project %s (%s)\n' "$PROJECT" "$CODESYNC_OS"
printf '─────────────────────────────\n'

case "$MODE" in
  repo)
    OUT=$(codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$CFG_FILE" "$PROJECT" "$REPO" <<'PY'
import sys
lib, cd, cfgf, proj, repo = sys.argv[1:6]
sys.path.insert(0, lib)
import state
cfg = state.load_config(cfgf)
ok, e = state.set_autonomy_repo(cd, proj, repo, cfg)
print("OK " + state.load_autonomy(cd)["projects"][proj]["repo_path"] if ok else "ERR " + e)
PY
)
    case "$OUT" in
      OK*)  log "repo_path set: ${OUT#OK }" ;;
      *)    err "${OUT#ERR }" ;;
    esac
    ;;

  model)
    [ -n "$MODEL" ] || err "--model needs an id"
    codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$PROJECT" "$MODEL" <<'PY'
import sys
lib, cd, proj, model = sys.argv[1:5]
sys.path.insert(0, lib)
import state
state.set_autonomy_model(cd, proj, model)
PY
    log "model pinned: $MODEL"
    ;;

  role)
    [ -n "$ROLE" ] || err "--role is required with --enable/--disable"
    codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$PROJECT" "$ROLE" "$ENABLED" "$TOOLS" <<'PY'
import sys
lib, cd, proj, role, en, tools = sys.argv[1:7]
sys.path.insert(0, lib)
import state
state.set_autonomy_role(cd, proj, role, enabled=(en == "1"),
                        allowed_tools=(tools if tools else None))
PY
    if [ "$ENABLED" = "1" ]; then
      log "autonomy ENABLED for role '$ROLE'${TOOLS:+ (tools: $TOOLS)}"
      # Pre-create the isolation clone so misconfiguration surfaces now, not on
      # the first scheduled run. Skip quietly if no repo_path is set yet.
      REPO_SET=$(codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$PROJECT" <<'PY'
import sys
lib, cd, proj = sys.argv[1:4]
sys.path.insert(0, lib)
import state
print((state.load_autonomy(cd).get("projects", {}).get(proj, {}) or {}).get("repo_path", ""))
PY
)
      if [ -n "$REPO_SET" ]; then
        CLONE=$(codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$PROJECT" "$ROLE" <<'PY'
import sys
lib, cd, proj, role = sys.argv[1:5]
sys.path.insert(0, lib)
import state
print(state.autonomy_clone_dir(cd, proj, role))
PY
)
        if codesync_autonomy_ensure_clone "$REPO_SET" "$CLONE"; then
          codesync_autonomy_hooks_disabled "$CLONE" \
            && log "isolation clone ready (hooks disabled): $CLONE" \
            || log "WARNING: clone created but hooks not confirmed disabled"
        else
          log "WARNING: could not create the isolation clone yet (check repo_path)"
        fi
      else
        log "note: set --repo-path before the first run so a clone can be made."
      fi
    else
      log "autonomy disabled for role '$ROLE'"
    fi
    ;;

  status)
    codesync_python - "$SCRIPT_DIR/lib" "$CONFIG_DIR" "$PROJECT" <<'PY'
import sys, os, json
lib, cd, proj = sys.argv[1:4]
sys.path.insert(0, lib)
import state
data = state.load_autonomy(cd).get("projects", {}).get(proj, {}) or {}
print("  repo_path:", data.get("repo_path", "(unset)"))
print("  model:    ", data.get("model", "(unset — runner will pin a default)"))
roles = data.get("roles", {}) or {}
if not roles:
    print("  roles:     (none enabled)")
for r, rc in sorted(roles.items()):
    state_s = "ENABLED" if rc.get("enabled") else "off"
    print(f"    {r}: {state_s}  tools=[{rc.get('allowed_tools','')}]")
PY
    ;;
esac

printf '\n'
