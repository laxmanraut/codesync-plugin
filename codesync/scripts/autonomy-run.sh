#!/usr/bin/env bash
# autonomy-run.sh — one polling cycle of control-panel Layer 3 sandboxed autonomy.
#
# Fired on a schedule (installed via autonomy-setup.sh --install). For each role
# with autonomy ENABLED in LOCAL config (never the synced role file), with
# unprocessed task threads, it runs a headless `claude -p` INSIDE the role's
# isolation clone (separate repo, hooks disabled) on a fresh branch, then files
# the result in the local review queue. It NEVER merges, NEVER writes the synced
# folder or the live working tree — a human approves + merges later (two gates).
#
# Brakes (reused from the autopilot) + Layer 3 additions:
#   - one-shot-per-thread `processed` map; never process `generated-by: auto`
#   - per-role lock (no two cycles on the same clone)            [L3-T6]
#   - rolling-hour run cap + token ceiling + a kill-switch file  [L3-T5]
#   - explicit --allowedTools, NO --dangerously-skip-permissions [eng-review]
#   - absolute claude bin, pinned --model, scrubbed CLAUDE_CODE_* env [spike]
#
# Env:
#   CODESYNC_PROJECT                  (required)
#   CODESYNC_AUTONOMY_CLAUDE_BIN      (optional) override claude binary (tests)
#   CODESYNC_AUTONOMY_MAX_RUNS_PER_HOUR / _MAX_TOKENS_PER_HOUR (optional)
set -euo pipefail

CONFIG_DIR="$HOME/.config/codesync"
CFG_FILE="$CONFIG_DIR/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# launchd/schtasks give a minimal PATH; extend before platform.sh (PY_BIN probes PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.claude/local:$PATH"
. "$SCRIPT_DIR/lib/platform.sh"
. "$SCRIPT_DIR/lib/autonomy.sh"

PROJECT="${CODESYNC_PROJECT:-}"
[ -n "$PROJECT" ] || { echo "autonomy: CODESYNC_PROJECT not set" >&2; exit 1; }
[ -f "$CFG_FILE" ] || exit 0
[ -n "${PY_BIN:-}" ] || exit 0

STATE_FILE="$CONFIG_DIR/autonomy-$PROJECT.json"
LOG_FILE="$CONFIG_DIR/autonomy-$PROJECT.log"
HALT_FILE="$CONFIG_DIR/autonomy-$PROJECT.halt"
REVIEW_DIR="$CONFIG_DIR/autonomy-review/$PROJECT"
MAX_RUNS="${CODESYNC_AUTONOMY_MAX_RUNS_PER_HOUR:-4}"
MAX_TOKENS="${CODESYNC_AUTONOMY_MAX_TOKENS_PER_HOUR:-200000}"
LIB="$SCRIPT_DIR/lib"

logln() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"; }

# Kill-switch: a single file halts ALL autonomy for the project (L3-T5).
if [ -f "$HALT_FILE" ]; then
  logln "HALT kill-switch present ($HALT_FILE) — skipping all roles"
  exit 0
fi

PROJ_PATH=$(codesync_python -c '
import json,sys
p=json.load(open(sys.argv[1]))["projects"].get(sys.argv[2],{})
print(p.get("path",""))' "$CFG_FILE" "$PROJECT")
[ -n "$PROJ_PATH" ] && [ -d "$PROJ_PATH" ] || exit 0

# ── T8: expire stale pending reviews + GC their branches (every cycle, cheap) ──
TTL_HOURS="${CODESYNC_AUTONOMY_REVIEW_TTL_HOURS:-72}"
EXPIRED=$(codesync_python - "$LIB" "$CONFIG_DIR" "$PROJECT" "$TTL_HOURS" <<'PY'
import sys
lib, cd, proj, ttl = sys.argv[1:5]
sys.path.insert(0, lib)
import state
for rid, branch, clone in state.expire_reviews(cd, proj, ttl_hours=int(ttl)):
    print(f"{branch}\t{clone}")
PY
)
if [ -n "$EXPIRED" ]; then
  printf '%s\n' "$EXPIRED" | while IFS="$(printf '\t')" read -r br cl; do
    [ -n "$br" ] && [ -n "$cl" ] && codesync_autonomy_gc_branch "$cl" "$br" \
      && logln "GC expired branch $br"
  done
fi

# Enabled roles (LOCAL authority).
ENABLED_ROLES=$(codesync_python - "$LIB" "$CONFIG_DIR" "$PROJECT" <<'PY'
import sys
lib, cd, proj = sys.argv[1:4]
sys.path.insert(0, lib)
import state
data = (state.load_autonomy(cd).get("projects", {}).get(proj, {}) or {})
for role, rc in (data.get("roles", {}) or {}).items():
    if rc.get("enabled"):
        print(role)
PY
)
[ -n "$ENABLED_ROLES" ] || exit 0

# Pinned model (spike lesson: never rely on the stale settings default).
MODEL=$(codesync_python -c '
import json,sys,os
sys.path.insert(0,sys.argv[3]); import state
print((state.load_autonomy(sys.argv[1]).get("projects",{}).get(sys.argv[2],{}) or {}).get("model",""))
' "$CONFIG_DIR" "$PROJECT" "$LIB")
[ -n "$MODEL" ] || MODEL="claude-sonnet-4-6"

CLAUDE_BIN="${CODESYNC_AUTONOMY_CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then CLAUDE_BIN="$(command -v claude 2>/dev/null || echo claude)"; fi

run_role() {
  __role="$1"
  __resolved=$(codesync_python - "$LIB" "$CONFIG_DIR" "$PROJECT" "$__role" <<'PY'
import sys, json
lib, cd, proj, role = sys.argv[1:5]
sys.path.insert(0, lib)
import state
r = state.resolve_autonomy_role(cd, proj, role)
print(json.dumps(r) if r else "")
PY
)
  [ -n "$__resolved" ] || return 0
  __repo=$(printf '%s' "$__resolved" | codesync_python -c 'import json,sys;print(json.load(sys.stdin).get("repo_path",""))')
  __clone=$(printf '%s' "$__resolved" | codesync_python -c 'import json,sys;print(json.load(sys.stdin).get("clone_dir",""))')
  __tools=$(printf '%s' "$__resolved" | codesync_python -c 'import json,sys;print(json.load(sys.stdin).get("allowed_tools",""))')
  [ -n "$__repo" ] || { logln "SKIP role=$__role no repo_path configured"; return 0; }
  [ -n "$__tools" ] || { logln "SKIP role=$__role no allowed_tools configured (refusing unrestricted autonomy)"; return 0; }

  # ── per-role lock (L3-T6): mkdir is atomic; stale-free via trap ──
  __lock="$CONFIG_DIR/autonomy-$PROJECT-$__role.lock"
  if ! mkdir "$__lock" 2>/dev/null; then
    logln "SKIP role=$__role locked (another cycle running)"
    return 0
  fi
  # shellcheck disable=SC2064
  trap "rmdir '$__lock' 2>/dev/null || true" RETURN

  # ── pre-check: unprocessed, non-auto task threads for this role (zero tokens) ──
  __cands=$(codesync_python - "$CFG_FILE" "$PROJECT" "$STATE_FILE" "$LIB" "$__role" <<'PY'
import json, os, sys
cfg_path, project, state_path, lib_dir, role = sys.argv[1:6]
sys.path.insert(0, lib_dir)
from frontmatter import read_frontmatter_from_file
cfg = json.load(open(cfg_path))
proj = cfg.get("projects", {}).get(project, {})
proj_path, identity = proj.get("path", ""), cfg.get("identity", "")
state = {"processed": {}}
if os.path.exists(state_path):
    try: state = json.load(open(state_path))
    except Exception: pass
processed = state.get("processed", {})
inbox = os.path.join(proj_path, "_inbox", role)
if os.path.isdir(inbox):
    for fn in sorted(os.listdir(inbox)):
        if not fn.endswith(".md") or fn == "README.md":
            continue
        rel = f"_inbox/{role}/{fn}"
        if rel in processed:
            continue
        fm = read_frontmatter_from_file(os.path.join(inbox, fn)) or {}
        if fm.get("generated-by", "") == "auto":
            continue
        if identity and fm.get("from-identity", "") == identity:
            continue
        print(rel)
PY
)
  [ -n "$__cands" ] || { logln "role=$__role no pending work"; return 0; }

  # ── budget: rolling-hour run cap + token ceiling (L3-T5) ──
  __budget=$(codesync_python - "$STATE_FILE" "$MAX_RUNS" "$MAX_TOKENS" <<'PY'
import json, os, sys, time
state_path, max_runs, max_tokens = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
state = {"runs": [], "tokens": []}
if os.path.exists(state_path):
    try: state = json.load(open(state_path))
    except Exception: pass
now = time.time()
runs = [t for t in state.get("runs", []) if now - t < 3600]
tok = sum(n for (t, n) in state.get("tokens", []) if now - t < 3600)
if len(runs) >= max_runs: print("CAP runs")
elif tok >= max_tokens:   print("CAP tokens")
else:                     print("OK")
PY
)
  if [ "$__budget" != "OK" ]; then
    logln "SKIP role=$__role budget $__budget (runs<=$MAX_RUNS tokens<=$MAX_TOKENS/hr)"
    return 0
  fi

  # ── isolation clone: refresh + pre-flight hooks check (refuse if not isolated) ──
  if ! codesync_autonomy_ensure_clone "$__repo" "$__clone"; then
    logln "ERROR role=$__role could not prepare isolation clone"
    return 0
  fi
  if ! codesync_autonomy_hooks_disabled "$__clone"; then
    logln "ERROR role=$__role clone hooks NOT disabled — refusing to run"
    return 0
  fi

  __stamp=$(date -u +%Y%m%d-%H%M%S)
  __branch="codesync/auto/$__role/$__stamp"
  # Branch from the PRISTINE base (origin's default branch), never from a prior
  # un-merged auto branch — each cycle proposes a fresh change from current base,
  # so branches don't compound. Fall back to the clone's current HEAD if origin
  # HEAD can't be resolved.
  __basebr=$(git -C "$__clone" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
  [ -n "$__basebr" ] || __basebr=$(git -C "$__clone" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  if ! git -C "$__clone" checkout -q -B "$__branch" "origin/$__basebr" 2>/dev/null; then
    git -C "$__clone" checkout -q -B "$__branch" 2>/dev/null || { logln "ERROR role=$__role branch checkout failed"; return 0; }
  fi
  __base=$(git -C "$__clone" rev-parse HEAD 2>/dev/null || echo "")

  __n=$(printf '%s\n' "$__cands" | wc -l | tr -d ' ')
  logln "RUN role=$__role branch=$__branch model=$MODEL tools=[$__tools] candidates=$__n"

  # Binding project + role rules (synced files → shared with the whole team).
  # The agent works in the CLONE, not the synced folder, so it can't auto-load
  # these — inject them into the prompt every run. Capped so a long rules file
  # can't blow up the prompt. GUARDRAILS.md = project-wide; _roles/<role>.md =
  # this role's scope. (Tool scope via --allowedTools is still the HARD limit;
  # these are the human-authored contract on top.)
  __rules=""
  if [ -f "$PROJ_PATH/GUARDRAILS.md" ]; then
    __rules="$__rules
=== PROJECT RULES for '$PROJECT' (BINDING — you MUST follow these) ===
$(head -c 8000 "$PROJ_PATH/GUARDRAILS.md")
"
  fi
  if [ -f "$PROJ_PATH/_roles/$__role.md" ]; then
    __rules="$__rules
=== YOUR ROLE '$__role' (stay within what it Owns; do not touch what it does NOT own) ===
$(head -c 4000 "$PROJ_PATH/_roles/$__role.md")
"
  fi

  __prompt="You are the codesync AUTONOMOUS agent for role '$__role' in project '$PROJECT'. You run UNATTENDED in an ISOLATED CLONE on branch '$__branch' — your work does NOT reach anyone until a human reviews and merges it. Work the tasks below using ONLY your allowed tools (edit files in the current directory). You do NOT need to commit or push — codesync captures your file changes for review automatically. Do NOT touch anything outside this repo.
$__rules
Task threads (under $PROJ_PATH):
$__cands

When done, print a one-line summary of what you changed."

  # Scrub a parent session's CLAUDE_CODE_* env (spike: they break the wrapper);
  # explicit --allowedTools, pinned --model, NO --dangerously-skip-permissions
  # (an out-of-scope tool is skipped+logged by claude, never auto-approved).
  set +e
  __out=$(cd "$__clone" && env -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_EXECPATH \
            -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION \
            -u CLAUDE_EFFORT -u AI_AGENT \
            "$CLAUDE_BIN" -p "$__prompt" --model "$MODEL" \
            --allowedTools "$__tools" --output-format json 2>&1)
  __exit=$?
  set -e

  # Parse usage (best-effort) + result text from claude's JSON; tolerate non-JSON.
  __tokens=$(printf '%s' "$__out" | codesync_python -c '
import json,sys
try:
    d=json.loads(sys.stdin.read()); u=d.get("usage",{}) or {}
    print(int(u.get("input_tokens",0))+int(u.get("output_tokens",0)))
except Exception:
    print(0)')
  __summary=$(printf '%s' "$__out" | codesync_python -c '
import json,sys
try: print((json.loads(sys.stdin.read()).get("result","") or "").strip()[:300])
except Exception: print("")')
  [ -n "$__summary" ] || __summary="(no summary; claude exit $__exit)"

  # The agent edits files with Read/Edit/Write but typically has NO Bash tool to
  # git-commit — so the runner (trusted infra) captures any working-tree changes
  # as a commit on the branch; the review diff then reflects exactly what the
  # agent changed. (If the agent did commit itself, there's nothing left to add.)
  if [ -n "$(git -C "$__clone" status --porcelain 2>/dev/null)" ]; then
    git -C "$__clone" add -A 2>/dev/null || true
    git -C "$__clone" -c user.email=autonomy@codesync -c "user.name=codesync-$__role" \
      commit -q -m "codesync autonomous change ($__role $__stamp)" 2>/dev/null || true
  fi
  __head=$(git -C "$__clone" rev-parse HEAD 2>/dev/null || echo "")
  __changed=no
  if [ -n "$__base" ] && [ -n "$__head" ] && [ "$__base" != "$__head" ]; then __changed=yes; fi

  # ── record run + tokens; mark candidates processed (one-shot) ──
  codesync_python - "$STATE_FILE" "$__exit" "$__tokens" <<PY
import json, os, sys, time
state_path, claude_exit, tokens = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
state = {"runs": [], "tokens": [], "processed": {}}
if os.path.exists(state_path):
    try: state = json.load(open(state_path))
    except Exception: pass
now = time.time()
state["runs"] = [t for t in state.get("runs", []) if now - t < 3600] + [now]
state["tokens"] = [(t, n) for (t, n) in state.get("tokens", []) if now - t < 3600] + [[now, tokens]]
if claude_exit == 0:
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for rel in """$__cands""".strip().splitlines():
        rel = rel.strip()
        if rel:
            state.setdefault("processed", {})[rel] = stamp
os.makedirs(os.path.dirname(state_path), exist_ok=True)
tmp = state_path + ".tmp"
json.dump(state, open(tmp, "w"), indent=2)
os.replace(tmp, state_path)
PY

  # ── file a review-queue entry when the branch advanced (L3-T7 reads these) ──
  if [ "$__changed" = yes ]; then
    __diffstat=$(git -C "$__clone" diff --stat "$__base" "$__head" 2>/dev/null | tail -1)
    __files=$(git -C "$__clone" diff --name-only "$__base" "$__head" 2>/dev/null)
    mkdir -p "$REVIEW_DIR"
    # T8 secret denylist: if the diff touches a secret-looking file, file the
    # entry as 'blocked' (approve refuses it) instead of 'pending'.
    __entry_out=$(printf '%s' "$__files" | codesync_python - "$LIB" "$REVIEW_DIR" "$PROJECT" "$__role" "$__branch" "$__basebr" "$__clone" "$__base" "$__head" "$__diffstat" "$__summary" <<'PY'
import json, os, sys, time
lib, review_dir, proj, role, branch, basebr, clone, base, head, diffstat, summary = sys.argv[1:12]
sys.path.insert(0, lib)
import state
files = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
secrets = state.secret_denylist_hits(files)
entry = {
    "id": f"{role}-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}",
    "project": proj, "role": role, "branch": branch, "base_branch": basebr,
    "clone_dir": clone, "base": base, "head": head, "diffstat": diffstat,
    "summary": summary, "secrets": secrets,
    "status": "blocked" if secrets else "pending",
    "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
dest = os.path.join(review_dir, entry["id"] + ".json")
tmp = dest + ".tmp"
json.dump(entry, open(tmp, "w"), indent=2)
os.replace(tmp, dest)
print(entry["status"])
PY
)
    logln "REVIEW filed role=$__role branch=$__branch status=$__entry_out tokens=$__tokens — $__summary"
  else
    logln "DONE role=$__role no changes (exit $__exit, tokens=$__tokens) — $__summary"
  fi
  return 0
}

printf '%s\n' "$ENABLED_ROLES" | while IFS= read -r role; do
  [ -n "$role" ] || continue
  run_role "$role"
done
exit 0
