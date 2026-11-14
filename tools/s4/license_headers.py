# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""License headers (CR-3, docs/s4/Copyright_and_Contributions.md).

Every source file in scope carries two comment lines at its top:

    Copyright <year> <holder>
    SPDX-License-Identifier: Apache-2.0

The copyright line is taken from NOTICE (its second line), so a change of holder is made once in NOTICE and
propagated with --apply.

usage:  license_headers.py --check     exit 1 if a file in scope lacks the header or carries a different copyright line
        license_headers.py --apply     add or update the header in place

Out of scope, never touched: committed migrations and bootstrap files (db/migrations up to 9039, db/bootstrap: installed
databases depend on their exact bytes; migrations from 9040 on are in scope), historical material (db/history), test fixtures (tests/sql), frozen reference oracles (tests/oracle: AT-R28-GOLD pins
their sha256), evidence records (EVIDENCE),
reviewer reports (docs/s4/reviews/g0: written by others), and file types without comments (JSON, lock files).
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPDX = "SPDX-License-Identifier: Apache-2.0"
STYLE = {".py": "#", ".sh": "#", ".yml": "#", ".yaml": "#", ".toml": "#",
         ".js": "//", ".mjs": "//", ".sql": "--", ".css": "/*", ".html": "<!--"}
EXCLUDE = ("EVIDENCE/", "docs/s4/reviews/g0/", "db/migrations/", "db/bootstrap/", "db/history/", "tests/sql/", "tests/oracle/")


def holder_line():
    lines = open(os.path.join(ROOT, "NOTICE"), encoding="utf-8").read().splitlines()
    line = lines[1].strip() if len(lines) > 1 else ""
    if not re.fullmatch(r"Copyright \d{4}(-\d{4})? \S.*", line):
        sys.exit("NOTICE line 2 must be the copyright line, e.g. 'Copyright 2026 <holder>'")
    return line


def in_scope():
    files = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    def new_migration(f):  # migrations from 9040 on carry the header from the start; 9039 and earlier are never edited
        m = re.match(r"db/migrations/(\d{4})_", f)
        return bool(m) and m.group(1) >= "9040"
    return [f for f in files if os.path.splitext(f)[1] in STYLE and (new_migration(f) or not f.startswith(EXCLUDE))]


def render(ext, copyright_line):
    c = STYLE[ext]
    if c == "/*":
        return [f"/* {copyright_line}", f"   {SPDX} */"]
    if c == "<!--":
        return [f"<!-- {copyright_line}", f"     {SPDX} -->"]
    return [f"{c} {copyright_line}", f"{c} {SPDX}"]


def insert_at(lines, ext):
    """index after the lines that must stay first: a shebang, a Python encoding line, an HTML doctype"""
    i = 0
    if lines and lines[0].startswith("#!"):
        i = 1
    if ext == ".py" and len(lines) > i and re.match(r"#.*coding[:=]", lines[i]):
        i += 1
    if ext == ".html" and lines and lines[0].lower().startswith("<!doctype"):
        i = 1
    return i


def fix(text, ext, copyright_line):
    lines = text.split("\n")
    want = render(ext, copyright_line)
    i = insert_at(lines, ext)
    if len(lines) >= i + 2 and SPDX in lines[i + 1] and "Copyright" in lines[i]:
        if lines[i:i + 2] == want:
            return text
        lines[i:i + 2] = want                      # holder changed in NOTICE
    else:
        lines[i:i] = want
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    cl = holder_line()
    bad = []
    files = in_scope()
    for f in files:
        p = os.path.join(ROOT, f)
        text = open(p, encoding="utf-8").read()
        new = fix(text, os.path.splitext(f)[1], cl)
        if new != text:
            bad.append(f)
            if a.apply:
                with open(p, "w", encoding="utf-8", newline="") as fh:
                    fh.write(new)
    if a.apply:
        print(f"license_headers: {len(files)} files in scope, {len(bad)} updated ({cl})")
        return 0
    if bad:
        print(f"license_headers: {len(bad)} of {len(files)} files lack the header '{cl}':")
        for f in bad:
            print("  " + f)
        return 1
    print(f"license_headers: OK, {len(files)} files carry '{cl}' / {SPDX}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
