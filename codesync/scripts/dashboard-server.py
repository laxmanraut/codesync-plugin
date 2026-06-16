#!/usr/bin/env python3
"""dashboard-server.py — local, read-only codesync monitoring dashboard.

Launched by dashboard-run.sh (never directly by the user). Serves a single
HTML page plus a small JSON API, bound to 127.0.0.1 on a random free port,
gated by a per-launch secret token. One write action: accept a pending
pairing request (device-trust only).

Security (eng-review D4):
  - 127.0.0.1 only, random free port (the OS picks it).
  - Per-launch token required on EVERY request (?t= or X-CSDash-Token header);
    missing/wrong → 403. The accept-pairing POST re-checks it.
  - The Syncthing API key is read server-side via state.py and NEVER sent to
    the browser.
  - All data flows through state.py, which sanitises peer-chosen strings; the
    page renders via textContent (no innerHTML of untrusted data).

Lifecycle (eng-review R2): writes ~/.config/codesync/dashboard.json (chmod
600) with pid/port/token so a relaunch can health-ping and reuse this
instance. Idle auto-shutdown after --idle-timeout seconds with no requests is
the cross-platform orphan reaper.

First stdout line is machine-parseable for dashboard-run.sh:
    DASHBOARD port=<port> token=<token>
"""
import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "lib"))
import state  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

INDEX_PATH = os.path.join(SCRIPT_DIR, "dashboard", "index.html")
# Scripts shelled out to bash use FORWARD slashes: on Windows os.path.join yields
# a backslash path (C:\...\x.sh), and bash treats "\" as an escape, so it fails to
# open the script (exit 127, no output). Forward slashes (C:/.../x.sh) open fine
# under Git Bash; on macOS this replace is a no-op. INDEX_PATH stays as-is — it is
# opened by Python's open(), where backslashes are fine.
PAIR_PEER = os.path.join(SCRIPT_DIR, "pair-peer.sh").replace("\\", "/")
LAUNCH_AGENT = os.path.join(SCRIPT_DIR, "launch-agent.sh").replace("\\", "/")
REGISTER_ROLE = os.path.join(SCRIPT_DIR, "register-role-in-config.sh").replace("\\", "/")
ROLES_JSON = os.path.join(SCRIPT_DIR, "lib", "roles.json")

# The bash to shell out to. On Windows, PATH-resolved "bash" is the WSL launcher
# (C:\Windows\System32\bash.exe) which has no distro and fails; platform.sh
# exports CODESYNC_BASH = the Git Bash that launched us, in native form.
_BASH = os.environ.get("CODESYNC_BASH") or "bash"

# Shared mutable launch state (set in main, read by the handler + watchdog).
# config_dir is the config.json directory — the seen-logs and dashboard.json
# live there. Derived from --config, NOT expanduser('~'), because Python's
# expanduser resolves USERPROFILE on Windows, not bash's $HOME (v0.22.x lesson).
_ctx = {"token": "", "config": "", "config_dir": "", "state_file": "",
        "last_activity": time.time()}
_lock = threading.Lock()


def _touch():
    with _lock:
        _ctx["last_activity"] = time.time()


class Handler(BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging (keeps the launcher clean).
    def log_message(self, *args):
        pass

    # ── token gate ──────────────────────────────────────────────────────────
    def _token_ok(self, qs):
        supplied = (self.headers.get("X-CSDash-Token", "")
                    or (qs.get("t", [""])[0]))
        # constant-time compare to avoid leaking the token via timing
        return bool(_ctx["token"]) and secrets.compare_digest(supplied, _ctx["token"])

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, (bytes, bytearray)) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # Defense-in-depth headers for a page that renders untrusted strings.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False), )

    # ── shared POST helpers (eng-review CQ: factor read/validate/run; T2: a
    #    stronger gate for writes than reads get) ────────────────────────────
    def _post_gate(self):
        """Gate for write/spawn POSTs. Stricter than the read gate (eng-review
        T2, because these endpoints now spawn processes + write a synced folder):
        token in the HEADER only (never ?t=, so it can't leak via URL/history/
        Referer), Host must be loopback (anti DNS-rebind), Origin absent or self
        (anti cross-site POST). Sends 403 and returns False on any failure."""
        supplied = self.headers.get("X-CSDash-Token", "")
        if not (_ctx["token"] and secrets.compare_digest(supplied, _ctx["token"])):
            self._send(403, "403 forbidden: missing or invalid token\n",
                       "text/plain; charset=utf-8")
            return False
        host = (self.headers.get("Host", "") or "").rsplit(":", 1)[0]
        if host not in ("127.0.0.1", "localhost"):
            self._send(403, "403 forbidden: bad host\n", "text/plain; charset=utf-8")
            return False
        origin = self.headers.get("Origin", "")
        if origin and (urlparse(origin).hostname or "") not in ("127.0.0.1", "localhost"):
            self._send(403, "403 forbidden: cross-origin\n", "text/plain; charset=utf-8")
            return False
        return True

    def _read_json_body(self):
        """Read + parse the JSON body; send 400 and return None on error."""
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw or b"{}")
        except Exception:
            self._json({"ok": False, "error": "bad request body"}, 400)
            return None

    def _require(self, body, field, regex):
        """Validated field accessor; send 400 and return None on mismatch."""
        val = str(body.get(field, "")).strip()
        if not regex.match(val):
            self._json({"ok": False, "error": f"invalid {field}"}, 400)
            return None
        return val

    def _run_bash(self, argv, timeout=30):
        """Run bash with argv (paths cross as argv, never env — the MSYS rule).
        Uses _BASH (Git Bash), never PATH-resolved "bash" (WSL on Windows).
        Returns (ok, stdout, stderr); raises TimeoutExpired for the caller."""
        proc = subprocess.run([_BASH, *argv], capture_output=True, text=True,
                              timeout=timeout, env={**os.environ})
        return proc.returncode == 0, proc.stdout.strip(), proc.stderr.strip()

    # ── GET ───────────────────────────────────────────────────────────────────
    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if not self._token_ok(qs):
            self._send(403, "403 forbidden: missing or invalid token\n",
                       "text/plain; charset=utf-8")
            return
        _touch()
        cfg = state.load_config(_ctx["config"])
        project = (qs.get("project", [""])[0]) or _default_project(cfg)

        if u.path == "/" or u.path == "/index.html":
            self._serve_index()
        elif u.path == "/api/overview":
            self._json(state.gather_overview(cfg))
        elif u.path == "/api/peers":
            self._json({"project": project,
                        **state.gather_peers(cfg, project),
                        "folder": state.gather_folder_status(cfg, project)})
        elif u.path == "/api/pending":
            self._json({"pending": state.gather_pending(cfg)})
        elif u.path == "/api/roles":
            # The role catalog (read-only static asset) for the new-role form.
            try:
                with open(ROLES_JSON, encoding="utf-8") as f:
                    self._json(json.load(f))
            except Exception:
                self._json({"categories": []})
        elif u.path == "/api/threads":
            self._json({"project": project,
                        "threads": state.gather_threads(cfg, project)})
        elif u.path == "/api/activity":
            # v0.25: full activity payload (feed + attention + autopilot +
            # metrics). All filesystem-derived, so it returns even when
            # Syncthing is offline.
            self._json({"project": project,
                        **state.gather_activity_full(cfg, project, _ctx["config_dir"])})
        else:
            self._send(404, "404 not found\n", "text/plain; charset=utf-8")

    # ── POST (write / spawn actions) ────────────────────────────────────────
    def do_POST(self):
        u = urlparse(self.path)

        # accept-pairing is a write action, so it gets the SAME strong gate as
        # launch-agent (header-only token + Host + Origin). The shipped frontend
        # already sends the token as the X-CSDash-Token header (index.html), and a
        # real browser POST is same-origin loopback, so this does not break the
        # pairing button. Shares the body/run helpers (eng-review CQ).
        if u.path == "/api/accept-pairing":
            if not self._post_gate():
                return
            _touch()
            body = self._read_json_body()
            if body is None:
                return
            device_id = str(body.get("device_id", "")).strip().upper()
            if not state._ID_RE.match(device_id):   # validate BEFORE shelling out
                self._json({"ok": False, "error": "invalid device id format"}, 400)
                return
            try:
                ok, out, err = self._run_bash([PAIR_PEER, "--peer", device_id, "--device-only"])
                self._json({
                    "ok": ok, "device_id": device_id,
                    "message": (out if ok else err)[-500:],
                    "pending": state.gather_pending(state.load_config(_ctx["config"])),
                }, 200 if ok else 500)
            except subprocess.TimeoutExpired:
                self._json({"ok": False, "error": "pairing timed out"}, 504)
            except Exception as e:
                self._json({"ok": False, "error": f"{type(e).__name__}"}, 500)
            return

        # launch-agent: spawns a process, so it gets the stronger write gate
        # (header token + Host + Origin).
        if u.path == "/api/launch-agent":
            if not self._post_gate():
                return
            _touch()
            body = self._read_json_body()
            if body is None:
                return
            self._launch_agent(body)
            return

        # create-role: writes the synced project folder + registers locally.
        if u.path == "/api/create-role":
            if not self._post_gate():
                return
            _touch()
            body = self._read_json_body()
            if body is None:
                return
            self._create_role(body)
            return

        self._send(404, "404 not found\n", "text/plain; charset=utf-8")

    def _launch_agent(self, body):
        """POST /api/launch-agent {project, role} — open a terminal as that role.
        Allowlist (eng-review): project must exist in config, its path must be on
        THIS machine (H1 — metadata can sync without the working dir), and the
        role must be registered. The launched command is FIXED (claude); only the
        allowlisted project/role/path reach launch-agent.sh, as argv."""
        cfg = state.load_config(_ctx["config"])
        project = self._require(body, "project", state._NAME_RE)
        if project is None:
            return
        role = self._require(body, "role", state._NAME_RE)
        if role is None:
            return
        proj = (cfg.get("projects") or {}).get(project)
        if not proj:
            self._json({"ok": False, "error": "unknown project"}, 400)
            return
        path = proj.get("path", "")
        if not path or not os.path.isdir(path):
            self._json({"ok": False, "error": "project not on this machine"}, 409)
            return
        if role not in (proj.get("roles") or []):
            self._json({"ok": False, "error": "role not registered"}, 400)
            return
        try:
            ok, out, err = self._run_bash([LAUNCH_AGENT, "--project", project,
                                           "--role", role, "--path", path])
        except subprocess.TimeoutExpired:
            self._json({"ok": False, "error": "launch timed out"}, 504)
            return
        except Exception as e:
            self._json({"ok": False, "error": f"{type(e).__name__}"}, 500)
            return
        # launch-agent.sh prints LAUNCHED or COPY<TAB><command> (universal fallback).
        launched = out.startswith("LAUNCHED")
        copy = out.split("\t", 1)[1] if out.startswith("COPY\t") else ""
        self._json({"ok": ok, "launched": launched, "copy": copy,
                    "project": project, "role": role,
                    "message": (out if ok else err)[-500:]}, 200 if ok else 500)

    def _create_role(self, body):
        """POST /api/create-role {project, role, owns[], not_owns[], confirm?}.
        Writes _roles/<role>.md into the SYNCED project folder and registers it
        locally. Refuses a name collision (409, no clobber of a synced peer
        file); warns on an Owns-keyword overlap unless confirm=true. Does NOT
        launch — the frontend chains to /api/launch-agent so each endpoint stays
        single-purpose. The deterministic checks here are NOT the full conflict
        check; the UI points quality-sensitive creation at /codesync-role-new."""
        cfg = state.load_config(_ctx["config"])
        project = self._require(body, "project", state._NAME_RE)
        if project is None:
            return
        role = self._require(body, "role", state._NAME_RE)
        if role is None:
            return
        if role.lower() in state._WIN_RESERVED:
            self._json({"ok": False, "error": "role name is reserved on Windows"}, 400)
            return
        proj = (cfg.get("projects") or {}).get(project)
        if not proj:
            self._json({"ok": False, "error": "unknown project"}, 400)
            return
        path = proj.get("path", "")
        if not path or not os.path.isdir(path):
            self._json({"ok": False, "error": "project not on this machine"}, 409)
            return
        owns = [str(x).strip() for x in (body.get("owns") or []) if str(x).strip()]
        not_owns = [str(x).strip() for x in (body.get("not_owns") or []) if str(x).strip()]
        # Name-collision: refuse, never clobber a (possibly synced) peer file.
        if os.path.exists(os.path.join(path, "_roles", f"{role}.md")):
            self._json({"ok": False, "error": "role already exists",
                        "hint": "pick another name, or run /codesync-role-new to reconcile"}, 409)
            return
        # Owns-overlap: non-blocking warning, requires an explicit confirm.
        if not body.get("confirm"):
            overlaps = state.role_overlaps(path, owns, exclude_role=role)
            if overlaps:
                self._json({"ok": False, "needs_confirm": True, "overlaps": overlaps,
                            "hint": "Owns overlaps an existing role. Resend with confirm:true, "
                                    "or run /codesync-role-new for a full conflict review."}, 409)
                return
        # Write the synced role file atomically, THEN register it locally. If
        # register fails, roll the file back — otherwise an orphaned synced
        # _roles/<role>.md is left behind and a retry is permanently blocked by
        # the collision guard above. `created` reflects the FULL success.
        try:
            state.write_role_file(path, role, owns, not_owns)
        except Exception as e:
            self._json({"ok": False, "created": False,
                        "error": f"write failed: {type(e).__name__}"}, 500)
            return
        try:
            ok, out, err = self._run_bash([REGISTER_ROLE, "--project", project, "--role", role])
        except subprocess.TimeoutExpired:
            ok, out, err = False, "", "register timed out"
        except Exception as e:
            ok, out, err = False, "", type(e).__name__
        if not ok:
            try:
                os.remove(os.path.join(path, "_roles", f"{role}.md"))
            except OSError:
                pass
            self._json({"ok": False, "created": False,
                        "error": f"register failed: {err}"[-300:]}, 500)
            return
        self._json({"ok": True, "created": True, "project": project, "role": role,
                    "message": out[-500:]}, 200)

    def _serve_index(self):
        try:
            with open(INDEX_PATH, "rb") as f:
                html = f.read()
        except OSError:
            self._send(500, "dashboard page missing\n", "text/plain; charset=utf-8")
            return
        self._send(200, html, "text/html; charset=utf-8")


def _default_project(cfg):
    env = os.environ.get("CODESYNC_PROJECT", "").strip()
    if env and env in (cfg.get("projects") or {}):
        return env
    projs = sorted((cfg.get("projects") or {}).keys())
    return projs[0] if projs else ""


def _write_state(port, token):
    sf = _ctx["state_file"]
    try:
        os.makedirs(os.path.dirname(sf), exist_ok=True)
        fd = os.open(sf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"pid": os.getpid(), "port": port, "token": token,
                       "started": int(time.time())}, f)
        os.chmod(sf, 0o600)
    except Exception:
        pass


def _watchdog(httpd, idle_timeout):
    """Shut the server down after idle_timeout seconds with no requests."""
    while True:
        time.sleep(min(30, max(5, idle_timeout // 4)))
        with _lock:
            idle = time.time() - _ctx["last_activity"]
        if idle >= idle_timeout:
            try:
                os.remove(_ctx["state_file"])
            except OSError:
                pass
            httpd.shutdown()
            return


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.expanduser("~/.config/codesync/config.json"))
    ap.add_argument("--idle-timeout", type=int, default=1800)  # 30 min
    args = ap.parse_args()

    _ctx["config"] = args.config
    _ctx["config_dir"] = os.path.dirname(os.path.abspath(args.config))
    _ctx["state_file"] = os.path.join(_ctx["config_dir"], "dashboard.json")
    _ctx["token"] = secrets.token_urlsafe(24)

    # Random free port on loopback only.
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()

    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    _write_state(port, _ctx["token"])

    # Machine-parseable handshake for dashboard-run.sh (FIRST line).
    print(f"DASHBOARD port={port} token={_ctx['token']}", flush=True)

    threading.Thread(target=_watchdog, args=(httpd, args.idle_timeout),
                     daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.remove(_ctx["state_file"])
        except OSError:
            pass


if __name__ == "__main__":
    main()
