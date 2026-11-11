#!/usr/bin/env python3
"""Guard C6 (Addendum A1 Rev 1): scan every tracked text file for SIN/ITN candidates with the reference detector
(origin 'native'). Prints file:line:rule for each hit, never the value. Exit 1 on any hit.
Binary files (NUL byte) and files larger than 5 MiB are skipped and counted. Usage: sin_repo_scan.py [--all-history]
--all-history additionally scans every blob reachable from any ref (slower; used before publishing history)."""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "apps", "executor"))
from bnx_exec import sin_detector as S  # noqa: E402

LIMIT = 5 * 1024 * 1024


def scan_bytes(name, data, out):
    if b"\0" in data[:8192] or len(data) > LIMIT:
        return False
    text = data.decode("utf-8", errors="replace")
    for hit in S.scan(text):
        line = text.count("\n", 0, hit["start"]) + 1
        out.append(f"{name}:{line}:{hit['rule']}")
    return True


def main():
    os.chdir(ROOT)
    out, scanned, skipped = [], 0, 0
    for f in subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True).stdout.split(b"\0"):
        if not f:
            continue
        p = f.decode()
        if not os.path.isfile(p):
            continue
        if scan_bytes(p, open(p, "rb").read(), out):
            scanned += 1
        else:
            skipped += 1
    if "--all-history" in sys.argv:
        objs = subprocess.run(["git", "rev-list", "--objects", "--all"], capture_output=True, text=True, check=True).stdout.split("\n")
        seen = set()
        for line in objs:
            parts = line.split(" ", 1)
            if len(parts) != 2 or parts[0] in seen:
                continue
            seen.add(parts[0])
            if subprocess.run(["git", "cat-file", "-t", parts[0]], capture_output=True, text=True).stdout.strip() != "blob":
                continue
            data = subprocess.run(["git", "cat-file", "blob", parts[0]], capture_output=True).stdout
            scan_bytes("history:" + parts[1], data, out)
    for o in sorted(set(out)):
        print(o)
    print(f"sin_repo_scan: detector {S.VERSION}, {scanned} files scanned, {skipped} skipped (binary or > 5 MiB), {len(set(out))} hit(s)")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main())
