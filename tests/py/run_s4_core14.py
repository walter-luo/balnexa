#!/usr/bin/env python3
"""S4 V1.2 increment 14 tests: CORE-7 Gateway support in migration 9017 — the bnx-tools/1.0 catalog generated into
COMMENT ON FUNCTION (AIH V1.2 §2, DD-21), binding facts for B1/B2/B3/B8 (Amendment 03 §5.2, AE V1.2 §6), B7 audience in
bnx.resolve_actor, deferral of unknown work-item kinds (UA V1.2 §9.1, AT-Q-02) and the presigned-upload target (UA §8.1,
AT-EV-01). The Gateway side is covered by tests/blackbox/api.test.mjs and unit.test.mjs. Synthetic data only.
Usage: run_s4_core14.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, hashlib, json, os, subprocess, sys, time, traceback, uuid
import psycopg
import harness as h
import fixture as F
import run_s4_core1 as C1
import run_s4_core3 as C3
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check
REQUIRED = {"name", "version", "kind", "rest", "core_function", "risk_class", "tier", "scopes", "channels", "module_flags", "input_schema",
            "output_schema", "errors", "idempotency", "masked_fields", "evidence_citation", "mcp", "ui_profile"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def household(server, db):
    H = F.Household(server, h.fresh(server, db))
    return H


@test("AT-CAT-01", "AIH V1.2 §2 (DD-21), §2.1; UA V1.2 §8 (catalog from COMMENT ON FUNCTION; no drift; RC-POST never on MCP)")
def t_catalog(server, ev):
    db = "bnx_c14cat"
    h.bootstrap(server, db); h.migrate(server, db)
    W = h.Role(server, db, "bnx_worker")
    cat = W.call("wrk_catalog")
    facts = W.call("wrk_binding_facts")
    W.close()
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        callable_ = {f"{n}.{p}" for n, p in cx.execute(
            "select n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in (select nspname from bnx.schema_registry) "
            "and (p.proname like 'cmd\\_%%' or p.proname like 'q\\_%%') and has_function_privilege('bnx_app', p.oid, 'EXECUTE')")}
        fscope = {r[0]: r[1] for r in cx.execute("select function_name, scope from bnx.function_scope")}
    entries = cat["entries"]
    names = [e["name"] for e in entries]
    gen = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools/s4/catalog_build.py"), "--server", server, "--db", db, "--check"],
                         capture_output=True, text=True)
    canon = "\n".join(json.dumps(e, separators=(", ", ": ")) for e in entries)
    bad_shape = [e["core_function"] for e in entries if not REQUIRED <= set(e)]
    mcp_post = [e["core_function"] for e in entries if "mcp" in e["channels"] and e["risk_class"] not in ("RC-READ", "RC-DRAFT")]
    mcp_unlisted = [e["core_function"] for e in entries if "mcp" in e["channels"] and e["core_function"].split(".")[1] not in fscope]
    rest_mismatch = [e["core_function"] for e in entries if e["rest"].rsplit("/", 1)[1] != e["core_function"].split(".")[1].split("_", 1)[1]]
    json.dump({"count": len(entries), "sha256": cat["catalog_sha256"], "uncatalogued": cat["uncatalogued"], "generator": gen.stdout,
               "risk": {r: sum(e["risk_class"] == r for e in entries) for r in sorted({e["risk_class"] for e in entries})}},
              open(os.path.join(ev, "AT-CAT-01.json"), "w"), indent=1)
    json.dump(entries, open(os.path.join(ev, "AT-CAT-01_catalog.json"), "w"), indent=1)
    check(cat["uncatalogued"] == [] and {e["core_function"] for e in entries} == callable_, f"{cat['uncatalogued']} {callable_ ^ {e['core_function'] for e in entries}}")
    check(gen.returncode == 0, gen.stdout + gen.stderr)
    check(len(set(names)) == len(names) and not bad_shape and not mcp_post and not mcp_unlisted and not rest_mismatch,
          f"dup={len(names) - len(set(names))} shape={bad_shape} mcp_post={mcp_post} unlisted={mcp_unlisted} rest={rest_mismatch}")
    check(facts["catalog_sha256"] == cat["catalog_sha256"] and len(cat["catalog_sha256"]) == 64, f"{facts} {cat['catalog_sha256']}")
    q = next(e for e in entries if e["core_function"] == "bnx.q_f1_balances")
    p = next(e for e in entries if e["core_function"] == "bnx.cmd_post_transaction")
    check(q["risk_class"] == "RC-READ" and "mcp" in q["channels"] and q["input_schema"]["properties"]["as_of"] == {"type": "string", "format": "date"}
          and p["risk_class"] == "RC-POST" and p["channels"] == ["pwa"] and p["idempotency"] == "required"
          and "idempotency_key" not in p["input_schema"]["properties"], f"{q} {p}")
    return (f"{len(entries)} entries = every REST-callable cmd_/q_ function (0 uncatalogued), read from COMMENT ON FUNCTION; the generator's "
            f"--check re-derives the same block from the function bodies (no drift); unique names; every MCP entry is RC-READ/RC-DRAFT and in "
            f"bnx.function_scope; RC-POST/RC-ADMIN are PWA-only; catalog digest {cat['catalog_sha256'][:12]} equals the binding facts'")


@test("AT-ISO-BF", "Amendment 03 §5.2 B1/B2/B3/B8; AE V1.2 §6 (binding facts for the Gateway; worker-only; reveal nothing to bnx_app)")
def t_binding_facts(server, ev):
    H = household(server, "bnx_c14bf")
    f = H.worker.call("wrk_binding_facts")
    with H.definer() as cx:
        ident = cx.execute("select project_id, instance_uid::text from bnx.instance_identity").fetchone()
        act = cx.execute("select config_version, config_sha256 from bnx.config_version_anchor where state = 'ACTIVE'").fetchone()
        flags = dict(cx.execute("select flag_key, value from bnx.instance_module_flag where config_version = %s", (act[0],)).fetchall())
        heads = cx.execute("select max(version) filter (where version < '9000'), max(version) filter (where version >= '9000') from bnx.schema_migrations").fetchone()
    denied = {fn: expect_err(H.app.call, "permission denied", fn) for fn in ("wrk_binding_facts", "wrk_catalog")}
    with psycopg.connect(h.dsn(server, "bnx_migrator", H.db)) as cx:
        cx.execute("set role bnx_definer")
        forb = expect_err(lambda: cx.execute("select bnx.wrk_binding_facts()"), "FORBIDDEN")
    health = H.app.call("q_health", None, {})
    H.close()
    json.dump({"facts": f, "health": health, "denied": denied}, open(os.path.join(ev, "AT-ISO-BF.json"), "w"), indent=1, default=str)
    check(f["identity"] == {"project_id": ident[0], "instance_uid": ident[1]} and f["active"]["config_version"] == act[0]
          and f["active"]["config_sha256"] == act[1] and act[1] in f["deployable_sha256"] and f["active"]["flags"] == flags
          and f["schema_head"] == {"core": heads[0], "extension": heads[1]} and heads[1] == max(x[:4] for x in os.listdir(os.path.join(h.ROOT, "db", "migrations")) if x[:4] >= "9000"), f"{f} {ident} {act} {flags} {heads}")
    check(set(health) == {"status", "schema_head", "identity_present"} and forb.startswith("FORBIDDEN"), f"{health} {forb}")
    return (f"wrk_binding_facts returns identity, ACTIVE digest and flags {flags}, deployable digests, schema heads {heads} and the catalog digest; "
            f"bnx_app cannot call it or wrk_catalog (permission denied); a non-worker session is FORBIDDEN; q_health still reveals no identity value")


@test("AT-B7-01", "Amendment 03 §5.2 B7; AE V1.2 §6 (token audience = this instance, inside resolve_actor)")
def t_b7(server, ev):
    H = household(server, "bnx_c14b7")
    C3.client(H)
    R = "https://bb.balnexa.test/mcp"
    r1, v1 = C3.consent(H, ["finance.read"], resource=R)
    t1 = C3.token(H, r1, v1)["access_token"]
    r0, v0 = C3.consent(H, ["finance.read"])
    t0 = C3.token(H, r0, v0)["access_token"]
    q = lambda tok, aud=None: H.app.call("q_balances", {"kind": "bearer", "secret": tok, **({"audience": aud} if aud else {})}, {})
    out = {"bound, same audience": "balances" in q(t1, R),
           "bound, other audience": expect_err(q, "UNAUTHENTICATED", t1, "https://other.example/mcp"),
           "bound, no audience (direct caller)": "balances" in q(t1),
           "unbound token, any audience": "balances" in q(t0, "https://other.example/mcp")}
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-B7-01.json"), "w"), indent=1)
    check(out["bound, same audience"] and out["bound, other audience"].startswith("UNAUTHENTICATED") and out["bound, no audience (direct caller)"]
          and out["unbound token, any audience"], f"{out}")
    return ("a token issued for resource R works at the Gateway of R and is UNAUTHENTICATED at another audience; tokens issued without a "
            "resource (R1/9009 optional parameter) stay accepted (limit L-CORE7-4)")


@test("AT-Q-02-DB", "UA V1.2 §9.1; S4B-F13; AT-Q-02 (unknown kind: back-off, Owner alert after 3 attempts, never done or dead)")
def t_defer(server, ev):
    H = household(server, "bnx_c14q")
    with H.definer() as cx:
        wid = cx.execute("select bnx.enqueue('doc.future_kind', '{\"x\": 1}'::jsonb)").fetchone()[0]
        cx.commit()
    steps = []
    for i in range(6):
        with H.definer() as cx:                                   # the back-off passed (simulated): the lease expires
            cx.execute("update bnx.work_item set lease_until = now() - interval '1 second' where id = %s and state = 'leased'", (wid,))
            cx.commit()
        c = H.worker.call("wrk_claim", 10)
        check([x["id"] for x in c["items"]] == [wid], f"claim {i}: {c}")
        d = H.worker.call("wrk_defer_item", wid)
        with H.definer() as cx:
            st, att, lu = cx.execute("select state, attempts, round(extract(epoch from lease_until - now()) / 60) from bnx.work_item where id = %s", (wid,)).fetchone()
        steps.append((d["attempts"], d["alerted"], st, int(lu)))
    status = H.worker.call("wrk_queue_status")
    again = H.worker.call("wrk_claim", 10)                         # still leased in the future: not claimable, queue drained
    with H.definer() as cx:
        alerts = cx.execute("select count(*) from bnx_intake.notification where minimal_metadata->>'kind' = 'WORK_KIND_UNKNOWN'").fetchone()[0]
    nf = H.worker.call("wrk_defer_item", 999999999)
    H.close()
    json.dump({"steps": steps, "status": status, "again": again, "alerts": alerts}, open(os.path.join(ev, "AT-Q-02-DB.json"), "w"), indent=1, default=str)
    check([s[0] for s in steps] == [1, 2, 3, 4, 5, 6] and all(s[2] == "leased" for s in steps), f"{steps}")
    check([s[3] for s in steps] == [5, 10, 20, 40, 80, 160] and [s[1] for s in steps] == [False, False, True, False, False, False] and alerts == 1, f"{steps} {alerts}")
    check(again["items"] == [] and status["queued"] == 0 and status["drained_generation"] == status["generation"] and nf["status"] == "not_found", f"{status} {again} {nf}")
    return (f"an item of an unknown kind is deferred with back-off {[s[3] for s in steps]} min over 6 attempts, stays leased (never done, never dead "
            f"— R1 would have marked it dead after 5 failures), one Owner alert at attempt 3 (deduplicated per kind and day); while deferred it is not "
            f"claimable and the queue counts as drained, so idle ticks do not wake Neon")


@test("AT-EV-01-DB", "UA V1.2 §8.1; OBJ-271; AT-EV-01 (upload target: own upload_pending file only; no oracle; never on an AI connection)")
def t_upload_target(server, ev):
    H = household(server, "bnx_c14ev")
    f = H.cmd(H.owner, "register_evidence", size=2048, sha256_declared=hashlib.sha256(b"stmt").hexdigest(), name="stmt.pdf")["evidence_file_id"]
    t = H.q(H.owner, "evidence_upload_target", evidence_file_id=f)
    out = {"member asks for the owner's file": expect_err(H.q, "NOT_AVAILABLE", H.member, "evidence_upload_target", evidence_file_id=f),
           "unknown file": expect_err(H.q, "NOT_AVAILABLE", H.owner, "evidence_upload_target", evidence_file_id=str(uuid.uuid4())),
           "malformed id": expect_err(H.q, "VALIDATION_FAILED", H.owner, "evidence_upload_target", evidence_file_id="x")}
    with H.definer() as cx:
        cx.execute("update bnx.evidence_file set storage_state = 'stored' where id = %s", (f,)); cx.commit()
    out["after upload"] = expect_err(H.q, "NOT_AVAILABLE", H.owner, "evidence_upload_target", evidence_file_id=f)
    C3.client(H)
    r, v = C3.consent(H, ["finance.read", "finance.draft"])
    tok = {"kind": "bearer", "secret": C3.token(H, r, v)["access_token"]}
    out["AI connection"] = expect_err(H.app.call, "SCOPE_NOT_CONSENTED", "q_evidence_upload_target", tok, {"evidence_file_id": f})
    H.close()
    json.dump({"target": t, **out}, open(os.path.join(ev, "AT-EV-01-DB.json"), "w"), indent=1)
    check(t["evidence_file_id"] == f and t["r2_key"].startswith("orig/") and t["size_bytes"] == 2048 and t["sha256_declared"] == hashlib.sha256(b"stmt").hexdigest(), f"{t}")
    return (f"the registering member gets the R2 key, size and declared SHA-256 of an upload_pending file; another member, an unknown file and a "
            f"stored file -> NOT_AVAILABLE (identical, no oracle); an AI connection is refused before the function body (SCOPE_NOT_CONSENTED: outside the MCP catalog; FORBIDDEN_CHANNEL behind it)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core14", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core14_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
