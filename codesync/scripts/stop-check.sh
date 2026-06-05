#!/usr/bin/env bash
# stop-check.sh — CodeSync Stop hook (v0.5.0+).
# After every Claude turn, surfaces files in the ACTIVE project's folder
# that have appeared, changed, or disappeared since the last hook run.
# - Silent if CODESYNC_PROJECT is unset (fail-open posture for hooks).
# - Silent if nothing changed.
# - Silent on errors.
# - First run for a given project establishes a baseline without surfacing.
# - Role-filters when CODESYNC_ROLE is set: only surfaces _inbox/<role>/ + _roles/.

CFG_FILE="$HOME/.config/codesync/config.json"

# Silent no-ops if plugin isn't installed or python3 missing
[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, sys

try:
    cfg_path, active_project, active_role = sys.argv[1:4]

    # No project active in this terminal → silent
    if not active_project:
        sys.exit(0)

    with open(cfg_path) as f:
        cfg = json.load(f)

    projects = cfg.get("projects", {})
    project = projects.get(active_project)
    if not project:
        # CODESYNC_PROJECT set but unknown — silent (slash commands will tell user)
        sys.exit(0)

    proj_path = project.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    # Per-project baseline file
    baseline_path = os.path.expanduser(
        f"~/.config/codesync/baseline-{active_project}.json"
    )

    EXCLUDE_DIRS  = {".stfolder", ".stversions"}
    EXCLUDE_FILES = {"README.md"}

    current = {}
    for root, dirs, files in os.walk(proj_path):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in EXCLUDE_DIRS]
        for fn in files:
            if fn.startswith(".") or fn in EXCLUDE_FILES:
                continue
            full = os.path.join(root, fn)
            try:
                current[os.path.relpath(full, proj_path)] = os.path.getmtime(full)
            except OSError:
                pass

    first_run = not os.path.exists(baseline_path)
    baseline = {}
    if not first_run:
        try:
            with open(baseline_path) as f:
                baseline = json.load(f)
        except Exception:
            baseline = {}

    os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
    with open(baseline_path, "w") as f:
        json.dump(current, f, indent=2, sort_keys=True)

    if first_run:
        sys.exit(0)

    new_files = [p for p in current if p not in baseline]
    changed   = [p for p in current if p in baseline and current[p] > baseline[p]]
    deleted   = [p for p in baseline if p not in current]

    # Role-based filtering
    if active_role:
        prefix = f"_inbox/{active_role}/"
        def relevant(p):
            return p.startswith(prefix) or p.startswith("_roles/")
        suppressed = sum(1 for ps in (new_files, changed, deleted) for p in ps if not relevant(p))
        new_files = [p for p in new_files if relevant(p)]
        changed   = [p for p in changed   if relevant(p)]
        deleted   = [p for p in deleted   if relevant(p)]
    else:
        suppressed = 0

    items  = [f"+ {p}" for p in sorted(new_files)]
    items += [f"~ {p}" for p in sorted(changed)]
    items += [f"- {p}" for p in sorted(deleted)]

    if not items and suppressed == 0:
        sys.exit(0)

    role_label = f"role={active_role}" if active_role else "no role active"
    header = f"[codesync project={active_project}, {role_label}]"
    if items:
        print()
        print(f"{header} {len(items)} change(s) for you:")
        for line in items[:10]:
            print(f"  {line}")
        if len(items) > 10:
            print(f"  …and {len(items) - 10} more")
        if suppressed and active_role:
            print(f"  ({suppressed} other change(s) outside _inbox/{active_role}/ — not for this role)")
    # else: silent when nothing for us

except Exception:
    pass  # never crash the user's session
PY
