---
description: Attach a directory to a project — writes .codesync/project.json so terminals launched here auto-detect the project without needing the env var
argument-hint: "<project> [<default-role>]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh:*)"]
---

# Attach the current directory to a project

The user invoked `/codesync-project-attach $ARGUMENTS`. This writes a small marker file (`.codesync/project.json`) in the current working directory. From then on, any Claude Code session launched from this directory (or any subdirectory) will auto-resolve `CODESYNC_PROJECT` (and optionally `CODESYNC_ROLE`) by walking up the directory tree looking for the marker — no shell exports needed.

Precedence: when the shell has `CODESYNC_PROJECT` or `CODESYNC_ROLE` exported, those still win. The marker is a per-directory **default**, not an override.

## Step 1 — Parse args

`$ARGUMENTS` should be `<project>` (required) or `<project> <default-role>` (role optional).

If args are empty or contain anything other than 1–2 lowercase identifiers, STOP and ask the user for `<project> [<default-role>]`.

Don't try to repair sloppy input — the marker file is small, the user should know what they're attaching.

## Step 2 — Run the attach script

Substitute `<PROJECT>` and `<ROLE>` (the second may be empty). Invoke Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh" --project "<PROJECT>" --role "<ROLE>"
```

If the user didn't supply a `<default-role>`, omit the `--role` flag entirely (don't pass an empty string).

The script prints:

```
ATTACHED=<absolute path to .codesync/project.json>
PROJECT=<project>
DEFAULT_ROLE=<role or empty>
```

If the script errors (project not registered, marker already exists), surface the error and STOP. If the error mentions `--force`, mention to the user that re-running with `--force` will overwrite.

## Step 3 — Tell the user what just happened

Print:

```
✓ Attached this directory to project '<PROJECT>'.
   Marker file: <ATTACHED>

Any Claude Code session launched from this directory (or a subdirectory)
will now resolve CODESYNC_PROJECT='<PROJECT>'<role suffix> automatically —
no shell exports needed.

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
