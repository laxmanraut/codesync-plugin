---
description: List project-wide docs in the active project's _docs/ directory
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/list-docs.sh:*)", "Bash(python3:*)"]
---

# List project docs

The user invoked `/codesync-doc-list`. List the markdown files in the active project's `_docs/` directory — these are project-wide reference notes (architecture, conventions, glossary, decisions, etc.) shared with every collaborator via Syncthing.

## Step 1 — Confirm a project is active

Run the resolver:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/lib/resolve.py"
```

Extract `CODESYNC_PROJECT=` value (strip single quotes).

If empty, STOP and tell the user: *"No project active in this terminal. Set CODESYNC_PROJECT in your shell or attach this directory with /codesync-project-attach <project>."*

## Step 2 — Run the list script

The script reads `CODESYNC_PROJECT` from the environment and prints the doc listing. If you resolved `PROJECT` from the marker (not the env), pass it inline:

```bash
CODESYNC_PROJECT="<PROJECT>" "${CLAUDE_PLUGIN_ROOT}/scripts/list-docs.sh"
```

## Step 3 — Show the output

Print the script's output verbatim. If `_docs/` doesn't exist yet (older projects from before v0.14), the script tells the user where to create it or to re-run `/install-codesync` to scaffold.

## Constraints

- Read-only. Do not modify any file.
- Do not edit, summarise, or pre-interpret the doc contents — just list filenames + headings + sizes. The user can ask Claude to read any specific doc afterwards.
