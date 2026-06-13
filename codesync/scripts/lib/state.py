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
def gather_pending(cfg):
    """Incoming pairing requests (devices that added us, waiting for accept).

    Drops entries whose ID isn't strict Syncthing format and sanitises the
    self-declared name (v0.23.1 hardening). Returns [] when none / offline.
    """
    pending = _syncthing_get(cfg, "/rest/cluster/pending/devices")
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
def gather_activity(cfg, project_name, now=None):
    """Time-to-notice metric from the shared first-seen log (OV7).

    Each seen-log line is 'rel<TAB>ISO-timestamp' = when a thread was first
    surfaced. We pair each against the thread file's mtime (arrival time) to
    get a per-thread notice latency, then summarise. Empty until handoffs flow.
    """
    proj = (cfg.get("projects") or {}).get(project_name)
    if not proj:
        return {"samples": 0, "median_seconds": None, "recent": []}
    proj_path = proj.get("path", "")
    seen_log = os.path.expanduser(
        f"~/.config/codesync/seen-{project_name}.log")
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
    cfg = load_config(cfg_path)
    blob = {"overview": gather_overview(cfg)}
    if project:
        blob["peers"] = gather_peers(cfg, project)
        blob["folder"] = gather_folder_status(cfg, project)
        blob["threads"] = gather_threads(cfg, project)
        blob["activity"] = gather_activity(cfg, project)
    blob["pending"] = gather_pending(cfg)
    print(json.dumps(blob, indent=2, ensure_ascii=False))
