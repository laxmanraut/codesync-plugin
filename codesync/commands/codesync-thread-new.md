---
description: Start a new thread (note, task, question, or decision) addressed to another role in the active project
argument-hint: "(no arguments — interactive)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh:*)", "Bash(python3:*)"]
---

# Start a new CodeSync thread

The user invoked `/codesync-thread-new`. This creates a markdown file in the active project's `_inbox/<to-role>/` with structured frontmatter, so the post-turn auto-check and `/codesync-thread-list` can route and surface it intelligently.

## Step 1 — Confirm a project and a role are active

Run the resolver (checks env vars first, then walks up looking for `.codesync/project.json`):

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Output is two `KEY=VALUE` lines:

```
CODESYNC_PROJECT='<name or empty>'
CODESYNC_ROLE='<name or empty>'
```

Extract both values (strip the single quotes).

If `CODESYNC_PROJECT` is empty, STOP: *"No project active in this terminal. Set CODESYNC_PROJECT in your shell or attach this directory with /codesync-project-attach <project>."*

If `CODESYNC_ROLE` is empty, STOP: *"No role active in this terminal. Set CODESYNC_ROLE in your shell — threads need to know who they're from."*

The resolved values become `PROJECT` and `FROM_ROLE`.

## Step 2 — Read the project's role profiles so you know who can receive

List the `.md` files in `<project-path>/_roles/` (ignoring `README.md`). The role names available as `--to` are the filenames without `.md`. You'll need them for Step 3 and Step 4.

(Find the project's path by reading `~/.config/codesync/config.json` and looking up `projects.<PROJECT>.path`.)

## Step 3 — Ask the user what they want to create

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

## Step 4 — Parse the user's response

From the user's response, extract:

- **`to-role`** — must match one of the roles from Step 2. If the user named a role that doesn't exist, STOP and ask which existing role they meant (or whether they want to register a new role via `/codesync-role-new`).
- **`title`** — a short headline (5–10 words). Infer from the user's words. If genuinely unclear, ask: *"What's a short title for this thread?"*
- **`status`** — infer from the framing:
  - User says "task to do", "please do X", "need to refactor" → `todo`
  - User describes work in progress → `wip`
  - User reports completion or announces something ready → `done`
  - User is blocked on something → `blocked`
  - User shares info, asks a question, makes a decision, or has prose-heavy discussion → `note`
- **`body`** — the substantive content the user typed. Strip the framing prefix (e.g., drop "For frontend:" since that's metadata now).

## Step 5 — Show the proposed thread to the user

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

## Step 6 — Write the thread

Pipe the body to the script via stdin. CRITICAL: substitute `<to-role>`, `<title>`, `<status>` BEFORE invoking Bash, AND replace the heredoc body with the user's actual content. Keep the heredoc delimiter quoted (`'BODY_EOF'`) so the body content is passed literally (no shell expansion of `$` or backticks):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh" \
  --to "<to-role>" --title "<title>" --status "<status>" --body-file - <<'BODY_EOF'
<body content from step 4>
BODY_EOF
```

The script will print `THREAD_FILE=<path>` and `SLUG=<slug>`. Capture them. If the script exited non-zero, surface its error and STOP.

## Step 7 — Tell the user

Print:

```
✓ Thread written to <THREAD_FILE>.

It will sync to your collaborator's machine within a few seconds. When their
Claude session next finishes a turn (with CODESYNC_PROJECT=<PROJECT> and
CODESYNC_ROLE=<to-role> set), the post-turn auto-check will surface it.

To reply later, run /codesync-thread-reply <SLUG>.
To list all threads in your inbox, run /codesync-thread-list.
```

## Constraints

- Never write the thread file without explicit user confirmation in Step 5.
- Never write to a role's inbox other than the one the user picked.
- Do not edit any plugin files or other config from this command.
- If the body the user provided is empty, ASK ONCE: *"You didn't say what to write — is the title alone enough, or do you want to add a body?"*
