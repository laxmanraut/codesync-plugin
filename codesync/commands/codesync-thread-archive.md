---
description: Move a resolved or stale thread out of the active inbox into _archive/ (preserves the file, just out of default views)
argument-hint: "<slug>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/archive-thread.sh:*)"]
---

# Archive a thread

The user invoked `/codesync-thread-archive $ARGUMENTS`. Move the thread from `_inbox/<role>/<slug>.md` to `_archive/<role>/<slug>.md` in the active project. The file is preserved — only its location changes — and Syncthing replicates the move to your collaborator's machine.

## Step 1 — Parse the slug

`$ARGUMENTS` should be a single positional value: the thread's slug (filename without `.md`).

If missing, STOP and ask the user for the slug. Run `/codesync-thread-list` if they want to see what's archivable.

## Step 2 — Run the archive script

Substitute `<SLUG>`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/archive-thread.sh" --slug "<SLUG>"
```

The script prints:

```
ARCHIVED=<destination path>
FROM=<original path>
ROLE=<role-name>
```

If it errors (thread not found, no project active, archive destination already exists), surface the message and STOP.

## Step 3 — Tell the user

Print:

```
✓ Archived '<SLUG>' from <ROLE>'s inbox.
   Now at: <ARCHIVED>

The file is preserved — just out of /codesync-thread-list's default view.
Use /codesync-thread-list --archive to see archived threads, or
/codesync-thread-unarchive <SLUG> to bring this one back.
```

## Constraints

- Don't edit any other files.
- If the archive destination already exists (somehow), refuse — the script enforces this.
- Don't auto-archive based on status; only the explicit slug the user named.
