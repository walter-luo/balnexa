#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 AI-first statement intake tests (migration 9043; docs/s4/S4_AI_First_Workflows_Design_2026-11-16.md G1, G4, G7):
cmd_draft_statement, the V-04 balance chain and V-11 continuity, gap explanations, history order, q_statement_chain,
q_ledger_accounts on MCP, the curated output schemas of the three tools. Synthetic data only.
Usage: run_s4_core20.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core19 as C19
import run_s4_core18 as C18

RESULTS, TESTS = [], []
check, expect_err = C1.check, C1.expect_err
OUT_9043 = ["cmd_draft_statement", "q_statement_chain", "q_ledger_accounts"]


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def household(server, db):
    H = C4.v2_full(server, db)
    r = H.cmd(H.owner, "create_account", kind="credit_card", **H.inst("Synthetic Bank"), label="Synthetic card", currencies=["CAD"])
    H.card = r["account_currencies"][0]
    return H


def stmt(H, cred, pf, pt, op, cl, lines, ac=None, sign="asset_positive", **kw):
    ac = ac or H.cad
    return H.cmd(cred, "draft_statement", account_currency_id=ac["account_currency_id"], period_from=pf, period_to=pt,
                 opening_balance=op, closing_balance=cl, sign_convention=sign, lines=lines, **kw)


def ln(H, d, amt, desc="Synthetic grocery", cat=None, **kw):
    return {"date": d, "amount": amt, "description": desc, "counter_ledger_account_id": cat or H.groceries, **kw}


def approve_run(H, p):
    C4.approve(H, H.owner, p)
    return C4.run_plan(H, p["plan_id"])


@test("AT-STM-01", "G1, G4; 9043 (an AI host submits a statement whole; the database checks the balance chain, duplicates and "
                   "continuity; the AI cannot approve; the Owner approves in the PWA; refusals; owed-positive statements)")
def t_statement(server, ev):
    H = household(server, "bnx_c20stm")
    cad = H.cad["account_currency_id"]
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad, H.card["account_currency_id"]])
    out = {}
    # G4: the AI finds its accounts and categories
    la = H.q(B, "ledger_accounts")
    out["ledger_accounts"] = (sorted(a["account_currency_id"] for a in la["accounts"]) == sorted([cad, H.card["account_currency_id"]])
                              and any(c["ledger_account_id"] == H.groceries for c in la["categories"]))
    # January: two identical lines on one day stay two rows (occurrence numbers); balance chain holds
    jan = stmt(H, B, "2026-01-01", "2026-01-31", "1000.00", "2950.00",
               [ln(H, "2026-01-05", "-25.00"), ln(H, "2026-01-05", "-25.00"), ln(H, "2026-01-15", "2000.00", "Synthetic payroll", H.salary)],
               institution="Synthetic Bank", account_last4="1234")
    out["jan"] = (jan["kind"], jan["hold_reasons"], jan["validation_result"]["V-04"], jan["validation_result"]["V-11"], jan["continuity"]["status"])
    fps = [r[0] for r in C4.sql(H, "select payload->>'source_fingerprint' from bnx.posting_plan_item where plan_id = %s order by seq", (jan["plan_id"],))]
    out["fingerprints distinct"] = len(set(fps)) == 3 and all(len(f) == 64 for f in fps)
    out["AI cannot approve"] = expect_err(H.cmd, "FORBIDDEN_CHANNEL", B, "approve_plan", plan_id=jan["plan_id"], plan_hash=jan["plan_hash"],
                                          scope_digest=jan["scope_digest"])
    out["jan run"] = approve_run(H, jan)[-1]
    out["balance 01-31"] = H.balance(H.owner, as_of="2026-01-31")
    # February with a misread closing balance: V-04 holds; the corrected statement replaces it
    feb_bad = stmt(H, B, "2026-02-01", "2026-02-28", "2950.00", "2900.00", [ln(H, "2026-02-03", "-40.00")])
    out["feb bad"] = (feb_bad["hold_reasons"], feb_bad["validation_result"]["V-04"])
    feb = stmt(H, B, "2026-02-01", "2026-02-28", "2950.00", "2910.00", [ln(H, "2026-02-03", "-40.00")], supersedes_plan_id=feb_bad["plan_id"])
    out["feb"] = (feb["hold_reasons"], feb["continuity"]["status"],
                  C4.one(H, "select state from bnx.posting_plan where id = %s", (feb_bad["plan_id"],))[0])
    out["feb run"] = approve_run(H, feb)[-1]
    # the same January again: duplicates and coverage
    again = stmt(H, B, "2026-01-01", "2026-01-31", "1000.00", "2950.00",
                 [ln(H, "2026-01-05", "-25.00"), ln(H, "2026-01-05", "-25.00"), ln(H, "2026-01-15", "2000.00", "Synthetic payroll", H.salary)])
    out["again"] = sorted(again["hold_reasons"])
    C4.sql(H, "select 1")
    H.cmd(B, "draft_withdraw", plan_id=again["plan_id"])
    # March opens with a different balance: a break holds until a member explains it
    mar = stmt(H, B, "2026-03-01", "2026-03-31", "2800.00", "2780.00", [ln(H, "2026-03-04", "-20.00")])
    out["mar"] = (mar["hold_reasons"], mar["validation_result"]["V-11"].split(" (")[0], mar["continuity"]["status"])
    out["AI cannot explain"] = expect_err(H.cmd, "FORBIDDEN", B, "explain_statement_gap", account_currency_id=cad,
                                          gap_from="2026-02-28", gap_to="2026-03-01", reason="statement_missing")
    H.cmd(H.owner, "explain_statement_gap", account_currency_id=cad, gap_from="2026-02-28", gap_to="2026-03-01",
          reason="other", note="synthetic: a correction posted outside the statements")
    v = H.cmd(B, "draft_validate", plan_id=mar["plan_id"])
    out["mar explained"] = (v["hold_reasons"], v["validation_result"]["V-11"])
    # May after a skipped April with matching balances: a gap is a finding, not a hold
    may = stmt(H, B, "2026-05-01", "2026-05-31", "2780.00", "2770.00", [ln(H, "2026-05-06", "-10.00")])
    out["may"] = (may["hold_reasons"], may["validation_result"]["V-11"], may["continuity"]["gap_from"], may["continuity"]["gap_to"])
    # a card statement as printed (owed positive): purchase +, payment -, turned to the ledger sign
    card = stmt(H, B, "2026-01-16", "2026-02-15", "0.00", "50.00", [
        ln(H, "2026-01-20", "80.00", "Synthetic card grocery"),
        {"date": "2026-02-01", "amount": "-30.00", "description": "Synthetic payment", "economic_type": "card_repayment",
         "lines": [{"ledger_account_id": H.card["ledger_account_id"], "currency": "CAD", "amount": "30.00"},
                   {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-30.00"}]}],
        ac=H.card, sign="owed_positive", account_last4="9876")
    st = C4.one(H, "select scope->'statement' from bnx.posting_plan where id = %s", (card["plan_id"],))[0]
    out["card"] = (card["hold_reasons"], st["opening"], st["closing"], st["printed_closing"], st["sign_convention"])
    # refusals
    base = dict(cred=B, pf="2026-06-01", pt="2026-06-30", op="2770.00", cl="2760.00")
    def bad(code, lines=None, **kw):
        return expect_err(stmt, code, H, base["cred"], kw.pop("pf", base["pf"]), kw.pop("pt", base["pt"]), base["op"], base["cl"],
                          [ln(H, "2026-06-02", "-10.00")] if lines is None else lines, **kw)
    out["refusals"] = [
        bad("VALIDATION_FAILED", lines=[ln(H, "2026-06-02", "-10.00", extra="x")]),
        bad("VALIDATION_FAILED", account_last4="12345"),
        bad("VALIDATION_FAILED", pf="2026-07-01"),
        bad("VALIDATION_FAILED", lines=[]),
        bad("VALIDATION_FAILED", sign="as_printed"),
        bad("VALIDATION_FAILED", lines=[ln(H, "2026-06-02", "-10.00", desc="  ")]),
        bad("PAN_CANDIDATE", lines=[ln(H, "2026-06-02", "-10.00", desc="card " + C18.synthetic_pan("4", 16, 7))]),
    ]
    other = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Other", currencies=["CAD"])["account_currencies"][0]
    out["not consented"] = expect_err(stmt, "NOT_AVAILABLE", H, B, "2026-06-01", "2026-06-30", "0", "0", [ln(H, "2026-06-02", "0.00")], ac=other)
    # the chain as the AI reads it
    ch = H.q(B, "statement_chain", account_currency_id=cad)
    out["chain"] = [(s["period_from"], s["state"], s["continuity"]["status"]) for s in ch["statements"]]
    out["notes"] = [(n["reason"], n["gap_from"], n["gap_to"]) for n in ch["gap_notes"]]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-STM-01.json"), "w"), indent=1, default=str)
    check(out["ledger_accounts"], "q_ledger_accounts over MCP")
    check(out["jan"] == ("ai_draft", [], "ok", "first", "first") and out["fingerprints distinct"], f"jan {out['jan']}")
    check(out["jan run"] == "activated" and out["balance 01-31"] in ("2950.00", "2950.0000", "2950"), f"jan run {out['jan run']} {out['balance 01-31']}")
    check(out["feb bad"] == (["BALANCE_CHAIN"], "HOLD:BALANCE_CHAIN"), f"feb bad {out['feb bad']}")
    check(out["feb"] == ([], "ok", "superseded") and out["feb run"] == "activated", f"feb {out['feb']} {out['feb run']}")
    check(out["again"] == ["COVERAGE", "DUPLICATE"], f"again {out['again']}")
    check(out["mar"] == (["BALANCE_BREAK"], "HOLD:BALANCE_BREAK", "break"), f"mar {out['mar']}")
    check(out["mar explained"] == ([], "explained"), f"mar explained {out['mar explained']}")
    check(out["may"] == ([], "FINDING:GAP (2026-04-01..2026-04-30)", "2026-04-01", "2026-04-30"), f"may {out['may']}")
    check(out["card"] == ([], "0", "-50", "50", "owed_positive"), f"card {out['card']}")
    check(out["chain"] == [("2026-01-01", "activated", "first"), ("2026-02-01", "activated", "ok"), ("2026-03-01", "frozen", "explained"),
                           ("2026-05-01", "frozen", "gap")], f"chain {out['chain']}")
    check(out["notes"] == [("other", "2026-02-28", "2026-03-01")], f"notes {out['notes']}")
    return ("AI statement draft: balance chain (V-04), duplicates and coverage (V-03/V-05), supersede, break held until explained "
            "(V-11), gap as a finding, owed-positive card statement in the ledger sign, 7 refusals incl. a card number, consent "
            "boundary, chain and notes read over MCP; the AI cannot approve or explain")


@test("AT-STM-02", "G7, W6; 9043 (history: statements submitted oldest first are checked against their pending predecessors and "
                   "approved together; a later statement that reopens an approved period is held)")
def t_history(server, ev):
    H = household(server, "bnx_c20hist")
    cad = H.cad["account_currency_id"]
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad])
    # the opening anchor is 2026-01-01: older statements are held before approval (V-12), not refused by the posting worker
    early = stmt(H, B, "2025-09-01", "2025-09-30", "520.00", "500.00", [ln(H, "2025-09-09", "-20.00")])
    H.cmd(B, "draft_withdraw", plan_id=early["plan_id"])
    # W6 step 2: the opening moves to the start of the earliest statement
    H.cmd(H.owner, "set_opening", account_currency_id=cad, anchor_date="2025-10-01", amount="500.00")
    months = [("2025-10-01", "2025-10-31", "500.00", "480.00", "2025-10-09"), ("2025-11-01", "2025-11-30", "480.00", "455.00", "2025-11-09"),
              ("2025-12-01", "2025-12-31", "455.00", "1000.00", "2025-12-09")]
    plans = []
    for pf, pt, op, cl, d in months:
        amt = f"{float(cl) - float(op):.2f}"
        cat = H.salary if float(amt) > 0 else H.groceries
        plans.append(stmt(H, B, pf, pt, op, cl, [ln(H, d, amt, "Synthetic history line", cat)]))
    pending = [(p["hold_reasons"], p["continuity"]["status"]) for p in plans]
    runs = [approve_run(H, p)[-1] for p in plans]
    chain = [(s["period_from"], s["state"], s["continuity"]["status"]) for s in H.q(H.owner, "statement_chain", account_currency_id=cad)["statements"]]
    # an overlapping later statement of an approved period is held (coverage)
    over = stmt(H, B, "2025-12-15", "2026-01-14", "1000.00", "990.00", [ln(H, "2026-01-02", "-10.00")])
    H.close()
    out = {"early": early["hold_reasons"], "pending": pending, "runs": runs, "chain": chain, "overlap": over["hold_reasons"]}
    json.dump(out, open(os.path.join(ev, "AT-STM-02.json"), "w"), indent=1)
    check(out["early"] == ["BEFORE_OPENING"], f"early {out['early']}")
    check(pending == [([], "first"), ([], "ok"), ([], "ok")], f"pending {pending}")
    check(runs == ["activated"] * 3, f"runs {runs}")
    check([c[2] for c in chain] == ["first", "ok", "ok"], f"chain {chain}")
    check("COVERAGE" in over["hold_reasons"], f"overlap {over['hold_reasons']}")
    return "three months submitted oldest first: each checked against its pending predecessor, all clean, approved and activated; an overlapping later statement is held (COVERAGE)"


@test("AT-OUT-04", "9043; 2.8 output contract (the curated output schemas of fin.draft.create_statement, fin.statements.chain and "
                   "fin.ledger.accounts hold for the Owner in the PWA and for an AI connection)")
def t_output(server, ev):
    H = household(server, "bnx_c20out")
    cad = H.cad["account_currency_id"]
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad])
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    calls = []
    for who, cred, pf in (("owner/pwa", H.owner, "2026-01-01"), ("ai/mcp", B, "2026-03-01")):
        pt = pf[:8] + "28"
        k = C19.new_key()
        body = dict(account_currency_id=cad, period_from=pf, period_to=pt, opening_balance="1000.00", closing_balance="990.00",
                    sign_convention="asset_positive", lines=[ln(H, pf[:8] + "05", "-10.00")], idempotency_key=k)
        calls.append((who, "cmd_draft_statement", H.app.call("cmd_draft_statement", cred, dict(body))))
        calls.append((who, "cmd_draft_statement", H.app.call("cmd_draft_statement", cred, dict(body))))      # replay
        calls.append((who, "q_statement_chain", H.app.call("q_statement_chain", cred, {"account_currency_id": cad})))
        calls.append((who, "q_ledger_accounts", H.app.call("q_ledger_accounts", cred, {})))
    entries = {fn: C19.catalog_entry(H, fn) for fn in OUT_9043}
    H.close()
    bad = [(w, fn, C19.validate(entries[fn]["output_schema"], r)) for w, fn, r in calls if C19.validate(entries[fn]["output_schema"], r)]
    same = all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] and entries[fn]["provenance"] == "curated" for fn in OUT_9043)
    kinds = sorted({r["kind"] for _, fn, r in calls if fn == "cmd_draft_statement"})
    check(bad == [] and same and kinds == ["ai_draft", "import"], f"{bad} {same} {kinds}")
    return f"{len(calls)} calls by the Owner (PWA) and an AI connection (MCP), incl. replays: every result conforms; the catalog carries the overrides' schemas"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core20", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core20_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
