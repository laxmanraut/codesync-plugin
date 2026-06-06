---
description: List threads in the active project's inbox for the active role (or all inboxes with --all)
argument-hint: "[--all] [--status <todo|wip|done|blocked|note>] [--archive | --include-archive]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh:*)", "Bash(python3:*)"]
---

# List CodeSync threads

The user invoked `/codesync-thread-list $ARGUMENTS`. Read the active project's inbox(es), parse frontmatter, print a structured listing.

`$ARGUMENTS` may contain:
- `--all` — list threads in every role's inbox, not just the active role's.
- `--status <s>` — filter to a status (`todo`, `wip`, `done`, `blocked`, `note`).
- `--archive` / `--include-archive` — show archived threads.

If no project is active in this terminal, the command starts with a project picker (existing projects only — this is read-only, so creating a new project here would be odd).

## Step 1 — Resolve the active project (and offer a picker if needed)

Run the resolver:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Output is two `KEY=VALUE` lines. Extract `CODESYNC_PROJECT=` value (strip quotes). Also capture `CODESYNC_ROLE=` value — used in Step 2.

If `CODESYNC_PROJECT` is non-empty AND that project exists in `~/.config/codesync/config.json`, set `PROJECT = <name>` and skip to Step 2.

Otherwise — project picker fallback:

Read the `projects` map from `~/.config/codesync/config.json`.

**If empty:** STOP and tell the user: *"No CodeSync projects exist on this machine yet. Run /install-codesync (or /codesync-project-new) first."*

**Otherwise:** print numbered picker (existing projects only — no "new project" option for a read-only command):

```
No project is active. Which project's threads do you want to list?

  1. lead_inbox
  2. mobile-app
  (etc.)

Pick one (1-N):
```

Parse pick. Set `PROJECT` to the chosen existing name.

## Step 2 — Determine the role filter

If `CODESYNC_ROLE` came back from the resolver (Step 1) AND `$ARGUMENTS` does NOT contain `--all`, the script will filter to that role's inbox. Pass through as-is.

If `CODESYNC_ROLE` is empty AND `$ARGUMENTS` does NOT contain `--all`, default to `--all` so the user sees something useful (every role's inbox) rather than an error. Append `--all` to the script invocation.

If `--all` is already in `$ARGUMENTS`, leave as-is regardless of role.

## Step 3 — Run the list script with the resolved project

The script reads `CODESYNC_PROJECT` (required) and `CODESYNC_ROLE` (required unless `--all`) from the environment. Since we may have resolved `PROJECT` via the picker (not the actual env), pass it explicitly as an inline env var. Substitute `<PROJECT>` BEFORE invoking; pass `$ARGUMENTS` (plus the optional `--all` from Step 2) verbatim:

```bash
CODESYNC_PROJECT="<PROJECT>" "${CLAUDE_PLUGIN_ROOT}/scripts/list-threads.sh" $ARGUMENTS
```

(If Step 2 decided to inject `--all`, append it: `... $ARGUMENTS --all`.)

## Step 4 — Show the output

The script's output is already human-readable. Print it verbatim to the user.

If the script reports zero threads, that's already explained in its output — no follow-up needed.

If the script errors, surface the error and STOP.

## Constraints

- This command is read-only. Do not modify any file or call any mutating Syncthing API endpoint.
- Pass through user args faithfully; don't infer additional filters they didn't ask for, EXCEPT the auto-`--all` fallback when role is unset (which prevents a confusing error).
- Step 1's project picker offers EXISTING projects only — no "New project" option for this read-only command.
