#!/usr/bin/env bash
# launch-agent.sh — server entrypoint for the dashboard's launch-agent endpoint.
#
# The dashboard server (dashboard-server.py) validates the allowlist FIRST —
# project exists in config, its path is on this machine, the role is registered —
# then calls this with the resolved values. Here we only launch; we do not
# re-derive anything from a request. Sources the platform layer and delegates to
# codesync_launch_terminal, which prints LAUNCHED or COPY<TAB><command>.
#
# Args (all required): --project <name> --role <role> --path <project-path>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"

PROJECT="" ROLE="" CSPATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --role)    ROLE="$2";    shift 2 ;;
    --path)    CSPATH="$2";  shift 2 ;;
    *) shift ;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$ROLE" ] && [ -n "$CSPATH" ] || {
  echo "ERROR: --project, --role and --path are all required" >&2; exit 2; }

codesync_launch_terminal "$PROJECT" "$ROLE" "$CSPATH"
