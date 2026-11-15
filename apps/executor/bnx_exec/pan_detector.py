# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Payment-card number (PAN) candidate detector, reference implementation (Python). Rule D-PAN-1 (2026-11-14): a full card
number is never stored, logged or displayed; only the last 4 digits are kept.

The database implements the same algorithm (bnx.pan_scan, migration 9041); tests/py compares the two on a generated corpus.
Values are never logged or returned: a hit is (start, end) in code-point positions of the NFKC-normalized text.

Algorithm v1 (docs/s4/S4_PAN_Guard_2026-11-14.md):
1. Normalize with NFKC (full-width digits become ASCII; a no-break space becomes a space).
2. Groups are maximal runs of ASCII digits. A group touching an ASCII letter on either side, or a decimal point or comma that
   touches another digit ("0.3000…04", "1234.50"), is "attached" (hex digests, identifiers such as "a1234…", decimal numbers)
   and never counts.
3. A chain is a sequence of free groups joined by exactly one space or hyphen.
4. Candidates: a single free group of 13-19 digits, or consecutive groups of a chain with the printed layouts 4-4-4-4,
   4-4-4-4-3, 4-6-5 or 4-6-4.
5. A candidate is a PAN when it passes the Luhn check and its prefix and length match a card scheme in SCHEMES.
"""
import re
import unicodedata

VERSION = "1.0.0"
LAYOUTS = ((4, 4, 4, 4), (4, 4, 4, 4, 3), (4, 6, 5), (4, 6, 4))
# (prefix low, prefix high, prefix digits, allowed lengths); the ranges are inclusive
SCHEMES = (
    ("visa", 4, 4, 1, (13, 16, 19)),
    ("mastercard", 51, 55, 2, (16,)),
    ("mastercard", 2221, 2720, 4, (16,)),
    ("amex", 34, 34, 2, (15,)),
    ("amex", 37, 37, 2, (15,)),
    ("discover", 6011, 6011, 4, (16, 17, 18, 19)),
    ("discover", 644, 649, 3, (16, 17, 18, 19)),
    ("discover", 65, 65, 2, (16, 17, 18, 19)),
    ("jcb", 3528, 3589, 4, (16, 17, 18, 19)),
    ("unionpay", 62, 62, 2, (16, 17, 18, 19)),
    ("diners", 300, 305, 3, (14, 15, 16, 17, 18, 19)),
    ("diners", 36, 36, 2, (14, 15, 16, 17, 18, 19)),
    ("diners", 38, 39, 2, (14, 15, 16, 17, 18, 19)),
    ("debit", 50, 50, 2, (16, 17, 18, 19)),
    ("debit", 56, 58, 2, (16, 17, 18, 19)),
    ("debit", 63, 63, 2, (16, 17, 18, 19)),
    ("debit", 67, 67, 2, (16, 17, 18, 19)),
)
_GROUP = re.compile("[0-9]+")
_LETTER = re.compile("[A-Za-z]")
_DEC = ".,"


def normalize(s):
    return unicodedata.normalize("NFKC", s)


def luhn(d):
    t = 0
    for i, c in enumerate(reversed(d)):
        n = ord(c) - 48
        if i % 2 == 1:
            n *= 2
            if n > 9:
                n -= 9
        t += n
    return t % 10 == 0


def scheme(d):
    for name, lo, hi, k, lens in SCHEMES:
        if len(d) in lens and len(d) >= k and lo <= int(d[:k]) <= hi:
            return name
    return None


def is_pan(d):
    return 13 <= len(d) <= 19 and scheme(d) is not None and luhn(d)


def _groups(n):
    """free groups with their positions; attached groups break chains"""
    out = []
    for m in _GROUP.finditer(n):
        a, b = m.span()
        attached = ((a > 0 and _LETTER.match(n[a - 1])) or (b < len(n) and _LETTER.match(n[b]))
                    or (a > 1 and n[a - 1] in _DEC and n[a - 2].isascii() and n[a - 2].isdigit())
                    or (b + 1 < len(n) and n[b] in _DEC and n[b + 1].isascii() and n[b + 1].isdigit()))
        out.append((a, b, m.group(), bool(attached)))
    return out


def scan(text):
    """[(start, end)] of PAN candidates in normalize(text); empty when none"""
    n = normalize(text)
    g = _groups(n)
    hits = []
    for i, (a, b, d, att) in enumerate(g):
        if att:
            continue
        if 13 <= len(d) <= 19 and is_pan(d):
            hits.append((a, b))
        for lay in LAYOUTS:                                  # windows starting at group i with a printed layout
            if i + len(lay) > len(g):
                continue
            w = g[i:i + len(lay)]
            ok = all(not x[3] and len(x[2]) == L for x, L in zip(w, lay))
            ok = ok and all(n[w[k][1]:w[k + 1][0]] in (" ", "-") for k in range(len(w) - 1))
            if ok and is_pan("".join(x[2] for x in w)):
                hits.append((w[0][0], w[-1][1]))
    return sorted(set(hits))


def has(text):
    return bool(scan(text))


def mask(text):
    """normalize(text) with every digit of each candidate except the last 4 replaced by '*'; text unchanged when it has none"""
    hits = scan(text)
    if not hits:
        return text
    n = list(normalize(text))
    for a, b in hits:
        digits = [i for i in range(a, b) if n[i].isdigit()]
        for i in digits[:-4]:
            n[i] = "*"
    return "".join(n)


def json_has(v):
    if isinstance(v, dict):
        return any(has(k) or json_has(x) for k, x in v.items())
    if isinstance(v, list):
        return any(json_has(x) for x in v)
    if isinstance(v, bool) or v is None:
        return False
    if isinstance(v, (int, float)):
        return has(str(v))
    return has(str(v))


def mask_json(v):
    if isinstance(v, dict):
        return {mask(k): mask_json(x) for k, x in v.items()}
    if isinstance(v, list):
        return [mask_json(x) for x in v]
    if isinstance(v, str):
        return mask(v)
    if isinstance(v, (int, float)) and not isinstance(v, bool) and has(str(v)):
        return mask(str(v))
    return v
