#!/usr/bin/env bash
# Unit test for the project manifest + repo_url validation (state.py):
# valid_repo_url (it later feeds `git clone`, so shell-y URLs MUST be rejected)
# and write/read_project_manifest (round-trip + preserves other keys).
. "$(dirname "$0")/lib.sh"
t_setup
. "$SCRIPTS/lib/platform.sh"

OUT=$($PY_BIN - "$SCRIPTS/lib" "$T_TMP" <<'PY'
import sys, json, os
sys.path.insert(0, sys.argv[1]); import state
proj = sys.argv[2]
print("HTTPS", state.valid_repo_url("https://github.com/a/b.git"))
print("SSH",   state.valid_repo_url("git@bitbucket.org:a/b.git"))
print("EMPTY", state.valid_repo_url(""))
print("SPACE", state.valid_repo_url("not a url; rm -rf /"))
print("SUBST", state.valid_repo_url("http://x.com/$(whoami)"))
state.write_project_manifest(proj, "demo", "https://github.com/a/b.git")
print("MANIFEST", json.dumps(state.read_project_manifest(proj), sort_keys=True))
# repo_url=None must preserve the existing url and any extra keys
open(os.path.join(proj, "_project.json"), "w").write(json.dumps({"name":"demo","repo_url":"u","extra":1}))
state.write_project_manifest(proj, "demo2", None)
print("PRESERVE", json.dumps(state.read_project_manifest(proj), sort_keys=True))
PY
)

t_contains "https git URL accepted"                "HTTPS True" "$OUT"
t_contains "git@host:path (scp-style) accepted"    "SSH True" "$OUT"
t_contains "empty repo_url allowed (optional)"     "EMPTY True" "$OUT"
t_contains "url with spaces/; rejected"            "SPACE False" "$OUT"
t_contains "url with command substitution rejected" "SUBST False" "$OUT"
t_contains "manifest round-trips name + repo_url"  '"name": "demo", "repo_url": "https://github.com/a/b.git"' "$OUT"
t_contains "write preserves other keys"            '"extra": 1' "$OUT"
t_contains "repo_url=None leaves the existing url" '"repo_url": "u"' "$OUT"

t_done
