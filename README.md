# codesync

A Claude Code plugin that lets two (or more) collaborators on different laptops have their Claude agents coordinate API work through a shared folder — no cloud service, no central server.

Backed by [Syncthing](https://syncthing.net) for peer-to-peer folder sync. Each *machine* registers one or more role profiles (`backend`, `mobile`, `devops`, anything you want). Each *terminal* activates one of those roles via an environment variable, so the same laptop can act as different roles in different terminals.

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

The `marketplace update` and `reload-plugins` steps refresh Claude Code's local plugin cache — without them, the install can complain that the plugin isn't there.

## First-time setup

```
/install-codesync
```

This will:

1. Install Syncthing via Homebrew if needed and start it as a background service.
2. Create `~/contracts/` and register it as a Syncthing folder.
3. Print this machine's Syncthing **Device ID** — copy it; you'll share it with collaborators when pairing.
4. Ask you to describe a role in your own words — what it does, what it doesn't do, anything else worth knowing. Claude formats your answer into a clean role profile saved to `~/contracts/_roles/<role>.md`.
5. Print the activation line for that role:

   ```
   export CODESYNC_ROLE=<role-name>
   ```

## Activating a role in a terminal

Roles are **per-terminal**. Each shell decides which role this Claude Code session is acting as via the `CODESYNC_ROLE` environment variable. This lets the same laptop work as backend in one terminal and mobile in another, simultaneously.

The minimum required to activate:

```
# In your shell, before launching Claude Code:
export CODESYNC_ROLE=backend
claude
```

Inside Claude Code, run `/codesync-status` to confirm the role is active.

### A nicer wrapper for `~/.zshrc`

Most people want a one-word command to switch roles. Add this to your `~/.zshrc` (or `~/.bashrc`):

```bash
cs() {
  if [ $# -eq 0 ]; then
    echo "Usage: cs <role>   # e.g. cs backend"
    [ -n "$CODESYNC_ROLE" ] && echo "Current: CODESYNC_ROLE=$CODESYNC_ROLE"
    return 1
  fi
  export CODESYNC_ROLE="$1"
  echo "Active CodeSync role for this terminal: $CODESYNC_ROLE"
}
```

After reloading your shell (`source ~/.zshrc`), switching roles per terminal becomes:

```
$ cs backend
$ claude
> /codesync-status
  Active role (this terminal): backend ✓
```

Open a second terminal, run `cs mobile && claude`, and that session acts as `mobile` while the first stays on `backend`.

## Pair two machines

After each side has run `/install-codesync`, exchange Device IDs (printed by install or anytime by `/codesync-status`) and on **each side** run:

```
/codesync-pair --peer <the-other-machine's-device-id>
```

Pairing is symmetric and idempotent. Sync starts automatically once both sides have run the command. Verify with:

```
/codesync-status
```

You should see the peer as `connected` and any role profiles synced from the other machine listed under "Known roles".

## Adding more roles later

You're not limited to one role per machine. To register an additional role on a machine that's already set up:

```
/codesync-role-new
```

Same interactive flow as the role step inside `/install-codesync`. To see all registered roles:

```
/codesync-role-list
```

Marks which one (if any) is active in the current terminal.

## Slash commands

| Command | What it does |
|---|---|
| `/install-codesync` | First-time setup: install Syncthing, create `~/contracts/`, register the first role for this machine. |
| `/codesync-pair --peer <device-id>` | Pair with a peer's Syncthing device. |
| `/codesync-status` | Read-only health check: active role for this terminal, Syncthing health, peers, folder state, all known roles. |
| `/codesync-role-new` | Register an additional role or update an existing one. |
| `/codesync-role-list` | List all roles registered on this machine (and synced from paired machines). |

## What's in here

- `codesync/` — the plugin itself (manifest, commands, scripts).
- `.claude-plugin/marketplace.json` — the marketplace index that lets Claude Code install the plugin from this repo.

## What's coming

A future slice will add `/request-api`, `/check-contracts`, `/fulfill-api` for the actual contract workflow on top of this synced foundation. The contract commands will read `CODESYNC_ROLE` to decide which contracts the current terminal should act on.
