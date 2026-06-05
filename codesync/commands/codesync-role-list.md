---
description: List role profiles registered in the active project (synced from paired peers too)
argument-hint: "(no arguments)"
allowed-tools: ["Bash(printenv:*)"]
---

# List CodeSync roles

The user invoked `/codesync-role-list`. Print every role profile that exists in the active project's `_roles/` directory, with a brief summary. Mark the role currently active in this terminal (if any).

## Step 1 — Resolve the active project

Run:

```!
printenv CODESYNC_PROJECT
```

If output is empty, STOP and tell the user: *"No project active in this terminal. Set CODESYNC_PROJECT in your shell first (or run /codesync-project-list to see what's registered)."*

Read `~/.config/codesync/config.json` and look up `projects.<active>.path`. If the project isn't in the config, STOP and tell the user to run `/codesync-project-new` first.

## Step 2 — Find which role is active in this terminal

Run:

```!
printenv CODESYNC_ROLE
```

If output is non-empty, that's the active role for this terminal. If empty, no role is currently active.

## Step 3 — List role files

List the `.md` files in `<project-path>/_roles/`, **ignoring `README.md`**. For each remaining file:
- Read its content.
- Extract the role name (filename without `.md`).
- Pull the first 1–2 bullets from `## Owns` and `## Does not own` as a brief summary.

## Step 4 — Print the listing

Print in this shape (use `← active here` next to the role whose name matches `CODESYNC_ROLE`):

```
CodeSync roles in project '<project-name>' (<project-path>/_roles/):

  backend                                    ← active here
    Owns:     auth, REST endpoints, background jobs
    Does not own: client UI, infra

  frontend
    Owns:     React UI, client state, accessibility
    Does not own: backend, infra
```

If no role is active in this terminal, omit the `← active here` marker and add ONE line at the bottom:

```
No role is active in this terminal. Set one with:
    export CODESYNC_ROLE=<role-name>
in your shell (or use the `cs` wrapper from the README), then re-open Claude Code.
```

If `_roles/` contains only `README.md` (or is empty after ignoring it), print:

```
No role profiles registered yet in project '<project-name>'. Run /codesync-role-new
to create one.
```

## Constraints

- This command is read-only. Do not edit any file, run any mutating script, or modify env vars.
- Do not attempt to set `CODESYNC_ROLE` yourself — a slash command cannot affect the parent shell's environment.
