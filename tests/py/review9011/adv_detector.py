# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Reviewer adversarial cases for the SIN/ITN detector (generators only; every value is built at run time from
tests/py/sin_corpus.value(kind, seed). No literal nine-digit value appears in this file. Case ids are R-A-nn.)"""
import os, random, sys
sys.path.insert(0, os.environ.get("BNX_REPO") and os.path.join(os.environ["BNX_REPO"], "tests", "py") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sin_corpus import value

def digits_in(v, zero):            # v rendered with a Unicode Nd block starting at 'zero'
    return "".join(chr(zero + int(c)) for c in v)

def grp(v, sep): return sep.join((v[:3], v[3:6], v[6:]))

def build():
    L, N, I = value("luhn", 101), value("nonluhn", 102), value("itn_nonluhn", 104)   # valid, Mod-10-invalid, ITN-shaped
    L2 = value("luhn", 103)
    c = []
    def add(i, text, origin="native", kind="text", note=""):
        c.append({"id": f"R-A-{i:02d}", "kind": kind, "origin": origin, "input": text, "note": note})
    # --- Unicode digits and compatibility characters
    add(1, "ref " + digits_in(L, 0x0E50), note="Thai digits")
    add(2, "ref " + digits_in(L, 0x1810), note="Mongolian digits")
    add(3, "ref " + digits_in(L, 0x0F20), note="Tibetan digits")
    add(4, "ref " + digits_in(L, 0x1D7CE), note="Mathematical bold digits (astral, Nd)")
    add(5, "ref " + "".join("⁰¹²³⁴⁵⁶⁷⁸⁹"[int(x)] for x in L), note="superscript digits (NFKC -> ASCII, category No)")
    add(6, "ref " + "".join("⓪①②③④⑤⑥⑦⑧⑨"[int(x)] for x in L), note="circled digits")
    add(7, "ref " + L[:4] + digits_in(L[4:7], 0xFF10) + L[7:], note="mixed ASCII/fullwidth")
    add(8, "ref " + grp(L, "−"), note="U+2212 minus sign as separator")
    add(9, "ref " + grp(L, "－"), note="fullwidth hyphen-minus")
    add(10, "ref " + grp(L, "‑"), note="non-breaking hyphen")
    # --- separators outside the spec
    for k, (sep, nm) in enumerate(((".", "dot"), ("/", "slash"), (",", "comma"), ("_", "underscore"), ("·", "middle dot"), (" - ", "space-dash-space"), ("\n", "newline"), ("•", "bullet")), 11):
        add(k, "ref " + grp(L, sep), note="separator " + nm)
    # --- irregular grouping
    add(19, "ref " + f"{L[:2]} {L[2:6]} {L[6:]}", note="2-4-3 grouping, unlabelled")
    add(20, "SIN: " + f"{L[:2]} {L[2:6]} {L[6:]}", note="2-4-3 grouping next to a SIN label")
    add(21, "SIN: " + f"{L[:4]} {L[4:]}", note="4-5 grouping next to a SIN label")
    add(22, "SIN: " + N[:3] + "a" + N[3:6] + "a" + N[6:], note="letters inside a labelled value")
    # --- zero-width / invisible characters (listed and unlisted)
    for k, cp in enumerate((0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD, 0x200E, 0x200F, 0x180E, 0x2061, 0x034F, 0xFE0F, 0x202A, 0x061C, 0x115F), 23):
        add(k, "ref " + L[:4] + chr(cp) + L[4:], note=f"U+{cp:04X} inside the value")
    # --- labels
    add(38, "SIN" + N, note="glued label before value")
    add(39, N + "SIN", note="glued label after value")
    add(40, "SIN" + " " * 63 + N, note="label, 63 spaces, value")
    add(41, "SIN" + " " * 64 + N, note="label, 64 spaces, value")
    add(42, "SIN" + " " * 65 + N, note="label, 65 spaces, value")
    add(43, N + " " * 31 + "SIN", note="value, 31 spaces, label after")
    add(44, N + " " * 32 + "SIN", note="value, 32 spaces, label after")
    add(45, N + " " * 33 + "SIN", note="value, 33 spaces, label after")
    add(46, "CASINO " + N, note="SIN inside a longer word")
    add(47, "S​I​N " + N, note="zero-width inside the label")
    add(48, "Ｓ Ｉ Ｎ: " + N, note="fullwidth label letters with spaces")
    add(49, "n° d’assurance sociale " + N, note="French label, right single quote")
    add(50, "社会保险号" + N, note="Chinese label glued")
    add(51, "社會保險號碼：" + N, note="Traditional label")
    add(52, "Social Insurance Number " + N, note="NBSP inside label")
    add(53, "SIN\n\n" + N, note="label, blank line, value")
    add(54, "s.i.n. " + N, note="dotted label lower case")
    # --- BN program accounts and ITN
    add(55, L + "RT0001", note="valid value + program account suffix (exempt by design)")
    add(56, L + "rt0001", note="lower-case suffix (not exempt)")
    add(57, L + " RT 0001", note="spaced suffix")
    add(58, L + "RT00012", note="five digits after RT")
    add(59, "SIN " + L + "RT0001", note="label + suffix (label precedence)")
    add(60, I + "RT0001", note="ITN-shaped + suffix")
    add(61, "XX" + L + "RT0001", note="letters before")
    # --- hex / UUID exemption
    add(62, "a" * 23 + L, note="23 hex letters then value (32-hex token)")
    add(63, "a" * 22 + L, note="22 hex letters then value (31-hex token)")
    add(64, L + "f" * 23, note="value then 23 hex letters")
    add(65, "SIN: " + "a" * 23 + L, note="label near, value inside 32-hex token")
    add(66, "SIN: " + L + "abc", note="short hex tail, label")
    add(67, "abcdef12-abcd-4bcd-8bcd-" + L + "abc", note="UUID-shaped, value in last group")
    add(68, "ABCDEF" * 6 + L, note="upper-case hex run")
    add(69, "a" * 23 + " " + L, note="space after the hex run")
    add(70, "Name: " + "a" * 23 + L + " end", note="padding in prose")
    # --- ITN / OCR (python only for OCR)
    add(71, grp(I, " "), note="ITN-shaped, grouped")
    add(72, grp(I, "-") + "RT0001", note="ITN-shaped grouped with suffix")
    add(73, grp(N, " "), origin="ocr", note="OCR: invalid value, grouped")
    add(74, f"{N[:2]} {N[2:6]} {N[6:]}", origin="ocr", note="OCR: 2-4-3 grouping")
    add(75, f"{N[:3]} {N[3:6]}\n{N[6:]}", origin="ocr", note="OCR: line break inside value")
    add(76, f"{N[:3]} {N[3:6]}. {N[6:]}", origin="ocr", note="OCR: noise dot inside value")
    add(77, N[:8], origin="ocr", note="OCR: 8 digits clean")
    add(78, N[:4] + "o" + N[5:], origin="ocr", note="OCR: lower-case o for a digit (9 chars)")
    add(79, N + "1", origin="ocr", note="OCR: 10 digits clean")
    add(80, N[:3] + "l" + N[4:8], origin="ocr", note="OCR: l glyph in 8-char run")
    add(81, N[:3] + "|" + N[4:8], origin="ocr", note="OCR: pipe in 8-char run")
    add(82, "SIN " + L + "RT0001", origin="ocr", note="OCR: program account")
    # --- JSON keys and values
    for k, key in enumerate(("sin", "SIN", "sinNumber", "SINValue", "SINNumber", "socialInsuranceNumber", "Social-Insurance", "ｓｉｎ", "nas_value", "NAS", "casino", "resin", "taxpayer.sin", "sin_", "s_i_n", "ssn", "sin1", "SIN#"), 83):
        add(k, {key: N}, kind="json", note="key " + key)
    n = 83 + 18
    add(n, {"a": [{"b": {"sin": [N]}}]}, kind="json", note="nested array under label key"); n += 1
    add(n, {"x": int(N)}, kind="json", note="number, unlabelled invalid"); n += 1
    add(n, {"x": int(L)}, kind="json", note="number, valid"); n += 1
    add(n, {"sin": int(N)}, kind="json", note="number under label key"); n += 1
    add(n, {"x": float(L) / 10.0}, kind="json", note="float with fraction"); n += 1
    add(n, {"x": -int(L)}, kind="json", note="negative number"); n += 1
    add(n, {"x": [int(L)]}, kind="json", note="number in array"); n += 1
    add(n, {"k" + L: 1}, kind="json", note="candidate inside a key"); n += 1
    return c

def fuzz(n=400, seed=7):
    """random concatenations of fragments; deterministic"""
    rnd = random.Random(seed)
    vals = [value(k, s) for k in ("luhn", "nonluhn", "itn_luhn", "itn_nonluhn") for s in range(200, 206)]
    seps = ["", " ", "-", "  ", "\t", "–", " ", "​", ".", "　"]
    labels = ["SIN", "NAS", "S.I.N.", "Social Insurance Number", "ITN", "社会保险号", "sin_", "Individual Tax Number", "BN"]
    pads = ["a" * 23, "f" * 25, "x" * 40, "0" * 3, "RT0001", " RT 0001", "abc", "\n", " | "]
    out = []
    for i in range(n):
        v = rnd.choice(vals); s1, s2 = rnd.choice(seps), rnd.choice(seps)
        body = v[:3] + s1 + v[3:6] + s2 + v[6:]
        if rnd.random() < 0.3: body = "".join(chr(0xFF10 + int(ch)) if ch.isdigit() and rnd.random() < 0.5 else ch for ch in body)
        text = ""
        if rnd.random() < 0.5: text += rnd.choice(labels) + rnd.choice([" ", ": ", "", "\n", " " * rnd.randint(1, 70)])
        if rnd.random() < 0.3: text += rnd.choice(pads)
        text += body
        if rnd.random() < 0.4: text += rnd.choice(pads)
        if rnd.random() < 0.2: text += " " + rnd.choice(labels)
        out.append({"id": f"R-F-{i:03d}", "kind": "text", "origin": rnd.choice(["native", "typed"]), "input": text, "note": "fuzz"})
    return out
