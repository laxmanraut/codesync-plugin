---
description: One-time setup — install Syncthing on this machine and register a first project + role
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/install-syncthing.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/migrate-v0.5.0.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh:*)", "Bash(python3:*)"]
---

# Install CodeSync

The user invoked `/install-codesync`.

This command:
1. Installs Syncthing on this machine and reads its Device ID + API key.
2. Migrates a legacy v0.4.x layout if one is found.
3. Otherwise, asks the user for a first project name and registers it.
4. Walks the user through creating the first role in that project.

It is interactive — work through the steps in order; do not skip ahead.

## Step 1 — Run the install script

The install script is idempotent (safe to re-run). Execute:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/install-syncthing.sh"
```

The script's last line is:

```
DEVICE_ID=<this machine's syncthing device id>
```

Capture the DEVICE_ID value. If the script exited non-zero, surface its error message to the user and STOP.

## Step 2 — Detect whether migration is needed

Read `~/.config/codesync/config.json`. If it contains a top-level `contracts_dir` field (v0.4.x schema) AND no `projects` map, a migration is needed.

If migration IS needed:

1. Tell the user: *"I found an older v0.4.x layout from before projects were introduced. I need to migrate it. What's the name of this existing collaboration? It will become the name of the project (default: `lead_inbox`)."*
2. Wait for the user's response. Default to `lead_inbox` if they press enter.
3. Validate the name (lowercase letters, digits, dashes, underscores only). If invalid, re-ask.
4. Run the migration script with the chosen name. Substitute `<NAME>` BEFORE invoking Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/migrate-v0.5.0.sh" "<NAME>"
```

5. The script prints `MIGRATED_PROJECT=<name>`, `PROJECT_PATH=<path>`, `FOLDER_ID=<id>`. Capture those.
6. Set `ACTIVE_PROJECT = <name>`, `PROJECT_PATH = <path>`.
7. Skip to Step 4 (role registration).

If migration is NOT needed, continue to Step 3.

## Step 3 — Set up the first project (fresh install or no projects yet)

Read the `projects` map from `~/.config/codesync/config.json`.

If the map is empty:

1. Ask the user: *"What's the name of your first project? Pick something both you and your collaborators will agree on (it has to match across machines). Lowercase letters, digits, dashes, and underscores only (e.g. `mobile-app`, `lead_inbox`)."*
2. Validate the name. Re-ask if invalid.
3. Run create-project. Substitute `<NAME>` BEFORE invoking Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --name "<NAME>"
```

4. The script prints `PROJECT_NAME`, `PROJECT_PATH`, `FOLDER_ID`. Capture them.
5. Set `ACTIVE_PROJECT = <name>`, `PROJECT_PATH = <path>`.

If the map already has projects (the plugin's already been installed once):

1. List them and ask: *"You already have these projects on this machine: [list]. Want to register a role in one of those, or create a new project? (Type a project name to pick one, or type 'new' to create a fresh project.)"*
2. If they say `new`, fall through to the project-creation flow above.
3. Otherwise, set `ACTIVE_PROJECT` to the chosen name and `PROJECT_PATH` to its path from config.

## Step 4 — Read existing role profiles in the active project

List the `.md` files in `<PROJECT_PATH>/_roles/`, **ignoring `README.md`**. For each remaining file, read its full content — these are the roles already registered on this machine or synced from paired peers.

Hold those profiles for the conflict check in Step 6. If there are no role files yet, there's nothing to compare against — proceed.

## Step 5 — Ask the user about the role

Ask the user EXACTLY this question:

> Tell me about this role on this machine, in project '<ACTIVE_PROJECT>'.
>
> Cover three things in your own words:
> - **What you do** (the work you'll handle)
> - **What you don't do** (so your collaborator's Claude doesn't misroute things to you)
> - **Anything else** worth knowing — stack, hours, preferences
>
> A few sentences or bullets — whatever feels natural. Examples:
> - *"Backend — Python on Postgres. I own auth, REST endpoints, background jobs. I don't touch the UI or anything infra. FastAPI stack."*
> - *"I build the React frontend and the React Native mobile app. UI, client state, accessibility. Not backend, not deploys. Available 09:00–18:00 IST."*

Wait for the user's response.

## Step 6 — Parse the response and check for conflicts

From the user's response, extract:

- **`role-name`** — kebab-case identifier (`backend`, `mobile`, `devops`, `data-eng`). Infer if not stated explicitly; ask ONE clarifying question if genuinely ambiguous.
- **`owns`** — bullet list of what the role is responsible for.
- **`does-not-own`** — bullet list of what the role explicitly avoids. If the user didn't address this, ASK ONCE; if they decline, write `- (not specified)`.
- **`notes`** — anything else from the response.

Conflict-check against the existing role profiles from Step 4:

1. **Name collision** — `<role-name>.md` already exists. Show its current content and ask whether the user is updating that role (overwrite is fine), whether this is a different role under the same name (pick a different name), or whether to abort.
2. **Semantic duplicate** — different filename but `Owns` overlaps heavily. Ask which is the canonical name.
3. **Responsibility overlap** — `Owns` includes an item another role also claims. Ask which role should own it, update accordingly.

Resolve before continuing.

## Step 7 — Show the proposed role profile

Format as Markdown (omit the `Notes` section entirely if `notes` is empty):

```
# <role-name>

## Owns
- <bullet>
- <bullet>

## Does not own
- <bullet>
- <bullet>

## Notes
<free-form notes>
```

Print and ask:

> This is how your role will appear to paired machines. Look right?
>
> - reply **yes** to write it
> - reply **edit** and tell me what to change
> - reply **cancel** to abort without writing anything

Loop until yes or cancel. If *cancel*, STOP without writing anything.

## Step 8 — Write the role file

Once confirmed, write the role profile to `<PROJECT_PATH>/_roles/<role-name>.md` with the exact markdown from Step 7.

Do NOT write the role name anywhere else — roles are activated per-terminal via `CODESYNC_ROLE`, not stored machine-wide.

## Step 9 — Tell the user what's next

Print this template (substituting real values):

```
✓ CodeSync installed on this machine.

  Device ID:       <DEVICE_ID>
  Active project:  <ACTIVE_PROJECT>
  Project path:    <PROJECT_PATH>
  Role profile:    <PROJECT_PATH>/_roles/<role-name>.md

To work as this role in THIS terminal, exit Claude Code and run in your shell:

    export CODESYNC_PROJECT=<ACTIVE_PROJECT>
    export CODESYNC_ROLE=<role-name>

(Or use the `cs` wrapper from the README: `cs <ACTIVE_PROJECT> <role-name>`.)

Then re-open Claude Code. /codesync-status will confirm both are active.

Roles AND projects are per-terminal — set them separately in each shell where
you want to act. The same laptop can run multiple terminals each on a
different project + role combo.

Next steps:
  1. Send the Device ID above to your collaborator.
  2. On their Mac they install this plugin and run /install-codesync.
     They'll describe their own role and get their own Device ID back.
     IMPORTANT: when they install, the project name must match exactly
     (yours: '<ACTIVE_PROJECT>') for sync to align.
  3. Pair the machines symmetrically — each side runs once, with
     CODESYNC_PROJECT=<ACTIVE_PROJECT> set in their shell:
        /codesync-pair --peer <other-machine's-device-id>
     Sync starts automatically once both sides have done it.
  4. Verify with /codesync-status.

To register an additional role in this project later, run /codesync-role-new.
To register a separate project, run /codesync-project-new.
```

## Constraints

- Never modify files outside `~/.config/codesync/`, `~/codesync/<project>/`, or Syncthing's own config.
- Never write the role file without showing it to the user and getting explicit confirmation.
- If a conflict was raised in Step 6 and the user didn't resolve it, STOP — don't write a conflicting profile.
- Do not edit the install / migration / create-project scripts or any other plugin files from this command.
- If `~/.config/codesync/config.json` doesn't exist after Step 1 (which would indicate a script failure), STOP — re-running the install script is the right next move, not improvising.
