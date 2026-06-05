# codesync

A Claude Code plugin that lets two (or more) collaborators on different laptops have their Claude agents coordinate API work through a shared folder — no cloud service, no central server.

Backed by [Syncthing](https://syncthing.net) for peer-to-peer folder sync. Each install registers a role profile (`backend`, `mobile`, `devops`, anything you want) so that when one collaborator writes an API contract, the other's Claude agent knows whether to act on it.

## Requirements

- macOS (the install scripts use `brew services` and read Syncthing's config from `~/Library/Application Support/`)
- [Homebrew](https://brew.sh)
- [Claude Code](https://claude.com/claude-code)

## Install

In Claude Code:

```
/plugin marketplace add github:laxmanraut/codesync-plugin
/plugin install codesync@codesync-shared
```

Then on each machine, run:

```
/install-codesync
```

It will install Syncthing if needed, create `~/contracts/`, ask you to describe this machine's role, and print your Syncthing Device ID.

## Pair two machines

After each side has run `/install-codesync`, exchange Device IDs (printed by the install command or anytime by `/codesync-status`) and on each side run:

```
/codesync-pair --peer <the-other-machine's-device-id>
```

Pairing is symmetric and idempotent. Sync starts automatically once both sides have run the command.

Verify with:

```
/codesync-status
```

You should see the peer as `connected` and both role profiles listed under "Known roles".

## What's in here

- `codesync/` — the plugin itself (manifest, commands, scripts).
- `.claude-plugin/marketplace.json` — the marketplace index that lets Claude Code install the plugin from this repo.

## Slash commands

- `/install-codesync` — one-time setup: installs Syncthing, creates the shared folder, registers this machine's role.
- `/codesync-pair --peer <device-id>` — pair with a peer's Syncthing device and share the contracts folder.
- `/codesync-status` — read-only health check: Syncthing reachability, peers, folder state, registered roles.

## What's coming

A future slice will add `/request-api`, `/check-contracts`, `/fulfill-api` for the actual contract workflow on top of this synced foundation.
