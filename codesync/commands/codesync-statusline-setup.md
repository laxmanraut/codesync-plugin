---
description: Install codesync's status-line segment — adds an unread-count indicator to Claude Code's status bar, composing safely with any existing statusLine
argument-hint: "(no arguments)"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh:*)"]
---

# Install the codesync status-line segment

The user invoked `/codesync-statusline-setup`. This safely adds codesync's "N new" indicator to Claude Code's bottom status bar. When there are unseen items in your inbox (since the last Claude turn), the indicator shows `codesync ▴ 3 new` next to whatever else is already on your status line (netmeter, etc.). When there are no new items, codesync stays silent — no real estate wasted.

The setup is **non-destructive**: it backs up your `~/.claude/settings.json` and preserves any existing statusLine command by chaining through a wrapper.

## Step 1 — Run the setup script

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh"
```

The script outputs one of:

```
STATUS=installed
WRAP=<absolute path to wrap script>
PRIOR_SAVED_TO=<path to prior command capture>  (only if there was one)
```

or, on subsequent runs:

```
STATUS=already_installed
WRAP=<absolute path>
```

If it errors (no `~/.claude/` directory, wrap script missing), surface the error and STOP.

## Step 2 — Tell the user what happens next

If status was `installed`, print:

```
✓ codesync status-line segment installed.

Claude Code refreshes the status line every few seconds, so the
indicator will appear at the bottom of this window shortly. If you
don't see anything yet, force a refresh by sending any message
(even a no-op) — the status line re-renders on every turn.

What you'll see:
  • codesync ▴ N new   — N unseen items in your role's inbox
                         (silent when N is 0)
  • The indicator joins your existing status (netmeter, etc.) with ' · '

To uninstall later: /codesync-statusline-teardown
```

If status was `already_installed`, print:

```
codesync status-line is already installed — nothing to do.
```

## Constraints

- Never edit `~/.claude/settings.json` directly from this command — the script handles that with backups.
- Don't run if the script reports an error; STOP and surface the message.
- Don't modify any other files.
