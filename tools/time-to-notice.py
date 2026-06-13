#!/usr/bin/env python3
"""time-to-notice.py — the codesync checkpoint metric.

Answers the one question that validates codesync's whole premise: when a thread
arrives for you, how long until it gets noticed? Run it on each paired machine
after a few days of real handoffs.

  python3 tools/time-to-notice.py [project]

It pairs every entry in ~/.config/codesync/seen-<project>.log (the moment a
thread was first surfaced to you) against that thread file's mtime (when it
arrived via Syncthing). The gap is the notice latency. Self-contained: no
plugin imports, just stdlib — so the colleague can run it too.

Gate from the design: median time-to-notice <= 1 hour.
"""
import calendar
import json
import os
import sys
import time

CFG = os.path.expanduser("~/.config/codesync/config.json")


def iso_to_epoch(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None


def human(sec):
    if sec is None:
        return "n/a"
    sec = int(sec)
    if sec < 90:
        return f"{sec}s"
    if sec < 5400:
        return f"{sec // 60}m"
    if sec < 172800:
        return f"{sec // 3600}h"
    return f"{sec // 86400}d"


def main():
    if not os.path.exists(CFG):
        sys.exit(f"No config at {CFG} — run /install-codesync first.")
    cfg = json.load(open(CFG))
    projects = cfg.get("projects", {})
    if not projects:
        sys.exit("No projects registered on this machine.")

    project = sys.argv[1] if len(sys.argv) > 1 else next(iter(sorted(projects)))
    proj = projects.get(project)
    if not proj:
        sys.exit(f"Project '{project}' not found. Known: {', '.join(sorted(projects))}")
    proj_path = proj.get("path", "")
    seen_log = os.path.expanduser(f"~/.config/codesync/seen-{project}.log")

    print(f"\ncodesync — time to notice · project '{project}'")
    print("─" * 52)
    if not os.path.exists(seen_log):
        print("  No seen-log yet — nothing has been surfaced on this machine.")
        print("  (This fills in once threads arrive and you open Claude Code.)\n")
        return

    latencies = []
    rows = []
    for line in open(seen_log):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        rel, seen_iso = parts[0], (parts[1] if len(parts) > 1 else "")
        seen_ep = iso_to_epoch(seen_iso)
        try:
            arrived = os.path.getmtime(os.path.join(proj_path, rel))
        except OSError:
            arrived = None
        if seen_ep is None or arrived is None:
            continue
        lat = max(0, seen_ep - arrived)
        latencies.append(lat)
        rows.append((lat, rel))

    if not latencies:
        print("  Entries exist but none could be paired to a thread file")
        print("  (files may have been archived/deleted). No measurable latency yet.\n")
        return

    s = sorted(latencies)
    n = len(s)
    median = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2
    p90 = s[min(n - 1, int(round(0.9 * (n - 1))))]
    gate = "PASS ✓" if median <= 3600 else "MISS ✗ (target ≤ 1h)"

    print(f"  measured handoffs:  {n}")
    print(f"  median:             {human(median)}      [gate ≤ 1h → {gate}]")
    print(f"  p90:                {human(p90)}")
    print(f"  fastest / slowest:  {human(s[0])} / {human(s[-1])}")
    print()
    print("  slowest few (thread → notice latency):")
    for lat, rel in sorted(rows, reverse=True)[:5]:
        name = rel.rsplit("/", 1)[-1][:-3] if rel.endswith(".md") else rel
        print(f"    {human(lat):>5}  {name[:54]}")
    print()


if __name__ == "__main__":
    main()
