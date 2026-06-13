#!/usr/bin/env bash
# Characterization (approval) test for status.sh — locks the rendered output
# the R1 refactor must preserve. Covers the SUMMARY mode (no CODESYNC_PROJECT:
# identity/device/projects list) and the pending-pairing banner — both
# filesystem/curl-derived, so no live Syncthing. The per-project peers/folder
# section uses urllib against a live Syncthing and is verified by the manual
# lead_inbox before/after diff (plan T4), not here.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

GOLDEN_DIR="$(dirname "$0")/golden"
GOLDEN="$GOLDEN_DIR/status-summary.txt"
mkdir -p "$GOLDEN_DIR"

# status.sh requires an api key + device id in config; add them to the fixture.
$PY_BIN - "$HOME/.config/codesync/config.json" <<'PY'
import json, sys
p = sys.argv[1]; cfg = json.load(open(p))
cfg["syncthing_api_key"] = "test-key"
cfg["device_id"] = "SELFAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
json.dump(cfg, open(p, "w"), indent=2)
PY

# stub curl: one canned pending device (locks the banner format the dedup
# touches); fixed id+time so the golden is stable.
STUB="$T_TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    */rest/cluster/pending/devices)
      printf '{"ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ23-4567ABC-DEFGHIJ-KLMNOPQ-RSTUVWX": {"time":"2026-06-11T00:00:00Z","name":"peer-win"}}'
      exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$STUB/curl"

normalize() {
  # ages drift with wall-clock; the sandbox PROJ path differs per run and per
  # platform (mixed-form C:/... on Windows) — substitute the literal known path.
  sed -E 's/[0-9]+[smhd] ago/<age>/g' | sed "s|$PROJ|<proj>|g"
}

# summary mode = no CODESYNC_PROJECT in the environment
ACTUAL=$(cd "$T_TMP" && env -u CODESYNC_PROJECT -u CODESYNC_ROLE HOME="$HOME" \
         PATH="$STUB:$PATH" bash "$SCRIPTS/status.sh" 2>/dev/null | normalize)

if [ ! -f "$GOLDEN" ]; then
  printf '%s\n' "$ACTUAL" > "$GOLDEN"
  t_pass "baseline captured → ${GOLDEN#$(dirname "$0")/} (commit it; re-run to compare)"
else
  if [ "$ACTUAL" = "$(cat "$GOLDEN")" ]; then
    t_pass "status.sh summary output matches golden (behavior preserved)"
  else
    t_fail "status.sh summary output DIFFERS from golden:"
    diff <(cat "$GOLDEN") <(printf '%s\n' "$ACTUAL") >&2 || true
  fi
fi

G="$(cat "$GOLDEN")"
t_contains "golden shows identity" "Identity:" "$G"
t_contains "golden lists the project" "testproj" "$G"
t_contains "golden renders the pending banner" "Incoming pairing requests" "$G"
t_contains "golden shows the accept command" "/codesync-pair --peer ABCDEFG" "$G"

t_done
