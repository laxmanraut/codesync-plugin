---
description: List threads in the active project's inbox for the active role (or all inboxes with --all)
argument-hint: "[--all] [--status <todo|wip|done|blocked|note>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh:*)"]
---

# List CodeSync threads

The user invoked `/codesync-thread-list $ARGUMENTS`. Read the active project's inbox(es), parse frontmatter, print a structured listing.

## Step 1 — Parse args

`$ARGUMENTS` may contain:
- `--all` — list threads in every role's inbox, not just the active role's.
- `--status <s>` — filter to that status: `todo`, `wip`, `done`, `blocked`, `note`.

Translate to the script's flags:
- `--all` in args → `--all-inboxes` script flag.
- `--status <s>` in args → `--status <s>` script flag.

If no args, just list the active role's inbox unfiltered.

## Step 2 — Run the list script

The script reads `CODESYNC_PROJECT` (required) and `CODESYNC_ROLE` (required unless `--all-inboxes`) from the environment. Just pass the translated args through:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh" $ARGUMENTS
```

(`$ARGUMENTS` is forwarded as-is; the script accepts the same flags as the user types, with `--all` mapped to `--all-inboxes` — actually, this is a slight mismatch. If the user typed `--all`, normalise it before invoking. See alternative below.)

**If the user passed `--all` rather than `--all-inboxes`, run the script via the Bash tool with the right flag substituted:**

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh" --all-inboxes
```

(Add `--status <s>` if the user supplied that too.)

## Step 3 — Show the output

The script's output is already human-readable. Print it verbatim to the user.

If the script reports zero threads, that's already explained in its output — no follow-up needed.

If the script errors (e.g., CODESYNC_PROJECT not set), surface the error and STOP.

## Constraints

- This command is read-only. Do not modify any file or call any mutating Syncthing API endpoint.
- Pass through user args faithfully; don't infer additional filters they didn't ask for.
