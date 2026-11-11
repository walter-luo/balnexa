#!/usr/bin/env python3
"""S4 V1.2 increment 10 tests: 9012c-1 balance observations, statement periods and the reconciliation exception structure
(UA V1.2 §5.6; OWNER_DECISION 2026-11-11 option 2). The RC-01...14 rules and the BAL01-12 cases are NOT tested here: their
Draft-04 texts are not available, so this suite claims none of those ids. Synthetic data only. Conventions as run_g0.py.
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


@test("AT-RCX-01", "UA V1.2 §5.6 reconciliation_exception structure (rule_code RC-01...14 format, class, state events; rules not implemented)")
def t_rcx(server, ev):
    H = household(server, "bnx_c10rcx")
    ac, card = H.cad["account_currency_id"], H.card["account_currency_id"]
    out, bad = {}, {}
    with H.definer() as cx:
        v = cx.execute("select version from bnx.ledger_state").fetchone()[0]
        ins = ("insert into bnx.reconciliation_exception(id, account_currency_id, as_of_at, observed, ledger, difference, rule_code, class, "
               "ledger_version) values (gen_random_uuid(), %s, '2026-03-31T23:59:59-04:00', %s, %s, %s, %s, %s, %s) returning id")
        for k, args in {"RC-15": (ac, "1", "1", "0", "RC-15", "CONFIRMED", v), "RC-00": (ac, "1", "1", "0", "RC-00", "CONFIRMED", v),
                        "difference not observed - ledger": (ac, "10", "8", "3", "RC-07", "CONFIRMED", v),
                        "class GUESS": (ac, "1", "1", "0", "RC-07", "GUESS", v)}.items():
            try:
                cx.execute(ins, args); bad[k] = "ALLOWED"
            except psycopg.Error as e:
                bad[k] = type(e).__name__
            cx.rollback(); cx.execute("set role bnx_definer")
        x1 = cx.execute(ins, (ac, "10.00", "8.00", "2.00", "RC-07", "CONFIRMED", v)).fetchone()[0]
        x2 = cx.execute(ins, (card, None, "5.00", None, "RC-14", "PROBABLE", v)).fetchone()[0]
        cx.commit()
        evt = lambda x, seq, st, act, rv: cx.execute("insert into bnx.reconciliation_exception_event(exception_id, seq, state, resolution_action, "
                                                    "recorded_version) values (%s, %s, %s, %s, %s)", (x, seq, st, act, rv))
        steps = [("first event EXPLAINED", (x1, 1, "EXPLAINED", None, v)), ("OPEN", (x1, 1, "OPEN", None, v)),
                 ("RESOLVED without action", (x1, 2, "RESOLVED", None, v)), ("seq gap", (x1, 3, "EXPLAINED", None, v)),
                 ("RESOLVED", (x1, 2, "RESOLVED", "SYNTHETIC_ACTION", v)), ("RESOLVED -> EXPLAINED", (x1, 3, "EXPLAINED", None, v)),
                 ("reopen", (x1, 3, "OPEN", None, v)), ("x2 OPEN", (x2, 1, "OPEN", None, v))]
        for k, args in steps:
            try:
                evt(*args); cx.commit(); out[k] = "OK"
            except psycopg.Error as e:
                cx.rollback(); cx.execute("set role bnx_definer"); out[k] = e.diag.message_primary or type(e).__name__
        try:
            cx.execute("update bnx.reconciliation_exception set rule_code = 'RC-01'"); out["update"] = "ALLOWED"
        except psycopg.Error as e:
            out["update"] = (e.diag.message_primary or "")[:40]
    q = lambda cred, **kw: H.app.call("q_reconciliation_exceptions", cred, kw)
    out["owner, all"] = q(H.owner)
    out["owner, OPEN"] = [x["rule_code"] for x in q(H.owner, state="OPEN")["exceptions"]]
    out["member (no grant on the card)"] = [x["rule_code"] for x in q(H.member)["exceptions"]]
    out["member, card id"] = expect_err(q, "NOT_FOUND", H.member, account_currency_id=card)
    out["bad state filter"] = expect_err(q, "VALIDATION_FAILED", H.owner, state="DONE")
    H.close()
    json.dump({"bad": bad, **out}, open(os.path.join(ev, "AT-RCX-01.json"), "w"), indent=1, default=str)
    check(set(bad.values()) == {"CheckViolation"}, f"{bad}")
    check(out["first event EXPLAINED"] == "EXCEPTION_STATE" and out["OPEN"] == "OK" and out["RESOLVED without action"] != "OK"
          and out["seq gap"] == "EXCEPTION_STATE" and out["RESOLVED"] == "OK" and out["RESOLVED -> EXPLAINED"] == "EXCEPTION_STATE"
          and out["reopen"] == "OK" and out["x2 OPEN"] == "OK" and out["update"] != "ALLOWED", f"{out}")
    al = out["owner, all"]
    check(al["rules_implemented"] is False and len(al["exceptions"]) == 2 and sorted(out["owner, OPEN"]) == ["RC-07", "RC-14"]
          and out["member (no grant on the card)"] == ["RC-07"], f"{out}")
    return ("rule_code outside RC-01...RC-14, an unknown class and a difference that is not observed - ledger are refused by "
            "CHECKs; the state machine starts at OPEN, needs a resolution action for RESOLVED, refuses gaps and RESOLVED -> "
            "EXPLAINED, allows a reopen; exceptions are append-only; q_reconciliation_exceptions shows the current state, says "
            "rules_implemented = false, and shows a member only the account-currencies they can view")


@test("AT-9012c-CAT", "F-C2-07 (flags on balance_observation_event, a UA §4.4.1 table, and reconciliation_exception); catalog; grants")
def t_cat(server, ev):
    db = "bnx_c10cat"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        trg = {r[0] for r in cx.execute("select tgname from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on "
                                        "n.oid = c.relnamespace where n.nspname = 'bnx' and c.relname in ('balance_observation_event',"
                                        "'reconciliation_exception','reconciliation_exception_event') and not t.tgisinternal")}
        fep = dict(cx.execute("select table_name, mode from bnx.flag_enforcement_point where table_name in "
                              "('balance_observation_event','reconciliation_exception')").fetchall())
        fs = cx.execute("select function_name, scope, needs_ac_subset from bnx.function_scope where function_name in "
                        "('q_balance_observations','q_reconciliation_exceptions') order by 1").fetchall()
        view = cx.execute("select to_regclass('bnx.statement_period') is not null").fetchone()[0]
        grants = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' and p.proname in "
                            "('cmd_record_observation','q_balance_observations','q_reconciliation_exceptions') and "
                            "has_function_privilege('bnx_app', p.oid, 'execute')").fetchone()[0]
        app_view = cx.execute("select has_table_privilege('bnx_app', 'bnx.statement_period', 'select')").fetchone()[0]
    check({"t_append_only", "t_scope_flag_balance_observation_event", "t_scope_flag_reconciliation_exception",
           "t_reconciliation_exception_state"} <= trg, f"{trg}")
    check(fep == {"balance_observation_event": "account_currency_id", "reconciliation_exception": "account_currency_id"}, f"{fep}")
    check(fs == [("q_balance_observations", "finance.read", True), ("q_reconciliation_exceptions", "finance.read", True)], f"{fs}")
    check(view and grants == 3 and app_view is False, f"{view} {grants} {app_view}")
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
