#!/usr/bin/env bash
# Layer 3 review queue + two-gate approve (T7) and TTL/GC + secret denylist (T8).
# The load-bearing guarantees: approve lands the branch in the LOCAL repo ONLY
# (never the synced folder, never origin's working tree, never a remote/peer);
# reject drops it; a secret-flagged entry can't be approved; stale entries expire.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
. "$SCRIPTS/lib/autonomy.sh"
CD="$HOME/.config/codesync"
REVDIR="$CD/autonomy-review/testproj"
mkdir -p "$REVDIR"

command -v git >/dev/null 2>&1 || { t_pass "git unavailable — skipping review test"; t_done; exit 0; }

# Local repo (outside synced) with a 'main' branch + a clone with hooks disabled.
SRC="$T_TMP/src-repo"
mkdir -p "$SRC"
( cd "$SRC" && git -c init.defaultBranch=main init -q && git config user.email t@t && git config user.name t \
  && echo base > base.txt && git add base.txt && git commit -q -m init )
CLONE="$CD/autonomy-clones/testproj/backend"
codesync_autonomy_ensure_clone "$SRC" "$CLONE" >/dev/null

# Helper: make an auto branch with a change + write a review entry of given status.
make_entry() {  # id  status  changefile
  local id="$1" status="$2" file="$3" br="codesync/auto/backend/$1"
  git -C "$CLONE" checkout -q -B "$br" origin/main
  echo data > "$CLONE/$file"; git -C "$CLONE" add "$file"
  git -C "$CLONE" -c user.email=a@a -c user.name=a commit -q -m "auto: $file"
  $PY_BIN - "$REVDIR" "$id" "$status" "$br" "$CLONE" <<'PY'
import sys, os, json
rd, rid, status, br, clone = sys.argv[1:6]
json.dump({"id":rid,"project":"testproj","role":"backend","branch":br,"base_branch":"main",
           "clone_dir":clone,"status":status,"created":"2026-06-16T00:00:00Z",
           "summary":"auto change","secrets":(["secret.pem"] if status=="blocked" else [])},
          open(os.path.join(rd, rid+".json"), "w"), indent=2)
PY
}

# ── approve (gate 1): branch lands in the LOCAL repo, synced+worktree untouched ──
make_entry "backend-20260616-100000" pending feature.txt
OUT=$(bash "$SCRIPTS/autonomy-review.sh" --project testproj --id backend-20260616-100000 --action approve 2>&1)
t_contains "approve reports APPROVED" "APPROVED" "$OUT"
t_assert  "approved branch landed in the LOCAL repo" \
  git -C "$SRC" rev-parse --verify --quiet codesync/auto/backend/backend-20260616-100000
t_eq      "origin working tree left clean (never checked out)" "" "$(git -C "$SRC" status --porcelain)"
t_refute  "approved change is NOT in origin's working tree"   test -f "$SRC/feature.txt"
t_refute  "approved change did NOT reach the synced folder"   test -f "$PROJ/feature.txt"
t_contains "entry marked approved" '"status": "approved"' "$(cat "$REVDIR/backend-20260616-100000.json")"

# ── reject: branch dropped from the clone, entry marked rejected ──
make_entry "backend-20260616-110000" pending other.txt
bash "$SCRIPTS/autonomy-review.sh" --project testproj --id backend-20260616-110000 --action reject >/dev/null 2>&1
t_refute  "rejected branch removed from the clone" \
  git -C "$CLONE" rev-parse --verify --quiet codesync/auto/backend/backend-20260616-110000
t_contains "entry marked rejected" '"status": "rejected"' "$(cat "$REVDIR/backend-20260616-110000.json")"

# ── blocked (secret denylist): approve refused, branch NOT pushed ──
make_entry "backend-20260616-120000" blocked secret.pem
BO=$(bash "$SCRIPTS/autonomy-review.sh" --project testproj --id backend-20260616-120000 --action approve 2>&1)
t_contains "secret-flagged entry refuses approve" "BLOCKED" "$BO"
t_refute  "blocked branch was NOT landed in the local repo" \
  git -C "$SRC" rev-parse --verify --quiet codesync/auto/backend/backend-20260616-120000

# ── state-level: secret_denylist_hits + expire_reviews ──
ST=$($PY_BIN - "$SCRIPTS/lib" "$CD" <<'PY'
import sys, json
lib, cd = sys.argv[1:3]
sys.path.insert(0, lib)
import state
hits = state.secret_denylist_hits(["src/app.py", "deploy/id_rsa", ".env.local", "k.pem", "ok.txt"])
print("SECRETS", json.dumps(sorted(hits)))
# expire: a pending entry created at epoch 0 is far older than ttl=72h vs now=1e6.
import os, time
rid = "backend-20260101-000000"
json.dump({"id":rid,"project":"testproj","role":"backend","branch":"codesync/auto/backend/old",
           "clone_dir":"/x","status":"pending","created":"2025-01-01T00:00:00Z"},
          open(os.path.join(cd,"autonomy-review","testproj",rid+".json"),"w"))
expired = state.expire_reviews(cd, "testproj", ttl_hours=72, now=1893456000)
print("EXPIRED_IDS", json.dumps(sorted(i for (i,_b,_c) in expired)))
print("OLD_STATUS", state.load_review(cd,"testproj",rid)["status"])
PY
)
t_contains "secret denylist flags id_rsa/.env/.pem, not normal files" '[".env.local", "deploy/id_rsa", "k.pem"]' "$ST"
t_contains "stale pending review is expired"  'backend-20260101-000000' "$ST"
t_contains "expired entry status is updated"  "OLD_STATUS expired" "$ST"

t_done
