---
description: One-time setup — install Syncthing on this machine and register a first project + role(s)
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/install-syncthing.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/register-role-in-config.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/register-identity.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/seed-project-docs.sh:*)", "Bash(python3:*)", "Bash(python:*)"]
---

# Install CodeSync

The user invoked `/install-codesync`.

This command:
1. Installs Syncthing on this machine and reads its Device ID + API key.
2. (Step retired in v0.22 — the legacy v0.4.x migration was removed; the layout never shipped publicly.)
3. Picks an existing project or creates a new one.
4. Walks the user through registering one OR MORE roles in that project (hybrid roles supported — pick PM + Designer in one go).

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

## Step 1b — Capture identity (this machine's "who am I")

Identity is a short human-readable name (e.g. `alice`, `bob`, `laxman`) that attaches to every thread you write — `from-identity: <name>` in the frontmatter. It matters when two or more people on the team share the same role (e.g., two backend developers): the identity tells the team WHO authored each thread, and it powers `/codesync-thread-claim` so one backend can grab a thread and the other knows to skip it.

Identity is machine-level (stored in `~/.config/codesync/config.json`), not synced to peers — your collaborators see it as the `from-identity` on your threads, but they don't share storage of it.

### Skip if already set

Read `~/.config/codesync/config.json`. If it has a non-empty top-level `identity` field, capture it as `IDENTITY` and skip to Step 2 — don't re-prompt.

### Suggest from git config

Run:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/register-identity.sh" --suggest
```

Output is `GIT_FOUND=yes|no`, `GIT_NAME=<full name from git>`, `SUGGESTED=<normalized>`.

### Confirm with the user

**Case A — `GIT_FOUND=yes`:** Ask the user:
> Your git config says `<GIT_NAME>` — I'll use `<SUGGESTED>` as your identity for thread attribution. Want to change it? (press enter to accept, or type a new one — lowercase letters/digits with hyphens, e.g. `alice`, `bob-frontend`)

If they press enter, use `SUGGESTED`. Otherwise validate the input matches `^[a-z0-9][a-z0-9-]*$`.

**Case B — `GIT_FOUND=no`:** Ask:
> What name should I attach to your threads? Lowercase letters/digits with hyphens — e.g. `alice`, `bob`, `laxman`. This is just for "who sent this" labels when two teammates share a role.

Validate the input. Re-ask if invalid.

### Save it

Once the user has confirmed a value, substitute `<IDENTITY>` and run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/register-identity.sh" --set "<IDENTITY>"
```

The script prints `SAVED_IDENTITY=<value>` on success.

## Step 2 — (retired)

The legacy v0.4.x→v0.5 migration was removed in v0.22 (the pre-release layout never shipped publicly; no installation can have it). Continue directly to Step 3. *(Step numbering kept stable so later cross-references stay valid.)*

## Step 3 — Project picker

Read the `projects` map from `~/.config/codesync/config.json`.

**Case A — No projects yet (fresh install):**

Ask: *"This is your first project. What should it be called? Pick a name both you and your collaborators will agree on (it must match exactly across machines). Lowercase letters, digits, dashes, and underscores only — e.g. `lead_inbox`, `mobile-app`, `client-acme`."*

Validate the name (regex `^[a-z0-9][a-z0-9_-]*$`). Re-ask if invalid.

Run create-project. Substitute `<NAME>` before invoking Bash:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --name "<NAME>"
```

The script prints `PROJECT_NAME`, `PROJECT_PATH`, `FOLDER_ID`. Capture them.

Set `ACTIVE_PROJECT = <name>`, `PROJECT_PATH = <path>`.

**Case B — Projects already exist (re-run or additional setup):**

Print a numbered picker. For example, with two existing projects:

```
Which project is this install for?

  1. lead_inbox       (existing — /Users/you/codesync/lead_inbox)
  2. mobile-app       (existing — /Users/you/codesync/mobile-app)
  3. New project (enter name)

Pick one (1-3):
```

Wait for the user's number. Validate it's in range.

- If they pick an existing project: set `ACTIVE_PROJECT` and `PROJECT_PATH` from config.
- If they pick "New project": ask for the name (validate as in Case A), then run `create-project.sh --name "<NAME>"`. Capture outputs.

After `ACTIVE_PROJECT` / `PROJECT_PATH` are set (regardless of which sub-case), run the docs seeder (idempotent — only writes files that don't exist):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/seed-project-docs.sh" --project "<ACTIVE_PROJECT>" --path "<PROJECT_PATH>"
```

The script prints `CREATED=<comma-separated>` of any files it added (`_docs/`, `_docs/README.md`, `CLAUDE.md`). If `CREATED` is non-empty, tell the user briefly: *"Scaffolded project docs: \<list>. The new `CLAUDE.md` is loaded automatically by Claude Code whenever you work in or near this directory — edit it to add project-specific instructions."* If `CREATED` is empty, stay quiet.

### Step 3b — Offer to refresh an out-of-date default CLAUDE.md

If the seeder reported `CREATED=` (empty — i.e. CLAUDE.md already existed and wasn't created fresh), check whether to offer a refresh to the latest template.

Read `<PROJECT_PATH>/CLAUDE.md`. Two cases:

**Case A — Current template (v4 marker present).** If the file contains the exact comment `<!-- codesync-template-v4 -->`, it's already on the current template. Do nothing. Stay quiet.

**Case B — No v4 marker.** The file is either an older default (v3 or earlier) OR a user-customized version. **We cannot reliably tell which from text alone** — a user who replaces the placeholder "Notes for the team" content with real team notes looks structurally identical to an unmodified default. So we must default to safe and let the user decide.

Ask the user, with a clear OVERWRITE warning, defaulting to **no**:

> Your project's `CLAUDE.md` doesn't have the current (v4) template marker. v0.20 ships an updated template reflecting the simplified command surface — `/codesync-thread-release` and `/codesync-thread-unarchive` are now flags on their counterparts (`--release`, `--unarchive`), and the obsolete `/codesync-project-list` / `/codesync-role-list` / `/codesync-project-invite` slash commands are gone (their functions absorbed into `/codesync-status` and `/codesync-pair`).
>
> **Refreshing will OVERWRITE the entire file with the new template — any custom edits will be lost.** If you've added project-specific notes in the "Notes for the team" section, those will be gone. (You can recover from Syncthing's `.stversions/` if needed.)
>
> Refresh now? (yes / **no** — default no)

Default to **no** on a bare enter. Only run the refresh if the user explicitly types **yes**.

On **yes**, run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/seed-project-docs.sh" --project "<ACTIVE_PROJECT>" --path "<PROJECT_PATH>" --refresh-claude-md
```

Tell the user the file has been refreshed and that the new behaviors will activate automatically in the next Claude session that loads this project's CLAUDE.md.

On **no** (or default), leave alone. Mention to the user that they can manually copy the "Default behaviors for Claude" section from a newly-created project's CLAUDE.md if they want the proactive instructions without losing their customizations.

## Step 4 — Read existing role profiles in the active project

List the `.md` files in `<PROJECT_PATH>/_roles/`, **ignoring `README.md`**. For each remaining file, read its full content — these are the roles already registered on this machine or synced from paired peers.

Hold those profiles for the conflict check in Step 7. If there are no role files yet, there's nothing to compare against — proceed.

## Step 5 — Role picker (multi-select)

Read the role catalog from `${CLAUDE_PLUGIN_ROOT}/scripts/lib/roles.json`. It has the shape:

```json
{"categories": [{"name": "Engineering", "roles": [{"name": "backend", "display": "Backend", "owns": [...], "does_not_own": [...]}, ...]}, ...]}
```

Render it as one big numbered picker, grouped visually by category. Add a "Custom (free-form)" option at the end. Example output:

```
Pick one or more roles for this machine in "<ACTIVE_PROJECT>"
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

Wait for the user's input. Parse comma-separated numbers (e.g. `5,7` or `1`). Validate each is in range. Re-ask on invalid input.

Build a list `PICKED_ROLES` — each entry is either:
- a predefined role object from the catalog (with `name`, `display`, `owns`, `does_not_own`), OR
- the literal string `"custom"` if option 13 was picked.

If multiple roles were picked, tell the user briefly: *"Got it — you'll wear N hats in this project: \<list of displays\>. I'll walk through them one at a time."*

## Step 6 — For each picked role, propose a profile and confirm

Initialize `REGISTERED_ROLE_NAMES = []` (you'll need this for Step 8).

For each entry in `PICKED_ROLES`, in order:

### If the entry is a predefined role (has `name`, `owns`, `does_not_own`)

1. Build the proposed markdown profile from the template:

```
# <name>

## Owns
- <each item from owns>

## Does not own
- <each item from does_not_own>
```

(No `Notes` section by default — leave it out unless the user adds one during the edit step.)

2. Run the conflict check (Step 7) for this role's `name`. Resolve before continuing.

3. Show the proposed profile and ask:

> Here's the proposed profile for **<display>** (`<name>`):
>
> \<markdown above\>
>
> Look right?
> - reply **yes** to write it as-is
> - reply **edit** and tell me what to change (e.g., "add 'caching' to owns", "I do touch infra so remove that from does-not-own", "add notes: 'Python stack'")
> - reply **skip** to drop this role and continue to the next

If *edit*: ask what to change, revise the proposed profile (preserving the structure), show again. Loop until yes or skip.

If *skip*: don't write the file, don't add to `REGISTERED_ROLE_NAMES`, move on to next picked role.

If *yes*: write the markdown to `<PROJECT_PATH>/_roles/<name>.md`. Append `name` to `REGISTERED_ROLE_NAMES`.

### If the entry is `"custom"` (free-form)

Drop into the free-form prose flow (same as the legacy install behavior):

1. Ask:

> Tell me about this custom role.
>
> Cover three things in your own words:
> - **What it does** (the work it handles)
> - **What it doesn't do** (so others don't misroute things to it)
> - **Anything else** worth knowing — stack, hours, preferences

2. Parse the response into `role-name` (kebab-case, ask for clarification if ambiguous), `owns`, `does-not-own` (ask once if not provided), `notes`.

3. Run the conflict check (Step 7) for the inferred `role-name`.

4. Format as markdown:

```
# <role-name>

## Owns
- <bullet>

## Does not own
- <bullet>

## Notes
<free-form notes if any, otherwise omit the Notes section entirely>
```

5. Show and confirm with the same yes/edit/skip prompt as above.

6. If *yes*: write to `<PROJECT_PATH>/_roles/<role-name>.md`. Append `role-name` to `REGISTERED_ROLE_NAMES`.

## Step 7 — Conflict check (run inline within Step 6 per role)

Compare the role-name being written against the existing role profiles read in Step 4:

1. **Name collision** — `<role-name>.md` already exists. Show its current content and ask whether the user is updating that role (overwrite is fine — proceed), whether this should be a different name (re-name and re-check), or whether to skip this one.

2. **Semantic duplicate** — a different filename's `Owns` overlaps heavily with this role's `Owns`. Show both profiles and ask: *"These look like the same role under different names. Are they?"* If yes, ask which name to keep.

3. **Responsibility overlap** — this role's `Owns` includes an item another existing role also claims. Show the overlap and ask which role should actually own it.

If any are raised and the user doesn't resolve them, skip writing this role's file. Continue with the next picked role.

## Step 8 — Register the roles in config

After Step 6 has processed all picked roles, register the successfully-written role names in `~/.config/codesync/config.json` so the Stop hook and SessionStart hook know which roles this device has registered for this project.

Skip this step if `REGISTERED_ROLE_NAMES` is empty (everything was skipped or cancelled).

Build a Bash command that passes one `--role <name>` per registered role. Substitute `<ACTIVE_PROJECT>` and each `<ROLE>` before invoking:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/register-role-in-config.sh" --project "<ACTIVE_PROJECT>" --role "<ROLE_1>" --role "<ROLE_2>"
```

The script prints `REGISTERED_ROLES=<comma-separated list>` on success. If it errors, surface the error and STOP.

## Step 8b — Offer to install the status-line indicator

Ask the user, defaulting to **yes**:

> Want a small `codesync ▴ N new` indicator in Claude Code's bottom bar so you can see at a glance when new threads arrive? Silent when zero, fires a macOS notification when something new comes in. Non-destructive (composes with any existing status line you have). [yes] / no

On **yes** (or bare enter), run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh"
```

Tell the user *"Installed. The indicator will appear in your bottom bar within a few seconds; macOS will ask for notification permission the first time something arrives."*

On **no**, skip. Mention they can run `/codesync-statusline-setup` later if they change their mind.

## Step 8c — Offer to add the `cs` shell wrapper to `~/.zshrc`

The `cs` wrapper lets the user switch project+role with `cs <project> <role>` instead of two `export` commands. Convenience.

First, detect the user's shell rc file:
- If `~/.zshrc` exists → use that
- Else if `~/.bashrc` exists → use that
- Else → skip this step (user is on an unusual shell setup; let them add it manually)

Read the rc file's content. If it already contains a `cs()` function definition (grep for `^cs\(\)` or `^function cs\(\)`), skip — don't ask, don't add.

Otherwise, ask the user, defaulting to **yes**:

> Want me to add a small `cs` shell function to `<rc-file-path>`? It lets you switch project+role with one command: `cs <project> <role>` (instead of `export CODESYNC_PROJECT=…; export CODESYNC_ROLE=…`). Non-destructive — just appends to your rc file. [yes] / no

On **yes**, append this exact block (with a leading blank line) to the rc file:

```bash

# Added by codesync /install-codesync — switch project+role in one shorthand
cs() {
  case $# in
    2) export CODESYNC_PROJECT="$1"; export CODESYNC_ROLE="$2"; echo "CodeSync: project=$CODESYNC_PROJECT role=$CODESYNC_ROLE" ;;
    1) export CODESYNC_ROLE="$1"; echo "CodeSync: project=${CODESYNC_PROJECT:-(unset)} role=$CODESYNC_ROLE" ;;
    0) echo "Usage: cs <project> <role>   or   cs <role>"; echo "Current: project=${CODESYNC_PROJECT:-(unset)} role=${CODESYNC_ROLE:-(unset)}" ;;
    *) echo "Usage: cs <project> <role>   or   cs <role>"; return 1 ;;
  esac
}
```

Tell the user: *"Added. To use it in this terminal right now, run `source <rc-file-path>` (or open a new terminal)."*

On **no**, skip. Note they can copy the function from the README anytime.

## Step 9 — Tell the user what's next

Pick the FIRST role in `REGISTERED_ROLE_NAMES` as the suggested default for the activation hint (call it `PRIMARY_ROLE`). If multiple roles were registered, note that they can switch per-terminal.

Print this template (substituting real values):

```
✓ CodeSync installed on this machine.

  Device ID:       <DEVICE_ID>
  Identity:        <IDENTITY>   (attached to every thread you write as `from-identity`)
  Active project:  <ACTIVE_PROJECT>
  Project path:    <PROJECT_PATH>
  Roles registered on this machine in this project:
    - <ROLE_1>   →  <PROJECT_PATH>/_roles/<ROLE_1>.md
    - <ROLE_2>   →  <PROJECT_PATH>/_roles/<ROLE_2>.md
    (etc.)

To activate in this terminal, exit Claude Code and run in your shell:

    export CODESYNC_PROJECT=<ACTIVE_PROJECT>
    export CODESYNC_ROLE=<PRIMARY_ROLE>

(Or use the `cs` wrapper from the README: `cs <ACTIVE_PROJECT> <PRIMARY_ROLE>`.)

CODESYNC_ROLE picks which hat you're "wearing" in this terminal — it sets
the `from` field on outgoing messages. Switch hats by changing CODESYNC_ROLE.
But your post-turn inbox check and session-start summary automatically cover
ALL roles you registered above, so you'll see messages addressed to any of
them without needing to switch terminals.

Next steps:
  1. Send the Device ID above to your collaborator.
  2. On their Mac they install this plugin and run /install-codesync.
     They'll pick their own role(s) and get their own Device ID back.
     IMPORTANT: the project name must match exactly on their side
     (yours: '<ACTIVE_PROJECT>') for sync to align.
  3. Pair the machines — each side runs once, with CODESYNC_PROJECT set:
        /codesync-pair --peer <other-machine's-device-id>
     Sync starts automatically once both sides have done it.
  4. Verify with /codesync-status.

To add more roles in this project later: /codesync-role-new
To register a separate project: /codesync-project-new
```

If `REGISTERED_ROLE_NAMES` is empty (everything was skipped), print a simpler message:

```
✓ Project '<ACTIVE_PROJECT>' is set up but no role profiles were registered on this machine.

Run /codesync-role-new whenever you're ready to register a role.
```

## Constraints

- Never modify files outside `~/.config/codesync/`, `~/codesync/<project>/`, or Syncthing's own config.
- Never write a role file without showing it to the user and getting explicit confirmation per role.
- If a conflict is raised in Step 7 and the user doesn't resolve it, skip that role — don't write a conflicting profile.
- Do not edit the install / migration / create-project / register-role scripts or any other plugin files from this command.
- If `~/.config/codesync/config.json` doesn't exist after Step 1 (would indicate a script failure), STOP — re-running the install script is the right next move, not improvising.
