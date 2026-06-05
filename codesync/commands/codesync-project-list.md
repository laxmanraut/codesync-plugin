---
description: List all CodeSync projects registered on this machine, marking the one active in this terminal
argument-hint: "(no arguments)"
allowed-tools: ["Bash(python3:*)", "Bash(printenv:*)"]
---

# List CodeSync projects

The user invoked `/codesync-project-list`. Show every project registered on this machine, with its path and Syncthing folder id. Mark the one whose name matches `$CODESYNC_PROJECT` (the project active in this terminal).

## Step 1 — Find the active project for this terminal

```!
printenv CODESYNC_PROJECT
```

If output is non-empty, that's the active project. Else no project is active in this terminal.

## Step 2 — List registered projects

Read `~/.config/codesync/config.json` and pull out the `projects` map. If config doesn't exist or has no projects, print:

```
No projects registered yet. Run /install-codesync if you haven't set up the
plugin, or /codesync-project-new to add a project.
```

Otherwise, for each project entry, print:

```
CodeSync projects on this machine:

  lead_inbox                       ← active in this terminal
    Path:        /Users/admin/codesync/lead_inbox
    Folder ID:   codesync-lead_inbox

  mobile-app
    Path:        /Users/admin/codesync/mobile-app
    Folder ID:   codesync-mobile-app
```

The `← active in this terminal` marker goes only next to the project matching `CODESYNC_PROJECT`. If `CODESYNC_PROJECT` is set but doesn't match any registered project, add a note at the bottom:

```
CODESYNC_PROJECT is set to "<value>" but no project by that name is registered.
Run /codesync-project-new to create it, or unset / change CODESYNC_PROJECT.
```

## Constraints

- This command is read-only. Do not edit config or any file.
