# TODOS

## Linux support via the platform layer

- **What:** Add Linux as a third branch of `lib/platform/` — `linux.sh` with `notify-send` notifications, systemd user timers (autopilot/watcher), XDG paths; extend the CI matrix with `ubuntu-latest`.
- **Why:** Completes the "works everywhere" claim for the public launch; Claude Code runs natively on Linux.
- **Pros:** Cheap after the Windows platform layer exists (the layer was designed for exactly this); widest possible audience for the published plugin.
- **Cons:** Zero Linux users exist today; every supported platform adds permanent CI + support burden.
- **Context:** Decided during the 2026-06-10 engineering review of the Windows port (design doc: `~/.gstack/projects/CODEBASE_UG/admin-unknown-design-20260610-170011.md`). Deliberately deferred until the Windows wedge proves out (checkpoint metric: median time-to-first-notice ≤ 1h in week one). Start from `lib/platform/`, mirror `windows.sh`, add `ubuntu-latest` to `.github/workflows/ci.yml`.
- **Depends on / blocked by:** Milestone 1 of the Windows port (platform layer + test suite + basic CI) must land first.

## `codesync launch <project> <role>` CLI wrapper

- **What:** A thin terminal command / shell function that does the same env-set + `claude` launch as the dashboard's launch-agent button, reusing `codesync_launch_terminal`.
- **Why:** The launch-agents eng review's outside voice argued launching is arguably better as a CLI than a localhost POST — lowest friction, works headless, no HTTP attack surface.
- **Pros:** Reuses the new launcher; no extra attack surface; usable from any terminal without opening the dashboard.
- **Cons:** A second entry point overlapping the dashboard button; another path in the test matrix.
- **Context:** Captured during the 2026-06-13 eng review of the launch-agents feature (design doc: `~/.gstack/projects/CODEBASE_UG/admin-unknown-design-20260613-134505.md`). Build it once `codesync_launch_terminal` exists (task T1 of that feature).
- **Depends on / blocked by:** `codesync_launch_terminal` (launch-agents feature, task T1).

## Full Syncthing conflict-recovery surface

- **What:** Extend the dashboard's `*.sync-conflict-*` flagging (added for `_roles/` and `_inbox/` by the launch-agents feature) to ALL synced paths, plus a "resolve" action and a link to `.stversions/` for recovery.
- **Why:** Silent last-write-wins conflicts are a latent risk for the whole product, not just roles; surfacing is step one, recovery is the complete answer.
- **Pros:** Protects the core sync model end to end; turns an invisible failure mode into a recoverable one.
- **Cons:** Scope well beyond launch-agents; "resolve" is a new write action = more attack surface and more tests.
- **Context:** Captured during the 2026-06-13 eng review (launch-agents). The conflict-surfacing groundwork lands as task T7 of that feature; this TODO is the recovery/resolve layer on top.
- **Depends on / blocked by:** Conflict-surfacing groundwork (launch-agents feature, task T7).
