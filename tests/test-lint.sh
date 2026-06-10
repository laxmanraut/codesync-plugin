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

t_done
