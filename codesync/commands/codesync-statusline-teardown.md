---
description: Remove codesync's status-line segment — restores your previous statusLine command (or removes it entirely if there wasn't one)
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/statusline-teardown.sh:*)"]
---

# Uninstall the codesync status-line segment

The user invoked `/codesync-statusline-teardown`. This reverses `/codesync-statusline-setup`: it restores whatever statusLine command was active before codesync was installed (or removes the entry entirely if there was nothing prior).

## Step 1 — Run the teardown script

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/statusline-teardown.sh"
```

Outputs `STATUS=uninstalled` on success, `STATUS=not_installed` if codesync's wrap isn't currently the active statusLine.

## Step 2 — Tell the user

If status was `uninstalled`, print:

```
✓ codesync status-line removed.

Your prior statusLine has been restored (or removed entirely if you
didn't have one before). The change takes effect on the next status-line
refresh — a few seconds, or instantly if you send any message.
```

If status was `not_installed`, print:

```
codesync status-line wasn't installed — nothing to do.
```

## Constraints

- Don't edit settings.json directly; the script handles it with backups.
- Don't modify any other files.
