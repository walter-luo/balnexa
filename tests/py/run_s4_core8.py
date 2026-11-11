#!/usr/bin/env python3
"""S4 V1.2 increment 8 tests: 9012a R28 intra-household loans (UA V1.2 §5.7, §10; BNX-S2-08; OR-L-01...06).
The database engine bnx.r28_evaluate is compared byte for byte (canonical JSON, including the rounding-event ledger) with
the CI oracle tests/oracle/r28_reference.py on every fixture of r28_fixtures_V1.1.json (30, unchanged) and
r28_fixtures_V1.2.json (11, AT-R28-16...23 without 20). Database-path tests use the commands and posted journals.
Synthetic data only. Conventions as run_g0.py.
Usage: run_s4_core8.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, hashlib, json, os, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
from run_g0 import expect_err

sys.path.insert(0, os.path.join(h.ROOT, "tests", "oracle"))
import r28_reference as ORACLE  # noqa: E402

RESULTS, TESTS = [], []
check = C1.check
FX = os.path.join(h.ROOT, "tests", "fixtures", "s4")
S2_ORACLE_SHA = "ead5a9f8619228ff86a341310f0f6a0f035fe4f292c8e0478d68b48758322f18"
V11_SHA = "84f68f546ebafe252620f60ce1f5f02dd63531abaf54a9ab4e9a7a5765d98254"


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def fixtures():
    return json.load(open(os.path.join(FX, "r28_fixtures_V1.1.json")))["fixtures"] + json.load(open(os.path.join(FX, "r28_fixtures_V1.2.json")))["fixtures"]


def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"))


def engine(cx, contract):
    return cx.execute("select bnx.r28_evaluate(%s)", (json.dumps(contract),)).fetchone()[0]


def fixture(fid):
    return next(f for f in fixtures() if f["id"] == fid)


# ------------------------------------------------------------------------------------------------ household with a loan
TERMS = [{"term_kind": "DAY_COUNT", "value": {"code": "ACT/365F"}},
         {"term_kind": "PERIOD_RULE", "value": {"code": "start_inclusive_end_exclusive"}},
         {"term_kind": "INTEREST_MODEL", "value": {"code": "simple"}},
         {"term_kind": "ROUNDING", "value": {"mode": "HALF_UP", "event": "payment_and_as_of"}},
         {"term_kind": "WATERFALL", "value": {"code": "interest_then_principal"}}]
EVID = {"doc": "synthetic-loan-agreement"}


def household(server, db):
    H = C4.v2_full(server, db)
    H.lender = H.cmd(H.owner, "create_party", kind="person", display_name="Synthetic Lender")["party_id"]
    H.borrower = H.cmd(H.owner, "create_party", kind="person", display_name="Synthetic Borrower")["party_id"]
    # private accounts: only the owner holds a grant until the tests add one (household accounts are granted to every member)
    rec = H.cmd(H.owner, "create_account", kind="loan_receivable", **H.inst("Synthetic Bank"), label="Loan to borrower", currencies=["CAD"],
                visibility="private")
    pay = H.cmd(H.owner, "create_account", kind="loan_payable", **H.inst("Synthetic Bank"), label="Loan from lender", currencies=["CAD"],
                visibility="private")
    H.rec_acc, H.rec = rec["account_id"], rec["account_currencies"][0]
    H.pay_acc, H.pay = pay["account_id"], pay["account_currencies"][0]
    for acc, party in ((H.rec_acc, H.lender), (H.pay_acc, H.borrower)):
        H.cmd(H.owner, "record_ownership", account_id=acc, events=[{"party_id": party, "kind": "legal_owner", "event": "set",
                                                                     "share": "100", "effective_from": "2025-01-01"}])
    return H


def declare(H, principal="5000.00", start="2026-01-01", both=True, cred=None, **kw):
    args = dict(currency="CAD", principal=principal, start=start, lender_party_id=H.lender, borrower_party_id=H.borrower,
                receivable_account_currency_id=H.rec["account_currency_id"], evidence_ref=EVID, **kw)
    if both:
        args["payable_account_currency_id"] = H.pay["account_currency_id"]
    return H.cmd(cred or H.owner, "declare_loan", **args)["loan_id"]


def terms(H, loan, events, cred=None):
    return H.cmd(cred or H.owner, "declare_loan_terms", loan_id=loan, evidence_ref=EVID, events=events)


def position(H, loan, cred=None, **q):
    return H.app.call("q_r28_loan_position", cred or H.owner, {"loan_id": loan, **q})


def pay_journal(H, d, amount):
    """A posted journal paying the lender: cash into the lender's chequing, the receivable reduced."""
    return H.cmd(H.owner, "post_transaction", economic_type="loan_principal_collected", transaction_date=d, description="loan payment",
                 lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": amount},
                        {"ledger_account_id": H.rec["ledger_account_id"], "currency": "CAD", "amount": f"-{amount}"}])["journal_id"]


def link(H, loan, journal, event="linked", cred=None):
    return H.cmd(cred or H.owner, "link_loan_payment", loan_id=loan, journal_id=journal,
                 cash_account_currency_id=H.cad["account_currency_id"], event=event)


# ------------------------------------------------------------------------------------------------ golden
@test("AT-R28-GOLD", "AT-R28-01...15 (V1.1, 30 fixtures) and AT-R28-16...23 (V1.2) — engine = oracle byte for byte")
def t_golden(server, ev):
    s2 = hashlib.sha256(open(os.path.join(h.ROOT, "tests", "oracle", "r28_reference_s2_v1_0.py"), "rb").read()).hexdigest()
    v11 = hashlib.sha256(open(os.path.join(FX, "r28_fixtures_V1.1.json"), "rb").read()).hexdigest()
    check(s2 == S2_ORACLE_SHA and v11 == V11_SHA, f"S2 oracle or V1.1 fixtures changed: {s2} {v11}")
    db = "bnx_r28gold"
    h.bootstrap(server, db); h.migrate(server, db)
    out, bad = {}, []
    with C1.migrator(server, db) as cx:
        for f in fixtures():
            d, o = engine(cx, f["contract"]), ORACLE.run(f["contract"])
            exp = f["expected"]
            exp_ok = (d.get("refusal") == exp["refusal"]) if "refusal" in exp else all(d.get(k) == v for k, v in exp.items())
            out[f["id"]] = {"engine_sha256": hashlib.sha256(canon(d).encode()).hexdigest()[:16], "byte_equal": canon(d) == canon(o),
                            "expected_fields_ok": exp_ok, "result": d.get("refusal") or {k: d[k] for k in ("accrued_interest_total", "principal_outstanding", "interest_outstanding")}}
            if canon(d) != canon(o) or not exp_ok:
                bad.append(f["id"])
    json.dump(out, open(os.path.join(ev, "AT-R28-GOLD.json"), "w"), indent=1)
    check(not bad, f"engine differs from oracle or fixture: {bad}")
    return (f"{len(out)} fixtures (30 of V1.1 unchanged, SHA-256 checked; 11 of V1.2): bnx.r28_evaluate output, including every rounding "
            f"event, is byte-equal to the oracle's canonical JSON and matches each fixture's expected fields")


@test("AT-R28-NEG", "AT-R28-NEG-01/02 (mutations: HALF_EVEN substituted; actual-day compounding substituted)")
def t_mutation(server, ev):
    db = "bnx_r28gold"
    res = {}
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        def mutate(fn_sig, old, new, fid):
            src = cx.execute("select pg_get_functiondef(%s::regprocedure)", (fn_sig,)).fetchone()[0]
            assert src.count(old) == 1, (fn_sig, old)
            cx.execute(src.replace(old, new))
            got = cx.execute("select bnx.r28_evaluate(%s)", (json.dumps(fixture(fid)["contract"]),)).fetchone()[0]
            cx.rollback()
            exp = fixture(fid)["expected"]
            return {"fixture": fid, "detected": any(got.get(k) != v for k, v in exp.items()), "mutant": {k: got.get(k) for k in exp}}
        res["NEG-01 HALF_EVEN for HALF_UP"] = mutate("bnx.r28_round(numeric,integer,text)", "(mode = 'HALF_UP' or mod(n, 2) = 1)", "(mod(n, 2) = 1)", "AT-R28-12a")
        res["NEG-02 daily (actual-day) compounding"] = mutate(
            "bnx.r28_evaluate(jsonb)",
            "for k in 1 .. n loop f := f * (ppy + rate); g := g * ppy; end loop;",
            "sd := 0; for k in 1 .. (b - last) loop f := f * (1 + rate / basis); end loop;", "AT-R28-03b")
        res["NEG-03 per-segment rounding (G1)"] = mutate(
            "bnx.r28_evaluate(jsonb)",
            "num := num + pout * rate * bnx.r28_days(conv, cd, nb);",
            "num := num + bnx.r28_round(bnx.r28_div(pout * rate * bnx.r28_days(conv, cd, nb), basis), mu, mode) * basis;", "AT-R28-22")
    json.dump(res, open(os.path.join(ev, "AT-R28-NEG.json"), "w"), indent=1)
    check(all(r["detected"] for r in res.values()), f"a mutant survived: {res}")
    return ("three mutants of the engine, each killed by its fixture: HALF_EVEN in place of HALF_UP (12a), actual-day compounding "
            "(daily compounding, 03b), rounding per rate segment instead of per event (22, gap G1)")


# ------------------------------------------------------------------------------------------------ database path
@test("AT-R28-HIST-01", "AT-R28-04a/04b on the command path; OR-L-01, OR-S-04 (terms are bitemporal; history reproducible)")
def t_hist(server, ev):
    H = household(server, "bnx_r28hist")
    loan = declare(H)
    r1 = terms(H, loan, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.04"}, "effective_from": "2026-01-01"},
                                 {"term_kind": "RATE", "value": {"annual_rate": "0.06"}, "effective_from": "2026-04-01"}])
    with C1.migrator(server, H.db) as cx:
        t1 = cx.execute("select max(recorded_at) from bnx.loan_term_event where loan_id = %s", (loan,)).fetchone()[0].isoformat()
    rate_seq = r1["event_seqs"][-1]
    terms(H, loan, [{"term_kind": "RATE", "retracts_event_seq": rate_seq},
                    {"term_kind": "RATE", "value": {"annual_rate": "0.06"}, "effective_from": "2026-03-01"}])
    v1 = position(H, loan, as_of="2026-07-01", terms_recorded_as_of=t1)
    v2 = position(H, loan, as_of="2026-07-01")
    with C1.migrator(server, H.db) as cx:
        n = cx.execute("select count(*) from bnx.loan_term_event where loan_id = %s", (loan,)).fetchone()[0]
    H.close()
    out = {"v1": v1["position"], "v2": v2["position"], "events": n}
    json.dump(out, open(os.path.join(ev, "AT-R28-HIST-01.json"), "w"), indent=1, default=str)
    check(v1["status"] == "OK" and v1["position"]["accrued_interest_total"] == "124.11", f"V1 terms: {v1}")
    check(v2["status"] == "OK" and v2["position"]["accrued_interest_total"] == "132.60", f"V2 terms: {v2}")
    check(n == 9, f"term events must only be appended: {n}")
    return ("terms declared by command (rates 4 % then 6 % from 2026-04-01) give 124.11 (fixture 04a); a backdated correction "
            "retracts that rate event and adds 6 % from 2026-03-01: now 132.60 (04b), while terms_recorded_as_of = the first "
            "recording still gives 124.11; 9 events, none updated")


@test("AT-R28-05,20", "AT-R28-05 on posted journals; AT-R28-20 (payment reversed by a correction at N+1); OR-L-04")
def t_payments(server, ev):
    H = household(server, "bnx_r28pay")
    loan = declare(H, principal="12000.00")
    terms(H, loan, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.03"}, "effective_from": "2026-01-01"}])
    j1, j2 = pay_journal(H, "2026-04-01", "2000.00"), pay_journal(H, "2026-07-01", "10164.23")
    link(H, loan, j1); n = link(H, loan, j2)["ledger_version"]
    at_n = position(H, loan, as_of="2026-07-01", ledger_version=n)
    corr = H.cmd(H.owner, "correct_transaction", journal_id=j2, reason="synthetic reversal")
    n1 = corr["ledger_version"]
    at_n1 = position(H, loan, as_of="2026-07-01")
    at_n_again = position(H, loan, as_of="2026-07-01", ledger_version=n)
    exp = fixture("AT-R28-05")["expected"]
    H.close()
    out = {"N": n, "N+1": n1, "at_N": at_n, "at_N+1": at_n1}
    json.dump(out, open(os.path.join(ev, "AT-R28-05_20.json"), "w"), indent=1, default=str)
    check(at_n["payments_counted"] == 2 and all(at_n["position"][k] == v for k, v in exp.items()), f"at N: {at_n}")
    check(at_n_again == at_n or {k: v for k, v in at_n_again.items() if k != "terms_recorded_as_of"} == {k: v for k, v in at_n.items() if k != "terms_recorded_as_of"},
          "position at N must be reproducible after N+1")
    p1 = at_n1["position"]
    check(at_n1["payments_counted"] == 1 and p1["principal_paid"] == "1911.23" and p1["principal_outstanding"] == "10088.77"
          and p1["interest_outstanding"] == "75.46" and len(at_n1["rounding_events"]) == 2
          and at_n1["rounding_events"] != at_n["rounding_events"], f"at N+1: {at_n1}")
    return (f"two payments posted as journals and linked: at version {n} the position equals fixture 05 (interest paid 164.23, "
            f"principal 0.00); the second journal corrected at {n1}: the position at {n1} counts one payment (principal "
            f"outstanding 10088.77, interest outstanding 75.46) and re-emits the rounding events; the position at {n} is unchanged")


@test("AT-R28-09", "AT-R28-09 (authorization: grants, partial view, revocation; never an existence leak)")
def t_auth(server, ev):
    H = household(server, "bnx_r28auth")
    loan = declare(H)
    terms(H, loan, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.05"}, "effective_from": "2026-01-01"}])
    out = {}
    out["member, no grant: position"] = expect_err(position, "NOT_FOUND", H, loan, H.member, as_of="2026-07-01")
    out["member, no grant: declare"] = expect_err(declare, "NOT_POSTABLE", H, cred=H.member)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.rec_acc, can_view=True, can_post=False)
    p = position(H, loan, H.member, as_of="2026-07-01")
    out["member, view on one side"] = {"partial_view": p["partial_view"], "status": p["status"]}
    out["member, view only: terms"] = expect_err(terms, "NOT_POSTABLE", H, loan, [TERMS[0]], H.member)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.rec_acc, can_view=True, can_post=True)
    out["member, post on one of two sides: terms"] = expect_err(terms, "NOT_POSTABLE", H, loan, [TERMS[0]], H.member)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.pay_acc, can_view=True, can_post=True)
    out["member, post on both: terms"] = terms(H, loan, [TERMS[0]], H.member)["event_seqs"]
    out["member, both sides: partial_view"] = position(H, loan, H.member, as_of="2026-07-01")["partial_view"]
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.rec_acc, can_view=False, can_post=False)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.pay_acc, can_view=False, can_post=False)
    out["member, grants revoked: position"] = expect_err(position, "NOT_FOUND", H, loan, H.member, as_of="2026-07-01")
    out["unknown loan id"] = expect_err(position, "NOT_FOUND", H, "00000000-0000-4000-8000-000000000000", H.owner)
    H.cmd(H.owner, "invite_member", display_name="Viewer R28", role="viewer", google_sub="g-viewer-r28")
    out["viewer: declare"] = expect_err(declare, "FORBIDDEN_ROLE", H, cred=H.login("g-viewer-r28"))
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-R28-09.json"), "w"), indent=1, default=str)
    check(out["member, view on one side"] == {"partial_view": True, "status": "OK"} and out["member, both sides: partial_view"] is False, f"{out}")
    return ("without a grant the position is NOT_FOUND (same as an unknown id) and declaring is NOT_POSTABLE; a view grant on one "
            "side shows the position with partial_view = true; terms need post rights on every household side; revoking the "
            "grants hides the loan again; a viewer cannot declare")


@test("AT-R28-11", "AT-R28-11 (idempotency, rollback, ledger-version reproducibility)")
def t_idem(server, ev):
    H = household(server, "bnx_r28idem")
    out = {}
    a = declare(H, key="loan-key-000001"); b = declare(H, key="loan-key-000001")
    out["same key twice"] = a == b
    out["same key, other payload"] = expect_err(declare, "IDEMPOTENCY_CONFLICT", H, principal="6000.00", key="loan-key-000001")
    with C1.migrator(server, H.db) as cx:
        out["loans"] = cx.execute("select count(*) from bnx.loan").fetchone()[0]
    out["batch with one bad event"] = expect_err(terms, "VALIDATION_FAILED", H, a, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "five"},
                                                                                          "effective_from": "2026-01-01"}])
    out["principal with 3 decimals"] = expect_err(declare, "INVALID_PRINCIPAL", H, principal="100.005")
    out["retract an unknown event"] = expect_err(terms, "VALIDATION_FAILED", H, a, [{"term_kind": "RATE", "retracts_event_seq": 99}])
    with C1.migrator(server, H.db) as cx:
        out["events after failed batch"] = cx.execute("select count(*) from bnx.loan_term_event where loan_id = %s", (a,)).fetchone()[0]
    terms(H, a, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.05"}, "effective_from": "2026-01-01"}])
    j = pay_journal(H, "2026-03-01", "500.00")
    with C1.migrator(server, H.db) as cx:
        v_before = cx.execute("select version from bnx.ledger_state").fetchone()[0]
    link(H, a, j)
    out["link twice"] = expect_err(link, "LINK_STATE", H, a, j)
    before = position(H, a, as_of="2026-07-01", ledger_version=v_before)
    after = position(H, a, as_of="2026-07-01")
    unl = link(H, a, j, "unlinked")
    unlinked = position(H, a, as_of="2026-07-01")
    out["payments counted: before link / after / after unlink"] = [before["payments_counted"], after["payments_counted"], unlinked["payments_counted"]]
    out["no terms -> TERMS_UNVERIFIED, figures null"] = None
    c = declare(H, principal="1000.00")
    nt = position(H, c, as_of="2026-07-01")
    out["no terms -> TERMS_UNVERIFIED, figures null"] = [nt["status"], nt["refusal"], nt["position"]]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-R28-11.json"), "w"), indent=1, default=str)
    check(out["same key twice"] and out["loans"] == 1 and out["events after failed batch"] == 0, f"{out}")
    check(out["payments counted: before link / after / after unlink"] == [0, 1, 0], f"{out}")
    check(out["no terms -> TERMS_UNVERIFIED, figures null"] == ["TERMS_UNVERIFIED", "TERMS_UNVERIFIED:day_count", None], f"{out}")
    return ("a repeated idempotency key returns the same loan (one row) and a changed payload under it is IDEMPOTENCY_CONFLICT; a "
            "term batch with one invalid event writes nothing; INVALID_PRINCIPAL for 3 decimals in CAD; a link is versioned "
            "(position at the earlier ledger version counts 0 payments, after the link 1, after unlinking 0); a loan without "
            "terms is TERMS_UNVERIFIED with null figures, never zero")


@test("AT-R28-CONS", "AT-R28-CONS-01 (household_internal only from verified ownership facts); F-C2-07 enforcement points")
def t_cons(server, ev):
    H = household(server, "bnx_r28cons")
    both = declare(H)
    one = declare(H, both=False)
    other = H.cmd(H.owner, "create_party", kind="person", display_name="Someone Else")["party_id"]
    wrong = H.cmd(H.owner, "declare_loan", currency="CAD", principal="100.00", start="2026-01-01", lender_party_id=H.lender,
                  borrower_party_id=other, receivable_account_currency_id=H.rec["account_currency_id"],
                  payable_account_currency_id=H.pay["account_currency_id"], evidence_ref=EVID)["loan_id"]
    for x in (both, one, wrong):
        terms(H, x, TERMS + [{"term_kind": "RATE", "value": {"annual_rate": "0.02"}, "effective_from": "2026-01-01"}])
    out = {k: position(H, x, as_of="2026-07-01")["household_internal"] for k, x in (("both sides, verified owners", both),
                                                                                     ("external borrower (one side)", one),
                                                                                     ("payable owned by someone else", wrong))}
    with C1.migrator(server, H.db) as cx:
        m = cx.execute("select bnx.flag_enforcement_matrix()").fetchone()[0]
    H.close()
    trig = sorted(x["trigger"] for x in m if x["table"].startswith("loan"))
    out["scope-flag triggers"] = trig
    json.dump(out, open(os.path.join(ev, "AT-R28-CONS.json"), "w"), indent=1)
    check(out["both sides, verified owners"] is True and out["external borrower (one side)"] is False
          and out["payable owned by someone else"] is False, f"{out}")
    check(trig == ["t_scope_flag_loan", "t_scope_flag_loan_payment_link", "t_scope_flag_loan_term_event"], f"{trig}")
    return ("household_internal is true only when both sides are household accounts whose recorded ownership names the lender "
            "and the borrower; false for an external borrower and for a payable account owned by another party; the three "
            "loan tables carry their t_scope_flag triggers")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core8", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core8_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
