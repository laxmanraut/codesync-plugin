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
DASHBOARD_STATE = os.path.expanduser("~/.config/codesync/dashboard.json")
PAIR_PEER = os.path.join(SCRIPT_DIR, "pair-peer.sh")

# Shared mutable launch state (set in main, read by the handler + watchdog).
_ctx = {"token": "", "config": "", "last_activity": time.time()}
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
        elif u.path == "/api/threads":
            self._json({"project": project,
                        "threads": state.gather_threads(cfg, project)})
        elif u.path == "/api/activity":
            self._json({"project": project,
                        "activity": state.gather_activity(cfg, project)})
        else:
            self._send(404, "404 not found\n", "text/plain; charset=utf-8")

    # ── POST (the one write action) ───────────────────────────────────────────
    def do_POST(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if not self._token_ok(qs):
            self._send(403, "403 forbidden: missing or invalid token\n",
                       "text/plain; charset=utf-8")
            return
        _touch()
        if u.path != "/api/accept-pairing":
            self._send(404, "404 not found\n", "text/plain; charset=utf-8")
            return
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw or b"{}")
            device_id = str(body.get("device_id", "")).strip().upper()
        except Exception:
            self._json({"ok": False, "error": "bad request body"}, 400)
            return
        # Validate ID shape BEFORE shelling out (defense in depth; pair-peer.sh
        # validates again).
        if not state._ID_RE.match(device_id):
            self._json({"ok": False, "error": "invalid device id format"}, 400)
            return
        try:
            # Device-trust only — no project-folder invite from the browser.
            proc = subprocess.run(
                ["bash", PAIR_PEER, "--peer", device_id, "--device-only"],
                capture_output=True, text=True, timeout=30,
                env={**os.environ},
            )
            ok = proc.returncode == 0
            self._json({
                "ok": ok,
                "device_id": device_id,
                "message": (proc.stdout.strip() if ok else proc.stderr.strip())[-500:],
                "pending": state.gather_pending(state.load_config(_ctx["config"])),
            }, 200 if ok else 500)
        except subprocess.TimeoutExpired:
            self._json({"ok": False, "error": "pairing timed out"}, 504)
        except Exception as e:
            self._json({"ok": False, "error": f"{type(e).__name__}"}, 500)

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
    try:
        os.makedirs(os.path.dirname(DASHBOARD_STATE), exist_ok=True)
        fd = os.open(DASHBOARD_STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"pid": os.getpid(), "port": port, "token": token,
                       "started": int(time.time())}, f)
        os.chmod(DASHBOARD_STATE, 0o600)
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
                os.remove(DASHBOARD_STATE)
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
            os.remove(DASHBOARD_STATE)
        except OSError:
            pass


if __name__ == "__main__":
    main()
