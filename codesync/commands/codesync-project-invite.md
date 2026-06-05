---
description: Invite a peer to the active project's Syncthing folder (peer must already be device-paired or will be auto-added to known devices)
argument-hint: "--peer <device-id> [--as-introducer]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/invite-peer-to-project.sh:*)", "Bash(python3:*)"]
---

# Invite a peer to the active project

The user invoked `/codesync-project-invite $ARGUMENTS`. This adds a peer's Syncthing device to the active project's folder so that project's content syncs with them. It does NOT add them to *other* projects on this machine.

Pass `--as-introducer` if you want this peer to act as an introducer **on your side** — Syncthing will then auto-add other teammates this peer is connected to in this project's folder. The flag is one-way: you mark the introducer in your own config; they don't reciprocate. Most useful for teams of 3+; see `/codesync-pair` for the full explanation and trust trade-off. Omitting the flag does NOT downgrade a peer who was previously marked as an introducer.

## Step 1 — Confirm a project is active

Run the resolver (env first, then `.codesync/project.json` walk-up):

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Extract the value from `CODESYNC_PROJECT='<v>'` (strip single quotes). If empty, STOP: *"No project active in this terminal. Set CODESYNC_PROJECT in your shell or attach this directory with /codesync-project-attach <project>."*

The resolved value becomes `<PROJECT>`.

## Step 2 — Parse arguments

The arguments must contain `--peer <device-id>`. A Syncthing device ID is 56 base32 characters in eight hyphen-separated groups of 7. Be lenient on exact format, strict on "is this clearly a device ID".

If `--peer` is missing, STOP and ask: *"Paste your collaborator's CodeSync Device ID — they get it from running `/install-codesync` or `/codesync-status` on their Mac."*

Also check whether the user passed the optional `--as-introducer` flag — if present, you will forward it to the script in step 3.

## Step 3 — Run the invite script

Substitute `<PROJECT>` (from step 1) and `<PEER_ID>` (from step 2). Pick ONE of the two invocations below — with or without `--as-introducer` — based on whether the user passed it in `$ARGUMENTS`. Do NOT include square brackets in the command you actually run.

Without `--as-introducer`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/invite-peer-to-project.sh" --peer "<PEER_ID>" --project "<PROJECT>"
```

With `--as-introducer` (only if the user passed it):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/invite-peer-to-project.sh" --peer "<PEER_ID>" --project "<PROJECT>" --as-introducer
```

The script prints:

```
PROJECT=<project>
FOLDER_ID=<folder id>
INVITED=<peer device id>
PEER_SHORT_NAME=<short label>
AS_INTRODUCER=<yes|no>
```

If the script exited non-zero, surface its error and STOP.

## Step 4 — Tell the user what's next

If `AS_INTRODUCER=yes`, prepend an extra line: `"Marked as introducer — they can introduce other peers automatically."`. Then print:

```
✓ Invited peer to project '<PROJECT>'.
   <introducer line if AS_INTRODUCER=yes, otherwise omit>

Sync starts after BOTH machines have invited each other to the project.
Have your collaborator run on their Mac (with CODESYNC_PROJECT=<PROJECT>):

    /codesync-project-invite --peer <your-device-id>

Run /codesync-status to confirm both sides are connected and the project
folder is syncing.
```

## Constraints

- Never modify files outside Syncthing's own config (via REST API).
- Do not edit the invite script or any other plugin file from this command.
