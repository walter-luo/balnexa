#!/usr/bin/env python3
"""Guard C6 (Addendum A1 Rev 1): scan every tracked text file for SIN/ITN candidates with the reference detector
(origin 'native'). Prints file:line:rule for each hit, never the value. Exit 1 on any hit.
Binary files (NUL byte) and files larger than 5 MiB are skipped and counted. Usage: sin_repo_scan.py [--all-history]
--all-history additionally scans every blob reachable from any ref (slower; used before publishing history).
Detector v1.1 has no hex/UUID exemption for text (D-9011R-1). This scanner (guard C6 only) counts a hit as a machine token,
reported but not failing, when the whole token around it ([0-9A-Za-z-] run) is exactly a UUID or a hex string of at least 32
characters (optionally prefixed x or 0x, as bytea in dumps): commit hashes, SHA-256 manifests and UUIDs in committed evidence. The in-product guards (C1, C2) never
apply this rule."""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "apps", "executor"))
from bnx_exec import sin_detector as S  # noqa: E402

LIMIT = 5 * 1024 * 1024
HEXV = re.compile(S.SPEC["hex_exempt"]["value_regex"])
TOKEN = re.compile("[0-9A-Za-z-]")
LONGHEX = re.compile("^(?:x|0x)?[0-9A-Fa-f]{32,}$")
MACHINE = []
ALLOW = set()
_af = os.path.join(ROOT, "tools", "s4", "sin_repo_scan_allow.txt")
if os.path.exists(_af):
    for _l in open(_af, encoding="utf-8"):
        _p = _l.split("#", 1)[0].split()
        if len(_p) == 3:
            ALLOW.add((_p[0], int(_p[1]), _p[2]))
ALLOWED = []


def machine_token(text, a, b):
    while a > 0 and TOKEN.match(text[a - 1]):
        a -= 1
    while b < len(text) and TOKEN.match(text[b]):
        b += 1
    t = text[a:b]
    return HEXV.match(t) is not None or LONGHEX.match(t) is not None


def scan_bytes(name, data, out, blob=None):
    if b"\0" in data[:8192] or len(data) > LIMIT:
        return False
    text = data.decode("utf-8", errors="replace")
    for hit in S.scan(text):
        line = text.count("\n", 0, hit["start"]) + 1
        if machine_token(text, hit["start"], hit["end"]):
            MACHINE.append(f"{name}:{line}")
            continue
        if blob is not None and (blob, line, hit["rule"]) in ALLOW:
            ALLOWED.append(f"{blob}:{line}")
            continue
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
            scan_bytes("history:" + parts[1], data, out, blob=parts[0])
    for o in sorted(set(out)):
        print(o)
    print(f"sin_repo_scan: detector {S.VERSION}, {scanned} files scanned, {skipped} skipped (binary or > 5 MiB), {len(set(out))} hit(s), {len(set(MACHINE))} machine token(s) not counted, "
          f"{len(set(ALLOWED))} reviewed history entr(ies) allowed")
    return 1 if out else 0


if __name__ == "__main__":
    # exit codes: 0 clean, 1 hits, 2 the scan itself could not run (G0 run 2026-11-13: a git failure was indistinguishable from hits)
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError) as e:
        err = e.stderr.decode(errors="replace") if isinstance(getattr(e, "stderr", None), bytes) else (getattr(e, "stderr", None) or "")
        print(f"sin_repo_scan: ERROR, the scan did not run: {e}; {err.strip()[-500:]}", file=sys.stderr)
        sys.exit(2)
