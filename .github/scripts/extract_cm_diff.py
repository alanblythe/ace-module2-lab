#!/usr/bin/env python3
"""Extract the unified diff that `cm fix` prints to stdout.

`cm fix` reliably *prints* the patch (between a "Patch generated successfully"
banner and a box-drawing separator) even when it doesn't write it to disk in a
non-interactive CI shell. This carves out just the diff so the workflow can
`git apply` it deterministically — independent of cm's interactive apply path.

Usage:  extract_cm_diff.py <cm-fix-output.log>   # writes the diff to stdout
Emits nothing (exit 0) if no diff is present.
"""
from __future__ import annotations

import re
import sys

DIFF_START = re.compile(r"^(diff --git |--- a/)")
# Stop at cm's box-drawing separator (U+2500 '─'), the trailing session-log
# line, or any obvious non-diff banner.
STOP = re.compile(r"^(─|=== |\s*✨|\d{4}-\d\d-\d\dT.*Session log)")


def is_diff_line(line: str) -> bool:
    if line == "":
        return True  # tolerate blank lines inside the hunk; trimmed at the end
    return line[0] in " +-@\\" or line.startswith(("diff --git", "--- ", "+++ ", "index "))


def main() -> int:
    if len(sys.argv) < 2:
        sys.stderr.write("usage: extract_cm_diff.py <cm-fix-output.log>\n")
        return 0
    with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    out: list[str] = []
    capturing = False
    for line in lines:
        if not capturing:
            if DIFF_START.match(line):
                capturing = True
                out.append(line)
            continue
        if STOP.match(line) or not is_diff_line(line):
            break
        out.append(line)

    # Trim trailing blank lines that aren't real context.
    while out and out[-1] == "":
        out.pop()

    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
