#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Payment-card numbers in the repository (rule D-PAN-1: a full card number is never stored; the repository is
public). Scans every tracked text file, and with --all-history every blob reachable from any ref, with the reference PAN
detector (apps/executor/bnx_exec/pan_detector.py). Prints file:line:scheme for each hit, never the value. Exit 1 on any hit,
2 when the scan itself could not run. Binary files (NUL byte) and files larger than 5 MiB are skipped and counted.

Published test numbers (for example the scheme test numbers used by guard tests) are allowed by the SHA-256 of their digits
in tools/s4/pan_repo_scan_allow.txt, so the allowlist itself holds no card number. Tests build their synthetic numbers at
run time; no literal is committed."""
import hashlib, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "apps", "executor"))
from bnx_exec import pan_detector as P  # noqa: E402

LIMIT = 5 * 1024 * 1024
ALLOW = set()
_af = os.path.join(ROOT, "tools", "s4", "pan_repo_scan_allow.txt")
if os.path.exists(_af):
    for _l in open(_af, encoding="utf-8"):
        _p = _l.split("#", 1)[0].split()
        if _p:
            ALLOW.add(_p[0])
ALLOWED = []


def scan_bytes(name, data, out):
    if b"\0" in data[:8192] or len(data) > LIMIT:
        return False
    text = P.normalize(data.decode("utf-8", errors="replace"))
    for a, b in P.scan(text):
        digits = "".join(c for c in text[a:b] if c.isdigit())
        line = text.count("\n", 0, a) + 1
        if hashlib.sha256(digits.encode()).hexdigest() in ALLOW:
            ALLOWED.append(f"{name}:{line}")
            continue
        out.append(f"{name}:{line}:{P.scheme(digits)}")
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
            data = subprocess.run(["git", "cat-file", "blob", parts[0]], capture_output=True, check=True).stdout
            scan_bytes("history:" + parts[1], data, out)
    for o in sorted(set(out)):
        print(o)
    print(f"pan_repo_scan: detector {P.VERSION}, {scanned} files scanned, {skipped} skipped (binary or > 5 MiB), {len(set(out))} hit(s), "
          f"{len(set(ALLOWED))} published test number(s) allowed")
    return 1 if out else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError) as e:
        print(f"pan_repo_scan: ERROR, the scan did not run: {e}", file=sys.stderr)
        sys.exit(2)
