---
description: One-time setup — install Syncthing, create the shared contracts folder, and register this machine's role profile
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/install-syncthing.sh:*)", "Bash(python3:*)"]
---

# Install CodeSync

The user invoked `/install-codesync`.

This command sets up Syncthing, creates the shared `~/contracts/` folder, and registers this machine's role so other Claude agents on paired machines know who lives here. It is interactive — work through each step in order; do not skip ahead.

## Step 1 — Run the install script

The install script is idempotent (safe to re-run). Execute:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/install-syncthing.sh"
```

The script's last two lines are:

```
DEVICE_ID=<this machine's syncthing device id>
CONTRACTS_DIR=<absolute path>
```

Capture both values. If the script exited non-zero, surface its error message to the user clearly and STOP — do not proceed.

## Step 2 — Read any existing role profiles

The install script ensures `<CONTRACTS_DIR>/_roles/` exists. List the `.md` files in that directory, **ignoring `README.md`**. For each remaining file, read its full content — these are the roles already registered by other paired machines (or by previous runs of this command on this machine).

Hold those profiles in mind for the conflict check in step 4. If the directory has no role files yet (first install, or Syncthing hasn't paired anyone yet), there is nothing to compare against — proceed.

## Step 3 — Ask the user about this machine's role

Ask the user EXACTLY this question (multi-line input — they may type several lines):

> Tell me about this role on this machine.
>
> Cover three things in your own words:
> - **What you do** (the work you'll handle)
> - **What you don't do** (so my colleague's Claude doesn't misroute things to me)
> - **Anything else** worth knowing — stack, hours, preferences
>
> A few sentences or bullets — whatever feels natural. Examples:
> - *"Backend — Python on Postgres. I own auth, REST endpoints, background jobs. I don't touch the UI or anything infra. FastAPI stack."*
> - *"I build the React frontend and the React Native mobile app. UI, client state, accessibility. Not backend, not deploys. Available 09:00–18:00 IST."*

Wait for the user's response.

## Step 4 — Parse the response and check for conflicts

From the user's response, extract:

- **`role-name`** — a short kebab-case identifier (e.g., `backend`, `mobile`, `devops`, `data-eng`). If the user explicitly named the role in their answer, use that (normalised to kebab-case). Otherwise infer it from the description. If genuinely ambiguous, ask ONE short clarifying question: *"What should I call this role in shorthand? (e.g., `backend`, `mobile`, `devops`)"*

- **`owns`** — a bullet list of what the role is responsible for, derived from the user's description.

- **`does-not-own`** — a bullet list of what the role explicitly avoids. If the user didn't address this, ASK ONCE: *"You didn't say what this role doesn't do — that's the field that prevents misrouting from your colleague's Claude. What's outside your scope?"* If they decline or say "nothing specific", write `- (not specified)` as the single bullet.

- **`notes`** — anything from the response that didn't fit into `owns` or `does-not-own`: stack, preferences, hours, etc. May be empty.

Now **conflict-check semantically** against the existing role profiles from step 2. Use judgment, not regex — look for:

1. **Name collision** — a `<role-name>.md` already exists. Show its current content to the user and ask whether they're updating that role (overwrite is fine), whether this is a different role under the same name (pick a different name), or whether this run was a mistake (abort).

2. **Semantic duplicate** — a different filename but the `Owns` lists overlap heavily. Show both profiles and ask: *"These look like the same role under different names. Are they? If so, which name should we keep?"*

3. **Responsibility overlap** — the new role's `Owns` includes an item another role also lists in `Owns`. Show the overlap and ask: *"Both `<this-role>` and `<other-role>` claim `<item>`. Which role should actually own it?"* — update the appropriate file with the user's answer.

If any of these surface, resolve with the user before continuing. If no conflicts, proceed.

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

Print the proposed file to the user and ask:

> This is how your role will appear to paired machines. Look right?
>
> - reply **yes** to write it
> - reply **edit** and tell me what to change
> - reply **cancel** to abort without writing anything

If they say *edit*, ask what to change, revise the proposal, and show it again. Loop until yes or cancel.

If they say *cancel*, STOP without writing anything to `_roles/` or to the config.

## Step 6 — Write the role file and update config

Once the user confirms:

1. **Write the role profile** to `<CONTRACTS_DIR>/_roles/<role-name>.md` with the exact markdown from step 5.

2. **Merge the role into `~/.config/codesync/config.json`** (preserves the fields the install script wrote). Use the Bash tool to run the command below. CRITICAL: substitute `<ROLE>` (the kebab-case role name) and `<ROLE_FILE>` (the absolute path to the role markdown file) BEFORE invoking Bash. Never run the literal text with the placeholders unfilled — that will write garbage into the config.

```bash
python3 -c '
import json, os, sys
path = os.path.expanduser("~/.config/codesync/config.json")
with open(path) as f: cfg = json.load(f)
cfg["role"] = sys.argv[1]
cfg["role_file"] = sys.argv[2]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
' "<ROLE>" "<ROLE_FILE>"
```

## Step 7 — Tell the user what to do next

Print exactly this template (substituting the real values):

```
✓ CodeSync installed on this machine.

  Role:           <role-name>
  Device ID:      <DEVICE_ID>
  Contracts dir:  <CONTRACTS_DIR>
  Role profile:   <CONTRACTS_DIR>/_roles/<role-name>.md

Next:
  1. Send the Device ID above to your colleague.
  2. On their Mac they install this plugin and run /install-codesync.
     They'll describe their own role and get their own Device ID back.
  3. Pair the two machines symmetrically — each side runs once:
        /codesync-pair --peer <other-machine's-device-id>
     Pairing is idempotent and order-independent. Sync starts
     automatically when both sides have done it.
  4. Verify with /codesync-status — it shows whether Syncthing is
     up, whether peers are connected, and which role profiles have
     synced into _roles/.

Once paired, Syncthing mirrors ~/contracts/ — including _roles/ —
between both machines, and either Claude can read all role profiles
to route contracts correctly.
```

## Constraints

- Never modify files outside `~/.config/codesync/`, `<CONTRACTS_DIR>`, or Syncthing's own config.
- Never write the role file without showing it to the user and getting explicit confirmation.
- If a conflict was raised in step 4 and the user didn't resolve it, STOP — don't write a conflicting profile.
- Do not edit the install script or any other plugin files from this command.
- If `~/.config/codesync/config.json` doesn't exist after the install script ran (which would indicate a script failure), STOP — re-running the install script is the right next move, not improvising.
