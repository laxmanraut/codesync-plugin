# codesync

A Claude Code plugin for coordinating work between AI-augmented collaborators across machines — no cloud service, no central server.

The mental model: each **project** is a peer-to-peer synced folder. Inside each project, work is **role-addressed** — backend, frontend, mobile, devops, whatever fits — via per-role inbox folders. Notes, tasks, design discussions, decisions, and questions flow through those inboxes, and Claude agents on each machine read and write them on behalf of their human. Each terminal picks one project + role, so the same laptop can act as different roles in different terminals — even across different projects.

Backed by [Syncthing](https://syncthing.net) for the actual peer-to-peer sync. Anything you write to a project folder ends up on your collaborator's machine within seconds (LAN) or minutes (over the internet). Anything they write ends up on yours.

```
    Your Mac                              Colleague's Mac
  ┌────────────┐                        ┌────────────┐
  │ Claude     │                        │ Claude     │
  │ Code       │                        │ Code       │
  └─────┬──────┘                        └──────┬─────┘
        │  writes a task                       │  reads it,
        │  for "frontend"                      │  replies back
        ▼                                      ▼
  ┌─────────────────┐                    ┌─────────────────┐
  │ ~/codesync/     │   shared folder    │ ~/codesync/     │
  │   lead_inbox/   │ ◄────────────────► │   lead_inbox/   │
  │     _inbox/     │      (Syncthing    │     _inbox/     │
  │       backend/  │      keeps both    │       backend/  │
  │       frontend/ │       in sync)     │       frontend/ │
  └─────────────────┘                    └─────────────────┘
         you                                 colleague
    (role: backend)                       (role: frontend)
```

**Reading the diagram:** the two boxes at the bottom are the same project folder, mirrored on both Macs by Syncthing — no server sits between them. When your Claude writes a file into `_inbox/frontend/`, Syncthing copies it to your colleague's matching folder within seconds (on the same LAN) or a minute or two (over the internet). Their Claude picks it up on its next turn. The reply flows back the same way, into `_inbox/backend/`. The role names (`backend`, `frontend`) are just folder names — they decide *who the message is for*, not which machine it lives on.

**Nothing manual, always in sync.** When your Claude has something for your colleague — a new task, a question, a design note, a "done" reply — it writes the file directly into the relevant role's inbox. No copy-paste, no export, no "send" button, no message-broker step. The folder sync runs continuously in the background after install (Syncthing is a small always-on service), so both Macs stay in sync even when Claude Code itself isn't open — if your colleague is asleep and you ship five tasks for them, all five are waiting on their machine when they wake up. The receiving Claude picks up new files automatically too: a session-start summary lists what's waiting in the inbox the moment you launch Claude Code, and a post-turn auto-check surfaces anything new that arrived while you were typing. Neither agent ever has to be told "go check the folder" — it's already happening every turn.

## Requirements

- macOS (the install scripts use `brew services` and read Syncthing's config from `~/Library/Application Support/`)
- [Homebrew](https://brew.sh)
- [Claude Code](https://claude.com/claude-code)

## Install

In Claude Code:

```
/plugin marketplace add github:laxmanraut/codesync-plugin
/plugin marketplace update codesync-shared
/plugin install codesync@codesync-shared
/reload-plugins
```

The `marketplace update` and `reload-plugins` steps refresh Claude Code's local plugin cache. Without them, the install can complain that the plugin isn't there.

## First-time setup

```
/install-codesync
```

This will:

1. Install Syncthing via Homebrew if needed and start it as a background service.
2. Save your Syncthing API key and Device ID.
3. Ask you to pick or create a **project** (e.g. `lead_inbox`, `mobile-app`). Each project becomes its own Syncthing folder at `~/codesync/<project>/`. If projects already exist on this machine, a numbered picker shows them plus a "New project" option.
4. Show a numbered **role picker** with 12 predefined roles across Engineering, Product & Design, and Project & People — pick one or more (comma-separated). Hybrid is fine: pick `5,7` for "Product Manager + Designer" in one go. Option 13 is "Custom (free-form)" for roles outside the curated list. Each pick comes with a starter `Owns` / `Does not own` template you can edit before saving.
5. Print the activation command:
   ```
   export CODESYNC_PROJECT=<project> CODESYNC_ROLE=<primary-role>
   ```

If you register multiple roles (e.g. PM + Designer), the post-turn inbox check and session-start summary will automatically cover ALL of them. You only need to switch `CODESYNC_ROLE` when you want to *send* messages "as" the other hat — receiving covers everything.

## Activating a project + role in a terminal

Both are **per-terminal**. Each shell decides which project and role this Claude Code session acts as, via two environment variables.

Minimum to activate manually:

```
export CODESYNC_PROJECT=lead_inbox
export CODESYNC_ROLE=backend
claude
```

Inside Claude Code, `/codesync-status` confirms both are set.

### A nicer wrapper for `~/.zshrc`

Add this to your `~/.zshrc` (or `~/.bashrc`):

```bash
cs() {
  case $# in
    2)
      export CODESYNC_PROJECT="$1"
      export CODESYNC_ROLE="$2"
      echo "CodeSync: project=$CODESYNC_PROJECT role=$CODESYNC_ROLE"
      ;;
    1)
      export CODESYNC_ROLE="$1"
      echo "CodeSync: project=${CODESYNC_PROJECT:-(unset)} role=$CODESYNC_ROLE"
      ;;
    0)
      echo "Usage: cs <project> <role>   or   cs <role>"
      echo "Current: project=${CODESYNC_PROJECT:-(unset)} role=${CODESYNC_ROLE:-(unset)}"
      ;;
    *)
      echo "Usage: cs <project> <role>   or   cs <role>"
      return 1
      ;;
  esac
}
```

After reloading your shell (`source ~/.zshrc`), switching becomes:

```
$ cs lead_inbox backend
$ claude
> /codesync-status
  Active project: lead_inbox
  Active role:    backend

# In another terminal:
$ cs mobile-app frontend
$ claude
> /codesync-status
  Active project: mobile-app
  Active role:    frontend
```

## Activating a project by `cd`-ing into a directory

You can avoid setting env vars for every terminal by *attaching* a directory to a project. Once attached, any Claude Code session launched from inside that directory (or any subdirectory) auto-resolves the project — no `export` needed.

```
cd ~/code/lead-inbox-app
/codesync-project-attach lead_inbox backend
```

That drops a small `.codesync/project.json` marker file in the directory. The marker can be committed to git so your collaborator gets the same default when they clone, or `.gitignore`'d if you prefer it private to your machine.

**Precedence:** if the shell has `CODESYNC_PROJECT` exported, that always wins. The marker is the default fallback. So you can have a marker setting one project, and override per-terminal with `export CODESYNC_PROJECT=otherproject` when needed.

For the role, the marker can declare a `default_role` that's used when `CODESYNC_ROLE` is unset — handy if a particular code directory is mostly worked on as one role.

**Auto-offer from `/codesync-role-new`:** if you run `/codesync-role-new` in a terminal where no project is active, it walks you through picking (or creating) a project, then offers to drop a marker in the current directory so you don't need to set the env var. The offer is guarded against general-purpose locations (`~`, `/tmp`, `/`) — in those it defaults to *no* with a warning, since a marker there would affect every terminal launched from your home.

## Adding another project

```
/codesync-project-new
```

Walks through naming + creates a new Syncthing folder + scaffold. After it runs, set `CODESYNC_PROJECT=<new-name>` in your shell (or use `cs <new-name> <role>`) and start `/codesync-role-new` inside the new project to register roles for it.

**Shortcut:** `/codesync-role-new` and `/codesync-thread-new` both fall back to a project picker if no project is active in the terminal — so you can skip the explicit `/codesync-project-new` step and just run `/codesync-role-new` directly. The picker will offer existing projects plus "New project (enter name)" as the last option.

## Pairing with a collaborator

After both of you have a project of the same name (e.g. both ran `/install-codesync` with project `lead_inbox`), exchange Device IDs (printed by install or `/codesync-status`).

In a terminal where `CODESYNC_PROJECT=lead_inbox` is set, run:

```
/codesync-pair --peer <their-device-id>
```

This pairs the devices AND invites the peer to the active project's folder. Your collaborator runs the same command on their side (with their own `CODESYNC_PROJECT` set). Sync starts automatically once both sides have done it.

If you want to invite an already-paired peer to a **different** project, set `CODESYNC_PROJECT` to that project and run:

```
/codesync-project-invite --peer <their-device-id>
```

### Teams of 3+ — use an introducer

Pairing two people is straightforward — each side runs `/codesync-pair` once and you're done. But with N people, the naive approach needs each person to pair with every other person: that's N×(N−1)/2 pairings, plus everyone has to swap Device IDs with everyone.

CodeSync uses Syncthing's **introducer** model to collapse this. Designate one trusted peer as the introducer (often the person who set the project up). Everyone else pairs *with the introducer* and passes `--as-introducer`:

```
/codesync-pair --peer <introducer-device-id> --as-introducer
```

Syncthing then automatically tells your machine about every other peer the introducer is connected to in the shared folder — you don't have to pair with them by hand. Total pairings drop from N×(N−1)/2 to roughly N.

**The flag is one-way and set on YOUR side.** When you pass `--as-introducer`, you are saying "*my* machine trusts this peer to introduce other teammates to *me*." The introducer themselves doesn't run `--as-introducer` — they just pair normally. Per Syncthing's own guidance, two peers should NOT mark each other as introducers; the relationship is intentionally directional.

**Workflow for a 3-person team (Alice = introducer, Bob and Carol join):**

1. Bob pairs with Alice using `--as-introducer`:
   ```
   /codesync-pair --peer <alice-device-id> --as-introducer
   ```
   Alice pairs back with Bob normally (no `--as-introducer` on Alice's side — she's the introducer, not the introduced).
2. Carol joins later. She runs the same as Bob did:
   ```
   /codesync-pair --peer <alice-device-id> --as-introducer
   ```
   Alice pairs back with Carol normally.
3. Bob's machine now learns about Carol automatically through Alice — no Bob↔Carol pairing needed. Carol's machine likewise learns about Bob through Alice. Same for every future teammate Alice adds.

**When to use it:**
- 2 people total → don't bother, just pair directly.
- 3+ people → pick one introducer; everyone else `--as-introducer`s through them. The introducer themselves does nothing special — they pair normally with each new teammate.

**Trust trade-off:** an introducer can add new devices to your Syncthing instance. Only mark someone as introducer if you'd be okay with them telling your machine about a new teammate. For most small teams that's fine; for adversarial settings, pair manually.

If you already paired with the introducer normally and want to upgrade, just rerun the pair command with `--as-introducer` — it's idempotent and only ever upgrades the flag, never downgrades.

## File layout inside a project

```
~/codesync/<project>/
├── CLAUDE.md                # project context, auto-loaded by Claude Code
├── _roles/                  # role definitions for this project
│   ├── backend.md
│   ├── frontend.md
│   └── README.md
├── _inbox/                  # role-addressed content
│   ├── backend/             # things addressed TO backend in this project
│   └── frontend/            # things addressed TO frontend in this project
└── _docs/                   # project-wide reference docs (shared with all roles)
    ├── ARCHITECTURE.md
    ├── CONVENTIONS.md
    ├── GLOSSARY.md
    └── README.md
```

When you have content for another role, drop it under `_inbox/<their-role>/`. When they reply, they drop it under `_inbox/<your-role>/`.

## Project-wide docs (`_docs/`) and `CLAUDE.md` auto-loading

Two pieces, working together, make every collaborator's Claude aware of project-wide context without anyone having to say "read the docs":

**`_docs/`** is a free-form directory of markdown reference files — architecture notes, conventions, glossary, decisions log, anything every collaborator should be able to read. Files sync to all paired peers within seconds. Create files by hand or with Claude; no slash command needed for creation. `/codesync-doc-list` shows what's there.

**`CLAUDE.md`** is dropped at the project root by `/install-codesync` and `/codesync-project-new`. Claude Code natively auto-loads any file named `CLAUDE.md` in the working directory or any ancestor — no plugin involvement needed for the loading itself. The starter template explains the folder layout, points the agent at `_docs/` for project-specific questions, and lists the slash commands the team uses. Edit it to add project-specific instructions (vocabulary, ways of working, "always check X before doing Y") and every collaborator's Claude picks them up after the next Syncthing sync.

**How agents reference docs automatically:**
- The session-start hook prints a one-line index of files in `_docs/` (filename + first heading) so agents know what exists.
- `CLAUDE.md` is loaded into every Claude Code session that starts in or near the project folder — telling agents to consult `_docs/` whenever relevant.
- Combined: agents have an index in context plus a standing instruction to consult `_docs/`. They reach for it without being explicitly told.

Edit conflicts: Syncthing is last-write-wins. If two collaborators edit the same doc at the same time, both versions are preserved under `.stversions/` for recovery — no automatic merge.

**For projects created before v0.14:** re-run `/install-codesync` and pick your existing project from the picker. The seeder is idempotent — it only adds the missing files (`_docs/` directory, `_docs/README.md`, `CLAUDE.md`) and leaves anything already in place.

## Threads — structured notes, tasks, and replies

A *thread* is a markdown file with a small YAML header that declares who wrote it, who it's for, what status it has, and (optionally) what earlier thread it replies to. Threads live in role-addressed inboxes inside a project: `_inbox/<recipient-role>/<slug>.md`.

### Frontmatter shape

```markdown
---
codesync:
  from: backend
  to: frontend
  status: todo            # todo | wip | done | blocked | note
  title: "Auth v2 endpoint ready to wire up"
  created: 2026-06-06T01:23:00Z
  replies-to: _inbox/backend/auth-v2-question.md   # optional, for replies
---

# Auth v2 endpoint ready to wire up

(write your note / task / discussion here)
```

Status semantics:
- `todo` / `wip` / `done` / `blocked` — actionable items the recipient role is meant to act on (or report back on).
- `note` — informational. No workflow expectation; just context, a decision, a question, an FYI, design discussion.

Roles aren't restricted to one status convention — same `to`-role can receive a mix of tasks and notes.

### Slash commands for threads

| Command | What it does |
|---|---|
| `/codesync-thread-new` | Interactive — asks who the thread is for, what status, what title, what body. Writes the file with frontmatter into the right inbox. Offers a project picker (existing + "New project") if no project is active in the terminal. |
| `/codesync-thread-list` | Lists threads in the active role's inbox, with status + title + sender + age. `--all` shows every role's inbox. `--status <s>` filters by status. `--archive` lists archived threads, `--include-archive` shows both. Offers a project picker (existing only) if no project is active. |
| `/codesync-thread-reply <slug>` | Creates a reply file addressed back to the original thread's sender, with `replies-to` set automatically. |
| `/codesync-thread-set-status <slug> <status>` | Moves a thread between `todo` / `wip` / `done` / `blocked` / `note` without opening the file. Atomic rewrite of the status field only. |
| `/codesync-thread-archive <slug>` | Moves a resolved or stale thread from `_inbox/<role>/` to `_archive/<role>/`. File preserved. |
| `/codesync-thread-unarchive <slug>` | Reverse of archive — moves an archived thread back into the active inbox. |

### Auto-check enrichment

When the post-turn Stop hook surfaces a new/changed thread file, it reads the frontmatter to show:

```
[codesync project=lead_inbox, role=backend] 1 change(s) for you:
  + [todo] Refactor lead inbox pagination (from frontend)  _inbox/backend/refactor-lead-inbox-pagination.md
```

Files without frontmatter (free-form markdown you write by hand) still surface, just without the status/title prefix.

## Status-line indicator (optional)

CodeSync can also surface unread-inbox counts in Claude Code's bottom **status line** — the same strip that shows things like "Remote Control active". When something new arrives in your inbox since the last Claude turn, you'll see:

```
codesync ▴ 3 new
```

next to whatever else is on your status line (netmeter, etc.). When the count is zero, codesync stays silent — no real estate used. The indicator is **per-terminal**: each Claude Code session shows the count for its active project + role.

### One-time install

```
/codesync-statusline-setup
```

That safely adds codesync to your `~/.claude/settings.json` statusLine. It backs up the file first, captures any existing statusLine command, and wraps both so they compose cleanly. The change is non-destructive — your existing setup (netmeter, etc.) keeps working.

To remove it later: `/codesync-statusline-teardown` — restores the prior statusLine command (or removes the entry entirely if there was none).

The status line refreshes every few seconds; after install the indicator appears at the bottom of your Claude Code window shortly. Sending any message forces an immediate refresh.

## Session-start summary

When you launch Claude Code in a terminal with `CODESYNC_PROJECT` (and `CODESYNC_ROLE`) set, the plugin's SessionStart hook surfaces what's waiting in your inbox before you type anything:

```
[codesync] Project: lead_inbox  Role: backend
  Inbox: 3 todo, 1 wip, 2 notes

    [todo]     Migrate to JSON Patch for partial updates (from frontend, 2d ago)
    [wip]      Lead inbox PR 3a (from backend, 5h ago)
    [todo]     Refactor pagination (from frontend, 3d ago)
    [note]     Auth v2 ready to wire (from backend, 1d ago)
    [note]     Feature-flag rollout plan (from devops, 6h ago)
    …and 2 more

  Run /codesync-thread-list to see them, or /codesync-thread-reply <slug> to respond.
```

When the inbox is empty, the hook stays silent. When `CODESYNC_PROJECT` is unset, it stays silent (matches Stop hook's fail-open posture). When project is set but role isn't, it nudges you to set the role.

## Archiving resolved threads

As threads accumulate, you'll want to move resolved/stale ones out of the active inbox without deleting them. Use `/codesync-thread-archive <slug>` — it moves the file from `_inbox/<role>/<slug>.md` to `_archive/<role>/<slug>.md`. The file is preserved with its frontmatter and body intact; it just stops appearing in `/codesync-thread-list`'s default view.

```
~/codesync/lead_inbox/
├── _inbox/<role>/        ← active work, surfaced everywhere
└── _archive/<role>/      ← preserved history, hidden by default
```

To see archived items: `/codesync-thread-list --archive` (only archive) or `/codesync-thread-list --include-archive` (both, with `[archived]` label on archived rows). To bring something back: `/codesync-thread-unarchive <slug>`.

Status (`todo`/`wip`/`done`/`blocked`/`note`) and archive are **orthogonal**: a `done` thread can stay in the inbox until acknowledged, then be archived; a `todo` thread can be archived if deferred. Two separate dials.

The post-turn auto-check and session-start summary continue to surface changes in `_archive/`, but with a `[archived]` prefix so they're visually distinct from active inbox work.

## Post-turn auto-check

After every Claude turn, a Stop hook walks the active project's folder and surfaces anything new/changed/deleted since the last check. When `CODESYNC_ROLE` is set, it filters to only items addressed to that role (under `_inbox/<role>/`) plus role-profile changes — other changes get a one-line "N changes outside your inbox" count.

When `CODESYNC_PROJECT` isn't set in a terminal, the hook stays silent.

## Slash command reference

| Command | What it does |
|---|---|
| `/install-codesync` | First-time setup: Syncthing, plus a project picker (existing or new) and a role picker (12 predefined roles with templates, multi-select for hybrid). |
| `/codesync-project-new` | Register an additional project. |
| `/codesync-project-list` | List all projects on this machine; mark the active one. |
| `/codesync-project-invite --peer <id> [--as-introducer]` | Invite an existing peer to the active project. Pass `--as-introducer` to let them introduce other peers automatically (3+ user teams). |
| `/codesync-project-attach <project> [<role>]` | Drop a `.codesync/project.json` marker in the current dir so terminals launched here auto-resolve the project. |
| `/codesync-pair --peer <id> [--as-introducer]` | Pair a brand-new peer at the device level and invite them to the active project in one step. Pass `--as-introducer` for the introducer pattern (see "Teams of 3+" above). |
| `/codesync-role-new` | Register one OR MORE roles (hybrid supported) in a project. Numbered picker of 12 predefined roles + "Custom"; each pick has a starter template you can edit. Offers a project picker (existing + "New project") if none is active, then offers to drop a `.codesync/project.json` marker in the current directory. |
| `/codesync-role-list` | List roles in the active project; mark the active one. |
| `/codesync-thread-new` | Start a new thread (note / task / decision / question) addressed to another role. Offers project + role pickers if either is unset in the terminal. |
| `/codesync-thread-list` | List threads in your role's inbox (or all inboxes with `--all`); filter by status. Offers a project picker if none active. |
| `/codesync-thread-reply <slug>` | Reply to an existing thread; auto-addresses the reply back to the original sender. |
| `/codesync-thread-set-status <slug> <status>` | Move a thread between `todo` / `wip` / `done` / `blocked` / `note` without hand-editing. |
| `/codesync-thread-archive <slug>` | Move a thread from `_inbox/<role>/` to `_archive/<role>/`. File preserved, just out of default views. |
| `/codesync-thread-unarchive <slug>` | Reverse of archive — bring an archived thread back into the active inbox. |
| `/codesync-doc-list` | List project-wide docs in `_docs/` — filename + first heading + size. Read-only; ask Claude to read any specific doc afterwards. |
| `/codesync-statusline-setup` | Install codesync's status-line segment (shows `codesync ▴ N new` in Claude Code's bottom bar when there are unread items). Backs up settings.json. |
| `/codesync-statusline-teardown` | Remove codesync's status-line segment; restore prior statusLine. |
| `/codesync-status` | Active project + role, Syncthing health, peers attached to the active project, folder sync state, registered roles. |

All commands except `/install-codesync` and `/codesync-project-new` require `CODESYNC_PROJECT` to be set in the terminal.

## Migration from earlier versions

If you installed v0.4.x (single `~/contracts/` folder, no projects), `/install-codesync` in v0.5.0 will run a one-time migration that:

- Asks for a name for your existing collaboration (default: `lead_inbox`).
- Moves `~/contracts/` → `~/codesync/<name>/`.
- Updates Syncthing to point at the new path (folder ID stays the same so sync survives).
- Rewrites `~/.config/codesync/config.json` to the new schema, preserving your API key and Device ID.
- Backs up the old config to `~/.config/codesync/config.json.v0.4.bak`.

Your collaborator runs the same migration when they update. Both of you pick the same project name so it lines up.

## What's coming

The originally planned scope is in. From here, real-world use will surface what's worth adding next.
