---
description: Reply to a thread in your active role's inbox — addressed back to the original sender, linked via replies-to
argument-hint: "<slug-or-path>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh:*)", "Bash(python3:*)", "Bash(printenv:*)"]
---

# Reply to a CodeSync thread

The user invoked `/codesync-thread-reply $ARGUMENTS`. Create a reply file addressed back to the original thread's sender, with frontmatter linking the two via `replies-to`.

## Step 1 — Confirm project and role are active

```!
printenv CODESYNC_PROJECT
```

```!
printenv CODESYNC_ROLE
```

Both required. If either is empty, STOP and tell the user to set the missing one in their shell.

## Step 2 — Resolve the original thread file

`$ARGUMENTS` should contain a slug or a relative path identifying the thread to reply to. Resolve in this order:

1. If it looks like a relative path (contains `_inbox/`), use it as-is, anchored on the project's path.
2. Otherwise, treat it as a slug and look for `<project-path>/_inbox/<active-role>/<slug>.md`.
3. If neither works, STOP and tell the user: *"Couldn't find a thread by that slug or path. Try /codesync-thread-list to see what's in your inbox."*

(Look up the project's path from `~/.config/codesync/config.json` under `projects.<active>.path`.)

## Step 3 — Read the original's frontmatter

Use the Bash tool to parse the original's frontmatter. Substitute `<ORIGINAL_PATH>` BEFORE invoking Bash:

```bash
python3 -c '
import sys, re, json
text = open(sys.argv[1]).read()
m = re.match(r"---\s*\n(.*?)\n---", text, re.DOTALL)
fm = {}
if m:
    in_cs = False
    for line in m.group(1).splitlines():
        if line.strip() == "codesync:": in_cs = True; continue
        if in_cs and line.startswith("  "):
            kv = line[2:]
            if ":" in kv:
                k, v = kv.split(":", 1)
                fm[k.strip()] = v.strip().strip(chr(34)).strip(chr(39))
        else:
            in_cs = False
print(json.dumps(fm))
' "<ORIGINAL_PATH>"
```

Parse the JSON output. From it:

- `original_from` = `fm.get("from", "")` — the role that wrote the original (we'll address our reply to them)
- `original_title` = `fm.get("title", "")` — the original's title (default reply title prefixes "Re: ")

If `fm` is empty (no frontmatter on the original), the thread is from before structured threads existed. In that case:
- ASK the user: *"The original has no structured-thread frontmatter. Who should this reply be addressed to?"*
- Use the user's answer as `original_from`.

## Step 4 — Compute defaults for the reply

- `reply_to` = `original_from`  (where the reply goes)
- `reply_title` = `"Re: " + original_title` if `original_title` is set, else `"Re: " + <slug-derived-text>`
- `reply_status` = `"note"`  (replies default to discussion; user can override)
- `replies_to` = the relative path of `<ORIGINAL_PATH>` from `<project-path>` (e.g., `_inbox/backend/owner-inbox.md`)

## Step 5 — Ask the user for the body

Tell the user what the reply will look like, then ask for the body:

> Replying to '<original_title>' (from <original_from>) in project '<active-project>'.
>
> Your reply will be addressed to <reply_to>, with status 'note'. Type the body:

Wait for the user's response. If empty, ASK ONCE if a title-only reply is intended.

## Step 6 — Show + confirm

Print:

```
About to write reply:

  From:        <active-role>
  To:          <reply_to>
  Title:       <reply_title>
  Status:      <reply_status>
  Replies to:  <replies_to>

Body:
─────
<user's reply body>
─────

Look right?
  - reply **yes** to write it
  - reply **edit** and tell me what to change
  - reply **cancel** to abort
```

Loop on edit; STOP on cancel.

## Step 7 — Write the reply via write-thread.sh

Pipe the body to the script via stdin. CRITICAL: substitute `<reply_to>`, `<reply_title>`, `<reply_status>`, `<replies_to>` BEFORE invoking Bash, AND replace the heredoc body with the user's actual reply. Keep the heredoc delimiter quoted (`'BODY_EOF'`) so body content passes literally:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/write-thread.sh" \
  --to "<reply_to>" --title "<reply_title>" --status "<reply_status>" \
  --replies-to "<replies_to>" --body-file - <<'BODY_EOF'
<reply body from step 5>
BODY_EOF
```

Capture `THREAD_FILE` from the output. Surface any script error and STOP.

## Step 8 — Tell the user

Print:

```
✓ Reply written to <THREAD_FILE>.
   Linked back to <replies_to>.

It will sync to your collaborator's machine within seconds. Their next
Claude session will see it surface in /codesync-thread-list (and via the
post-turn auto-check, if they're acting as <reply_to>).
```

## Constraints

- Never write the reply file without explicit user confirmation in Step 6.
- Never overwrite an existing file (write-thread.sh will refuse if there's a collision).
- Do not edit any plugin files from this command.
