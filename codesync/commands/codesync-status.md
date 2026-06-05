---
description: Show the health of the CodeSync setup on this machine — Syncthing, peers, folder, and registered roles
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh:*)"]
---

# CodeSync status

The user invoked `/codesync-status`. Run the status script and print its output verbatim:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

If the script exited non-zero, surface its error.

After printing the script's output, add ONE short follow-up line ONLY if you spot an issue the script's own output doesn't already address with a next step. Examples of when to add a follow-up:

- All peers show `DISCONNECTED` → "Sync is paired but neither side is online — check your colleague's Mac is on and Syncthing is running there."
- Folder state is `error` or `stopped` → "Folder is in an error state — check the Syncthing web UI at http://127.0.0.1:8384 for the underlying cause."

If the script already explained the next step inline (e.g., "(none — run /codesync-pair --peer <id> to add one)"), do NOT add a redundant follow-up. Stay quiet.

## Constraints

- This command is read-only. Do not edit any files, do not call any mutating Syncthing API endpoint, do not run any script other than the one above.
