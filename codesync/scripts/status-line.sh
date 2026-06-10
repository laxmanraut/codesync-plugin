#!/usr/bin/env bash
# status-line.sh — Output the codesync segment for Claude Code's status line.
#
# Claude Code's harness re-invokes this command every few seconds while a
# session is open (the script does not self-schedule). Budget: <100ms.
#
# v0.22.0 design (M1, eng-review 6A + OV7 + OV12):
#   1. PURE-BASH mtime fast path — if no inbox file is newer than the last
#      full scan, print the cached segment and exit WITHOUT spawning Python.
#      Protects the latency budget on Windows, where process spawn is slow.
#   2. Full scan (Python) — count unread (vs the Stop-hook baseline, as
#      before) AND determine never-before-seen threads via the shared
#      first-seen log (~/.config/codesync/seen-<project>.log).
#   3. Notification fires ONLY for never-seen threads; the seen-log is the
#      cross-session dedup: any number of concurrent Claude sessions share
#      it, so one arrival = one notification total (OV12), and every entry
#      doubles as wedge instrumentation — time-to-notice is measured as
#      file mtime → seen-log timestamp (OV7).
#
# Outputs:
#   codesync ▴ N new       when N >= 1 unread-since-last-turn items
#   (nothing)              when no project active or N == 0
# Silent on every error path so it never breaks the user's status line.

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CFG_FILE" ] || exit 0

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"
[ -n "${PY_BIN:-}" ] || exit 0

[ -n "${CODESYNC_PROJECT:-}" ] || exit 0

STATE_DIR="$HOME/.config/codesync"
SCAN_MARKER="$STATE_DIR/.statusline-scan-$CODESYNC_PROJECT"
CACHE_FILE="$STATE_DIR/.statusline-cache-$CODESYNC_PROJECT"
SEEN_LOG="$STATE_DIR/seen-$CODESYNC_PROJECT.log"
PROJ_PTR="$STATE_DIR/.statusline-path-$CODESYNC_PROJECT"

# ── 1. Pure-bash mtime fast path ─────────────────────────────────────────────
if [ -f "$PROJ_PTR" ] && [ -f "$SCAN_MARKER" ]; then
  PROJ_PATH=$(cat "$PROJ_PTR" 2>/dev/null)
  if [ -n "$PROJ_PATH" ] && [ -d "$PROJ_PATH/_inbox" ]; then
    MARKER_M=$(codesync_mtime "$SCAN_MARKER")
    NEWEST=0
    for d in "$PROJ_PATH/_inbox"/*/; do
      [ -d "$d" ] || continue
      M=$(codesync_mtime "$d")
      [ "$M" -gt "$NEWEST" ] 2>/dev/null && NEWEST=$M
      for f in "$d"*.md; do
        [ -f "$f" ] || continue
        M=$(codesync_mtime "$f")
        [ "$M" -gt "$NEWEST" ] 2>/dev/null && NEWEST=$M
      done
    done
    # Strictly-less-than: with 1-second mtime granularity a file written in
    # the same second as the marker would be skipped by -le. Equal → rescan.
    if [ "$NEWEST" -lt "$MARKER_M" ] 2>/dev/null; then
      # Nothing changed since the last full scan — cached output, zero Python.
      [ -f "$CACHE_FILE" ] && cat "$CACHE_FILE"
      exit 0
    fi
  fi
fi

# ── 2+3. Full scan (Python): unread count + first-seen notification ─────────
BASELINE_FILE="$STATE_DIR/baseline-$CODESYNC_PROJECT.json"

# Stamp the marker time BEFORE the scan (promoted to the real marker only on
# success). Touching after the scan would open a race: a file arriving while
# Python runs gets an mtime older than the marker and the fast path would
# wrongly treat it as already scanned.
mkdir -p "$STATE_DIR" 2>/dev/null
touch "$SCAN_MARKER.tmp" 2>/dev/null

OUTPUT=$($PY_BIN - "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" "$SEEN_LOG" "$BASELINE_FILE" <<'PY' 2>/dev/null
import json, os, sys, time

try:
    # Native Windows Python defaults stdout to cp1252 — the ▴ in the segment
    # would raise UnicodeEncodeError and silently kill the whole scan.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    # All paths arrive as argv (MSYS converts argv for native python.exe;
    # Python-side expanduser would resolve USERPROFILE, not bash's $HOME).
    cfg_path, project, role, seen_log, baseline_path = sys.argv[1:6]
    cfg = json.load(open(cfg_path))
    proj = cfg.get("projects", {}).get(project)
    if not proj:
        sys.exit(0)
    proj_path = proj.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    inbox_root = os.path.join(proj_path, "_inbox")
    if not os.path.isdir(inbox_root):
        sys.exit(0)

    print(f"PROJPATH\t{proj_path}")

    baseline = {}
    if os.path.exists(baseline_path):
        try:
            with open(baseline_path) as f:
                baseline = json.load(f)
        except Exception:
            baseline = {}

    registered = proj.get("roles", []) or []
    if registered:
        scan_dirs = [os.path.join(inbox_root, r) for r in registered]
    elif role:
        scan_dirs = [os.path.join(inbox_root, role)]
    else:
        scan_dirs = [os.path.join(inbox_root, d)
                     for d in os.listdir(inbox_root)
                     if os.path.isdir(os.path.join(inbox_root, d))]

    # Shared first-seen log: slug-keyed dedup across ALL sessions + wedge metric
    seen = set()
    if os.path.exists(seen_log):
        try:
            with open(seen_log) as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if parts and parts[0]:
                        seen.add(parts[0])
        except Exception:
            pass

    new_count = 0       # unread since last Claude turn (baseline-relative)
    unseen = []         # never-notified threads (seen-log-relative)
    for d in scan_dirs:
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(d, fn)
            # Forward slashes always: relpath yields backslashes on Windows,
            # which would fork the seen-log/baseline key space per platform.
            rel = os.path.relpath(full, proj_path).replace(os.sep, "/")
            try:
                mtime = os.path.getmtime(full)
            except OSError:
                continue
            base_mtime = baseline.get(rel)
            if base_mtime is None or mtime > base_mtime:
                new_count += 1
            if rel not in seen:
                unseen.append(rel)

    # Mark unseen as seen (append-only, O_APPEND). The same-instant window
    # where two sessions both append is accepted: duplicate log lines are
    # harmless, and each process only notifies for what IT discovered after
    # re-reading the log — sequential invocations dedup perfectly.
    if unseen:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        try:
            fd = os.open(seen_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a") as f:
                for rel in unseen:
                    f.write(f"{rel}\t{stamp}\n")
        except Exception:
            pass

    print(f"NOTIFY\t{len(unseen)}")

    if new_count > 0:
        cap = min(new_count, 9)
        plus = "+" if new_count > 9 else ""
        print(f"SEGMENT\tcodesync ▴ {cap}{plus} new")
    else:
        print("SEGMENT\t")
except Exception:
    pass
PY
)

PROJ_PATH=$(printf '%s\n' "$OUTPUT" | awk -F'\t' '$1=="PROJPATH"{print $2; exit}')
NOTIFY_N=$(printf '%s\n' "$OUTPUT" | awk -F'\t' '$1=="NOTIFY"{print $2; exit}')
SEGMENT=$(printf '%s\n' "$OUTPUT" | awk -F'\t' '$1=="SEGMENT"{print $2; exit}')

# Only refresh cache + scan marker if the scan actually succeeded (Python
# always emits PROJPATH on success). On a crashed/empty scan, leave the old
# state so the next invocation retries a full scan instead of trusting it.
if [ -n "$PROJ_PATH" ]; then
  printf '%s\n' "$PROJ_PATH" > "$PROJ_PTR" 2>/dev/null
  # Empty segment → truncate the cache to zero bytes, so the fast path's
  # `cat` prints nothing (a cached bare newline would emit a blank line).
  if [ -n "${SEGMENT:-}" ]; then
    printf '%s\n' "$SEGMENT" > "$CACHE_FILE" 2>/dev/null
  else
    : > "$CACHE_FILE" 2>/dev/null
  fi
  # Promote the PRE-scan timestamp (see above) to the real marker.
  mv -f "$SCAN_MARKER.tmp" "$SCAN_MARKER" 2>/dev/null
else
  rm -f "$SCAN_MARKER.tmp" 2>/dev/null
fi

# Fire ONE notification for this batch of never-seen threads
if [ -n "$NOTIFY_N" ] && [ "$NOTIFY_N" -gt 0 ] 2>/dev/null; then
  if [ "$NOTIFY_N" = "1" ]; then
    codesync_notify "codesync" "1 new thread in $CODESYNC_PROJECT"
  else
    codesync_notify "codesync" "$NOTIFY_N new threads in $CODESYNC_PROJECT"
  fi
fi

[ -n "${SEGMENT:-}" ] && printf '%s\n' "$SEGMENT"
exit 0
