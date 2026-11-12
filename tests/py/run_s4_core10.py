#!/usr/bin/env python3
"""S4 V1.2 increment 10 tests: 9012c balance observations, statement periods and the deterministic reconciliation engine
(UA V1.2 §5.6; Draft-04 §D1-§D7, SHA-256 4ad49225...). Statements, statement rows and links are inserted as the definer, as
document extraction would leave them (no writer exists yet). Synthetic data only. Conventions as run_g0.py.
Usage: run_s4_core10.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import sin_corpus as SC
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check
EVID = {"doc": "synthetic-statement"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def version(H):
    with H.definer() as cx:
        return cx.execute("select version from bnx.ledger_state").fetchone()[0]


def household(server, db):
    H = C4.v2_full(server, db)
    r = H.cmd(H.owner, "create_account", kind="credit_card", **H.inst("Synthetic Bank"), label="Synthetic card", currencies=["CAD"],
              visibility="private")
    H.card_acc, H.card = r["account_id"], r["account_currencies"][0]
    H.cmd(H.owner, "invite_member", display_name="Viewer O", role="viewer", google_sub="g-viewer-o")
    H.viewer = H.login("g-viewer-o")
    return H


def obs(H, cred=None, ac=None, **kw):
    return H.cmd(cred or H.owner, "record_observation", account_currency_id=(ac or H.cad)["account_currency_id"], **kw)


def listing(H, cred=None, ac=None, **q):
    return H.app.call("q_balance_observations", cred or H.owner, {"account_currency_id": (ac or H.cad)["account_currency_id"], **q})


@test("AT-OBS-01", "UA V1.2 §5.6 balance observations (S4B-F04): events only, checkpoint for MEMBER, derived supersession, conflicts kept")
def t_obs(server, ev):
    H = household(server, "bnx_c10obs")
    out = {}
    m = obs(H, source="MEMBER", observed_at="2026-03-31T23:30:00-04:00", amount="1000.00")
    with H.definer() as cx:
        out["checkpoint"] = cx.execute("select as_of::text, amount::text, kind from bnx.balance_checkpoint where id = %s",
                                       (m["checkpoint_id"],)).fetchone()
    out["statement without evidence"] = expect_err(obs, "VALIDATION_FAILED", H, source="STATEMENT", observed_at="2026-03-31T23:59:59-04:00",
                                                   amount="990.00")
    s1 = obs(H, source="STATEMENT", observed_at="2026-03-31T23:59:59-04:00", amount="990.00", evidence_ref=EVID)
    obs(H, source="EXPORT", observed_at="2026-03-31T23:59:59-04:00", amount="1000.00", evidence_ref={"doc": "synthetic-export"})
    v_before = version(H)
    s2 = obs(H, source="STATEMENT", observed_at="2026-03-31T23:59:59-04:00", amount="995.00", evidence_ref={"doc": "synthetic-statement-v2"})
    e1 = obs(H, source="EMAIL_NOTICE", observed_at="2026-03-15T09:00:00-04:00", amount="800.00", evidence_ref={"doc": "synthetic-notice"})
    e2 = obs(H, source="EMAIL_NOTICE", observed_at="2026-03-15T10:00:00-04:00", amount="805.00", evidence_ref={"doc": "synthetic-notice-2"},
             revision_of=e1["event_seq"])
    out["current"] = listing(H)
    out["with superseded"] = listing(H, include_superseded=True)
    out["at the earlier version"] = listing(H, ledger_version=v_before)
    out["card default sign"] = obs(H, ac=H.card, source="MEMBER", observed_at="2026-03-31T12:00:00-04:00", amount="250.00")
    with H.definer() as cx:
        out["card sign stored"] = cx.execute("select sign_convention from bnx.balance_observation_event where account_currency_id = %s",
                                             (H.card["account_currency_id"],)).fetchone()[0]
    out["refused"] = {
        "revision of another source": expect_err(obs, "VALIDATION_FAILED", H, source="EXPORT", observed_at="2026-03-31T23:59:59-04:00",
                                                 amount="1.00", evidence_ref=EVID, revision_of=e1["event_seq"]),
        "other currency": expect_err(obs, "VALIDATION_FAILED", H, source="MEMBER", observed_at="2026-03-31T12:00:00Z", amount="1.00", currency="USD"),
        "3 decimals": expect_err(obs, "VALIDATION_FAILED", H, source="MEMBER", observed_at="2026-03-31T12:00:00Z", amount="1.005"),
        "unknown tz": expect_err(obs, "VALIDATION_FAILED", H, source="MEMBER", observed_at="2026-03-31T12:00:00Z", amount="1.00", tz="Mars/Base"),
        "unknown source": expect_err(obs, "VALIDATION_FAILED", H, source="GUESS", observed_at="2026-03-31T12:00:00Z", amount="1.00", evidence_ref=EVID),
        "viewer": expect_err(obs, "FORBIDDEN_ROLE", H, H.viewer, source="MEMBER", observed_at="2026-03-31T12:00:00Z", amount="1.00"),
        "member without grant (record)": expect_err(obs, "NOT_POSTABLE", H, H.member, ac=H.card, source="MEMBER",
                                                    observed_at="2026-03-31T12:00:00Z", amount="1.00"),
        "member without grant (read)": expect_err(listing, "NOT_FOUND", H, H.member, ac=H.card),
    }
    n0 = len(listing(H, include_superseded=True)["observations"])
    out["refused"]["evidence holding a SIN candidate"] = expect_err(obs, "SIN_CANDIDATE", H, source="STATEMENT", observed_at="2026-04-30T12:00:00Z",
                                                                    amount="1.00", evidence_ref={"note": "SIN " + SC.value("luhn", 9013)})
    n1 = len(listing(H, include_superseded=True)["observations"])
    try:
        with H.definer() as cx:
            cx.execute("update bnx.balance_observation_event set amount = 0"); out["update"] = "ALLOWED"
    except psycopg.Error as e:
        out["update"] = (e.diag.message_primary or "")[:40]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-OBS-01.json"), "w"), indent=1, default=str)
    cur = {o["event_seq"]: o for o in out["current"]["observations"]}
    allo = {o["event_seq"]: o for o in out["with superseded"]["observations"]}
    old = {o["event_seq"]: o for o in out["at the earlier version"]["observations"]}
    check(out["checkpoint"] == ("2026-03-31", "1000.0000", "member_spot_check"), f"{out['checkpoint']}")
    check(set(cur) == {m["event_seq"], s2["event_seq"], s1["event_seq"] + 1, e2["event_seq"]}, f"{sorted(cur)}")
    check(allo[s1["event_seq"]]["current"] is False and allo[e1["event_seq"]]["current"] is False and len(allo) == 6, f"{allo}")
    check(old[s1["event_seq"]]["current"] is True and s2["event_seq"] not in old, f"{old}")
    conf = out["current"]["conflicts"]
    check(len(conf) == 1 and conf[0]["event_seqs"] == [s1["event_seq"] + 1, s2["event_seq"]], f"{conf}")
    check(len(out["at the earlier version"]["conflicts"]) == 1, f"{out['at the earlier version']['conflicts']}")
    check(out["card sign stored"] == "owed_positive" and n0 == n1 and out["update"] != "ALLOWED", f"{out['card sign stored']} {n0} {n1} {out['update']}")
    return ("a MEMBER observation writes one balance_checkpoint (member_spot_check, local date 2026-03-31 for 23:30 Toronto); "
            "other sources need evidence; a later observation of the same instant and source supersedes the earlier one and an "
            "explicit revision supersedes its target, both derived (nothing updated); the earlier ledger version still shows "
            "the superseded statement value; two sources disagreeing at one instant are both kept and listed as a conflict; a "
            "card observation defaults to owed_positive; 8 invalid or unauthorised calls refused; evidence holding a SIN "
            "candidate is refused with nothing stored; the table is append-only")


@test("AT-STP-01", "UA V1.2 §5.6 statement coverage view (R15 input; partial periods never final)")
def t_stp(server, ev):
    H = household(server, "bnx_c10stp")
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        eo = cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state) values (gen_random_uuid(), "
                        "'orig/' || gen_random_uuid(), 10, 'unverified') returning id").fetchone()[0]
        doc = cx.execute("insert into bnx.document(id, evidence_object_id, seq, doc_type) values (gen_random_uuid(), %s, 1, 'bank_statement') "
                         "returning id", (eo,)).fetchone()[0]
        ac = H.cad["account_currency_id"]
        mk = lambda acid, ps, pe, cb: cx.execute(
            "insert into bnx.statement(id, document_id, account_currency_id, currency, period_start, period_end, closing_balance, "
            "sign_convention) values (gen_random_uuid(), %s, %s, 'CAD', %s, %s, %s, 'asset_positive') returning id",
            (doc, acid, ps, pe, cb)).fetchone()[0]
        full = mk(ac, "2026-03-01", "2026-03-31", "990.00")
        part = mk(ac, "2026-04-01", None, None)
        gone = mk(ac, "2026-02-01", "2026-02-28", "900.00")
        unassigned = mk(None, "2026-01-01", "2026-01-31", "800.00")
        ev_ = lambda sid, seq, e, p, rv: cx.execute("insert into bnx.statement_event values (%s, %s, %s, %s, %s, %s)",
                                                    (sid, seq, e, json.dumps(p), rv, H.owner_id if hasattr(H, "owner_id") else "00000000-0000-4000-8000-000000000000"))
        ev_(full, 1, "confirmed", {}, v); ev_(full, 2, "version_role_set", {"role": "original"}, v)
        ev_(part, 1, "confirmed", {}, v)
        ev_(gone, 1, "confirmed", {}, v); ev_(gone, 2, "withdrawn", {}, v + 5)
        ev_(unassigned, 1, "assigned", {"account_currency_id": ac}, v)
        cx.commit()
        cols = "statement_id, account_currency_id, partial, final, confirmed, version_role"
        now = {r[0]: r[1:] for r in cx.execute(f"select {cols} from bnx.statement_period").fetchall()}
        later = {r[0]: r[1:] for r in cx.execute(f"select {cols} from bnx.statement_period_at(%s)", (v + 5,)).fetchall()}
    H.close()
    out = {"now": {str(k): v_ for k, v_ in now.items()}, "at v+5": {str(k): v_ for k, v_ in later.items()}}
    json.dump(out, open(os.path.join(ev, "AT-STP-01.json"), "w"), indent=1, default=str)
    acu = __import__("uuid").UUID(ac)
    check(now[full] == (acu, False, True, True, "original"), f"{now[full]}")
    check(now[part] == (acu, True, False, True, None), f"{now[part]}")
    check(gone in now and gone not in later and len(later) == 3, f"{sorted(map(str, later))}")
    check(now[unassigned][0] == acu and now[unassigned][3] is False and now[unassigned][2] is False, f"{now[unassigned]}")
    return ("a confirmed statement with both bounds and a closing balance is final with its version role; a confirmed statement "
            "without an end date or closing balance is partial and never final; a withdrawal hides the statement from the version "
            "it was recorded at (still listed before); an unassigned statement takes its account-currency from the latest "
            "'assigned' event and is not final until confirmed")


# ------------------------------------------------------------------------------------------------ reconciliation engine
def post(H, et, d, lines):
    return H.cmd(H.owner, "post_transaction", economic_type=et, transaction_date=d, description="synthetic",
                 lines=[{"ledger_account_id": la, "currency": "CAD", "amount": amt} for la, amt in lines])["journal_id"]


def stmt(H, ac, ps, pe, opening, closing, sign="asset_positive", verified=True, confirm=True):
    """a statement as document extraction would leave it (synthetic, inserted as the definer)"""
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        eo = cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, sha256, integrity_state) values (gen_random_uuid(), "
                        "'orig/' || gen_random_uuid(), 10, case when %s then sha256(gen_random_uuid()::text::bytea) end, %s) returning id",
                        (verified, "verified" if verified else "unverified")).fetchone()[0]
        doc = cx.execute("insert into bnx.document(id, evidence_object_id, seq, doc_type) values (gen_random_uuid(), %s, 1, 'bank_statement') "
                         "returning id", (eo,)).fetchone()[0]
        sid = cx.execute("insert into bnx.statement(id, document_id, account_currency_id, currency, period_start, period_end, opening_balance, "
                         "closing_balance, sign_convention) values (gen_random_uuid(), %s, %s, 'CAD', %s, %s, %s, %s, %s) returning id",
                         (doc, ac["account_currency_id"], ps, pe, opening, closing, sign)).fetchone()[0]
        if confirm:
            cx.execute("insert into bnx.statement_event values (%s, 1, 'confirmed', '{}', %s, %s)", (sid, v, H.owner_id))
        cx.commit()
    return str(sid)


def row(H, ac, d, amount, desc="synthetic row", link=None):
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        t = cx.execute("insert into bnx.source_txn(id, account_currency_id, posting_date, amount, currency, normalized_description, "
                       "canonical_occurrence, source_fingerprint) values (gen_random_uuid(), %s, %s, %s, 'CAD', %s, 1, "
                       "sha256(gen_random_uuid()::text::bytea)) returning id", (ac["account_currency_id"], d, amount, desc)).fetchone()[0]
        if link:
            cx.execute("insert into bnx.source_link_event(source_txn_id, journal_id, event, recorded_version) values (%s, %s, 'linked', %s)",
                       (t, link, v))
        cx.commit()
    return str(t)


def link(H, src, journal):
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        cx.execute("insert into bnx.source_link_event(source_txn_id, journal_id, event, recorded_version) values (%s, %s, 'linked', %s)", (src, journal, v))
        cx.commit()


def run(H, cred=None, **kw):
    return H.cmd(cred or H.owner, "run_reconciliation", **kw)


def findings(H, cred=None, **q):
    return H.app.call("q_reconciliation_exceptions", cred or H.owner, q)["exceptions"]


@test("AT-RCN-01", "Draft-04 §D2-§D5, §D7 Δ3: a deterministic finding is confirmed only with C1-C5; resolution by action re-runs to matched")
def t_rcn1(server, ev):
    H = household(server, "bnx_c10rcn1")
    out = {}
    # ledger: opening 1000.00 on 01-01, a purchase of 100.00 on 01-05. Statement 01-02..01-31: opening 1000.00, rows -100.00 (posted)
    # and -50.00 "MONTHLY FEE" (not posted), closing 850.00. Stage 1: 1000 - 150 = 850 -> pass. Stage 2: 850 - 900 = -50.
    j1 = post(H, "consumption_expense", "2026-01-05", [(H.groceries, "100.00"), (H.cad["ledger_account_id"], "-100.00")])
    s = stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "850.00")
    row(H, H.cad, "2026-01-05", "-100.00", link=j1)
    fee = row(H, H.cad, "2026-01-10", "-50.00", desc="MONTHLY FEE")
    out["run 1"] = run(H, statement_id=s)
    v1 = version(H)
    out["findings 1"] = findings(H)
    f1 = out["findings 1"][0]
    # the member investigates, then posts the missing fee (D7 POST_MISSING_ROW) and links the row; the re-run is matched
    H.cmd(H.owner, "set_reconciliation_exception_state", exception_id=f1["exception_id"], phase="investigating")
    jf = post(H, "fee", "2026-01-10", [(H.groceries, "50.00"), (H.cad["ledger_account_id"], "-50.00")])
    link(H, fee, jf)
    out["run 2"] = run(H, statement_id=s)
    out["findings at v1"] = findings(H, ledger_version=v1)
    out["findings now"] = findings(H)
    with H.definer() as cx:
        out["events of finding 1"] = cx.execute("select state, phase, resolution_action from bnx.reconciliation_exception_event "
                                                "where exception_id = %s order by seq", (f1["exception_id"],)).fetchall()
    out["coverage"] = H.app.call("q_reconciliation_coverage", H.owner, {"account_currency_id": H.cad["account_currency_id"]})
    out["viewer runs"] = expect_err(run, "FORBIDDEN_ROLE", H, H.viewer, statement_id=s)
    out["member without grant on the card"] = expect_err(run, "NOT_POSTABLE", H, H.member, account_currency_id=H.card["account_currency_id"],
                                                         observation_event_seq=1)
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-RCN-01.json"), "w"), indent=1, default=str)
    check(out["run 1"]["stage1_state"] == "pass" and out["run 1"]["stage2_state"] == "difference_open" and out["run 1"]["difference"] == "-50.0000",
          f"{out['run 1']}")
    check(len(out["findings 1"]) == 1 and f1["rule_code"] == "RC-05" and f1["classification"] == "confirmed" and f1["confirmation"] == "deterministic"
          and all(f1["criteria"][k]["ok"] for k in ("C2", "C3", "C4", "C5")) and f1["criteria"]["C1"] is True and f1["amount_effect"] == "-50.0000",
          f"{f1}")
    check(out["run 2"]["stage2_state"] == "matched" and out["run 2"]["findings"] == 0 and out["findings now"] == [], f"{out['run 2']}")
    check([x.get("rule_code") for x in out["findings at v1"]] == ["RC-05"] and out["findings at v1"][0]["state"] == "OPEN", f"{out['findings at v1']}")
    check(out["events of finding 1"] == [("OPEN", "findings_ready", None), ("OPEN", "investigating", None), ("RESOLVED", "resolved_matched", "RERUN_MATCHED")],
          f"{out['events of finding 1']}")
    cov = out["coverage"]
    check(cov["gaps"] == [] and cov["statements"][0]["stage2_state"] == "matched" and cov["statements"][0]["final"] is True, f"{cov}")
    return ("an unposted fee row is RC-05 (the fee subtype of RC-01), confirmed by the engine because C1-C5 all hold and are stored "
            "(verified evidence, stage 1 pass, no gap, exact closure -50.00, no competing explanation); the member investigates, posts "
            "the fee and links the row; the re-run is matched and the finding becomes RESOLVED / RERUN_MATCHED; the earlier ledger version "
            "still shows the open finding; coverage shows the statement final and matched with no gap; viewer and ungranted member refused")


@test("AT-RCN-02", "Draft-04 §D4 RC-01/03/07/14, §D5 C5: a competing explanation keeps every finding probable; remainder unresolved")
def t_rcn2(server, ev):
    H = household(server, "bnx_c10rcn2")
    out = {}
    sav = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Savings", currencies=["CAD"])["account_currencies"][0]
    j1 = post(H, "consumption_expense", "2026-01-05", [(H.groceries, "100.00"), (H.cad["ledger_account_id"], "-100.00")])
    post(H, "consumption_expense", "2026-01-15", [(H.groceries, "45.00"), (H.cad["ledger_account_id"], "-45.00")])        # not on the statement
    post(H, "consumption_expense", "2026-01-12", [(H.groceries, "200.00"), (sav["ledger_account_id"], "-200.00")])         # wrong account?
    s = stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "700.00")
    row(H, H.cad, "2026-01-05", "-100.00", link=j1)
    row(H, H.cad, "2026-01-12", "-200.00")
    # statement 700.00; ledger 1000 - 100 - 45 = 855.00; difference -155.00 = RC-01 (-200.00) + RC-03 (+45.00)
    out["run"] = run(H, statement_id=s)
    out["findings"] = findings(H)
    # a second statement whose difference the rows do not explain: remainder unresolved
    j5 = post(H, "consumption_expense", "2026-02-03", [(H.groceries, "10.00"), (H.cad["ledger_account_id"], "-10.00")])
    s2 = stmt(H, H.cad, "2026-02-01", "2026-02-28", "700.00", "680.00")
    row(H, H.cad, "2026-02-03", "-10.00", link=j5)
    row(H, H.cad, "2026-02-04", "-10.00")
    out["run feb"] = run(H, statement_id=s2)
    out["findings feb"] = [x for x in findings(H) if x["subject"].get("statement_id") == s2]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-RCN-02.json"), "w"), indent=1, default=str)
    by = {}
    for x in out["findings"]:
        by.setdefault(x.get("rule_code"), []).append(x)
    check(out["run"]["difference"] == "-155.0000" and set(by) == {"RC-01", "RC-03", "RC-07"}, f"{sorted(by)} {out['run']}")
    check(all(x["classification"] == "probable" for x in out["findings"]), f"{[(x.get('rule_code'), x['classification']) for x in out['findings']]}")
    r1 = by["RC-01"][0]
    check(r1["criteria"]["C4"]["ok"] is True and r1["criteria"]["C5"]["ok"] is False and r1["criteria"]["C2"]["ok"] is True
          and by["RC-03"][0]["amount_effect"] == "45.0000" and len(r1["criteria"]["C5"]["subset_search"]["subsets"]) == 1, f"{r1['criteria']}")
    # Feb: statement 680.00; ledger 855 - 10 = 845; but the Jan statement says 700 (chain pass on printed values). difference -165.00;
    # RC-01 -10.00 explains part; -155.00 remains unresolved (the January difference was never posted)
    fb = {x.get("rule_code"): x for x in out["findings feb"]}
    check(out["run feb"]["difference"] == "-165.0000" and fb["RC-01"]["amount_effect"] == "-10.0000" and fb[None]["classification"] == "unresolved"
          and fb[None]["amount_effect"] == "-155.0000", f"{out['findings feb']}")
    return ("difference -155.00 is closed exactly by RC-01 (-200.00 row not posted) and RC-03 (+45.00 ledger leg not on the statement), "
            "but the same -200.00 on the same date sits on another account (RC-07), a competing explanation: C5 fails and every finding is "
            "probable; the subset search (RC-14 input to C5) finds exactly one closing subset; in the next month the part not explained by RC-01 "
            "(-155.00) is an unresolved remainder without a rule code")


@test("AT-RCN-03", "Draft-04 §D2/§D3: stage-1 failure and acceptance, RC-09/10/11/12/13, owed_positive, unverified evidence, observations")
def t_rcn3(server, ev):
    H = household(server, "bnx_c10rcn3")
    out = {}
    # stage 1 fail: 1000 - 50 != 900 (arithmetic difference 50.00) -> not evaluated; accepted by the member -> evaluated, RC-09 probable
    s = stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "900.00")
    j = post(H, "consumption_expense", "2026-01-06", [(H.groceries, "50.00"), (H.cad["ledger_account_id"], "-50.00")])
    row(H, H.cad, "2026-01-06", "-50.00", link=j)
    out["stage1 fail"] = run(H, statement_id=s)
    out["accepted"] = run(H, statement_id=s, accept_stage1_fail=True)
    acc = {x.get("rule_code"): x for x in findings(H) if x["subject"].get("statement_id") == s}
    out["accepted findings"] = acc
    # March statement while February is not covered: incomplete history, RC-11 unresolved; also a transposition (RC-13):
    # row -54.10 posted as -45.10 -> difference -9.00
    jt = post(H, "consumption_expense", "2026-03-04", [(H.groceries, "45.10"), (H.cad["ledger_account_id"], "-45.10")])
    s3 = stmt(H, H.cad, "2026-03-01", "2026-03-31", "950.00", "895.90")
    row(H, H.cad, "2026-03-04", "-54.10", link=jt)
    out["gap"] = run(H, statement_id=s3)
    g = [x for x in findings(H) if x["subject"].get("statement_id") == s3]
    out["gap findings"] = [(x.get("rule_code"), x["classification"]) for x in g]
    # RC-10 on an unverified first statement: opening 990.00 vs ledger 1000.00 on the day before, nothing else (difference -10.00)
    def acct(label):
        x = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label=label, currencies=["CAD"])["account_currencies"][0]
        H.cmd(H.owner, "set_opening", account_currency_id=x["account_currency_id"], anchor_date="2026-01-01", amount="1000.00")
        return x
    chq2 = acct("Joint")
    s4 = stmt(H, chq2, "2026-01-02", "2026-01-31", "990.00", "990.00", verified=False)
    out["rc10"] = run(H, statement_id=s4)
    f4 = {x.get("rule_code"): x for x in findings(H) if x["subject"].get("statement_id") == s4}
    # RC-12: a +30.00 deposit posted as -30.00 -> difference 60.00 = 2 x 30.00
    chq3 = acct("Second")
    jw = post(H, "consumption_expense", "2026-01-08", [(H.groceries, "30.00"), (chq3["ledger_account_id"], "-30.00")])
    s5 = stmt(H, chq3, "2026-01-02", "2026-01-31", "1000.00", "1030.00")
    row(H, chq3, "2026-01-08", "30.00", link=jw)
    out["rc12"] = run(H, statement_id=s5)
    f5 = {x.get("rule_code"): x for x in findings(H) if x["subject"].get("statement_id") == s5}
    out["rc10 findings"], out["rc12 findings"] = f4, f5
    # a credit card with an owed_positive statement: 250.00 owed = ledger -250.00 -> matched
    H.cmd(H.owner, "set_opening", account_currency_id=H.card["account_currency_id"], anchor_date="2026-01-01", amount="0")
    jc = post(H, "card_spend", "2026-01-09", [(H.groceries, "250.00"), (H.card["ledger_account_id"], "-250.00")])
    sc = stmt(H, H.card, "2026-01-02", "2026-01-31", "0", "250.00", sign="owed_positive")
    row(H, H.card, "2026-01-09", "-250.00", link=jc)
    out["card"] = run(H, statement_id=sc)
    # observations: a member and a statement value at the same instant that disagree -> conflict recorded; difference unresolved
    o1 = obs(H, source="MEMBER", observed_at="2026-01-31T20:00:00-05:00", amount="940.00")
    obs(H, source="STATEMENT", observed_at="2026-01-31T20:00:00-05:00", amount="950.00", evidence_ref=EVID)
    out["observation"] = run(H, account_currency_id=H.cad["account_currency_id"], observation_event_seq=o1["event_seq"])
    ob = [x for x in findings(H) if x["subject"].get("observation_event_seq") == o1["event_seq"]]
    out["observation findings"] = ob
    out["unconfirmed statement"] = run(H, statement_id=stmt(H, H.cad, "2026-04-01", "2026-04-30", "895.90", "895.90", confirm=False))
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-RCN-03.json"), "w"), indent=1, default=str)
    check(out["stage1 fail"]["stage1_state"] == "fail" and out["stage1 fail"]["stage2_state"] == "not_evaluated", f"{out['stage1 fail']}")
    check(out["accepted"]["stage1_state"] == "fail_accepted_by_member" and out["accepted"]["stage2_state"] == "difference_open"
          and acc["RC-09"]["classification"] == "probable" and acc["RC-09"]["criteria"]["C3"]["ok"] is False, f"{acc}")
    check(out["gap"]["stage2_state"] == "incomplete_history" and ("RC-11", "unresolved") in out["gap findings"]
          and ("RC-13", "probable") in out["gap findings"] and out["gap"]["difference"] == "-9.0000", f"{out['gap']} {out['gap findings']}")
    check(out["rc10"]["difference"] == "-10.0000" and f4["RC-10"]["amount_effect"] == "-10.0000" and f4["RC-10"]["classification"] == "probable"
          and f4["RC-10"]["criteria"]["C2"]["ok"] is False and f4["RC-10"]["criteria"]["C2"]["evidence_integrity"] == "unverified"
          and f4["RC-10"]["criteria"]["C4"]["ok"] is True, f"{f4}")
    check(out["rc12"]["difference"] == "60.0000" and f5["RC-12"]["classification"] == "probable" and f5[None]["amount_effect"] == "60.0000", f"{f5}")
    check(out["card"]["stage2_state"] == "matched", f"{out['card']}")
    check(out["observation"]["stage2_state"] == "difference_open" and len(ob) == 1 and ob[0]["classification"] == "unresolved"
          and ob[0]["conflicting_observation_event_seqs"] == [o1["event_seq"] + 1], f"{out['observation']} {ob}")
    check(out["unconfirmed statement"]["stage2_state"] == "not_evaluated", f"{out['unconfirmed statement']}")
    return ("stage-1 arithmetic failure stops stage 2 until the member accepts it, then RC-09 is probable and C3 fails; a period after an "
            "uncovered month is incomplete_history with RC-11 unresolved, and a -54.10 row posted as -45.10 is RC-13; on an unverified "
            "statement the opening difference (RC-10, -10.00) cannot be confirmed (C2) and a deposit posted with the wrong sign is RC-12; an "
            "owed_positive card statement matches the negative ledger; a member observation disagreeing with a statement value at the same "
            "instant carries the conflict and an unresolved difference; an unconfirmed statement is not evaluated")


@test("AT-RCX-01", "Draft-04 §D5/§D7 storage rules: classification, AI hypotheses, criteria, lifecycle, member confirmation")
def t_rcx(server, ev):
    H = household(server, "bnx_c10rcx")
    out, bad = {}, {}
    j1 = post(H, "consumption_expense", "2026-01-05", [(H.groceries, "100.00"), (H.cad["ledger_account_id"], "-100.00")])
    s = stmt(H, H.cad, "2026-01-02", "2026-01-31", "1000.00", "880.00", verified=False)
    row(H, H.cad, "2026-01-05", "-100.00", link=j1)
    row(H, H.cad, "2026-01-07", "-20.00")
    run(H, statement_id=s)
    f = findings(H)[0]                                         # RC-01 probable (evidence unverified)
    with H.definer() as cx:
        ins = ("insert into bnx.reconciliation_exception(id, run_id, account_currency_id, as_of_at, rule_code, classification, confirmation, "
               "source, criteria, evidence, ledger_version) values (gen_random_uuid(), %s, %s, now(), %s, %s, %s, %s, %s, '{}', 1)")
        base = (f["run_id"], H.cad["account_currency_id"])
        for k, args in {"RC-15": ("RC-15", "probable", None, "deterministic", "{}"),
                        "AI hypothesis confirmed": ("RC-01", "confirmed", "member", "ai_hypothesis", "{}"),
                        "confirmed without confirmation": ("RC-01", "confirmed", None, "deterministic", "{}"),
                        "deterministic confirmed without criteria": ("RC-01", "confirmed", "deterministic", "deterministic", '{"C1": true}'),
                        "rule-less probable": (None, "probable", None, "deterministic", "{}"),
                        "classification GUESS": ("RC-01", "GUESS", None, "deterministic", "{}")}.items():
            try:
                cx.execute(ins, base + args); bad[k] = "ALLOWED"
            except psycopg.Error as e:
                bad[k] = type(e).__name__
            cx.rollback(); cx.execute("set role bnx_definer")
        cx.execute(ins, base + ("RC-14", "probable", None, "ai_hypothesis", "{}")); cx.commit(); out["AI hypothesis probable"] = "OK"
    st = lambda **kw: H.cmd(H.owner, "set_reconciliation_exception_state", exception_id=f["exception_id"], **kw)
    out["explain without kind"] = expect_err(st, "VALIDATION_FAILED", phase="resolved_explained")
    out["explained"] = st(phase="resolved_explained", explanation_kind="timing_in_transit", note={"text": "synthetic"})["phase"]
    out["explained again"] = expect_err(st, "EXCEPTION_STATE", phase="resolved_explained", explanation_kind="other")
    out["reopen"] = st(phase="open")["phase"]
    out["parked"] = st(phase="unresolved_parked")["phase"]
    out["resolve with RERUN_MATCHED by hand"] = expect_err(st, "VALIDATION_FAILED", phase="resolved_matched", resolution_action="RERUN_MATCHED")
    out["resolved"] = st(phase="resolved_matched", resolution_action="POST_MISSING_ROW")["phase"]
    out["resolved -> explained"] = expect_err(st, "EXCEPTION_STATE", phase="resolved_explained", explanation_kind="other")
    st(phase="open")
    out["member confirmation without evidence"] = expect_err(st, "VALIDATION_FAILED", phase="member_confirmed")
    mc = st(phase="member_confirmed", evidence_ref={"doc": "synthetic-receipt"})
    now = {x["exception_id"]: x for x in findings(H)}
    out["member confirmed"] = now.get(mc["exception_id"])
    out["original hidden"] = f["exception_id"] not in now
    try:
        with H.definer() as cx:
            cx.execute("update bnx.reconciliation_exception set classification = 'confirmed'"); out["update"] = "ALLOWED"
    except psycopg.Error as e:
        out["update"] = (e.diag.message_primary or "")[:40]
    out["member reads card findings"] = expect_err(findings, "NOT_FOUND", H, H.member, account_currency_id=H.card["account_currency_id"])
    H.close()
    json.dump({"bad": bad, **out}, open(os.path.join(ev, "AT-RCX-01.json"), "w"), indent=1, default=str)
    check(f["rule_code"] == "RC-01" and f["classification"] == "probable" and f["criteria"]["C2"]["ok"] is False, f"{f}")
    check(set(bad.values()) == {"CheckViolation"} and out["AI hypothesis probable"] == "OK", f"{bad}")
    check(out["explained"] == "resolved_explained" and out["reopen"] == "open" and out["parked"] == "unresolved_parked"
          and out["resolved"] == "resolved_matched" and out["update"] != "ALLOWED", f"{out}")
    m = out["member confirmed"]
    check(m and m["classification"] == "confirmed" and m["confirmation"] == "member" and m["source"] == "member" and out["original hidden"], f"{m}")
    return ("six invalid findings refused by CHECKs (rule code range, AI hypothesis confirmed, confirmed without confirmation, deterministic "
            "confirmed without the five criteria, rule-less non-remainder, unknown class), an AI hypothesis can be probable; the D7 lifecycle "
            "(explained needs a reason kind and no journal, reopen, park, resolved needs a D7 action, RERUN_MATCHED is the engine's, "
            "resolved cannot become explained); member confirmation needs evidence and supersedes the probable finding; append-only")


@test("AT-9012c-CAT", "F-C2-07 (flags on balance_observation_event, a UA §4.4.1 table, and reconciliation_exception); catalog; grants")
def t_cat(server, ev):
    db = "bnx_c10cat"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        trg = {r[0] for r in cx.execute("select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on "
                                        "n.oid = c.relnamespace where n.nspname = 'bnx' and c.relname in ('balance_observation_event',"
                                        "'reconciliation_run','reconciliation_exception','reconciliation_exception_event') and not t.tgisinternal")}
        fep = dict(cx.execute("select table_name, mode from bnx.flag_enforcement_point where table_name in "
                              "('balance_observation_event','reconciliation_run','reconciliation_exception')").fetchall())
        fs = cx.execute("select function_name, scope, needs_ac_subset from bnx.function_scope where function_name in "
                        "('q_balance_observations','q_reconciliation_coverage','q_reconciliation_exceptions') order by 1").fetchall()
        view = cx.execute("select to_regclass('bnx.statement_period') is not null").fetchone()[0]
        grants = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and p.proname in "
                            "('cmd_record_observation','q_balance_observations','q_reconciliation_exceptions','q_reconciliation_coverage','cmd_run_reconciliation',"
                            "'cmd_set_reconciliation_exception_state') and "
                            "has_function_privilege('bnx_app', p.oid, 'execute')").fetchone()[0]
        app_view = cx.execute("select has_table_privilege('bnx_app', 'bnx.statement_period', 'select')").fetchone()[0]
    check({"t_append_only", "t_scope_flag_balance_observation_event", "t_scope_flag_reconciliation_exception", "t_scope_flag_reconciliation_run",
           "t_reconciliation_exception_state"} <= trg, f"{trg}")
    check(fep == {"balance_observation_event": "account_currency_id", "reconciliation_run": "account_currency_id",
                  "reconciliation_exception": "account_currency_id"}, f"{fep}")
    check(fs == [("q_balance_observations", "finance.read", True), ("q_reconciliation_coverage", "finance.read", True),
                 ("q_reconciliation_exceptions", "finance.read", True)], f"{fs}")
    check(view and grants == 6 and app_view is False, f"{view} {grants} {app_view}")
    H = household(server, "bnx_c10flg")
    import run_s4_core2 as C2
    C2.set_modules(H, {"Canada": "NO", "International": "NO", "CRA": "NO"}, "3" * 64)
    m = expect_err(obs, "SCOPE_DISABLED", H, source="MEMBER", observed_at="2026-03-31T12:00:00Z", amount="1.00")
    H.close()
    return ("append-only, state-machine and t_scope_flag_* triggers present; enforcement points on balance_observation_event and "
            "reconciliation_exception; both queries finance.read with an account-currency subset; the command and queries are "
            "granted to bnx_app, the statement_period view is not (read through definer functions only); with the region "
            f"disabled an observation is refused ({m})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core10", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core10_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
