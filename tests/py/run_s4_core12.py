#!/usr/bin/env python3
"""S4 V1.2 increment 12 tests: 9013 report families F1-F7, R09 cash flow, R30 review queue, R31 traceability, snapshot status and
artifacts (UA V1.2 §5.8; OR-R-02...06; crosswalk V1.1). Golden oracles: every expected figure below is derived by hand from the
postings of `world()` (comments show the arithmetic), never read back from the database. Synthetic data only.
Usage: run_s4_core12.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core2 as C2
import run_s4_core10 as C10
import run_s4_core11 as C11
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check
EVID = {"doc": "synthetic-loan-note"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def acct(H, kind, label, cur="CAD", opening="0", **kw):
    r = H.cmd(H.owner, "create_account", kind=kind, label=label, currencies=[cur], **(kw or H.inst("Synthetic Bank")))["account_currencies"][0]
    H.cmd(H.owner, "set_opening", account_currency_id=r["account_currency_id"], anchor_date="2026-01-01", amount=opening)
    return r


def post(H, et, d, lines, cur="CAD"):
    return H.cmd(H.owner, "post_transaction", economic_type=et, transaction_date=d, description=f"synthetic {et}",
                 lines=[{"ledger_account_id": la, "currency": cur, "amount": amt} for la, amt in lines])["journal_id"]


def world(server, db):
    """cad chequing 1000.00, savings 500.00, investment 0, USD chequing 100.00 USD, card (private) 0, loan receivable / payable
    (FAMILY) 0 - all opened 2026-01-01. January postings:
      J1 01-10 income 3000 to cad | J2 01-12 groceries 200 from cad | J3 01-15 card groceries 150 | J4 01-20 card repayment 100
      J5 01-22 transfer 400 cad->sav | J6 01-25 investment subscription 1000 cad->inv | J7 01-28 intra-household loan 300
      (receivable +300, cad -300, sav +300, payable -300). Balances 01-31: cad 2000, sav 1200, inv 1000, card -50, rec 300,
      pay -300, usd 100 USD."""
    H = C10.household(server, db)
    H.cmd(H.owner, "set_opening", account_currency_id=H.card["account_currency_id"], anchor_date="2026-01-01", amount="0")
    H.sav = acct(H, "bank_deposit", "Savings", opening="500.00")
    H.inv = acct(H, "investment", "Brokerage")
    H.usd = acct(H, "bank_deposit", "USD chequing", cur="USD", opening="100.00")
    fam = dict(institution_code="FAMILY", region_scope="CA")
    H.rec = acct(H, "loan_receivable", "Loan to sibling", **fam)
    H.pay = acct(H, "loan_payable", "Loan from sibling", **fam)
    H.lender = H.cmd(H.owner, "create_party", kind="person", display_name="Synthetic Lender")["party_id"]
    H.borrower = H.cmd(H.owner, "create_party", kind="person", display_name="Synthetic Borrower")["party_id"]
    cad, sav, inv, card, rec, pay = (x["ledger_account_id"] for x in (H.cad, H.sav, H.inv, H.card, H.rec, H.pay))
    H.j = {}
    H.j["J1"] = post(H, "income", "2026-01-10", [(cad, "3000.00"), (H.salary, "-3000.00")])
    H.j["J2"] = post(H, "consumption_expense", "2026-01-12", [(H.groceries, "200.00"), (cad, "-200.00")])
    H.j["J3"] = post(H, "card_spend", "2026-01-15", [(H.groceries, "150.00"), (card, "-150.00")])
    H.j["J4"] = post(H, "card_repayment", "2026-01-20", [(card, "100.00"), (cad, "-100.00")])
    H.j["J5"] = post(H, "internal_transfer", "2026-01-22", [(sav, "400.00"), (cad, "-400.00")])
    H.j["J6"] = post(H, "investment_subscription", "2026-01-25", [(inv, "1000.00"), (cad, "-1000.00")])
    H.j["J7"] = post(H, "intra_household_loan", "2026-01-28", [(rec, "300.00"), (cad, "-300.00"), (sav, "300.00"), (pay, "-300.00")])
    H.cmd(H.owner, "declare_loan", currency="CAD", principal="300.00", start="2026-01-28", lender_party_id=H.lender, borrower_party_id=H.borrower,
          receivable_account_currency_id=H.rec["account_currency_id"], payable_account_currency_id=H.pay["account_currency_id"], evidence_ref=EVID)
    H.cmd(H.owner, "record_ownership", account_id=H.acc, events=[{"party_id": H.lender, "kind": "legal_owner", "event": "set", "share": "100",
                                                                   "effective_from": "2025-01-01"}])
    H.cmd(H.owner, "record_fx_quote", base="CAD", quote="USD", as_of="2026-01-31", rate="0.75", quality="REFERENCE", source="Synthetic reference feed")
    return H


def call(H, fn, cred=None, **q):
    return H.app.call(fn, cred or H.owner, q)


@test("AT-F1", "F1 balances (R03, R11, R16, R27, R33): native balances, statement column apart, reporting currency, grouping by account id")
def t_f1(server, ev):
    H = world(server, "bnx_c12f1")
    C10.stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "1950.00")       # printed closing differs from the ledger: shown apart, never merged
    out = {"owner": call(H, "q_f1_balances", as_of="2026-01-31", reporting_currency="USD"),
           "member": call(H, "q_f1_balances", H.member, as_of="2026-01-31"),
           "member asks for the card": expect_err(call, "NOT_AVAILABLE", H, "q_f1_balances", H.member, account_currency_ids=[H.card["account_currency_id"]])}
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-F1.json"), "w"), indent=1, default=str)
    o = out["owner"]
    bal = {r["account_currency_id"]: r["balance"] for r in o["rows"]}
    # CAD total = 2000 + 1200 + 1000 - 50 + 300 - 300 = 4150; reporting USD = 4150 x 0.75 + 100 = 3212.50
    check(bal[H.cad["account_currency_id"]] == "2000.00" and bal[H.card["account_currency_id"]] == "-50.00" and bal[H.usd["account_currency_id"]] == "100.00", f"{bal}")
    check(o["totals_by_currency"] == {"CAD": "4150.00", "USD": "100.00"} and o["total_reporting"] == "3212.50", f"{o['totals_by_currency']} {o['total_reporting']}")
    cad_row = next(r for r in o["rows"] if r["account_currency_id"] == H.cad["account_currency_id"])
    check(cad_row["latest_statement"]["closing_balance"] == "1950.0000" and cad_row["balance"] == "2000.00"
          and cad_row["holders"][0]["party_id"] == H.lender and cad_row["reporting"]["rate_quality"] == "REFERENCE", f"{cad_row}")
    check(all(k in o for k in ("ledger_version", "as_of", "reporting_currency", "fx_policy", "fx_snapshot_ref", "grants_digest", "scope_warnings", "evidence_refs")), f"{list(o)}")
    m = out["member"]
    check(H.card["account_currency_id"] not in {r["account_currency_id"] for r in m["rows"]} and m["totals_by_currency"]["CAD"] == "4200.00"
          and m["grants_digest"] != o["grants_digest"], f"{m['totals_by_currency']}")
    return ("native balances per account-currency (cad 2000.00, card -50.00, USD 100.00); CAD total 4150 and USD 100 never summed; "
            "reporting USD 3212.50 = 4150 x 0.75 + 100; the printed statement closing (1950) stays in its own column; holders from "
            "verified ownership; envelope complete; a member without the card grant does not see it (CAD 4200) and cannot ask for it")


@test("AT-F2-F3", "F2 transactions (R12, provenance, masking, calendar) and F3 income/expense (R05/R07/R08)")
def t_f23(server, ev):
    H = world(server, "bnx_c12f23")
    f2o = call(H, "q_f2_transactions", account_currency_id=H.cad["account_currency_id"], date_from="2026-01-01", date_to="2026-01-31")
    f2m = call(H, "q_f2_transactions", H.member, account_currency_id=H.cad["account_currency_id"], date_from="2026-01-01", date_to="2026-01-31")
    f3o = call(H, "q_f3_income_expense", date_from="2026-01-01", date_to="2026-01-31")
    f3m = call(H, "q_f3_income_expense", H.member, date_from="2026-01-01", date_to="2026-01-31")
    H.close()
    json.dump({"f2o": f2o, "f2m": f2m, "f3o": f3o, "f3m": f3m}, open(os.path.join(ev, "AT-F2-F3.json"), "w"), indent=1, default=str)
    # cad journals in January: opening (01-01), J1, J2, J4, J5, J6, J7 = 7
    check(len(f2o["rows"]) == 7 and len(f2m["rows"]) == 7, f"{len(f2o['rows'])} {len(f2m['rows'])}")
    rep = next(r for r in f2m["rows"] if r["economic_type"] == "card_repayment")
    check(any(l.get("masked") for l in rep["lines"]) and rep["flow_class"] == "CARD_REPAYMENT", f"{rep}")
    cal = {c["date"]: (c["inflow"], c["outflow"]) for c in f2o["calendar"]}
    check(cal["2026-01-10"] == ("3000.0000", "0") and cal["2026-01-28"] == ("0", "-300.0000"), f"{cal}")
    # F3 owner: income 3000 (salary); expense 200 + 150 = 350 groceries; operating net 2650
    t = f3o["totals_by_currency"]["CAD"]
    check(t["operating_income"] == "3000.0000" and t["operating_expense"] == "350.0000" and t["operating_net"] == "2650.0000", f"{t}")
    # member: the card purchase (private account) is absent -> expense 200, net 2800
    tm = f3m["totals_by_currency"]["CAD"]
    check(tm["operating_expense"] == "200.0000" and tm["operating_net"] == "2800.0000", f"{tm}")
    return ("F2 lists the 7 cad journals with economic type, flow class and lines; a member sees the card repayment on cad with the "
            "card line masked; calendar inflow/outflow per day; F3: income 3000, expenses 350, net 2650 for the owner, and the "
            "private card purchase is absent from the member's totals (expenses 200, net 2800)")


@test("AT-P0-R09", "R09 cash flow: operating vs transfer / investing / financing / card repayment; opening + flows = closing")
def t_r09(server, ev):
    H = world(server, "bnx_c12r09")
    cf = call(H, "q_cashflow_statement", date_from="2026-01-02", date_to="2026-01-31")
    H.close()
    json.dump(cf, open(os.path.join(ev, "AT-P0-R09.json"), "w"), indent=1, default=str)
    c = cf["by_currency"]["CAD"]
    # liquid CAD = cad + sav: opening (01-01) 1000 + 500 = 1500; closing 2000 + 1200 = 3200
    # OPERATING +3000 -200 = 2800; CARD_REPAYMENT -100; TRANSFER (J5, J7 on both liquid sides) in 700 out -700 net 0; INVESTING -1000
    # 1500 + 2800 - 100 + 0 - 1000 = 3200
    f = c["flows"]
    check(c["opening"] == "1500.0000" and c["closing"] == "3200.0000" and c["reconciles"] is True, f"{c}")
    check(f["OPERATING"] == {"inflow": "3000.0000", "outflow": "-200.0000", "net": "2800.0000"} and f["CARD_REPAYMENT"]["net"] == "-100.0000"
          and f["TRANSFER"] == {"inflow": "700.0000", "outflow": "-700.0000", "net": "0.0000"} and f["INVESTING"]["net"] == "-1000.0000"
          and c["operating_net"] == "2800.0000", f"{f}")
    check(cf["by_currency"]["USD"]["reconciles"] is True and cf["by_currency"]["USD"]["flows"] == {}, f"{cf['by_currency']['USD']}")
    return ("operating net 2800 (salary 3000, groceries -200) stays apart from the card repayment (-100), transfers (gross 700 each way, "
            "net 0) and the investment subscription (-1000); the card purchase does not move cash; opening 1500 + flows = closing 3200")


@test("AT-F4-F5-F6", "F4 investments, F5 net worth with R28 elimination and ownership (R01, R27, R28), F6 cards (R17, R19-R21)")
def t_f456(server, ev):
    H = world(server, "bnx_c12f456")
    X = "44444444-4444-4444-8444-444444444444"
    H.cmd(H.owner, "record_investment_lot", account_currency_id=H.inv["account_currency_id"], instrument_id=X, units="100", cost="1000.00",
          acquired_on="2026-01-25", source_journal_id=H.j["J6"])
    H.cmd(H.owner, "record_valuation", instrument_id=X, valuation_date="2026-01-31", price="10.50", currency="CAD", source="Synthetic NAV")
    H.cmd(H.owner, "set_card_fee_policy", card_account_id=H.card_acc, effective_from="2026-01-01", annual_fee="120.00", currency="CAD",
          period_rule="CALENDAR_YEAR", criteria={"qualifying_spend": "1000.00"}, issuer_confirmed=False, evidence_ref=EVID)
    out = {"f4": call(H, "q_f4_investments", as_of="2026-01-31", date_from="2026-01-02"),
           "f5": call(H, "q_f5_networth", as_of="2026-01-31", reporting_currency="USD"),
           "f5 member": call(H, "q_f5_networth", H.member, as_of="2026-01-31"),
           "f6": call(H, "q_f6_cards", as_of="2026-01-31")}
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-F4-F5-F6.json"), "w"), indent=1, default=str)
    acc = out["f4"]["accounts"][0]
    # 100 units x 10.50 = 1050.00; cost 1000.00; unrealized 50.00; one subscription movement
    check(acc["totals"] == {"cost_remaining": "1000.00", "realized_confirmed": "0.00", "realized_estimated": "0.00", "market_value": "1050.00",
                            "unrealized": "50.00"} and len(acc["movements"]) == 1 and "MATURITIES_NOT_MODELLED" in out["f4"]["scope_warnings"], f"{acc['totals']}")
    t = out["f5"]["totals_by_currency"]["CAD"]
    # R28 pair eliminated: assets cad 2000 + sav 1200 + inv 1000 = 4200; liabilities card -50; net 4150; eliminated 300 - 300 = 0
    check(t == {"assets": "4200.0000", "liabilities": "-50.0000", "net_worth": "4150.0000", "eliminated_r28": "0.0000"}, f"{t}")
    check(out["f5"]["reporting"]["net_worth"] == "3212.50", f"{out['f5']['reporting']}")          # 4150 x 0.75 + 100
    own = {(x["party_id"], x["currency"]): x["net"] for x in out["f5"]["by_owner"]}
    check(own[(H.lender, "CAD")] == "2000.0000" and own[("unknown", "CAD")] == "2150.0000", f"{own}")   # cad owned by lender; rest unknown
    tm = out["f5 member"]["totals_by_currency"]["CAD"]
    check(tm["liabilities"] == "0.0000" and tm["net_worth"] == "4200.0000", f"{tm}")                   # the private card is absent
    c = out["f6"]["cards"][0]
    # owed 50.00; repayments 100 (no statement yet); fee progress: spend 150 of 1000 -> NOT_YET_QUALIFIED
    check(c["owed"] == "50.00" and c["repayments_since_statement"] == "100.0000" and c["annual_fee"]["progress"]["spend"] == "150.00"
          and c["annual_fee"]["calculated"]["status"] == "NOT_YET_QUALIFIED" and "DUE_DATE_NOT_MODELLED" in out["f6"]["scope_warnings"], f"{c}")
    return ("F4: 100 units at NAV 10.50 = 1050.00 against cost 1000.00 (unrealized 50.00) with the subscription movement; F5: the "
            "R28 receivable and payable (both household) are eliminated, net worth 4150 (USD 3212.50), cad attributed to its verified "
            "owner and the rest to 'unknown', the private card absent for a member; F6: owed 50.00, repayments 100, annual-fee spend "
            "150 of 1000 not yet qualified, due dates flagged as not modelled")


@test("AT-F7-P0", "F7 (R13, R14, R15) and P0 cases R11, R13, R15, R30, R31")
def t_f7(server, ev):
    H = world(server, "bnx_c12f7")
    out = {}
    # R15: January and March final, February missing, April partial (no closing) -> gap Feb, April never final
    s1 = C10.stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "2000.00")
    C10.stmt(H, H.cad, "2026-03-01", "2026-03-31", "2000.00", "2000.00")
    C10.stmt(H, H.cad, "2026-04-01", "2026-04-30", "2000.00", None)
    for jid, d, amt in (("J1", "2026-01-10", "3000.00"), ("J2", "2026-01-12", "-200.00"), ("J4", "2026-01-20", "-100.00"), ("J5", "2026-01-22", "-400.00"),
                        ("J6", "2026-01-25", "-1000.00"), ("J7", "2026-01-28", "-300.00")):
        C10.row(H, H.cad, d, amt, link=H.j[jid])
    run = H.cmd(H.owner, "run_reconciliation", statement_id=s1)
    # R13 / R30: an unmatched transfer-like row and an ambiguous ledger match in April
    p1 = C11.post(H, "2026-04-03", "-25.00", H.cad, desc="A"); C11.post(H, "2026-04-04", "-25.00", H.cad, desc="B")
    amb = C10.row(H, H.cad, "2026-04-03", "-25.00", desc="PARKING")
    C10.row(H, H.cad, "2026-04-10", "-75.00", desc="E-TRANSFER OUT")
    C11.match(H, H.cad)
    f7 = call(H, "q_f7_reconciliation", account_currency_id=H.cad["account_currency_id"])
    q1 = call(H, "q_r30_review_queue")
    out.update(run=run, f7=f7, queue_before=q1["counts"])
    with H.definer() as cx:
        legs = [str(r[0]) for r in cx.execute("select jl.id from bnx.journal_line jl join bnx.journal_entry je on je.id = jl.journal_id where "
                                              "jl.ledger_account_id = %s and jl.amount = -25.00 order by je.posting_date", (H.cad["ledger_account_id"],))]
        no_dismiss = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' "
                                "and p.proname ~ '(dismiss|skip|bypass).*(queue|review)|review_queue_(set|clear)'").fetchone()[0]
    H.cmd(H.owner, "decide_match", source_txn_id=amb, kind="ledger", decision="confirmed", journal_line_id=legs[0])
    out["queue_after"] = call(H, "q_r30_review_queue")["counts"]
    # R31: source row -> statement -> evidence -> journal -> correction -> snapshot
    snap = H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", as_of="2026-01-31")["snapshot_id"]
    H.cmd(H.owner, "correct_transaction", journal_id=H.j["J2"], reason="synthetic amount fix", replacement={
        "transaction_date": "2026-01-12", "description": "fixed", "lines": [
            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "210.00"},
            {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-210.00"}]})
    with H.definer() as cx:
        src = str(cx.execute("select id from bnx.source_txn where amount = -200.00").fetchone()[0])
    out["trace"] = call(H, "q_evidence_trace", source_txn_id=src)
    out["trace member card"] = expect_err(call, "NOT_AVAILABLE", H, "q_evidence_trace", H.member, journal_id=H.j["J3"])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-F7-P0.json"), "w"), indent=1, default=str)
    cov = f7["coverage"][0]
    check(cov["gaps"] == [{"from": "2026-02-01", "to": "2026-02-28"}] and any(s["partial"] and not s["final"] for s in cov["statements"])
          and run["stage2_state"] == "matched", f"{cov} {run}")                                                   # R15
    check(f7["transfer_matching"]["decisions_by_state"] in ({"clearing_post": 1}, {}), f"{f7['transfer_matching']}")   # R13 (MR-12 has no kind)
    check(out["queue_before"].get("match_decision_pending") == 1 and out["queue_before"].get("unmatched_source_row", 0) >= 1, f"{out['queue_before']}")
    check("match_decision_pending" not in out["queue_after"] and no_dismiss == 0, f"{out['queue_after']} {no_dismiss}")   # R30
    t = out["trace"]
    check(t["journal_id"] == H.j["J2"] and t["source_rows"][0]["statements"][0]["statement_id"] == s1 and len(t["corrections"]) == 1
          and t["snapshots"][0]["snapshot_id"] == snap and len(t["evidence_refs"]) == 1, f"{t}")                    # R31
    return ("R15: January and March final, February a gap, April partial and never final; R14: the January statement reconciles (matched); "
            "R13/R30: the ambiguous match and the unmatched rows are queued and leave the queue only through the matching decision (no "
            "dismiss path exists); R31: a statement row traces to its statement, evidence, journal, its correction and the snapshot "
            "that included it; a member cannot trace a private-card journal")


@test("AT-RPT-STALE", "OR-R-05 snapshot status (AT-RPT-STALE-01...05): CURRENT, STALE reasons, ACCESS_REVOKED; over-invalidation only")
def t_stale(server, ev):
    H = world(server, "bnx_c12stale")
    st = lambda s, cred=None: call(H, "q_snapshot_status", cred, snapshot_id=s)
    snap = lambda cred=None, **kw: H.cmd(cred or H.owner, "create_report_snapshot", report_code="R-BAL", as_of="2026-01-31", **kw)["snapshot_id"]
    out = {}
    s1 = snap(account_currency_ids=[H.cad["account_currency_id"]])
    out["01 fresh"] = st(s1)
    post(H, "consumption_expense", "2026-02-05", [(H.groceries, "10.00"), (H.cad["ledger_account_id"], "-10.00")])          # after as_of
    post(H, "consumption_expense", "2026-01-30", [(H.groceries, "5.00"), (H.sav["ledger_account_id"], "-5.00")])           # other account
    out["02 later posting, other account"] = st(s1)
    post(H, "consumption_expense", "2026-01-29", [(H.groceries, "7.00"), (H.cad["ledger_account_id"], "-7.00")])           # backdated, in scope
    out["03 backdated posting"] = st(s1)
    s2 = snap(account_currency_ids=[H.sav["account_currency_id"]])
    H.cmd(H.owner, "correct_transaction", journal_id=H.j["J5"], reason="synthetic", replacement={"transaction_date": "2026-01-22", "description": "fixed",
          "lines": [{"ledger_account_id": H.sav["ledger_account_id"], "currency": "CAD", "amount": "401.00"},
                    {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-401.00"}]})
    out["04 backdated correction"] = st(s2)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.card_acc, can_view=True, can_post=False)
    s3 = snap(H.member, account_currency_ids=[H.card["account_currency_id"]])
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.card_acc, can_view=False, can_post=False)
    out["05 grant revoked"] = st(s3, H.member)
    out["other member's snapshot"] = expect_err(st, "NOT_AVAILABLE", s1, H.member)
    out["list"] = {x["snapshot_id"]: x["status"] for x in call(H, "q_snapshot_list")["snapshots"]}
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-RPT-STALE.json"), "w"), indent=1, default=str)
    check(out["01 fresh"]["status"] == "CURRENT" and out["01 fresh"]["definition_version"] == "R-BAL/1", f"{out['01 fresh']}")
    check(out["02 later posting, other account"]["status"] == "CURRENT", f"{out['02 later posting, other account']}")
    check(out["03 backdated posting"]["status"] == "STALE" and "LEDGER_CHANGED_IN_SCOPE" in out["03 backdated posting"]["reasons"], f"{out}")
    check(out["04 backdated correction"]["status"] == "STALE" and "BACKDATED_CORRECTION" in out["04 backdated correction"]["reasons"], f"{out}")
    check(out["05 grant revoked"] == {"snapshot_id": s3, "status": "ACCESS_REVOKED"}, f"{out['05 grant revoked']}")
    check(out["list"].get(s1) == "STALE" and out["list"].get(s2) == "STALE" and s3 not in out["list"], f"{out['list']}")
    return ("a fresh snapshot is CURRENT with its definition version; a posting after the as-of date or on another account keeps it "
            "CURRENT; a backdated posting in scope makes it STALE (LEDGER_CHANGED_IN_SCOPE); a backdated correction makes it STALE "
            "(BACKDATED_CORRECTION); a revoked grant gives ACCESS_REVOKED and nothing else; another member's snapshot is NOT_AVAILABLE")


@test("AT-ARCH-ACL", "O-4 artifact facts (AT-ARCH-ACL-01, -02, -04) and AT-SNAP-03/04 under module toggles")
def t_arch(server, ev):
    H = world(server, "bnx_c12arch")
    out = {}
    s = H.cmd(H.member, "create_report_snapshot", report_code="R-BAL", as_of="2026-01-31", account_currency_ids=[H.cad["account_currency_id"]])["snapshot_id"]
    out["not rendered"] = expect_err(call, "ARTIFACT_NOT_RENDERED", H, "q_snapshot_artifact", H.member, snapshot_id=s)
    art = {"artifact_ref": "drive:System_Outputs/Report_Archive/2026/synthetic.pdf", "artifact_sha256": "ab" * 32, "renderer_version": "r1.0",
           "source_revision": 1, "ownership_revision": 1, "warnings": []}
    out["app cannot record"] = None
    try:
        H.app.call("wrk_snapshot_artifact", s, art); out["app cannot record"] = "ALLOWED"
    except psycopg.Error as e:
        out["app cannot record"] = type(e).__name__
    out["bad hash"] = expect_err(H.worker.call, "VALIDATION_FAILED", "wrk_snapshot_artifact", s, {**art, "artifact_sha256": "xyz"})
    H.worker.call("wrk_snapshot_artifact", s, art)
    out["01 read"] = call(H, "q_snapshot_artifact", H.member, snapshot_id=s)
    out["04 other member"] = expect_err(call, "NOT_AVAILABLE", H, "q_snapshot_artifact", H.owner, snapshot_id=s)
    # AT-SNAP-03/04: digests verify at every step while a module toggles; the Canada account's snapshot is revoked while Canada is off
    rp = lambda: call(H, "q_replay_snapshot", H.member, snapshot_id=s)["projection_digest_verified"]
    out["replay 0"] = rp()
    C2.set_modules(H, {"Canada": "YES", "International": "NO", "CRA": "YES"}, "4" * 64); out["International NO"] = rp()
    C2.set_modules(H, {"Canada": "YES", "International": "YES", "CRA": "YES"}, "5" * 64); out["International YES"] = rp()
    C2.set_modules(H, {"Canada": "NO", "International": "YES", "CRA": "YES"}, "6" * 64)
    out["02 Canada NO: artifact"] = expect_err(call, "ACCESS_REVOKED", H, "q_snapshot_artifact", H.member, snapshot_id=s)
    out["02 Canada NO: status"] = call(H, "q_snapshot_status", H.member, snapshot_id=s)["status"]
    C2.set_modules(H, {"Canada": "YES", "International": "YES", "CRA": "YES"}, "7" * 64); out["Canada YES again"] = rp()
    with H.definer() as cx:
        try:
            cx.execute("update bnx.report_snapshot_artifact set artifact_sha256 = repeat('0', 64)"); out["update"] = "ALLOWED"
        except psycopg.Error as e:
            out["update"] = (e.diag.message_primary or "")[:40]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-ARCH-ACL.json"), "w"), indent=1, default=str)
    check(out["app cannot record"] == "InsufficientPrivilege" and out["01 read"]["artifact_sha256"] == "ab" * 32
          and out["01 read"]["status"] == "CURRENT", f"{out}")
    check(all(out[k] is True for k in ("replay 0", "International NO", "International YES", "Canada YES again"))
          and out["02 Canada NO: status"] == "ACCESS_REVOKED" and out["update"] != "ALLOWED", f"{out}")
    return ("an artifact is recorded only by the worker (app role refused, hash format checked) and append-only; the snapshot owner reads "
            "its reference with the status; another member gets NOT_AVAILABLE; while the snapshot's region is disabled the artifact is "
            "ACCESS_REVOKED and no reference is disclosed; the projection digest verifies at every module toggle step")


@test("AT-9013-CAT", "9013 catalog: report_definition rows, function catalog, grants, report_snapshot untouched")
def t_cat(server, ev):
    db = "bnx_c12cat"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        defs = [r[0] for r in cx.execute("select report_id || '/' || version from bnx.report_definition order by 1").fetchall()]
        fs = cx.execute("select count(*) from bnx.function_scope where function_name in ('q_f1_balances','q_f2_transactions','q_f3_income_expense',"
                        "'q_f4_investments','q_f5_networth','q_f6_cards','q_f7_reconciliation','q_cashflow_statement','q_r30_review_queue',"
                        "'q_evidence_trace','q_snapshot_status','q_snapshot_list','q_snapshot_artifact')").fetchone()[0]
        g = cx.execute("select p.proname, has_function_privilege('bnx_app', p.oid, 'execute'), has_function_privilege('bnx_worker', p.oid, 'execute') from pg_proc p "
                       "join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and p.proname in ('q_f5_networth','wrk_snapshot_artifact','rpt_envelope') "
                       "order by 1").fetchall()
        cols = cx.execute("select count(*) from information_schema.columns where table_schema = 'bnx' and table_name = 'report_snapshot'").fetchone()[0]
    check(defs == ["F1/1", "F2/1", "F3/1", "F4/1", "F5/1", "F6/1", "F7/1", "R-BAL/1", "R09/1", "R28/1", "R30/1", "R31/1"] and fs == 13, f"{defs} {fs}")
    check(g == [("q_f5_networth", True, False), ("rpt_envelope", False, False), ("wrk_snapshot_artifact", False, True)], f"{g}")
    return (f"12 versioned report definitions (R-BAL/1 kept); 13 queries in the function catalog; queries granted to bnx_app, the "
            f"artifact writer to bnx_worker only, helpers to nobody; report_snapshot keeps its R1 shape ({cols} columns)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core12", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core12_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
