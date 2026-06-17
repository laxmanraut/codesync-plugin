#!/usr/bin/env bash
# generate-doc.sh — draft a project doc (CLAUDE.md / GUARDRAILS.md) by reading the
# project's CLONED code with a headless, READ-ONLY claude run. Prints ONLY the
# draft markdown to stdout (progress/errors → stderr). Writes NOTHING: the human
# reviews + saves it via the dashboard editor (that Save is the approval gate).
# Args: --project P --target CLAUDE.md|GUARDRAILS.md
set -uo pipefail

CONFIG_DIR="$HOME/.config/codesync"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# launchd/headless gives a minimal PATH; extend before platform.sh (PY_BIN probes PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local:$PATH"
. "$SCRIPT_DIR/lib/platform.sh"
LIB="$SCRIPT_DIR/lib"
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT="" TARGET="CLAUDE.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --target)  TARGET="$2";  shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT" ] || err "--project required"
case "$TARGET" in CLAUDE.md|GUARDRAILS.md) ;; *) err "unsupported target: $TARGET" ;; esac
[ -n "${PY_BIN:-}" ] || err "no usable Python"

_field() { codesync_python -c '
import json,sys; sys.path.insert(0,sys.argv[1]); import state
print((state.load_autonomy(sys.argv[2]).get("projects",{}).get(sys.argv[3],{}) or {}).get(sys.argv[4],""))' \
  "$LIB" "$CONFIG_DIR" "$PROJECT" "$1"; }

RP="$(_field repo_path)"
[ -n "$RP" ] && [ -d "$RP" ] || err "no cloned code for '$PROJECT' — clone the repo first"
MODEL="$(_field model)"; [ -n "$MODEL" ] || MODEL="claude-sonnet-4-6"
CLAUDE_BIN="${CODESYNC_AUTONOMY_CLAUDE_BIN:-}"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"

if [ "$TARGET" = "GUARDRAILS.md" ]; then
  PROMPT="Read this codebase and draft a concise GUARDRAILS.md of rules for AI agents working here: sections ## Always / ## Never / ## Ask first, grounded in what you actually see (build/test commands, sensitive areas, conventions). Output ONLY the markdown, no preamble and no surrounding code fences."
else
  PROMPT="Read this codebase and write a concise CLAUDE.md: a short project overview, the main structure, how to build and run the tests, and the key conventions an AI agent should follow. Keep it tight and concrete. Output ONLY the markdown content, no preamble and no surrounding code fences."
fi

# Read-only tools; pinned model; scrubbed CLAUDE_CODE_* env (spike lessons).
OUT=$(cd "$RP" && env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH -u CLAUDECODE \
        -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_EFFORT -u AI_AGENT \
        "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --allowedTools "Read,Glob,Grep" \
        --output-format json 2>/dev/null)
DRAFT=$(printf '%s' "$OUT" | codesync_python -c '
import json,sys
try: print((json.loads(sys.stdin.read()).get("result","") or "").strip())
except Exception: print("")')
[ -n "$DRAFT" ] || err "generation produced no content (the claude run may have failed)"
printf '%s\n' "$DRAFT"
