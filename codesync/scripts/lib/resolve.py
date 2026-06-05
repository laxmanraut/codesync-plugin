"""Resolve the active CODESYNC_PROJECT and CODESYNC_ROLE for this shell.

Precedence (env var wins, marker file is the fallback):
1. $CODESYNC_PROJECT / $CODESYNC_ROLE if set in the environment.
2. Walk up from current working directory looking for `.codesync/project.json`.
   That file may declare `project` (required to be useful) and `default_role`
   (optional — only applied when CODESYNC_ROLE is unset).

Stops walking up at the user's home directory or the filesystem root.

Outputs are KEY=VALUE shell-eval-able lines on stdout, e.g.:

    CODESYNC_PROJECT='lead_inbox'
    CODESYNC_ROLE='backend'

Callers (bash scripts) do `eval "$(python3 resolve.py)"` to set these vars
locally — does not modify the parent shell.
"""
import json
import os
import shlex
import sys


MARKER_RELPATH = ".codesync/project.json"


def find_marker(start_path):
    """Walk up from `start_path` looking for the marker file.

    Stops at the user's home directory or filesystem root (whichever comes
    first). Returns absolute path to the marker, or None.
    """
    path = os.path.abspath(start_path)
    home = os.path.expanduser("~")
    while path and path != "/" and path != home:
        marker = os.path.join(path, MARKER_RELPATH)
        if os.path.isfile(marker):
            return marker
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return None


def load_marker(path):
    """Load and parse a marker file. Returns dict or {} on any error."""
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def resolve():
    """Compute (project, role) using env-then-marker precedence."""
    project = os.environ.get("CODESYNC_PROJECT", "").strip()
    role = os.environ.get("CODESYNC_ROLE", "").strip()

    if not project or not role:
        marker = find_marker(os.getcwd())
        if marker:
            data = load_marker(marker)
            if not project:
                project = str(data.get("project", "")).strip()
            if not role:
                role = str(data.get("default_role", "")).strip()

    return project, role


def main():
    project, role = resolve()
    # Always emit both lines so shell scripts can rely on the var being set
    # (possibly to empty string).
    print(f"CODESYNC_PROJECT={shlex.quote(project)}")
    print(f"CODESYNC_ROLE={shlex.quote(role)}")


if __name__ == "__main__":
    main()
