#!/usr/bin/env bash
# statusline-wrap.sh — Statusline wrapper that runs the previously-configured
# statusline command AND codesync's status-line.sh, joining them with ' · '.
#
# Claude Code passes session JSON on stdin; we tee it to the prior command
# so existing statuslines (netmeter, etc.) keep working unchanged.

PRIOR_FILE="$HOME/.config/codesync/statusline-prior.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read stdin once (status line input from Claude Code)
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

LEFT=""
if [ -f "$PRIOR_FILE" ]; then
  PRIOR_CMD=$(cat "$PRIOR_FILE")
  if [ -n "$PRIOR_CMD" ]; then
    LEFT=$(printf '%s' "$INPUT" | bash -c "$PRIOR_CMD" 2>/dev/null || true)
  fi
fi

RIGHT=$(bash "$SCRIPT_DIR/status-line.sh" 2>/dev/null || true)

# Trim trailing newlines to keep status line single-row
LEFT=$(printf '%s' "$LEFT" | tr -d '\n')
RIGHT=$(printf '%s' "$RIGHT" | tr -d '\n')

if [ -n "$LEFT" ] && [ -n "$RIGHT" ]; then
  printf '%s · %s' "$LEFT" "$RIGHT"
elif [ -n "$LEFT" ]; then
  printf '%s' "$LEFT"
elif [ -n "$RIGHT" ]; then
  printf '%s' "$RIGHT"
fi
