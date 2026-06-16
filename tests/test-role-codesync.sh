#!/usr/bin/env bash
# Unit test for the control-panel Layer 1 capability block on the synced role
# (state.parse_role_codesync / write_role_codesync). Covers: round-trip,
# body-preservation, fail-soft on malformed/missing, paren-comma list safety,
# block-list form, and the advisory-only contract (writing grants nothing — it
# is just frontmatter, asserted by the data it produces, not by any grant path).
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

mkdir -p "$PROJ/_roles"
# An existing hand-written role with a markdown body but no frontmatter.
cat > "$PROJ/_roles/qa.md" <<'EOF'
# qa

## Owns
- test plans

## Does not own
- prod deploys
EOF

OUT=$($PY_BIN - "$SCRIPTS/lib" "$PROJ" <<'PY'
import sys, os, json, glob
lib, proj = sys.argv[1], sys.argv[2]
sys.path.insert(0, lib)
import state
rd = os.path.join(proj, "_roles")

# 1. Write a fresh codesync block onto a role that has no file yet → seeds body.
p = state.write_role_codesync(proj, "backend", title="Backend",
                              allowed_tools=["Read", "Edit", "Bash(npm test)"],
                              autonomy="sandboxed")
print("WROTE", os.path.basename(p), os.path.exists(p))
print("PARSE_NEW", json.dumps(state.parse_role_codesync(p), sort_keys=True))

# 2. Add a block onto the existing qa role → its markdown body is preserved.
qp = state.write_role_codesync(proj, "qa", allowed_tools=["Read", "Glob", "Grep"])
body = open(qp, encoding="utf-8").read()
print("QA_BODY_KEPT", ("## Owns" in body and "test plans" in body))
print("PARSE_QA", json.dumps(state.parse_role_codesync(qp), sort_keys=True))

# 3. Atomic write leaves no temp file behind.
print("TMP", json.dumps(glob.glob(os.path.join(rd, ".*tmp"))))

# 4. Fail-soft: missing file, and malformed (unclosed) frontmatter → {}.
print("MISSING", json.dumps(state.parse_role_codesync(os.path.join(rd, "nope.md"))))
open(os.path.join(rd, "bad.md"), "w").write("---\ncodesync:\n  title: x\n")
print("UNCLOSED", json.dumps(state.parse_role_codesync(os.path.join(rd, "bad.md"))))

# 5. Inline list with a comma inside parens is not torn apart.
open(os.path.join(rd, "pc.md"), "w").write(
    "---\ncodesync:\n  allowed-tools: [Read, Bash(a, b), Edit]\n  autonomy: notify\n---\n# x\n")
print("PARENCOMMA", json.dumps(state.parse_role_codesync(os.path.join(rd, "pc.md")), sort_keys=True))

# 6. Block-list (- item) form parses too.
open(os.path.join(rd, "bl.md"), "w").write(
    "---\ncodesync:\n  allowed-tools:\n    - Read\n    - Edit\n  title: t\n---\n# x\n")
print("BLOCKLIST", json.dumps(state.parse_role_codesync(os.path.join(rd, "bl.md")), sort_keys=True))
PY
)

t_contains "write_role_codesync wrote backend.md atomically"   'WROTE backend.md True' "$OUT"
t_contains "fresh block round-trips title/tools/autonomy"      '"allowed-tools": ["Read", "Edit", "Bash(npm test)"], "autonomy": "sandboxed", "title": "Backend"' "$OUT"
t_contains "existing markdown body is preserved on rewrite"    'QA_BODY_KEPT True' "$OUT"
t_contains "qa block reads back its tools"                     '"allowed-tools": ["Read", "Glob", "Grep"]' "$OUT"
t_contains "no leftover temp file after atomic write"          'TMP []' "$OUT"
t_contains "missing file fails soft to {}"                     'MISSING {}' "$OUT"
t_contains "unclosed frontmatter fails soft to {}"             'UNCLOSED {}' "$OUT"
t_contains "comma inside parens is not split"                  '"Bash(a, b)"' "$OUT"
t_contains "block-list form parses allowed-tools"              'BLOCKLIST {"allowed-tools": ["Read", "Edit"], "title": "t"}' "$OUT"

t_done
