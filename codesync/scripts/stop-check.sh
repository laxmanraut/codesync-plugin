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

# Silent no-ops if plugin isn't installed or $PY_BIN missing
[ -f "$CFG_FILE" ] || exit 0

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"
[ -n "${PY_BIN:-}" ] || exit 0

SEEN_LOG="$HOME/.config/codesync/seen-${CODESYNC_PROJECT:-none}.log"
BASELINE_FILE="$HOME/.config/codesync/baseline-${CODESYNC_PROJECT:-none}.json"

$PY_BIN - "$SCRIPT_DIR/lib" "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" "$SEEN_LOG" "$BASELINE_FILE" <<'PY' 2>/dev/null
import json, os, sys, time

try:
    # All paths arrive as argv (MSYS converts argv for native python.exe;
    # Python-side expanduser would resolve USERPROFILE, not bash's $HOME).
    lib_dir, cfg_path, active_project, active_role, seen_log, baseline_path = sys.argv[1:7]
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
        gen_by = fm.get("generated-by", "")
        parts2 = []
        if is_archive: parts2.append("[archived]")
        if gen_by == "auto": parts2.append("[auto]")
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

    def body_preview(rel_path, maxlen=110):
        """Return first non-empty non-heading line of the body, capped."""
        try:
            full = os.path.join(proj_path, rel_path)
            with open(full) as f:
                content = f.read()
            # Strip a leading YAML frontmatter block if present
            import re as _re_bp
            m = _re_bp.match(r'\A---\s*\n.*?\n---\s*\n', content, _re_bp.DOTALL)
            body = content[m.end():] if m else content
            for line in body.splitlines():
                stripped = line.strip()
                if not stripped or stripped.startswith('#'):
                    continue
                # Collapse any internal whitespace
                stripped = ' '.join(stripped.split())
                if len(stripped) > maxlen:
                    return stripped[:maxlen - 1] + '…'
                return stripped
            return ''
        except Exception:
            return ''

    # Build items as (display_line, optional_preview). Previews only for files
    # that still exist (i.e., new or changed — not deleted).
    items = []  # list of tuples (line, preview or None)
    for p in sorted(new_files):
        items.append((f"+ {label(p)}", body_preview(p)))
    for p in sorted(changed):
        items.append((f"~ {label(p)}", body_preview(p)))
    for p in sorted(deleted):
        items.append((f"- {p}", None))

    # First-seen log (shared with status-line.sh): when this hook surfaces a
    # thread for the first time, record slug + timestamp. This is BOTH the
    # cross-session notification dedup (OV12 — a thread surfaced here won't
    # re-toast from the status line) and the wedge instrumentation (OV7 —
    # time-to-notice = inbox-file mtime → seen-log timestamp).
    if seen_log and active_project:
        seen = set()
        if os.path.exists(seen_log):
            try:
                with open(seen_log) as f:
                    seen = {l.split("\t")[0] for l in f if l.strip()}
            except Exception:
                seen = set()
        surfaced = [p for p in list(new_files) + list(changed)
                    if p.startswith("_inbox/") and p.endswith(".md") and p not in seen]
        if surfaced:
            stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            try:
                fd = os.open(seen_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                with os.fdopen(fd, "a") as f:
                    for p in surfaced:
                        f.write(f"{p}\t{stamp}\n")
            except Exception:
                pass

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
        for line, preview in items[:10]:
            print(f"  {line}")
            if preview:
                print(f'      > "{preview}"')
        if len(items) > 10:
            print(f"  …and {len(items) - 10} more")
        if suppressed and filter_roles:
            joined = "/".join(filter_roles)
            print(f"  ({suppressed} other change(s) outside _inbox/{{{joined}}}/ — not for your registered role(s))")

except Exception:
    pass
PY
