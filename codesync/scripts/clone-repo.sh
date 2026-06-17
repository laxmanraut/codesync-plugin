#!/usr/bin/env bash
# clone-repo.sh — clone a project's code repo locally and record it as repo_path.
# Provider-agnostic (plain `git clone`, works for GitHub/Bitbucket/GitLab/etc).
# Uses the caller's own git credentials; never stores any. The clone dir MUST be
# OUTSIDE every synced project folder (so the codebase doesn't sync via Syncthing).
# Args: --project P --url URL [--dir DIR]   (DIR defaults to ~/codesync-code/P)
set -uo pipefail   # NOT -e: we handle git clone failure explicitly

CONFIG_DIR="$HOME/.config/codesync"
CFG_FILE="$CONFIG_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
LIB="$SCRIPT_DIR/lib"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT="" URL="" DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --url)     URL="$2";     shift 2 ;;
    --dir)     DIR="$2";     shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$URL" ] || err "--project and --url are required"
[ -n "${PY_BIN:-}" ] || err "no usable Python"
command -v git >/dev/null 2>&1 || err "git not found on PATH"

# Validate the URL shape (defence-in-depth; the server validates too).
codesync_python - "$LIB" "$URL" <<'PY' || err "repo url doesn't look like a git URL: passed value rejected"
import sys; sys.path.insert(0, sys.argv[1]); import state
sys.exit(0 if state.valid_repo_url(sys.argv[2]) and sys.argv[2] else 1)
PY

# Default clone dir, in native form on Windows so config/Python read it cleanly.
if [ -z "$DIR" ]; then
  DIR="$HOME/codesync-code/$PROJECT"
  if [ "$CODESYNC_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    DIR="$(cygpath -m "$DIR")"
  fi
fi

# The clone dir MUST be outside every synced project folder.
INSIDE=$(codesync_python - "$LIB" "$CFG_FILE" "$DIR" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); import state
cfg = state.load_config(sys.argv[2])
print("yes" if state.is_inside_synced(sys.argv[3], cfg) else "no")
PY
)
[ "$INSIDE" = "no" ] || err "clone dir must be OUTSIDE every synced project folder: $DIR"

# Clone (or reuse an existing clone). GIT_TERMINAL_PROMPT=0 → fail fast instead
# of hanging on a credential prompt in this non-interactive context.
if [ -d "$DIR/.git" ]; then
  printf '  reusing existing clone at %s\n' "$DIR"
elif [ -e "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then
  err "directory exists and is not a git clone: $DIR"
else
  mkdir -p "$(dirname "$DIR")" || err "could not create parent of $DIR"
  printf '  cloning %s -> %s ...\n' "$URL" "$DIR"
  GIT_TERMINAL_PROMPT=0 git clone "$URL" "$DIR" 2>&1 \
    || err "git clone failed — check the URL and that your git has access (no interactive prompt is available here)"
fi

# Record it as the project's repo_path (validates git-repo + outside-synced again).
OUT=$(codesync_python - "$LIB" "$CONFIG_DIR" "$CFG_FILE" "$PROJECT" "$DIR" <<'PY'
import sys
lib, cd, cfgf, proj, d = sys.argv[1:6]
sys.path.insert(0, lib); import state
cfg = state.load_config(cfgf)
ok, e = state.set_autonomy_repo(cd, proj, d, cfg)
print("OK" if ok else "ERR " + e)
PY
)
case "$OUT" in
  OK) printf 'CLONED\t%s\n' "$DIR" ;;
  *)  err "${OUT#ERR }" ;;
esac
