# tests/lib.sh — shared helpers for the codesync test suite.
#
# Every test is HERMETIC: t_setup creates a throwaway HOME (so scripts read
# and write ~/.config/codesync inside the sandbox, never the real machine)
# plus a fake synced project directory, and registers both in a minimal
# config.json. Notifications are captured via CODESYNC_TEST_NOTIFY_LOG
# instead of hitting osascript/powershell.
#
# Scripts under test are resolved from CODESYNC_SCRIPTS_DIR, defaulting to
# the repo layout (<repo>/codesync/scripts). Override locally to point at a
# development tree.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPTS="${CODESYNC_SCRIPTS_DIR:-$REPO_ROOT/codesync/scripts}"

[ -d "$SCRIPTS" ] || { echo "FATAL: scripts dir not found: $SCRIPTS" >&2; exit 2; }

T_PASS=0
T_FAIL=0
T_NAME="${0##*/}"

t_setup() {
  T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codesync-test.XXXXXX")"
  export HOME="$T_TMP/home"
  export CODESYNC_TEST_NOTIFY_LOG="$T_TMP/notify.log"
  export CODESYNC_PROJECT="testproj"
  export CODESYNC_ROLE="qa"
  PROJ="$T_TMP/proj"
  mkdir -p "$HOME/.config/codesync" "$PROJ/_inbox/qa" "$PROJ/_inbox/backend" "$PROJ/_archive/qa" "$PROJ/_roles" "$PROJ/_docs"
  cat > "$HOME/.config/codesync/config.json" <<EOF
{
  "identity": "tester",
  "projects": {
    "testproj": {
      "path": "$PROJ",
      "folder_id": "codesync-testproj",
      "roles": ["qa"]
    }
  }
}
EOF
  chmod 600 "$HOME/.config/codesync/config.json"
}

t_teardown() {
  [ -n "${T_TMP:-}" ] && rm -rf "$T_TMP"
}

# t_thread <role> <slug> [title] — create a minimal thread file in the sandbox inbox
t_thread() {
  local role="$1" slug="$2" title="${3:-Test thread}"
  cat > "$PROJ/_inbox/$role/$slug.md" <<EOF
---
codesync:
  title: $title
  from: backend
  from-identity: tester
  status: open
  created: 2026-06-10
---
# $title

Body line for $slug.
EOF
}

t_pass() { T_PASS=$((T_PASS + 1)); printf '  ok    %s\n' "$1"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

# t_assert <description> <command...>  — pass if command exits 0
t_assert() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then t_pass "$desc"; else t_fail "$desc"; fi
}

# t_refute <description> <command...>  — pass if command exits non-zero
t_refute() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then t_fail "$desc (expected failure, got success)"; else t_pass "$desc"; fi
}

# t_eq <description> <expected> <actual>
t_eq() {
  if [ "$2" = "$3" ]; then t_pass "$1"; else t_fail "$1 (expected '$2', got '$3')"; fi
}

# t_contains <description> <needle> <haystack>
t_contains() {
  case "$3" in
    *"$2"*) t_pass "$1" ;;
    *) t_fail "$1 (no '$2' in output)" ;;
  esac
}

t_done() {
  t_teardown
  printf '%s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
