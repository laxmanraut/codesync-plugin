---
description: Claim a thread — sets the owner field to your identity (and flips todo→wip by default) so the other person in your role knows it's taken
argument-hint: "<slug> [--no-status-change]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claim-thread.sh:*)"]
---

# Claim a CodeSync thread

The user invoked `/codesync-thread-claim $ARGUMENTS`. Use this when two or more people on the team share the same role — claiming a thread tells the other(s) that you've picked it up so they don't duplicate work.

## Step 1 — Parse args

`$ARGUMENTS` should contain a `<slug>` (required) and optionally `--no-status-change`.

If `$ARGUMENTS` is empty or doesn't contain a recognisable slug, STOP and ask: *"Which thread do you want to claim? Pass the slug — e.g. /codesync-thread-claim refactor-pagination."* Suggest `/codesync-thread-list` if they don't know.

## Step 2 — Run the claim script

Pass `$ARGUMENTS` through directly — the script's parser handles the flag and the positional slug:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/claim-thread.sh" --slug $ARGUMENTS
```

(If the user passed `--no-status-change`, it appears in `$ARGUMENTS` and the script handles it. The `--slug` flag is needed for positional argument parsing — Claude should ensure the slug comes right after `--slug`.)

The script prints either:
- `Claimed by '<identity>' (status: todo → wip).` and `FILE=<path>` on success
- `Claimed by '<identity>'.` (no status change) on success
- `You (<identity>) already own this thread — no change needed.` if already claimed by you
- An error if the thread doesn't exist, has no frontmatter, or is owned by someone else

Surface the script's output verbatim. If it exited non-zero, surface the error and STOP.

## Step 3 — Tell the user what happened

If the script succeeded, the script's own message is enough — just confirm in one line:

```
✓ Thread '<slug>' is yours. The other people in your role will see [owned by <identity>] in their inbox listings and skip it.
```

If the script reports it's owned by someone else, suggest one of:
- Talk to the current owner before taking it over (manual coordination)
- Wait for them to `/codesync-thread-release <slug>`

## Constraints

- Never modify any thread file directly — always via the script (atomic write, race-protected).
- If identity isn't set on this machine, the script errors with a clear message — surface it; don't try to auto-register identity from this command.
