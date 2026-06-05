# codesync

A Claude Code plugin for coordinating work between AI-augmented collaborators across machines — no cloud service, no central server.

The mental model: each **project** is a peer-to-peer synced folder. Inside each project, work is **role-addressed** — backend, frontend, mobile, devops, whatever fits — via per-role inbox folders. Notes, tasks, design discussions, decisions, and questions flow through those inboxes, and Claude agents on each machine read and write them on behalf of their human. Each terminal picks one project + role, so the same laptop can act as different roles in different terminals — even across different projects.

Backed by [Syncthing](https://syncthing.net) for the actual peer-to-peer sync. Anything you write to a project folder ends up on your collaborator's machine within seconds (LAN) or minutes (over the internet). Anything they write ends up on yours.

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
3. Ask you to register your first **project** (e.g. `lead_inbox`, `mobile-app`). Each project becomes its own Syncthing folder at `~/codesync/<project>/`.
4. Walk you through registering your first **role** in that project — what you do, what you don't do.
5. Print the activation command:
   ```
   export CODESYNC_PROJECT=<project> CODESYNC_ROLE=<role>
   ```

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

## Adding another project

```
/codesync-project-new
```

Walks through naming + creates a new Syncthing folder + scaffold. After it runs, set `CODESYNC_PROJECT=<new-name>` in your shell (or use `cs <new-name> <role>`) and start `/codesync-role-new` inside the new project to register roles for it.

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

## File layout inside a project

```
~/codesync/<project>/
├── _roles/                  # role definitions for this project
│   ├── backend.md
│   ├── frontend.md
│   └── README.md
└── _inbox/                  # role-addressed content
    ├── backend/             # things addressed TO backend in this project
    └── frontend/            # things addressed TO frontend in this project
```

When you have content for another role, drop it under `_inbox/<their-role>/`. When they reply, they drop it under `_inbox/<your-role>/`.

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

### Three slash commands for threads

| Command | What it does |
|---|---|
| `/codesync-thread-new` | Interactive — asks who the thread is for, what status, what title, what body. Writes the file with frontmatter into the right inbox. |
| `/codesync-thread-list` | Lists threads in the active role's inbox, with status + title + sender + age. `--all` shows every role's inbox. `--status <s>` filters by status. |
| `/codesync-thread-reply <slug>` | Creates a reply file addressed back to the original thread's sender, with `replies-to` set automatically. |

### Auto-check enrichment

When the post-turn Stop hook surfaces a new/changed thread file, it reads the frontmatter to show:

```
[codesync project=lead_inbox, role=backend] 1 change(s) for you:
  + [todo] Refactor lead inbox pagination (from frontend)  _inbox/backend/refactor-lead-inbox-pagination.md
```

Files without frontmatter (free-form markdown you write by hand) still surface, just without the status/title prefix.

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

## Post-turn auto-check

After every Claude turn, a Stop hook walks the active project's folder and surfaces anything new/changed/deleted since the last check. When `CODESYNC_ROLE` is set, it filters to only items addressed to that role (under `_inbox/<role>/`) plus role-profile changes — other changes get a one-line "N changes outside your inbox" count.

When `CODESYNC_PROJECT` isn't set in a terminal, the hook stays silent.

## Slash command reference

| Command | What it does |
|---|---|
| `/install-codesync` | First-time setup: Syncthing, first project, first role. |
| `/codesync-project-new` | Register an additional project. |
| `/codesync-project-list` | List all projects on this machine; mark the active one. |
| `/codesync-project-invite --peer <id>` | Invite an existing peer to the active project. |
| `/codesync-pair --peer <id>` | Pair a brand-new peer at the device level and invite them to the active project in one step. |
| `/codesync-role-new` | Register a role in the active project (or update an existing one). |
| `/codesync-role-list` | List roles in the active project; mark the active one. |
| `/codesync-thread-new` | Start a new thread (note / task / decision / question) addressed to another role. |
| `/codesync-thread-list` | List threads in your role's inbox (or all inboxes with `--all`); filter by status. |
| `/codesync-thread-reply <slug>` | Reply to an existing thread; auto-addresses the reply back to the original sender. |
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

CWD auto-detection — so `cd ~/code/lead_inbox` automatically activates that project for the terminal (via a `.codesync/project.yaml` marker file the plugin walks up the directory tree to find), without having to `export CODESYNC_PROJECT=` manually each shell. Env var override stays for power users.

Possibly: a `/codesync-thread-set-status <slug> <status>` to move a task through `todo → wip → done` without re-opening the file. And a `/codesync-thread-archive` that moves resolved threads out of the active inbox into `_archive/`.
