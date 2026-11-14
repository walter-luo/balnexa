# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""
R28 intra-household loan reference engine (design oracle checker).
Exact decimal arithmetic; rounding only at declared rounding events.
Usage: python -I r28_reference.py <fixtures.json>
"""
import json, sys
from decimal import Decimal, getcontext, ROUND_HALF_UP, ROUND_HALF_EVEN
from datetime import date

getcontext().prec = 60

CURRENCY_MINOR_UNITS = {"CAD": 2, "CNY": 2, "USD": 2, "HKD": 2, "EUR": 2, "GBP": 2, "JPY": 0}
SUPPORTED_DAY_COUNTS = {"ACT/365F", "ACT/360", "30/360-BB", "30E/360"}
SUPPORTED_WATERFALLS = {"interest_then_principal"}
SUPPORTED_PERIOD_RULES = {"start_inclusive_end_exclusive"}
ROUNDING_MODES = {"HALF_UP": ROUND_HALF_UP, "HALF_EVEN": ROUND_HALF_EVEN}


class Refusal(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def d(s):
    return date.fromisoformat(s)


def day_count_fraction(conv, start, end):
    """Fraction of a year between start (inclusive) and end (exclusive)."""
    if conv == "ACT/365F":
        return Decimal((end - start).days) / Decimal(365)
    if conv == "ACT/360":
        return Decimal((end - start).days) / Decimal(360)
    y1, m1, d1 = start.year, start.month, start.day
    y2, m2, d2 = end.year, end.month, end.day
    if conv == "30/360-BB":  # ISDA 2006 "30/360" (Bond Basis)
        if d1 == 31:
            d1 = 30
        if d2 == 31 and d1 >= 30:
            d2 = 30
    elif conv == "30E/360":  # Eurobond basis
        d1 = min(d1, 30)
        d2 = min(d2, 30)
    else:
        raise Refusal("TERMS_UNVERIFIED:day_count_unknown")
    days = 360 * (y2 - y1) + 30 * (m2 - m1) + (d2 - d1)
    return Decimal(days) / Decimal(360)


def quantize(amount, minor_units, mode):
    q = Decimal(1).scaleb(-minor_units)
    return amount.quantize(q, rounding=mode)


def evaluate(contract):
    # --- V1 structural rejections (REJECT:*) ---
    cur = contract.get("currency")
    if cur not in CURRENCY_MINOR_UNITS:
        raise Refusal("REJECT:UNKNOWN_CURRENCY")
    mu = CURRENCY_MINOR_UNITS[cur]
    start = d(contract["start"])
    as_of = d(contract["as_of"])
    if as_of < start:
        raise Refusal("REJECT:AS_OF_BEFORE_START")
    # --- V2 term completeness (TERMS_UNVERIFIED:*) ---
    conv = contract.get("day_count")
    if conv is None:
        raise Refusal("TERMS_UNVERIFIED:day_count")
    if conv not in SUPPORTED_DAY_COUNTS:
        raise Refusal("TERMS_UNVERIFIED:day_count_unknown")
    if contract.get("period_rule") not in SUPPORTED_PERIOD_RULES:
        raise Refusal("TERMS_UNVERIFIED:period_rule")
    rates = contract.get("rates") or []
    if not rates:
        raise Refusal("TERMS_UNVERIFIED:rates")
    rounding = contract.get("rounding")
    if not rounding or rounding.get("mode") not in ROUNDING_MODES or rounding.get("event") != "payment_and_as_of":
        raise Refusal("TERMS_UNVERIFIED:rounding")
    rmode = ROUNDING_MODES[rounding["mode"]]
    waterfall = contract.get("waterfall")
    if waterfall is None:
        raise Refusal("TERMS_UNVERIFIED:waterfall")
    if waterfall not in SUPPORTED_WATERFALLS:
        raise Refusal("TERMS_UNVERIFIED:waterfall_unknown")
    model = contract.get("interest_model")
    if model not in {"simple", "compound"}:
        raise Refusal("TERMS_UNVERIFIED:interest_model")
    # --- V3 rate schedule validity ---
    segs = sorted(((d(r["from"]), Decimal(r["annual_rate"])) for r in rates), key=lambda t: t[0])
    for _, rate in segs:
        if rate < 0:
            raise Refusal("REJECT:NEGATIVE_RATE")
    froms = [f for f, _ in segs]
    if len(set(froms)) != len(froms):
        raise Refusal("REJECT:OVERLAPPING_RATE_SEGMENTS")
    if froms[0] > start:
        raise Refusal("TERMS_UNVERIFIED:no_rate_at_start")
    if model == "compound":
        comp = contract.get("compounding")
        if not comp or not comp.get("period_ends") or not comp.get("periods_per_year"):
            raise Refusal("TERMS_UNVERIFIED:compounding")
        if len(segs) > 1:
            raise Refusal("TERMS_UNVERIFIED:compound_with_rate_changes")
    # --- V4 payments validity ---
    payments = []
    for p in contract.get("payments") or []:
        if p.get("currency", cur) != cur:
            raise Refusal("REJECT:PAYMENT_CURRENCY_MISMATCH")
        payments.append((d(p["date"]), Decimal(p["amount"])))
    payments.sort(key=lambda t: t[0])

    principal = Decimal(contract["principal"])

    def rate_at(day):
        r = None
        for f, rate in segs:
            if f <= day:
                r = rate
        return r

    def simple_accrual(balance, a, b):
        """Exact (unrounded) simple interest on `balance` from a (incl.) to b (excl.) across rate segments."""
        total = Decimal(0)
        cur_day = a
        boundaries = [f for f, _ in segs if a < f < b]
        for bnd in boundaries + [b]:
            if bnd > cur_day:
                total += balance * rate_at(cur_day) * day_count_fraction(conv, cur_day, bnd)
            cur_day = bnd
        return total

    def compound_accrual(balance, a, b):
        """Nominal rate / periods_per_year per contracted period; stub by day count on the compounded balance."""
        comp = contract["compounding"]
        ppy = Decimal(comp["periods_per_year"])
        rate = segs[0][1]
        per = rate / ppy
        bal = balance
        cur_day = a
        for pe in sorted(d(x) for x in comp["period_ends"]):
            if pe <= a:
                continue
            if pe > b:
                break
            bal = bal * (1 + per)
            cur_day = pe
        if b > cur_day:  # stub
            bal += bal * rate * day_count_fraction(conv, cur_day, b)
        return bal - balance

    accrual = simple_accrual if model == "simple" else compound_accrual

    # --- event loop: payments then as_of, rounding at each event ---
    principal_out = principal
    interest_carry = Decimal(0)  # rounded interest accrued and unpaid
    interest_paid = Decimal(0)
    principal_paid = Decimal(0)
    accrued_total = Decimal(0)
    last_event = start
    for pdate, pamt in payments:
        if pdate > as_of:
            break
        if pdate < start:
            raise Refusal("REJECT:PAYMENT_BEFORE_START")
        acc = quantize(accrual(principal_out, last_event, pdate), mu, rmode)
        accrued_total += acc
        interest_carry += acc
        # waterfall interest_then_principal
        if pamt > interest_carry + principal_out:
            raise Refusal("REJECT:OVERPAYMENT")
        pay_i = min(pamt, interest_carry)
        interest_carry -= pay_i
        interest_paid += pay_i
        pay_p = pamt - pay_i
        principal_out -= pay_p
        principal_paid += pay_p
        last_event = pdate
    acc = quantize(accrual(principal_out, last_event, as_of), mu, rmode)
    accrued_total += acc
    interest_carry += acc

    fmt = lambda x: str(quantize(x, mu, rmode))
    result = {
        "accrued_interest_total": fmt(accrued_total),
        "accrued_interest": fmt(accrued_total),
        "principal_outstanding": fmt(principal_out),
        "interest_outstanding": fmt(interest_carry),
        "outstanding_total": fmt(principal_out + interest_carry),
        "interest_paid": fmt(interest_paid),
        "principal_paid": fmt(principal_paid),
    }
    due = contract.get("due_date")
    if due is None:
        result["overdue"] = None
        result["days_past_due"] = None
    else:
        due_d = d(due)
        outstanding = principal_out + interest_carry
        result["overdue"] = bool(as_of > due_d and outstanding > 0)
        result["days_past_due"] = (as_of - due_d).days if result["overdue"] else 0
    return result


def main(path):
    with open(path, encoding="utf-8") as f:
        fx = json.load(f)
    passed = failed = 0
    for item in fx["fixtures"]:
        exp = item["expected"]
        try:
            res = evaluate(item["contract"])
            if "refusal" in exp:
                failed += 1
                print(f"FAIL {item['id']}: expected refusal {exp['refusal']} got result {res}")
                continue
            bad = {k: (exp[k], res.get(k)) for k in exp if res.get(k) != exp[k]}
            if bad:
                failed += 1
                print(f"FAIL {item['id']}: mismatches {bad}")
            else:
                passed += 1
                print(f"PASS {item['id']}: {{{', '.join(f'{k}={res[k]}' for k in exp)}}}")
        except Refusal as r:
            if exp.get("refusal") == r.code:
                passed += 1
                print(f"PASS {item['id']}: refusal {r.code}")
            else:
                failed += 1
                print(f"FAIL {item['id']}: expected {exp} got refusal {r.code}")
    print(f"\n{passed} passed, {failed} failed, {passed+failed} total")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
