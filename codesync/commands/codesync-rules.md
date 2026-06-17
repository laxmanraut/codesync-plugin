---
description: Create or view per-project rules & guardrails (GUARDRAILS.md) that every agent — launched, autopilot, and autonomous — must follow. Synced, so shared with the whole team.
argument-hint: "[init | show | path]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/rules-init.sh:*)"]
---

# CodeSync project rules & guardrails

The user invoked `/codesync-rules $ARGUMENTS`. This manages **`GUARDRAILS.md`** in
the active project — the binding, human-authored rules every agent in the project
must follow.

How the rules reach each kind of agent:
- **Launched terminal agents + autopilot** run with their working directory inside
  the synced project, so Claude Code auto-loads the project's `CLAUDE.md`, which
  `@`-imports `GUARDRAILS.md`.
- **Autonomous agents** run in an isolated clone (not the synced folder), so they
  can't auto-load it — the autonomy runner **injects `GUARDRAILS.md` (and the
  agent's `_roles/<role>.md`) into the agent's prompt every run**.
- `GUARDRAILS.md` lives in the **synced** project folder, so the whole team shares
  one set of rules automatically.

Important: `GUARDRAILS.md` is the human-readable **contract** (advisory — the model
reads and follows it). The **hard** limit on what an agent *can* do is still its
role's tool scope (`allowed-tools` / the launch capability). If a rule must never
be broken, also encode it as a tool restriction, not just prose here.

## Step 1 — Parse the mode
- `init` (or empty) → create `GUARDRAILS.md` (if absent) + wire `CLAUDE.md` to import it
- `show` → print the current `GUARDRAILS.md`
- `path` → print the file path

## Step 2 — Run the script
The script needs `CODESYNC_PROJECT` resolved (env or marker) — rules are per project.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/rules-init.sh" ${ARGUMENTS:-init}
```

## Step 3 — Tell the user
- For **init**: print the `GUARDRAILS.md` path and tell them to edit it — it ships
  with a starter `## Always / ## Never / ## Ask first` template. Remind them it's
  synced (teammates get it) and that autonomous agents will have it injected on
  their next run. Offer to help draft the rules if they describe their project.
- For **show**/**path**: print the script output verbatim.

## Constraints
- Never overwrite an existing `GUARDRAILS.md` — the script only scaffolds when absent.
- Do not hand-edit the autonomy runner or `CLAUDE.md` import wiring from here.
- Keep rules short and concrete; for hard limits, point the user at role tool scope
  (`/codesync-autonomy enable <role> "<tools>"` or the launch capability presets).
