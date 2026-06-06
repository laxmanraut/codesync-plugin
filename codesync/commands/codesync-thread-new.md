---
description: Start a new thread (note, task, question, or decision) addressed to another role in the active project
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh:*)", "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh:*)", "Bash(python3:*)"]
---

# Start a new CodeSync thread

The user invoked `/codesync-thread-new`. This creates a markdown file in the active project's `_inbox/<to-role>/` with structured frontmatter, so the post-turn auto-check and `/codesync-thread-list` can route and surface it intelligently.

If no project is active in this terminal, the command starts with a project picker. If no role is active, it picks one of the device's registered roles for the chosen project.

## Step 1 — Resolve the active project (and offer a picker if needed)

Run the resolver:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Output is two `KEY=VALUE` lines. Extract `CODESYNC_PROJECT=` value (strip quotes).

If `CODESYNC_PROJECT` is non-empty AND that project exists in `~/.config/codesync/config.json`, set `PROJECT = <name>` and skip to Step 2.

Otherwise — project picker fallback:

Read the `projects` map from `~/.config/codesync/config.json`.

**Case A — no projects registered yet:** ask for a new project name (validate `^[a-z0-9][a-z0-9_-]*$`), then run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/create-project.sh" --name "<NAME>"
```

Set `PROJECT = <NAME>`.

**Case B — projects exist:** print numbered picker:

```
No project is active. Which project is this thread for?

  1. lead_inbox
  2. mobile-app
  3. New project (enter name)

Pick one (1-3):
```

Parse pick. If "New project," ask for name and create as in Case A. Otherwise set `PROJECT` to the chosen existing name.

Read `projects.<PROJECT>.path` from config and store as `PROJECT_PATH`.

## Step 2 — Resolve the active role (and offer a picker if needed)

Extract `CODESYNC_ROLE=` from the resolver output (also captured in Step 1).

If `CODESYNC_ROLE` is non-empty, set `FROM_ROLE = <value>` and skip to Step 3.

Otherwise — role picker fallback:

Read `projects.<PROJECT>.roles` from `~/.config/codesync/config.json` (it's an array; may be missing on configs from earlier versions).

**If the array is empty or missing:** STOP and tell the user: *"No roles are registered on this device for project '<PROJECT>'. Run /codesync-role-new first, then come back."*

**If the array has exactly one role:** set `FROM_ROLE = <that role>` and continue (no need to ask).

**If multiple roles registered:** print picker:

```
You're acting as which role for this thread? (one of your registered roles in '<PROJECT>')

  1. backend
  2. project-manager
  3. (etc.)

Pick one (1-N):
```

Parse pick. Set `FROM_ROLE` to the chosen name.

## Step 3 — Read the project's role profiles so you know who can receive

List the `.md` files in `<PROJECT_PATH>/_roles/` (ignoring `README.md`). The role names available as `--to` are the filenames without `.md`. You'll need them for Step 4 and Step 5.

## Step 4 — Ask the user what they want to create

Ask the user **one open question**:

> What do you want to send?
>
> Tell me in your own words. Cover whatever's natural:
> - **Who it's for** (one of: <list-of-roles>)
> - **What it is** — a task you need them to do, a note for their context, a question, a design discussion, a decision you're making, anything
> - **The body** — what you want to say to them
>
> A few sentences, bullet points, or a full document — any of those work. Examples:
> - *"For frontend: auth v2 is ready to wire up. Endpoint /api/auth/v2, request {email, password}, returns {token, refresh_token}. No breaking changes from v1."*
> - *"Task for backend: refactor the lead inbox endpoint to return paginated results. We're seeing >50 items per call. Pagination param `?page=N` would be great."*
> - *"Question for devops: are we OK with the new auth flow burning ~30k extra Redis ops/min during peak hours?"*

Wait for the user's response.

## Step 5 — Parse the user's response

From the user's response, extract:

- **`to-role`** — must match one of the roles from Step 3. If the user named a role that doesn't exist, STOP and ask which existing role they meant (or whether they want to register a new role via `/codesync-role-new`).
- **`title`** — a short headline (5–10 words). Infer from the user's words. If genuinely unclear, ask: *"What's a short title for this thread?"*
- **`status`** — infer from the framing:
  - User says "task to do", "please do X", "need to refactor" → `todo`
  - User describes work in progress → `wip`
  - User reports completion or announces something ready → `done`
  - User is blocked on something → `blocked`
  - User shares info, asks a question, makes a decision, or has prose-heavy discussion → `note`
- **`body`** — the substantive content the user typed. Strip the framing prefix (e.g., drop "For frontend:" since that's metadata now).

## Step 6 — Show the proposed thread to the user

Print:

```
About to create thread in project '<PROJECT>':

  From:    <FROM_ROLE>
  To:      <to-role>
  Status:  <status>
  Title:   <title>

Body:
─────
<body>
─────

Look right?
  - reply **yes** to write it
  - reply **edit** and tell me what to change (title, status, to-role, body)
  - reply **cancel** to abort
```

If *edit*, ask what to change, revise, show again. Loop until yes or cancel.

If *cancel*, STOP without writing anything.

## Step 7 — Write the thread

The write-thread.sh script reads `CODESYNC_PROJECT` and `CODESYNC_ROLE` (for the `from` field) from the environment. Since we may have resolved both via the pickers (not the actual env), pass them explicitly via inline env vars on the bash command. Substitute `<PROJECT>`, `<FROM_ROLE>`, `<to-role>`, `<title>`, `<status>` BEFORE invoking, and replace the heredoc body with the user's actual content. Keep the heredoc delimiter quoted (`'BODY_EOF'`) so the body is passed literally:

```bash
CODESYNC_PROJECT="<PROJECT>" CODESYNC_ROLE="<FROM_ROLE>" "${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh" \
  --to "<to-role>" --title "<title>" --status "<status>" --body-file - <<'BODY_EOF'
<body content from step 5>
BODY_EOF
```

The script will print `THREAD_FILE=<path>` and `SLUG=<slug>`. Capture them. If the script exited non-zero, surface its error and STOP.

## Step 8 — Tell the user

Print:

```
✓ Thread written to <THREAD_FILE>.

It will sync to your collaborator's machine within a few seconds. When their
Claude session next finishes a turn (with CODESYNC_PROJECT=<PROJECT> set and
they've registered '<to-role>' as one of their roles), the post-turn auto-check
will surface it.

To reply later, run /codesync-thread-reply <SLUG>.
To list all threads in your inbox, run /codesync-thread-list.
```

## Constraints

- Never write the thread file without explicit user confirmation in Step 6.
- Never write to a role's inbox other than the one the user picked.
- Do not edit any plugin files or other config from this command.
- If the body the user provided is empty, ASK ONCE: *"You didn't say what to write — is the title alone enough, or do you want to add a body?"*
- The project picker in Step 1 may create a new project; never modify projects without the explicit "New project" pick.
