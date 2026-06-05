"""Shared YAML frontmatter parser for codesync scripts.

Recognises the codesync: namespace inside a leading `---` / `---` block.
Returns a dict of fields (from, to, status, title, created, replies-to)
or None when no frontmatter / no codesync namespace is present.
"""
import re

FM_RE = re.compile(r'\A---\s*\n(.*?)\n---', re.DOTALL)


def parse_frontmatter(text):
    """Parse the codesync: namespace from YAML frontmatter at the top of `text`.

    Returns a dict of string keys → string values, or None.
    """
    m = FM_RE.match(text)
    if not m:
        return None
    in_cs = False
    fm = {}
    for line in m.group(1).splitlines():
        stripped = line.rstrip()
        if stripped == "":
            continue  # blank lines don't terminate the codesync block
        if stripped == "codesync:":
            in_cs = True
            continue
        if in_cs and stripped.startswith("  "):
            kv = stripped[2:]
            if ":" in kv:
                k, v = kv.split(":", 1)
                fm[k.strip()] = v.strip().strip('"').strip("'")
        else:
            in_cs = False
    return fm if fm else None


def read_frontmatter_from_file(path, max_bytes=4096):
    """Open `path`, read the first `max_bytes`, parse frontmatter.

    Returns a dict or None on any error / no frontmatter.
    """
    try:
        with open(path) as f:
            head = f.read(max_bytes)
    except OSError:
        return None
    return parse_frontmatter(head)
