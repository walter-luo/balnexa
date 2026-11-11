"""Synthetic SIN/ITN detector corpus (guard C1/C6; Addendum A1 Rev 1 §11).

tests/fixtures/s4/sin_corpus_v1.json holds templates only. The nine-digit values are generated here, deterministically, at
test time, so the repository never contains a SIN-shaped literal (the CI repository scan, guard C6, would otherwise flag the
corpus itself). Generated values are synthetic: built from a seed, never taken from a person. Tests never write a generated
value to evidence; they record case ids and rule codes only.

Placeholder grammar inside templates: {name:arg:...}
  {v:<kind>:<seed>:<group>}   nine-digit value; kind luhn | nonluhn | itn_luhn | itn_nonluhn; group see GROUPS
  {hex33:<kind>:<seed>}       the value inside a 33-character hex token
  {hex20:<kind>:<seed>}       the value inside a 20-character hex token (too short for the exemption)
  {uuid:<kind>:<seed>}        the value inside a UUID-shaped token
  {straddle:<kind>:<seed>}    six digits ending a 32-character hex token, a tab, three more digits (a dump column break)
  {ocrconf:<kind>:<seed>}     the value with one digit written as its confusable letter (OCR cases)
  {run:<n>:<seed>:<variant>}  an n-digit run; variant plain | conf (one confusable letter)
  {pad:<n>}                   n filler letters
A JSON case's template is a JSON value; a string equal to {"$num": "<placeholder>"} becomes a JSON number.
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(os.path.dirname(HERE), "fixtures", "s4", "sin_corpus_v1.json")
CONF_OF = {"0": "O", "1": "l", "5": "S", "8": "B", "2": "Z", "6": "G"}


def _luhn_ok(d):
    t = 0
    for k, c in enumerate(reversed(d)):
        v = int(c)
        if k % 2:
            v *= 2
            v = v - 9 if v > 9 else v
        t += v
    return t % 10 == 0


def _body(seed, n):
    return f"{(seed * 2654435761 + 12345) % 10 ** n:0{n}d}"


def value(kind, seed):
    if kind in ("luhn", "nonluhn"):
        head = "4" + _body(seed, 7)
    elif kind in ("itn_luhn", "itn_nonluhn"):
        head = ("08" if seed % 2 == 0 else "09") + _body(seed, 6)
    else:
        raise ValueError(kind)
    good = next(str(c) for c in range(10) if _luhn_ok(head + str(c)))
    return head + (good if kind.endswith("luhn") and not kind.endswith("nonluhn") else str((int(good) + 1) % 10))


def _digits(v, base):
    return "".join(chr(base + int(c)) for c in v)


GROUPS = {
    "none": lambda v: v,
    "space": lambda v: f"{v[:3]} {v[3:6]} {v[6:]}",
    "dash": lambda v: f"{v[:3]}-{v[3:6]}-{v[6:]}",
    "endash": lambda v: f"{v[:3]}–{v[3:6]}–{v[6:]}",
    "nbsp": lambda v: f"{v[:3]} {v[3:6]} {v[6:]}",
    "thin": lambda v: f"{v[:3]} {v[3:6]} {v[6:]}",
    "nnbsp": lambda v: f"{v[:3]} {v[3:6]} {v[6:]}",
    "ideo": lambda v: f"{v[:3]}　{v[3:6]}　{v[6:]}",
    "dspace": lambda v: f"{v[:3]}  {v[3:6]}  {v[6:]}",
    "tab": lambda v: f"{v[:3]}\t{v[3:6]}\t{v[6:]}",
    "zwsp": lambda v: f"{v[:3]}​{v[3:6]}​{v[6:]}",
    "shy": lambda v: f"{v[:4]}­{v[4:]}",
    "fullwidth": lambda v: _digits(v, 0xFF10),
    "arabic": lambda v: _digits(v, 0x0660),
    "devanagari": lambda v: _digits(v, 0x0966),
}


def _ocrconf(kind, seed):
    s = seed
    while True:
        v = value(kind, s)
        for k in range(1, 9):
            if v[k] in CONF_OF:
                return v[:k] + CONF_OF[v[k]] + v[k + 1:]
        s += 1


def _run(n, seed, variant):
    d = "4" + _body(seed, n - 1)
    if variant == "conf":
        d = d[:3] + "O" + d[4:]
    return d


def expand(tpl):
    def rep(m):
        a = m.group(1).split(":")
        name = a[0]
        if name == "v":
            return GROUPS[a[3]](value(a[1], int(a[2])))
        if name == "hex33":
            return "a" * 12 + value(a[1], int(a[2])) + "f" * 12
        if name == "hex20":
            return "a" * 5 + value(a[1], int(a[2])) + "f" * 6
        if name == "straddle":
            v = value(a[1], int(a[2]))
            return "a" * 26 + v[:6] + "\t" + v[6:]
        if name == "uuid":
            return "abcdef12-abcd-4bcd-8bcd-" + value(a[1], int(a[2])) + "abc"
        if name == "ocrconf":
            return _ocrconf(a[1], int(a[2]))
        if name == "run":
            return _run(int(a[1]), int(a[2]), a[3])
        if name == "pad":
            return "x" * int(a[1])
        raise ValueError(name)
    return re.sub(r"\{([a-z0-9_]+(?::[a-z0-9_]+)*)\}", rep, tpl)


def expand_json(v):
    if isinstance(v, dict):
        if set(v) == {"$num"}:
            return int(expand(v["$num"]))
        return {expand(k): expand_json(x) for k, x in v.items()}
    if isinstance(v, list):
        return [expand_json(x) for x in v]
    if isinstance(v, str):
        return expand(v)
    return v


def cases():
    """Concrete cases: {id, test, kind ('text'|'json'), origin, input, expect, confidences?}."""
    c = json.load(open(CORPUS, encoding="utf-8"))
    out = []
    for x in c["cases"]:
        y = {"id": x["id"], "test": x["test"], "kind": x.get("kind", "text"), "origin": x.get("origin", "native"), "expect": x["expect"]}
        y["input"] = expand_json(x["template"]) if y["kind"] == "json" else expand(x["template"])
        if "low_conf_at" in x:
            y["confidences"] = [0.2 if k in x["low_conf_at"] else 0.99 for k in range(len(y["input"]))]
        out.append(y)
    return out
