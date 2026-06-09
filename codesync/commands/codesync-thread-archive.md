---
description: Archive (or unarchive with --unarchive) a thread — moves the file between _inbox/ and _archive/, preserving its contents and any attachments
argument-hint: "<slug> [--unarchive]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/archive-thread.sh:*)"]
---

# Archive (or unarchive) a thread

The user invoked `/codesync-thread-archive $ARGUMENTS`.

**Default mode — archive.** Moves the thread from `_inbox/<role>/<slug>.md` to `_archive/<role>/<slug>.md`. Use this for resolved or stale threads to keep the active inbox clean.

**With `--unarchive`** — reverses the move, bringing the thread back from `_archive/` to `_inbox/`.

In both directions, any attachments (`<slug>.attachments/`) move along with the thread, and Syncthing replicates the move to every paired collaborator's machine.

## Step 1 — Parse args

`$ARGUMENTS` should contain a `<slug>` and optionally `--unarchive`.

If empty or no recognizable slug, STOP and ask: *"Which thread do you want to archive (or unarchive)? Pass the slug — e.g. `/codesync-thread-archive old-task`, or add `--unarchive` to reverse."* Suggest `/codesync-thread-list` (or `/codesync-thread-list --archive`) if they don't know.

## Step 2 — Run the archive script

Pass `$ARGUMENTS` through — the script handles `--unarchive`:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/archive-thread.sh" --slug $ARGUMENTS
```

The script prints either:
- **Archive**: `ARCHIVED=<dest>`, `FROM=<src>`, `ROLE=<role>`, `MOVED_ATTACHMENTS=<dir-or-empty>`
- **Unarchive** (`--unarchive` passed): `UNARCHIVED=<dest>`, `FROM=<src>`, `ROLE=<role>`, `MOVED_ATTACHMENTS=<dir-or-empty>`

If the script errors (thread not found, no project active, destination exists), surface and STOP.

## Step 3 — Tell the user

For **archive** success:
```
✓ Archived '<SLUG>' from <ROLE>'s inbox.
   Now at: <ARCHIVED>

The file is preserved — just out of /codesync-thread-list's default view.
Use /codesync-thread-list --archive to see archived threads, or
/codesync-thread-archive <SLUG> --unarchive to bring this one back.
```

For **unarchive** success:
```
✓ Unarchived '<SLUG>' back into <ROLE>'s inbox.
   Now at: <UNARCHIVED>
```

## Constraints

- Don't edit any other files.
- If the destination already exists (e.g. a thread of the same slug is already in the target folder), refuse — the script enforces this.
- Don't auto-archive based on status; only the explicit slug the user named.
