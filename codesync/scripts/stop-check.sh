#!/usr/bin/env bash
# stop-check.sh — CodeSync Stop hook (v0.5.0+).
# After every Claude turn, surfaces files in the ACTIVE project's folder
# that have appeared, changed, or disappeared since the last hook run.
# - Silent if CODESYNC_PROJECT is unset (fail-open posture for hooks).
# - Silent if nothing changed.
# - Silent on errors.
# - First run for a given project establishes a baseline without surfacing.
# - Role-filters by ALL roles registered for this device in the active project
#   (from config.projects.<name>.roles). Falls back to CODESYNC_ROLE if the
#   roles list is empty/missing (backward compat). Then to no filter.

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Silent no-ops if plugin isn't installed or python3 missing
[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

python3 - "$SCRIPT_DIR/lib" "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, sys

try:
    lib_dir, cfg_path, active_project, active_role = sys.argv[1:5]
    sys.path.insert(0, lib_dir)
    from frontmatter import read_frontmatter_from_file  # noqa: E402

    # No project active in this terminal → silent
    if not active_project:
        sys.exit(0)

    with open(cfg_path) as f:
        cfg = json.load(f)

    projects = cfg.get("projects", {})
    project = projects.get(active_project)
    if not project:
        sys.exit(0)

    proj_path = project.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    # Determine which roles to filter by:
    #   1. projects.<name>.roles list (this device's registered roles) — preferred
    #   2. CODESYNC_ROLE env var (backward compat for older configs)
    #   3. None → show all changes unfiltered
    registered_roles = project.get("roles", []) or []
    if registered_roles:
        filter_roles = list(registered_roles)
    elif active_role:
        filter_roles = [active_role]
    else:
        filter_roles = []  # no filter

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

    # Build relevance check: any registered-role inbox/archive, plus _roles/
    if filter_roles:
        inbox_prefixes   = tuple(f"_inbox/{r}/" for r in filter_roles)
        archive_prefixes = tuple(f"_archive/{r}/" for r in filter_roles)
        def relevant(p):
            return (p.startswith(inbox_prefixes)
                    or p.startswith(archive_prefixes)
                    or p.startswith("_roles/"))
        suppressed = sum(1 for ps in (new_files, changed, deleted) for p in ps if not relevant(p))
        new_files = [p for p in new_files if relevant(p)]
        changed   = [p for p in changed   if relevant(p)]
        deleted   = [p for p in deleted   if relevant(p)]
    else:
        suppressed = 0

    # Collapse attachment-file events under their parent thread. When the
    # frontmatter parser later reads the thread's .md, it picks up the
    # updated `attachments:` count, so the user sees one event with
    # [+ N attachments] instead of N+1 separate file lines.
    import re as _re_attach
    _attach_re = _re_attach.compile(r'^(_(?:inbox|archive))/([^/]+)/([^/]+)\.attachments/')
    def _is_attachment(path):
        return bool(_attach_re.match(path))
    def _parent_thread(path):
        m = _attach_re.match(path)
        if not m:
            return None
        root, role, slug = m.groups()
        return f"{root}/{role}/{slug}.md"

    # Track which threads have implicit changes (attachment-only, .md not changed)
    explicit_paths = set(new_files) | set(changed) | set(deleted)
    implicit_threads_changed = set()
    for p in list(new_files) + list(changed) + list(deleted):
        if _is_attachment(p):
            parent = _parent_thread(p)
            if parent and parent not in explicit_paths and os.path.isfile(os.path.join(proj_path, parent)):
                implicit_threads_changed.add(parent)

    # Filter out attachment file paths from the three lists
    new_files = [p for p in new_files if not _is_attachment(p)]
    changed   = [p for p in changed   if not _is_attachment(p)]
    deleted   = [p for p in deleted   if not _is_attachment(p)]

    # Surface implicit thread changes (attachment-only) as additional changes
    for t in sorted(implicit_threads_changed):
        if t not in explicit_paths:
            changed.append(t)

    def label(p):
        is_archive = p.startswith("_archive/")
        # Identify the role this file belongs to (for multi-role surfacing)
        addressed_to = ""
        if p.startswith("_inbox/") or p.startswith("_archive/"):
            parts = p.split("/", 2)
            if len(parts) >= 2:
                addressed_to = parts[1]
        fm = read_frontmatter_from_file(os.path.join(proj_path, p))
        if not fm:
            base = f"[archived] {p}" if is_archive else p
            return f"[→{addressed_to}] {base}" if (addressed_to and len(filter_roles) > 1) else base
        status = fm.get("status", "")
        title  = fm.get("title", "")
        frm    = fm.get("from", "")
        frm_id = fm.get("from-identity", "")
        owner  = fm.get("owner", "")
        attach_raw = fm.get("attachments", "")
        attach_count = len([a for a in attach_raw.split(",") if a.strip()]) if attach_raw else 0
        parts2 = []
        if is_archive: parts2.append("[archived]")
        if addressed_to and len(filter_roles) > 1:
            parts2.append(f"[→{addressed_to}]")
        if status:     parts2.append(f"[{status}]")
        if owner:      parts2.append(f"[owned by {owner}]")
        if title:      parts2.append(title)
        if attach_count: parts2.append(f"[+ {attach_count} attachment{'s' if attach_count != 1 else ''}]")
        if frm and frm_id: parts2.append(f"(from {frm}/{frm_id})")
        elif frm:          parts2.append(f"(from {frm})")
        prefix = " ".join(parts2) if parts2 else ""
        return f"{prefix}  {p}" if prefix else p

    items  = [f"+ {label(p)}" for p in sorted(new_files)]
    items += [f"~ {label(p)}" for p in sorted(changed)]
    items += [f"- {p}" for p in sorted(deleted)]

    if not items and suppressed == 0:
        sys.exit(0)

    if filter_roles:
        if len(filter_roles) == 1:
            role_label = f"role={filter_roles[0]}"
        else:
            role_label = f"roles={','.join(filter_roles)}"
    else:
        role_label = "no role active"
    header = f"[codesync project={active_project}, {role_label}]"
    if items:
        print()
        print(f"{header} {len(items)} change(s) for you:")
        for line in items[:10]:
            print(f"  {line}")
        if len(items) > 10:
            print(f"  …and {len(items) - 10} more")
        if suppressed and filter_roles:
            joined = "/".join(filter_roles)
            print(f"  ({suppressed} other change(s) outside _inbox/{{{joined}}}/ — not for your registered role(s))")

except Exception:
    pass
PY
