#!/usr/bin/env python3
"""S4 V1.2 increment 5 tests: 9011a SIN/ITN detector and database guards (Addendum A1 Rev 1 §3, §7 DOC-SIN-10, guards C1, C2,
C6). Conventions as run_g0.py. Generated corpus values are synthetic and are never written to evidence: evidence holds case ids,
rule codes and counts only.
Usage: run_s4_core5.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, subprocess, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import sin_corpus as SC

sys.path.insert(0, os.path.join(h.ROOT, "apps", "executor"))
from bnx_exec import sin_detector as S  # noqa: E402

RESULTS, TESTS = [], []
check, expect_err, Fail = C1.check, C1.expect_err, C1.Fail
HERE = os.path.dirname(os.path.abspath(__file__))


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def key(x):
    return (x.get("path", ""), x["start"], x["end"], x["rule"])


def py_hits(c):
    if c["kind"] == "json":
        return S.scan_json(c["input"], c["origin"])
    return S.scan(c["input"], c["origin"], c.get("confidences"))


def js_hits(cases):
    r = subprocess.run(["node", os.path.join(HERE, "sin_js_runner.mjs")], input=json.dumps(cases), capture_output=True, text=True)
    check(r.returncode == 0, "JS runner failed: " + r.stderr[-800:])
    return json.loads(r.stdout)


def sql_hits(cx, c):
    if c["kind"] == "json":
        return cx.execute("select bnx.sin_scan_json(%s::jsonb, %s)", (json.dumps(c["input"]), c["origin"])).fetchone()[0]
    return cx.execute("select bnx.sin_scan(%s, %s)", (c["input"], c["origin"])).fetchone()[0]


def no_value(text, values):
    """True when none of the generated values (digits only) appears in text, in any grouping."""
    digits = "".join(ch for ch in text if ch.isdigit())
    return not any(v in digits for v in values)


# ------------------------------------------------------------------------------------------------ detector
@test("AT-SIN-11", "Addendum A1 Rev 1 §3, guard C1 (one specification: Python, JS and SQL give identical hits)")
def t_parity(server, ev):
    gen = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools", "s4", "gen_sin_detector_spec.py"), "--check"])
    cases = SC.cases()
    shared = [c for c in cases if c["origin"] != "ocr"]
    js = js_hits(shared)
    db = h.fresh(server, "bnx_s4c5parity")
    diffs, n_hits = [], 0
    with C1.migrator(server, db) as cx:
        spec_db = cx.execute("select bnx.sin_detector_spec()").fetchone()[0]
        for c in shared:
            p, j, s = sorted(map(key, py_hits(c))), sorted(map(key, js[c["id"]])), sorted(map(key, sql_hits(cx, c)))
            n_hits += len(p)
            if not (p == j == s):
                diffs.append(c["id"])
        refused = {}
        for impl, fn in (("sql", lambda: cx.execute("select bnx.sin_scan('x', 'ocr')").fetchone()),):
            try:
                fn(); refused[impl] = "accepted"
            except psycopg.Error as e:
                refused[impl] = e.diag.message_primary; cx.rollback(); cx.execute("set role bnx_definer")
    js_ocr = js_hits([{"id": "ocr", "kind": "text", "origin": "ocr", "input": "x"}])["ocr"]
    spec_file = json.load(open(os.path.join(h.ROOT, "spec", "sin-detector", "sin_detector_v1.json"), encoding="utf-8"))
    json.dump({"cases": len(shared), "hits": n_hits, "diffs": diffs, "ocr_refused": {**refused, "js": js_ocr}},
              open(os.path.join(ev, "AT-SIN-11_parity.json"), "w"), indent=1)
    check(gen.returncode == 0, "committed spec differs from the generator output")
    check(spec_db == spec_file, "bnx.sin_detector_spec() differs from spec/sin-detector/sin_detector_v1.json")
    check(not diffs, f"implementations differ on {diffs}")
    check(refused["sql"] == "VALIDATION_FAILED" and isinstance(js_ocr, dict) and "error" in js_ocr, f"ocr origin must be refused: {refused} {js_ocr}")
    return (f"{len(shared)} native/typed corpus cases ({n_hits} hits): Python, JS and SQL identical (rule, start, end, path); "
            f"embedded spec equals the spec file; generator check clean; origin 'ocr' refused by SQL ({refused['sql']}) and JS")


@test("AT-SIN-12-15b", "Addendum A1 Rev 1 §11 AT-SIN-12, 13, 14, 15, 15b; D-A1-1; D-9011a-1 (expected rules per corpus case)")
def t_expect(server, ev):
    per, bad = {}, []
    for c in SC.cases():
        if c["kind"] == "json":
            got = sorted([x["path"], x["part"], x["rule"]] for x in py_hits(c))
            exp = sorted([SC.expand(p), part, r] for p, part, r in c["expect"])
        else:
            got, exp = [x["rule"] for x in py_hits(c)], c["expect"]
        per.setdefault(c["test"], [0, 0])[0] += 1
        if got == exp:
            per[c["test"]][1] += 1
        else:
            bad.append((c["id"], got, exp))
    json.dump({"per_test": per, "mismatches": [(i, g, e) for i, g, e in bad]}, open(os.path.join(ev, "AT-SIN-12-15b.json"), "w"), indent=1)
    check(not bad, f"mismatches {bad}")
    return "expected rules met: " + ", ".join(f"{t} {ok}/{n}" for t, (n, ok) in sorted(per.items())) + \
           " (OCR cases in the Python reference only; JS and SQL agree with it on all other cases, AT-SIN-11)"


# ------------------------------------------------------------------------------------------------ database guards
@test("AT-SIN-08a", "Addendum A1 Rev 1 guard C2, DOC-SIN-10; D-9011a-2, D-9011a-3 (staging, shared index, plans, commands, audit)")
def t_guards(server, ev):
    H = C4.index_household(server, "bnx_s4c5guards")
    vals = [SC.value("luhn", 41), SC.value("nonluhn", 42), SC.value("itn_nonluhn", 44)]
    luhn_sp = SC.GROUPS["space"](vals[0])
    out = {}
    n_audit0 = C4.one(H, "select count(*) from bnx.audit_event")[0]
    # 1. direct posting and a category name: refused by the generic audit guard, value not echoed
    e1 = C4.err(H.expense, H.owner, "12.00", desc="Cheque " + luhn_sp)
    e2 = C4.err(H.cmd, H.owner, "create_category", kind="expense", currency="CAD", name_en="Ref " + vals[2])
    out["expense"], out["category"] = e1[0], e2[0]
    # 2. a plan item description (import plan) and an AI-style draft path: refused
    e3 = C4.err(C4.imp, H, H.owner, [C4.item(H, "2026-03-05", "10.00", description="SIN " + vals[1])])
    out["import_plan"] = e3[0]
    # 3. staging of a non-index kind: refused, nothing staged, the lease stays unused
    L = C4.lease(H, "DOC_PROCESS")
    n_stg0 = C4.one(H, "select count(*) from bnx_intake.staging_payload")[0]
    e4 = C4.err(H.worker.call, "wrk_stage_completion", L["nonce"], "doc_validated", {"doc": "x", "note": "employee " + luhn_sp})
    out["staging"] = e4[0]
    n_stg1 = C4.one(H, "select count(*) from bnx_intake.staging_payload")[0]
    lease_open = C4.one(H, "select completed_at is null from bnx.exec_lease where lease_id = %s", (L["lease_id"],))[0]
    # 4. shared index: the record holding a candidate is masked at staging and blocked by the consumer; the others proceed
    recs = [C4.rec("f-sin-1", notes="Employee SIN " + vals[1]), C4.rec("f-ok-1"), C4.rec("f-sin-2", name="Slip " + vals[2])]
    st, sid = C4.consume(H, recs)
    staged = C4.one(H, "select payload::text from bnx_intake.staging_payload where id = %s", (sid,))[0]
    acks = dict(C4.sql(H, "select record_key, status from bnx_intake.index_record_ack"))
    cols = dict(C4.sql(H, "select record_key, columns from bnx_intake.external_index_record"))
    excs = [r[0] for r in C4.sql(H, "select class from bnx_intake.intake_exception where class = 'SIN_CANDIDATE'")]
    # 5. nothing of any value anywhere in the database text that matters; audit chain intact; refused commands left no audit row
    dump = " ".join(str(r[0]) for r in C4.sql(H, "select payload::text || coalesce(result::text, '') from bnx_intake.staging_payload "
                                                  "union all select columns::text from bnx_intake.external_index_record "
                                                  "union all select coalesce(subject::text, '') from bnx.audit_event "
                                                  "union all select coalesce(detail::text, '') from bnx_intake.intake_exception"))
    verify = C4.one(H, "select bnx.audit_verify()")[0]
    n_audit1 = C4.one(H, "select count(*) from bnx.audit_event")[0]
    msgs = " ".join(m or "" for m in (e1[1], e2[1], e3[1], e4[1]))
    H.close()
    out.update({"staging_rows_added": n_stg1 - n_stg0, "lease_still_open": lease_open, "index_result": st, "acks": acks,
                "blocked_columns": {k: v for k, v in cols.items() if k.startswith("f-sin") or k.startswith("sin:")},
                "sin_exceptions": len(excs), "audit_verify": verify, "audit_rows_added": n_audit1 - n_audit0})
    json.dump(out, open(os.path.join(ev, "AT-SIN-08a.json"), "w"), indent=1, default=str)
    check(e1[0] == e2[0] == e3[0] == e4[0] == "SIN_CANDIDATE", f"refusals {out}")
    check(no_value(msgs, vals), "an error detail echoed a value")
    check(n_stg1 == n_stg0 and lease_open, "refused staging must leave no row and an unused lease")
    check(acks.get("f-ok-1") == "CONSUMED" and acks.get("f-sin-1") == "BLOCKED" and acks.get("f-sin-2") == "BLOCKED", f"acks {acks}")
    check(cols.get("f-sin-1") == {} and cols.get("f-sin-2") == {} and cols.get("f-ok-1"), f"columns {cols}")
    check(S.MASK in staged and no_value(staged, vals) and no_value(dump, vals), "a value reached the database")
    check(len(excs) == 2 and verify == 0, f"exceptions {excs}, audit_verify {verify}")
    return (f"refused with SIN_CANDIDATE, value never echoed: direct posting (description), create_category (name), import plan "
            f"(item description), staging of doc_validated (no row, lease unused); shared index: 2 records with candidates masked at "
            f"staging and BLOCKED by the consumer with no columns stored and 2 Owner-only SIN_CANDIDATE exceptions, the clean record "
            f"CONSUMED; no value in staging, index, audit subjects or exception details; audit_verify {verify}; "
            f"no audit row from the refused commands ({n_audit1 - n_audit0} rows added in total)")


@test("AT-MUT-04", "D-9011a-3 (mutation: the guard tests detect removal of the audit guard)")
def t_mutation(server, ev):
    H = C4.v2_full(server, "bnx_s4c5mut")
    v = SC.GROUPS["space"](SC.value("luhn", 51))
    before = C4.err(H.expense, H.owner, "12.00", desc="Cheque " + v)[0]
    body = C1.installer_sql(server, H.db, "select pg_get_functiondef('bnx.audit(bnx.actor,text,jsonb,jsonb,bigint)'::regprocedure)")[0][0]
    stripped = body.replace("if bnx.sin_json_has(p_payload) or bnx.sin_json_has(p_subject) then", "if false then")
    check(stripped != body, "guard text not found in bnx.audit")
    with C1.migrator(server, H.db) as cx:
        cx.execute(stripped); cx.commit()
    after = H.expense(H.owner, "12.00", desc="Cheque " + v)
    H.close()
    check(before == "SIN_CANDIDATE" and after, f"{before} {after}")
    return "with the audit guard removed the same posting is accepted, so AT-SIN-08a would fail: the guard is what refuses it"


@test("AT-SIN-C6", "Addendum A1 Rev 1 guard C6 (repository scan with the reference detector)")
def t_repo_scan(server, ev):
    r = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools", "s4", "sin_repo_scan.py")], capture_output=True, text=True)
    open(os.path.join(ev, "AT-SIN-C6_scan.txt"), "w").write(r.stdout[-4000:])
    check(r.returncode == 0, "repository scan found candidates:\n" + r.stdout[-2000:])
    return r.stdout.strip().splitlines()[-1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core5", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "SKIP" if isinstance(msg, str) and msg.startswith("SKIP:") else "PASS"
            msg = msg[5:] if status == "SKIP" else msg
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__, "seconds": round(time.time() - t0, 1),
               "pass": sum(r["status"] == "PASS" for r in RESULTS), "fail": sum(r["status"] == "FAIL" for r in RESULTS),
               "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core5_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
