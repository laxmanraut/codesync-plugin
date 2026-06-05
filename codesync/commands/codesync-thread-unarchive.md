---
description: Bring an archived thread back into the active inbox (reverse of /codesync-thread-archive)
argument-hint: "<slug>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/unarchive-thread.sh:*)"]
---

# Unarchive a thread

The user invoked `/codesync-thread-unarchive $ARGUMENTS`. Move the thread from `_archive/<role>/<slug>.md` back to `_inbox/<role>/<slug>.md` in the active project.

## Step 1 — Parse the slug

`$ARGUMENTS` should be a single positional value: the thread's slug. If missing, STOP and ask; suggest `/codesync-thread-list --archive` to see what's archived.

## Step 2 — Run the unarchive script

Substitute `<SLUG>`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/unarchive-thread.sh" --slug "<SLUG>"
```

The script prints:

```
UNARCHIVED=<destination path>
FROM=<original archive path>
ROLE=<role-name>
```

If it errors (thread not found in any archive, no project active, inbox destination already exists), surface the message and STOP.

## Step 3 — Tell the user

Print:

```
✓ Unarchived '<SLUG>' back into <ROLE>'s inbox.
   Now at: <UNARCHIVED>

The thread will surface in /codesync-thread-list again. Its frontmatter
status is unchanged — if you want to mark it active in a different
state, use /codesync-thread-set-status <SLUG> <new-status>.
```

## Constraints

- Don't edit any other files.
- If the inbox destination already exists (e.g., a thread with that slug was created after archiving), refuse — the script enforces this.
