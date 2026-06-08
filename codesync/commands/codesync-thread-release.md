---
description: Release a thread you previously claimed — clears the owner field so anyone else in your role can pick it up
argument-hint: "<slug>"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/release-thread.sh:*)"]
---

# Release a CodeSync thread

The user invoked `/codesync-thread-release $ARGUMENTS`. Use this when you previously claimed a thread but won't be working on it after all — releasing returns it to the unclaimed pool so anyone else sharing your role can take it.

## Step 1 — Parse args

`$ARGUMENTS` should contain a `<slug>`.

If empty, STOP and ask: *"Which thread do you want to release? Pass the slug — e.g. /codesync-thread-release refactor-pagination."*

## Step 2 — Run the release script

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/release-thread.sh" --slug $ARGUMENTS
```

The script prints either:
- `Released. Thread no longer owned by '<identity>'.` on success
- `Thread is already unclaimed — no change.` if there was no owner
- An error if the thread is owned by someone else (only the owner can release their own claim)

Surface the script's output verbatim. If it exited non-zero, surface the error and STOP.

## Step 3 — Tell the user what happened

One short confirmation:

```
✓ Released '<slug>'. It's back in the unclaimed pool.
```

The thread's status is unchanged — release only clears the owner field. If the thread was promoted to `wip` when you claimed it and you want to revert to `todo`, run `/codesync-thread-set-status <slug> todo` separately.

## Constraints

- Never modify the thread file directly — always via the script.
- The script refuses to release a thread owned by someone other than the current identity. If the user really needs to "steal" a claim, they should talk to the current owner — there's no force flag (intentional).
