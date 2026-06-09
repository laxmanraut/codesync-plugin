---
description: Create a new CodeSync project (own Syncthing folder, own role definitions, can have different peers from other projects)
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh:*)"]
---

# Create a new CodeSync project

The user invoked `/codesync-project-new`. This command creates a new project: a dedicated Syncthing folder for that project's content, a `_roles/` directory for its role definitions, and an `_inbox/<role>/` structure for role-addressed content. Each project can be shared with a different set of peers.

## Step 1 — Ask for a project name

Ask the user:

> What's the name of this new project? Lowercase letters, digits, dashes, and underscores only (e.g. `mobile-app`, `marketing_site`). Pick something both you and your collaborators on this project will agree on — the name has to match across machines for sync to align.

Wait for the user's response.

Validate the name client-side:
- Lowercase only
- Must start with a letter or digit
- Only `a-z`, `0-9`, `-`, `_` allowed
- Don't pick a name that matches an existing project (run `/codesync-status` in a terminal without `CODESYNC_PROJECT` set first — it lists every project on this machine)

If the user types something invalid, re-ask with the specific reason.

## Step 2 — Run the create-project script

Use the Bash tool to invoke the script. CRITICAL: substitute `<NAME>` with the validated project name from step 1 BEFORE invoking Bash. The shell will expand `${CLAUDE_PLUGIN_ROOT}` itself at runtime.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --name "<NAME>"
```

The script prints:

```
PROJECT_NAME=<name>
PROJECT_PATH=<absolute path>
FOLDER_ID=codesync-<name>
```

Capture all three. If the script exits non-zero, surface its error and STOP.

## Step 3 — Tell the user what's next

Print exactly this template, substituting real values:

```
✓ Project '<PROJECT_NAME>' created.

  Path:        <PROJECT_PATH>
  Folder ID:   <FOLDER_ID>

To work in this project from this terminal, exit Claude Code and run:

    export CODESYNC_PROJECT=<PROJECT_NAME>

(Or use the `cs` wrapper: `cs <PROJECT_NAME> <role>` — see README.)

Then re-open Claude Code and run /codesync-role-new to register your
first role for this project. Once a role is registered, share the
project with a peer via /codesync-pair --peer <their-id> (with
CODESYNC_PROJECT set to this new project).
```

## Constraints

- Never modify files outside `~/codesync/<new-project>/`, `~/.config/codesync/config.json`, or Syncthing's own config.
- Do not edit the create-project script or any other plugin file from this command.
- If the user types a name that conflicts with an existing project, do NOT silently overwrite — the script will refuse; you should re-ask.
