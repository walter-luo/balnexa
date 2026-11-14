"""R28 intra-household loan reference engine, V1.2 (CI oracle for bnx.r28_evaluate, migration 9012a).

Derived from the S2 design oracle `r28_reference_s2_v1_0.py` (BNX-S2-08a, SHA-256 ead5a9f8…22f18, kept unchanged next to
this file). Changes, each recorded in docs/s4/S4_9012_Implementation_Notes.md:

  1. Exact rational arithmetic (fractions.Fraction) instead of Decimal with 60 digits. Simple interest is
     sum(balance x rate_i x days_i) / basis and compound interest is
     balance x (ppy + rate)^n x (basis + rate x stub_days) / (ppy^n x basis) - balance. These are the same formulas the
     database engine evaluates with one division, so a value is either exact on both sides or far from any rounding tie.
  2. UA V1.2 §10.4 validations V0a (principal) and V0b (payments), in this order:
       V0a principal is a decimal string > 0                       REJECT:INVALID_PRINCIPAL
       V0b every payment amount is a decimal string > 0            REJECT:INVALID_PAYMENT
           and its date is not before start                        REJECT:PAYMENT_BEFORE_START
       V1  currency known (money currencies of bnx.currency)       REJECT:UNKNOWN_CURRENCY
       V1a principal scale <= the currency's minor units           REJECT:INVALID_PRINCIPAL
       V1b payment scale <= the currency's minor units             REJECT:INVALID_PAYMENT
     then V2...V14 exactly as S2 (V13 currency mismatch is checked before the scale of that payment).
  3. Output adds `status` ("OK") and the rounding-event ledger: one row per event (payment dates <= as_of, then as_of)
     with the exact accrual truncated to 12 decimals (`unrounded_trunc12`), the rounded amount and the mode.
  4. Currency minor units: those seeded in bnx.currency (0106, 9006).

Usage: python3 -I r28_reference.py <fixtures.json> [--json]   (--json prints every evaluation as canonical JSON)
"""
import json, re, sys
from datetime import date
from fractions import Fraction
from math import floor

CURRENCY_MINOR_UNITS = {"CAD": 2, "CNY": 2, "USD": 2, "JPY": 0, "EUR": 2, "HKD": 2, "GBP": 2, "AUD": 2, "SGD": 2, "CHF": 2}
SUPPORTED_DAY_COUNTS = {"ACT/365F", "ACT/360", "30/360-BB", "30E/360"}
SUPPORTED_WATERFALLS = {"interest_then_principal"}
SUPPORTED_PERIOD_RULES = {"start_inclusive_end_exclusive"}
ROUNDING_MODES = {"HALF_UP", "HALF_EVEN"}
DEC = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")


class Refusal(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def d(s):
    return date.fromisoformat(s)


def dec(s, code):
    if not isinstance(s, str) or not DEC.match(s):
        raise Refusal(code)
    return Fraction(s), (len(s.split(".")[1]) if "." in s else 0)


def days_and_basis(conv, start, end):
    """(days, basis): the day-count fraction for [start, end) is days / basis."""
    if conv == "ACT/365F":
        return (end - start).days, 365
    if conv == "ACT/360":
        return (end - start).days, 360
    y1, m1, d1 = start.year, start.month, start.day
    y2, m2, d2 = end.year, end.month, end.day
    if conv == "30/360-BB":
        if d1 == 31:
            d1 = 30
        if d2 == 31 and d1 >= 30:
            d2 = 30
    elif conv == "30E/360":
        d1, d2 = min(d1, 30), min(d2, 30)
    else:
        raise Refusal("TERMS_UNVERIFIED:day_count_unknown")
    return 360 * (y2 - y1) + 30 * (m2 - m1) + (d2 - d1), 360


def round_frac(x, mu, mode):
    q = x * 10 ** mu
    sign = -1 if q < 0 else 1
    q = abs(q)
    n = floor(q)
    f = q - n
    if f > Fraction(1, 2) or (f == Fraction(1, 2) and (mode == "HALF_UP" or n % 2 == 1)):
        n += 1
    return Fraction(sign * n, 10 ** mu)


def fmt(x, places):
    """A Fraction with a terminating decimal expansion of at most `places` digits, printed with exactly `places` digits."""
    n = x * 10 ** places
    assert n.denominator == 1, x
    n = n.numerator
    s = "-" if n < 0 else ""
    n = abs(n)
    if places == 0:
        return s + str(n)
    return f"{s}{n // 10 ** places}.{n % 10 ** places:0{places}d}"


def trunc12(x):
    return fmt(Fraction(floor(x * 10 ** 12), 10 ** 12), 12)


def evaluate(c):
    # V0a, V0b
    principal, pscale = dec(c.get("principal"), "REJECT:INVALID_PRINCIPAL")
    if principal <= 0:
        raise Refusal("REJECT:INVALID_PRINCIPAL")
    start = d(c["start"])
    raw_payments = []
    for p in c.get("payments") or []:
        amt, ascale = dec(p.get("amount"), "REJECT:INVALID_PAYMENT")
        if amt <= 0:
            raise Refusal("REJECT:INVALID_PAYMENT")
        if d(p["date"]) < start:
            raise Refusal("REJECT:PAYMENT_BEFORE_START")
        raw_payments.append((d(p["date"]), amt, ascale, p.get("currency")))
    # V1, V1a, V1b
    cur = c.get("currency")
    if cur not in CURRENCY_MINOR_UNITS:
        raise Refusal("REJECT:UNKNOWN_CURRENCY")
    mu = CURRENCY_MINOR_UNITS[cur]
    if pscale > mu:
        raise Refusal("REJECT:INVALID_PRINCIPAL")
    for _, _, ascale, pcur in raw_payments:
        if (pcur or cur) == cur and ascale > mu:
            raise Refusal("REJECT:INVALID_PAYMENT")
    # V2 ... V12 (S2 order)
    as_of = d(c["as_of"])
    if as_of < start:
        raise Refusal("REJECT:AS_OF_BEFORE_START")
    conv = c.get("day_count")
    if conv is None:
        raise Refusal("TERMS_UNVERIFIED:day_count")
    if conv not in SUPPORTED_DAY_COUNTS:
        raise Refusal("TERMS_UNVERIFIED:day_count_unknown")
    if c.get("period_rule") not in SUPPORTED_PERIOD_RULES:
        raise Refusal("TERMS_UNVERIFIED:period_rule")
    rates = c.get("rates") or []
    if not rates:
        raise Refusal("TERMS_UNVERIFIED:rates")
    rounding = c.get("rounding")
    if not rounding or rounding.get("mode") not in ROUNDING_MODES or rounding.get("event") != "payment_and_as_of":
        raise Refusal("TERMS_UNVERIFIED:rounding")
    mode = rounding["mode"]
    waterfall = c.get("waterfall")
    if waterfall is None:
        raise Refusal("TERMS_UNVERIFIED:waterfall")
    if waterfall not in SUPPORTED_WATERFALLS:
        raise Refusal("TERMS_UNVERIFIED:waterfall_unknown")
    model = c.get("interest_model")
    if model not in {"simple", "compound"}:
        raise Refusal("TERMS_UNVERIFIED:interest_model")
    segs = sorted(((d(r["from"]), Fraction(r["annual_rate"])) for r in rates), key=lambda t: t[0])
    if any(rate < 0 for _, rate in segs):
        raise Refusal("REJECT:NEGATIVE_RATE")
    froms = [f for f, _ in segs]
    if len(set(froms)) != len(froms):
        raise Refusal("REJECT:OVERLAPPING_RATE_SEGMENTS")
    if froms[0] > start:
        raise Refusal("TERMS_UNVERIFIED:no_rate_at_start")
    if model == "compound":
        comp = c.get("compounding")
        if not comp or not comp.get("period_ends") or not comp.get("periods_per_year"):
            raise Refusal("TERMS_UNVERIFIED:compounding")
        if len(segs) > 1:
            raise Refusal("TERMS_UNVERIFIED:compound_with_rate_changes")
    # V13
    payments = []
    for pdate, amt, _, pcur in raw_payments:
        if (pcur or cur) != cur:
            raise Refusal("REJECT:PAYMENT_CURRENCY_MISMATCH")
        payments.append((pdate, amt))
    payments.sort(key=lambda t: t[0])

    def rate_at(day):
        r = None
        for f, rate in segs:
            if f <= day:
                r = rate
        return r

    def simple_accrual(balance, a, b):
        num, basis, cur_day = Fraction(0), None, a
        for bnd in [f for f, _ in segs if a < f < b] + [b]:
            if bnd > cur_day:
                days, basis = days_and_basis(conv, cur_day, bnd)
                num += balance * rate_at(cur_day) * days
            cur_day = bnd
        return num / basis if basis else Fraction(0)

    def compound_accrual(balance, a, b):
        comp = c["compounding"]
        ppy, rate = Fraction(comp["periods_per_year"]), segs[0][1]
        n, cur_day = 0, a
        for pe in sorted(d(x) for x in comp["period_ends"]):
            if pe <= a:
                continue
            if pe > b:
                break
            n, cur_day = n + 1, pe
        days, basis = days_and_basis(conv, cur_day, b) if b > cur_day else (0, 365)
        return balance * (ppy + rate) ** n * (basis + rate * days) / (ppy ** n * basis) - balance

    accrual = simple_accrual if model == "simple" else compound_accrual
    principal_out, carry, ipaid, ppaid, total = principal, Fraction(0), Fraction(0), Fraction(0), Fraction(0)
    events, last = [], start
    for pdate, pamt in payments:
        if pdate > as_of:
            break
        exact = accrual(principal_out, last, pdate)
        acc = round_frac(exact, mu, mode)
        events.append({"event_date": pdate.isoformat(), "kind": "payment", "unrounded_trunc12": trunc12(exact),
                       "rounded": fmt(acc, mu), "mode": mode})
        total += acc
        carry += acc
        if pamt > carry + principal_out:                                   # V14
            raise Refusal("REJECT:OVERPAYMENT")
        pi = min(pamt, carry)
        carry -= pi
        ipaid += pi
        principal_out -= pamt - pi
        ppaid += pamt - pi
        last = pdate
    exact = accrual(principal_out, last, as_of)
    acc = round_frac(exact, mu, mode)
    events.append({"event_date": as_of.isoformat(), "kind": "as_of", "unrounded_trunc12": trunc12(exact),
                   "rounded": fmt(acc, mu), "mode": mode})
    total += acc
    carry += acc
    result = {"status": "OK", "accrued_interest_total": fmt(total, mu), "accrued_interest": fmt(total, mu),
              "principal_outstanding": fmt(principal_out, mu), "interest_outstanding": fmt(carry, mu),
              "outstanding_total": fmt(principal_out + carry, mu), "interest_paid": fmt(ipaid, mu),
              "principal_paid": fmt(ppaid, mu)}
    due = c.get("due_date")
    if due is None:
        result["overdue"], result["days_past_due"] = None, None
    else:
        overdue = as_of > d(due) and principal_out + carry > 0
        result["overdue"], result["days_past_due"] = overdue, (as_of - d(due)).days if overdue else 0
    result["rounding_events"] = events
    return result


def run(contract):
    try:
        return evaluate(contract)
    except Refusal as r:
        return {"refusal": r.code}


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def main(path, as_json=False):
    fx = json.load(open(path, encoding="utf-8"))
    passed = failed = 0
    for item in fx["fixtures"]:
        res, exp = run(item["contract"]), item["expected"]
        if as_json:
            print(item["id"], canonical(res))
        ok = (res.get("refusal") == exp["refusal"]) if "refusal" in exp else \
             ("refusal" not in res and all(res.get(k) == v for k, v in exp.items()))
        passed, failed = passed + ok, failed + (not ok)
        if not ok:
            print(f"FAIL {item['id']}: expected {exp} got {res}")
    print(f"{passed} passed, {failed} failed, {passed + failed} total")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], "--json" in sys.argv))
