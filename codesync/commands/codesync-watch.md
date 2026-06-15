---
description: Manage the always-on inbox watcher — a background job that notifies you when a thread arrives, even when Claude Code is closed
argument-hint: "[on | off | status]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/watch-setup.sh:*)"]
---

# CodeSync inbox watcher

The user invoked `/codesync-watch $ARGUMENTS`. The watcher is a per-project background job (launchd on macOS, Task Scheduler on Windows) that polls your registered-role inboxes every ~2 minutes, 24/7, and fires a desktop notification the moment a new thread arrives — **even when no Claude Code session is open**.

It is the fix for the gap where handoffs only surfaced once you re-opened Claude Code (measured time-to-notice was ~22h before this). It shares the same first-seen log the in-session statusline uses, so:

- Opening Claude Code later does **not** re-notify what the watcher already surfaced.
- The `time-to-notice` metric reflects the faster notice automatically.

**What it does:** scan → notify. Nothing else. Unlike the autopilot, it runs no headless Claude, sends no replies, and writes nothing except the shared seen-log. Zero API tokens. A quiet inbox costs nothing.

## Step 1 — Parse the mode

- `on` (or empty + the user confirms) → install
- `off` → teardown
- `status` (or empty) → status

If `$ARGUMENTS` is empty, default to **status** — don't install anything without an explicit `on`.

## Step 2 — Run the setup script

For **on**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/watch-setup.sh"
```

For **off**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/watch-setup.sh" --teardown
```

For **status**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/watch-setup.sh" --status
```

The script requires `CODESYNC_PROJECT` to be resolved (env or marker) — the watcher is per project. If it errors with "No project active", tell the user to activate a project first.

## Step 3 — Tell the user

For **on**, print:

```
✓ Inbox watcher enabled for project '<project>'.

  Polls every ~2 minutes, around the clock. When a thread arrives in one of
  your registered roles' inboxes, you get a desktop notification — even with
  Claude Code closed. No replies, no API tokens; it only notifies.

  Log:    ~/.config/codesync/watch-<project>.log
  Check:  /codesync-watch status
  Stop:   /codesync-watch off
```

For macOS, add: *"First run may prompt for notification permission — allow it, or toasts won't show."*

For Windows, add: *"The task runs hidden and only while you're logged on (so toasts display). If notifications don't appear, check Focus Assist and that the task registered: `schtasks /Query /TN codesync-watch-<project>`."*

For **off**: confirm it's removed and that arrivals will again only surface when Claude Code is open.

For **status**: print the script output verbatim.

## Constraints

- Never install the scheduled job without the explicit `on` argument.
- Do not edit the plist / scheduled task or the watcher scripts by hand from this command.
- To change the poll interval: `/codesync-watch off`, then `on` with `CODESYNC_WATCH_INTERVAL` set (seconds), or `--interval <seconds>`. Don't edit a live plist or task.
