#!/usr/bin/env bash
# Test generate-doc.sh: drafts a doc from the project's cloned code via a headless
# (fake) claude and prints ONLY the draft to stdout; errors when there's no clone
# or an unsupported target. Writes nothing (the dashboard editor's Save approves).
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"
CD="$HOME/.config/codesync"

command -v git >/dev/null 2>&1 || { t_pass "git unavailable — skipping generate-doc test"; t_done; exit 0; }

SRC="$T_TMP/code"
mkdir -p "$SRC"
( cd "$SRC" && git init -q && git config user.email t@t && git config user.name t \
  && echo "x=1" > f.py && git add f.py && git commit -q -m init )
# point testproj's repo_path at the clone + pin a model
$PY_BIN - "$SCRIPTS/lib" "$CD" "$CD/config.json" "$SRC" <<'PY'
import sys; lib,cd,cfgf,src=sys.argv[1:5]; sys.path.insert(0,lib); import state
cfg=state.load_config(cfgf); ok,e=state.set_autonomy_repo(cd,"testproj",src,cfg); assert ok,e
state.set_autonomy_model(cd,"testproj","claude-haiku-4-5-20251001")
PY
FAKE="$T_TMP/fakeclaude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","result":"# Generated CLAUDE\n\n## Overview\nThis is a test project.","usage":{}}'
EOF
chmod +x "$FAKE"

OUT=$(CODESYNC_AUTONOMY_CLAUDE_BIN="$FAKE" bash "$SCRIPTS/generate-doc.sh" --project testproj --target CLAUDE.md 2>/dev/null)
t_contains "generate-doc prints the drafted markdown" "# Generated CLAUDE" "$OUT"
t_contains "draft carries the generated body"          "This is a test project" "$OUT"

ERR=$(bash "$SCRIPTS/generate-doc.sh" --project noproj --target CLAUDE.md 2>&1)
t_contains "no cloned code → clear error" "no cloned code" "$ERR"

ERR2=$(CODESYNC_AUTONOMY_CLAUDE_BIN="$FAKE" bash "$SCRIPTS/generate-doc.sh" --project testproj --target x.sh 2>&1)
t_contains "unsupported target → error" "unsupported target" "$ERR2"

t_done
