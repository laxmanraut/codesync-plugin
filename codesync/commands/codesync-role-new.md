---
description: Register a new role profile (or update an existing one) for the active project
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(python3:*)"]
---

# Register a CodeSync role

The user invoked `/codesync-role-new`. This command adds (or updates) a role profile in the active project's `_roles/` directory. Roles are *definitions* shared with all peers invited to the same project via Syncthing. **Activation** of a role for a given terminal is separate — done by setting `CODESYNC_ROLE` in the shell. This command only creates the definition.

## Step 1 — Resolve the active project

Run the resolver (checks env var first, then walks up looking for `.codesync/project.json`):

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Output is two `KEY=VALUE` lines. Extract the value after `CODESYNC_PROJECT=` (strip surrounding single quotes).

If empty, STOP and tell the user: *"No project active in this terminal. Either set CODESYNC_PROJECT in your shell, or attach this directory with /codesync-project-attach <project>."*

Then read `~/.config/codesync/config.json` and look up `projects.<active>.path` — that's the directory the role will be written under. If the project isn't in the config, STOP and tell the user to run `/codesync-project-new` first.

## Step 2 — Read any existing role profiles

List the `.md` files in `<project-path>/_roles/`, **ignoring `README.md`**. For each remaining file, read its full content — these are the roles already registered on this machine or synced from paired peers.

Hold those profiles in mind for the conflict check in step 4. If the directory has no role files yet, there is nothing to compare against — proceed.

## Step 3 — Ask the user about the role

Ask the user EXACTLY this question (multi-line input — they may type several lines):

> Tell me about the role you want to register.
>
> Cover three things in your own words:
> - **What this role does** (the work it handles)
> - **What it doesn't do** (so other Claude agents don't misroute things to it)
> - **Anything else** worth knowing — stack, hours, preferences
>
> A few sentences or bullets — whatever feels natural. Examples:
> - *"Backend — Python on Postgres. Owns auth, REST endpoints, background jobs. Not the UI, not infra. FastAPI stack."*
> - *"Mobile — React Native iOS/Android. UI, client state, push notifications. Not backend, not the web frontend."*

Wait for the user's response.

## Step 4 — Parse the response and check for conflicts

From the user's response, extract:

- **`role-name`** — a short kebab-case identifier (e.g., `backend`, `mobile`, `devops`, `data-eng`). If the user explicitly named the role, use that (normalised to kebab-case). Otherwise infer from the description. If genuinely ambiguous, ask ONE short clarifying question: *"What should I call this role in shorthand?"*

- **`owns`** — bullet list of what the role is responsible for.

- **`does-not-own`** — bullet list of what the role explicitly avoids. If the user didn't address this, ASK ONCE: *"You didn't say what this role doesn't do — that's the field that prevents misrouting. What's outside its scope?"* If they decline, write `- (not specified)` as the single bullet.

- **`notes`** — anything from the response that didn't fit into the above. May be empty.

Now **conflict-check semantically** against the existing role profiles from step 2:

1. **Name collision** — a `<role-name>.md` already exists. Show its current content and ask whether the user is updating that role (overwrite is fine), whether this should be a different name, or whether to abort.

2. **Semantic duplicate** — a different filename but `Owns` lists overlap heavily. Show both profiles and ask: *"These look like the same role under different names. Are they? If so, which name should we keep?"*

3. **Responsibility overlap** — the new role's `Owns` includes an item another role also lists in `Owns`. Show the overlap and ask: *"Both `<this-role>` and `<other-role>` claim `<item>`. Which role should actually own it?"* — update the appropriate file with the user's answer.

If any of these surface, resolve with the user before continuing.

## Step 5 — Show the proposed role profile

Format the parsed content as Markdown using this exact structure (omit the `Notes` section entirely if `notes` is empty):

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

Print the proposed file and ask:

> This is how the role will appear to paired machines. Look right?
>
> - reply **yes** to write it
> - reply **edit** and tell me what to change
> - reply **cancel** to abort without writing anything

If they say *edit*, ask what to change, revise, show again. Loop until yes or cancel.

If they say *cancel*, STOP without writing anything.

## Step 6 — Write the role file

Once confirmed, write the role profile to `<project-path>/_roles/<role-name>.md` with the exact markdown from step 5.

## Step 7 — Tell the user what's next

Print exactly this template (substituting the real values):

```
✓ Role '<role-name>' registered in project '<project-name>'.

  Role profile:  <project-path>/_roles/<role-name>.md

To activate this role in a terminal, exit Claude Code and run in your shell:

    export CODESYNC_ROLE=<role-name>

(If CODESYNC_PROJECT isn't already set, also: export CODESYNC_PROJECT=<project-name>)

Then re-open Claude Code. /codesync-status will confirm both project and role are active.

Each terminal can act as a different project+role combo. See the README for
the `cs` wrapper function that activates both in one go.
```

## Constraints

- Never modify files outside the active project's directory (specifically `<project-path>/_roles/`).
- Never write the role file without showing it and getting explicit confirmation.
- If a conflict was raised and the user didn't resolve it, STOP.
- Do not edit any plugin files from this command.
- Do not touch `~/.config/codesync/config.json` — roles aren't stored there.
