---
description: Pair this machine with a peer Syncthing device and share the contracts folder
argument-hint: "--peer <device-id>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/pair-peer.sh:*)"]
---

# Pair CodeSync with a peer

The user invoked `/codesync-pair $ARGUMENTS`.

## Step 1 — Parse the peer device ID

The arguments must contain `--peer <device-id>`. A Syncthing device ID is 56 base32 characters formatted as eight hyphen-separated groups of 7 (e.g. `ABCDEFG-HIJKLMN-OPQRSTU-VWXYZ01-2345678-9ABCDEF-GHIJKLM-NOPQRST`). Be lenient on exact format, strict on "is this clearly a device ID" — Syncthing's own validation will reject anything malformed at the next step.

If `--peer` is missing, STOP and ask: *"Paste your colleague's CodeSync Device ID — they get it from running `/install-codesync` on their Mac."*

If `--peer` is present but the value clearly isn't a device ID (e.g., too short, contains spaces, looks like a name), STOP and re-ask.

## Step 2 — Run the pair script

Once step 1 has validated that the user supplied `--peer <device-id>`, run the pair script. The script reads the user's `--peer` argument directly from `$ARGUMENTS` — no Claude-side substitution is needed.

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/pair-peer.sh" $ARGUMENTS
```

The script is idempotent. Its last two lines are:

```
PAIRED_WITH=<peer device id>
PEER_SHORT_NAME=<short label assigned locally to the peer>
```

If the script exited non-zero, surface its error message and STOP.

## Step 3 — Tell the user what's next

Print exactly this template (substituting real values):

```
✓ Paired with peer <PAIRED_WITH>.
   Local label:  <PEER_SHORT_NAME>

Pairing is symmetric — sync starts automatically once BOTH machines have
run /codesync-pair. If your colleague hasn't run it yet, send them your
own Device ID (find it with /codesync-status) and have them run on their
Mac:

   /codesync-pair --peer <your-device-id>

Then run /codesync-status here to confirm both machines are connected
and the contracts folder is syncing.
```

## Constraints

- Never modify files outside Syncthing's own config (which the script mutates via REST API).
- Do not edit the pair script, the install script, or any other plugin file from this command.
- If the user passes anything other than `--peer <id>`, treat it as a parse error and ask again — don't try to "interpret" stray arguments.
