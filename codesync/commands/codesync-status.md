---
description: Show CodeSync health — Syncthing, peers, folder, registered roles (active project). When CODESYNC_PROJECT isn't set, lists all projects + roles on this machine instead.
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh:*)"]
---

# CodeSync status

The user invoked `/codesync-status`. Two modes:

- **Per-project mode** (when `CODESYNC_PROJECT` is set in the terminal): full health output for the active project — Syncthing reachable, peers connected, folder sync state, registered roles, etc.
- **Summary mode** (when `CODESYNC_PROJECT` is unset): lists every project on this machine, their paths, and which roles are registered for each. Replaces what used to be a separate `/codesync-project-list` and `/codesync-role-list`.

Run the status script and print its output verbatim:

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
