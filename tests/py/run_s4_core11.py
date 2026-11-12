#!/usr/bin/env python3
"""S4 V1.2 increment 11 tests: 9012d matching MR-08...MR-13, onboarding job / file / history states, import mappings, payment
attributes and cross-source matches (UA V1.2 §5.6; BNX-S2-02; Draft-04 §C4/§C5, SHA-256 4ad49225...). Source rows, evidence
objects and clearing items are inserted as the definer, as document extraction and plans would leave them. Synthetic data
only. Conventions as run_g0.py.
Usage: run_s4_core11.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core10 as C10
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def household(server, db):
    H = C10.household(server, db)
    r = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Savings", currencies=["CAD"])
    H.sav = r["account_currencies"][0]
    H.cmd(H.owner, "set_opening", account_currency_id=H.sav["account_currency_id"], anchor_date="2026-01-01", amount="500.00")
    return H


def post(H, d, amt, ac, desc="synthetic", et="consumption_expense"):
    return H.cmd(H.owner, "post_transaction", economic_type=et, transaction_date=d, description=desc,
                 lines=[{"ledger_account_id": H.groceries, "currency": "CAD", "amount": amt.lstrip("-") if amt.startswith("-") else "-" + amt},
                        {"ledger_account_id": ac["ledger_account_id"], "currency": "CAD", "amount": amt}])["journal_id"]


def match(H, ac, d0="2026-01-01", d1="2026-12-31", cred=None):
    return H.cmd(cred or H.owner, "match_source_rows", account_currency_id=ac["account_currency_id"], date_from=d0, date_to=d1)


def states(H, ac, cred=None, **q):
    r = H.app.call("q_transfer_matching", cred or H.owner, {"account_currency_id": ac["account_currency_id"], **q})
    return {x["source_txn_id"]: x for x in r["rows"]}


def st(rows, src, kind="ledger"):
    d = [x for x in rows[src].get("decisions") or [] if x["kind"] == kind]
    return (d[0]["state"], d[0]["decision"], d[0]["rule"]) if d else (None, None, None)


@test("AT-MR-01", "Draft-04 §C4.3 MR-08/09/10, §C4.5 uniqueness, §C4.9 append-only decisions; OBJ-249 q_transfer_matching")
def t_ledger(server, ev):
    H = household(server, "bnx_c11mr1")
    out = {}
    j_strong = post(H, "2026-02-03", "-42.17", H.cad, desc="SYNTHETIC GROCER 123")
    s_strong = C10.row(H, H.cad, "2026-02-03", "-42.17", desc="SYNTHETIC GROCER 123")
    post(H, "2026-02-09", "-18.00", H.cad, desc="something else")
    s_single = C10.row(H, H.cad, "2026-02-10", "-18.00", desc="COFFEE SHOP")
    post(H, "2026-02-15", "-25.00", H.cad, desc="A"); post(H, "2026-02-16", "-25.00", H.cad, desc="B")
    s_amb = C10.row(H, H.cad, "2026-02-15", "-25.00", desc="PARKING")
    s_new = C10.row(H, H.cad, "2026-02-20", "-7.77", desc="NOTHING LIKE IT")
    j_posted = post(H, "2026-02-21", "-9.00", H.cad, desc="linked")
    s_posted = C10.row(H, H.cad, "2026-02-21", "-9.00", desc="linked", link=j_posted)
    out["run"] = match(H, H.cad)
    v1 = C10.version(H)
    rows = states(H, H.cad)
    out["first"] = {k: st(rows, s) for k, s in [("strong", s_strong), ("single", s_single), ("ambiguous", s_amb), ("new", s_new)]}
    out["posted"] = rows[s_posted].get("posted_journal_id") == j_posted
    out["rerun records nothing new"] = match(H, H.cad)["decisions_recorded"]
    with H.definer() as cx:
        legs = [str(r[0]) for r in cx.execute("select jl.id from bnx.journal_line jl join bnx.journal_entry je on je.id = jl.journal_id where "
                                              "jl.ledger_account_id = %s and jl.amount = -25.00 order by je.posting_date", (H.cad["ledger_account_id"],))]
    dec = lambda **kw: H.cmd(H.owner, "decide_match", kind="ledger", **kw)
    out["ambiguous without a leg"] = expect_err(dec, "VALIDATION_FAILED", source_txn_id=s_amb, decision="confirmed")
    dec(source_txn_id=s_amb, decision="confirmed", journal_line_id=legs[0])
    dec(source_txn_id=s_single, decision="rejected")
    out["confirm again"] = expect_err(dec, "MATCH_STATE", source_txn_id=s_single, decision="confirmed")
    out["reverse MR-08"] = dec(source_txn_id=s_strong, decision="rejected")["decision"]
    # a second row proposing the leg another row has confirmed: the leg is no longer a candidate
    s_dup = C10.row(H, H.cad, "2026-02-15", "-25.00", desc="PARKING AGAIN")
    match(H, H.cad)
    rows2 = states(H, H.cad)
    out["after decisions"] = {k: st(rows2, s) for k, s in [("strong", s_strong), ("single", s_single), ("ambiguous", s_amb), ("dup", s_dup)]}
    out["at v1"] = {k: st(states(H, H.cad, ledger_version=v1), s) for k, s in [("strong", s_strong), ("ambiguous", s_amb)]}
    out["viewer runs"] = expect_err(match, "FORBIDDEN_ROLE", H, H.cad, cred=H.viewer)
    out["member without grant reads the card"] = expect_err(states, "NOT_FOUND", H, H.card, H.member)
    with H.definer() as cx:
        out["events"] = cx.execute("select count(*) from bnx.match_decision_event").fetchone()[0]
        try:
            cx.execute("update bnx.match_decision_event set decision = 'confirmed'"); out["update"] = "ALLOWED"
        except psycopg.Error as e:
            out["update"] = (e.diag.message_primary or "")[:40]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-MR-01.json"), "w"), indent=1, default=str)
    check(out["first"] == {"strong": ("ledger_match_confirmed", "confirmed", "MR-08"), "single": ("ledger_match_proposed", "proposed", "MR-09"),
                           "ambiguous": ("ledger_match_ambiguous", "proposed", "MR-10"), "new": (None, None, None)} and out["posted"], f"{out['first']}")
    check(out["rerun records nothing new"] == 0 and out["reverse MR-08"] == "rejected", f"{out}")
    a = out["after decisions"]
    check(a["strong"][1] == "rejected" and a["single"][1] == "rejected" and a["ambiguous"][1] == "confirmed"
          and a["dup"] == ("ledger_match_proposed", "proposed", "MR-09"), f"{a}")
    check(out["at v1"]["strong"] == ("ledger_match_confirmed", "confirmed", "MR-08") and out["at v1"]["ambiguous"][0] == "ledger_match_ambiguous",
          f"{out['at v1']}")
    check(out["update"] != "ALLOWED", out["update"])
    return ("same date and description with one candidate on each side -> MR-08 confirmed automatically; one candidate each side "
            "otherwise -> MR-09 proposed; two candidate legs -> MR-10 ambiguous, confirmable only by naming a leg; a linked row is "
            "posted; a re-run records nothing new; member decisions stand and MR-08 can be reversed; a leg confirmed for one row "
            "is no longer offered to another (the other row's single remaining leg becomes MR-09); the earlier ledger version shows "
            "the earlier decisions; decisions are append-only events")


@test("AT-MR-02", "Draft-04 §C4.3 MR-11/12/13, INV-34; OBJ-249 cmd_match_clearing; S2 cross_source_match (OR-I-11)")
def t_transfer(server, ev):
    H = household(server, "bnx_c11mr2")
    out = {}
    a = C10.row(H, H.cad, "2026-03-02", "-300.00", desc="E-TRANSFER TO SAVINGS")
    b = C10.row(H, H.sav, "2026-03-04", "300.00", desc="TRANSFER IN")
    c = C10.row(H, H.cad, "2026-03-10", "-80.00", desc="TRANSFER")
    C10.row(H, H.sav, "2026-03-11", "80.00", desc="deposit x"); C10.row(H, H.card, "2026-03-12", "80.00", desc="payment")
    d = C10.row(H, H.cad, "2026-03-20", "-55.00", desc="TRANSFER OUT")          # no counterpart row; savings has no statement -> clearing
    match(H, H.cad); match(H, H.sav)
    r = states(H, H.cad)
    out["pair"], out["ambiguous"], out["no counterpart"] = st(r, a, "transfer_pair"), st(r, c, "transfer_pair"), r[d].get("decisions")
    out["counterpart side"] = st(states(H, H.sav), b, "transfer_pair")
    # with final statements covering every other account on that date, the counterpart is missing instead
    for ac in (H.sav, H.card):
        C10.stmt(H, ac, "2026-03-01", "2026-03-31", "0", "0", sign="owed_positive" if ac is H.card else "asset_positive")
    with H.definer() as cx:
        out["MR-12 with coverage"] = cx.execute("select bnx.match_propose(%s, (select version from bnx.ledger_state))->>'state'", (d,)).fetchone()[0]
        out["MR-12 without coverage"] = cx.execute("select bnx.match_propose(%s, 1)->>'state'", (d,)).fetchone()[0]
    # MR-13: an open clearing item on the chequing account hinting at savings; a savings row of the opposite amount resolves it
    jo = post(H, "2026-04-01", "-120.00", H.cad, desc="to savings later")
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        ci = cx.execute("insert into bnx.clearing_item(id, account_currency_id, currency, kind, amount, counterpart_hint, opened_journal) values "
                        "(gen_random_uuid(), %s, 'CAD', 'transfer_in_transit', -120.00, %s, %s) returning id",
                        (H.cad["account_currency_id"], json.dumps({"account_currency_id": H.sav["account_currency_id"], "window_days": 7}), jo)).fetchone()[0]
        cx.execute("insert into bnx.clearing_item_event(clearing_item_id, seq, event, recorded_version) values (%s, 1, 'opened', %s)", (ci, v))
        cx.commit()
    e = C10.row(H, H.sav, "2026-04-05", "120.00", desc="incoming")
    late = C10.row(H, H.sav, "2026-04-20", "120.00", desc="incoming late")
    match(H, H.sav, "2026-04-01", "2026-04-30")
    rs = states(H, H.sav)
    out["clearing in window"], out["clearing late"] = st(rs, e, "clearing_resolution"), rs[late].get("decisions")
    out["match clearing"] = H.cmd(H.owner, "match_clearing", source_txn_id=e, clearing_item_id=str(ci))["decision_event_id"] is not None
    out["second row for the same item"] = expect_err(H.cmd, "ALREADY_MATCHED", H.owner, "match_clearing", source_txn_id=late, clearing_item_id=str(ci))
    # cross-source match: a wallet row and the card row of the same purchase; the supporting row may not be posted
    w = C10.row(H, H.card, "2026-04-07", "-33.00", desc="APPLE PAY GROCER")
    k = C10.row(H, H.cad, "2026-04-07", "-33.00", desc="WALLET GROCER")
    m = H.cmd(H.owner, "cross_source_match", primary_source_txn_id=w, supporting_source_txn_id=k, kind="CARD_FUNDED_WALLET", state="PROPOSED")
    out["pair again"] = expect_err(H.cmd, "ALREADY_MATCHED", H.owner, "cross_source_match", primary_source_txn_id=k, supporting_source_txn_id=w,
                                   kind="WALLET_VS_BANK", state="PROPOSED")
    jk = post(H, "2026-04-07", "-33.00", H.cad, desc="posted by mistake")
    C10.link(H, k, jk)
    out["confirm with the supporting row posted"] = expect_err(H.cmd, "SUPPORTING_ROW_POSTED", H.owner, "cross_source_match", match_id=m["match_id"],
                                                               state="CONFIRMED")
    out["reject"] = H.cmd(H.owner, "cross_source_match", match_id=m["match_id"], state="REJECTED")["state"]
    out["decide again"] = expect_err(H.cmd, "MATCH_STATE", H.owner, "cross_source_match", match_id=m["match_id"], state="CONFIRMED")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-MR-02.json"), "w"), indent=1, default=str)
    check(out["pair"] == ("transfer_pair_proposed", "proposed", "MR-11") and out["counterpart side"][0] == "transfer_pair_proposed"
          and out["ambiguous"] == ("transfer_pair_ambiguous", "proposed", "MR-11") and out["no counterpart"] is None, f"{out}")
    check(out["MR-12 with coverage"] == "transfer_counterpart_missing" and out["MR-12 without coverage"] == "clearing_post", f"{out}")
    check(out["clearing in window"] == ("clearing_resolution_proposed", "proposed", "MR-13") and out["clearing late"] is None and out["match clearing"], f"{out}")
    check(out["reject"] == "REJECTED", f"{out}")
    return ("a transfer-like row with exactly one opposite row on another account within 5 days -> MR-11 pair proposed (both sides); "
            "two candidates -> ambiguous; no counterpart -> MR-12 clearing_post while other accounts lack statement coverage, "
            "counterpart_missing once every other account is covered; an open clearing item hinting at savings is resolved by the "
            "opposite savings row inside its window (MR-13), not by a late one, and cannot be matched twice; a cross-source match is "
            "unique per pair, cannot be confirmed once its supporting row is posted (no second journal), and is decided once")


@test("AT-ONB-01", "Draft-04 §C5.2-§C5.5 onboarding job, SF-*, AH-* states, progress counters; UA V1.2 posting_plan.job_id FK")
def t_onb(server, ev):
    H = household(server, "bnx_c11onb")
    out = {}
    cj = lambda **kw: H.cmd(H.owner, "onboarding_create_job", **kw)
    out["bad scope"] = expect_err(cj, "VALIDATION_FAILED", title="History", scope={"start_policy": "household_start_date"})
    out["unknown scope key"] = expect_err(cj, "VALIDATION_FAILED", title="History", scope={"start_policy": "manual", "note": "x"})
    job = cj(title="History 2019-2026", scope={"start_policy": "earliest_evidence"})["job_id"]
    q = lambda **kw: H.app.call("q_onboarding_job", H.owner, {"job_id": job, **kw})
    out["s0"] = q()["state"]
    with H.definer() as cx:
        eos = [str(cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state) values (gen_random_uuid(), "
                              "'orig/' || gen_random_uuid(), 10, 'unverified') returning id").fetchone()[0]) for _ in range(3)]
        cx.commit()
    add = lambda eo: H.cmd(H.owner, "onboarding_add_file", job_id=job, evidence_object_id=eo)
    out["s1"] = add(eos[0])["job_state"]; add(eos[1]); add(eos[2])
    out["same file twice"] = expect_err(add, "ALREADY_ADDED", eos[0])
    step = lambda kind, subj, state, detail=None: H.worker.call("wrk_onboarding_step", job, kind, subj, state, detail)
    step("file", eos[0], "SF-CLASSIFIED"); step("file", eos[0], "SF-ASSIGNED")
    step("file", eos[1], "SF-NOT_STATEMENT")
    out["skip a file state"] = expect_err(step, "ONBOARDING_STATE", "file", eos[2], "SF-EXTRACTED")
    for _ in range(3):
        step("file", eos[2], "SF-FAILED"); step("file", eos[2], "SF-QUEUED")
    step("file", eos[2], "SF-FAILED")
    out["dead after attempts"] = step("file", eos[2], "SF-DEAD")["job_state"]
    hist = lambda state, ac=H.cad, cred=None: H.cmd(cred or H.owner, "onboarding_history", job_id=job, account_currency_id=ac["account_currency_id"], state=state)
    hist("AH-PROPOSED")
    out["review"] = q()["state"]
    out["worker cannot approve"] = expect_err(step, "VALIDATION_FAILED", "history", H.cad["account_currency_id"], "AH-APPROVED")
    hist("AH-APPROVED")
    for s in ("AH-ORDERED", "AH-EXTRACTED", "AH-MATCHED", "AH-CLASSIFIED", "AH-READY"):
        step("history", H.cad["account_currency_id"], s)
    out["unblock a ready history"] = expect_err(hist, "ONBOARDING_STATE", "AH-READY")
    # a plan of this job: posting_plan.job_id references the job
    with H.definer() as cx:
        fk = cx.execute("select count(*) from pg_constraint where conname = 'posting_plan_job_fk' and contype = 'f' "
                        "and confrelid = 'bnx.onboarding_job'::regclass and conrelid = 'bnx.posting_plan'::regclass").fetchone()[0]
    for s in ("AH-PLANNED", "AH-PLAN_APPROVED", "AH-POSTING"):
        step("history", H.cad["account_currency_id"], s)
    out["posting"] = q()["state"]
    step("history", H.cad["account_currency_id"], "AH-ACTIVE")
    out["reconciling"] = q()["state"]
    hist("AH-PROPOSED", H.sav); hist("AH-EXCLUDED", H.sav)
    step("history", H.cad["account_currency_id"], "AH-RECONCILED_WITH_EXCEPTIONS")
    out["before closing"] = q()["state"]
    H.cmd(H.owner, "onboarding_job_event", job_id=job, event="collection_closed")
    out["after closing"] = q()["state"]
    out["add after closing"] = expect_err(add, "COLLECTION_CLOSED", eos[0])
    H.cmd(H.owner, "onboarding_job_event", job_id=job, event="paused")
    out["worker while paused"] = expect_err(step, "ONBOARDING_STATE", "history", H.cad["account_currency_id"], "AH-BLOCKED")
    out["paused"] = q()["state"]
    out["resume"] = H.cmd(H.owner, "onboarding_job_event", job_id=job, event="resumed")["job_state"]
    out["counters"] = q()
    out["member reads another's job"] = expect_err(H.app.call, "NOT_FOUND", "q_onboarding_job", H.member, {"job_id": job})
    out["member history on the card"] = expect_err(H.cmd, "NOT_FOUND", H.member, "onboarding_history", job_id=job,
                                                   account_currency_id=H.card["account_currency_id"], state="AH-PROPOSED")
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-ONB-01.json"), "w"), indent=1, default=str)
    check(out["s0"] == "ONB-DRAFT" and out["s1"] == "ONB-COLLECTING" and out["review"] == "ONB-REVIEW" and out["posting"] == "ONB-POSTING"
          and out["reconciling"] == "ONB-RECONCILING" and out["before closing"] == "ONB-PROCESSING"
          and out["after closing"] == "ONB-COMPLETED_WITH_EXCEPTIONS" and out["paused"] == "ONB-PAUSED"
          and out["resume"] == "ONB-COMPLETED_WITH_EXCEPTIONS", f"{out}")
    check(out["dead after attempts"] and fk == 1, f"{out} {fk}")
    c = out["counters"]
    check(c["files_by_state"] == {"SF-ASSIGNED": 1, "SF-NOT_STATEMENT": 1, "SF-DEAD": 1}
          and sorted(x["state"] for x in c["histories"]) == ["AH-EXCLUDED", "AH-RECONCILED_WITH_EXCEPTIONS"], f"{c}")
    return ("job states derived from item states (DRAFT -> COLLECTING -> REVIEW -> POSTING -> RECONCILING -> PROCESSING until "
            "collection closes -> COMPLETED_WITH_EXCEPTIONS; PAUSED and back); file and history transitions enforced (no skipped "
            "stage, SF-DEAD only after 3 failed attempts, members approve or exclude, the worker records deterministic stages and "
            "stops while paused); posting_plan.job_id references the job; counters come from the tables; another member's job and "
            "an ungranted account are not visible")


@test("AT-IMP-PAY-01", "S2-02 import_mapping (data, not code), payment_attribute (OR-I-11 attributes, never accounts)")
def t_map(server, ev):
    H = household(server, "bnx_c11map")
    out = {}
    base = dict(provider="GENERIC_CSV", label="Synthetic bank CSV", column_map={"posting_date": "Date", "amount": "Amount", "description": "Memo"},
                date_rules={"format": "YYYY-MM-DD"}, amount_rules={"decimal_separator": "."}, status="ACTIVE")
    m1 = H.cmd(H.owner, "set_import_mapping", **base)
    m2 = H.cmd(H.owner, "set_import_mapping", mapping_id=m1["mapping_id"], **{**base, "status": "RETIRED"})
    out["versions"] = (m1["version"], m2["version"])
    out["provider change"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_import_mapping", mapping_id=m1["mapping_id"], **{**base, "provider": "OFX"})
    out["unknown column key"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_import_mapping", **{**base, "column_map": {"script": "x"}})
    out["member"] = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_import_mapping", **base)
    j = post(H, "2026-05-01", "-12.00", H.card, desc="APPLE PAY", et="card_spend")
    out["attribute"] = H.cmd(H.owner, "set_payment_attribute", journal_id=j, payment_method="APPLE_PAY", payment_network="UNIONPAY")["seq"]
    out["unknown network"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_payment_attribute", journal_id=j, payment_network="WALLETNET")
    out["member without grant"] = expect_err(H.cmd, "NOT_FOUND", H.member, "set_payment_attribute", journal_id=j, payment_method="APPLE_PAY")
    with H.definer() as cx:
        out["no wallet account created"] = cx.execute("select count(*) from bnx.account where label ilike '%apple%'").fetchone()[0]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-IMP-PAY-01.json"), "w"), indent=1, default=str)
    check(out["versions"] == (1, 2) and out["attribute"] == 1 and out["no wallet account created"] == 0, f"{out}")
    return ("an import mapping is versioned data with closed keys, keeps its provider and is Owner/admin only; Apple Pay and "
            "UnionPay are recorded as attributes of the card journal, no wallet account appears; unknown values and ungranted "
            "members refused")


@test("AT-9012d-CAT", "9012d catalog: append-only, transition triggers, flag on account_history_state, catalog rows, grants")
def t_cat(server, ev):
    db = "bnx_c11cat"
    h.bootstrap(server, db); h.migrate(server, db)
    names = ("import_mapping", "payment_attribute", "cross_source_match", "cross_source_match_event", "onboarding_job", "onboarding_job_event",
             "source_file_state", "account_history_state")
    with C1.migrator(server, db) as cx:
        ao = cx.execute("select count(distinct c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 't_append_only' "
                        "and c.relname = any(%s)", (list(names),)).fetchone()[0]
        tr = cx.execute("select count(*) from pg_trigger where tgname in ('t_onboarding_transition','t_scope_flag_account_history_state')").fetchone()[0]
        fs = cx.execute("select function_name, scope from bnx.function_scope where function_name in ('q_transfer_matching','q_onboarding_job') "
                        "order by 1").fetchall()
        g = cx.execute("select p.proname, has_function_privilege('bnx_app', p.oid, 'execute'), has_function_privilege('bnx_worker', p.oid, 'execute') "
                       "from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and p.proname in "
                       "('wrk_onboarding_step','cmd_match_source_rows','match_propose') order by 1").fetchall()
        tc = cx.execute("select count(*) from bnx.table_class where table_name = any(%s)", (list(names),)).fetchone()[0]
    check(ao == 8 and tr == 3 and tc == 8, f"{ao} {tr} {tc}")
    check(fs == [("q_onboarding_job", "finance.read"), ("q_transfer_matching", "finance.read")], f"{fs}")
    check(g == [("cmd_match_source_rows", True, False), ("match_propose", False, False), ("wrk_onboarding_step", False, True)], f"{g}")
    return ("the 8 new tables are append-only and classed; SF/AH transition triggers and the module flag on account_history_state "
            "exist; both queries are finance.read; commands go to bnx_app, wrk_onboarding_step to bnx_worker only, internal "
            "helpers to nobody")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core11", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core11_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
