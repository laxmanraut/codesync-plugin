---
description: Manage sandboxed autonomy — let a role's agent work its queued tasks on a schedule, in an isolated clone, with every change human-reviewed before it can reach anyone
argument-hint: "[status | repo <path> | model <id> | enable <role> [tools] | disable <role> | on | off]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh:*)"]
---

# CodeSync sandboxed autonomy

The user invoked `/codesync-autonomy $ARGUMENTS`. This is the control panel's autonomy layer: a per-project background job (launchd on macOS, Task Scheduler on Windows) that, every ~15 minutes, lets each **enabled** role's agent work its unprocessed task threads — but safely.

**The safety model (say this plainly if the user is enabling it for the first time):**

- **Local authority.** Whether a role runs autonomously, and what tools it gets, live in **local** config (`~/.config/codesync/autonomy.json`) — never the synced role file. A teammate editing a synced role can **never** arm an agent or widen tools on your machine.
- **Isolation.** The agent works in a **separate clone** of your repo (`repo_path`) with git hooks disabled — not the live working tree, not the synced folder. The clone path must be **outside** every synced project folder (enforced; a repo_path inside a synced folder is refused).
- **Two-gate review.** Each cycle produces a branch and files a **pending entry in the dashboard's "Autonomy review queue."** Nothing reaches a teammate until **you** approve it (gate 1: the rebased branch lands in your local repo) **and then** merge + sync it yourself (gate 2). codesync never writes the synced folder or pushes to a remote on the agent's behalf.
- **Brakes.** Per-role lock, a rolling-hour run cap + token ceiling, a kill-switch file, a review TTL, and a secret denylist (an entry whose diff touches a `.env`/`*.pem`/`id_rsa`-type file is flagged **blocked** and can't be approved).

## Step 1 — Parse the subcommand

`$ARGUMENTS` (first word is the subcommand; default **status**):

- `status` (or empty) → show local autonomy config + clone state
- `repo <path>` → set the local git repo clones are made from (must be OUTSIDE every synced folder)
- `model <id>` → pin the model the runner passes to `claude -p` (the settings default can be stale)
- `enable <role> [comma,tools]` → enable autonomy for a role; tools default to a read+edit set if omitted
- `disable <role>` → disable autonomy for a role
- `on` → schedule the runner (every ~15 min)
- `off` → unschedule the runner

Never schedule the runner (`on`) without the explicit `on` argument.

## Step 2 — Run the setup script

The script needs `CODESYNC_PROJECT` resolved (env or marker) — autonomy is per project. If it errors with "No project active", tell the user to activate a project first.

```bash
# status (default)
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --status

# repo <path>
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --repo-path "<path>"

# model <id>
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --model "<id>"

# enable <role> [tools]   (omit --tools to use the default below)
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --role "<role>" --enable --tools "Read,Glob,Grep,Edit,Write"

# disable <role>
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --role "<role>" --disable

# on / off
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --install
"${CLAUDE_PLUGIN_ROOT}/scripts/autonomy-setup.sh" --teardown
```

Pass tools through verbatim if the user supplied them; otherwise use `Read,Glob,Grep,Edit,Write`. The agent has no Bash by default — it edits files and the runner captures the change for review, so it does not need to commit.

## Step 3 — Guide the first-time setup order

A role won't actually run until all of these are done. If the user runs `enable` or `on` before the prerequisites, point them at the missing step (the script also warns):

1. `/codesync-autonomy repo <path-to-your-local-repo>`  (outside any synced folder)
2. `/codesync-autonomy model <id>`  (optional but recommended)
3. `/codesync-autonomy enable <role> [tools]`
4. `/codesync-autonomy on`  (schedules the runner)

Then produced branches show up in the dashboard (`/codesync-dashboard` → "Autonomy review queue"), where you **Approve** or **Reject** each one.

## Step 4 — Tell the user

For **on**, print:

```
✓ Autonomy runner scheduled for project '<project>' (every ~15 min).

  Each enabled role's agent works its queued tasks in an ISOLATED clone and
  files every change to the review queue. Nothing reaches a teammate until you
  approve it AND merge + sync it yourself.

  Review:  /codesync-dashboard  →  "Autonomy review queue"
  Status:  /codesync-autonomy status
  Stop:    /codesync-autonomy off
  Halt now: touch ~/.config/codesync/autonomy-<project>.halt
```

For **status**/other subcommands: print the script output verbatim.

## Constraints

- Never schedule the runner without an explicit `on`.
- Do not edit `autonomy.json`, the plist/scheduled task, the clones, or the review queue by hand from this command — use the subcommands.
- `repo_path` MUST be outside every synced project folder; if the script refuses it, do not try to work around it.
- macOS/launchd headless auth is verified; Windows/schtasks auth is not yet confirmed — on Windows, mention that the first scheduled run may need a logged-on session and that auth hasn't been validated there.
