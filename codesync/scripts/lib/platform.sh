# platform.sh — OS detection + platform-specific primitives for codesync.
#
# Source this (idempotent). Provides:
#   CODESYNC_OS                       "macos" | "windows" | "unknown"
#   PY_BIN                            resolved Python interpreter (may be "py -3")
#   codesync_python ...               run Python portably (handles multi-word PY_BIN)
#   codesync_syncthing_config_dir     echoes the Syncthing config directory
#   codesync_notify TITLE BODY        fire a native notification (background, silent fail)
#   codesync_mtime FILE               file mtime as epoch seconds (BSD/GNU stat portable)
#
# Path-translation notes (the MSYS↔native audit lives here, OV1):
#   - Claude Code's Bash tool on Windows runs under Git Bash (MSYS). When bash
#     execs a NATIVE Windows binary (python.exe, curl.exe, powershell.exe), the
#     MSYS runtime heuristically converts POSIX-looking ARGV entries
#     (/c/Users/x -> C:\Users\x). It NEVER converts environment variables.
#   - Therefore the codebase rule, enforced by review: paths cross the
#     bash->python boundary ONLY as argv or stdin — never via env vars.
#     (CODESYNC_PROJECT / CODESYNC_ROLE are names, not paths — safe as env.)
#   - Inside Python, os.path.expanduser("~") resolves natively
#     (C:\Users\x on Windows) which lands in the same directory Git Bash
#     calls $HOME (/c/Users/x), because Git Bash maps HOME to USERPROFILE.
#   - Args that contain "://" (URLs) are NOT converted by the heuristic
#     (no leading slash), so REST calls to http://127.0.0.1:8384 are safe.
#   - Windows-native paths from env vars like $LOCALAPPDATA arrive in
#     Windows form (C:\...); convert with cygpath before use in bash.

# Guard against double-sourcing
if [ -z "${CODESYNC_PLATFORM_LOADED:-}" ]; then
CODESYNC_PLATFORM_LOADED=1

case "$(uname -s 2>/dev/null)" in
  Darwin)                 CODESYNC_OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*)   CODESYNC_OS="windows" ;;
  *)                      CODESYNC_OS="unknown" ;;
esac
export CODESYNC_OS

# ── Python resolution ────────────────────────────────────────────────────────
# Order: python3, python, py -3. Each candidate must actually RUN code —
# `command -v python` succeeding is NOT enough on Windows, where a Microsoft
# Store stub (App Execution Alias) sits on PATH and opens the Store instead
# of running anything (OV2). `-c "import sys"` filters the stub: it exits
# non-zero without executing.
__codesync_py_works() {
  # shellcheck disable=SC2086
  $1 -c 'import sys' >/dev/null 2>&1
}

if [ -z "${PY_BIN:-}" ]; then
  if __codesync_py_works "python3"; then
    PY_BIN="python3"
  elif __codesync_py_works "python"; then
    PY_BIN="python"
  elif __codesync_py_works "py -3"; then
    PY_BIN="py -3"
  else
    PY_BIN=""
  fi
fi
export PY_BIN

# Portable Python invocation — PY_BIN may be two words ("py -3"), so callers
# use this function instead of "$PY_BIN" directly when they want safety.
# (Scripts that interpolate "$PY_BIN" unquoted also work for the two-word
# case under word-splitting, but the function is the explicit, clean path.)
codesync_python() {
  [ -n "$PY_BIN" ] || { printf 'ERROR: no usable Python found (tried python3, python, py -3). On Windows: winget install -e --id Python.Python.3.12\n' >&2; return 127; }
  # shellcheck disable=SC2086
  $PY_BIN "$@"
}

# ── Syncthing config directory ───────────────────────────────────────────────
codesync_syncthing_config_dir() {
  case "$CODESYNC_OS" in
    macos)
      printf '%s\n' "$HOME/Library/Application Support/Syncthing"
      ;;
    windows)
      # $LOCALAPPDATA arrives Windows-form (C:\Users\x\AppData\Local);
      # cygpath converts to the POSIX form bash file tests understand.
      if command -v cygpath >/dev/null 2>&1 && [ -n "${LOCALAPPDATA:-}" ]; then
        printf '%s/Syncthing\n' "$(cygpath -u "$LOCALAPPDATA")"
      else
        printf '%s/AppData/Local/Syncthing\n' "$HOME"
      fi
      ;;
    *)
      printf '%s/.config/syncthing\n' "$HOME"  # XDG-ish fallback (future Linux)
      ;;
  esac
}

# ── Notifications ────────────────────────────────────────────────────────────
# codesync_notify TITLE BODY — fire-and-forget, never blocks, never errors.
# Test hook: when CODESYNC_TEST_NOTIFY_LOG is set, append "TITLE|BODY" to that
# file instead of firing a real notification (lets the suite count toasts).
codesync_notify() {
  __cn_title="$1"; __cn_body="$2"
  if [ -n "${CODESYNC_TEST_NOTIFY_LOG:-}" ]; then
    printf '%s|%s\n' "$__cn_title" "$__cn_body" >> "$CODESYNC_TEST_NOTIFY_LOG" 2>/dev/null || true
    return 0
  fi
  case "$CODESYNC_OS" in
    macos)
      __cn_body_esc=$(printf '%s' "$__cn_body" | sed 's/\\/\\\\/g; s/"/\\"/g')
      __cn_title_esc=$(printf '%s' "$__cn_title" | sed 's/\\/\\\\/g; s/"/\\"/g')
      osascript -e "display notification \"$__cn_body_esc\" with title \"$__cn_title_esc\" sound name \"Glass\"" >/dev/null 2>&1 &
      ;;
    windows)
      # Zero-dependency WinRT toast via powershell. AppId borrowed from
      # Windows PowerShell (always registered). If the WinRT path fails on
      # this machine (Focus Assist, policy), the design's sanctioned fallback
      # is BurntToast — installed during the setup hour, used automatically
      # here when present. The M1 visibility spike validates this live.
      powershell.exe -NoProfile -NonInteractive -Command "
        try {
          if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast;
            New-BurntToastNotification -Text '$__cn_title', '$__cn_body' | Out-Null
          } else {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;
            \$tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
            \$texts = \$tpl.GetElementsByTagName('text');
            \$texts.Item(0).AppendChild(\$tpl.CreateTextNode('$__cn_title')) | Out-Null;
            \$texts.Item(1).AppendChild(\$tpl.CreateTextNode('$__cn_body')) | Out-Null;
            \$toast = [Windows.UI.Notifications.ToastNotification]::new(\$tpl);
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe').Show(\$toast)
          }
        } catch {}" >/dev/null 2>&1 &
      ;;
  esac
  return 0
}

# ── Portable mtime ───────────────────────────────────────────────────────────
# BSD stat (macOS) uses -f FORMAT; GNU stat (Git Bash / Linux) uses -c FORMAT.
# CANNOT chain them with || : on GNU, `stat -f %m FILE` is "filesystem status"
# mode — it SUCCEEDS and prints the mount point, so the fallback never runs
# and callers get "/" instead of an epoch. Probe the dialect once instead.
if stat -c %Y / >/dev/null 2>&1; then
  codesync_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
else
  codesync_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
fi

fi # CODESYNC_PLATFORM_LOADED
