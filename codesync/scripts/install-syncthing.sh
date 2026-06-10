#!/usr/bin/env bash
# install-syncthing.sh — Machine-level CodeSync setup (v0.5.0+).
# - macOS:   installs Syncthing via Homebrew, runs it as a brew service.
# - Windows: installs Python (if missing — D13) and Syncthing via winget,
#            launches Syncthing detached in THIS session (OV5 — the startup
#            shortcut only fires on next login), and registers a Startup-
#            folder shortcut so it survives reboots.
# - Reads the Syncthing API key + Device ID and persists them to
#   ~/.config/codesync/config.json, alongside an (initially empty)
#   projects map. Project folders are created by create-project.sh.
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/platform.sh"

API="http://127.0.0.1:8384"
CFG_DIR="$HOME/.config/codesync"
CFG_FILE="$CFG_DIR/config.json"
CONFIG_XML="$(codesync_syncthing_config_dir)/config.xml"

log() { printf '  %s\n' "$*"; }
err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. Prerequisites + Syncthing install/start (per platform) ────────────────
command -v curl >/dev/null 2>&1 || err "curl required."

if [ "$CODESYNC_OS" = "windows" ]; then
  # Package manager: winget ships with Windows 10 1709+/11 via App Installer.
  command -v winget >/dev/null 2>&1 || err "winget (Windows Package Manager) not found. Install 'App Installer' from the Microsoft Store (https://aka.ms/getwinget), then re-run /install-codesync."

  # Python auto-install (D13): PY_BIN is empty when no working Python exists
  # (the Microsoft Store stub is filtered out by the platform layer).
  if [ -z "$PY_BIN" ]; then
    log "No working Python found — installing via winget (user scope, ~30s)..."
    winget install -e --id Python.Python.3.12 --scope user \
      --accept-package-agreements --accept-source-agreements >/dev/null \
      || err "winget could not install Python. Install it manually from https://python.org and re-run."
    # winget updates PATH for NEW shells only; locate the fresh install directly.
    for cand in "$(cygpath -u "$LOCALAPPDATA")/Programs/Python/Python312/python.exe" \
                "$(command -v python3 2>/dev/null || true)" \
                "$(command -v python 2>/dev/null || true)"; do
      [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c 'import sys' >/dev/null 2>&1 && PY_BIN="$cand" && break
    done
    [ -n "$PY_BIN" ] || err "Python installed but not yet on PATH. Close this terminal, open a new one, and re-run /install-codesync."
    log "Python ready: $PY_BIN"
  fi

  # Install Syncthing if missing
  if ! command -v syncthing >/dev/null 2>&1; then
    log "Installing syncthing via winget..."
    winget install -e --id Syncthing.Syncthing \
      --accept-package-agreements --accept-source-agreements >/dev/null \
      || err "winget could not install Syncthing. See https://syncthing.net/downloads/ for a manual install, then re-run."
    # Same PATH caveat: find the binary for THIS session.
    if ! command -v syncthing >/dev/null 2>&1; then
      SYNCTHING_EXE=$(find "$(cygpath -u "$LOCALAPPDATA")/Microsoft/WinGet" \
        "$(cygpath -u "$PROGRAMFILES")" \
        -maxdepth 4 -name syncthing.exe 2>/dev/null | head -1)
      [ -n "$SYNCTHING_EXE" ] || err "Syncthing installed but binary not found. Open a new terminal and re-run /install-codesync."
    fi
  else
    log "syncthing already installed"
  fi
  SYNCTHING_EXE="${SYNCTHING_EXE:-$(command -v syncthing)}"

  # Launch detached IN THIS SESSION if not already running (OV5). The Startup
  # shortcut below only takes effect at next login — without this, the rest
  # of the install (API wait) would hang forever on first run.
  if ! curl -s -o /dev/null "$API" 2>/dev/null && ! tasklist 2>/dev/null | grep -qi 'syncthing.exe'; then
    log "Starting syncthing (background, no browser)..."
    SYNCTHING_WIN=$(cygpath -w "$SYNCTHING_EXE")
    cmd //c start "codesync-syncthing" //b "$SYNCTHING_WIN" -no-browser -no-restart >/dev/null 2>&1 || true
    log "NOTE: if Windows Defender Firewall pops up, click 'Allow access'"
    log "      (private networks is enough) — Syncthing needs it to reach peers."
  else
    log "syncthing already running"
  fi

  # Startup-folder shortcut so Syncthing auto-starts on login (idempotent).
  STARTUP_DIR=$(cygpath -u "$APPDATA")/Microsoft/Windows/"Start Menu"/Programs/Startup
  if [ -d "$STARTUP_DIR" ] && [ ! -f "$STARTUP_DIR/codesync-syncthing.lnk" ]; then
    powershell.exe -NoProfile -NonInteractive -Command "
      \$ws = New-Object -ComObject WScript.Shell;
      \$lnk = \$ws.CreateShortcut(\"\$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\codesync-syncthing.lnk\");
      \$lnk.TargetPath = '$(cygpath -w "$SYNCTHING_EXE")';
      \$lnk.Arguments = '-no-browser -no-restart';
      \$lnk.WindowStyle = 7;
      \$lnk.Save()" >/dev/null 2>&1 \
      && log "Registered Syncthing in the Startup folder (auto-starts on login)" \
      || log "WARNING: could not create the Startup shortcut — Syncthing won't auto-start after reboot. You can add it manually (Win+R → shell:startup)."
  fi
else
  # macOS path (unchanged from v0.21)
  command -v brew >/dev/null 2>&1 || err "Homebrew required. Install from https://brew.sh and re-run."
  [ -n "$PY_BIN" ] || err "python3 required (ships with macOS)."

  if ! command -v syncthing >/dev/null 2>&1; then
    log "Installing syncthing via Homebrew..."
    brew install syncthing >/dev/null
  else
    log "syncthing already installed"
  fi

  if brew services list | awk '$1=="syncthing"{print $2}' | grep -qx started; then
    log "syncthing service already running"
  else
    log "Starting syncthing service..."
    brew services start syncthing >/dev/null
  fi
fi

# ── 2. Wait for config.xml (Syncthing creates it on first run) ───────────────
log "Waiting for Syncthing to initialise..."
for _ in $(seq 1 30); do
  [ -f "$CONFIG_XML" ] && break
  sleep 1
done
if [ ! -f "$CONFIG_XML" ]; then
  if [ "$CODESYNC_OS" = "windows" ]; then
    err "Syncthing config not found at $CONFIG_XML after 30s. Check that syncthing.exe is running (Task Manager), then re-run."
  else
    err "Syncthing config not found at $CONFIG_XML after 30s. Try: brew services restart syncthing"
  fi
fi

# ── 3. Extract API key ───────────────────────────────────────────────────────
API_KEY=$($PY_BIN - "$CONFIG_XML" <<'PY' || true
import sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse(sys.argv[1])
    gui = tree.getroot().find("gui")
    if gui is None: sys.exit("no <gui> element in config.xml")
    key = gui.findtext("apikey")
    if not key: sys.exit("no <apikey> element in config.xml")
    print(key)
except Exception as e:
    sys.exit(f"failed to parse config: {e}")
PY
)
[ -n "${API_KEY:-}" ] || err "Could not read API key from $CONFIG_XML"

# ── 4. Wait for REST API ─────────────────────────────────────────────────────
for _ in $(seq 1 30); do
  curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" >/dev/null 2>&1 \
  || err "Syncthing REST API at $API did not respond. Check the Syncthing process is running and try again."

# ── 5. Read Device ID ────────────────────────────────────────────────────────
DEVICE_ID=$(curl -sf -H "X-API-Key: $API_KEY" "$API/rest/system/status" \
  | $PY_BIN -c 'import sys, json; print(json.load(sys.stdin)["myID"])') \
  || err "Could not read Device ID from Syncthing"

# ── 6. Persist machine-level config — preserve any existing projects map ─────
mkdir -p "$CFG_DIR"
$PY_BIN - "$CFG_FILE" "$API_KEY" "$DEVICE_ID" <<'PY'
import json, os, sys
cfg_path, api_key, device_id = sys.argv[1:4]
cfg = {}
if os.path.exists(cfg_path):
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
    except Exception:
        cfg = {}
cfg["syncthing_api_key"] = api_key
cfg["device_id"]         = device_id
# Preserve existing projects map, or create empty
if not isinstance(cfg.get("projects"), dict):
    cfg["projects"] = {}
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
chmod 600 "$CFG_FILE"
log "Wrote $CFG_FILE"

# ── 7. Machine-parseable output ──────────────────────────────────────────────
printf '\n'
printf 'DEVICE_ID=%s\n' "$DEVICE_ID"
