#!/usr/bin/env python3
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


def build():
    zeros = [cp for cp in range(0x110000) if unicodedata.category(chr(cp)) == "Nd" and unicodedata.digit(chr(cp)) == 0]
    labels = []
    for lang, lab, kind in LABELS:
        f = fold(lab)
        labels.append({"lang": lang, "label": lab, "kind": kind, "folded": f, "pattern": esc(f),
                       "word_start": f[0].isascii() and f[0].isalnum(), "word_end": f[-1].isascii() and f[-1].isalnum()})
    return {
        "spec": "bnx-sin-detector", "version": "1.0.0",
        "source": "Addendum A1 Rev 1 §3 (S4 V1.2); Owner decisions A1-OD-1 (2026-11-10) and DELEGATED_DECISION D-A1-1..4",
        "unicode_version": unicodedata.unidata_version,
        "origins": ["native", "typed", "ocr"], "origins_sql_js": ["native", "typed"],
        "zero_width": [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD],
        "whitespace": [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] + list(range(0x2000, 0x200B)) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000],
        "dash_separators": [0x2D] + list(range(0x2010, 0x2016)),
        "apostrophes": [0x2019, 0x2018, 0x02BC],
        "nd_zeros": zeros,
        "sequence_regex": "[0-9]{3}(?: +|[-‐-―])?[0-9]{3}(?: +|[-‐-―])?[0-9]{3}(?![0-9])",
        "label_window_after": 64, "label_window_before": 32,
        "labels": labels,
        "key_tokens": [["sin"], ["nas"], ["itn"], ["social", "insurance"], ["assurance", "sociale"], ["individual", "tax"]],
        "program_identifiers": ["RT", "RP", "RC", "RZ", "RR", "RG", "RD", "RE", "RM", "RN", "LT", "RU", "PT"],
        "bn15_suffix_regex": "[ -]?(?:RT|RP|RC|RZ|RR|RG|RD|RE|RM|RN|LT|RU|PT)[ -]?[0-9]{4}(?![0-9A-Za-z])",
        "itn_prefixes": ["08", "09"],
        "hex_token_min": 32,
        "uuid_regex": "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        "ocr": {"confusables": {"O": "0", "o": "0", "I": "1", "l": "1", "|": "1", "S": "5", "B": "8", "Z": "2", "G": "6"},
                "t_ocr": 0.9, "run_digits": [8, 10], "t_ocr_note": "provisional; D-A1-4 sets the final value in 9011c from the corpus"},
        "mask": "[MASKED:SIN]",
        "rules": {"R_LABEL": "nine-digit sequence near a SIN/ITN label or under a labelled key",
                  "R_MOD10": "nine-digit sequence passing Mod 10 (Luhn; assumption A-1 accepted as D-A1-2)",
                  "R_ITN": "nine-digit sequence beginning 08 or 09 (D-A1-1)",
                  "R_OCR9": "any nine-digit sequence in OCR text", "R_OCR_RUN": "8- or 10-digit OCR run with a low-confidence or confusable glyph"},
    }


def main():
    text = json.dumps(build(), ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read()
        # the Nd table depends on the generating Python's Unicode version; compare everything else exactly
        a, b = json.loads(cur), json.loads(text)
        for k in ("nd_zeros", "unicode_version"):
            a.pop(k); b.pop(k)
        sys.exit(0 if a == b else 1)
    open(OUT, "w", encoding="utf-8").write(text)
    print(OUT)


if __name__ == "__main__":
    main()
