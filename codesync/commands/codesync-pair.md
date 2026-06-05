---
description: Pair this machine with a peer Syncthing device (and invite them to the active project's folder if CODESYNC_PROJECT is set)
argument-hint: "--peer <device-id> [--as-introducer]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/pair-peer.sh:*)"]
---

# Pair CodeSync with a peer

The user invoked `/codesync-pair $ARGUMENTS`. This is two operations bundled:

1. Adds the peer to Syncthing's known devices (machine-level).
2. If `CODESYNC_PROJECT` is set in this terminal, also invites the peer to that project's folder.

If you want to invite an already-paired peer to an additional project, use `/codesync-project-invite --peer <id>` from a terminal with `CODESYNC_PROJECT` set to that project.

## When to use `--as-introducer`

For teams of 3+ people, designate one peer as the **introducer** on each side. When you pair with an introducer using `--as-introducer`, Syncthing will automatically learn about every other peer the introducer is connected to — you don't have to pair with each teammate manually. This collapses N×(N−1) pairings down to roughly N.

Rule of thumb:
- 2 people: don't bother — just pair the two of you directly.
- 3+ people: pick one trusted peer (often the person who set the project up) as the introducer; everyone else pairs with that peer using `--as-introducer`.

Only set `--as-introducer` on someone you trust to route the team; an introducer can add new devices to your Syncthing instance.

## Step 1 — Parse the peer device ID

The arguments must contain `--peer <device-id>`. A Syncthing device ID is 56 base32 characters formatted as eight hyphen-separated groups of 7 (e.g. `ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ01-2345678-9ABCDEF-GHIJKLM-NOPQRST`). Be lenient on exact format, strict on "is this clearly a device ID" — Syncthing's own validation will reject anything malformed at the next step.

If `--peer` is missing, STOP and ask: *"Paste your colleague's CodeSync Device ID — they get it from running `/install-codesync` on their Mac."*

If `--peer` is present but the value clearly isn't a device ID (e.g., too short, contains spaces, looks like a name), STOP and re-ask.

## Step 2 — Run the pair script

Once step 1 has validated that the user supplied `--peer <device-id>`, run the pair script. The script reads `--peer` and `--as-introducer` directly from `$ARGUMENTS` — no Claude-side substitution is needed.

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/pair-peer.sh" $ARGUMENTS
```

The script is idempotent. Its last four lines are:

```
PAIRED_WITH=<peer device id>
PEER_SHORT_NAME=<short label assigned locally to the peer>
INVITED_TO=<project name or empty>
AS_INTRODUCER=<yes|no>
```

If the script exited non-zero, surface its error message and STOP.

## Step 3 — Tell the user what's next

Build a one-line introducer note: if `AS_INTRODUCER=yes`, set `INTRO_NOTE` to `"Marked as introducer — they can introduce you to other peers automatically."`; otherwise leave it empty.

If `INVITED_TO` is non-empty (the peer was also invited to the active project), print:

```
✓ Paired with peer <PAIRED_WITH> and invited them to project '<INVITED_TO>'.
   Local label:  <PEER_SHORT_NAME>
   <INTRO_NOTE if non-empty, otherwise omit this line>

Sync starts when BOTH machines have done the same. Have your collaborator
on their Mac run (with CODESYNC_PROJECT=<INVITED_TO> set in their shell):

   /codesync-pair --peer <your-device-id>

Then run /codesync-status here to confirm peers are connected and the
project folder is syncing.
```

If `INVITED_TO` is empty (no project was active when pairing happened), print:

```
✓ Paired with peer <PAIRED_WITH> at the device level.
   Local label:  <PEER_SHORT_NAME>
   <INTRO_NOTE if non-empty, otherwise omit this line>

No project was active in this terminal (CODESYNC_PROJECT was not set), so
no folder is being shared yet. To share a project with this peer, set
CODESYNC_PROJECT in your shell and run:

   /codesync-project-invite --peer <PAIRED_WITH>
```

## Constraints

- Never modify files outside Syncthing's own config (which the script mutates via REST API).
- Do not edit the pair script, the install script, or any other plugin file from this command.
- If the user passes anything other than `--peer <id>`, treat it as a parse error and ask again — don't try to "interpret" stray arguments.
