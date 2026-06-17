#!/usr/bin/env bash
# rules-init.sh — scaffold per-project agent rules for the active project.
# Writes GUARDRAILS.md (the binding, human-authored rules) into the SYNCED
# project folder, so it is shared with the whole team automatically, and wires
# the project CLAUDE.md to @-import it so launched/terminal agents auto-load it.
# Autonomous agents get GUARDRAILS.md injected into their prompt by the runner.
#
# Modes:
#   (default | --init)   create GUARDRAILS.md (if absent) + wire CLAUDE.md; print paths
#   --show               print the current GUARDRAILS.md
#   --path               print the GUARDRAILS.md path
set -euo pipefail

CONFIG_DIR="$HOME/.config/codesync"
CFG_FILE="$CONFIG_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/load-env.sh"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '  %s\n' "$*"; }

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || err "No project active. Set CODESYNC_PROJECT first — rules are per project."
[ -f "$CFG_FILE" ] || err "Config not found at $CFG_FILE. Run /install-codesync first."
[ -n "${PY_BIN:-}" ] || err "No usable Python found."

MODE="init"
case "${1:-}" in
  --show) MODE="show" ;;
  --path) MODE="path" ;;
  --init|"") MODE="init" ;;
  *) MODE="init" ;;
esac

PROJ_PATH=$(codesync_python -c '
import json,sys
print((json.load(open(sys.argv[1])).get("projects",{}).get(sys.argv[2],{}) or {}).get("path",""))
' "$CFG_FILE" "$PROJECT")
[ -n "$PROJ_PATH" ] && [ -d "$PROJ_PATH" ] || err "Project '$PROJECT' is not on this machine."

GUARD="$PROJ_PATH/GUARDRAILS.md"
CLAUDEMD="$PROJ_PATH/CLAUDE.md"

case "$MODE" in
  path) printf '%s\n' "$GUARD"; exit 0 ;;
  show)
    [ -f "$GUARD" ] && cat "$GUARD" || err "No GUARDRAILS.md yet — run /codesync-rules to create it."
    exit 0 ;;
esac

printf '\nProject rules — %s\n─────────────────────────────\n' "$PROJECT"

# 1. GUARDRAILS.md — create a starter only if absent (never clobber edits).
if [ -f "$GUARD" ]; then
  log "GUARDRAILS.md already exists — leaving it untouched: $GUARD"
else
  cat > "$GUARD" <<EOF
# Project rules & guardrails — $PROJECT

These rules are BINDING for every agent working in this project — launched
terminals, the autopilot, and autonomous agents (the autonomy runner injects
this file into each agent's prompt). They are synced, so the whole team shares
the same rules. Edit freely; keep them short and concrete.

## Always
- Keep the test suite green before finishing a change.
- Match the existing code style and structure of the file you are editing.
- Explain non-obvious changes in your summary.

## Never
- Never edit secrets, credentials, or production configuration.
- Never run destructive or irreversible commands.
- Never touch files outside the task you were given.

## Ask / escalate first
- Anything touching auth, billing, data migrations, or deletes.
- Anything you are not confident about — leave a note instead of guessing.

> Note: the HARD limit on what an agent can do is its role's tool scope
> (allowed-tools). This file is the human-readable contract on top of that —
> if a rule must never be broken, also encode it as a tool restriction.
EOF
  log "created GUARDRAILS.md (edit it): $GUARD"
fi

# 2. CLAUDE.md — ensure it @-imports GUARDRAILS.md so in-project agents load it.
if [ -f "$CLAUDEMD" ]; then
  if grep -q "GUARDRAILS.md" "$CLAUDEMD"; then
    log "CLAUDE.md already references GUARDRAILS.md — leaving it untouched."
  else
    printf '\n## Project rules\n\nEvery agent working here must follow the rules in @GUARDRAILS.md.\n' >> "$CLAUDEMD"
    log "appended a GUARDRAILS.md reference to the existing CLAUDE.md."
  fi
else
  cat > "$CLAUDEMD" <<EOF
# $PROJECT

Every agent working in this project must follow the rules in @GUARDRAILS.md.

You are a codesync role — read \`_roles/<your-role>.md\` and stay within what it
owns. Project reference docs live in \`_docs/\`.
EOF
  log "created CLAUDE.md (imports GUARDRAILS.md): $CLAUDEMD"
fi

printf '\nEdit your rules:  %s\n' "$GUARD"
printf 'Launched + autopilot agents load them via CLAUDE.md; autonomous agents get them injected.\n'
printf 'They are in the synced folder, so your teammates get them automatically.\n\n'
