---
description: Claim a thread (sets owner + promotes todo→wip) — or pass --release to give it back to the unclaimed pool
argument-hint: "<slug> [--release] [--no-status-change]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claim-thread.sh:*)"]
---

# Claim (or release) a CodeSync thread

The user invoked `/codesync-thread-claim $ARGUMENTS`.

**Default mode — claim.** Sets `owner: <your-identity>` on the thread. If current status is `todo`, also flips it to `wip`. Use this when two or more teammates share a role and you want others to know you've taken a thread.

**With `--release` — release.** Clears the `owner` field, returning the thread to the unclaimed pool. Refuses if the current owner isn't you.

## Step 1 — Parse args

`$ARGUMENTS` should contain a `<slug>` (required) and optionally `--release` and/or `--no-status-change`.

If `$ARGUMENTS` is empty or doesn't contain a recognisable slug, STOP and ask: *"Which thread do you want to claim or release? Pass the slug — e.g. `/codesync-thread-claim refactor-pagination` to claim, or add `--release` to give it back."* Suggest `/codesync-thread-list` if they don't know.

## Step 2 — Run the claim script

Pass `$ARGUMENTS` through directly — the script's parser handles `--release` and `--no-status-change`. The slug should come right after `--slug`:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/claim-thread.sh" --slug $ARGUMENTS
```

The script prints either:
- **Claim**: `Claimed by '<identity>' (status: todo → wip).` and `FILE=<path>`
- **Claim, no status change** (`--no-status-change` passed): `Claimed by '<identity>'.`
- **Claim, already yours**: `You (<identity>) already own this thread — no change needed.`
- **Release** (`--release` passed): `Released. Thread no longer owned by '<identity>'.`
- **Release, already unclaimed**: `Thread is already unclaimed — no change.`
- **Errors** if the thread doesn't exist, lacks frontmatter, or is owned by someone else

Surface the script's output verbatim. If non-zero exit, surface the error and STOP.

## Step 3 — Tell the user what happened

For **claim** success:
```
✓ Thread '<slug>' is yours. Other teammates in your role will see [owned by <identity>] in their listings and skip it.
```

For **release** success:
```
✓ Released '<slug>'. It's back in the unclaimed pool. The thread's status is unchanged — if you want to revert wip→todo, run /codesync-thread-set-status <slug> todo.
```

If the script reports it's owned by someone else, suggest one of:
- Talk to the current owner before taking it over
- Wait for them to run `/codesync-thread-claim <slug> --release`

## Constraints

- Never modify any thread file directly — always via the script (atomic write, race-protected).
- If identity isn't set on this machine, the script errors with a clear message — surface it; don't try to auto-register identity from this command.
- The `--release` flag is not "force-release" — it only works if you're the current owner. To take over from someone else, they need to release first.
