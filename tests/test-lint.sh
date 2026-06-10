#!/usr/bin/env bash
# Lint: every shipped script must parse (bash -n), carry no CR bytes
# (the .gitattributes eol=lf guarantee, verified), and every Python lib
# must compile.
. "$(dirname "$0")/lib.sh"
t_setup

. "$SCRIPTS/lib/platform.sh"

for s in "$SCRIPTS"/*.sh "$SCRIPTS"/lib/*.sh; do
  [ -f "$s" ] || continue
  name="${s##*/}"
  t_assert "bash -n $name" bash -n "$s"
  if grep -q $'\r' "$s"; then
    t_fail "$name contains CR bytes (CRLF leak)"
  else
    t_pass "$name is LF-only"
  fi
done

for p in "$SCRIPTS"/lib/*.py; do
  [ -f "$p" ] || continue
  t_assert "py_compile ${p##*/}" $PY_BIN -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$p"
done

# Use-before-source audit: any script referencing the platform layer
# ($PY_BIN, $CODESYNC_OS, codesync_* helpers) must source platform.sh or
# load-env.sh BEFORE the first such reference. Caught two real set -u
# crashes (status.sh, create-project.sh) during the v0.22.0 review —
# this keeps the whole bug class out permanently.
AUDIT=$($PY_BIN - "$SCRIPTS" <<'PYEOF'
import glob, os, re, sys
scripts = sys.argv[1]
bad = []
for fn in sorted(glob.glob(os.path.join(scripts, "*.sh"))):
    src = first = None
    for i, line in enumerate(open(fn, encoding="utf-8", errors="replace"), 1):
        code = line.split("#", 1)[0]
        if src is None and re.search(r'lib/(load-env|platform)\.sh"', code):
            src = i
        if first is None and re.search(
                r'\$PY_BIN|\$\{PY_BIN|\$CODESYNC_OS|\$\{CODESYNC_OS|codesync_(mtime|notify|python|syncthing_config_dir)\b',
                code):
            first = i
    if first is not None and (src is None or first < src):
        bad.append(f"{os.path.basename(fn)}: platform use at line {first}, source at {src}")
print("\n".join(bad))
PYEOF
)
if [ -z "$AUDIT" ]; then
  t_pass "no script uses the platform layer before sourcing it"
else
  t_fail "platform layer used before source: $AUDIT"
fi

t_done
