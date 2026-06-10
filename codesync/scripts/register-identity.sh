#!/usr/bin/env bash
# register-identity.sh — Capture this machine's identity for thread attribution.
# Reads `git config user.name` and offers a normalized form (lowercase, first
# token only — e.g. "Laxman Raut" → "laxman"). The slash command flow decides
# whether to ask the user to confirm/edit before saving.
#
# Args:
#   --suggest         Print a normalized suggestion + status without writing.
#                     Output: SUGGESTED=<value>, GIT_FOUND=yes|no
#   --set <name>      Save the given identity to ~/.config/codesync/config.json
#                     (top-level `identity` field). Validates kebab-case.
#                     Output: SAVED_IDENTITY=<value>
#
# Idempotent. Used by /install-codesync (registers on first run, prompts to
# update if missing on re-run) and by /codesync-thread-claim (errors out and
# tells the user to /install-codesync if identity is missing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"

CFG_FILE="$HOME/.config/codesync/config.json"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

MODE=""
VALUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --suggest) MODE="suggest"; shift ;;
    --set)     MODE="set"; [ $# -ge 2 ] || err "--set requires a value"; VALUE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$MODE" ] || err "Usage: register-identity.sh --suggest | --set <name>"

if [ "$MODE" = "suggest" ]; then
  # Try to read git config user.name; normalize to lowercase, first token only.
  GIT_NAME=""
  if command -v git >/dev/null 2>&1; then
    GIT_NAME=$(git config --global --get user.name 2>/dev/null || true)
    [ -z "$GIT_NAME" ] && GIT_NAME=$(git config --get user.name 2>/dev/null || true)
  fi
  if [ -n "$GIT_NAME" ]; then
    # Lowercase, take first word, strip non-alphanumeric (keep hyphens)
    SUGGEST=$(printf '%s' "$GIT_NAME" | awk '{print tolower($1)}' | tr -cd 'a-z0-9-')
    printf 'GIT_FOUND=yes\n'
    printf 'GIT_NAME=%s\n' "$GIT_NAME"
    printf 'SUGGESTED=%s\n' "$SUGGEST"
  else
    printf 'GIT_FOUND=no\n'
    printf 'GIT_NAME=\n'
    printf 'SUGGESTED=\n'
  fi
  exit 0
fi

# MODE = set
[ -n "$VALUE" ] || err "--set requires a non-empty value"

# Validate: lowercase alphanumeric + hyphens, no spaces
if ! printf '%s' "$VALUE" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
  err "Identity must be lowercase letters/digits with optional hyphens (got: '$VALUE')"
fi

[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."

$PY_BIN - "$CFG_FILE" "$VALUE" <<'PY'
import json, sys
cfg_path, identity = sys.argv[1], sys.argv[2]
with open(cfg_path) as f:
    cfg = json.load(f)
cfg["identity"] = identity
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"

printf 'SAVED_IDENTITY=%s\n' "$VALUE"
