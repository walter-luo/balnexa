#!/usr/bin/env python3
"""S4 V1.2 increment 9 tests: 9012b FX quotes, investment lots and card annual-fee policy and events (UA V1.2 §5.7;
BNX-S2-02 §4.7; BNX-S2-14 OR-R-07 AT-P0-R19, OR-R-08 AT-INV-01 (named AT-INVL-01 here: AT-INV-01 is the catalog inventory
test of core1), OR-R-09 AT-FX-01). Every expected figure is computed independently in this file with Python Decimal and
HALF_EVEN, never read back from the database. Synthetic data only. Conventions as run_g0.py.
Usage: run_s4_core9.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
from decimal import Decimal as D, ROUND_HALF_EVEN
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core2 as C2
import run_s4_core4 as C4
import sin_corpus as SC
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check
EVID = {"doc": "synthetic-evidence"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def m2(x):
    return str(D(x).quantize(D("0.01"), rounding=ROUND_HALF_EVEN))


def version(H):
    with C1.migrator(H.server, H.db) as cx:
        return cx.execute("select version from bnx.ledger_state").fetchone()[0]


def sql(H, q, p=None):
    with C1.migrator(H.server, H.db) as cx:
        return cx.execute(q, p).fetchall()


def post(H, et, d, lines, cred=None):
    return H.cmd(cred or H.owner, "post_transaction", economic_type=et, transaction_date=d, description="synthetic",
                 lines=[{"ledger_account_id": la, "currency": "CAD", "amount": amt} for la, amt in lines])["journal_id"]


# ------------------------------------------------------------------------------------------------ FX (OR-R-09)
def rate(H, base, quote, d, cred=None, **kw):
    return H.app.call("q_fx_rate", cred or H.owner, {"base": base, "quote": quote, "date": d, **kw})


def quote(H, cred=None, **kw):
    return H.cmd(cred or H.owner, "record_fx_quote", **kw)


@test("AT-FX-01", "OR-R-09 AT-FX-01 (quotes labelled; override audited; evidenced settlement authoritative); UA §5.7")
def t_fx(server, ev):
    H = C4.v2_full(server, "bnx_c9fx")
    out = {}
    out["no quote"] = rate(H, "CAD", "USD", "2026-03-01")
    quote(H, base="CAD", quote="USD", as_of="2026-03-02", rate="0.7300", quality="REFERENCE", source="Synthetic reference feed")
    out["reference 3 days old"] = rate(H, "CAD", "USD", "2026-03-05")
    out["reference 10 days old"] = rate(H, "CAD", "USD", "2026-03-12")
    out["inverse of reference"] = rate(H, "USD", "CAD", "2026-03-05")
    quote(H, base="CAD", quote="USD", as_of="2026-03-05", rate="0.7250", quality="EVIDENCED_SETTLEMENT", source="Synthetic statement",
          evidence_ref=EVID)
    v_settle = version(H)
    out["settlement same day"] = rate(H, "CAD", "USD", "2026-03-05")
    out["settlement is not used for another day"] = rate(H, "CAD", "USD", "2026-03-06")
    ovr = H.cmd(H.owner, "fx_override", base="CAD", quote="USD", rate_date="2026-03-05", rate="0.72", reason="synthetic owner override")
    out["override"] = rate(H, "CAD", "USD", "2026-03-05")
    out["override, inverse pair"] = rate(H, "USD", "CAD", "2026-03-05")
    out["at the version before the override"] = rate(H, "CAD", "USD", "2026-03-05", ledger_version=v_settle)
    quote(H, base="CAD", quote="CNY", as_of="2026-03-20", quality="MISSING", source="Synthetic reference feed")
    out["recorded MISSING"] = rate(H, "CAD", "CNY", "2026-03-20")
    out["identity"] = rate(H, "CAD", "CAD", "2026-03-20")
    out["audit of override"] = sql(H, "select command, subject->>'override_id' from bnx_audit.audit_event where command = 'fx_override'")
    out["member override"] = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "fx_override", base="CAD", quote="USD", rate_date="2026-03-06",
                                        rate="0.7", reason="x")
    H.cmd(H.owner, "invite_member", display_name="Viewer FX", role="viewer", google_sub="g-viewer-fx")
    viewer = H.login("g-viewer-fx")
    out["viewer record"] = expect_err(quote, "FORBIDDEN_ROLE", H, viewer, base="CAD", quote="USD", as_of="2026-03-06", rate="0.7",
                                      quality="REFERENCE", source="x")
    out["viewer reads"] = rate(H, "CAD", "USD", "2026-03-05", viewer)["quality"]
    bad = {"11 decimals": dict(rate="0.12345678901", quality="REFERENCE"), "same currency": dict(quote="CAD", rate="1", quality="REFERENCE"),
           "MISSING with a rate": dict(rate="0.7", quality="MISSING"), "zero rate": dict(rate="0", quality="REFERENCE"),
           "settlement without evidence": dict(rate="0.7", quality="EVIDENCED_SETTLEMENT"), "unknown quality": dict(rate="0.7", quality="GUESS")}
    for k, b in bad.items():
        args = dict(base="CAD", quote="USD", as_of="2026-03-07", source="x"); args.update(b)
        out[f"refused: {k}"] = expect_err(quote, "VALIDATION_FAILED", H, **args)
    n0 = sql(H, "select count(*) from bnx.fx_override_event")[0][0]
    sin = "SIN " + SC.value("luhn", 9012)
    out["override reason with a SIN candidate"] = expect_err(H.cmd, "SIN_CANDIDATE", H.owner, "fx_override", base="CAD", quote="USD",
                                                             rate_date="2026-03-08", rate="0.7", reason=sin)
    n1 = sql(H, "select count(*) from bnx.fx_override_event")[0][0]
    out["direct update refused"] = None
    try:
        with C1.migrator(server, H.db) as cx:
            cx.execute("set role bnx_definer"); cx.execute("update bnx.fx_quote set rate = 1")
    except psycopg.Error as e:
        out["direct update refused"] = (e.diag.message_primary or "")[:60]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-FX-01.json"), "w"), indent=1, default=str)
    q = lambda k: (out[k]["quality"], out[k]["rate"])
    check(q("no quote") == ("MISSING", None), f"{out['no quote']}")
    check(q("reference 3 days old") == ("REFERENCE", "0.73") and q("reference 10 days old") == ("STALE", "0.73"), f"{out}")
    check(out["inverse of reference"]["inverse"] and out["inverse of reference"]["rate"] == str((D(1) / D("0.73")).quantize(D("1E-10"), ROUND_HALF_EVEN)), f"{out['inverse of reference']}")
    check(q("settlement same day") == ("EVIDENCED_SETTLEMENT", "0.725") and q("settlement is not used for another day") == ("REFERENCE", "0.73"), f"{out}")
    check(q("override") == ("OVERRIDE", "0.72") and out["override"]["override_id"] == ovr["override_id"], f"{out['override']}")
    check(out["override, inverse pair"]["rate"] == "1.3888888889" and out["override, inverse pair"]["quality"] == "OVERRIDE", f"{out}")
    check(q("at the version before the override") == ("EVIDENCED_SETTLEMENT", "0.725"), f"{out}")
    check(q("recorded MISSING") == ("MISSING", None) and out["recorded MISSING"]["source"] == "Synthetic reference feed", f"{out}")
    check(q("identity") == ("IDENTITY", "1"), f"{out}")
    check(out["audit of override"] == [("fx_override", ovr["override_id"])], f"{out['audit of override']}")
    check(n0 == n1 == 1 and out["direct update refused"], f"{n0} {n1} {out['direct update refused']}")
    return ("no quote -> MISSING with a null rate (never 1 or 0); a reference quote is REFERENCE for 7 days, then STALE; the inverse "
            "pair is 1/rate at 10 decimals HALF_EVEN; an evidenced settlement rate wins over the reference on its own date only; "
            "the Owner override wins over both, is audited with its reason and is versioned (the earlier ledger version still "
            "answers EVIDENCED_SETTLEMENT); a recorded MISSING names its source; same currency -> IDENTITY; member override "
            "FORBIDDEN_ROLE, viewer can read but not record; 6 malformed quotes refused; an override reason holding a SIN "
            "candidate is refused with nothing stored; fx_quote is append-only")


# ------------------------------------------------------------------------------------------------ investments (OR-R-08)
def inv_household(server, db):
    H = C4.v2_full(server, db)
    r = H.cmd(H.owner, "create_account", kind="investment", **H.inst("Synthetic Bank"), label="Brokerage", currencies=["CAD"],
              visibility="private")
    H.inv_acc, H.inv = r["account_id"], r["account_currencies"][0]
    H.result = H.cmd(H.owner, "create_category", kind="income", currency="CAD", name_en="Investment result")["ledger_account_id"]
    return H


def position(H, cred=None, **q):
    return H.app.call("q_investment_position", cred or H.owner, {"account_currency_id": H.inv["account_currency_id"], **q})


@test("AT-INVL-01", "OR-R-08 AT-INV-01 (realized vs unrealized vs FX; missing NAV flagged; estimated vs confirmed proceeds)")
def t_inv(server, ev):
    H = inv_household(server, "bnx_c9inv")
    X = "11111111-1111-4111-8111-111111111111"
    acid = H.inv["account_currency_id"]
    sub = post(H, "investment_subscription", "2026-01-10", [(H.inv["ledger_account_id"], "1000.00"), (H.cad["ledger_account_id"], "-1000.00")])
    l1 = H.cmd(H.owner, "record_investment_lot", account_currency_id=acid, instrument_id=X, units="100", cost="1000.00",
               acquired_on="2026-01-10", source_journal_id=sub)["lot_id"]
    H.cmd(H.owner, "record_investment_lot", account_currency_id=acid, instrument_id=X, units="50", cost="600.00", acquired_on="2026-02-10")
    for d, r in (("2026-01-10", "0.74"), ("2026-02-10", "0.75"), ("2026-03-01", "0.73"), ("2026-03-31", "0.72")):
        quote(H, base="CAD", quote="USD", as_of=d, rate=r, quality="REFERENCE", source="Synthetic reference feed")
    est = H.cmd(H.owner, "record_lot_disposal", lot_id=l1, units="40", proceeds="520.00", disposed_on="2026-03-01",
                proceeds_quality="ESTIMATED")["disposal_id"]
    out = {}
    out["no NAV"] = position(H, as_of="2026-03-31", reporting_currency="USD")
    H.cmd(H.owner, "record_valuation", instrument_id=X, valuation_date="2026-03-31", price="12.50", currency="CAD", source="Synthetic NAV")
    v_est = version(H)
    out["NAV, estimated proceeds"] = position(H, as_of="2026-03-31", reporting_currency="USD")
    red = post(H, "investment_redemption", "2026-03-03", [(H.cad["ledger_account_id"], "515.00"), (H.inv["ledger_account_id"], "-400.00"),
                                                           (H.result, "-115.00")])
    H.cmd(H.owner, "record_lot_disposal", lot_id=l1, units="40", proceeds="515.00", disposed_on="2026-03-01", proceeds_quality="CONFIRMED",
          journal_id=red, supersedes_disposal_id=est)
    out["confirmed"] = position(H, as_of="2026-03-31", reporting_currency="USD")
    out["at the earlier version"] = position(H, as_of="2026-03-31", reporting_currency="USD", ledger_version=v_est)
    out["as of 2026-05-15 (NAV 45 days old)"] = position(H, as_of="2026-05-15")["instruments"][0]["valuation"]["status"]
    out["units exceeded"] = expect_err(H.cmd, "UNITS_EXCEEDED", H.owner, "record_lot_disposal", lot_id=l1, units="61", proceeds="1.00",
                                       disposed_on="2026-03-02", proceeds_quality="ESTIMATED")
    out["supersede a confirmed disposal"] = expect_err(H.cmd, "SUPERSEDE_STATE", H.owner, "record_lot_disposal", lot_id=l1, units="1",
                                                       proceeds="1.00", disposed_on="2026-03-02", proceeds_quality="ESTIMATED",
                                                       supersedes_disposal_id=est)
    out["confirmed without journal"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "record_lot_disposal", lot_id=l1, units="1",
                                                  proceeds="1.00", disposed_on="2026-03-02", proceeds_quality="CONFIRMED")
    out["disposal before acquisition"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "record_lot_disposal", lot_id=l1, units="1",
                                                    proceeds="1.00", disposed_on="2026-01-01", proceeds_quality="ESTIMATED")
    out["lot on a bank account"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "record_investment_lot", account_currency_id=H.cad["account_currency_id"],
                                              instrument_id=X, units="1", cost="1.00", acquired_on="2026-01-10")
    out["cost with 3 decimals"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "record_investment_lot", account_currency_id=acid,
                                             instrument_id=X, units="1", cost="1.005", acquired_on="2026-01-10")
    out["member without grant: position"] = expect_err(position, "NOT_FOUND", H, H.member, as_of="2026-03-31")
    out["member without grant: lot"] = expect_err(H.cmd, "NOT_POSTABLE", H.member, "record_investment_lot", account_currency_id=acid,
                                                  instrument_id=X, units="1", cost="1.00", acquired_on="2026-01-10")
    out["member without grant: valuation"] = expect_err(H.cmd, "NOT_FOUND", H.member, "record_valuation", instrument_id=X,
                                                        valuation_date="2026-03-31", price="1", currency="CAD", source="x")
    # a second instrument priced in USD without a USD->CAD rate on its valuation date: NAV_FX_MISSING, totals null
    Y = "22222222-2222-4222-8222-222222222222"
    H.cmd(H.owner, "record_investment_lot", account_currency_id=acid, instrument_id=Y, units="10", cost="100.00", acquired_on="2026-02-10")
    H.cmd(H.owner, "record_valuation", instrument_id=Y, valuation_date="2026-01-05", price="8", currency="USD", source="Synthetic NAV")
    out["USD NAV without a rate"] = position(H, as_of="2026-03-31")
    # a later USD NAV converts through the inverse of the stale CAD->USD reference (03-01, 29 days old): computed and flagged
    H.cmd(H.owner, "record_valuation", instrument_id=Y, valuation_date="2026-03-30", price="8", currency="USD", source="Synthetic NAV")
    out["USD NAV at a stale rate"] = position(H, as_of="2026-03-31")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-INVL-01.json"), "w"), indent=1, default=str)

    # independent expectation (Decimal): lot 1 100 u / 1000.00 on 01-10, lot 2 50 u / 600.00 on 02-10; 40 u of lot 1 sold
    # 03-01; NAV 12.50 on 03-31; CAD->USD 0.74 / 0.75 / 0.73 / 0.72 on 01-10 / 02-10 / 03-01 / 03-31
    alloc = D("1000.00") * 40 / 100
    cost_rem = D("1000.00") + D("600.00") - alloc
    mv = 110 * D("12.50")
    r_acq1, r_acq2, r_disp, r_now = D("0.74"), D("0.75"), D("0.73"), D("0.72")
    cost_usd = (D("1000.00") - alloc) * r_acq1 + D("600.00") * r_acq2

    def exp(proceeds, quality):
        rz = D(proceeds) - alloc
        rz_usd = D(proceeds) * r_disp - alloc * r_acq1
        e = {"units_held": "110", "cost_remaining": m2(cost_rem), "market_value": m2(mv), "unrealized": m2(mv - cost_rem),
             "realized": {"confirmed": m2(rz if quality == "CONFIRMED" else 0), "estimated": m2(rz if quality == "ESTIMATED" else 0)},
             "reporting": {"cost_remaining": m2(cost_usd), "market_value": m2(mv * r_now), "unrealized": m2(mv * r_now - cost_usd),
                           "unrealized_fx_effect": m2(cost_rem * r_now - cost_usd),
                           "realized_confirmed": m2(rz_usd if quality == "CONFIRMED" else 0),
                           "realized_estimated": m2(rz_usd if quality == "ESTIMATED" else 0),
                           "realized_fx_effect": m2(alloc * (r_disp - r_acq1))}}
        return e

    def got(p):
        i = p["instruments"][0]
        return {"units_held": i["units_held"], "cost_remaining": i["cost_remaining"], "market_value": i["market_value"],
                "unrealized": i["unrealized"], "realized": {k: i["realized"][k] for k in ("confirmed", "estimated")},
                "reporting": {k: i["reporting"][k] for k in ("cost_remaining", "market_value", "unrealized", "unrealized_fx_effect",
                                                             "realized_confirmed", "realized_estimated", "realized_fx_effect")}}
    n = out["no NAV"]["instruments"][0]
    check(n["valuation"]["status"] == "MISSING_NAV" and n["market_value"] is None and n["unrealized"] is None
          and n["reporting"]["market_value"] is None and "MISSING_NAV" in out["no NAV"]["warnings"]
          and out["no NAV"]["totals"]["market_value"] is None and n["realized"]["estimated"] == "120.00", f"{n}")
    check(got(out["NAV, estimated proceeds"]) == exp("520.00", "ESTIMATED"), f"{got(out['NAV, estimated proceeds'])} vs {exp('520.00', 'ESTIMATED')}")
    check("ESTIMATED_PROCEEDS" in out["NAV, estimated proceeds"]["warnings"], f"{out['NAV, estimated proceeds']['warnings']}")
    check(got(out["confirmed"]) == exp("515.00", "CONFIRMED") and "ESTIMATED_PROCEEDS" not in out["confirmed"]["warnings"],
          f"{got(out['confirmed'])} vs {exp('515.00', 'CONFIRMED')}")
    check(got(out["at the earlier version"]) == exp("520.00", "ESTIMATED"), f"{got(out['at the earlier version'])}")
    check(out["as of 2026-05-15 (NAV 45 days old)"] == "STALE_NAV", out["as of 2026-05-15 (NAV 45 days old)"])
    u = out["USD NAV without a rate"]
    y = next(i for i in u["instruments"] if i["instrument_id"] == Y)
    check(y["valuation"]["status"] == "NAV_FX_MISSING" and y["market_value"] is None and u["totals"]["market_value"] is None
          and u["totals"]["unrealized"] is None and u["totals"]["cost_remaining"] == m2(cost_rem + 100), f"{u}")
    st_ = out["USD NAV at a stale rate"]
    ys = next(i for i in st_["instruments"] if i["instrument_id"] == Y)
    inv073 = (D(1) / D("0.73")).quantize(D("1E-10"), ROUND_HALF_EVEN)
    check(ys["valuation"]["status"] == "OK" and "NAV_FX_STALE" in ys["warnings"] and ys["market_value"] == m2(10 * D(8) * inv073), f"{ys}")
    e = exp("515.00", "CONFIRMED")
    return (f"two lots, 40 units of the first sold: without a NAV the market value and unrealized gain are null and MISSING_NAV is "
            f"flagged (realized estimated 120.00); with NAV 12.50: cost {e['cost_remaining']}, market value {e['market_value']}, "
            f"unrealized {e['unrealized']}; in USD: unrealized {e['reporting']['unrealized']} of which FX {e['reporting']['unrealized_fx_effect']}, "
            f"realized FX {e['reporting']['realized_fx_effect']} (all equal to an independent Decimal computation, HALF_EVEN); "
            f"estimated proceeds 520.00 superseded by confirmed 515.00 from the posted redemption (realized confirmed "
            f"{e['realized']['confirmed']}); the earlier ledger version still shows the estimate; NAV older than 31 days -> "
            f"STALE_NAV; a USD NAV with no USD->CAD rate -> NAV_FX_MISSING and null totals, at a stale rate -> computed and NAV_FX_STALE; 6 invalid commands refused; a member "
            f"without a grant gets NOT_FOUND / NOT_POSTABLE")


# ------------------------------------------------------------------------------------------------ card fees (OR-R-07)
def card_household(server, db):
    H = C4.v2_full(server, db)
    r = H.cmd(H.owner, "create_account", kind="credit_card", **H.inst("Synthetic Bank"), label="Synthetic card", currencies=["CAD"],
              visibility="private")
    H.card_acc, H.card = r["account_id"], r["account_currencies"][0]
    H.fees = H.cmd(H.owner, "create_category", kind="expense", currency="CAD", name_en="Card fees")["ledger_account_id"]
    return H


def progress(H, cred=None, **q):
    return H.app.call("q_card_fee_progress", cred or H.owner, {"card_account_id": H.card_acc, **q})


def spend(H, d, amt):
    return post(H, "card_spend", d, [(H.groceries, amt), (H.card["ledger_account_id"], f"-{amt}")])


def refund(H, d, amt, cat=None):
    return post(H, "refund", d, [(H.card["ledger_account_id"], amt), (cat or H.groceries, f"-{amt}")])


def fee_event(H, cred=None, **kw):
    return H.cmd(cred or H.owner, "record_card_fee_event", card_account_id=H.card_acc, **kw)


POLICY = dict(effective_from="2026-02-15", annual_fee="120.00", currency="CAD", period_rule="CARD_YEAR", anniversary="2025-02-15",
              criteria={"qualifying_spend": "500.00"}, issuer_confirmed=False, evidence_ref=EVID)


@test("AT-P0-R19", "OR-R-07 AT-P0-R19 (refund regresses progress; calculated != confirmed != posted, + and -); R20; UA §5.7")
def t_card(server, ev):
    H = card_household(server, "bnx_c9card")
    out = {}
    out["no policy"] = progress(H, as_of="2026-03-31")["status"]
    H.cmd(H.owner, "set_card_fee_policy", card_account_id=H.card_acc, **POLICY)
    spend(H, "2026-02-10", "900.00")                              # before the card year: not counted
    spend(H, "2026-02-20", "300.00")
    p2 = spend(H, "2026-03-05", "250.00")
    post(H, "card_repayment", "2026-03-06", [(H.card["ledger_account_id"], "200.00"), (H.cad["ledger_account_id"], "-200.00")])
    fee = post(H, "fee", "2026-02-16", [(H.fees, "120.00"), (H.card["ledger_account_id"], "-120.00")])
    out["qualified"] = progress(H, as_of="2026-03-31")
    v_q = version(H)
    refund(H, "2026-03-10", "100.00")
    out["after refund"] = progress(H, as_of="2026-03-31")
    out["at the version before the refund"] = progress(H, as_of="2026-03-31", ledger_version=v_q)
    H.cmd(H.owner, "correct_transaction", journal_id=p2, reason="synthetic amount fix", replacement={
        "transaction_date": "2026-03-05", "description": "fixed", "lines": [
            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "260.00"},
            {"ledger_account_id": H.card["ledger_account_id"], "currency": "CAD", "amount": "-260.00"}]})
    out["after correction"] = progress(H, as_of="2026-03-31")
    calc = fee_event(H, kind="CALCULATED_QUALIFICATION", period_start="2026-02-15", as_of="2026-03-31")
    out["recorded calculation"] = calc
    out["fee posted"] = fee_event(H, kind="FEE_POSTED", period_start="2026-02-15", journal_id=fee)
    spend(H, "2026-03-20", "50.00")
    out["qualified again, fee posted, no waiver"] = progress(H, as_of="2026-03-31")
    fee_event(H, kind="ISSUER_CONFIRMED_WAIVER", period_start="2026-02-15", evidence_ref={"doc": "synthetic-issuer-letter"})
    out["waiver confirmed, fee still posted"] = progress(H, as_of="2026-03-31")
    fr = refund(H, "2026-03-25", "120.00", cat=H.fees)
    fee_event(H, kind="FEE_REFUNDED", period_start="2026-02-15", journal_id=fr)
    out["fee refunded"] = progress(H, as_of="2026-03-31")
    # negatives
    out["FEE_POSTED with a purchase journal"] = expect_err(fee_event, "VALIDATION_FAILED", H, kind="FEE_POSTED", period_start="2026-02-15",
                                                           journal_id=spend(H, "2026-03-21", "1.00"))
    out["same journal twice"] = expect_err(fee_event, "ALREADY_LINKED", H, kind="FEE_POSTED", period_start="2026-02-15", journal_id=fee)
    out["waiver without evidence"] = expect_err(fee_event, "VALIDATION_FAILED", H, kind="ISSUER_CONFIRMED_WAIVER", period_start="2026-02-15")
    out["not a period start"] = expect_err(fee_event, "VALIDATION_FAILED", H, kind="ISSUER_CONFIRMED_WAIVER", period_start="2026-02-16",
                                           evidence_ref=EVID)
    out["unknown criteria key"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_card_fee_policy", card_account_id=H.card_acc,
                                             **{**POLICY, "criteria": {"qualifying_spend": "1.00", "note": "x"}})
    out["CARD_YEAR without anniversary"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_card_fee_policy", card_account_id=H.card_acc,
                                                      **{k: v for k, v in POLICY.items() if k != "anniversary"})
    out["policy on a bank account"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_card_fee_policy", card_account_id=H.acc, **POLICY)
    out["member without grant: progress"] = expect_err(progress, "NOT_FOUND", H, H.member, as_of="2026-03-31")
    out["member without grant: policy"] = expect_err(H.cmd, "NOT_POSTABLE", H.member, "set_card_fee_policy", card_account_id=H.card_acc, **POLICY)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.card_acc, can_view=True, can_post=False)
    out["member with view grant: progress"] = progress(H, H.member, as_of="2026-03-31")["calculated"]["status"]
    out["member with view grant: event"] = expect_err(fee_event, "NOT_POSTABLE", H, H.member, kind="CALCULATED_QUALIFICATION",
                                                      period_start="2026-02-15")
    # a new policy version from the next card year: count criterion, ANY; the first year keeps the first policy
    H.cmd(H.owner, "set_card_fee_policy", card_account_id=H.card_acc, **{**POLICY, "effective_from": "2027-02-15", "issuer_confirmed": True,
                                                                         "criteria": {"qualifying_spend": "5000.00", "qualifying_count": 2, "combine": "ANY"}})
    spend(H, "2027-02-20", "10.00"); spend(H, "2027-03-01", "10.00")
    out["second policy"] = progress(H, as_of="2027-03-31")
    out["first year under the first policy"] = progress(H, as_of="2026-03-31")["policy"]["seq"]
    out["first year at its end"] = progress(H, as_of="2027-02-14", period_start="2026-02-15")["calculated"]["status"]
    out["periods"] = sql(H, "select (bnx.card_period('CARD_YEAR', '2024-02-29', '2026-03-01')).*, (bnx.card_period('CARD_YEAR', "
                            "'2024-02-29', '2028-02-29')).*, (bnx.card_period('CALENDAR_YEAR', null, '2026-07-04')).*")[0]
    out["events"] = sql(H, "select kind, amount::text from bnx.card_fee_event order by seq")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-P0-R19.json"), "w"), indent=1, default=str)

    def st(p):
        return (p["progress"]["spend"], p["calculated"]["status"], p["issuer"]["waiver_confirmed"], p["fee"]["status"])
    check(out["no policy"] == "NO_POLICY", out["no policy"])
    check(st(out["qualified"]) == ("550.00", "QUALIFIED", False, "NOT_POSTED") and out["qualified"]["progress"]["purchase_count"] == 2
          and out["qualified"]["period"] == {"rule": "CARD_YEAR", "start": "2026-02-15", "end": "2027-02-14", "counted_through": "2026-03-31"},
          f"{out['qualified']}")
    check("POLICY_NOT_ISSUER_CONFIRMED" in out["qualified"]["warnings"] and "QUALIFICATION_NOT_CONFIRMED_BY_ISSUER" in out["qualified"]["warnings"],
          f"{out['qualified']['warnings']}")
    check(st(out["after refund"]) == ("450.00", "NOT_YET_QUALIFIED", False, "NOT_POSTED")
          and out["after refund"]["progress"]["spend_remaining"] == "50.00", f"{out['after refund']['progress']}")
    check(st(out["at the version before the refund"]) == ("550.00", "QUALIFIED", False, "NOT_POSTED"), f"{out['at the version before the refund']}")
    check(st(out["after correction"]) == ("460.00", "NOT_YET_QUALIFIED", False, "NOT_POSTED"), f"{out['after correction']['progress']}")
    check(calc["calculated_status"] == "NOT_YET_QUALIFIED", f"{calc}")
    check(st(out["qualified again, fee posted, no waiver"]) == ("510.00", "QUALIFIED", False, "POSTED")
          and "FEE_POSTED_DESPITE_QUALIFICATION_OR_WAIVER" in out["qualified again, fee posted, no waiver"]["warnings"]
          and out["qualified again, fee posted, no waiver"]["last_recorded_calculation"]["status"] == "NOT_YET_QUALIFIED", f"{out}")
    check(st(out["waiver confirmed, fee still posted"]) == ("510.00", "QUALIFIED", True, "POSTED"), f"{out}")
    fr_ = out["fee refunded"]
    check(st(fr_) == ("510.00", "QUALIFIED", True, "REFUNDED") and fr_["fee"]["net"] == "0.00" and fr_["warnings"] == ["POLICY_NOT_ISSUER_CONFIRMED"],
          f"{fr_}")
    check(out["member with view grant: progress"] == "QUALIFIED", out["member with view grant: progress"])
    s2 = out["second policy"]
    check(s2["policy"]["seq"] == 2 and s2["calculated"]["status"] == "QUALIFIED" and s2["progress"]["count_met"] is True
          and s2["progress"]["spend_met"] is False and s2["warnings"] == ["QUALIFICATION_NOT_CONFIRMED_BY_ISSUER"], f"{s2}")
    check(out["first year under the first policy"] == 1 and out["first year at its end"] == "QUALIFIED", f"{out}")
    import datetime as dt
    check(out["periods"] == (dt.date(2026, 2, 28), dt.date(2027, 2, 27), dt.date(2028, 2, 29), dt.date(2029, 2, 27),
                             dt.date(2026, 1, 1), dt.date(2026, 12, 31)), f"{out['periods']}")
    check(out["events"] == [("CALCULATED_QUALIFICATION", None), ("FEE_POSTED", "120.0000"), ("ISSUER_CONFIRMED_WAIVER", None),
                            ("FEE_REFUNDED", "120.0000")], f"{out['events']}")
    return ("card year from 15 Feb: purchases 300 + 250 (one before the year, a repayment and the fee excluded) -> spend 550.00 "
            "QUALIFIED; a refund of 100 regresses it to 450.00 NOT_YET_QUALIFIED (50.00 remaining) while the earlier ledger "
            "version still answers 550.00; a corrected purchase counts by its replacement (460.00); the recorded calculation, "
            "the issuer's waiver and the posted fee are three separate fields and events (POSTED despite QUALIFIED is warned; "
            "the fee refund journal does not count as a purchase refund); a new policy version governs the next year only "
            "(count criterion, ANY); 29 Feb anniversaries fall on 28 Feb; 9 invalid or unauthorised commands refused; a view "
            "grant reads but cannot record")


# ------------------------------------------------------------------------------------------------ catalog and flags
@test("AT-9012b-CAT", "F-C2-07 (module flags on the account-scoped 9012b tables); function catalog; append-only; table classes")
def t_cat(server, ev):
    db = "bnx_c9cat"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        trg = {r[0] for r in cx.execute("select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n "
                                        "on n.oid = c.relnamespace where n.nspname = 'bnx' and c.relname in ('fx_quote','investment_lot',"
                                        "'investment_lot_disposal','card_fee_policy','card_fee_event') and not t.tgisinternal")}
        fep = dict(cx.execute("select table_name, mode from bnx.flag_enforcement_point where migration = '9012'").fetchall())
        fs = cx.execute("select function_name, scope, needs_ac_subset from bnx.function_scope where function_name in "
                        "('q_fx_rate','q_investment_position','q_card_fee_progress') order by 1").fetchall()
        tc = dict(cx.execute("select table_name, class from bnx.table_class where table_name in ('fx_quote','investment_lot',"
                             "'investment_lot_disposal','card_fee_policy','card_fee_event')").fetchall())
        grants = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and "
                            "p.proname in ('q_fx_rate','q_investment_position','q_card_fee_progress','cmd_record_fx_quote','cmd_fx_override',"
                            "'cmd_record_investment_lot','cmd_record_lot_disposal','cmd_record_valuation','cmd_set_card_fee_policy',"
                            "'cmd_record_card_fee_event') and has_function_privilege('bnx_app', p.oid, 'execute')").fetchone()[0]
        internal = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and "
                              "p.proname in ('fx_rate_at','card_fee_progress','card_policy_at') and has_function_privilege('bnx_app', p.oid, 'execute')").fetchone()[0]
    expect_trg = {"t_append_only", "t_scope_flag_investment_lot", "t_scope_flag_investment_lot_disposal", "t_scope_flag_card_fee_policy",
                  "t_scope_flag_card_fee_event"}
    check(expect_trg <= trg, f"{trg}")
    check({k: fep.get(k) for k in ("investment_lot", "investment_lot_disposal", "card_fee_policy", "card_fee_event")} ==
          {"investment_lot": "account_currency_id", "investment_lot_disposal": "lot_id", "card_fee_policy": "card_fee", "card_fee_event": "card_fee"}, f"{fep}")
    check(fs == [("q_card_fee_progress", "finance.read", True), ("q_fx_rate", "finance.read", False), ("q_investment_position", "finance.read", True)], f"{fs}")
    check(set(tc.values()) == {"F"} and len(tc) == 5 and grants == 10 and internal == 0, f"{tc} {grants} {internal}")
    # module flag: once the account's region (Canada) is disabled, the lot, the disposal and the position are refused
    H = C4.v2_full(server, "bnx_c9flg")
    r = H.cmd(H.owner, "create_account", kind="investment", **H.inst("Synthetic Bank"), label="Brokerage", currencies=["CAD"])
    acid = r["account_currencies"][0]["account_currency_id"]
    lot = H.cmd(H.owner, "record_investment_lot", account_currency_id=acid, instrument_id="33333333-3333-4333-8333-333333333333",
                units="1", cost="1.00", acquired_on="2026-01-10")["lot_id"]
    # bnx.journal_counts_at equals the R1 rule (visible_at, not corrected) for every journal and version, including a plan
    # posting (visible from its batch activation, not from its own version) and a corrected journal
    md = H.cmd(H.owner, "draft_create_transaction", account_currency_id=H.cad["account_currency_id"], transaction_date="2026-03-02",
               economic_type="consumption_expense", amount="-12.00", counter_ledger_account_id=H.groceries, description="plan entry")
    C4.approve(H, H.owner, md); C4.run_plan(H, md["plan_id"])
    e = H.expense(H.owner, "5.00", date="2026-03-03")
    H.cmd(H.owner, "correct_transaction", journal_id=e["journal_id"], reason="synthetic")
    with C1.migrator(server, H.db) as cx:
        diff = cx.execute("""select count(*) from bnx.journal_entry je cross join generate_series(0, (select version from bnx.ledger_state)) v
                              where bnx.journal_counts_at(je.id, v) <> (exists (select 1 from bnx.visible_at(v) x where x.journal_id = je.id)
                                and not exists (select 1 from bnx.journal_correction jc where jc.original_journal_id = je.id
                                                  and jc.recorded_version <= v))""").fetchone()[0]
        pairs = cx.execute("select count(*) * ((select version from bnx.ledger_state) + 1) from bnx.journal_entry").fetchone()[0]
        plan_j = cx.execute("select count(*) from bnx.journal_entry where posting_batch_id is not null").fetchone()[0]
    check(diff == 0 and plan_j >= 1, f"journal_counts_at differs from visible_at on {diff} of {pairs} pairs (plan journals {plan_j})")
    C2.set_modules(H, {"Canada": "NO", "International": "NO", "CRA": "NO"}, "3" * 64)
    out = {"lot on a disabled region": expect_err(H.cmd, "SCOPE_DISABLED", H.owner, "record_investment_lot", account_currency_id=acid,
                                                  instrument_id="33333333-3333-4333-8333-333333333333", units="1", cost="1.00",
                                                  acquired_on="2026-01-10"),
           "disposal on a disabled region": expect_err(H.cmd, "SCOPE_DISABLED", H.owner, "record_lot_disposal", lot_id=lot, units="1",
                                                       proceeds="1.00", disposed_on="2026-02-01", proceeds_quality="ESTIMATED"),
           # reads: 9007 live visibility requires an enabled scope, so the account is simply not visible (no existence leak)
           "position on a disabled region": expect_err(H.app.call, "NOT_FOUND", "q_investment_position", H.owner, {"account_currency_id": acid})}
    H.close()
    json.dump({"triggers": sorted(trg), "enforcement": fep, "function_scope": fs, "out": out}, open(os.path.join(ev, "AT-9012b-CAT.json"), "w"),
              indent=1, default=str)
    return (f"append-only and t_scope_flag_* triggers on the 9012b tables; enforcement points {sorted(fep)}; the three queries are "
            f"finance.read in the function catalog (positions need an account-currency subset); 10 commands and queries granted to "
            f"bnx_app, the internal helpers are not; journal_counts_at equals the R1 visibility rule on all {pairs} (journal, version) "
            f"pairs including a plan posting and a correction; with the account's region disabled the lot and the disposal are refused "
            f"(SCOPE_DISABLED) and the position is NOT_FOUND (9007 visibility needs an enabled scope)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core9", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "PASS"
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__,
               "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core9_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
