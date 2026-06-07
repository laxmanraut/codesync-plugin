#!/usr/bin/env bash
# session-start.sh — CodeSync SessionStart hook (v0.7.0+).
# At the start of every Claude Code session, if CODESYNC_PROJECT is set,
# summarise the user's inbox(es) so they know what's pending without having
# to run a slash command.
#
# - Silent if CODESYNC_PROJECT is unset or unknown.
# - With project + registered roles in config: shows ALL registered roles'
#   inboxes, grouped by role.
# - With project + no registered roles but CODESYNC_ROLE env var set:
#   backward-compat path — shows just that role's inbox.
# - With project + neither: nudges user to register a role.
# - Silent if every inbox is empty.
# - Silent on errors.

CFG_FILE="$HOME/.config/codesync/config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Populate CODESYNC_PROJECT/ROLE from env or .codesync/project.json walk-up
. "$SCRIPT_DIR/lib/load-env.sh"

python3 - "$SCRIPT_DIR/lib" "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, sys, time

try:
    lib_dir, cfg_path, active_project, active_role = sys.argv[1:5]
    sys.path.insert(0, lib_dir)
    from frontmatter import read_frontmatter_from_file

    # No project active in this terminal → silent
    if not active_project:
        sys.exit(0)

    with open(cfg_path) as f:
        cfg = json.load(f)

    project = cfg.get("projects", {}).get(active_project)
    if not project:
        # CODESYNC_PROJECT set but unknown — silent
        sys.exit(0)

    proj_path = project.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    # Determine which roles to show inboxes for:
    #   1. projects.<name>.roles (this device's registered roles) — preferred
    #   2. CODESYNC_ROLE env var (backward compat)
    #   3. Neither → nudge to register a role
    registered = project.get("roles", []) or []
    if registered:
        roles_to_show = list(registered)
        source = "registered"
    elif active_role:
        roles_to_show = [active_role]
        source = "env"
    else:
        print()
        print(f"[codesync] Project '{active_project}' active, but no roles registered on this device.")
        print(f"           Run /codesync-role-new to register a role, or export CODESYNC_ROLE=<name>")
        print(f"           in your shell if you want to use a role that's already registered elsewhere.")
        sys.exit(0)

    def short_age(ts):
        try:
            age = time.time() - ts
            if age < 60:    return f"{int(age)}s ago"
            if age < 3600:  return f"{int(age // 60)}m ago"
            if age < 86400: return f"{int(age // 3600)}h ago"
            return f"{int(age // 86400)}d ago"
        except Exception:
            return "?"

    STATUS_PRI = {"todo": 0, "wip": 1, "blocked": 2, "note": 3, "done": 4, "(no-fm)": 5, "": 5}

    def scan_inbox(role):
        inbox_path = os.path.join(proj_path, "_inbox", role)
        if not os.path.isdir(inbox_path):
            return []
        entries = []
        for fn in sorted(os.listdir(inbox_path)):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(inbox_path, fn)
            fm = read_frontmatter_from_file(full) or {}
            try:
                mtime = os.path.getmtime(full)
            except OSError:
                mtime = 0
            entries.append({
                "file":   fn,
                "status": fm.get("status", ""),
                "title":  fm.get("title", "") or fn[:-3],
                "from":   fm.get("from", ""),
                "mtime":  mtime,
                "age":    short_age(mtime),
            })
        entries.sort(key=lambda e: (STATUS_PRI.get(e["status"] or "(no-fm)", 5), -e["mtime"]))
        return entries

    # Scan each role's inbox
    per_role = {role: scan_inbox(role) for role in roles_to_show}
    total = sum(len(es) for es in per_role.values())

    # Scan project docs (separate from inbox; surfaces even with empty inbox)
    import re as _re
    docs_dir = os.path.join(proj_path, "_docs")
    doc_files = []
    if os.path.isdir(docs_dir):
        for fn in sorted(os.listdir(docs_dir)):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(docs_dir, fn)
            if not os.path.isfile(full):
                continue
            heading = None
            try:
                with open(full) as f:
                    for line in f:
                        m = _re.match(r'^#\s+(.*)', line.rstrip())
                        if m:
                            heading = m.group(1).strip()
                            break
                        if line.strip() and not line.startswith('#'):
                            break
            except OSError:
                pass
            doc_files.append((fn, heading))

    # Determine whether we'll need to inject CLAUDE.md (only when cwd isn't
    # inside the synced project folder — otherwise native loading covers it).
    cwd_real = os.path.realpath(os.getcwd())
    proj_real = os.path.realpath(proj_path)
    cwd_is_inside_project = (
        cwd_real == proj_real or cwd_real.startswith(proj_real + os.sep)
    )
    claude_md_path = os.path.join(proj_path, "CLAUDE.md")
    will_inject_claude_md = (
        os.path.isfile(claude_md_path) and not cwd_is_inside_project
    )

    # Silent only if inbox empty AND no docs AND no CLAUDE.md to inject
    if total == 0 and not doc_files and not will_inject_claude_md:
        sys.exit(0)

    # Header
    if len(roles_to_show) == 1:
        roles_label = f"Role: {roles_to_show[0]}"
    else:
        roles_label = f"Roles: {', '.join(roles_to_show)}"
    print()
    print(f"[codesync] Project: {active_project}  {roles_label}")

    # Per-role section
    for role in roles_to_show:
        entries = per_role[role]
        if not entries:
            continue
        counts = {}
        for e in entries:
            s = e["status"] or "(no-fm)"
            counts[s] = counts.get(s, 0) + 1
        order = ["todo", "wip", "blocked", "note", "done", "(no-fm)"]
        parts = []
        for s in order:
            if counts.get(s):
                parts.append(f"{counts[s]} {s}")
        counts_str = ", ".join(parts) if parts else f"{len(entries)} items"

        if len(roles_to_show) > 1:
            print()
            print(f"  Inbox ({role}): {counts_str}")
        else:
            print(f"  Inbox: {counts_str}")
            print()

        # Top items for this role
        per_role_top = 5 if len(roles_to_show) == 1 else 3
        top = entries[:per_role_top]
        for e in top:
            tag = f"[{e['status'] or 'no-fm'}]".ljust(10)
            title = e["title"]
            if len(title) > 50:
                title = title[:47] + "..."
            from_str = f"from {e['from']}" if e["from"] else "no from"
            print(f"    {tag} {title} ({from_str}, {e['age']})")
        if len(entries) > per_role_top:
            print(f"    …and {len(entries) - per_role_top} more")

    if total > 0:
        print()
        print("  Run /codesync-thread-list to see them, or /codesync-thread-reply <slug> to respond.")

    # Surface project docs index (already scanned above)
    if doc_files:
        print()
        print(f"  Project docs ({len(doc_files)}) — read any with Claude when relevant:")
        name_w = max(8, max(len(fn) for fn, _ in doc_files))
        for fn, heading in doc_files:
            if heading:
                print(f"    - {fn:<{name_w}}  — {heading}")
            else:
                print(f"    - {fn}")
        print("  (Run /codesync-doc-list for details.)")

    # Inject project CLAUDE.md content as fallback context.
    # Native Claude Code CLAUDE.md loading only walks UP from cwd. For users
    # whose cwd is OUTSIDE the synced project folder (e.g. ~/code/<app>/),
    # the synced CLAUDE.md at <proj_path>/CLAUDE.md is invisible to the
    # native loader. We surface it here so it ends up in session context
    # regardless of cwd. Skip when cwd is inside proj_path (native loading
    # is already handling it) to avoid duplicate context.
    if will_inject_claude_md:
        try:
            with open(claude_md_path) as f:
                claude_content = f.read().rstrip()
        except OSError:
            claude_content = ""
        if claude_content:
            print()
            print(f"  ─── Project CLAUDE.md (from {claude_md_path}) ───")
            print("  (auto-included because your cwd isn't inside the synced project folder;")
            print("   treat as if Claude Code had loaded it natively)")
            print()
            for line in claude_content.splitlines():
                print(f"  {line}" if line else "")
            print()
            print("  ─── end CLAUDE.md ───")

except Exception:
    pass  # never let the hook break a session start
PY
