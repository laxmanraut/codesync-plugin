---
description: Update the status of a thread (todo / wip / done / blocked / note) without hand-editing the file
argument-hint: "<slug> <status>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/set-thread-status.sh:*)"]
---

# Set a thread's status

The user invoked `/codesync-thread-set-status $ARGUMENTS`. Update the `status` field in a thread's frontmatter to a new value, atomically.

## Step 1 — Parse the args

`$ARGUMENTS` should be two positional values: `<slug> <status>`.

- `<slug>` is the filename without `.md` (e.g. `owner-inbox`, `auth-flow-refactor`). Run `/codesync-thread-list` if unsure.
- `<status>` must be one of: `todo`, `wip`, `done`, `blocked`, `note`.

If either is missing or `<status>` isn't one of the valid values, STOP and ask the user to fix the invocation. Do NOT guess.

## Step 2 — Run the script

Substitute `<SLUG>` and `<STATUS>` BEFORE invoking Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/set-thread-status.sh" --slug "<SLUG>" --status "<STATUS>"
```

The script prints two lines on success:

```
Updated status: <old> → <new>
FILE=<absolute path>
```

Or, when the status already matches:

```
Status already '<status>' — no change.
FILE=<absolute path>
```

If the script exits non-zero, surface its error (it gives helpful messages — e.g., "Thread '<slug>' not found", "File has no codesync frontmatter").

## Step 3 — Tell the user

Print the script's output verbatim, then add ONE short context line if useful:

- If status changed from `todo` to `wip` and the user is the addressee (`to:` role of the file), suggest *"You're now showing this as in-progress — your collaborator will see the status flip on their next session-start summary."*
- If status changed to `done`, suggest *"Marking this done. Your collaborator can run `/codesync-thread-list --status done` to see completed items."*
- If no change was made (idempotent path), no follow-up.

Don't be chatty about it. One sentence at most.

## Constraints

- Don't edit any file directly. The script handles the atomic write.
- Don't try to update other frontmatter fields (`title`, `to`, etc.) from this command — only status. Other edits are user's job for now.
- Refuse to operate on files lacking codesync frontmatter (the script enforces this; surface its error).
