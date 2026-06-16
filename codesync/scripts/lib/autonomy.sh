# lib/autonomy.sh — control-panel Layer 3 (sandboxed autonomy) helpers.
# Sourced by autonomy-setup.sh and autonomy-run.sh; depends on platform.sh.
#
# Isolation model (eng-review): autonomy runs in a SEPARATE CLONE of the local
# repo_path with git HOOKS DISABLED — NOT a bare worktree (a worktree shares
# .git/hooks/config with the live repo, so it is not a sandbox). The clone lives
# under the LOCAL config dir, outside every synced folder, so nothing an agent
# writes reaches a peer until a human merges it (codesync never writes the synced
# folder or the live working tree on an agent's behalf).

# codesync_autonomy_ensure_clone REPO_PATH CLONE_DIR
# Create the clone if absent, else refresh it; disable hooks either way. The
# caller has already validated REPO_PATH is outside every synced project
# (state.is_inside_synced). Returns 0 on success, non-zero on failure.
codesync_autonomy_ensure_clone() {
  __aec_repo="$1"; __aec_clone="$2"
  command -v git >/dev/null 2>&1 || { echo "autonomy: git not found" >&2; return 1; }
  [ -d "$__aec_repo/.git" ] || { echo "autonomy: not a git repo: $__aec_repo" >&2; return 1; }
  if [ ! -d "$__aec_clone/.git" ]; then
    mkdir -p "$(dirname "$__aec_clone")" || return 1
    git clone --quiet "$__aec_repo" "$__aec_clone" || { echo "autonomy: clone failed" >&2; return 1; }
  fi
  # Neutralise hooks belt-and-suspenders: point core.hooksPath at an empty dir
  # AND keep it empty, so neither a configured nor a sample hook can execute on
  # this machine — even if the source repo ever set core.hooksPath itself. An
  # empty directory is portable; '/dev/null' is not a valid hooksPath on Windows.
  __aec_empty="$__aec_clone/.git/codesync-empty-hooks"
  rm -rf "$__aec_empty" 2>/dev/null || true
  mkdir -p "$__aec_empty"
  git -C "$__aec_clone" config core.hooksPath "$__aec_empty" || return 1
  # Refresh from source so each run starts from current state (best-effort: a
  # brand-new clone is already current; a stale clone catches up).
  git -C "$__aec_clone" fetch --quiet origin 2>/dev/null || true
  return 0
}

# codesync_autonomy_hooks_disabled CLONE_DIR — 0 if hooks are neutralised.
# Used by tests and by the runner's pre-flight (refuse to run an un-isolated clone).
codesync_autonomy_hooks_disabled() {
  __ahd_clone="$1"
  __ahd_hp="$(git -C "$__ahd_clone" config --get core.hooksPath 2>/dev/null || echo)"
  [ -n "$__ahd_hp" ] || return 1
  # neutralised iff hooksPath points at an existing, empty directory
  [ -d "$__ahd_hp" ] || return 1
  [ -z "$(ls -A "$__ahd_hp" 2>/dev/null)" ] || return 1
  return 0
}

# ── review two-gate approve / reject / GC (Layer 3 T7/T8) ────────────────────
# codesync_autonomy_approve CLONE BRANCH [BASE_BRANCH]
# GATE 1: rebase BRANCH onto the current base, then push it into the LOCAL
# origin repo (= repo_path) as a branch ref. Never checks out / writes origin's
# working tree, never pushes to a network remote, never reaches a peer — the
# human merges + syncs that branch themselves (GATE 2). Returns 0 ok / 2 conflict
# / 1 other failure.
codesync_autonomy_approve() {
  __aa_clone="$1"; __aa_branch="$2"; __aa_base="${3:-}"
  command -v git >/dev/null 2>&1 || return 1
  git -C "$__aa_clone" fetch --quiet origin 2>/dev/null || true
  if [ -n "$__aa_base" ] && git -C "$__aa_clone" rev-parse --verify --quiet "origin/$__aa_base" >/dev/null 2>&1; then
    if ! git -C "$__aa_clone" rebase --quiet "origin/$__aa_base" "$__aa_branch" 2>/dev/null; then
      git -C "$__aa_clone" rebase --abort 2>/dev/null || true
      echo "approve: rebase conflict against current base — resolve manually" >&2
      return 2
    fi
  fi
  # Push the branch into the local origin (repo_path). We only ever push a
  # codesync/auto/* ref, never origin's checked-out branch, so a non-bare origin
  # accepts it without denyCurrentBranch trouble.
  git -C "$__aa_clone" push --quiet origin "$__aa_branch:$__aa_branch" 2>/dev/null \
    || { echo "approve: could not land the branch in the local repo" >&2; return 1; }
  return 0
}

# codesync_autonomy_reject CLONE BRANCH — drop the branch in the clone.
codesync_autonomy_reject() { codesync_autonomy_gc_branch "$1" "$2"; }

# codesync_autonomy_gc_branch CLONE BRANCH — delete a branch in the clone
# (detach first so a checked-out branch can be removed). Idempotent.
codesync_autonomy_gc_branch() {
  __gc_clone="$1"; __gc_branch="$2"
  git -C "$__gc_clone" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$__gc_clone" checkout -q --detach 2>/dev/null || true
  git -C "$__gc_clone" branch -D "$__gc_branch" 2>/dev/null || true
  return 0
}
