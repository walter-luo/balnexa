#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 findings of the second and third live AI runs (migration 9047; F-LIVE-9, F-SIN-2 of 2026-11-21): fin.draft.check_statement
runs the statement checks and stores nothing (no draft, audit entry or idempotency record; a superseded draft stays as it was;
the same refusals as fin.draft.create_statement), and a merge of account proposals is no longer refused at random when the
target's UUID holds a Luhn-valid 9-digit run. Synthetic data only; the test digits are made at run time, never written here.
Usage: run_s4_core23.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core20 as C20

RESULTS, TESTS = [], []
check, expect_err = C1.check, C1.expect_err


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def counts(H):
    return C4.one(H, "select (select count(*) from bnx.posting_plan), (select count(*) from bnx_audit.audit_event), "
                     "(select count(*) from bnx.idempotency)")


@test("AT-CHK-01", "F-LIVE-9; 9047 (fin.draft.check_statement answers what fin.draft.create_statement would, holds and texts "
                   "included, and stores nothing: no draft, no audit entry, no idempotency record; with supersedes_plan_id the "
                   "open draft stays frozen; the AI then submits once)")
def t_check(server, ev):
    H = C20.household(server, "bnx_c23chk")
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[H.cad["account_currency_id"]])
    out = {}
    args = dict(account_currency_id=H.cad["account_currency_id"], period_from="2026-01-01", period_to="2026-01-31",
                opening_balance="1000.00", closing_balance="950.00", sign_convention="asset_positive")
    bad = [C20.ln(H, "2026-01-05", "-40.00")]                                   # misread: closing says -50
    good = [C20.ln(H, "2026-01-05", "-40.00"), C20.ln(H, "2026-01-20", "-10.00", needs_review=True)]
    c0 = counts(H)
    out["bad"] = H.cmd(B, "check_statement", lines=bad, **args)
    out["good"] = H.cmd(B, "check_statement", lines=good, **args)
    out["after checks"] = counts(H) == c0
    p = H.cmd(B, "draft_statement", lines=good, **args)
    out["same as draft"] = (p["hold_reasons"], p["validation_result"]) == (out["good"]["hold_reasons"], out["good"]["validation_result"])
    c1 = counts(H)
    sup = H.cmd(B, "check_statement", lines=good[:1] + [C20.ln(H, "2026-01-20", "-10.00")], supersedes_plan_id=p["plan_id"], **args)
    out["superseding check"] = (sup["hold_reasons"], C4.one(H, "select state from bnx.posting_plan where id = %s", (p["plan_id"],))[0],
                                counts(H) == c1)
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-CHK-01.json"), "w"), indent=1, default=str)
    check(out["bad"]["stored"] is False and out["bad"]["hold_reasons"] == ["BALANCE_CHAIN"]
          and out["bad"]["validation_result"]["V-04"] == "HOLD:BALANCE_CHAIN (ledger sign: opening 1000 + lines -40 = 960, closing 950)"
          and "plan_id" not in out["bad"], f"bad {out['bad']}")
    check(out["good"]["hold_reasons"] == ["REVIEW_QUEUE"] and out["good"]["continuity"]["status"] == "first" and out["after checks"],
          f"good {out['good']} stored nothing {out['after checks']}")
    check(out["same as draft"] and out["superseding check"] == ([], "frozen", True), f"same {out['same as draft']} sup {out['superseding check']}")
    return "misread -> BALANCE_CHAIN with figures, nothing stored; good reading -> REVIEW_QUEUE as the draft then got; a superseding check leaves the draft frozen"


@test("AT-CHK-02", "F-LIVE-9; 9047 (the check refuses what the draft refuses: an account the connection may not see, a connection "
                   "without finance.draft, a missing field; nothing is stored)")
def t_check_refusals(server, ev):
    H = C20.household(server, "bnx_c23ref")
    B = C4.bearer(H, ["finance.read", "finance.draft"], acs=[H.cad["account_currency_id"]])
    R = C4.bearer(H, ["finance.read"], acs=[H.cad["account_currency_id"]])
    args = dict(period_from="2026-01-01", period_to="2026-01-31", opening_balance="1000.00", closing_balance="960.00",
                sign_convention="asset_positive", lines=[C20.ln(H, "2026-01-05", "-40.00")])
    c0 = counts(H)
    out = {"refusals": [
        expect_err(H.cmd, "NOT_AVAILABLE", B, "check_statement", account_currency_id=H.card["account_currency_id"], **args),
        expect_err(H.cmd, "SCOPE_NOT_CONSENTED", R, "check_statement", account_currency_id=H.cad["account_currency_id"], **args),
        expect_err(H.cmd, "VALIDATION_FAILED", B, "check_statement", account_currency_id=H.cad["account_currency_id"],
                   **{k: v for k, v in args.items() if k != "closing_balance"})]}
    out["unchanged"] = counts(H) == c0
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-CHK-02.json"), "w"), indent=1, default=str)
    check(len(out["refusals"]) == 3 and out["unchanged"], f"{out}")
    return "NOT_AVAILABLE, SCOPE_NOT_CONSENTED, VALIDATION_FAILED; nothing stored"


def luhn_uuid():
    """A UUID whose last group starts with a Luhn-valid 9-digit run the SIN detector reports (made at run time)."""
    import random
    rnd = random.Random(9047)
    while True:
        body = [rnd.randint(1, 7)] + [rnd.randint(0, 9) for _ in range(7)]
        s = sum(d if i % 2 == 0 else (d * 2 - 9 if d * 2 > 9 else d * 2) for i, d in enumerate(body))
        digits = "".join(map(str, body)) + str((10 - s % 10) % 10)
        yield f"abcdefab-cdef-4abc-8def-{digits}abc"


@test("AT-SIN-02", "F-SIN-2; 9047 (a merge whose target UUID holds a Luhn-valid 9-digit run is no longer refused as SIN_CANDIDATE; "
                   "the guard still refuses a SIN in a free-text field)")
def t_merge_uuid(server, ev):
    H = C4.household(server, "bnx_c23sin")
    out = {}
    gen = luhn_uuid()
    for _ in range(200):
        u = next(gen)
        if C4.one(H, "select bnx.sin_json_has(jsonb_build_object('merge_into', %s::text)), "
                     "bnx.sin_json_has(jsonb_build_object('merge_into_id', %s::text))", (u, u)) == (True, False):
            break
    else:
        raise AssertionError("no test UUID found")
    a = C4.signal(H, period_start="2026-01-01")
    b = C4.signal(H, period_start="2026-02-01", holder_names=["BO SAMPLE"])
    ps = H.cmd(H.member, "propose_account", signal_ids=[a])["proposals"] + H.cmd(H.member, "propose_account", signal_ids=[b])["proposals"]
    C4.sql(H, "update bnx_intake.account_proposal set id = %s where id = %s", (u, ps[1]["proposal_id"]))
    r = H.cmd(H.owner, "resolve_account_proposal", proposal_id=ps[0]["proposal_id"], action="merge", merge_into=u)
    out["merged"] = C4.one(H, "select state, merged_into::text = %s from bnx_intake.account_proposal where id = %s", (u, ps[0]["proposal_id"]))
    out["result keys"] = sorted(r)        # the values are not kept: the run-time digits stay out of the evidence (SIN scan)
    out["still guarded"] = expect_err(H.cmd, "SIN_CANDIDATE", H.owner, "resolve_account_proposal", proposal_id=u,
                                      action="reject", label=u.split("-")[-1][:9])
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-SIN-02.json"), "w"), indent=1, default=str)
    check(out["merged"] == ("MERGED", True), f"merged {out['merged']} {r}")
    return f"merge into a UUID with a Luhn-valid run accepted ({out['merged'][0]}); a SIN-shaped label still refused ({out['still guarded']})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core23", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core23_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
