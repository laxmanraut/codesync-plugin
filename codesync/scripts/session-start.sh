#!/usr/bin/env bash
# session-start.sh — CodeSync SessionStart hook (v0.7.0+).
# At the start of every Claude Code session, if CODESYNC_PROJECT is set,
# summarise the user's inbox so they know what's pending without having
# to run a slash command.
#
# - Silent if CODESYNC_PROJECT is unset or unknown (matches Stop hook's
#   fail-open posture; no nagging for unrelated terminals).
# - With project but no role: prompts user to set CODESYNC_ROLE.
# - With project + role: prints counts by status, lists top items.
# - Silent if the inbox has no items.
# - Silent on errors.

CFG_FILE="$HOME/.config/codesync/config.json"

[ -f "$CFG_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$CFG_FILE" "${CODESYNC_PROJECT:-}" "${CODESYNC_ROLE:-}" <<'PY' 2>/dev/null
import json, os, re, sys, time

try:
    cfg_path, active_project, active_role = sys.argv[1:4]

    # No project active in this terminal → silent
    if not active_project:
        sys.exit(0)

    with open(cfg_path) as f:
        cfg = json.load(f)

    project = cfg.get("projects", {}).get(active_project)
    if not project:
        # CODESYNC_PROJECT set but unknown — silent (other surfaces will alert)
        sys.exit(0)

    proj_path = project.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        sys.exit(0)

    # Project set but no role — nudge but don't error
    if not active_role:
        print()
        print(f"[codesync] Project '{active_project}' active in this terminal, but CODESYNC_ROLE is not set.")
        print(f"           Set it in your shell (e.g. export CODESYNC_ROLE=backend) to see your inbox.")
        sys.exit(0)

    inbox_path = os.path.join(proj_path, "_inbox", active_role)
    if not os.path.isdir(inbox_path):
        # Inbox dir doesn't exist yet — silent
        sys.exit(0)

    # Frontmatter parser — same logic as list-threads.sh / stop-check.sh
    FM_RE = re.compile(r'\A---\s*\n(.*?)\n---', re.DOTALL)
    def parse_fm(path):
        try:
            with open(path) as f:
                head = f.read(4096)
        except OSError:
            return None
        m = FM_RE.match(head)
        if not m:
            return None
        in_cs = False
        fm = {}
        for line in m.group(1).splitlines():
            stripped = line.rstrip()
            if stripped == "":
                continue
            if stripped == "codesync:":
                in_cs = True
                continue
            if in_cs and stripped.startswith("  "):
                kv = stripped[2:]
                if ":" in kv:
                    k, v = kv.split(":", 1)
                    fm[k.strip()] = v.strip().strip('"').strip("'")
            else:
                in_cs = False
        return fm if fm else None

    def short_age(ts):
        try:
            age = time.time() - ts
            if age < 60:    return f"{int(age)}s ago"
            if age < 3600:  return f"{int(age // 60)}m ago"
            if age < 86400: return f"{int(age // 3600)}h ago"
            return f"{int(age // 86400)}d ago"
        except Exception:
            return "?"

    # Scan inbox
    entries = []
    for fn in sorted(os.listdir(inbox_path)):
        if not fn.endswith(".md") or fn == "README.md":
            continue
        full = os.path.join(inbox_path, fn)
        fm = parse_fm(full) or {}
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
            "has_fm": bool(fm),
        })

    if not entries:
        # Empty inbox — silent
        sys.exit(0)

    # Tally counts by status
    counts = {}
    for e in entries:
        s = e["status"] or "(no-fm)"
        counts[s] = counts.get(s, 0) + 1

    # Build the summary line
    order = ["todo", "wip", "blocked", "note", "done", "(no-fm)"]
    parts = []
    for s in order:
        if counts.get(s):
            parts.append(f"{counts[s]} {s}")
    counts_str = ", ".join(parts) if parts else f"{len(entries)} items"

    print()
    print(f"[codesync] Project: {active_project}  Role: {active_role}")
    print(f"  Inbox: {counts_str}")

    # Show top items sorted by status priority then recency
    STATUS_PRI = {"todo": 0, "wip": 1, "blocked": 2, "note": 3, "done": 4, "(no-fm)": 5, "": 5}
    entries.sort(key=lambda e: (STATUS_PRI.get(e["status"] or "(no-fm)", 5), -e["mtime"]))

    top = entries[:5]
    if top:
        print()
        for e in top:
            tag = f"[{e['status'] or 'no-fm'}]".ljust(10)
            title = e["title"]
            if len(title) > 50:
                title = title[:47] + "..."
            from_str = f"from {e['from']}" if e["from"] else "no from"
            print(f"    {tag} {title} ({from_str}, {e['age']})")
        if len(entries) > 5:
            print(f"    …and {len(entries) - 5} more")

    print()
    print("  Run /codesync-thread-list to see them, or /codesync-thread-reply <slug> to respond.")

except Exception:
    pass  # never let the hook break a session start
PY
