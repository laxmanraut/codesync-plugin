#!/usr/bin/env bash
# Hermetic test for the Layer 3 autonomy runner (autonomy-run.sh) with a FAKE
# claude (CODESYNC_AUTONOMY_CLAUDE_BIN). Proves the load-bearing guarantees:
#  - the agent works in the ISOLATION CLONE and its change does NOT reach the
#    synced project folder (codesync never writes synced/working tree);
#  - a review-queue entry is filed (pending) for a human to merge later;
#  - one-shot per thread; and the three brakes (kill-switch, run-cap, per-role
#    lock) each stop a cycle that would otherwise produce work.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
CD="$HOME/.config/codesync"
CFG="$CD/config.json"
REVDIR="$CD/autonomy-review/testproj"
STATE="$CD/autonomy-testproj.json"

count_reviews() { ls "$REVDIR"/*.json 2>/dev/null | wc -l | tr -d ' '; }

command -v git >/dev/null 2>&1 || { t_pass "git unavailable — skipping runner test"; t_done; exit 0; }

# Source git repo OUTSIDE the synced project (sibling of $PROJ).
SRC="$T_TMP/src-repo"
mkdir -p "$SRC"
( cd "$SRC" && git init -q && git config user.email t@t && git config user.name t \
  && echo base > base.txt && git add base.txt && git commit -q -m init )

# Local autonomy config: repo_path=SRC (outside-synced), model pinned, backend on.
$PY_BIN - "$SCRIPTS/lib" "$CD" "$CFG" "$SRC" <<'PY'
import sys
lib, cd, cfg, src = sys.argv[1:5]
sys.path.insert(0, lib)
import state
c = state.load_config(cfg)
ok, e = state.set_autonomy_repo(cd, "testproj", src, c)
assert ok, e
state.set_autonomy_model(cd, "testproj", "claude-sonnet-4-6")
state.set_autonomy_role(cd, "testproj", "backend", enabled=True, allowed_tools="Read,Edit,Write")
PY

# A pending (non-auto) task thread addressed to backend.
mkdir -p "$PROJ/_inbox/backend"
cat > "$PROJ/_inbox/backend/task.md" <<'EOF'
---
from: pm
to: backend
status: task
---
Please make the change.
EOF

# Fake claude: simulate agent work (commit in cwd=clone) + emit result JSON.
FAKE="$T_TMP/fakeclaude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
echo "autonomously edited" > agent-change.txt
git add agent-change.txt 2>/dev/null
git -c user.email=a@a -c user.name=agent commit -q -m "auto: change" 2>/dev/null
printf '{"type":"result","result":"changed agent-change.txt","usage":{"input_tokens":10,"output_tokens":20}}\n'
EOF
chmod +x "$FAKE"

export CODESYNC_PROJECT=testproj
export CODESYNC_AUTONOMY_CLAUDE_BIN="$FAKE"

# ── Phase A: happy path ─────────────────────────────────────────────────────
bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
RV=$(ls "$REVDIR"/*.json 2>/dev/null | head -1)
t_assert "a review entry was filed"                    test -n "$RV"
t_contains "review entry is pending"                   '"status": "pending"' "$(cat "$RV" 2>/dev/null)"
t_contains "review entry names the auto branch"        'codesync/auto/backend/' "$(cat "$RV" 2>/dev/null)"
t_contains "review entry carries the agent summary"    'agent-change.txt' "$(cat "$RV" 2>/dev/null)"
t_refute  "agent change did NOT reach the synced folder" test -f "$PROJ/agent-change.txt"
t_assert  "the isolation clone has the agent commit"   test -f "$CD/autonomy-clones/testproj/backend/agent-change.txt"

# ── Phase B: one-shot — same state, no new entry ────────────────────────────
N1=$(count_reviews)
bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
t_eq "processed thread is not reprocessed (one-shot)" "$N1" "$(count_reviews)"

# ── Phase C: kill-switch halts even with fresh candidates ───────────────────
rm -f "$STATE"                       # clear processed → thread is a candidate again
touch "$CD/autonomy-testproj.halt"
NC=$(count_reviews)
bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
t_eq "kill-switch halts the runner" "$NC" "$(count_reviews)"
rm -f "$CD/autonomy-testproj.halt"

# ── Phase D: run-cap of 0 blocks the cycle ──────────────────────────────────
rm -f "$STATE"
ND=$(count_reviews)
CODESYNC_AUTONOMY_MAX_RUNS_PER_HOUR=0 bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
t_eq "run cap of 0 blocks the runner" "$ND" "$(count_reviews)"

# ── Phase E: a held per-role lock makes the cycle skip ──────────────────────
rm -f "$STATE"
mkdir -p "$CD/autonomy-testproj-backend.lock"
NE=$(count_reviews)
bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
t_eq "held per-role lock makes the cycle skip" "$NE" "$(count_reviews)"
rmdir "$CD/autonomy-testproj-backend.lock"

# ── Phase F: regression — a real agent EDITS but has no Bash to commit; the
# runner must capture the uncommitted change as a commit and still file a review
# (the bug live-dogfooding caught that the committing fake claude had masked). ──
FAKE2="$T_TMP/fakeclaude-editonly"
cat > "$FAKE2" <<'EOF'
#!/usr/bin/env bash
echo "edited but not committed" > editonly.txt
printf '{"type":"result","result":"edited editonly.txt (no commit)","usage":{"input_tokens":5,"output_tokens":5}}\n'
EOF
chmod +x "$FAKE2"
rm -f "$STATE"
NF=$(count_reviews)
CODESYNC_AUTONOMY_CLAUDE_BIN="$FAKE2" bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
t_eq    "runner captures an UNCOMMITTED edit + files a review" "$((NF+1))" "$(count_reviews)"
t_assert "the runner-committed change is in the clone branch" \
  test -f "$CD/autonomy-clones/testproj/backend/editonly.txt"

# ── Phase G: binding rules — GUARDRAILS.md + the role file are injected into the
# autonomous agent's prompt (the agent works in the clone and can't auto-load the
# synced project's rules, so injection is how it "always references" them). ──
CAP="$T_TMP/prompt-capture.txt"
FAKE3="$T_TMP/fakeclaude-capture"
cat > "$FAKE3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CAP"     # dump argv (incl. the -p prompt) for assertion
echo ruletest > ruletest.txt
printf '{"type":"result","result":"ok","usage":{"input_tokens":1,"output_tokens":1}}\n'
EOF
chmod +x "$FAKE3"
printf 'PROJECT RULE: NEVER touch billing code.\n' > "$PROJ/GUARDRAILS.md"
mkdir -p "$PROJ/_roles"
printf '# backend\n\n## Owns\n- plugin tests\n\n## Does not own\n- billing\n' > "$PROJ/_roles/backend.md"
rm -f "$STATE"
CODESYNC_AUTONOMY_CLAUDE_BIN="$FAKE3" bash "$SCRIPTS/autonomy-run.sh" >/dev/null 2>&1
PROMPT=$(cat "$CAP" 2>/dev/null)
t_contains "agent prompt injects the project GUARDRAILS rules" "NEVER touch billing code" "$PROMPT"
t_contains "agent prompt marks project rules as BINDING"        "BINDING"                  "$PROMPT"
t_contains "agent prompt injects the role's Owns scope"         "plugin tests"             "$PROMPT"

t_done
