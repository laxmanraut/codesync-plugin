#!/usr/bin/env bash
# stop-check.sh — CodeSync Stop hook.
# After every Claude turn, surfaces files that have appeared, changed, or
# disappeared in the synced contracts folder since the last hook run.
# - Quiet when nothing changed.
# - Silent on errors (never breaks the user's session).
# - First run establishes a baseline without surfacing anything.

CFG_FILE="$HOME/.config/codesync/config.json"
BASELINE_FILE="$HOME/.config/codesync/baseline.json"

# Silently no-op if plugin isn't installed or python3 isn't available
[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$CFG_FILE" "$BASELINE_FILE" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, sys

try:
    cfg_path, baseline_path, active_role = sys.argv[1:4]

    with open(cfg_path) as f:
        cfg = json.load(f)
    contracts = cfg.get("contracts_dir", "")
    if not contracts or not os.path.isdir(contracts):
        sys.exit(0)

    EXCLUDE_DIRS  = {".stfolder", ".stversions"}
    EXCLUDE_FILES = {"README.md"}

    # Walk contracts/ and collect (relative_path → mtime) for files we care about.
    current = {}
    for root, dirs, files in os.walk(contracts):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in EXCLUDE_DIRS]
        for fn in files:
            if fn.startswith(".") or fn in EXCLUDE_FILES:
                continue
            full = os.path.join(root, fn)
            try:
                current[os.path.relpath(full, contracts)] = os.path.getmtime(full)
            except OSError:
                pass

    first_run = not os.path.exists(baseline_path)
    baseline  = {}
    if not first_run:
        try:
            with open(baseline_path) as f:
                baseline = json.load(f)
        except Exception:
            baseline = {}

    # Always update baseline so we don't re-surface the same items
    os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
    with open(baseline_path, "w") as f:
        json.dump(current, f, indent=2, sort_keys=True)

    # On first run, just establish the baseline silently
    if first_run:
        sys.exit(0)

    new_files = [p for p in current if p not in baseline]
    changed   = [p for p in current if p in baseline and current[p] > baseline[p]]
    deleted   = [p for p in baseline if p not in current]

    # Role-based filtering: when CODESYNC_ROLE is set, only surface paths under
    # _inbox/<role>/ and _roles/. When unset, surface everything (today's behaviour).
    # Files outside the role's inbox are still tracked in the baseline so they
    # don't re-surface when the role is unset later.
    if active_role:
        prefix_inbox = f"_inbox/{active_role}/"
        def relevant(p):
            return p.startswith(prefix_inbox) or p.startswith("_roles/")
        suppressed_count = (
            sum(1 for p in new_files if not relevant(p))
            + sum(1 for p in changed if not relevant(p))
            + sum(1 for p in deleted if not relevant(p))
        )
        new_files = [p for p in new_files if relevant(p)]
        changed   = [p for p in changed   if relevant(p)]
        deleted   = [p for p in deleted   if relevant(p)]
    else:
        suppressed_count = 0

    items = []
    items += [f"+ {p}" for p in sorted(new_files)]
    items += [f"~ {p}" for p in sorted(changed)]
    items += [f"- {p}" for p in sorted(deleted)]

    if not items and suppressed_count == 0:
        sys.exit(0)

    role_label = f"role={active_role}" if active_role else "no role active in this terminal"
    if items:
        print()
        print(f"[codesync] {len(items)} change(s) for you in the shared contracts folder ({role_label}):")
        for line in items[:10]:
            print(f"  {line}")
        if len(items) > 10:
            print(f"  …and {len(items) - 10} more")
        if suppressed_count:
            print(f"  ({suppressed_count} other change(s) outside _inbox/{active_role}/ — not for this role)")
    elif suppressed_count:
        # Silent unless we want a heartbeat; for now stay quiet when nothing is for us.
        sys.exit(0)
except Exception:
    pass  # never let the hook crash the user's session
PY
