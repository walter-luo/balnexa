#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Generate spec/sin-detector/sin_detector_v1.json, the single source of the SIN/ITN detector parameters shared by the
Executor (Python), the Worker (JS) and the database (SQL, embedded in migration 9011). Addendum A1 Rev 1 §3.

Usage: gen_sin_detector_spec.py [--check]   (--check: exit 1 if the committed file differs from what would be generated)
The Unicode decimal-digit table is pinned to the Unicode version of the Python that generated it (recorded in the spec)."""
import json, os, sys, unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "spec", "sin-detector", "sin_detector_v1.json")
APOS = {"’": "'", "‘": "'", "ʼ": "'"}


def fold_char(c):
    """One character in, one character out: base letter of NFD, lower case, apostrophe variants unified."""
    c = APOS.get(c, c)
    d = unicodedata.normalize("NFD", c)
    b = (d[0] if d else c).lower()
    return b[0]


def fold(s):
    return "".join(fold_char(c) for c in s)


def esc(s):
    out = []
    for c in s:
        if c == " ":
            out.append(" +")
        elif c in ".+*?()[]{}|^$\\/":
            out.append("\\" + c)
        else:
            out.append(c)
    return "".join(out)


LABELS = [
    # (language, label as written, kind)
    ("en", "SIN", "sin"), ("en", "S.I.N.", "sin"), ("en", "Social Insurance Number", "sin"), ("en", "Social Insurance No", "sin"),
    ("en", "Social Insurance #", "sin"), ("en", "Soc. Ins. No", "sin"),
    ("en", "Individual Tax Number", "itn"), ("en", "ITN", "itn"),
    ("fr", "NAS", "sin"), ("fr", "N.A.S.", "sin"), ("fr", "numéro d'assurance sociale", "sin"), ("fr", "no d'assurance sociale", "sin"),
    ("fr", "n° d'assurance sociale", "sin"),
    ("zh-Hans", "社会保险号", "sin"), ("zh-Hans", "社会保险号码", "sin"), ("zh-Hans", "社会保障号", "sin"),
    ("zh-Hant", "社會保險號", "sin"), ("zh-Hant", "社會保險號碼", "sin"),
]


def ranges(cps):
    out = []
    for c in sorted(cps):
        if out and c == out[-1][1] + 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return out


# group separators (v1.1, R-03): whitespace and dashes (with U+2212 minus) link any grouping (S links); dot, slash,
# underscore, middle dot, bullet and a bare comma link only the printed 3-3-3 form (L links)
DASH_CHARS = [0x2D] + list(range(0x2010, 0x2016)) + [0x2212]
OTHER_CHARS = [0x2E, 0x2F, 0x5F, 0xB7, 0x2022]


def sep_class(cps):
    # literal characters, hyphen-minus last; no backslash escapes (identical in Python re, JS and PostgreSQL ARE)
    body = "".join(chr(c) for c in cps if c != 0x2D)
    return "[" + body + ("-" if 0x2D in cps else "") + "]"


def build():
    zeros = [cp for cp in range(0x110000) if unicodedata.category(chr(cp)) == "Nd" and unicodedata.digit(chr(cp)) == 0]
    # v1.1 (R-02, R-41): every default-ignorable or combining character is removed before matching
    ign = set()
    for cp in range(0x110000):
        if unicodedata.category(chr(cp)) in ("Cf", "Mn", "Me"):
            ign.add(cp)
    ign |= {0x115F, 0x1160, 0x3164, 0xFFA0} | set(range(0xE0000, 0xE1000))
    # v1.1 (R-41): digit characters that are not Nd and that NFKC leaves unchanged (dingbat and double circled digits)
    dmap = []
    for cp in range(0x110000):
        ch = chr(cp)
        if unicodedata.category(ch) != "Nd" and unicodedata.normalize("NFKC", ch) == ch:
            d = unicodedata.digit(ch, None)
            if d is not None and 0 <= d <= 9:
                dmap.append([cp, d])
    labels = []
    for lang, lab, kind in LABELS:
        f = fold(lab)
        labels.append({"lang": lang, "label": lab, "kind": kind, "folded": f, "pattern": esc(f),
                       "word_start": f[0].isascii() and f[0].isalnum(), "word_end": f[-1].isascii() and f[-1].isalnum()})
    strict, other = sep_class(DASH_CHARS), sep_class(OTHER_CHARS)
    return {
        "spec": "bnx-sin-detector", "version": "1.1.0",
        "source": "Addendum A1 Rev 1 §3 (S4 V1.2); Owner decisions A1-OD-1 (2026-11-10) and DELEGATED_DECISION D-A1-1..4; "
                  "v1.1.0: 9011 review remediation D-9011R-1..6 (docs/s4/S4_9011R_Remediation_2026-11-11.md)",
        "unicode_version": unicodedata.unidata_version,
        "origins": ["native", "typed", "ocr"], "origins_sql_js": ["native", "typed"],
        "ignorable_ranges": ranges(ign),
        "digit_map": dmap,
        "whitespace": [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] + list(range(0x2000, 0x200B)) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000],
        "line_breaks": [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029],
        "hard_separators": [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029],
        "dash_separators": [0x2D] + list(range(0x2010, 0x2016)),
        "apostrophes": [0x2019, 0x2018, 0x02BC],
        "nd_zeros": zeros,
        "sequence": {"digits": 9, "strict_max_groups": 3, "strict_min_group": 2,
                     "link_strict_regex": "^(?: +| *" + strict + "{1,2} *)$",
                     "link_loose_regex": "^(?: *" + other + "{1,2} *|,)$",
                     "note": "groups are maximal ASCII digit runs after §3.2; consecutive groups are linked by a separator matching the "
                             "strict regex (S: spaces, dashes) or the loose regex (L: dot, slash, underscore, middle dot, bullet, bare comma); "
                             "a strict link whose original characters include a hard separator (tab, line break) counts as L; a window of linked groups holding exactly "
                             "nine digits is a sequence when: (a) all links are S, it has at most strict_max_groups groups and every "
                             "group has at least strict_min_group digits; or (b) it is three groups of three digits (S or L links); "
                             "near a label, under a labelled key and in origin ocr also (c) any grouping whose links are all S"},
        "uuid_regex": "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        "uuid_note": "a window of two or more groups lying inside a UUID-shaped substring is the token's own dash structure, not a "
                     "sequence; a single nine-digit group inside it remains a sequence (D-9011R-1)",
        "label_window_after": 64, "label_window_before": 32, "label_line_max": 256,
        "labels": labels,
        "key_split_chars": list(range(0x21, 0x30)) + list(range(0x3A, 0x41)) + list(range(0x5B, 0x61)) + list(range(0x7B, 0x7F)),
        "key_tokens": [["sin"], ["nas"], ["itn"], ["social", "insurance"], ["assurance", "sociale"], ["individual", "tax"],
                       ["s", "i", "n"], ["n", "a", "s"], ["i", "t", "n"]],
        "program_identifiers": ["RT", "RP", "RC", "RZ", "RR", "RG", "RD", "RE", "RM", "RN", "LT", "RU", "PT"],
        "bn15_suffix_regex": "[ -]?(?:RT|RP|RC|RZ|RR|RG|RD|RE|RM|RN|LT|RU|PT)[ -]?[0-9]{4}(?![0-9A-Za-z])",
        "itn_prefixes": ["08", "09"],
        "hex_exempt": {"key_tokens": ["id", "ids", "uid", "uuid", "uuids", "guid", "sha1", "sha256", "sha512", "md5", "hash",
                                      "hashes", "digest", "checksum", "etag", "key", "keys", "nonce", "token"],
                       "value_regex": "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|"
                                      "[0-9A-Fa-f]{32}|[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}|[0-9A-Fa-f]{128})$",
                       "note": "structured data only (JSON string values), never under a labelled key; free text has no exemption (D-9011R-1)"},
        "ocr": {"confusables": {"O": "0", "o": "0", "I": "1", "l": "1", "|": "1", "S": "5", "B": "8", "Z": "2", "G": "6"},
                "t_ocr": 0.9, "run_digits": [8, 10, 11, 12], "t_ocr_note": "set in 9011c from the corpus (D-9011c-3)"},
        "mask": "[MASKED:SIN]",
        "rules": {"R_LABEL": "nine-digit sequence near a SIN/ITN label or under a labelled key",
                  "R_MOD10": "nine-digit sequence passing Mod 10 (Luhn; assumption A-1 accepted as D-A1-2)",
                  "R_ITN": "nine-digit sequence beginning 08 or 09 (D-A1-1)",
                  "R_OCR9": "any nine-digit sequence in OCR text",
                  "R_OCR_RUN": "8-, 10-, 11- or 12-digit OCR run with a low-confidence or confusable glyph"},
    }


def main():
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read()
        # the Nd table depends on the generating Python's Unicode version; compare everything else exactly
        a, b = json.loads(cur), json.loads(text)
        for k in ("nd_zeros", "unicode_version", "ignorable_ranges", "digit_map"):
            a.pop(k); b.pop(k)
        sys.exit(0 if a == b else 1)
    open(OUT, "w", encoding="utf-8").write(text)
    print(OUT)


if __name__ == "__main__":
    main()
