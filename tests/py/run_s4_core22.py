#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 findings of the first live AI run (migration 9046; F-LIVE-1, F-LIVE-2, F-LIVE-5 of 2026-11-20): hold texts that say
where the problem is (V-04 figures, V-09 item numbers, V-12 items and opening date), the member's line review of a statement
draft in the PWA (cmd_review_statement_items: category, other account for a card payment, reviewed; a new version keeps
kind and AI connection; refusals), and set_opening's amount in the catalog schema. Synthetic data only.
Usage: run_s4_core22.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core20 as C20
import run_s4_core21 as C21

RESULTS, TESTS = [], []
check, expect_err = C1.check, C1.expect_err


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def setup(server, db):
    """A household with chequing (opening 1000 at 2026-01-01), a card (opening -250 at 2026-03-01), the default categories
    and an AI connection that sees both accounts."""
    H = C20.household(server, db)
    H.cmd(H.owner, "set_opening", account_currency_id=H.card["account_currency_id"], anchor_date="2026-03-01", amount="-250.00")
    C21.defaults(H)
    H.cats = {c["name_en"]: c["ledger_account_id"] for c in H.q(H.owner, "ledger_accounts")["categories"] if c["currency"] == "CAD"}
    H.B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[H.cad["account_currency_id"], H.card["account_currency_id"]])
    return H


def march(H):
    """The card's March statement as an unsure AI submits it: every line marked for review, the payment under a guessed category."""
    lines = [C20.ln(H, "2026-03-05", "85.40", "SYNTHETIC GROCER", H.cats["Groceries"], economic_type="card_spend", needs_review=True),
             C20.ln(H, "2026-03-15", "-250.00", "PAYMENT - THANK YOU", H.cats["Other Income"], needs_review=True),
             C20.ln(H, "2026-03-20", "23.75", "SYNTHETIC DRUG STORE", H.cats["Pharmacy"], economic_type="card_spend", needs_review=True)]
    return C20.stmt(H, H.B, "2026-03-01", "2026-03-31", "250.00", "109.15", lines, ac=H.card, sign="owed_positive", account_last4="4321")


@test("AT-HOLD-01", "F-LIVE-1; 9046 (hold texts say where: V-04 opening + lines = result against the closing, V-09 the item "
                    "numbers, V-12 the items and the opening date they fall before, without naming the other account; codes unchanged)")
def t_holds(server, ev):
    H = setup(server, "bnx_c22hold")
    out = {}
    m = march(H)
    out["march"] = (m["hold_reasons"], m["validation_result"]["V-09"], m["validation_result"]["V-07"][:22])
    # February, before the card's opening anchor, with a misread closing balance
    f = C20.stmt(H, H.B, "2026-02-01", "2026-02-28", "100.00", "999.00",
                 [C20.ln(H, "2026-02-10", "20.00", "SYNTHETIC CAFE", H.cats["Restaurants"], economic_type="card_spend")],
                 ac=H.card, sign="owed_positive")
    out["february"] = (f["hold_reasons"], f["validation_result"]["V-04"], f["validation_result"]["V-12"])
    # the same texts reach the draft screen of the PWA and the AI
    out["screen"] = [H.q(c, "draft_get_for_confirmation", plan_id=f["plan_id"])["validation_result"]["V-12"] for c in (H.owner, H.B)]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-HOLD-01.json"), "w"), indent=1, default=str)
    check(out["march"] == (["ECONOMIC_TYPE", "REVIEW_QUEUE"], "HOLD:REVIEW_QUEUE (seq 1, 2, 3)", "HOLD:ECONOMIC_TYPE (se"), f"march {out['march']}")
    check(out["february"] == (["BALANCE_CHAIN", "BEFORE_OPENING"],
                              "HOLD:BALANCE_CHAIN (ledger sign: opening -100 + lines -20 = -120, closing -999)",
                              "HOLD:BEFORE_OPENING (seq 1 2026-02-10 before opening 2026-03-01)"), f"february {out['february']}")
    check(out["screen"] == [out["february"][2]] * 2, f"screen {out['screen']}")
    return "V-04 figures, V-09 seq 1, 2, 3, V-12 seq and opening date; the same text on the PWA and MCP draft screens"


@test("AT-REV-01", "F-LIVE-2, G3; 9046 (the member reviews an AI statement draft line by line: a category, the other account for "
                   "the card payment (typed card_repayment), reviewed; a new version without holds supersedes the old, keeps kind "
                   "ai_draft and the AI connection; dates, amounts and fingerprints unchanged; approved and posted)")
def t_review(server, ev):
    H = setup(server, "bnx_c22rev")
    out = {}
    m = march(H)
    d = H.q(H.owner, "draft_get_for_confirmation", plan_id=m["plan_id"])
    out["reviewable"] = (d["reviewable_by_me"], d["approvable_by_me"], H.q(H.B, "draft_get_for_confirmation", plan_id=m["plan_id"])["reviewable_by_me"])
    before = C4.sql(H, "select seq, payload->>'transaction_date', payload->>'amount', payload->>'source_fingerprint' "
                       "from bnx.posting_plan_item where plan_id = %s order by seq", (m["plan_id"],))
    r = H.cmd(H.owner, "review_statement_items", plan_id=m["plan_id"], plan_hash=m["plan_hash"], changes=[
        {"seq": 1, "reviewed": True},
        {"seq": 2, "counter_ledger_account_id": H.cad["ledger_account_id"], "reviewed": True},
        {"seq": 3, "counter_ledger_account_id": H.cats["Personal Care"], "reviewed": True}])
    out["result"] = (r["kind"], r["hold_reasons"], r["changed"], r["continuity"]["status"])
    out["old"] = C4.one(H, "select state from bnx.posting_plan where id = %s", (m["plan_id"],))[0]
    out["new"] = C4.one(H, "select supersedes_plan_id::text, origin_ai_connection_id = (select origin_ai_connection_id from bnx.posting_plan "
                           "where id = %s), scope->'statement'->>'printed_closing' from bnx.posting_plan where id = %s", (m["plan_id"], r["plan_id"]))
    after = C4.sql(H, "select seq, payload->>'transaction_date', payload->>'amount', payload->>'source_fingerprint' "
                      "from bnx.posting_plan_item where plan_id = %s order by seq", (r["plan_id"],))
    out["evidence kept"] = before == after
    items = {i["seq"]: i for i in H.q(H.owner, "draft_get_for_confirmation", plan_id=r["plan_id"])["items"]}
    out["payment"] = (items[2]["economic_type"], sorted((l["ledger_account_name"], l["amount"]) for l in items[2]["lines"]),
                      "needs_review" in items[2]["payload"])
    out["drug store"] = [l["ledger_account_name"] for l in items[3]["lines"]]
    out["ai sees new"] = H.q(H.B, "draft_get_for_confirmation", plan_id=r["plan_id"])["plan_id"] == r["plan_id"]
    out["audit"] = C4.one(H, "select count(*) from bnx.audit_event where command = 'review_statement_items'")[0]
    chq0 = H.balance(H.owner, {"account_currency_id": H.cad["account_currency_id"]}, as_of="2026-03-31")
    out["run"] = C20.approve_run(H, r)[-1]
    out["card"] = H.balance(H.owner, {"account_currency_id": H.card["account_currency_id"]}, as_of="2026-03-31")
    chq1 = H.balance(H.owner, {"account_currency_id": H.cad["account_currency_id"]}, as_of="2026-03-31")
    out["chequing delta"] = str(float(chq1) - float(chq0))
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-REV-01.json"), "w"), indent=1, default=str)
    check(out["reviewable"] == (True, False, False), f"reviewable {out['reviewable']}")
    check(out["result"] == ("ai_draft", [], 3, "first") and out["old"] == "superseded", f"result {out['result']} old {out['old']}")
    check(out["new"] == (m["plan_id"], True, "109.15") and out["evidence kept"], f"new {out['new']} kept {out['evidence kept']}")
    check(out["payment"] == ("card_repayment", [("Chequing", "-250"), ("Synthetic card", "250")], False), f"payment {out['payment']}")
    check(out["drug store"] == ["Synthetic card", "Personal Care"],
          f"drug store {out['drug store']}")
    check(out["ai sees new"] and out["audit"] == 1 and out["run"] == "activated", f"ai {out['ai sees new']} audit {out['audit']} run {out['run']}")
    check(out["card"] in ("-109.15", "-109.1500") and out["chequing delta"] == "-250.0", f"card {out['card']} chequing {out['chequing delta']}")
    return "3 lines reviewed (reviewed, card payment to chequing, Personal Care) -> new ai_draft without holds -> posted: card -109.15, chequing -250"


@test("AT-REV-02", "F-LIVE-2; 9046 (refusals: an AI connection, a stale or wrong plan_hash, a superseded plan, a change to amount or "
                   "an unknown field, an unknown or repeated line, a category in another currency, a system account, a plan "
                   "that is not a statement; nothing changes)")
def t_refusals(server, ev):
    H = setup(server, "bnx_c22ref")
    usd_cat = H.cmd(H.owner, "create_category", kind="expense", currency="USD", name_en="Synthetic USD cost", name_zh="合成美元支出")
    usd_cat = usd_cat.get("ledger_account_id") or usd_cat.get("id")
    eq = C4.one(H, "select id::text from bnx.ledger_account where kind = 'equity' and currency = 'CAD' limit 1")[0]
    m = march(H)
    base = dict(plan_id=m["plan_id"], plan_hash=m["plan_hash"])
    one = [{"seq": 1, "reviewed": True}]
    out = {"refusals": [
        expect_err(H.cmd, "FORBIDDEN_CHANNEL", H.B, "review_statement_items", changes=one, **base),
        expect_err(H.cmd, "PLAN_DIGEST_MISMATCH", H.owner, "review_statement_items", plan_id=m["plan_id"], plan_hash="0" * 64, changes=one),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=[{"seq": 1, "amount": "1.00"}], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=[{"seq": 99, "reviewed": True}], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=one + one, **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=[{"seq": 1}], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=[], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items",
                   changes=[{"seq": 1, "counter_ledger_account_id": usd_cat}], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items", changes=[{"seq": 1, "counter_ledger_account_id": eq}], **base),
        expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "review_statement_items",
                   changes=[{"seq": 1, "economic_type": "opening_balance"}], **base)]}
    out["unchanged"] = C4.one(H, "select state from bnx.posting_plan where id = %s", (m["plan_id"],))[0]
    tx = H.cmd(H.owner, "draft_create_transaction", account_currency_id=H.cad["account_currency_id"], transaction_date="2026-03-06",
               economic_type="consumption_expense", amount="-5.00", counter_ledger_account_id=H.groceries, description="synthetic")
    out["not a statement"] = expect_err(H.cmd, "NOT_AVAILABLE", H.owner, "review_statement_items", plan_id=tx["plan_id"],
                                        plan_hash=tx["plan_hash"], changes=one)
    r = H.cmd(H.owner, "review_statement_items", changes=one, **base)
    out["superseded"] = expect_err(H.cmd, "PLAN_NOT_REVISABLE", H.owner, "review_statement_items", changes=one, **base)
    out["after"] = (r["hold_reasons"], C4.one(H, "select count(*) from bnx.posting_plan where supersedes_plan_id = %s", (m["plan_id"],))[0])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-REV-02.json"), "w"), indent=1, default=str)
    check(len(out["refusals"]) == 10 and out["unchanged"] == "frozen", f"refusals {len(out['refusals'])} state {out['unchanged']}")
    check(out["after"] == (["ECONOMIC_TYPE", "REVIEW_QUEUE"], 1), f"after {out['after']}")
    return "10 refusals leave the draft as it was; a statement-less plan is not available; a superseded version cannot be reviewed"


@test("AT-OPEN-02", "F-LIVE-5; 9046 (set_opening's catalog input schema carries amount as a decimal, so the PWA form offers it; "
                    "an existing account's opening moves earlier through the Gateway; cmd_post_transaction's original_amount numeric)")
def t_opening(server, ev):
    H = setup(server, "bnx_c22open")
    out = {}
    cat = {}
    for fn in ("cmd_set_opening", "cmd_post_transaction"):
        cat[fn] = json.loads(C4.one(H, "select obj_description(%s::regprocedure, 'pg_proc')", (f"bnx.{fn}(jsonb,jsonb)",))[0])
    out["amount"] = cat["cmd_set_opening"]["input_schema"]["properties"].get("amount")
    out["original_amount"] = cat["cmd_post_transaction"]["input_schema"]["properties"].get("original_amount")
    r = H.app.call("cmd_set_opening", H.owner, {"account_currency_id": H.card["account_currency_id"], "anchor_date": "2026-02-01",
                                                 "amount": "-100.00", "idempotency_key": "open-moved-0001"})
    out["moved"] = C4.one(H, "select anchor_date::text, amount::text from bnx.opening_anchor_version where account_currency_id = %s "
                             "order by revision desc limit 1", (H.card["account_currency_id"],))
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-OPEN-02.json"), "w"), indent=1, default=str)
    dec = {"pattern": "^-?[0-9]{1,24}(\\.[0-9]{1,12})?$", "type": ["number", "string"]}
    check(out["amount"] == dec and out["original_amount"] == dec, f"schemas {out['amount']} {out['original_amount']}")
    check(isinstance(r, dict) and out["moved"] == ("2026-02-01", "-100.0000"), f"moved {out['moved']} {r}")
    return "amount and original_amount are decimals in the catalog; the card's opening moved from 03-01 to 02-01 through the Gateway"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core22", a.server)
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
    summary = {"server": a.server, "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core22_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
