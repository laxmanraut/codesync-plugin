# codesync

A Claude Code plugin that lets collaborators on different laptops coordinate work through shared folders — no cloud service, no central server.

Backed by [Syncthing](https://syncthing.net) for peer-to-peer folder sync. The plugin organises work into **projects** (each its own Syncthing folder, with potentially different peers) and **roles** (the part you play within a project: backend, frontend, mobile, devops, whatever fits). Each terminal picks one project + role via environment variables, so the same laptop can act as different roles in different terminals — even across different projects.

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

A structured-thread format with YAML frontmatter on contract files (so the auto-check can also route by explicit metadata like `to: backend`, not just by inbox path). Plus CWD auto-detection of the active project (so `cd ~/code/lead_inbox` auto-sets `CODESYNC_PROJECT` for that terminal).
