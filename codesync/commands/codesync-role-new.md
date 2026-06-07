---
description: Register one or more role profiles in the active project (or pick a project first if none is active)
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/register-role-in-config.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/seed-project-docs.sh:*)", "Bash(python3:*)"]
---

# Register CodeSync role(s)

The user invoked `/codesync-role-new`. This adds one OR MORE role profiles in a project's `_roles/` directory. Roles are *definitions* shared via Syncthing with all peers invited to the project. **Activation** in a given terminal is separate — set `CODESYNC_ROLE` in the shell to wear that hat for outgoing messages. This command only creates the definitions.

If no project is active in this terminal, the command starts with a project picker (existing projects + "New project" option). After picking, it walks through the role picker the same way `/install-codesync` does.

## Step 1 — Resolve the active project (if any)

Run the resolver (checks env var, then walks up looking for `.codesync/project.json`):

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Output is two `KEY=VALUE` lines. Extract the value after `CODESYNC_PROJECT=` (strip surrounding single quotes).

If `CODESYNC_PROJECT` is non-empty AND that project exists in `~/.config/codesync/config.json`, set `ACTIVE_PROJECT = <name>` and `PROJECT_PATH` from `projects.<name>.path`, then skip to Step 3.

If `CODESYNC_PROJECT` is empty (or set but unregistered), continue to Step 2.

## Step 2 — Project picker fallback

Read the `projects` map from `~/.config/codesync/config.json`.

**Case A — No projects registered yet:**

Ask the user: *"No CodeSync project is set up yet. What should the first one be called? Pick a name both you and your collaborators will agree on — it must match exactly across machines. Lowercase letters, digits, dashes, and underscores only (e.g. `lead_inbox`, `mobile-app`)."*

Validate (regex `^[a-z0-9][a-z0-9_-]*$`). Re-ask if invalid.

Run create-project. Substitute `<NAME>` before invoking Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --name "<NAME>"
```

Capture `PROJECT_NAME`, `PROJECT_PATH` from the script output. Set `ACTIVE_PROJECT` and `PROJECT_PATH` accordingly.

**Case B — Projects already registered:**

Print a numbered picker:

```
No project is active in this terminal. Which project is this role for?

  1. lead_inbox       (/Users/you/codesync/lead_inbox)
  2. mobile-app       (/Users/you/codesync/mobile-app)
  3. New project (enter name)

Pick one (1-3):
```

Wait for the user's number. Validate it's in range. Re-ask on invalid input.

- If they pick an existing project: set `ACTIVE_PROJECT` and `PROJECT_PATH` from config.
- If they pick "New project": ask for the name (validate as in Case A), then run `create-project.sh --name "<NAME>"`. Capture outputs.

## Step 2b — Backfill project docs scaffold (idempotent)

If the project came from the picker in Step 2 (not from a pre-existing env var or marker), run the docs seeder. It's idempotent — does nothing for projects that already have `_docs/` and `CLAUDE.md`:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/seed-project-docs.sh" --project "<ACTIVE_PROJECT>" --path "<PROJECT_PATH>"
```

The script prints `CREATED=<comma-separated>`. If non-empty, tell the user briefly which files were added (e.g., *"Scaffolded `_docs/` and `CLAUDE.md` for this project."*). If empty, stay quiet.

## Step 3 — Read existing role profiles in the active project

List the `.md` files in `<PROJECT_PATH>/_roles/`, **ignoring `README.md`**. For each, read full content. These are the existing roles (yours and synced peers').

Hold for conflict check in Step 5. If empty, proceed.

## Step 4 — Role picker (multi-select)

Read the role catalog from `${CLAUDE_PLUGIN_ROOT}/scripts/lib/roles.json`. Shape:

```json
{"categories": [{"name": "Engineering", "roles": [{"name": "backend", "display": "Backend", "owns": [...], "does_not_own": [...]}, ...]}, ...]}
```

Render one numbered picker, grouped by category, with "Custom (free-form)" last:

```
Pick one or more roles to register in "<ACTIVE_PROJECT>"
(comma-separated numbers — e.g. "5,7" for PM + Designer):

  Engineering
    1. Backend
    2. Frontend
    3. Mobile
    4. DevOps / Platform

  Product & Design
    5. Product Manager
    6. Product Owner
    7. Designer (UI/UX)
    8. Tech Writer

  Project & People
    9. Project Manager
   10. Engineering Manager
   11. Tech Lead
   12. QA / Test

  13. Custom (free-form — describe your own role)

Your pick:
```

Parse comma-separated numbers. Validate range. Re-ask on invalid input.

Build `PICKED_ROLES` — each entry is either a predefined role object or the literal `"custom"`.

If multiple roles were picked, briefly tell the user: *"Got it — you'll register N roles in this project: \<list of displays\>. I'll walk through them one at a time."*

## Step 5 — For each picked role: propose, conflict-check, confirm, write

Initialize `REGISTERED_ROLE_NAMES = []`.

For each entry in `PICKED_ROLES`, in order:

### Predefined role (has `name`, `owns`, `does_not_own`)

1. Build proposed markdown:

```
# <name>

## Owns
- <each item from owns>

## Does not own
- <each item from does_not_own>
```

2. Run the conflict check (see Step 5b below) against the existing profiles read in Step 3.

3. Show and ask:

> Here's the proposed profile for **<display>** (`<name>`):
>
> \<markdown\>
>
> Look right?
> - reply **yes** to write it
> - reply **edit** and tell me what to change
> - reply **skip** to drop this role

If *edit*: revise and re-show. Loop until yes or skip.

If *yes*: write `<PROJECT_PATH>/_roles/<name>.md`. Append `name` to `REGISTERED_ROLE_NAMES`.

### Custom role (`"custom"`)

1. Ask:

> Tell me about this custom role.
>
> Cover three things:
> - **What it does**
> - **What it doesn't do**
> - **Anything else** — stack, hours, preferences

2. Parse the response into `role-name` (kebab-case), `owns`, `does-not-own` (ask once if missing), `notes`.

3. Run the conflict check (Step 5b).

4. Format markdown:

```
# <role-name>

## Owns
- <bullet>

## Does not own
- <bullet>

## Notes
<notes if any, otherwise omit the Notes section entirely>
```

5. Show with the yes/edit/skip prompt. On yes, write to `<PROJECT_PATH>/_roles/<role-name>.md` and append to `REGISTERED_ROLE_NAMES`.

### Step 5b — Conflict check (run inline within Step 5 per role)

Compare the role-name being written against existing profiles:

1. **Name collision** — `<role-name>.md` exists. Show its content. Ask whether to update (overwrite OK), rename, or skip.
2. **Semantic duplicate** — different filename, `Owns` overlaps heavily. Show both. Ask which is canonical.
3. **Responsibility overlap** — `Owns` claims something another role also claims. Ask which should own it.

If unresolved, skip writing this role; continue to next.

## Step 6 — Register roles in config

Skip if `REGISTERED_ROLE_NAMES` is empty.

Build a Bash command that passes one `--role <name>` per role. Substitute `<ACTIVE_PROJECT>` and each `<ROLE>` before invoking:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/register-role-in-config.sh" --project "<ACTIVE_PROJECT>" --role "<ROLE_1>" --role "<ROLE_2>"
```

The script prints `REGISTERED_ROLES=<comma-separated>`. If it errors, surface and STOP.

## Step 7 — Offer to drop a project marker in cwd

Skip this entire step if `ACTIVE_PROJECT` came from `CODESYNC_PROJECT` or from an already-existing marker (Step 1 succeeded) — the user is already attached.

Otherwise (the project came from the picker in Step 2), offer the marker. Default to **yes**, but guard against general-purpose dirs.

Determine the current working directory (`$PWD` / `pwd`). If it matches any of:
- `$HOME` exactly
- `/tmp`, `/var/tmp`
- `/` (root)
- a parent of one of the above

then default the prompt to **no** and prepend a warning. Otherwise default to **yes**.

Print one of these:

**Safe cwd (default yes):**

```
Drop a project marker in <cwd>?

This writes a small .codesync/project.json so future terminals launched
from <cwd> (or any subdirectory) auto-resolve to '<ACTIVE_PROJECT>' — no
need to export CODESYNC_PROJECT every time.

  [yes] / no
```

**Guarded cwd (default no, warn):**

```
You're in <cwd> — that's a general-purpose directory. Dropping a project
marker here would make EVERY terminal launched from <cwd> auto-resolve to
'<ACTIVE_PROJECT>', which is usually not what you want.

If you have a dedicated code directory for this project, cd there first
and run /codesync-project-attach <ACTIVE_PROJECT>.

Drop the marker here anyway?

  yes / [no]
```

If user accepts (yes — including just pressing enter on the default-yes case), run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/attach-project.sh" --project "<ACTIVE_PROJECT>" --link-claude-md
```

(Optionally include `--role "<PRIMARY_ROLE>"` — the first entry in `REGISTERED_ROLE_NAMES` — as the marker's `default_role`. Skip the role flag if `REGISTERED_ROLE_NAMES` is empty.)

`--link-claude-md` tells the attach script to also symlink the project's `CLAUDE.md` into the current directory so Claude Code's native CLAUDE.md mechanism auto-loads project context. It's a no-op if cwd already has a CLAUDE.md (user files aren't clobbered) or if the project doesn't have a CLAUDE.md yet.

The script will refuse to overwrite an existing marker without `--force` — if that happens, tell the user the marker is already there and don't proceed.

If the user declines: don't run the script; print one line: *"OK — to attach later, cd into your project's code directory and run /codesync-project-attach <ACTIVE_PROJECT>."*

## Step 8 — Tell the user what's next

Pick the FIRST role in `REGISTERED_ROLE_NAMES` as `PRIMARY_ROLE` for the activation hint.

If `REGISTERED_ROLE_NAMES` is empty, print:

```
No roles were registered (everything was skipped). Re-run /codesync-role-new whenever you're ready.
```

and STOP.

Otherwise print:

```
✓ Registered N role(s) in project '<ACTIVE_PROJECT>':
    - <ROLE_1>   →  <PROJECT_PATH>/_roles/<ROLE_1>.md
    - <ROLE_2>   →  <PROJECT_PATH>/_roles/<ROLE_2>.md
    (etc.)

To activate in THIS terminal, exit Claude Code and run in your shell:

    export CODESYNC_PROJECT=<ACTIVE_PROJECT>
    export CODESYNC_ROLE=<PRIMARY_ROLE>

(Or: cs <ACTIVE_PROJECT> <PRIMARY_ROLE> — see the README for the wrapper.)

Your post-turn inbox check and session-start summary will surface messages
addressed to ANY of your registered roles, regardless of which CODESYNC_ROLE
is active in the terminal.
```

If a marker was dropped in Step 7, append one more line:

```
A project marker was written to <cwd>/.codesync/project.json — future
terminals launched from this directory will auto-resolve to this project.
```

## Constraints

- Never modify files outside the active project's directory and `~/.config/codesync/`.
- Never write a role file without explicit confirmation per role.
- If a conflict was raised in Step 5b and the user didn't resolve it, skip that role — don't write.
- Do not edit any plugin scripts from this command.
- For the marker prompt: NEVER drop a marker without an explicit user yes. The guarded-cwd case must default to "no" even on a bare enter.
