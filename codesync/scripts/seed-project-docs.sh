#!/usr/bin/env bash
# seed-project-docs.sh — Idempotently scaffold project-wide docs.
# Creates _docs/ directory, _docs/README.md, and a starter CLAUDE.md
# at the project root if they don't already exist.
#
# Args:
#   --project <name>          (required)  used for the CLAUDE.md heading
#   --path <path>             (required)  absolute path to the project directory
#   --refresh-claude-md       (optional)  overwrite an existing CLAUDE.md with
#                                          the current template. WITHOUT this
#                                          flag, an existing CLAUDE.md is
#                                          preserved untouched. The flag is
#                                          intended for the /install-codesync
#                                          flow when the user has confirmed
#                                          the existing file is the default
#                                          template and wants the latest
#                                          version (with newer proactive-
#                                          behavior instructions).
#
# Used by create-project.sh (new projects) AND by install-codesync's
# backfill step.

set -euo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT_NAME=""
PROJECT_PATH=""
REFRESH_CLAUDE_MD="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)             [ $# -ge 2 ] || err "--project requires a value"; PROJECT_NAME="$2"; shift 2 ;;
    --path)                [ $# -ge 2 ] || err "--path requires a value";    PROJECT_PATH="$2"; shift 2 ;;
    --refresh-claude-md)   REFRESH_CLAUDE_MD="yes"; shift ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT_NAME" ] || err "Usage: seed-project-docs.sh --project <name> --path <path> [--refresh-claude-md]"
[ -n "$PROJECT_PATH" ] || err "Usage: seed-project-docs.sh --project <name> --path <path> [--refresh-claude-md]"
[ -d "$PROJECT_PATH" ] || err "Project directory does not exist: $PROJECT_PATH"

CREATED=()

# 1. _docs/ directory
if [ ! -d "$PROJECT_PATH/_docs" ]; then
  mkdir -p "$PROJECT_PATH/_docs"
  CREATED+=("_docs/")
fi

# 2. _docs/README.md
DOCS_README="$PROJECT_PATH/_docs/README.md"
if [ ! -f "$DOCS_README" ]; then
  cat > "$DOCS_README" <<'README'
# Project docs

Free-form markdown files in this directory are project-wide reference docs — architecture notes, conventions, glossary, decisions log, anything that every collaborator should be able to read.

Anything in here syncs to every paired peer via Syncthing within seconds. Edit by hand or via Claude; no slash command is needed to create files (use `/codesync-doc-list` to see what's here).

There's no required structure. A few conventions that work well:
- One topic per file (e.g. `ARCHITECTURE.md`, `CONVENTIONS.md`, `GLOSSARY.md`, `DECISIONS.md`).
- Lead each file with a single `# Heading` — it's what the SessionStart summary surfaces.
- Treat docs as a living reference: if a decision changes, update the file.

Edit conflicts: Syncthing is last-write-wins. If two collaborators edit the same file at the same time, both versions are preserved under `.stversions/` for recovery.
README
  CREATED+=("_docs/README.md")
fi

# 3. CLAUDE.md (Claude Code's native context file — auto-loaded when working
#    in or near this directory, no plugin needed for the loading itself).
#    Write if missing; refresh if --refresh-claude-md is passed.
CLAUDE_MD="$PROJECT_PATH/CLAUDE.md"
WRITE_CLAUDE_MD="no"
if [ ! -f "$CLAUDE_MD" ]; then
  WRITE_CLAUDE_MD="yes"
  CREATED+=("CLAUDE.md")
elif [ "$REFRESH_CLAUDE_MD" = "yes" ]; then
  WRITE_CLAUDE_MD="yes"
  CREATED+=("CLAUDE.md (refreshed)")
fi

if [ "$WRITE_CLAUDE_MD" = "yes" ]; then
  cat > "$CLAUDE_MD" <<README
# Project context: $PROJECT_NAME

This folder is a CodeSync project — multiple AI-augmented collaborators work here, coordinating through structured markdown files. Each collaborator's machine is connected via Syncthing; everything in this folder stays in sync between machines.

## Folder layout

- \`_roles/<role>.md\` — role definitions for everyone in the project. Read these to understand who does what before routing tasks or questions.
- \`_inbox/<role>/\` — pending threads addressed to each role.
- \`_archive/<role>/\` — archived threads (preserved, hidden from default listings).
- \`_docs/\` — project-wide reference docs (architecture, conventions, glossary, decisions).

## Default behaviors for Claude

When working in this project, follow these patterns automatically. They're what make codesync feel ambient — the user doesn't have to remember to use it.

### Do automatically (no need to ask the user)

- **Read \`_docs/\` files before answering structure/convention questions.** When the user asks something that relates to project structure, naming conventions, domain terms, architecture, or accepted design decisions: look for a relevant file in \`_docs/\` and READ it BEFORE answering from general knowledge. The session-start summary lists what's available; if a likely-relevant filename is listed, open it first.
- **Read inbox threads for context.** When the user references a thread by slug, title, or topic — or when their current task plausibly connects to a recent inbox item — read the relevant file in \`_inbox/<role>/\` (or \`_archive/<role>/\`) before responding.
- **Read role profiles before routing or referencing another role.** When the user names another role (frontend, backend, designer, devops, pm, etc.), check \`_roles/<role>.md\` for that role's scope so the response matches what they actually own.

### Suggest, then wait for the user's yes (don't act silently)

- **Routing work to another role.** When the user describes work intended for someone else — phrases like *"tell the frontend…"*, *"ask backend to…"*, *"the designer should…"*, *"need devops to…"* — SUGGEST \`/codesync-thread-new\` and only run it after explicit confirmation. Do NOT silently create threads on the user's behalf.
- **Attaching files.** When the user shares an image, PDF, or other non-markdown file and the discussion implies another role would benefit from seeing it, SUGGEST \`/codesync-thread-attach\` after the thread is created.
- **Claiming threads.** When the user begins work on a thread that's in their inbox with status \`todo\` or \`wip\`, SUGGEST \`/codesync-thread-claim <slug>\` so other teammates in the same role know it's taken.
- **Marking done.** When the user reports completing work on a claimed thread, SUGGEST \`/codesync-thread-set-status <slug> done\` and optionally \`/codesync-thread-release <slug>\`.

### Never automatically (requires explicit user instruction)

- Never archive a thread (\`/codesync-thread-archive\`), release a claim (\`/codesync-thread-release\`), or mark a thread \`done\`/\`blocked\` without the user explicitly saying so. These are workflow judgments only the user should make.
- Never create projects, register roles, or pair with new peers without explicit user instruction. These are machine-level operations with persistent side effects.
- Never write threads "from" a role other than the user's currently active \`CODESYNC_ROLE\`. If they want to send "as" a different role, they need to switch \`CODESYNC_ROLE\` themselves first.

## Conventions

- New tasks, questions, notes, decisions between collaborators: \`/codesync-thread-new\`.
- Replies to existing threads: \`/codesync-thread-reply <slug>\`.
- Status transitions on a thread: \`/codesync-thread-set-status <slug> <status>\`.
- Resolved or stale threads: \`/codesync-thread-archive <slug>\`.
- Attach files (mockups, PDFs, screenshots) to a thread: \`/codesync-thread-attach <slug> <file>...\`.

## Notes for the team

(Edit this file to add project-specific instructions, vocabulary, or anything an incoming collaborator's Claude should know. This file is loaded into every Claude Code session that starts in or near this directory.)

<!-- codesync-template-v2 — If you've customized this file and don't want /install-codesync to auto-update it during future re-runs, delete this comment line. The detection looks for this exact marker; without it, your edits are preserved. -->
README
fi

# Output: list what was created (empty if everything already existed)
printf 'CREATED=%s\n' "$(IFS=,; echo "${CREATED[*]:-}")"
