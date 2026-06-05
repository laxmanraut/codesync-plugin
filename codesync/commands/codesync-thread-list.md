---
description: List threads in the active project's inbox for the active role (or all inboxes with --all)
argument-hint: "[--all] [--status <todo|wip|done|blocked|note>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh:*)"]
---

# List CodeSync threads

The user invoked `/codesync-thread-list $ARGUMENTS`. Read the active project's inbox(es), parse frontmatter, print a structured listing.

`$ARGUMENTS` may contain:
- `--all` — list threads in every role's inbox, not just the active role's.
- `--status <s>` — filter to a status (`todo`, `wip`, `done`, `blocked`, `note`).

## Step 1 — Run the list script

The script reads `CODESYNC_PROJECT` (required) and `CODESYNC_ROLE` (required unless `--all`) from the environment. It accepts both `--all` and `--all-inboxes` so the user's args can be forwarded as-is:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh" $ARGUMENTS
```

## Step 2 — Show the output

The script's output is already human-readable. Print it verbatim to the user.

If the script reports zero threads, that's already explained in its output — no follow-up needed.

If the script errors (e.g., CODESYNC_PROJECT not set, or `--all` not given when CODESYNC_ROLE is also unset), surface the error and STOP.

## Constraints

- This command is read-only. Do not modify any file or call any mutating Syncthing API endpoint.
- Pass through user args faithfully; don't infer additional filters they didn't ask for.
