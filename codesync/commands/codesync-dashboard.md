---
description: Open the local codesync monitoring dashboard in your browser (read-only view of projects, peers, threads, pending pairings; accept pairing requests)
argument-hint: "[--stop]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dashboard-run.sh:*)"]
---

# CodeSync Dashboard

The user invoked `/codesync-dashboard`.

This launches a small **local, read-only** web dashboard for codesync and opens
it in the user's default browser. It shows — for every project on this machine —
the registered projects and roles, paired peers (online/offline + sync status),
threads in the inboxes (with status/sender/age), incoming pairing requests, and
the time-to-notice metric. The one action it can take is **accept a pending
pairing request** (device-trust only; folder sharing still happens via
`/codesync-pair`).

It binds to `127.0.0.1` on a random port behind a per-launch secret token, so
no other machine — and no untrusted local process without the token — can reach
it. It auto-stops after 30 minutes idle.

## Run it

If the user passed `--stop`, stop the running instance:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dashboard-run.sh" --stop
```

Otherwise start (or reopen) it:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dashboard-run.sh"
```

The script prints `DASHBOARD_URL=http://127.0.0.1:<port>/?t=<token>` on success
and opens that URL in the browser automatically. If the browser didn't open
(e.g. a headless shell), tell the user they can paste that URL themselves.

If the script exits non-zero, surface its error (it points at
`~/.config/codesync/dashboard.log`) and STOP — do not try to start it another
way.

## Notes for the user

- The dashboard is per-machine: it shows this machine's projects and its own
  Syncthing view. There is no shared/central dashboard.
- It's read-only except for accepting pairing requests. Everything else
  (sending threads, status changes) stays in Claude Code.
- To stop it sooner than the 30-minute idle timeout: `/codesync-dashboard --stop`.
