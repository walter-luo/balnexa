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

_ZW = {chr(c) for c in SPEC["zero_width"]}
_WS = {chr(c) for c in SPEC["whitespace"]}
_APOS = {chr(c) for c in SPEC["apostrophes"]}
_DIGIT = {}
for _z in SPEC["nd_zeros"]:
    for _d in range(10):
        _DIGIT[chr(_z + _d)] = str(_d)
_SEQ = re.compile(SPEC["sequence_regex"])
_BN15 = re.compile(SPEC["bn15_suffix_regex"])
_UUID = re.compile(SPEC["uuid_regex"])
_HEX = re.compile("[0-9A-Fa-f]{%d,}" % SPEC["hex_token_min"])
_LABELS = [(re.compile(l["pattern"]), l["word_start"], l["word_end"], l["kind"]) for l in SPEC["labels"]]
_KEY_TOKENS = [tuple(t) for t in SPEC["key_tokens"]]
_CONF = SPEC["ocr"]["confusables"]
_ASCII_LETTER = re.compile("[A-Za-z]")   # label word boundary: an ASCII letter (after folding) breaks it; a digit does not


def normalize(s):
    """Return (n, idx): normalized text and, per character of n, the code-point index in s it came from."""
    out, idx = [], []
    for i, ch in enumerate(s):
        if ch in _ZW:
            continue
        for c in unicodedata.normalize("NFKC", ch):
            if c in _ZW:
                continue
            c = _DIGIT.get(c, c)
            if c in _WS:
                c = " "
            out.append(c)
            idx.append(i)
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


def sequences(n):
    """Nine-digit sequences: start where the previous character is not a digit (spec §3.1)."""
    res = []
    for i, c in enumerate(n):
        if "0" <= c <= "9" and (i == 0 or not ("0" <= n[i - 1] <= "9")):
            m = _SEQ.match(n, i)
            if m:
                res.append((i, m.end(), re.sub("[^0-9]", "", m.group(0))))
    return res


def _hex_spans(n):
    sp = [(m.start(), m.end()) for m in _HEX.finditer(n)]
    sp += [(m.start(), m.end()) for m in _UUID.finditer(n)]
    return sp


def _near(i, j, spans):
    wa, wb = SPEC["label_window_after"], SPEC["label_window_before"]
    for a, b, _k in spans:
        if b <= i and i - b <= wa:
            return True
        if j <= a and a - j <= wb:
            return True
        if a < j and i < b:      # overlap (a label glued to the digits)
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


_RUN = re.compile("[0-9](?:(?: +|[-‐-―])?[0-9])*")


def scan(text, origin="native", confidences=None, force_label=False):
    """Return a list of hits {rule, start, end}. force_label: the text sits under a labelled key (structured data)."""
    if origin not in SPEC["origins"]:
        raise ValueError("origin")
    if text is None:
        return []
    n, idx = normalize(text)
    mapped = None
    if origin == "ocr":
        n, mapped = _ocr_map(n)
    spans = label_spans(fold(n))
    hexes = _hex_spans(n) if origin != "ocr" else []
    hits = []
    for i, j, d in sequences(n):
        near = force_label or _near(i, j, spans)
        if origin == "ocr":
            rule = "R_OCR9"
        else:
            if not near and any(a <= i and j <= b for a, b in hexes):
                continue
            if near:
                rule = "R_LABEL"
            elif _bn15(n, i, j):
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
    hits.sort(key=lambda h: (h["start"], h["end"], h["rule"]))
    return hits


def candidate(text, origin="native"):
    return bool(scan(text, origin))


def key_is_label(key):
    k = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", key or "")
    toks = [t for t in re.split(r"[\s_\-.]+", fold(normalize(k)[0])) if t]
    for pat in _KEY_TOKENS:
        for s in range(len(toks) - len(pat) + 1):
            if tuple(toks[s:s + len(pat)]) == pat:
                return True
    return False


def scan_json(v, origin="native", path="$", labelled=False):
    """Hits in a JSON value: keys, strings and numbers. Values under a labelled key are judged with force_label."""
    out = []
    if isinstance(v, dict):
        for k, x in v.items():
            p = path + "." + k
            for h in scan(k, origin):
                out.append({**h, "path": p, "part": "key"})
            out += scan_json(x, origin, p, labelled or key_is_label(k))
    elif isinstance(v, list):
        for i, x in enumerate(v):
            out += scan_json(x, origin, "%s[%d]" % (path, i), labelled)
    elif isinstance(v, bool) or v is None:
        pass
    elif isinstance(v, (int, float, str)):
        s = v if isinstance(v, str) else json.dumps(v)
        for h in scan(s, origin, force_label=labelled):
            out.append({**h, "path": path, "part": "value"})
    return out


def mask_json(v, origin="native", labelled=False):
    """Copy of v with every key, string or number that holds a candidate replaced by MASK."""
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            nk = MASK if scan(k, origin) else k
            if nk in out:
                nk = "%s#%d" % (nk, len(out))
            out[nk] = mask_json(x, origin, labelled or key_is_label(k))
        return out
    if isinstance(v, list):
        return [mask_json(x, origin, labelled) for x in v]
    if isinstance(v, bool) or v is None:
        return v
    s = v if isinstance(v, str) else json.dumps(v)
    return MASK if scan(s, origin, force_label=labelled) else v
