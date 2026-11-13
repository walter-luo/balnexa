#!/usr/bin/env python3
"""S4 phase 2 tests: 2.8 part 3 curated MCP output schemas (migration 9032) and INS-1 signed releases
(tools/s4/release_sign.py; deploy/install_instance.py --require-signed). Synthetic data only.
Usage: run_s4_core19.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time, traceback, types
import importlib.util
import harness as h
from fixture import new_key
import run_s4_core1 as C1
import run_s4_core2 as C2
import run_s4_core4 as C4
import run_s4_core14 as C14

sys.path.insert(0, os.path.join(h.ROOT, "tools", "s4"))
import release_sign as RS   # noqa: E402
import catalog_build as CB  # noqa: E402

RESULTS, TESTS = [], []
check = C1.check


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


# ---------------------------------------------------------------------------------------------- JSON Schema (output side)
from jsonschema_lite import validate  # noqa: E402,F401 (shared with the harness output contract)


# ---------------------------------------------------------------------------------------------- 2.8 part 3 output schemas
# the read tools of 9034, made field-level by 9035 (2.8 part 6, D-OUT-1); AT-OUT-03 calls them
OUT_9035 = ["q_account_proposals", "q_balance_observations", "q_card_fee_progress", "q_evidence_access", "q_investment_position",
            "q_onboarding_job", "q_r28_loan_position", "q_reconciliation_coverage", "q_reconciliation_exceptions", "q_replay_snapshot",
            "q_snapshot_artifact", "q_transfer_matching"]


def catalog_entry(H, fn):
    with C1.migrator(H.server, H.db) as cx:
        return json.loads(cx.execute("select obj_description(%s::regprocedure, 'pg_proc')", (f"bnx.{fn}(jsonb, jsonb)",)).fetchone()[0])


@test("AT-OUT-01", "2.8 part 3; MCP tools outputSchema; 9032 (every tool with a curated output schema returns conforming results "
                   "for an Owner in the PWA and for an AI connection: draft tools incl. replay, transfer, revise, validate, withdraw; "
                   "balances; whoami; report families F1-F7, R09, R30, R31; FX rate, snapshots, registry search, handoff status)")
def t_output_schemas(server, ev):
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    # field-level schemas of 9032/9033 are called here; the 9035 ones (the 9034 tools made field-level) by AT-OUT-03; every
    # suite checks all of them through the harness output contract (AT-OUT-02)
    curated = sorted(k for k, v in ovr["schemas"].items() if "output" in v and v["output"].get("required") and k not in OUT_9035)
    H = C4.v2_full(server, "bnx_c19out")
    cad = H.cad["account_currency_id"]
    sav = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Savings", currencies=["CAD"])["account_currencies"][0]
    H.cmd(H.owner, "set_opening", account_currency_id=sav["account_currency_id"], anchor_date="2026-01-01", amount="50.00")
    B = C4.bearer(H, ["finance.read", "finance.draft", "reports.read", "handoff.read"], acs=[cad, sav["account_currency_id"]])
    entries = {fn: catalog_entry(H, fn) for fn in curated}
    calls = []                                       # (who, function, result)

    def run(who, cred, fn, key=None, **body):
        if fn.startswith("cmd_"):
            body["idempotency_key"] = key or new_key()
        r = H.app.call(fn, cred, body)
        calls.append((who, fn, r))
        return r

    j = H.expense(H.owner, "25.00", date="2026-02-10")["journal_id"]
    for who, cred in (("owner/pwa", H.owner), ("ai/mcp", B)):
        # the report families (common envelope of bnx.rpt_envelope plus their own keys)
        run(who, cred, "q_f1_balances", as_of="2026-12-31")
        run(who, cred, "q_f1_balances", as_of="2026-12-31", reporting_currency="USD")      # a missing rate: null total
        run(who, cred, "q_f2_transactions", account_currency_id=cad, date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_f3_income_expense", date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_f4_investments", as_of="2026-12-31")
        run(who, cred, "q_f5_networth", as_of="2026-12-31")
        run(who, cred, "q_f6_cards", as_of="2026-12-31")
        run(who, cred, "q_f7_reconciliation", account_currency_id=cad)
        run(who, cred, "q_cashflow_statement", date_from="2026-01-01", date_to="2026-12-31")
        run(who, cred, "q_r30_review_queue")
        run(who, cred, "q_evidence_trace", journal_id=j)
        # 2.8 part 4 (9033): FX, snapshots, registry search, handoff status
        run(who, cred, "q_fx_rate", base="CAD", quote="USD", date="2026-03-01")                # no rate: MISSING, rate null
        run(who, cred, "q_fx_rate", base="CAD", quote="CAD", date="2026-03-01")                # IDENTITY
        snap = H.app.call("cmd_create_report_snapshot", cred, {"report_code": "R-BAL", "as_of": "2026-12-31", "idempotency_key": new_key()})
        run(who, cred, "q_snapshot_list")
        run(who, cred, "q_snapshot_status", snapshot_id=snap["snapshot_id"])
        run(who, cred, "q_institutions_search", text="CIBC")
        run(who, cred, "q_handoff_status")
        run(who, cred, "q_whoami")
        run(who, cred, "q_balances", as_of="2026-12-31")
        k = new_key()
        tx = dict(account_currency_id=cad, transaction_date="2026-03-02", economic_type="consumption_expense", amount="-12.00",
                  description="synthetic draft")
        tx.update(counter_ledger_account_id=H.groceries) if who == "owner/pwa" else tx.update(lines=[
            {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-12.00"},
            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "12.00"}])
        d = run(who, cred, "cmd_draft_create_transaction", key=k, **tx)
        run(who, cred, "cmd_draft_create_transaction", key=k, **tx)                      # replay
        run(who, cred, "q_draft_get_for_confirmation", plan_id=d["plan_id"])
        run(who, cred, "cmd_draft_validate", key=new_key(), plan_id=d["plan_id"])
        t = run(who, cred, "cmd_draft_create_transfer", key=new_key(), from_account_currency_id=cad,
                to_account_currency_id=sav["account_currency_id"], amount="5.00", transaction_date="2026-03-04")
        run(who, cred, "q_draft_get_for_confirmation", plan_id=t["plan_id"])
        run(who, cred, "cmd_draft_withdraw", key=new_key(), plan_id=t["plan_id"])
        run(who, cred, "q_draft_get_for_confirmation", plan_id=t["plan_id"])            # a withdrawn draft
    # a member draft revised by its author (draft_revise is the member path)
    md = run("member/pwa", H.member, "cmd_draft_create_transaction", key=new_key(), account_currency_id=cad, transaction_date="2026-03-05",
             economic_type="consumption_expense", amount="-3.00", counter_ledger_account_id=H.groceries, description="member draft")
    run("member/pwa", H.member, "cmd_draft_revise", key=new_key(), plan_id=md["plan_id"],
        item={"transaction_date": "2026-03-06", "economic_type": "consumption_expense", "amount": "-4.00",
              "counter_ledger_account_id": H.groceries, "description": "member draft revised"})
    run("member/pwa", H.member, "q_balances", as_of="2026-12-31")
    H.close()
    bad = [(who, fn, validate(entries[fn]["output_schema"], r)) for who, fn, r in calls
           if validate(entries[fn]["output_schema"], r if isinstance(r, dict) else {"result": r})]
    covered = sorted({fn for _, fn, _ in calls})
    replays = [r["replayed"] for _, fn, r in calls if fn == "cmd_draft_create_transaction"]
    kinds = sorted({r["kind"] for _, fn, r in calls if fn == "cmd_draft_create_transaction"})
    check(bad == [] and covered == curated, f"{bad} {covered} {curated}")
    check(all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] and entries[fn]["provenance"] == "curated" for fn in curated),
          "catalog output schemas differ from the overrides")
    check(replays.count(True) == 2 and kinds == ["ai_draft", "member_draft"], f"{replays} {kinds}")
    # the generator refuses an output schema the Gateway could not enforce
    probs = CB.schema_problems({"type": "object", "required": ["x"], "properties": {"y": {"oneOf": []}}})
    check(probs == ["$.y: unsupported keyword oneOf", "$: required x has no property"], probs)
    json.dump([{"who": w, "fn": f} for w, f, _ in calls], open(os.path.join(ev, "AT-OUT-01_calls.json"), "w"), indent=1)
    return (f"{len(calls)} calls by the Owner (PWA), an AI connection (MCP) and a member over {len(curated)} tools with curated output "
            f"schemas ({', '.join(curated)}): every result conforms (incl. replays, ai_draft and member_draft, a withdrawn draft); "
            f"the catalog carries the overrides' schemas; the generator refuses unsupported keywords and dangling required keys")


@test("AT-OUT-03", "2.8 part 6; 9035; D-OUT-1, D-OUT-3 (field-level output schemas for the 12 read tools of 9034: each is called by "
                   "the Owner in the PWA and, where its scope allows, by an AI connection; the branches the other suites do not reach "
                   "are built here: loan overdue, not overdue, REJECTED, TERMS_UNVERIFIED and a partial view; coverage gaps; a STALE "
                   "artifact; a card without policy; evidence denied over MCP)")
def t_output_fields(server, ev):
    import run_s4_core8 as C8
    import run_s4_core10 as C10
    import run_s4_core11 as C11
    import run_s4_core12 as C12
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    H = C12.world(server, "bnx_c19out3")
    cad, rec = H.cad["account_currency_id"], H.rec["account_currency_id"]
    entries = {fn: catalog_entry(H, fn) for fn in OUT_9035}
    import run_s4_core3 as C3                        # an AI connection that sees the receivable side of the loans only
    C3.client(H)
    r, v = C3.consent(H, ["finance.read", "reports.read", "documents.read"], acs=[cad, rec], document_classes=["statement"])
    B = {"kind": "bearer", "secret": C3.token(H, r, v)["access_token"]}
    calls = []

    def run(who, cred, fn, **q):
        r = H.app.call(fn, cred, q)
        calls.append((who, fn, r))
        return r

    # reconciliation: January and March final, February missing (a gap), April partial; one January run
    s1 = C10.stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "2000.00")
    C10.stmt(H, H.cad, "2026-03-01", "2026-03-31", "2000.00", "2000.00")
    C10.stmt(H, H.cad, "2026-04-01", "2026-04-30", "2000.00", None)
    for jid, d, amt in (("J1", "2026-01-10", "3000.00"), ("J2", "2026-01-12", "-200.00"), ("J4", "2026-01-20", "-100.00"),
                        ("J5", "2026-01-22", "-400.00"), ("J6", "2026-01-25", "-1000.00"), ("J7", "2026-01-28", "-300.00")):
        C10.row(H, H.cad, d, amt, link=H.j[jid])
    H.cmd(H.owner, "run_reconciliation", statement_id=s1)
    C10.row(H, H.cad, "2026-04-10", "-75.00", desc="E-TRANSFER OUT")
    C11.match(H, H.cad)
    # loans: one without terms (TERMS_UNVERIFIED), one with terms and a due date (overdue or not; REJECTED before its start)
    bare = H.cmd(H.owner, "declare_loan", currency="CAD", principal="100.00", start="2026-02-01", lender_party_id=H.lender,
                 borrower_party_id=H.borrower, receivable_account_currency_id=rec, payable_account_currency_id=H.pay["account_currency_id"],
                 evidence_ref=C8.EVID)["loan_id"]
    due = H.cmd(H.owner, "declare_loan", currency="CAD", principal="1000.00", start="2026-02-01", due_date="2026-03-01",
                lender_party_id=H.lender, borrower_party_id=H.borrower, receivable_account_currency_id=rec,
                payable_account_currency_id=H.pay["account_currency_id"], evidence_ref=C8.EVID)["loan_id"]
    H.cmd(H.owner, "declare_loan_terms", loan_id=due, evidence_ref=C8.EVID,
          events=C8.TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.05"}, "effective_from": "2026-02-01"}])
    # snapshot and artifact (CURRENT, then STALE after a backdated posting in scope)
    snap = H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", as_of="2026-01-31", account_currency_ids=[cad])["snapshot_id"]
    H.worker.call("wrk_snapshot_artifact", snap, {"artifact_ref": "drive:System_Outputs/Report_Archive/2026/synthetic.pdf",
                                                  "artifact_sha256": "cd" * 32, "renderer_version": "r1.0", "source_revision": 1,
                                                  "ownership_revision": 1, "warnings": []})
    job = H.cmd(H.owner, "onboarding_create_job", title="History 2026", scope={"start_policy": "earliest_evidence"})["job_id"]

    for who, cred in (("owner/pwa", H.owner), ("ai/mcp", B)):
        run(who, cred, "q_reconciliation_coverage", account_currency_id=cad)
        run(who, cred, "q_reconciliation_exceptions", account_currency_id=cad)
        run(who, cred, "q_balance_observations", account_currency_id=cad, include_superseded=True)
        run(who, cred, "q_transfer_matching", account_currency_id=cad)
        run(who, cred, "q_r28_loan_position", loan_id=bare, as_of="2026-02-15")
        for d in ("2026-02-15", "2026-04-01", "2026-01-15"):                          # before due, overdue, before start
            run(who, cred, "q_r28_loan_position", loan_id=due, as_of=d)
        run(who, cred, "q_evidence_access", evidence_file_id="00000000-0000-4000-8000-000000000000", purpose="contract test")
    # Owner only: the AI connection's consent does not cover the brokerage, and the snapshot is the Owner's
    run("owner/pwa", H.owner, "q_investment_position", account_currency_id=H.inv["account_currency_id"], as_of="2026-01-31",
        reporting_currency="USD")
    run("owner/pwa", H.owner, "q_snapshot_artifact", snapshot_id=snap)
    run("owner/pwa", H.owner, "q_replay_snapshot", snapshot_id=snap)
    run("owner/pwa", H.owner, "q_card_fee_progress", card_account_id=H.card_acc, as_of="2026-01-31")   # no policy
    run("owner/pwa", H.owner, "q_onboarding_job", job_id=job)
    run("owner/pwa", H.owner, "q_account_proposals")
    H.expense(H.owner, "10.00", date="2026-01-20")                                    # backdated, in the snapshot's scope
    stale = run("owner/pwa", H.owner, "q_snapshot_artifact", snapshot_id=snap)
    replay = run("owner/pwa", H.owner, "q_replay_snapshot", snapshot_id=snap)
    H.close()
    bad = [(who, fn, validate(entries[fn]["output_schema"], r)) for who, fn, r in calls if validate(entries[fn]["output_schema"], r)]
    covered = sorted({fn for _, fn, _ in calls})
    loans = [r for _, fn, r in calls if fn == "q_r28_loan_position"]
    seen = {"status": sorted({r["status"] for r in loans}), "overdue": sorted({str((r["position"] or {}).get("overdue")) for r in loans}),
            "partial_view": sorted({r["partial_view"] for r in loans}),
            "gaps": [r["gaps"] for w, fn, r in calls if fn == "q_reconciliation_coverage" and w == "owner/pwa"][0],
            "artifact": [r["status"] for _, fn, r in calls if fn == "q_snapshot_artifact"],
            "card": [r["status"] for _, fn, r in calls if fn == "q_card_fee_progress"],
            "evidence over mcp": [r["decision"] for w, fn, r in calls if fn == "q_evidence_access" and w == "ai/mcp"],
            "replay verified": replay["projection_digest_verified"]}
    json.dump({"calls": [{"who": w, "fn": f} for w, f, _ in calls], "seen": seen}, open(os.path.join(ev, "AT-OUT-03.json"), "w"),
              indent=1, default=str)
    check(bad == [] and covered == sorted(OUT_9035), f"{bad} {covered}")
    check(all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] and entries[fn]["output_schema"].get("required")
              for fn in OUT_9035), "catalog output schemas differ from the overrides, or are not field-level")
    check(seen["status"] == ["OK", "REJECTED", "TERMS_UNVERIFIED"] and seen["overdue"] == ["False", "None", "True"]
          and seen["partial_view"] == [False, True] and seen["gaps"] == [{"from": "2026-02-01", "to": "2026-02-28"}]
          and seen["artifact"] == ["CURRENT", "STALE"] and stale["status"] == "STALE" and seen["card"] == ["NO_POLICY"]
          and seen["evidence over mcp"] == ["denied"] and seen["replay verified"] is True, f"{seen}")
    return (f"{len(calls)} calls over the 12 tools of 9035 by the Owner (PWA) and an AI connection (MCP): every result conforms to "
            f"its field-level schema in the catalog; loan statuses {seen['status']}, overdue true/false, a partial view; a February "
            f"gap; artifact CURRENT then STALE; a card with no policy; evidence denied over MCP; the replay still verifies")


@test("AT-OUT-04", "2.8 part 7; 9036; D-OUT-1 (field-level rows and nested objects of the report families F1-F7: each family is "
                   "called by the Owner and by an AI connection over a household with statements, a reconciliation difference, an "
                   "open clearing item, an intra-household loan, an investment account and a card; the row branches are asserted)")
def t_output_rows(server, ev):
    import run_s4_core3 as C3
    import run_s4_core10 as C10
    import run_s4_core11 as C11
    import run_s4_core12 as C12
    fams = ["q_f1_balances", "q_f2_transactions", "q_f3_income_expense", "q_f4_investments", "q_f5_networth", "q_f6_cards",
            "q_f7_reconciliation"]
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    H = C12.world(server, "bnx_c19out4")
    cad, rec = H.cad["account_currency_id"], H.rec["account_currency_id"]
    entries = {fn: catalog_entry(H, fn) for fn in fams}
    C3.client(H)
    r, v = C3.consent(H, ["finance.read", "reports.read"], acs=[cad, rec])       # sees neither savings nor the payable side
    B = {"kind": "bearer", "secret": C3.token(H, r, v)["access_token"]}
    # statements: chequing matches the ledger; savings prints 1250.00 where the ledger has 1200.00 (a reconciliation exception)
    s1 = C10.stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "2000.00")
    s2 = C10.stmt(H, H.sav, "2026-01-02", "2026-01-31", "500.00", "1250.00")
    for jid, d, amt in (("J1", "2026-01-10", "3000.00"), ("J2", "2026-01-12", "-200.00"), ("J4", "2026-01-20", "-100.00"),
                        ("J5", "2026-01-22", "-400.00"), ("J6", "2026-01-25", "-1000.00"), ("J7", "2026-01-28", "-300.00")):
        C10.row(H, H.cad, d, amt, link=H.j[jid])
    H.cmd(H.owner, "run_reconciliation", statement_id=s1)
    H.cmd(H.owner, "run_reconciliation", statement_id=s2)
    C10.row(H, H.cad, "2026-01-30", "-75.00", desc="E-TRANSFER OUT")
    C11.match(H, H.cad)
    with H.definer() as cx:                          # an open clearing item, as the clearing path leaves it (fixture as in AT-MR-02)
        ver = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        ci = cx.execute("insert into bnx.clearing_item(id, account_currency_id, currency, kind, amount, counterpart_hint, opened_journal) "
                        "values (gen_random_uuid(), %s, 'CAD', 'transfer_in_transit', -400.00, %s, %s) returning id",
                        (cad, json.dumps({"account_currency_id": H.sav["account_currency_id"], "window_days": 7}), H.j["J5"])).fetchone()[0]
        cx.execute("insert into bnx.clearing_item_event(clearing_item_id, seq, event, recorded_version) values (%s, 1, 'opened', %s)", (ci, ver))
        cx.commit()
    calls = []

    def run(who, cred, fn, **q):
        res = H.app.call(fn, cred, q)
        calls.append((who, fn, res))
        return res

    for who, cred in (("owner/pwa", H.owner), ("ai/mcp", B)):
        run(who, cred, "q_f1_balances", as_of="2026-01-31", reporting_currency="USD")
        run(who, cred, "q_f2_transactions", date_from="2026-01-01", date_to="2026-01-31")
        run(who, cred, "q_f3_income_expense", date_from="2026-01-01", date_to="2026-01-31")
        run(who, cred, "q_f4_investments", as_of="2026-01-31", reporting_currency="USD")
        run(who, cred, "q_f5_networth", as_of="2026-01-31", reporting_currency="USD")
        run(who, cred, "q_f6_cards", as_of="2026-01-31")
        run(who, cred, "q_f7_reconciliation")
    H.close()
    bad = [(who, fn, validate(entries[fn]["output_schema"], res)) for who, fn, res in calls if validate(entries[fn]["output_schema"], res)]
    got = lambda who, fn: next(res for w, f, res in calls if w == who and f == fn)
    o, ai = (lambda fn: got("owner/pwa", fn)), (lambda fn: got("ai/mcp", fn))
    seen = {
        "f1 holders": sorted({type(x["holders"]).__name__ for x in o("q_f1_balances")["rows"]}),
        "f1 latest statement": any("latest_statement" in x for x in o("q_f1_balances")["rows"]),
        "f1 reporting": all("reporting" in x for x in o("q_f1_balances")["rows"]),
        "f2 masked line (ai)": any(l.get("masked") for x in ai("q_f2_transactions")["rows"] for l in x["lines"]),
        "f3 kinds": sorted({x["kind"] for x in o("q_f3_income_expense")["categories"]}),
        "f4 movements": [len(x["movements"]) for x in o("q_f4_investments")["accounts"]],
        "f5 eliminated": sorted({x["eliminated_r28"] for x in o("q_f5_networth")["lines"]}),
        "f5 by_owner": len(o("q_f5_networth")["by_owner"]),
        "f6 cards": [x["annual_fee"]["status"] for x in o("q_f6_cards")["cards"]],
        "f7 exceptions": len(o("q_f7_reconciliation")["exceptions"]),
        "f7 open clearing": len(o("q_f7_reconciliation")["transfer_matching"]["open_clearing_items"]),
        "f7 coverage": len(o("q_f7_reconciliation")["coverage"]),
    }
    json.dump({"calls": [{"who": w, "fn": f} for w, f, _ in calls], "seen": seen}, open(os.path.join(ev, "AT-OUT-04.json"), "w"),
              indent=1, default=str)
    check(bad == [] and sorted({fn for _, fn, _ in calls}) == fams, f"{bad}")
    check(all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] for fn in fams), "catalog output schemas differ from the overrides")
    check(seen["f1 holders"] == ["list", "str"] and seen["f1 latest statement"] and seen["f1 reporting"] and seen["f2 masked line (ai)"]
          and seen["f3 kinds"] == ["expense", "income"] and seen["f4 movements"] and all(seen["f4 movements"])
          and seen["f5 eliminated"] == [False, True] and seen["f5 by_owner"] > 0 and seen["f6 cards"] == ["NO_POLICY"]
          and seen["f7 exceptions"] > 0 and seen["f7 open clearing"] == 1 and seen["f7 coverage"] > 0, f"{seen}")
    return (f"{len(calls)} calls of F1-F7 by the Owner and an AI connection: every result conforms to its field-level row schema in the "
            f"catalog; branches seen: {seen}")


@test("AT-OUT-05", "2.8 part 8; 9037; D-OUT-1 (field-level rows of R09 cash flow, R30 review queue and R31 evidence trace: called "
                   "by the Owner and an AI connection; R09 with and without available balances, R30 with every kind the household "
                   "produces, R31 from a source row through its statement, evidence, correction and snapshot)")
def t_output_rows_2(server, ev):
    import run_s4_core3 as C3
    import run_s4_core10 as C10
    import run_s4_core11 as C11
    import run_s4_core12 as C12
    fams = ["q_cashflow_statement", "q_r30_review_queue", "q_evidence_trace"]
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    H = C12.world(server, "bnx_c19out5")
    cad, rec = H.cad["account_currency_id"], H.rec["account_currency_id"]
    entries = {fn: catalog_entry(H, fn) for fn in fams}
    C3.client(H)
    r, v = C3.consent(H, ["finance.read", "reports.read"], acs=[cad, rec])
    B = {"kind": "bearer", "secret": C3.token(H, r, v)["access_token"]}
    s1 = C10.stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "2000.00")
    s2 = C10.stmt(H, H.sav, "2026-01-02", "2026-01-31", "500.00", "1250.00")      # differs from the ledger: an exception
    for jid, d, amt in (("J1", "2026-01-10", "3000.00"), ("J2", "2026-01-12", "-200.00"), ("J4", "2026-01-20", "-100.00"),
                        ("J5", "2026-01-22", "-400.00"), ("J6", "2026-01-25", "-1000.00"), ("J7", "2026-01-28", "-300.00")):
        C10.row(H, H.cad, d, amt, link=H.j[jid])
    H.cmd(H.owner, "run_reconciliation", statement_id=s1)
    H.cmd(H.owner, "run_reconciliation", statement_id=s2)
    C11.post(H, "2026-04-03", "-25.00", H.cad, desc="A")
    C11.post(H, "2026-04-04", "-25.00", H.cad, desc="B")
    C10.row(H, H.cad, "2026-04-03", "-25.00", desc="PARKING")                        # ambiguous: a pending match decision
    C10.row(H, H.cad, "2026-04-10", "-75.00", desc="E-TRANSFER OUT")                 # unmatched
    C11.match(H, H.cad)
    with H.definer() as cx:                                                           # an open clearing item (as in AT-MR-02)
        ver = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        ci = cx.execute("insert into bnx.clearing_item(id, account_currency_id, currency, kind, amount, counterpart_hint, opened_journal) "
                        "values (gen_random_uuid(), %s, 'CAD', 'transfer_in_transit', -400.00, %s, %s) returning id",
                        (cad, json.dumps({"account_currency_id": H.sav["account_currency_id"], "window_days": 7}), H.j["J5"])).fetchone()[0]
        cx.execute("insert into bnx.clearing_item_event(clearing_item_id, seq, event, recorded_version) values (%s, 1, 'opened', %s)", (ci, ver))
        cx.commit()
    H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", as_of="2026-01-31")
    H.cmd(H.owner, "correct_transaction", journal_id=H.j["J2"], reason="synthetic amount fix", replacement={
        "transaction_date": "2026-01-12", "description": "fixed", "lines": [
            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "210.00"},
            {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-210.00"}]})
    with H.definer() as cx:
        src = str(cx.execute("select id from bnx.source_txn where amount = -200.00").fetchone()[0])
    calls = []

    def run(who, cred, fn, **q):
        res = H.app.call(fn, cred, q)
        calls.append((who, fn, res))
        return res

    for who, cred in (("owner/pwa", H.owner), ("ai/mcp", B)):
        run(who, cred, "q_cashflow_statement", date_from="2026-01-02", date_to="2026-01-31")
        run(who, cred, "q_cashflow_statement", date_from="2025-11-01", date_to="2026-01-31")   # opening before any balance
        run(who, cred, "q_r30_review_queue")
        run(who, cred, "q_evidence_trace", source_txn_id=src)
    H.close()
    bad = [(who, fn, validate(entries[fn]["output_schema"], res)) for who, fn, res in calls if validate(entries[fn]["output_schema"], res)]
    owner = [res for w, fn, res in calls if w == "owner/pwa"]
    cf_ok, cf_na, queue, trace = owner
    seen = {
        "r09 reconciles": sorted({str(x["reconciles"]) for x in cf_ok["by_currency"].values()}),
        "r09 not available": sorted({str(x["reconciles"]) for x in cf_na["by_currency"].values()}),
        "r09 flow classes": sorted({k for x in cf_ok["by_currency"].values() for k in x["flows"]}),
        "r30 kinds": sorted(queue["counts"]),
        "r31 statements": sum(len(x.get("statements", [])) for x in trace["source_rows"]),
        "r31 corrections": [c["replacement_journal_id"] is not None for c in trace["corrections"]],
        "r31 snapshots": len(trace["snapshots"]),
    }
    json.dump({"calls": [{"who": w, "fn": f} for w, f, _ in calls], "seen": seen}, open(os.path.join(ev, "AT-OUT-05.json"), "w"),
              indent=1, default=str)
    check(bad == [] and sorted({fn for _, fn, _ in calls}) == sorted(fams), f"{bad}")
    check(all(entries[fn]["output_schema"] == ovr["schemas"][fn]["output"] for fn in fams), "catalog output schemas differ from the overrides")
    check("True" in seen["r09 reconciles"] and seen["r09 not available"] == ["None"] and "OPERATING" in seen["r09 flow classes"]
          and {"reconciliation_exception", "open_clearing_item", "match_decision_pending", "unmatched_source_row"} <= set(seen["r30 kinds"])
          and seen["r31 statements"] > 0 and seen["r31 corrections"] == [True] and seen["r31 snapshots"] > 0, f"{seen}")
    return (f"{len(calls)} calls of R09, R30 and R31 by the Owner and an AI connection: every result conforms to its field-level row "
            f"schema in the catalog; branches seen: {seen}")


@test("AT-OUT-02", "2.8 part 5; D-OUT-2 (the output contract runs in every suite: every bnx_app call of a tool with a curated "
                   "output schema is validated by the harness; a mismatch fails the calling test, with the path only)")
def t_output_contract(server, ev):    # noqa: ARG001 - no database needed
    import jsonschema_lite as J
    ovr = json.load(open(os.path.join(h.ROOT, "db", "catalog", "bnx-tools-1.0.overrides.json")))
    mcp_reads = sorted(k for k, v in ovr["schemas"].items() if k.startswith("q_"))
    missing = [k for k in ovr["schemas"] if "output" not in ovr["schemas"][k]]
    good = J.check_output("q_snapshot_status", {"snapshot_id": "00000000-0000-4000-8000-000000000000", "status": "CURRENT"})
    errs = []
    for fn, r in (("q_snapshot_status", {"snapshot_id": "00000000-0000-4000-8000-000000000000", "status": "SOMETHING_ELSE"}),
                  ("q_balances", {"ledger_version": 3, "as_of": "2026-01-01"}),
                  ("q_fx_rate", {"base": "CAD", "quote": "USD", "date": "2026-01-01", "rate": 1.5, "quality": "REFERENCE", "inverse": False,
                                 "ledger_version": 1, "fx_policy": "x"}),
                  ("q_cashflow_statement", {"report": "R09/1", "ledger_version": 1, "as_of": "2026-01-31", "reporting_currency": None,
                                            "fx_policy": "x", "fx_snapshot_ref": "fx@1", "grants_digest": "0" * 64,
                                            "scope_warnings": [], "rounding": "x",
                                            "by_currency": {"CAD": {"opening": 1, "closing": None, "flows": {}, "operating_net": "0",
                                                                    "reconciles": None}}})):   # a schema-valued additionalProperties
        try:
            J.check_output(fn, r)
        except J.OutputContractError as e:
            errs.append(str(e))
    hooked = "jsonschema_lite.check_output" in open(os.path.join(h.ROOT, "tests", "py", "harness.py")).read()
    check(good is None and missing == [] and hooked and errs == [
        "OUTPUT_SCHEMA_MISMATCH q_snapshot_status at $.status: enum",
        "OUTPUT_SCHEMA_MISMATCH q_balances at $.balances: required",
        "OUTPUT_SCHEMA_MISMATCH q_fx_rate at $.rate: type number",
        "OUTPUT_SCHEMA_MISMATCH q_cashflow_statement at $.by_currency.CAD.opening: type integer"], f"{good} {missing} {hooked} {errs}")
    return (f"every curated tool ({len(ovr['schemas'])}, of which {len(mcp_reads)} read tools) has an output schema; the harness "
            f"validates every bnx_app call against it in every suite; a wrong enum, a missing required key, a number for a decimal "
            f"string and a wrong value under a keyed object (schema-valued additionalProperties, as in the Gateway) are each reported "
            f"with their path and no value")


# ---------------------------------------------------------------------------------------------- INS-1 signed releases
@test("AT-SIG-01", "INS-1 signed releases (Ed25519 detached signature over release/manifest.json; installer --require-signed)")
def t_signed_release(server, ev):    # noqa: ARG001 - no database needed
    tmp = tempfile.mkdtemp(prefix="bnx-sig-")
    try:
        man = os.path.join(tmp, "manifest.json")
        shutil.copyfile(RS.MANIFEST, man)
        priv, pub = os.path.join(tmp, "k.key"), os.path.join(tmp, "k.pub")
        kid = RS.keygen(priv, pub)
        mode = oct(os.stat(priv).st_mode & 0o777)
        inside = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools", "s4", "release_sign.py"), "keygen", "--private",
                                 os.path.join(h.ROOT, "release", "x.key"), "--public", os.path.join(tmp, "y.pub")], capture_output=True, text=True)
        unsigned = RS.verify(pub, man)
        RS.sign(priv, man)
        good = RS.verify(pub, man)
        sig = json.load(open(man + ".sig"))
        # the manifest changes after signing
        body = open(man).read()
        open(man, "w").write(body.replace('"format"', '"format" ', 1))
        changed = RS.verify(pub, man)
        # a signature whose digest was edited to match, but whose signature bytes are for the old body
        import hashlib
        json.dump({**sig, "manifest_sha256": hashlib.sha256(open(man, "rb").read()).hexdigest()}, open(man + ".sig", "w"))
        forged = RS.verify(pub, man)
        open(man, "w").write(body); RS.sign(priv, man)
        priv2, pub2 = os.path.join(tmp, "o.key"), os.path.join(tmp, "o.pub")
        RS.keygen(priv2, pub2)
        other = RS.verify(pub2, man)
        nokey = RS.verify(os.path.join(tmp, "absent.pub"), man)
        # migration files against the manifest
        mig = os.path.join(tmp, "mig")
        shutil.copytree(os.path.join(h.ROOT, "db", "migrations"), mig)
        clean = RS.check_files(man, mig)
        last = sorted(f for f in os.listdir(mig) if f.endswith(".sql"))[-1]
        open(os.path.join(mig, last), "a").write("\n-- edited\n")
        open(os.path.join(mig, "9999_s4_unlisted.sql"), "w").write("select 1;\n")
        dirty = RS.check_files(man, mig)
        # the installer: the repository release (unsigned) passes by default; --require-signed refuses it
        spec = importlib.util.spec_from_file_location("install_instance", os.path.join(h.ROOT, "deploy", "install_instance.py"))
        I = importlib.util.module_from_spec(spec); spec.loader.exec_module(I)
        base = dict(pg="host=127.0.0.1 dbname=balnexa user=balnexa_owner", runtime_host="ep-synthetic.c-8.us-east-2.aws.neon.tech",
                    project_id="synthetic-test-01", modules='{"Canada":"YES","International":"YES","CRA":"NO"}', worker_name="balnexa-test",
                    app_origin="https://balnexa-test.synthetic.workers.dev", kv_id="0" * 32,
                    google_client_id="1000000000001-abcdefghijklmnop.apps.googleusercontent.com", bind_owner_sub=None, secrets_dir="/nonexistent")
        dflt = I.validate(types.SimpleNamespace(**base))
        req = I.validate(types.SimpleNamespace(**base, require_signed=True))
        req_pub = I.validate(types.SimpleNamespace(**base, require_signed=True, release_pub=pub))
        plan = subprocess.run([sys.executable, os.path.join(h.ROOT, "deploy", "install_instance.py"), "--pg", base["pg"], "--runtime-host",
                               base["runtime_host"], "--project-id", base["project_id"], "--app-origin", base["app_origin"], "--kv-id",
                               base["kv_id"], "--google-client-id", base["google_client_id"], "--secrets-dir", "/nonexistent-dir", "--plan"],
                              capture_output=True, text=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    check(mode == "0o600" and inside.returncode != 0 and "outside the repository" in (inside.stdout + inside.stderr)
          and not os.path.exists(os.path.join(h.ROOT, "release", "x.key")), f"{mode} {inside}")
    check(unsigned == (False, "UNSIGNED") and good == (True, "VALID") and sig["key_id"] == kid and len(base64_len(sig["signature"])) == 64
          and changed == (False, "MANIFEST_CHANGED") and forged == (False, "SIGNATURE_INVALID") and other == (False, "KEY_MISMATCH")
          and nokey == (None, "NO_PUBLIC_KEY"), f"{unsigned} {good} {changed} {forged} {other} {nokey}")
    check(clean == [] and sorted(dirty) == sorted([f"CHANGED {last}", "UNLISTED 9999_s4_unlisted.sql"]), f"{clean} {dirty}")
    check(dflt == [] and req == ["--require-signed: the release signature is NO_PUBLIC_KEY"]
          and req_pub == ["--require-signed: the release signature is UNSIGNED"] and plan.returncode == 0
          and "0. release: signature NO_PUBLIC_KEY; migration files match" in plan.stdout, f"{dflt} {req} {req_pub} {plan.stdout} {plan.stderr}")
    return (f"key {kid}: private key 0600 and refused inside the repository; unsigned -> UNSIGNED, signed -> VALID, edited manifest -> "
            f"MANIFEST_CHANGED, edited digest -> SIGNATURE_INVALID, other key -> KEY_MISMATCH, no key -> NO_PUBLIC_KEY; an edited and an "
            f"unlisted migration are reported; the installer passes the unsigned repository release by default, refuses it with "
            f"--require-signed (no key / unsigned), and --plan reports the release state")


def base64_len(s):
    import base64
    return base64.b64decode(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core19", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core19_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
