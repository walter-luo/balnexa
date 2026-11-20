#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 default categories and accounts proposed from a statement (migration 9045; Owner decisions OD-CAT-1, OD-ACC-1 of
2026-11-20): install_default_categories (two levels, idempotent, members' own names kept), q_ledger_accounts parent_id and
reference_display, cmd_propose_account_from_statement over MCP and its refusals, the two-step approval (account with opening
anchor and connection grant, then the statement), q_account_proposals per connection, and the enriched draft screen
(account, statement header, line names). Synthetic data only.
Usage: run_s4_core21.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import harness as h
import run_s4_core1 as C1
import run_s4_core3 as C3
import run_s4_core4 as C4
import run_s4_core20 as C20

RESULTS, TESTS = [], []
check, expect_err = C1.check, C1.expect_err


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def defaults(H, cur=None):
    with H.definer() as cx:
        r = cx.execute("select bnx.install_default_categories(%s)", (cur,)).fetchone()[0]
        cx.commit()
    return r


def tree(H):
    return C4.sql(H, "select kind, parent_en, name_en, name_zh from bnx.default_category_tree() order by ord")


def connection(H, cid="host-t"):
    return str(C4.one(H, "select id from bnx.ai_connection where client_id = %s and revoked_at is null order by approved_at desc nulls last limit 1",
                      (cid,))[0])


@test("AT-CAT-01", "OD-CAT-1; 9045 (built-in two-level categories in the reporting currency; repeatable; a member's own category of "
                   "the same kind, currency and English name is kept; parent links and Chinese names reach q_ledger_accounts)")
def t_defaults(server, ev):
    H = C4.v2_full(server, "bnx_c21cat")                    # the member already has Groceries (expense) and Salary (income)
    out, T = {}, tree(H)
    first = defaults(H)
    out["first"] = (first["currency"], first["added"], first["kept"])
    out["second"] = (lambda r: (r["added"], r["kept"], r["ledger_version"]))(defaults(H))
    la = H.q(H.owner, "ledger_accounts")
    cats = {c["name_en"]: c for c in la["categories"] if c["currency"] == "CAD"}
    out["count"] = (len(cats), len(T))
    out["groceries kept"] = cats["Groceries"]["ledger_account_id"] == H.groceries
    out["salary kept"] = cats["Salary"]["ledger_account_id"] == H.salary
    out["restaurants parent"] = cats["Restaurants"]["parent_id"] == cats["Food & Dining"]["ledger_account_id"]
    out["bonus parent"] = cats["Bonus"]["parent_id"] == cats["Employment"]["ledger_account_id"]
    out["zh"] = (cats["Restaurants"]["name_zh"], cats["Employment"]["name_zh"], cats["Other Expense"]["parent_id"])
    kinds = {r[2]: r[0] for r in T}
    out["kinds"] = all(cats[n]["kind"] == k for n, k in kinds.items())
    out["tree unique"] = len({(r[0], r[2].lower()) for r in T}) == len(T) and all(r[1] is None or any(p[2] == r[1] and p[1] is None for p in T) for r in T)
    out["usd"] = (lambda r: (r["currency"], r["added"]))(defaults(H, "USD"))
    out["unknown currency"] = expect_err(defaults, "UNKNOWN_CURRENCY", H, "XXX")
    out["audit"] = C4.one(H, "select count(*) from bnx.audit_event where command = 'install_default_categories'")[0]
    out["no runtime grant"] = C4.one(H, "select has_function_privilege('bnx_app', 'bnx.install_default_categories(character)', 'execute')")[0]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-CAT-01.json"), "w"), indent=1, default=str)
    check(out["first"] == ("CAD", len(T) - 2, 2), f"first {out['first']}")
    check(out["second"][:2] == (0, len(T)) and out["second"][2] is None, f"second {out['second']}")
    check(out["count"] == (len(T), len(T)) and out["groceries kept"] and out["salary kept"], f"count {out['count']}")
    check(out["restaurants parent"] and out["bonus parent"] and out["kinds"] and out["tree unique"], "parents and kinds")
    check(out["zh"] == ("餐厅", "职业收入", None), f"zh {out['zh']}")
    check(out["usd"] == ("USD", len(T)) and out["audit"] == 2 and out["no runtime grant"] is False, f"usd {out['usd']} audit {out['audit']}")
    return f"{len(T)} defaults ({sum(1 for r in T if r[1] is None)} top level), 2 kept from the member, repeat adds 0, USD separate, installer-only"


@test("AT-ACC-01", "OD-ACC-1; 9045 (the AI proposes an account read from a statement; the Owner approves it in the PWA, which sets "
                   "the opening anchor from the statement and lets the proposing connection see the account; the AI then submits "
                   "the statement; duplicates and existing accounts; refusals)")
def t_propose(server, ev):
    H = C20.household(server, "bnx_c21acc")
    cad = H.cad["account_currency_id"]
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad])
    cid = connection(H)
    inst = H.inst("Synthetic Bank")["institution_id"]
    out = {}
    base = dict(institution_id=inst, kind="credit_card", account_last4="4321", currency="CAD", holder_names=["SYNTHETIC HOLDER"],
                period_from="2026-03-01", opening_balance="250.00", sign_convention="owed_positive")
    p = H.cmd(B, "propose_account_from_statement", **base)
    out["proposal"] = (p["state"], p["existing"], p["suggested_kind"], p["suggested_label"], p["opening"])
    again = H.cmd(B, "propose_account_from_statement", **{**base, "idempotency_key": "another-key-0001"})
    out["again"] = (again["proposal_id"] == p["proposal_id"], again["existing"])
    seen = H.q(B, "account_proposals", state="PROPOSED")["proposals"]
    out["ai sees"] = [(x["proposal_id"] == p["proposal_id"], x["suggested_kind"], x["reference_display"], x["institution_code"], x["origin_client"])
                      for x in seen]
    out["AI cannot resolve"] = expect_err(H.cmd, "FORBIDDEN", B, "resolve_account_proposal", proposal_id=p["proposal_id"], action="approve")
    # refusals
    out["refusals"] = [
        expect_err(H.cmd, "VALIDATION_FAILED", B, "propose_account_from_statement", **{**base, "account_last4": "43210"}),
        expect_err(H.cmd, "VALIDATION_FAILED", B, "propose_account_from_statement", **{**base, "kind": "cash"}),
        expect_err(H.cmd, "VALIDATION_FAILED", B, "propose_account_from_statement", **{**base, "holder_names": ["HOLDER 123456789"]}),
        expect_err(H.cmd, "VALIDATION_FAILED", B, "propose_account_from_statement", **{**base, "sign_convention": None}),
        expect_err(H.cmd, "INSTITUTION_NOT_ELIGIBLE", B, "propose_account_from_statement", **{**base, "institution_id": "00000000-0000-0000-0000-000000000000"}),
        expect_err(H.cmd, "UNKNOWN_CURRENCY", B, "propose_account_from_statement", **{**base, "currency": "XXX"})]
    # step 1: the Owner approves in the PWA with the suggestion as it is
    r = H.cmd(H.owner, "resolve_account_proposal", proposal_id=p["proposal_id"], action="approve")
    out["approved"] = (r["opening_set"], r["connection_granted"], len(r["account_currencies"]))
    new_ac = r["account_currencies"][0]["account_currency_id"]
    acc = C4.one(H, "select kind, label, masked_display, institution_id from bnx.account where id = %s", (r["account_id"],))
    out["account"] = (acc[0], acc[1], acc[2], str(acc[3]) == inst)
    anc = C4.one(H, "select anchor_date::text, amount::text from bnx.opening_anchor_version where account_currency_id = %s", (new_ac,))
    out["anchor"] = (anc[0], anc[1].rstrip("0").rstrip("."))
    la = H.q(B, "ledger_accounts")
    mine = [a for a in la["accounts"] if a["account_currency_id"] == new_ac]
    out["ai sees account"] = (len(mine), mine[0]["reference_display"] if mine else None, mine[0]["can_post"] if mine else None)
    out["subset row"] = C4.one(H, "select count(*) from bnx.ai_connection_subset where connection_id = %s and value = %s", (cid, new_ac))[0]
    # step 2: the AI submits the statement it read; the opening matches the anchor (V-12) and it is the first of the chain (V-11)
    st = C20.stmt(H, B, "2026-03-01", "2026-03-31", "250.00", "300.00",
                  [C20.ln(H, "2026-03-10", "50.00", "SYNTHETIC STORE", economic_type="card_spend")], ac={"account_currency_id": new_ac},
                  sign="owed_positive", account_last4="4321")
    out["statement"] = (st["hold_reasons"], st["validation_result"]["V-04"], st["validation_result"]["V-11"], st["validation_result"]["V-12"])
    out["run"] = C20.approve_run(H, st)[-1]
    out["balance"] = H.balance(H.owner, {"account_currency_id": new_ac}, as_of="2026-03-31")
    # the same account again is refused without telling which account it is
    out["exists"] = expect_err(H.cmd, "ACCOUNT_EXISTS", B, "propose_account_from_statement", **{**base, "idempotency_key": "third-key-00001"})
    out["closed"] = expect_err(H.cmd, "PROPOSAL_NOT_OPEN", H.owner, "resolve_account_proposal", proposal_id=p["proposal_id"], action="reject")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-ACC-01.json"), "w"), indent=1, default=str)
    check(out["proposal"] == ("PROPOSED", False, "credit_card", "SYNTHETIC_BANK card 4321",
                              {"anchor_date": "2026-03-01", "amount": "-250", "printed_opening": "250", "sign_convention": "owed_positive"}),
          f"proposal {out['proposal']}")
    check(out["again"] == (True, True), f"again {out['again']}")
    check(out["ai sees"] == [(True, "credit_card", "•••• 4321", "SYNTHETIC_BANK", "T")], f"ai sees {out['ai sees']}")
    check(len(out["refusals"]) == 6, "refusals")
    check(out["approved"] == (True, True, 1), f"approved {out['approved']}")
    check(out["account"] == ("credit_card", "SYNTHETIC_BANK card 4321", "•••• 4321", True), f"account {out['account']}")
    check(out["anchor"] == ("2026-03-01", "-250"), f"anchor {out['anchor']}")
    check(out["ai sees account"] == (1, "•••• 4321", False) and out["subset row"] == 1, f"ai sees account {out['ai sees account']}")
    check(out["statement"] == ([], "ok", "first", "ok") and out["run"] == "activated", f"statement {out['statement']} {out['run']}")
    check(out["balance"] in ("-300.00", "-300.0000", "-300"), f"balance {out['balance']}")
    return "proposal -> approval (kind, label, opening -250 at 03-01, connection sees it) -> statement V-11 first, V-12 ok -> posted; duplicates refused"


@test("AT-ACC-02", "OD-ACC-1; 9045 (the member may change the suggestion, decline the opening and the connection grant; an AI "
                   "connection sees only its own proposals; the PWA sees all; reject)")
def t_choices(server, ev):
    H = C20.household(server, "bnx_c21acc2")
    cad = H.cad["account_currency_id"]
    B1 = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad])
    C3.client(H, "host-u", "https://u.example/cb")
    r2, v2 = C3.consent(H, ["finance.read", "finance.draft"], acs=[cad], cid="host-u", cb="https://u.example/cb")
    B2 = {"kind": "bearer", "secret": C3.token(H, r2, v2, cid="host-u", cb="https://u.example/cb")["access_token"]}
    inst = H.inst("Synthetic Bank")["institution_id"]
    out = {}
    p1 = H.cmd(B1, "propose_account_from_statement", institution_id=inst, kind="bank_deposit", account_last4="1111", currency="CAD",
               period_from="2026-02-01", opening_balance="10.00", sign_convention="asset_positive")
    p2 = H.cmd(B2, "propose_account_from_statement", institution_id=inst, kind="bank_deposit", account_last4="2222", currency="CAD")
    out["own only"] = ([x["proposal_id"] for x in H.q(B1, "account_proposals")["proposals"]] == [p1["proposal_id"]],
                       [x["proposal_id"] for x in H.q(B2, "account_proposals")["proposals"]] == [p2["proposal_id"]])
    out["pwa sees both"] = sorted(x["proposal_id"] for x in H.q(H.owner, "account_proposals", state="PROPOSED")["proposals"]) == sorted([p1["proposal_id"], p2["proposal_id"]])
    out["no opening in p2"] = p2["opening"] is None and p2["suggested_label"] == "SYNTHETIC_BANK account 2222"
    r = H.cmd(H.owner, "resolve_account_proposal", proposal_id=p1["proposal_id"], action="approve", label="Joint chequing",
              set_opening="false", grant_connection="false")
    new_ac = r["account_currencies"][0]["account_currency_id"]
    out["choices"] = (r["opening_set"], r["connection_granted"],
                      C4.one(H, "select label from bnx.account where id = %s", (r["account_id"],))[0],
                      C4.one(H, "select count(*) from bnx.opening_anchor_version where account_currency_id = %s", (new_ac,))[0],
                      any(a["account_currency_id"] == new_ac for a in H.q(B1, "ledger_accounts")["accounts"]))
    rj = H.cmd(H.owner, "resolve_account_proposal", proposal_id=p2["proposal_id"], action="reject")
    out["rejected"] = (rj["action"], C4.one(H, "select state from bnx_intake.account_proposal where id = %s", (p2["proposal_id"],))[0],
                       C4.one(H, "select count(*) from bnx.account where masked_display = '•••• 2222'")[0])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-ACC-02.json"), "w"), indent=1, default=str)
    check(out["own only"] == (True, True) and out["pwa sees both"] and out["no opening in p2"], f"visibility {out}")
    check(out["choices"] == (False, False, "Joint chequing", 0, False), f"choices {out['choices']}")
    check(out["rejected"] == ("reject", "REJECTED", 0), f"rejected {out['rejected']}")
    return "label changed, opening and grant declined; each connection sees its own proposals; reject creates nothing"


@test("AT-CONF-09", "9045 (the draft screen data: account-currency and label, statement header, and the name of every line's ledger "
                    "account in English and Chinese; same for MCP)")
def t_confirm(server, ev):
    H = C20.household(server, "bnx_c21conf")
    cad = H.cad["account_currency_id"]
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[cad])
    defaults(H)
    cats = {c["name_en"]: c for c in H.q(H.owner, "ledger_accounts")["categories"]}
    out = {}
    st = C20.stmt(H, B, "2026-01-01", "2026-01-31", "1000.00", "975.00",
                  [C20.ln(H, "2026-01-05", "-25.00", "SYNTHETIC CAFE", cats["Restaurants"]["ledger_account_id"])])
    for who, cred in (("pwa", H.owner), ("mcp", B)):
        d = H.q(cred, "draft_get_for_confirmation", plan_id=st["plan_id"])
        out[who] = (d["account_currency_id"] == cad, d["account_label"], d["account_currency"], d["statement"]["period_from"],
                    d["statement"]["printed_closing"],
                    [(l["ledger_account_name"], l["ledger_account_name_zh"], l["amount"]) for l in d["items"][0]["lines"]])
    tx = H.cmd(H.owner, "draft_create_transaction", account_currency_id=cad, transaction_date="2026-01-06", economic_type="consumption_expense",
               amount="-5.00", counter_ledger_account_id=H.groceries, description="synthetic")
    d = H.q(H.owner, "draft_get_for_confirmation", plan_id=tx["plan_id"])
    out["transaction"] = (d["statement"], [l["ledger_account_name"] for l in d["items"][0]["lines"]])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-CONF-09.json"), "w"), indent=1, default=str)
    exp = (True, "Chequing", "CAD", "2026-01-01", "975",
           [("Chequing", "Chequing", "-25.00"), ("Food & Dining › Restaurants", "食品餐饮 › 餐厅", "25.00")])
    check(out["pwa"][:5] == exp[:5] and [x[:2] for x in out["pwa"][5]] == [x[:2] for x in exp[5]], f"pwa {out['pwa']}")
    check(out["mcp"] == out["pwa"], f"mcp {out['mcp']}")
    check(out["transaction"] == (None, ["Chequing", "Groceries"]), f"transaction {out['transaction']}")
    return "account, statement header and line names (Parent › Child, zh) for the PWA and MCP; transactions carry no header"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core21", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core21_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
