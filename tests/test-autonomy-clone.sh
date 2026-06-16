#!/usr/bin/env bash
# Unit test for control-panel Layer 3 clone isolation (lib/autonomy.sh):
# codesync_autonomy_ensure_clone makes a SEPARATE clone with git hooks
# NEUTRALISED, so an agent- or peer-authored hook can never execute on this
# machine. The load-bearing proof: a hook planted in the clone's DEFAULT hooks
# dir is bypassed because core.hooksPath is redirected to an empty dir.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
. "$SCRIPTS/lib/autonomy.sh"

command -v git >/dev/null 2>&1 || { t_pass "git unavailable — skipping clone isolation test"; t_done; exit 0; }

SRC="$T_TMP/src-repo"
mkdir -p "$SRC"
( cd "$SRC" && git init -q && git config user.email t@t && git config user.name t \
  && echo hi > a.txt && git add a.txt && git commit -q -m init )

CLONE="$T_TMP/clone"
codesync_autonomy_ensure_clone "$SRC" "$CLONE" && echo "clone ok"
t_assert "clone created"                         test -d "$CLONE/.git"
t_assert "hooks reported disabled"               codesync_autonomy_hooks_disabled "$CLONE"
HP=$(git -C "$CLONE" config --get core.hooksPath)
t_assert "hooksPath points at an existing dir"   test -d "$HP"
t_eq     "hooksPath dir is empty"                "0" "$(ls -A "$HP" 2>/dev/null | wc -l | tr -d ' ')"

# Plant a hook in the clone's DEFAULT hooks dir; it must be bypassed on checkout.
cat > "$CLONE/.git/hooks/post-checkout" <<EOF
#!/bin/sh
touch "$T_TMP/HOOK_RAN"
EOF
chmod +x "$CLONE/.git/hooks/post-checkout"
git -C "$CLONE" checkout -q -b probe 2>/dev/null || true
t_refute "a hook in the default dir is BYPASSED (hooksPath redirected)" test -f "$T_TMP/HOOK_RAN"

# Refresh is idempotent and keeps hooks disabled.
codesync_autonomy_ensure_clone "$SRC" "$CLONE" && echo "refresh ok"
t_assert "refresh keeps hooks disabled"          codesync_autonomy_hooks_disabled "$CLONE"

t_done
