---
description: Invite a peer to the active project's Syncthing folder (peer must already be device-paired or will be auto-added to known devices)
argument-hint: "--peer <device-id>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/invite-peer-to-project.sh:*)", "Bash(python3:*)"]
---

# Invite a peer to the active project

The user invoked `/codesync-project-invite $ARGUMENTS`. This adds a peer's Syncthing device to the active project's folder so that project's content syncs with them. It does NOT add them to *other* projects on this machine.

## Step 1 — Confirm a project is active

Run the resolver (env first, then `.codesync/project.json` walk-up):

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Extract the value from `CODESYNC_PROJECT='<v>'` (strip single quotes). If empty, STOP: *"No project active in this terminal. Set CODESYNC_PROJECT in your shell or attach this directory with /codesync-project-attach <project>."*

The resolved value becomes `<PROJECT>`.

## Step 2 — Parse the peer device ID

The arguments must contain `--peer <device-id>`. A Syncthing device ID is 56 base32 characters in eight hyphen-separated groups of 7. Be lenient on exact format, strict on "is this clearly a device ID".

If `--peer` is missing, STOP and ask: *"Paste your collaborator's CodeSync Device ID — they get it from running `/install-codesync` or `/codesync-status` on their Mac."*

## Step 3 — Run the invite script

Substitute `<PROJECT>` (from step 1) and `<PEER_ID>` (from step 2):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/invite-peer-to-project.sh" --peer "<PEER_ID>" --project "<PROJECT>"
```

The script prints:

```
PROJECT=<project>
FOLDER_ID=<folder id>
INVITED=<peer device id>
PEER_SHORT_NAME=<short label>
```

If the script exited non-zero, surface its error and STOP.

## Step 4 — Tell the user what's next

Print:

```
✓ Invited peer to project '<PROJECT>'.

Sync starts after BOTH machines have invited each other to the project.
Have your collaborator run on their Mac (with CODESYNC_PROJECT=<PROJECT>):

    /codesync-project-invite --peer <your-device-id>

Run /codesync-status to confirm both sides are connected and the project
folder is syncing.
```

## Constraints

- Never modify files outside Syncthing's own config (via REST API).
- Do not edit the invite script or any other plugin file from this command.
