---
description: List all role profiles registered on this machine (and on paired machines, via the synced _roles/ folder)
argument-hint: "(no arguments)"
allowed-tools: ["Bash(echo:*)", "Bash(printenv:*)"]
---

# List CodeSync roles

The user invoked `/codesync-role-list`. Print every role profile that exists in `~/contracts/_roles/`, with a brief summary of each. Mark the role currently active in this terminal (if any).

## Step 1 — Find the contracts directory

Read `~/.config/codesync/config.json` and extract `contracts_dir`. If config is missing, STOP and ask the user to run `/install-codesync`.

## Step 2 — Find which role is active in this terminal

Run:

```!
printenv CODESYNC_ROLE
```

If the output is non-empty, that's the active role for this terminal. If empty (the variable is unset), no role is currently active in this terminal.

## Step 3 — List role files

List the `.md` files in `<contracts_dir>/_roles/`, **ignoring `README.md`**. For each remaining file:
- Read its content.
- Extract the role name (filename without `.md`).
- Pull the first 1–2 bullets from `## Owns` and `## Does not own` as a brief summary.

## Step 4 — Print the listing

Print in this shape (use `← active here` next to the role whose name matches `CODESYNC_ROLE`):

```
CodeSync roles registered (in <contracts_dir>/_roles/):

  backend                                    ← active here
    Owns:     auth, REST endpoints, background jobs
    Does not own: client UI, infra

  mobile
    Owns:     React Native iOS/Android, UI state
    Does not own: backend, web frontend

  devops
    Owns:     deploys, CI/CD, monitoring
    Does not own: application code
```

If no role is active in this terminal, omit the `← active here` marker entirely and add ONE line at the bottom:

```
No role is active in this terminal. Set one with:
    export CODESYNC_ROLE=<role-name>
in your shell (or in ~/.zshrc), then re-open Claude Code.
```

If `_roles/` contains only `README.md` (or is empty after ignoring it), print:

```
No role profiles registered yet. Run /codesync-role-new to create one,
or /install-codesync if you haven't set up the plugin yet.
```

## Constraints

- This command is read-only. Do not edit any file, run any mutating script, or modify env vars.
- Do not attempt to set `CODESYNC_ROLE` yourself — a slash command cannot affect the parent shell's environment. The user sets the env var themselves.
