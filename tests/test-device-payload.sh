#!/usr/bin/env bash
# REGRESSION (v0.12.x guarantee): re-pairing without --as-introducer must
# never silently demote an existing introducer=true.
. "$(dirname "$0")/lib.sh"
t_setup

. "$SCRIPTS/lib/platform.sh"
DP="$SCRIPTS/lib/device_payload.py"
PEER="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"

intro_of() { $PY_BIN -c 'import json,sys; print(json.loads(sys.argv[1])["introducer"])' "$1"; }

OUT=$($PY_BIN "$DP" "$PEER" peer-name yes "")
t_eq "--as-introducer sets true" "True" "$(intro_of "$OUT")"

OUT=$($PY_BIN "$DP" "$PEER" peer-name no "")
t_eq "fresh pair without flag is false" "False" "$(intro_of "$OUT")"

EXISTING='{"deviceID": "'$PEER'", "introducer": true}'
OUT=$($PY_BIN "$DP" "$PEER" peer-name no "$EXISTING")
t_eq "existing introducer=true PRESERVED without flag" "True" "$(intro_of "$OUT")"

OUT=$($PY_BIN "$DP" "$PEER" peer-name no "not-json")
t_eq "garbage existing JSON degrades safely to false" "False" "$(intro_of "$OUT")"

t_contains "autoAcceptFolders stays off" '"autoAcceptFolders": false' "$OUT"

t_done
