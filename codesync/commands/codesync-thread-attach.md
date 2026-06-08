---
description: Attach one or more files (images, PDFs, HTML mockups, anything) to an existing thread so collaborators receive them alongside the thread
argument-hint: "<slug> <file-path> [<file-path>...]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/attach-thread.sh:*)"]
---

# Attach files to a CodeSync thread

The user invoked `/codesync-thread-attach $ARGUMENTS`. This copies one or more files into the thread's per-thread attachments directory (`<inbox>/<role>/<slug>.attachments/`) and updates the thread's frontmatter so collaborators see `[+ N attachments]` next to the thread.

## When to use this

A designer who wants to send mockup screens to the frontend role: write the thread first with `/codesync-thread-new` describing what the mockups are about, then attach the files with this command. Same pattern for product spec PDFs, architecture diagrams, sample HTML, screenshots — anything that isn't markdown text.

## Step 1 — Parse args

`$ARGUMENTS` should start with `<slug>` followed by one or more file paths. Example:

```
/codesync-thread-attach login-mockup-v1 ~/Desktop/login.png ~/Desktop/profile.png
```

If `$ARGUMENTS` is empty or contains only the slug, STOP and ask: *"Which file(s) do you want to attach? Pass one or more paths after the slug — e.g. /codesync-thread-attach login-mockup-v1 ./mockup1.png ./mockup2.png."*

Each path may be absolute or relative to the current working directory. Tilde (`~`) is expanded by the shell.

## Step 2 — Run the attach script

The script accepts `--slug <slug>` plus one or more `--file <path>` flags. Build the command by substituting the slug and looping over the paths:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/attach-thread.sh" --slug "<SLUG>" --file "<PATH_1>" --file "<PATH_2>"
```

The script:
- Searches every `_inbox/<role>/` and `_archive/<role>/` for `<slug>.md`. Errors if not found.
- Validates each file exists, is readable, and has no comma in its basename (the frontmatter field is comma-separated).
- Creates the attachments directory if needed.
- Copies each file in. Overwrites a same-name attachment if one exists — Syncthing keeps the prior version under `.stversions/` so this is the safe way to ship "v2 of the same mockup."
- Updates the `attachments:` frontmatter field (deduped, comma-separated).

The script prints `THREAD_FILE=<path>` and `ATTACH_DIR=<dir>` on success. Each attached filename is logged.

If the script exited non-zero, surface its error and STOP.

## Step 3 — Tell the user

Print:

```
✓ Attached <N> file(s) to thread '<SLUG>':
  - <filename 1>
  - <filename 2>
  (etc.)

Stored in <ATTACH_DIR>/. They'll sync to every collaborator paired into
this project within seconds. Your colleague's Claude can read images and
PDFs directly — they can ask "open <filename> and tell me what's on it".
```

## Constraints

- Never modify files outside the thread's attachment directory and the thread's frontmatter block.
- The script handles the file copy and frontmatter update atomically — don't write the frontmatter or copy files from this command directly.
- Attachment filenames containing commas are rejected — surface the script's error and suggest renaming.
- Large files sync fine (Syncthing has no hard limit) but warn the user if a single attachment is over ~50 MB — that's noticeably slower for collaborators on slower internet.
