# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""SIN/ITN candidate detector, reference implementation (Executor, Python).

Specification: Addendum A1 Rev 1 §3 and spec/sin-detector/sin_detector_v1.json. The Worker (apps/worker/src/sin_detector.js)
and the database (bnx.sin_scan in migration 9011) implement the same algorithm for origins 'native' and 'typed'; only this
module implements 'ocr', because only the Executor performs OCR. Values are never logged or returned: a hit is
{rule, start, end} in code-point positions of the ORIGINAL text.
"""
import json
import os
import re
import unicodedata

_SPEC_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))),
                          "spec", "sin-detector", "sin_detector_v1.json")
SPEC = json.load(open(_SPEC_PATH, encoding="utf-8"))
VERSION = SPEC["version"]
MASK = SPEC["mask"]

import bisect

_IGN_LO = [r[0] for r in SPEC["ignorable_ranges"]]
_IGN_HI = [r[1] for r in SPEC["ignorable_ranges"]]
_WS = {chr(c) for c in SPEC["whitespace"]}
_LB = {chr(c) for c in SPEC["line_breaks"]}
_HARD = {chr(c) for c in SPEC["hard_separators"]}
_APOS = {chr(c) for c in SPEC["apostrophes"]}
_DIGIT = {}
for _z in SPEC["nd_zeros"]:
    for _d in range(10):
        _DIGIT[chr(_z + _d)] = str(_d)
for _cp, _d in SPEC["digit_map"]:
    _DIGIT[chr(_cp)] = str(_d)
_SQ = SPEC["sequence"]
_LINK_STRICT = re.compile(_SQ["link_strict_regex"])
_LINK_LOOSE = re.compile(_SQ["link_loose_regex"])
_BN15 = re.compile(SPEC["bn15_suffix_regex"])
_HEX_VALUE = re.compile(SPEC["hex_exempt"]["value_regex"])
_UUID = re.compile(SPEC["uuid_regex"])
_HEX_KEYS = set(SPEC["hex_exempt"]["key_tokens"])
_LABELS = [(re.compile(l["pattern"]), l["word_start"], l["word_end"], l["kind"]) for l in SPEC["labels"]]
_KEY_TOKENS = [tuple(t) for t in SPEC["key_tokens"]]
_KEY_SPLIT = {c: " " for c in SPEC["key_split_chars"]}
_CONF = SPEC["ocr"]["confusables"]
_ASCII_LETTER = re.compile("[A-Za-z]")   # label word boundary: an ASCII letter (after folding) breaks it; a digit does not


def ignorable(ch):
    cp = ord(ch)
    if cp < 0xAD:
        return False
    k = bisect.bisect_right(_IGN_LO, cp) - 1
    return k >= 0 and cp <= _IGN_HI[k]


def normalize(s, lines=False):
    """Return (n, idx): normalized text and, per character of n, the code-point index in s it came from.
    With lines=True also return brk: per character of n, whether it came from a line break."""
    out, idx, brk = [], [], []
    for i, ch in enumerate(s):
        if ignorable(ch):
            continue
        for c in unicodedata.normalize("NFKC", ch):
            if ignorable(c):
                continue
            c = _DIGIT.get(c, c)
            b = c in _LB
            if c in _WS:
                c = " "
            out.append(c)
            idx.append(i)
            brk.append(b)
    if lines:
        return "".join(out), idx, brk
    return "".join(out), idx


def _fold_char(c):
    if c in _APOS:
        return "'"
    d = unicodedata.normalize("NFD", c)
    b = (d[0] if d else c).lower()
    return b[0]


def fold(n):
    return "".join(_fold_char(c) for c in n)


def luhn(d):
    t = 0
    for k, c in enumerate(reversed(d)):
        v = int(c)
        if k % 2:
            v *= 2
            if v > 9:
                v -= 9
        t += v
    return t % 10 == 0


def label_spans(f):
    spans = []
    for rx, ws, we, kind in _LABELS:
        for m in rx.finditer(f):
            a, b = m.start(), m.end()
            if ws and a > 0 and _ASCII_LETTER.match(f[a - 1]):
                continue
            if we and b < len(f) and _ASCII_LETTER.match(f[b]):
                continue
            spans.append((a, b, kind))
    return sorted(set(spans))


def _groups(n):
    return [(m.start(), m.end()) for m in re.finditer("[0-9]+", n)]


def windows(n, text=None, idx=None):
    """Candidate windows (i, j, digits, ok_free, ok_near, ngroups): linked digit groups holding exactly nine digits (v1.1).
    text/idx: the original text and the index map; a strict link holding a hard separator (tab, line break) counts as L."""
    g = _groups(n)
    link = []
    for k in range(len(g) - 1):
        sep = n[g[k][1]:g[k + 1][0]]
        if _LINK_STRICT.match(sep):
            hard = text is not None and any(text[idx[q]] in _HARD for q in range(g[k][1], g[k + 1][0]))
            link.append("L" if hard else "S")
        else:
            link.append("L" if _LINK_LOOSE.match(sep) else None)
    res = []
    for a in range(len(g)):
        tot, alls, mn, mx = 0, True, 99, 0
        for b in range(a, len(g)):
            if b > a:
                if link[b - 1] is None:
                    break
                alls = alls and link[b - 1] == "S"
            ln = g[b][1] - g[b][0]
            tot += ln
            mn, mx = min(mn, ln), max(mx, ln)
            if tot > _SQ["digits"]:
                break
            if tot == _SQ["digits"]:
                ng = b - a + 1
                d = "".join(n[x:y] for x, y in g[a:b + 1])
                f333 = ng == 3 and mn == 3 and mx == 3
                ok_free = (alls and ng <= _SQ["strict_max_groups"] and mn >= _SQ["strict_min_group"]) or f333
                res.append((g[a][0], g[b][1], d, ok_free, alls or f333, ng))
    return res


def sequences(n):
    """Nine-digit sequences of the unlabelled rule (kept for callers of v1.0): (i, j, digits)."""
    return [(i, j, d) for i, j, d, ok, _n, _g in windows(n) if ok]


def _near(i, j, spans, n=None, brk=None):
    wa, wb, lm = SPEC["label_window_after"], SPEC["label_window_before"], SPEC["label_line_max"]
    for a, b, _k in spans:
        if b <= i and i - b <= wa:
            return True
        if j <= a and a - j <= wb:
            return True
        if a < j and i < b:      # overlap (a label glued to the digits)
            return True
        if brk is None:
            continue
        if b <= i and i - b <= lm:
            # same line, or the next non-empty line: only spaces between the first and the last line break in [b, i)
            br = [k for k in range(b, i) if brk[k]]
            if not br or n[br[0]:br[-1] + 1].strip(" ") == "":
                return True
        if j <= a and a - j <= lm and not any(brk[k] for k in range(j, a)):
            return True
    return False


def _bn15(n, i, j):
    if j - i != 9:
        return False
    if i > 0 and re.match("[A-Za-z]", n[i - 1]):
        return False
    return _BN15.match(n, j) is not None


def _ocr_map(n):
    chars = list(n)
    mapped = [False] * len(chars)
    for k, c in enumerate(chars):
        if c in _CONF:
            left = k > 0 and "0" <= n[k - 1] <= "9"
            right = k + 1 < len(n) and "0" <= n[k + 1] <= "9"
            if left or right:
                chars[k] = _CONF[c]
                mapped[k] = True
    return "".join(chars), mapped




_RUN = re.compile("[0-9](?:(?:" + _SQ["link_strict_regex"][4:-2] + "|" + _SQ["link_loose_regex"][4:-2] + ")?[0-9])*")


def scan(text, origin="native", confidences=None, force_label=False):
    """Return a list of hits {rule, start, end}. force_label: the text sits under a labelled key (structured data)."""
    if origin not in SPEC["origins"]:
        raise ValueError("origin")
    if text is None:
        return []
    n, idx, brk = normalize(text, lines=True)
    mapped = None
    if origin == "ocr":
        n, mapped = _ocr_map(n)
    if sum(1 for c in n if "0" <= c <= "9") < (min(SPEC["ocr"]["run_digits"]) if origin == "ocr" else _SQ["digits"]):
        return []
    spans = label_spans(fold(n))
    uu = [(m.start(), m.end()) for m in _UUID.finditer(n)]
    hits = []
    for i, j, d, ok, oknear, ng in windows(n, text, idx):
        if not oknear:
            continue
        if ng > 1 and any(a <= i and j <= b for a, b in uu):
            continue
        near = force_label or _near(i, j, spans, n, brk)
        if origin == "ocr":
            rule = "R_OCR9"
        else:
            if not (ok or near):
                continue
            if near:
                rule = "R_LABEL"
            elif ng == 1 and _bn15(n, i, j):
                continue
            elif luhn(d):
                rule = "R_MOD10"
            elif d[:2] in SPEC["itn_prefixes"]:
                rule = "R_ITN"
            else:
                continue
        hits.append({"rule": rule, "start": idx[i], "end": idx[j - 1] + 1})
    if origin == "ocr":
        seen = {(h["start"], h["end"]) for h in hits}
        t = SPEC["ocr"]["t_ocr"]
        for m in _RUN.finditer(n):
            i, j = m.start(), m.end()
            if i > 0 and "0" <= n[i - 1] <= "9":
                continue
            nd = sum(1 for c in m.group(0) if "0" <= c <= "9")
            if nd not in SPEC["ocr"]["run_digits"]:
                continue
            weak = any(mapped[k] for k in range(i, j))
            if confidences is not None:
                weak = weak or any(confidences[idx[k]] is not None and confidences[idx[k]] < t for k in range(i, j))
            if weak and (idx[i], idx[j - 1] + 1) not in seen:
                hits.append({"rule": "R_OCR_RUN", "start": idx[i], "end": idx[j - 1] + 1})
    out, seen = [], set()
    for h in sorted(hits, key=lambda h: (h["start"], h["end"], h["rule"])):
        k = (h["start"], h["end"], h["rule"])
        if k not in seen:
            seen.add(k); out.append(h)
    return out


def candidate(text, origin="native"):
    return bool(scan(text, origin))


def key_split(key, digits=True):
    """Key text split for the key rule (v1.1, R-04): camelCase and acronym boundaries, letter/digit boundaries (digits=True),
    ASCII punctuation as separators; returns the folded tokens."""
    k = key or ""
    k = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", k)
    k = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", k)
    if digits:
        k = re.sub(r"([A-Za-z])([0-9])", r"\1 \2", k)
        k = re.sub(r"([0-9])([A-Za-z])", r"\1 \2", k)
    k = fold(normalize(k)[0]).translate(_KEY_SPLIT)
    return [t for t in k.split(" ") if t]


def key_is_label(key):
    toks = key_split(key)
    for pat in _KEY_TOKENS:
        for s in range(len(toks) - len(pat) + 1):
            if tuple(toks[s:s + len(pat)]) == pat:
                return True
    return bool(label_spans(" ".join(toks)))


def key_is_hex(key):
    toks = key_split(key, digits=False)
    return bool(toks) and toks[-1] in _HEX_KEYS


def _hex_exempt(s, hexkey, labelled):
    return hexkey and not labelled and _HEX_VALUE.match(s) is not None


def scan_json(v, origin="native", path="$", labelled=False, hexkey=False):
    """Hits in a JSON value: keys, strings and numbers. Values under a labelled key are judged with force_label; a string
    that is exactly a UUID or a hex digest under an id/hash key is machine data (v1.1, D-9011R-1)."""
    out = []
    if isinstance(v, dict):
        for k, x in v.items():
            p = path + "." + k
            for h in scan(k, origin):
                out.append({**h, "path": p, "part": "key"})
            out += scan_json(x, origin, p, labelled or key_is_label(k), key_is_hex(k))
    elif isinstance(v, list):
        for i, x in enumerate(v):
            out += scan_json(x, origin, "%s[%d]" % (path, i), labelled, hexkey)
    elif isinstance(v, bool) or v is None:
        pass
    elif isinstance(v, (int, float, str)):
        s = v if isinstance(v, str) else json.dumps(v)
        if isinstance(v, str) and _hex_exempt(s, hexkey, labelled):
            return out
        for h in scan(s, origin, force_label=labelled):
            out.append({**h, "path": path, "part": "value"})
    return out


def mask_json(v, origin="native", labelled=False, hexkey=False):
    """Copy of v with every key, string or number that holds a candidate replaced by MASK."""
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            nk = MASK if scan(k, origin) else k
            if nk in out:
                nk = "%s#%d" % (nk, len(out))
            out[nk] = mask_json(x, origin, labelled or key_is_label(k), key_is_hex(k))
        return out
    if isinstance(v, list):
        return [mask_json(x, origin, labelled, hexkey) for x in v]
    if isinstance(v, bool) or v is None:
        return v
    s = v if isinstance(v, str) else json.dumps(v)
    if isinstance(v, str) and _hex_exempt(s, hexkey, labelled):
        return v
    return MASK if scan(s, origin, force_label=labelled) else v


def scrub(text, origin="native"):
    """Guard C3: the text with every candidate replaced by MASK (for log writers)."""
    out, k = [], 0
    for h in scan(text, origin):
        if h["start"] < k:
            continue
        out.append(text[k:h["start"]]); out.append(MASK); k = h["end"]
    out.append(text[k:])
    return "".join(out)
