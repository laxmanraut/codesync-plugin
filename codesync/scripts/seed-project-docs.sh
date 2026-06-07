#!/usr/bin/env bash
# seed-project-docs.sh — Idempotently scaffold project-wide docs.
# Creates _docs/ directory, _docs/README.md, and a starter CLAUDE.md
# at the project root if they don't already exist. Never overwrites.
#
# Args:
#   --project <name>   (required)  used for the CLAUDE.md heading
#   --path <path>      (required)  absolute path to the project directory
#
# Used by create-project.sh (new projects) AND by install-codesync's
# backfill step (existing pre-v0.14 projects that lack these files).

set -euo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PROJECT_NAME=""
PROJECT_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || err "--project requires a value"; PROJECT_NAME="$2"; shift 2 ;;
    --path)    [ $# -ge 2 ] || err "--path requires a value";    PROJECT_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$PROJECT_NAME" ] || err "Usage: seed-project-docs.sh --project <name> --path <path>"
[ -n "$PROJECT_PATH" ] || err "Usage: seed-project-docs.sh --project <name> --path <path>"
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
CLAUDE_MD="$PROJECT_PATH/CLAUDE.md"
if [ ! -f "$CLAUDE_MD" ]; then
  cat > "$CLAUDE_MD" <<README
# Project context: $PROJECT_NAME

This folder is a CodeSync project — multiple AI-augmented collaborators work here, coordinating through structured markdown files. Each collaborator's machine is connected via Syncthing; everything in this folder stays in sync between machines.

## Folder layout

- \`_roles/<role>.md\` — role definitions for everyone in the project. Read these to understand who does what before routing tasks or questions.
- \`_inbox/<role>/\` — pending threads addressed to each role.
- \`_archive/<role>/\` — archived threads (preserved, hidden from default listings).
- \`_docs/\` — project-wide reference docs (architecture, conventions, glossary, decisions). **Consult these whenever a question relates to project structure, conventions, or domain terms — before answering from general knowledge.**

## Conventions

- New tasks, questions, notes, decisions between collaborators: use \`/codesync-thread-new\`.
- Replies to existing threads: \`/codesync-thread-reply <slug>\`.
- Status transitions on a thread: \`/codesync-thread-set-status <slug> <status>\`.
- Resolved or stale threads: \`/codesync-thread-archive <slug>\`.

## Notes for the team

(Edit this file to add project-specific instructions, vocabulary, or anything an incoming collaborator's Claude should know. This file is loaded into every Claude Code session that starts in or near this directory.)
README
  CREATED+=("CLAUDE.md")
fi

# Output: list what was created (empty if everything already existed)
printf 'CREATED=%s\n' "$(IFS=,; echo "${CREATED[*]:-}")"
