---
description: Manage the autopilot — a background job that picks up queued inbox threads every 15 minutes and auto-replies to questions answerable from project docs
argument-hint: "[on | off | status]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/autopilot-setup.sh:*)"]
---

# CodeSync autopilot

The user invoked `/codesync-autopilot $ARGUMENTS`. The autopilot is a per-project launchd job that polls the inbox every 15 minutes (24/7) and wakes a headless Claude session to process new threads — so queued messages get picked up even when no Claude Code session is open.

**What the autonomous agent may do:** auto-reply to questions it can answer with high confidence purely from project-local knowledge (`_docs/`, `_roles/`, existing threads). Replies are tagged `generated-by: auto` and shown with an `[auto]` label everywhere.

**What it never does:** claim, archive, change status, create non-reply threads, guess at answers, or reply to other autopilot-generated threads (loop brake). Everything it can't handle stays untouched in the inbox for the human.

**Safety rails:** max 4 headless runs per rolling hour; each thread is processed at most once ever; zero cost on cycles where nothing new arrived (a pure-bash pre-check gates the Claude invocation).

## Step 1 — Parse the mode

- `on` (or empty + user confirms they want to enable) → install
- `off` → teardown
- `status` (or empty) → status

If `$ARGUMENTS` is empty, default to **status** and show the current state — don't install anything without an explicit `on`.

## Step 2 — Run the setup script

For **on**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/autopilot-setup.sh"
```

For **off**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/autopilot-setup.sh" --teardown
```

For **status**:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/autopilot-setup.sh" --status
```

The script requires `CODESYNC_PROJECT` to be resolved (env or marker) — the autopilot is configured per project. If it errors with "No project active", tell the user to activate a project first.

## Step 3 — Tell the user

For **on**, print:

```
✓ Autopilot enabled for project '<project>'.

  Polls every 15 minutes, around the clock. When new threads arrive in your
  registered roles' inboxes, a headless Claude session triages them:
    - Questions answerable from _docs/ get an automatic reply (tagged [auto]).
    - Everything else stays untouched for you.

  Log:    ~/.config/codesync/autopilot-<project>.log
  Check:  /codesync-autopilot status
  Stop:   /codesync-autopilot off

Note: each headless run consumes Claude API tokens (only when new threads
actually arrived — quiet cycles are free). Capped at 4 runs/hour.
```

For **off**: confirm it's removed and that queued threads will now wait for a normal Claude session.

For **status**: print the script output verbatim.

## Constraints

- Never install the launchd job without the explicit `on` argument.
- Do not edit the autopilot scripts or plist by hand from this command.
- If the user asks to change the polling interval or rate cap, explain those are in the plist (`StartInterval`) and the `CODESYNC_AUTOPILOT_MAX_RUNS_PER_HOUR` env var — editable via `/codesync-autopilot off`, manual tweak, `on`. Don't edit live plists.
