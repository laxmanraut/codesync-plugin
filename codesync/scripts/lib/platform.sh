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

# UTF-8 mode for every Python the plugin spawns (PEP 540). Without this,
# native Windows Python defaults stdout AND open() to cp1252 — printing the
# ▴/→ glyphs or reading a thread body with umlauts raises UnicodeEncodeError
# and kills the script. One env var fixes the whole class everywhere.
export PYTHONUTF8=1

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

# Windows PATH-staleness fallback: a winget/python.org user install updates
# PATH in the REGISTRY, but already-running processes (Claude Code and every
# bash it spawns) keep their old PATH until restarted. Probe the standard
# per-user install location directly so the plugin works in the same session
# Python was installed in — and in hooks, which inherit the same stale PATH.
if [ -z "$PY_BIN" ] && [ "$CODESYNC_OS" = "windows" ] \
   && [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
  for __codesync_cand in "$(cygpath -u "$LOCALAPPDATA")"/Programs/Python/Python3*/python.exe; do
    if [ -x "$__codesync_cand" ] && "$__codesync_cand" -c 'import sys' >/dev/null 2>&1; then
      PY_BIN="$__codesync_cand"
      break
    fi
  done
  unset __codesync_cand
fi
export PY_BIN

# ── Bash to hand to native code (the dashboard server) ───────────────────────
# The Python server shells out to .sh scripts. On Windows, the SYSTEM PATH's
# "bash" is C:\Windows\System32\bash.exe — the WSL launcher, which has no distro
# and exits 1 with a UTF-16 error — so a native process that PATH-resolves "bash"
# never reaches Git Bash. Resolve THIS (Git) bash here and export it so the
# server uses it explicitly. Deliberate exception to the "env carries names, not
# paths" rule: Python needs the path, so we hand it over in NATIVE Windows form
# (forward-slash via cygpath -m) that Python/CreateProcess uses directly.
if [ -z "${CODESYNC_BASH:-}" ]; then
  CODESYNC_BASH="$(command -v bash 2>/dev/null || echo bash)"
  if [ "$CODESYNC_OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
    CODESYNC_BASH="$(cygpath -m "$CODESYNC_BASH" 2>/dev/null || echo "$CODESYNC_BASH")"
  fi
fi
export CODESYNC_BASH

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

# codesync_ps_lit STR — escape STR for safe embedding inside a PowerShell
# SINGLE-quoted literal: double every single quote ('' is a literal ' in
# '...'). Without this a peer-controlled thread title (now passed to the toast
# by the 24/7 watcher) could break out of the quotes into PowerShell — RCE on
# Windows. macOS escapes its own (double-quoted osascript) context separately.
codesync_ps_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

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
      # Escape both fields for the PowerShell single-quoted literals — the title
      # can be peer-controlled (thread title via the watcher), so an unescaped
      # quote would be PowerShell injection.
      __cn_title_ps=$(codesync_ps_lit "$__cn_title")
      __cn_body_ps=$(codesync_ps_lit "$__cn_body")
      powershell.exe -NoProfile -NonInteractive -Command "
        try {
          if (Get-Module -ListAvailable -Name BurntToast) {
            Import-Module BurntToast;
            New-BurntToastNotification -Text '$__cn_title_ps', '$__cn_body_ps' | Out-Null
          } else {
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;
            \$tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
            \$texts = \$tpl.GetElementsByTagName('text');
            \$texts.Item(0).AppendChild(\$tpl.CreateTextNode('$__cn_title_ps')) | Out-Null;
            \$texts.Item(1).AppendChild(\$tpl.CreateTextNode('$__cn_body_ps')) | Out-Null;
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

# ── Open a URL in the default browser ────────────────────────────────────────
# codesync_open_url URL — fire-and-forget, never blocks, never errors.
# macOS: open(1). Windows: PowerShell Start-Process (NOT `cmd start`, which
# mis-parses an unquoted first arg as the program — the v0.22.4 dialog bug;
# Start-Process takes the URL as a single -FilePath value with no such trap).
# Test hook: when CODESYNC_TEST_OPEN_LOG is set, append the URL there instead
# of launching, so the suite can assert what would have opened.
codesync_open_url() {
  __cou_url="$1"
  if [ -n "${CODESYNC_TEST_OPEN_LOG:-}" ]; then
    printf '%s\n' "$__cou_url" >> "$CODESYNC_TEST_OPEN_LOG" 2>/dev/null || true
    return 0
  fi
  case "$CODESYNC_OS" in
    macos)
      open "$__cou_url" >/dev/null 2>&1 &
      ;;
    windows)
      powershell.exe -NoProfile -NonInteractive -Command \
        "Start-Process '$__cou_url'" >/dev/null 2>&1 &
      ;;
    *)
      command -v xdg-open >/dev/null 2>&1 && xdg-open "$__cou_url" >/dev/null 2>&1 &
      ;;
  esac
  return 0
}

# ── Launch an agent terminal (role + project) ────────────────────────────────
# codesync_launch_terminal PROJECT ROLE PROJECT_PATH
# Open a new terminal running `claude` with CODESYNC_PROJECT/ROLE set and cwd in
# the project. The launched command is FIXED (`claude`); the project + role come
# from the caller's allowlist, never from a request body.
#
# Security (launch-agents eng-review 1A + T3): the project PATH and env VALUES
# are never interpolated into the osascript / terminal-spawn string. We write a
# chmod-600 temp launcher whose values are %q-quoted and whose FIRST line deletes
# the file, then exec claude. So the spawn API only ever sees our own mktemp
# path — a path with a space, quote, or $(...) cannot reach a shell/AppleScript
# parser. The self-delete-first line means no secret-bearing temp file lingers
# and there is no disposal race.
#
# Prints exactly one line:
#   LAUNCHED                 a terminal was spawned
#   COPY<TAB><command>       no auto-launch path here; caller shows a copy button
# Test hook: with CODESYNC_TEST_LAUNCH_LOG set, write the would-run launcher
# (macos/windows) or the COPY line (other) to that file and return WITHOUT
# spawning. The visible GUI window is the only part that can't be unit-tested;
# the constructed launcher is asserted via this hook on macOS AND Windows.
codesync_launch_terminal() {
  __clt_project="$1"; __clt_role="$2"; __clt_path="$3"

  # Launcher: self-delete (the temp file never lingers); register a live-session
  # file ('project<TAB>role<TAB>pid<TAB>started' — all safe values, parsed by
  # state.gather_sessions); cd (path %q-quoted — a space/quote/$() in the path
  # can't reach a shell) + export the role/project; run claude (NOT exec, so the
  # cleanup line runs when the session ends); remove the session file. role and
  # project are regex-validated names, safe inside the single-quoted slots. The
  # launcher pid ($$) stays alive for the whole session, so it doubles as the
  # liveness pid. macOS osascript only ever sees our mktemp path, never these.
  __clt_pathq=$(printf '%q' "$__clt_path")
  # __pid is the liveness pid the dashboard checks. In Git Bash, "$$" is the
  # MSYS pid, but the native-Python server checks liveness / taskkills via the
  # WINDOWS pid — so use /proc/$$/winpid when present (Git Bash exposes it),
  # falling back to $$ on macOS/Linux. Filename and pid field use the same value.
  __clt_script=$(cat <<LAUNCHER
#!/usr/bin/env bash
rm -f -- "\$0"
__sd="\$HOME/.config/codesync/sessions"; mkdir -p "\$__sd" 2>/dev/null
__pid=\$\$; [ -r "/proc/\$\$/winpid" ] && __pid=\$(cat "/proc/\$\$/winpid" 2>/dev/null || echo \$\$)
__sf="\$__sd/\$__pid.session"
printf '%s\t%s\t%s\t%s\n' '$__clt_project' '$__clt_role' "\$__pid" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "\$__sf" 2>/dev/null
cd $__clt_pathq || exit 1
export CODESYNC_PROJECT='$__clt_project'
export CODESYNC_ROLE='$__clt_role'
claude
rm -f "\$__sf" 2>/dev/null
LAUNCHER
)
  # Universal fallback command (shell-quoted) for when we can't auto-launch.
  __clt_copy=$(printf 'cd %q && export CODESYNC_PROJECT=%q CODESYNC_ROLE=%q && claude' \
               "$__clt_path" "$__clt_project" "$__clt_role")

  if [ -n "${CODESYNC_TEST_LAUNCH_LOG:-}" ]; then
    # Dump the would-run launcher to the log (for inspection) AND print the same
    # LAUNCHED / COPY contract to stdout the real path would, so both the unit
    # test (reads the log) and the endpoint test (reads stdout) are exercised.
    case "$CODESYNC_OS" in
      macos|windows)
        printf '%s' "$__clt_script" > "$CODESYNC_TEST_LAUNCH_LOG" 2>/dev/null || true
        printf 'LAUNCHED\n' ;;
      *)
        printf 'COPY\t%s\n' "$__clt_copy" > "$CODESYNC_TEST_LAUNCH_LOG" 2>/dev/null || true
        printf 'COPY\t%s\n' "$__clt_copy" ;;
    esac
    return 0
  fi

  case "$CODESYNC_OS" in
    macos)
      __clt_tmp=$(mktemp "${TMPDIR:-/tmp}/codesync-launch.XXXXXX") || { printf 'COPY\t%s\n' "$__clt_copy"; return 0; }
      printf '%s' "$__clt_script" > "$__clt_tmp"
      chmod 600 "$__clt_tmp"
      # osascript only ever sees our mktemp path (safe chars), never the project path.
      osascript -e "tell application \"Terminal\" to do script \"bash '$__clt_tmp'\"" \
                -e 'tell application "Terminal" to activate' >/dev/null 2>&1 &
      printf 'LAUNCHED\n'
      ;;
    windows)
      __clt_tmp=$(mktemp "${TMPDIR:-/tmp}/codesync-launch.XXXXXX") || { printf 'COPY\t%s\n' "$__clt_copy"; return 0; }
      printf '%s' "$__clt_script" > "$__clt_tmp"
      # No chmod on Windows; the per-user %TEMP% ACL protects the file. Run the
      # launcher via the current bash.exe so the env exports take effect; prefer
      # Windows Terminal, else `start` (title arg first so it doesn't eat the program).
      __clt_bash_win="$(cygpath -w "$(command -v bash)" 2>/dev/null || echo bash.exe)"
      __clt_tmp_win="$(cygpath -m "$__clt_tmp" 2>/dev/null || echo "$__clt_tmp")"
      if command -v wt >/dev/null 2>&1; then
        wt "$__clt_bash_win" "$__clt_tmp_win" >/dev/null 2>&1 &
      else
        cmd //c start "codesync" "$__clt_bash_win" "$__clt_tmp_win" >/dev/null 2>&1 &
      fi
      printf 'LAUNCHED\n'
      ;;
    *)
      printf 'COPY\t%s\n' "$__clt_copy"
      ;;
  esac
  return 0
}

# ── Scheduled jobs (launchd / Task Scheduler) ────────────────────────────────
# codesync_install_scheduled_job / codesync_remove_scheduled_job register a
# recurring background job that runs a codesync .sh every N seconds, 24/7,
# surviving logout→login (launchd RunAtLoad / schtasks). ONE registration
# path, tested once (test-watch-setup.sh) and reused — by the inbox watcher
# (watch-setup.sh) today, and by the autonomy runner once Layer 3 ships (CQ2).
#
# Install args (positional; documented because there are several):
#   $1 label      launchd Label             e.g. com.codesync.watch.<project>
#   $2 task       schtasks task name        e.g. codesync-watch-<project>
#   $3 script     absolute path to the .sh  e.g. .../watch-inbox.sh
#   $4 interval   poll seconds (>=1; Windows floors to whole minutes, min 1)
#   $5 log_file   launchd StandardErrorPath (macOS; Windows ignores it)
#   $6 launcher   the .cmd path (Windows; macOS ignores it)
#   $7 env_pairs  newline-separated KEY=VALUE lines baked into the job's env.
#                 VALUES MUST BE NAMES, never paths (platform.sh env rule: env
#                 vars are not MSYS path-translated; pass project/role names).
# Remove args: $1 label  $2 task  $3 launcher.
#
# Test hook: with CODESYNC_TEST_SCHED_LOG set, the launchctl/schtasks call is
# replaced by an append to that file in the same MACOS_LOAD / WIN_SCHTASKS /
# MACOS_UNLOAD / WIN_DELETE line format the suite asserts on — artifact
# generation is hermetic; live OS registration is validated manually.
_codesync_sched_log() {
  [ -n "${CODESYNC_TEST_SCHED_LOG:-}" ] || return 1
  printf '%s\n' "$*" >> "$CODESYNC_TEST_SCHED_LOG" 2>/dev/null || true
  return 0
}

codesync_install_scheduled_job() {
  __sj_label="$1"; __sj_task="$2"; __sj_script="$3"; __sj_interval="$4"
  __sj_log="$5"; __sj_launcher="$6"; __sj_env="$7"
  case "$CODESYNC_OS" in
    macos)
      __sj_plist="$HOME/Library/LaunchAgents/$__sj_label.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      # Build the EnvironmentVariables dict from the KEY=VALUE lines.
      __sj_envxml=""
      while IFS='=' read -r __sj_k __sj_v; do
        [ -n "$__sj_k" ] || continue
        __sj_envxml="${__sj_envxml}    <key>${__sj_k}</key>
    <string>${__sj_v}</string>
"
      done <<ENVEOF
$__sj_env
ENVEOF
      cat > "$__sj_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$__sj_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$__sj_script</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
$__sj_envxml  </dict>
  <key>StartInterval</key>
  <integer>$__sj_interval</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>$__sj_log</string>
</dict>
</plist>
PLIST_EOF
      if _codesync_sched_log "MACOS_LOAD label=$__sj_label interval=$__sj_interval plist=$__sj_plist"; then return 0; fi
      launchctl unload "$__sj_plist" 2>/dev/null || true
      launchctl load "$__sj_plist"
      ;;
    windows)
      # The .cmd carries the env (schtasks has no env dict) and invokes Git Bash
      # to run the script. Written in native Windows form so cmd.exe/schtasks
      # understand it; env VALUES are names (no MSYS path-translation needed),
      # the SCRIPT path is forward-slashed so bash accepts it unambiguously.
      __sj_bash_win="$(cygpath -w "$(command -v bash)" 2>/dev/null || echo bash.exe)"
      __sj_script_fwd="$(cygpath -m "$__sj_script" 2>/dev/null || echo "$__sj_script")"
      {
        printf '@echo off\r\n'
        while IFS='=' read -r __sj_k __sj_v; do
          [ -n "$__sj_k" ] || continue
          printf 'set %s=%s\r\n' "$__sj_k" "$__sj_v"
        done <<ENVEOF
$__sj_env
ENVEOF
        printf '"%s" "%s"\r\n' "$__sj_bash_win" "$__sj_script_fwd"
      } > "$__sj_launcher"
      # Hidden-window wrapper so the poll never flashes a console; /IT keeps the
      # task interactive (logged-on) so toasts display. /sc MINUTE /mo in min.
      __sj_launcher_win="$(cygpath -w "$__sj_launcher" 2>/dev/null || echo "$__sj_launcher")"
      __sj_every=$(( __sj_interval / 60 )); [ "$__sj_every" -ge 1 ] || __sj_every=1
      __sj_tr="powershell -WindowStyle Hidden -NonInteractive -Command \"Start-Process -WindowStyle Hidden -FilePath '$__sj_launcher_win'\""
      if _codesync_sched_log "WIN_SCHTASKS task=$__sj_task every_min=$__sj_every launcher=$__sj_launcher_win"; then
        _codesync_sched_log "WIN_LAUNCHER $(tr -d '\r' < "$__sj_launcher" | tr '\n' '|')"
        return 0
      fi
      schtasks //Create //TN "$__sj_task" //SC MINUTE //MO "$__sj_every" //IT //F \
        //TR "$__sj_tr" >/dev/null
      ;;
    *)
      return 2
      ;;
  esac
}

codesync_remove_scheduled_job() {
  __sj_label="$1"; __sj_task="$2"; __sj_launcher="$3"
  case "$CODESYNC_OS" in
    macos)
      __sj_plist="$HOME/Library/LaunchAgents/$__sj_label.plist"
      if _codesync_sched_log "MACOS_UNLOAD label=$__sj_label plist=$__sj_plist"; then rm -f "$__sj_plist"; return 0; fi
      [ -f "$__sj_plist" ] && launchctl unload "$__sj_plist" 2>/dev/null || true
      rm -f "$__sj_plist"
      ;;
    windows)
      if _codesync_sched_log "WIN_DELETE task=$__sj_task"; then rm -f "$__sj_launcher"; return 0; fi
      schtasks //Delete //TN "$__sj_task" //F >/dev/null 2>&1 || true
      rm -f "$__sj_launcher"
      ;;
    *)
      return 2
      ;;
  esac
}

fi # CODESYNC_PLATFORM_LOADED
