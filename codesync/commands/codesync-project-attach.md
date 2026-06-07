---
description: Attach a directory to a project — writes .codesync/project.json so terminals launched here auto-detect the project, and optionally symlinks the project's CLAUDE.md
argument-hint: "<project> [<default-role>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh:*)"]
---

# Attach the current directory to a project

The user invoked `/codesync-project-attach $ARGUMENTS`. This writes a small marker file (`.codesync/project.json`) in the current working directory. From then on, any Claude Code session launched from this directory (or any subdirectory) will auto-resolve `CODESYNC_PROJECT` (and optionally `CODESYNC_ROLE`) by walking up the directory tree looking for the marker — no shell exports needed.

Precedence: when the shell has `CODESYNC_PROJECT` or `CODESYNC_ROLE` exported, those still win. The marker is a per-directory **default**, not an override.

This command also offers to **symlink the project's `CLAUDE.md`** into the current directory. That makes Claude Code's native CLAUDE.md auto-loading pick up project context from any session launched here — no plugin involvement needed for the loading itself. The symlink stays current as the synced version changes.

## Step 1 — Parse args

`$ARGUMENTS` should be `<project>` (required) or `<project> <default-role>` (role optional).

If args are empty or contain anything other than 1–2 lowercase identifiers, STOP and ask the user for `<project> [<default-role>]`.

Don't try to repair sloppy input — the marker file is small, the user should know what they're attaching.

## Step 2 — Ask whether to symlink CLAUDE.md

Check whether `CLAUDE.md` exists in the current directory (`$PWD/CLAUDE.md`).

- **If it doesn't exist:** ask the user *"Also symlink the project's CLAUDE.md into this directory so Claude Code auto-loads project context from sessions launched here? (yes/no, default yes)"*. Default to yes on a bare enter.
- **If it already exists** (regular file): tell the user *"You already have a CLAUDE.md here — keeping it. The synced project's CLAUDE.md will still be surfaced by the SessionStart hook."* — don't prompt; skip the symlink.
- **If it already exists as a symlink to the synced one:** tell the user *"CLAUDE.md is already symlinked here — no change needed."* — skip.

Capture the user's choice as `LINK_CLAUDE = yes` or `no`.

## Step 3 — Run the attach script

Substitute `<PROJECT>` and `<ROLE>`. Append `--link-claude-md` only if `LINK_CLAUDE = yes`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh" --project "<PROJECT>" --role "<ROLE>" [--link-claude-md]
```

If the user didn't supply a `<default-role>`, omit the `--role` flag entirely (don't pass an empty string). If `LINK_CLAUDE = no`, omit `--link-claude-md`.

The script prints:

```
ATTACHED=<absolute path to .codesync/project.json>
PROJECT=<project>
DEFAULT_ROLE=<role or empty>
LINKED_CLAUDE_MD=<absolute path to created symlink, or empty>
```

If the script errors (project not registered, marker already exists), surface the error and STOP. If the error mentions `--force`, mention to the user that re-running with `--force` will overwrite.

## Step 4 — Tell the user what just happened

Build the output. If `LINKED_CLAUDE_MD` is non-empty (from the script output in Step 3), include the CLAUDE.md line in the message.

```
✓ Attached this directory to project '<PROJECT>'.
   Marker file: <ATTACHED>
   <CLAUDE.md symlink: <LINKED_CLAUDE_MD>  (only if non-empty)>

Any Claude Code session launched from this directory (or a subdirectory)
will now resolve CODESYNC_PROJECT='<PROJECT>'<role suffix> automatically —
no shell exports needed.
<If CLAUDE.md was symlinked:>
Project conventions in CLAUDE.md will be auto-loaded by Claude Code on
every session launched here. Updates from collaborators flow through
because it's a symlink to the synced file.
<End if>
The env var still wins if you've exported one — CWD detection is the
fallback when env is unset.
```

Where `<role suffix>` is:
- ` and CODESYNC_ROLE='<DEFAULT_ROLE>'` if a default role was given
- empty otherwise

If a default role was set, also mention:

```
You can still override the role per-terminal with `export CODESYNC_ROLE=<other>`.
```

## Constraints

- Never modify files outside the current working directory and (Syncthing's config is unrelated here).
- Don't auto-commit the marker file to git. If the user wants to share the marker with their team, they commit it themselves; if they want it private, they `.gitignore` it.
- Do not edit the attach script or any other plugin file from this command.
