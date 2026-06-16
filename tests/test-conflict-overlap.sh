#!/usr/bin/env bash
# Unit test for the launch-agents conflict-overlap heuristic + atomic role write
# (state.role_overlaps / parse_role_owns / write_role_file). The calibration the
# eng review asked for: a genuine duplicate flags, a clearly-distinct role does
# NOT (so the warning isn't alarm-fatigue noise).
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

mkdir -p "$PROJ/_roles"
cat > "$PROJ/_roles/backend.md" <<'EOF'
# backend

## Owns
- REST/GraphQL APIs
- Database schema and queries

## Does not own
- UI components
EOF

OUT=$($PY_BIN - "$SCRIPTS/lib" "$PROJ" <<'PY'
import sys, os, json, glob
lib, proj = sys.argv[1], sys.argv[2]
sys.path.insert(0, lib)
import state
print("DUP", json.dumps(state.role_overlaps(proj, ["REST/GraphQL APIs"])))
print("DIST", json.dumps(state.role_overlaps(proj, ["Visual design and interaction patterns", "Design system specs"])))
print("OWNS", json.dumps(state.parse_role_owns(os.path.join(proj, "_roles", "backend.md"))))
p = state.write_role_file(proj, "designer", ["Visual design"], ["Backend code"])
print("WROTE", os.path.basename(p), os.path.exists(p))
print("READBACK", json.dumps(state.parse_role_owns(p)))
print("TMP", json.dumps(glob.glob(os.path.join(proj, "_roles", ".*tmp"))))
PY
)

t_contains "duplicate Owns flags the existing role"        '"role": "backend"' "$OUT"
t_contains "overlap names a shared keyword"                'apis' "$OUT"
t_contains "clearly-distinct role does NOT flag (calibration)" 'DIST []' "$OUT"
t_contains "parse_role_owns reads the Owns bullets"        'REST/GraphQL APIs' "$OUT"
t_contains "parse_role_owns stops at 'Does not own'"       '["REST/GraphQL APIs", "Database schema and queries"]' "$OUT"
t_contains "write_role_file wrote designer.md atomically"  'WROTE designer.md True' "$OUT"
t_contains "written role reads back its Owns"              'Visual design' "$OUT"
t_contains "no leftover temp file after atomic write"      'TMP []' "$OUT"

t_done
