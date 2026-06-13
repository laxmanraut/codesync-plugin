#!/usr/bin/env bash
# Characterization (approval) test for session-start.sh — captures its rendered
# output against a fixed fixture so the R1 refactor (consume state.py) is proven
# behavior-preserving. Filesystem-derived, so no live Syncthing needed; the
# pending banner uses curl, stubbed via PATH to return "{}" (no banner).
#
# Approval pattern: first run writes tests/golden/session-start.txt (the
# baseline from CURRENT code); later runs diff against it. Volatile bits
# (relative ages) are normalized so the golden is stable across wall-clock.
. "$(dirname "$0")/lib.sh"
t_setup

GOLDEN_DIR="$(dirname "$0")/golden"
GOLDEN="$GOLDEN_DIR/session-start.txt"
mkdir -p "$GOLDEN_DIR"

# ── deterministic fixture ───────────────────────────────────────────────────
# project testproj, role qa registered; threads with known statuses/senders;
# a project doc and a CLAUDE.md (cwd is outside the project → injection path).
mkthread() { # role slug status title from from_id
  cat > "$PROJ/_inbox/$1/$2.md" <<EOF
---
codesync:
  title: $4
  from: $5
  from-identity: $6
  status: $3
  created: 2026-06-10
---
body of $2
EOF
}
mkthread qa todo-a todo "Wire the gateway" backend vineer
mkthread qa wip-b wip "Refactor the parser" backend vineer
mkthread qa note-c note "FYI deploy window" frontend laxman
printf '# Team docs\nstuff\n' > "$PROJ/_docs/handbook.md"
printf '<!-- codesync-template-v4 -->\n# CLAUDE\nproject rules\n' > "$PROJ/CLAUDE.md"

# stub curl → empty pending (no banner noise in the golden)
STUB="$T_TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in */rest/cluster/pending/devices) printf '{}'; exit 0;; esac; done
exit 0
EOF
chmod +x "$STUB/curl"

# normalize volatile bits so the golden is stable across runs:
#   relative ages ("3d ago") and the per-run sandbox temp path.
normalize() {
  # ages drift with wall-clock; the sandbox PROJ path differs per run and per
  # platform (mixed-form C:/... on Windows) — substitute the literal known path.
  # also canonicalise the post-<proj> separator: os.path.join yields a
  # backslash on Windows, forward slash on macOS — normalise to "/".
  sed -E 's/[0-9]+[smhd] ago/<age>/g' | sed "s|$PROJ|<proj>|g" | sed 's#<proj>\\#<proj>/#g'
}

# run from OUTSIDE the project dir so the CLAUDE.md-injection path is exercised
ACTUAL=$(cd "$T_TMP" && PATH="$STUB:$PATH" CODESYNC_PROJECT=testproj CODESYNC_ROLE=qa \
         bash "$SCRIPTS/session-start.sh" 2>/dev/null | normalize)

if [ ! -f "$GOLDEN" ]; then
  printf '%s\n' "$ACTUAL" > "$GOLDEN"
  t_pass "baseline captured → ${GOLDEN#$(dirname "$0")/} (commit it; re-run to compare)"
else
  if [ "$ACTUAL" = "$(cat "$GOLDEN")" ]; then
    t_pass "session-start.sh output matches golden (behavior preserved)"
  else
    t_fail "session-start.sh output DIFFERS from golden:"
    diff <(cat "$GOLDEN") <(printf '%s\n' "$ACTUAL") >&2 || true
  fi
fi

# sanity: golden actually captured the meaningful sections (guards a silent-empty regression)
G="$(cat "$GOLDEN")"
t_contains "golden has the project header" "[codesync] Project: testproj" "$G"
t_contains "golden lists a thread title" "Wire the gateway" "$G"
t_contains "golden injects CLAUDE.md" "Project CLAUDE.md" "$G"

t_done
