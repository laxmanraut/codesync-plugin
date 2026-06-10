# TODOS

## Linux support via the platform layer

- **What:** Add Linux as a third branch of `lib/platform/` — `linux.sh` with `notify-send` notifications, systemd user timers (autopilot/watcher), XDG paths; extend the CI matrix with `ubuntu-latest`.
- **Why:** Completes the "works everywhere" claim for the public launch; Claude Code runs natively on Linux.
- **Pros:** Cheap after the Windows platform layer exists (the layer was designed for exactly this); widest possible audience for the published plugin.
- **Cons:** Zero Linux users exist today; every supported platform adds permanent CI + support burden.
- **Context:** Decided during the 2026-06-10 engineering review of the Windows port (design doc: `~/.gstack/projects/CODEBASE_UG/admin-unknown-design-20260610-170011.md`). Deliberately deferred until the Windows wedge proves out (checkpoint metric: median time-to-first-notice ≤ 1h in week one). Start from `lib/platform/`, mirror `windows.sh`, add `ubuntu-latest` to `.github/workflows/ci.yml`.
- **Depends on / blocked by:** Milestone 1 of the Windows port (platform layer + test suite + basic CI) must land first.
