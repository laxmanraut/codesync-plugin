#!/usr/bin/env bash
# Unit test for state.gather_sessions (launch-agents live-session tracking).
# A launched terminal writes sessions/<pid>.session; the dashboard lists the
# live ones and reaps the dead. Verifies: a live-pid session is listed, a
# dead-pid session is reaped (removed + absent), and another project's session
# is filtered out.
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

OUT=$($PY_BIN - "$SCRIPTS/lib" "$HOME/.config/codesync" <<'PY'
import sys, os, subprocess, json
lib, cfgdir = sys.argv[1], sys.argv[2]
sys.path.insert(0, lib); import state
cfg = state.load_config(os.path.join(cfgdir, "config.json"))
sdir = os.path.join(cfgdir, "sessions"); os.makedirs(sdir, exist_ok=True)
live = os.getpid()                              # this process — reliably alive
p = subprocess.Popen(["true"]); p.wait(); dead = p.pid   # reaped child — reliably dead
def w(name, body): open(os.path.join(sdir, name), "w").write(body)
w(f"{live}.session", f"testproj\tqa\t{live}\t2026-01-01T00:00:00Z\n")
w(f"{dead}.session", f"testproj\tbackend\t{dead}\t2026-01-01T00:00:00Z\n")
w("999.session",     f"otherproj\tqa\t{live}\t2026-01-01T00:00:00Z\n")
res = state.gather_sessions(cfg, "testproj", cfgdir)
print("ROLES", json.dumps(sorted(r["role"] for r in res)))
print("DEADREAPED", not os.path.exists(os.path.join(sdir, f"{dead}.session")))
print("LIVEPID", json.dumps([r["pid"] for r in res]), live)
PY
)

t_contains "live session is listed"                 '"qa"' "$OUT"
t_contains "only the live testproj session listed"  'ROLES ["qa"]' "$OUT"
t_contains "dead-pid session file was reaped"        'DEADREAPED True' "$OUT"

t_done
