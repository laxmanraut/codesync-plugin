"""state.py — single source of truth for codesync's machine + project state.

Everything the dashboard server and the status/session-start scripts need to
*know* (as opposed to *format*) lives here, returned as plain dicts/lists so it
serialises straight to JSON. One implementation, unit-testable, no duplication
across the six scripts that used to scan inboxes independently (eng-review R1).

Design rules:
  - Pure data. No printing, no formatting, no sys.exit. Callers format.
  - Syncthing calls fail SOFT: on any error they return a sentinel
    (syncthing_ok=False / empty lists), never raise. The dashboard must render
    filesystem panels even when Syncthing is down (eng-review T7).
  - Untrusted strings (peer-chosen device names, thread fields) are returned
    raw; the *renderer* escapes. The one exception is pending-device names,
    which are sanitised here because they are matched against a strict ID
    format and surfaced as a security-sensitive banner (v0.23.1 hardening).

Usage:
    import state
    cfg = state.load_config(cfg_path)
    overview = state.gather_overview(cfg)
    peers    = state.gather_peers(cfg, project_name)
    pending  = state.gather_pending(cfg)
    threads  = state.gather_threads(cfg, project_name, roles)
    activity = state.gather_activity(cfg, project_name)
"""
import json
import os
import re
import time
import urllib.error
import urllib.request

API_BASE = "http://127.0.0.1:8384"

# Strict Syncthing device-ID shape: 8 dash-separated groups of 7 base32 chars.
_ID_RE = re.compile(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$')

# Project / role name shape (matches codesync-role-new.md + create-project.sh):
# lowercase start, then lowercase/digit/dash/underscore. No shell metacharacters,
# so a validated name is safe to interpolate into a launched command's env.
_NAME_RE = re.compile(r'^[a-z0-9][a-z0-9_-]*$')

# Thread sort: surface actionable items first (matches session-start.sh).
_STATUS_PRI = {"todo": 0, "wip": 1, "blocked": 2, "note": 3, "done": 4,
               "(no-fm)": 5, "": 5}


# ─────────────────────────────── config ────────────────────────────────────
def load_config(cfg_path):
    """Load ~/.config/codesync/config.json. Returns {} on any error."""
    try:
        with open(cfg_path) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except Exception:
        return {}


def _api_key(cfg):
    return cfg.get("syncthing_api_key", "") or ""


# ─────────────────────────── small helpers ─────────────────────────────────
def short_age(ts, now=None):
    """Human 'time ago' for an epoch mtime. Matches session-start.sh wording."""
    try:
        now = time.time() if now is None else now
        age = now - ts
        if age < 0:
            age = 0
        if age < 60:
            return f"{int(age)}s ago"
        if age < 3600:
            return f"{int(age // 60)}m ago"
        if age < 86400:
            return f"{int(age // 3600)}h ago"
        return f"{int(age // 86400)}d ago"
    except Exception:
        return "?"


def _sanitize(s, n=60):
    """Neutralise control chars / markup in untrusted strings (peer names)."""
    return re.sub(r'[^A-Za-z0-9 ._:@/-]', '?', str(s))[:n]


def _syncthing_get(cfg, path, timeout=4):
    """GET a Syncthing REST path. Returns parsed JSON, or None on ANY failure.

    None is the graceful-degradation signal: callers render a 'Syncthing
    offline' state rather than erroring (T7).
    """
    key = _api_key(cfg)
    if not key:
        return None
    try:
        req = urllib.request.Request(f"{API_BASE}{path}",
                                     headers={"X-API-Key": key})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def syncthing_reachable(cfg):
    return _syncthing_get(cfg, "/rest/system/status", timeout=3) is not None


# ─────────────────────────────── overview ──────────────────────────────────
def gather_overview(cfg):
    """Identity, device id, and every project registered on this machine.

    Pure filesystem/config read — never touches Syncthing, so it always works.
    """
    projects = []
    for name, p in sorted((cfg.get("projects") or {}).items()):
        path = p.get("path", "")
        projects.append({
            "name": name,
            "path": path,
            "folder_id": p.get("folder_id", ""),
            "roles": list(p.get("roles", []) or []),
            "exists": bool(path) and os.path.isdir(path),
        })
    return {
        "identity": cfg.get("identity", "") or "",
        "device_id": cfg.get("device_id", "") or "",
        "projects": projects,
    }


# ──────────────────────────────── peers ────────────────────────────────────
def gather_peers(cfg, project_name):
    """Peers attached to one project's Syncthing folder.

    Mirrors status.sh's peer block. Returns {syncthing_ok, peers:[...]}.
    syncthing_ok=False means the daemon is unreachable; peers will be empty
    and the caller should show an offline state, not 'no peers'.
    """
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return {"syncthing_ok": syncthing_reachable(cfg), "peers": []}
    folder_id = proj.get("folder_id", "")
    self_id = cfg.get("device_id", "")

    folder = _syncthing_get(cfg, f"/rest/config/folders/{folder_id}")
    if folder is None:
        return {"syncthing_ok": False, "peers": []}

    folder_devs = [d.get("deviceID") for d in folder.get("devices", [])
                   if d.get("deviceID") and d.get("deviceID") != self_id]
    conns = (_syncthing_get(cfg, "/rest/system/connections") or {}).get("connections", {})
    all_devs_list = _syncthing_get(cfg, "/rest/config/devices") or []
    all_devs = {d.get("deviceID"): d for d in all_devs_list if isinstance(d, dict)}

    peers = []
    for pid in sorted(folder_devs):
        d = all_devs.get(pid, {})
        c = conns.get(pid, {})
        connected = bool(c.get("connected"))
        peers.append({
            "id": pid,
            "id_short": pid[:7],
            "name": _sanitize(d.get("name") or "(unnamed)"),
            "connected": connected,
            "address": _sanitize(c.get("address", "") or "", 40) if connected else "",
        })
    return {"syncthing_ok": True, "peers": peers}


def gather_folder_status(cfg, project_name):
    """Sync state for a project's folder (state/local/global/need)."""
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return {"syncthing_ok": False}
    fstat = _syncthing_get(cfg, f"/rest/db/status?folder={proj.get('folder_id','')}")
    if fstat is None:
        return {"syncthing_ok": False}
    return {
        "syncthing_ok": True,
        "state": fstat.get("state", "?"),
        "local_files": fstat.get("localFiles", 0),
        "global_files": fstat.get("globalFiles", 0),
        "need_files": fstat.get("needFiles", 0),
    }


# ────────────────────────────── pending ────────────────────────────────────
def sanitize_pending(pending):
    """Validate + sanitise a raw Syncthing pending-devices dict → list of
    {id, name, time}.

    The SINGLE SOURCE for the v0.23.1 hardening (strict ID format + name
    sanitisation), shared by gather_pending (urllib fetch) AND the status.sh /
    session-start.sh banners (curl fetch) so this logic can't drift across the
    three places it used to be copied into (eng-review R1). Fetch stays where
    each caller had it; only the parsing/sanitising is consolidated here.
    """
    if not isinstance(pending, dict):
        return []
    out = []
    for dev_id, info in pending.items():
        if not _ID_RE.match(str(dev_id)):
            continue
        info = info or {}
        out.append({
            "id": dev_id,
            "name": _sanitize(info.get("name", "") or "unnamed device", 40),
            "time": _sanitize(info.get("time", ""), 25),
        })
    return out


def gather_pending(cfg):
    """Incoming pairing requests (devices that added us, waiting for accept).
    Returns [] when none / offline. Sanitisation lives in sanitize_pending."""
    return sanitize_pending(_syncthing_get(cfg, "/rest/cluster/pending/devices"))


# ────────────────────────────── threads ────────────────────────────────────
def _frontmatter(path):
    """Local copy of the frontmatter read used by gather_threads.

    state.py is imported from the lib/ dir, so frontmatter is a sibling module.
    """
    try:
        from frontmatter import read_frontmatter_from_file
        return read_frontmatter_from_file(path)
    except Exception:
        return None


def gather_threads(cfg, project_name, roles=None, now=None):
    """Threads across the given roles' inboxes, sorted actionable-first.

    Consolidates session-start.sh's scan_inbox (the thread-enumeration logic
    that does NOT live in status.sh — eng-review C2). `roles` defaults to the
    project's registered roles; pass an explicit list to scope it.
    """
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return []
    proj_path = proj.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        return []
    if roles is None:
        roles = list(proj.get("roles", []) or [])

    out = []
    for role in roles:
        inbox = os.path.join(proj_path, "_inbox", role)
        if not os.path.isdir(inbox):
            continue
        for fn in sorted(os.listdir(inbox)):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(inbox, fn)
            fm = _frontmatter(full) or {}
            try:
                mtime = os.path.getmtime(full)
            except OSError:
                mtime = 0
            attach_raw = fm.get("attachments", "")
            attach_count = len([a for a in attach_raw.split(",") if a.strip()]) if attach_raw else 0
            out.append({
                "role": role,
                "file": fn,
                "slug": fn[:-3],
                "status": fm.get("status", ""),
                "title": fm.get("title", "") or fn[:-3],
                "from": fm.get("from", ""),
                "from_identity": fm.get("from-identity", ""),
                "owner": fm.get("owner", ""),
                "generated_by": fm.get("generated-by", ""),
                "attach_count": attach_count,
                "mtime": mtime,
                "age": short_age(mtime, now),
            })
    out.sort(key=lambda e: (_STATUS_PRI.get(e["status"] or "(no-fm)", 5), -e["mtime"]))
    return out


# ────────────────────────────── activity ───────────────────────────────────
def gather_activity(cfg, project_name, config_dir=None, now=None):
    """Time-to-notice metric from the shared first-seen log (OV7).

    Each seen-log line is 'rel<TAB>ISO-timestamp' = when a thread was first
    surfaced. We pair each against the thread file's mtime (arrival time) to
    get a per-thread notice latency, then summarise. Empty until handoffs flow.

    `config_dir` is where seen-*.log lives (the config.json directory). It is
    passed explicitly because Python's expanduser('~') resolves USERPROFILE on
    Windows, NOT bash's $HOME — the v0.22.x path-staleness lesson. Falls back
    to expanduser only when not supplied (real single-user runs).
    """
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return {"samples": 0, "median_seconds": None, "recent": []}
    proj_path = proj.get("path", "")
    if config_dir:
        seen_log = os.path.join(config_dir, f"seen-{project_name}.log")
    else:
        seen_log = os.path.expanduser(f"~/.config/codesync/seen-{project_name}.log")
    if not os.path.exists(seen_log):
        return {"samples": 0, "median_seconds": None, "recent": []}

    latencies = []
    recent = []
    try:
        with open(seen_log) as f:
            lines = [l.rstrip("\n") for l in f if l.strip()]
    except Exception:
        lines = []
    for line in lines:
        parts = line.split("\t")
        rel = parts[0] if parts else ""
        seen_iso = parts[1] if len(parts) > 1 else ""
        if not rel:
            continue
        full = os.path.join(proj_path, rel)
        try:
            arrived = os.path.getmtime(full)
        except OSError:
            arrived = None
        seen_epoch = _iso_to_epoch(seen_iso)
        latency = None
        if arrived is not None and seen_epoch is not None:
            latency = max(0, seen_epoch - arrived)
            latencies.append(latency)
        recent.append({"thread": rel, "seen": seen_iso, "latency_seconds": latency})

    median = None
    if latencies:
        s = sorted(latencies)
        mid = len(s) // 2
        median = s[mid] if len(s) % 2 else (s[mid - 1] + s[mid]) / 2
    recent = recent[-10:][::-1]  # newest first, capped
    return {"samples": len(latencies), "median_seconds": median, "recent": recent}


def _iso_to_epoch(s):
    """Parse the seen-log's '%Y-%m-%dT%H:%M:%SZ' UTC stamp to epoch seconds."""
    try:
        t = time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        return calendar_timegm(t)
    except Exception:
        return None


def calendar_timegm(t):
    """timegm without importing calendar at module top (kept explicit)."""
    import calendar
    return calendar.timegm(t)


# ──────────────── first-seen scan (watcher + status-line share) ─────────────
# The notification contract: a thread addressed to one of THIS machine's roles
# fires exactly one notification, ever — deduped via the shared, slug-keyed
# seen-<project>.log. status-line.sh / stop-check.sh do this inline while a
# Claude session is open. The always-on watcher (watch-inbox.sh) calls the two
# functions below so the SAME notice happens with NO session open, writing the
# SAME seen-log — so opening Claude later does not re-notify, and time-to-notice
# (gather_activity) reflects the watcher's faster notice.
#
#   arrival (Syncthing)              find_unseen_threads()        mark_threads_seen()
#   _inbox/<role>/x.md  ──────────►  rel not in seen-log?  ─yes─►  append rel<TAB>now
#        (file mtime)                                                      │
#                                                                          ▼
#                                            caller fires ONE codesync_notify(count)
#
# R1-continuation (deferred, NOT this change): migrate the two hooks onto these
# too. They are latency-sensitive and golden-tested, so that move gets its own
# before/after golden diff rather than riding along here.

def _scan_dirs(proj_path, registered, active_role=None):
    """Inbox dirs to scan: registered roles, else the active role, else all.

    Mirrors status-line.sh exactly so the watcher notifies for precisely what
    the statusline would have. Returns absolute dir paths (existence unchecked).
    """
    inbox_root = os.path.join(proj_path, "_inbox")
    if registered:
        return [os.path.join(inbox_root, r) for r in registered]
    if active_role:
        return [os.path.join(inbox_root, active_role)]
    if not os.path.isdir(inbox_root):
        return []
    return [os.path.join(inbox_root, d) for d in sorted(os.listdir(inbox_root))
            if os.path.isdir(os.path.join(inbox_root, d))]


def find_unseen_threads(cfg, project_name, config_dir=None, active_role=None):
    """Threads in this machine's role inboxes not yet in the seen-log.

    Pure read (no write). Returns dicts {rel, role, title, mtime}, newest first.
    `rel` is forward-slash POSIX (never a backslash) so the seen-log key space
    does not fork per platform (v0.22.x lesson). The caller marks them via
    mark_threads_seen and fires the notification.
    """
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return []
    proj_path = proj.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        return []
    seen = _seen_map(config_dir, project_name)
    registered = proj.get("roles", []) or []
    out = []
    for d in _scan_dirs(proj_path, registered, active_role):
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            if not fn.endswith(".md") or fn == "README.md":
                continue
            full = os.path.join(d, fn)
            rel = os.path.relpath(full, proj_path).replace(os.sep, "/")
            if rel in seen:
                continue
            try:
                mtime = os.path.getmtime(full)
            except OSError:
                mtime = 0
            fm = _frontmatter(full) or {}
            out.append({"rel": rel, "role": os.path.basename(d),
                        "title": fm.get("title", "") or fn[:-3], "mtime": mtime})
    out.sort(key=lambda e: -e["mtime"])
    return out


def mark_threads_seen(config_dir, project_name, rels, now=None):
    """Append rels to seen-<project>.log as first-seen. Returns the count written.

    The ONE writer in state.py (the gather_* family is read-only — this is the
    documented exception). Mirrors status-line.sh's inline append: O_APPEND,
    mode 0600, slug-keyed. A same-instant double-append from two writers is
    harmless — every reader dedups on the rel key, so duplicate lines collapse.
    """
    rels = [r for r in (rels or []) if r]
    if not rels:
        return 0
    if config_dir:
        path = os.path.join(config_dir, f"seen-{project_name}.log")
    else:
        path = os.path.expanduser(f"~/.config/codesync/seen-{project_name}.log")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ",
                          time.gmtime(now) if now is not None else time.gmtime())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            for rel in rels:
                f.write(f"{rel}\t{stamp}\n")
    except Exception:
        return 0
    return len(rels)


# ─────────────── conflict-overlap heuristic (launch-agents 3A) ──────────────
# The deterministic slice of the role conflict check that a model-less server
# CAN do: flag when a new role's Owns shares a significant keyword with an
# existing role's Owns. Crude and NON-blocking by design — the semantic-
# duplicate and responsibility-overlap judgments still need /codesync-role-new
# (a model in the loop). Tuned (stopwords + a 4-char floor) so clearly-distinct
# roles do not false-flag; the calibration test locks that.
_OWNS_STOP = {
    "and", "or", "the", "a", "an", "of", "for", "to", "in", "on", "with", "from",
    "at", "by", "this", "that", "its", "etc", "other", "others", "across", "into",
    "up", "per", "side", "own", "owns", "not", "work", "working", "team", "level",
    "management", "strategy", "support", "general", "stuff", "things",
}


def _owns_tokens(bullets):
    """Significant lowercase tokens (>=4 chars, non-stopword) from Owns bullets."""
    out = set()
    for b in bullets:
        for w in re.split(r"[^a-z0-9]+", b.lower()):
            if len(w) >= 4 and w not in _OWNS_STOP:
                out.add(w)
    return out


def parse_role_owns(path):
    """Best-effort extract of the '## Owns' bullet lines from a role .md."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    owns, in_owns = [], False
    for ln in lines:
        s = ln.strip()
        if s.startswith("## "):
            in_owns = s.lower().startswith("## owns")
            continue
        if in_owns and s.startswith("- "):
            owns.append(s[2:].strip())
    return owns


def role_overlaps(proj_path, new_owns, exclude_role=None):
    """Existing roles whose Owns share a significant keyword with new_owns.

    Returns [{role, shared:[tokens]}], newest-irrelevant, empty when none. A
    non-blocking warning signal for create-role; the caller requires an explicit
    confirm to proceed past it.
    """
    roles_dir = os.path.join(proj_path, "_roles")
    if not os.path.isdir(roles_dir):
        return []
    new_tokens = _owns_tokens(new_owns or [])
    if not new_tokens:
        return []
    out = []
    for fn in sorted(os.listdir(roles_dir)):
        if not fn.endswith(".md") or fn == "README.md":
            continue
        name = fn[:-3]
        if exclude_role and name == exclude_role:
            continue
        shared = sorted(new_tokens & _owns_tokens(parse_role_owns(os.path.join(roles_dir, fn))))
        if shared:
            out.append({"role": name, "shared": shared})
    return out


def write_role_file(proj_path, role, owns, not_owns):
    """Atomically write _roles/<role>.md (temp + os.replace). Returns the path.

    Atomic so a half-written role never syncs to a peer (launch-agents 2A). The
    caller has already refused a name collision and validated the role name.
    """
    roles_dir = os.path.join(proj_path, "_roles")
    os.makedirs(roles_dir, exist_ok=True)
    dest = os.path.join(roles_dir, f"{role}.md")
    body = [f"# {role}", "", "## Owns"]
    body += [f"- {o}" for o in (owns or [])] or ["- (define)"]
    body += ["", "## Does not own"]
    body += [f"- {n}" for n in (not_owns or [])] or ["- (define)"]
    tmp = os.path.join(roles_dir, f".{role}.md.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(body) + "\n")
    os.replace(tmp, dest)
    return dest


# ───────────────────── activity & attention (v0.25 / Tranche 2) ─────────────
# The dashboard's "what's happening / what needs attention" layer. Everything
# here is DERIVED from persistent timestamps each call (eng-review decision):
# thread mtimes + the seen-log + the autopilot state json. No new storage, no
# hook changes, no dependency on Syncthing's ephemeral event stream — so peer
# connect/disconnect is NOT in the feed (it can't be reconstructed); peer
# *current* status lives in gather_peers. One inbox+archive walk feeds the
# feed, attention, and metrics (DRY + the dashboard's 4s-poll budget).

STALE_DAYS = 3      # an open thread older than this is "needs attention"
FEED_CAP = 50       # most recent events surfaced
RECENT_AUTOPILOT = 10


def _walk_threads(proj_path):
    """One pass over _inbox/* and _archive/* → list of thread records.

    The single source the feed/attention/metrics all derive from, so the
    dashboard does not re-walk the tree once per section every poll.
    """
    records = []
    for root in ("_inbox", "_archive"):
        base = os.path.join(proj_path, root)
        if not os.path.isdir(base):
            continue
        for role in sorted(os.listdir(base)):
            rdir = os.path.join(base, role)
            if not os.path.isdir(rdir):
                continue
            for fn in sorted(os.listdir(rdir)):
                if not fn.endswith(".md") or fn == "README.md":
                    continue
                full = os.path.join(rdir, fn)
                try:
                    mtime = os.path.getmtime(full)
                except OSError:
                    mtime = 0
                fm = _frontmatter(full) or {}
                attach_raw = fm.get("attachments", "")
                records.append({
                    "root": root, "role": role, "slug": fn[:-3],
                    "rel": f"{root}/{role}/{fn}", "mtime": mtime,
                    "status": fm.get("status", ""),
                    "title": fm.get("title", "") or fn[:-3],
                    "from": fm.get("from", ""),
                    "from_identity": fm.get("from-identity", ""),
                    "owner": fm.get("owner", ""),
                    "generated_by": fm.get("generated-by", ""),
                    "attach_count": len([a for a in attach_raw.split(",") if a.strip()]) if attach_raw else 0,
                })
    return records


def _seen_map(config_dir, project_name):
    """{rel: last-ISO} from seen-<project>.log (config_dir, not expanduser)."""
    if config_dir:
        path = os.path.join(config_dir, f"seen-{project_name}.log")
    else:
        path = os.path.expanduser(f"~/.config/codesync/seen-{project_name}.log")
    out = {}
    if not os.path.exists(path):
        return out
    try:
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                parts = line.split("\t")
                if parts and parts[0]:
                    out[parts[0]] = parts[1] if len(parts) > 1 else ""
    except Exception:
        pass
    return out


def _autopilot(config_dir, project_name, now):
    """Read autopilot-<project>.json (already structured — no log parsing).

    `runs` = run epochs (rate-cap), `processed` = {rel: ISO} when it auto-
    replied. Returns a client-safe dict plus an internal `_processed` the feed
    consumes (stripped by the orchestrator before returning to the browser).
    """
    if config_dir:
        path = os.path.join(config_dir, f"autopilot-{project_name}.json")
    else:
        path = os.path.expanduser(f"~/.config/codesync/autopilot-{project_name}.json")
    if not os.path.exists(path):
        return {"enabled": False, "_processed": {}}
    try:
        with open(path) as f:
            st = json.load(f)
    except Exception:
        return {"enabled": False, "_processed": {}}
    runs = [t for t in st.get("runs", []) if isinstance(t, (int, float))]
    processed = st.get("processed", {}) if isinstance(st.get("processed"), dict) else {}
    last_run = max(runs) if runs else None
    recent = sorted(processed.items(), key=lambda kv: str(kv[1]), reverse=True)[:RECENT_AUTOPILOT]
    return {
        "enabled": True,
        "last_run_age": short_age(last_run, now) if last_run else None,
        "runs_last_hour": len([t for t in runs if now - t < 3600]),
        "recent": [{"thread": k.rsplit("/", 1)[-1][:-3] if k.endswith(".md") else k,
                    "rel": k, "when": v} for k, v in recent],
        "_processed": processed,
    }


def _feed(records, seen, autopilot_processed, now):
    """Chronological 'what happened' events, newest first, capped.

    Reconstructed from durable traces — NOT a complete audit log (the UI says
    so). One thread can yield several events (active + noticed + auto-replied);
    that is the activity stream, not duplication to dedupe.
    """
    ev = []
    for r in records:
        ev.append({
            "ts": r["mtime"],
            "kind": "archived" if r["root"] == "_archive" else "active",
            "title": r["title"], "role": r["role"], "slug": r["slug"],
            "status": r["status"], "from": r["from"],
            "age": short_age(r["mtime"], now),
        })
    for rel, iso in seen.items():
        ep = _iso_to_epoch(iso)
        if ep is not None:
            ev.append({"ts": ep, "kind": "noticed", "rel": rel,
                       "title": rel.rsplit("/", 1)[-1][:-3], "age": short_age(ep, now)})
    for rel, iso in (autopilot_processed or {}).items():
        ep = _iso_to_epoch(iso)
        if ep is not None:
            ev.append({"ts": ep, "kind": "autopilot", "rel": rel,
                       "title": rel.rsplit("/", 1)[-1][:-3], "age": short_age(ep, now)})
    ev.sort(key=lambda e: e["ts"], reverse=True)
    return ev[:FEED_CAP]


def _attention(records, proj_path, now):
    """Threads that need a human: stale, unclaimed, blocked, dead-lettered.

    Dead-letter is PARTIAL by design: we can only flag an inbox role with no
    _roles/<role>.md profile, because peers' registered roles are not synced
    (eng-review limitation). Cap each list so a flooded inbox stays readable.
    """
    roles_dir = os.path.join(proj_path, "_roles")
    have_profile = set()
    if os.path.isdir(roles_dir):
        have_profile = {f[:-3] for f in os.listdir(roles_dir)
                        if f.endswith(".md") and f != "README.md"}
    stale, unclaimed, blocked, dead = [], [], [], []

    def item(r):
        return {"role": r["role"], "slug": r["slug"], "title": r["title"],
                "status": r["status"], "age": short_age(r["mtime"], now)}

    for r in records:
        if r["root"] != "_inbox":
            continue
        st = r["status"]
        if st == "blocked":
            blocked.append(item(r))
        if st == "todo" and not r["owner"]:
            unclaimed.append(item(r))
        if st in ("todo", "wip", "blocked") and (now - r["mtime"]) > STALE_DAYS * 86400:
            stale.append(item(r))
        if r["role"] not in have_profile:
            dead.append(item(r))
    return {
        "stale": stale[:20], "unclaimed": unclaimed[:20],
        "blocked": blocked[:20], "dead_letter": dead[:20],
        "stale_days": STALE_DAYS,
    }


def _metrics(records, ttn, now):
    """Cheap, accurate counters from the single walk. (Response-time-per-role
    needs reply pairing — deferred to keep this honest, not half-built.)"""
    inbox = [r for r in records if r["root"] == "_inbox"]
    done = sum(1 for r in inbox if r["status"] == "done")
    by_role, by_identity = {}, {}
    oldest = None
    week = now - 7 * 86400
    active_7d = 0
    for r in inbox:
        if r["status"] != "done":
            by_role[r["role"]] = by_role.get(r["role"], 0) + 1
            if oldest is None or r["mtime"] < oldest:
                oldest = r["mtime"]
        if r["from_identity"]:
            by_identity[r["from_identity"]] = by_identity.get(r["from_identity"], 0) + 1
        if r["mtime"] >= week:
            active_7d += 1
    return {
        "open": len(inbox) - done, "done": done,
        "by_role": by_role, "by_identity": by_identity,
        "oldest_open_age": short_age(oldest, now) if oldest else None,
        "active_7d": active_7d,
        "ttn_median_seconds": ttn.get("median_seconds"),
        "ttn_samples": ttn.get("samples", 0),
    }


def gather_activity_full(cfg, project_name, config_dir=None, now=None):
    """Orchestrator: ONE inbox+archive walk → feed + attention + autopilot +
    metrics (+ the time-to-notice summary). The dashboard's /api/activity."""
    now = time.time() if now is None else now
    empty = {"feed": [], "attention": {}, "autopilot": {"enabled": False}, "metrics": {}}
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return empty
    proj_path = proj.get("path", "")
    if not proj_path or not os.path.isdir(proj_path):
        return empty
    records = _walk_threads(proj_path)
    seen = _seen_map(config_dir, project_name)
    ap = _autopilot(config_dir, project_name, now)
    feed = _feed(records, seen, ap.get("_processed"), now)
    ap.pop("_processed", None)               # internal only — never to the browser
    ttn = gather_activity(cfg, project_name, config_dir, now)
    return {
        "feed": feed,
        "attention": _attention(records, proj_path, now),
        "autopilot": ap,
        "metrics": _metrics(records, ttn, now),
    }


# ─────────────────────────── CLI (debug / status.sh) ───────────────────────
if __name__ == "__main__":
    import sys
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    cfg_path = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.config/codesync/config.json")
    project = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("CODESYNC_PROJECT", "")
    config_dir = os.path.dirname(os.path.abspath(cfg_path))
    cfg = load_config(cfg_path)
    blob = {"overview": gather_overview(cfg)}
    if project:
        blob["peers"] = gather_peers(cfg, project)
        blob["folder"] = gather_folder_status(cfg, project)
        blob["threads"] = gather_threads(cfg, project)
        blob["activity"] = gather_activity(cfg, project, config_dir)
        blob["activity_full"] = gather_activity_full(cfg, project, config_dir)
    blob["pending"] = gather_pending(cfg)
    print(json.dumps(blob, indent=2, ensure_ascii=False))
