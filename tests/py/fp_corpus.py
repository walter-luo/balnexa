# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""FP-SIN-01 benign corpus (Addendum A1 Rev 1 §6, §11): synthetic texts of the kinds a household's documents and postings hold,
none of which contains a SIN or an ITN by construction intent. Every item is generated from a seed; nothing here is real
data. The measurement is the share of items the detector flags (a false positive by construction). Random nine-digit
references are included on purpose: about one in ten passes Mod 10 and about one in fifty begins 08/09, which is the
accepted cost of A1-OD-1; the measurement reports the rate per category so the cost is visible.

Usage (measurement, not pass/fail): python3 tests/py/fp_corpus.py [--n N]"""
import json, random, uuid, hashlib

CATS = ["amount", "date_time", "phone", "postal", "masked_card", "invoice_ref", "bank_line_csv", "hash_uuid_prose",
        "address", "quantity_list", "reference_9", "reference_other", "transit_institution", "timestamp_log"]


def _amount(r):
    v = r.choice([r.randint(1, 999), r.randint(1000, 99999), r.randint(100000, 9999999)])
    c = r.randint(0, 99)
    s = f"{v:,}.{c:02d}"
    return r.choice([f"Total ${s}", f"Payment of {s} CAD", f"Balance: {s}", f"¥{s}", f"Withdrawal -{s}"])


def _date_time(r):
    y, m, d, hh, mm = r.randint(2015, 2026), r.randint(1, 12), r.randint(1, 28), r.randint(0, 23), r.randint(0, 59)
    return r.choice([f"{y}-{m:02d}-{d:02d} {hh:02d}:{mm:02d}", f"{m:02d}/{d:02d}/{y} {hh}:{mm:02d}", f"{d:02d}.{m:02d}.{y}",
                     f"Statement period {y}-{m:02d}-01 to {y}-{m:02d}-{d:02d}", f"{y}年{m}月{d}日 {hh}:{mm:02d}"])


def _phone(r):
    a, b, c = r.randint(200, 999), r.randint(200, 999), r.randint(0, 9999)
    return r.choice([f"Call 1-800-{b}-{c:04d}", f"Tel: ({a}) {b}-{c:04d}", f"+1 {a} {b} {c:04d}", f"{a}.{b}.{c:04d}"])


def _postal(r):
    L = "ABCEGHJKLMNPRSTVXY"
    return f"{r.randint(1, 9999)} Main St, Toronto ON {r.choice(L)}{r.randint(0, 9)}{r.choice(L)} {r.randint(0, 9)}{r.choice(L)}{r.randint(0, 9)}"


def _masked(r):
    return r.choice([f"Card ending {r.randint(0, 9999):04d}", f"**** **** **** {r.randint(0, 9999):04d}",
                     f"Account xxxx-xxx{r.randint(0, 9999):04d}"])


def _invoice(r):
    return r.choice([f"Invoice INV-{r.randint(10000, 99999)}", f"Order #{r.randint(100000, 9999999)}",
                     f"Confirmation {r.randint(1000, 9999)}-{r.randint(1000, 9999)}", f"PO {r.randint(1, 99999):05d}"])


def _csv(r):
    return ",".join([f"{r.randint(2020, 2026)}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}", "POS PURCHASE",
                     f"{r.randint(1, 500)}.{r.randint(0, 99):02d}", "", f"{r.randint(1000, 20000)}.{r.randint(0, 99):02d}"])


def _hash_uuid(r):
    u = uuid.UUID(int=r.getrandbits(128), version=4)
    h = hashlib.sha256(str(r.random()).encode()).hexdigest()
    return r.choice([f"evidence {u} attached", f"sha256 {h}", f"see document {u}", f"etag {h[:32]}"])


def _address(r):
    return f"Unit {r.randint(1, 2500)}, {r.randint(1, 999)} Queen St W, Toronto"


def _qty(r):
    return " ".join(str(r.randint(1, 99)) for _ in range(r.randint(3, 8)))


def _ref9(r):
    return r.choice(["Ref ", "Trace no. ", "Txn ", "Cheque ", ""]) + f"{r.randint(0, 999999999):09d}"


def _refother(r):
    n = r.choice([6, 7, 8, 10, 11, 12, 16])
    return "Reference " + "".join(str(r.randint(0, 9)) for _ in range(n))


def _transit(r):
    return f"Transit {r.randint(0, 99999):05d} Institution {r.randint(1, 999):03d} Account {r.randint(0, 9999999):07d}"


def _log(r):
    return f"[{r.randint(1600000000, 1800000000)}] job {r.randint(1, 9999)} done in {r.randint(1, 999)} ms"


GEN = dict(zip(CATS, [_amount, _date_time, _phone, _postal, _masked, _invoice, _csv, _hash_uuid, _address, _qty, _ref9,
                      _refother, _transit, _log]))


def corpus(n_per_cat=500, seed=20261111):
    r = random.Random(seed)
    return [(cat, GEN[cat](r)) for cat in CATS for _ in range(n_per_cat)]


def measure(scan, n_per_cat=500):
    rows = {c: [0, 0] for c in CATS}
    for cat, text in corpus(n_per_cat):
        rows[cat][1] += 1
        if scan(text):
            rows[cat][0] += 1
    tot = sum(v[0] for v in rows.values()), sum(v[1] for v in rows.values())
    excl = sum(v[0] for c, v in rows.items() if c != "reference_9"), sum(v[1] for c, v in rows.items() if c != "reference_9")
    return {"per_category": {c: {"flagged": a, "items": b, "rate": round(a / b, 4)} for c, (a, b) in rows.items()},
            "overall": {"flagged": tot[0], "items": tot[1], "rate": round(tot[0] / tot[1], 4)},
            "overall_without_reference_9": {"flagged": excl[0], "items": excl[1], "rate": round(excl[0] / excl[1], 4)}}


if __name__ == "__main__":
    import os, sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "apps", "executor"))
    from bnx_exec import sin_detector as S
    print(json.dumps(measure(lambda t: S.scan(t)), indent=1))
