#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""S4 V1.2 increment 7 tests: G0 remediation G0R (G0 report 2026-11-11, SAME_FAMILY_VERIFICATION).
F-01 (owner path could empty or shorten the audit chain undetected): bootstrap B003, migration 9011 block G0R, runner gate,
external verifier tools/s4/audit_chain_verify.py. F-04 (invisible Unicode in envelope values). F-06 (anchor = seq and head
hash). Conventions as run_g0.py. Synthetic data only.
Usage: run_s4_core7.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, subprocess, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4

RESULTS, TESTS = [], []
check = C1.check
ROOT = h.ROOT
TOOL = os.path.join(ROOT, "tools", "s4", "audit_chain_verify.py")
T = "bnx_audit.audit_event"


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def verifier(server, db, *anchors):
    cmd = [sys.executable, "-I", TOOL, "--dsn", h.dsn(server, "bnx_backup", db)] + [x for a in anchors for x in ("--anchor", a)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        out = {"raw": r.stdout[-500:], "stderr": r.stderr[-500:]}
    return r.returncode, out


def as_owner_path(server, db, sql):
    """bnx_migrator -> SET ROLE bnx_definer (the path G0 X3 used); the statement is rolled back if it succeeds."""
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        try:
            cx.execute(sql)
            cx.rollback()
            return "ACCEPTED"
        except psycopg.Error as e:
            return "refused: " + (e.diag.message_primary or str(e))[:80]


def violations(server, db):
    with C1.migrator(server, db) as cx:
        return cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]


def built(server, name):
    """A v2 household with audited activity (installation, configuration, members)."""
    return C4.v2_full(server, name)


# ------------------------------------------------------------------------------------------------ F-01 owner path
@test("AT-G0R-01", "G0 F-01 / V8.4 / X3 (owner path cannot remove, change or replace audit rows)")
def t_owner_path(server, ev):
    H = built(server, "bnx_g0r01")
    db = H.db
    n0 = C4.one(H, f"select count(*) from {T}")[0]
    v0 = C4.one(H, "select bnx.audit_verify()")[0]
    H.close()
    attempts = {
        "TRUNCATE table": f"truncate {T}", "TRUNCATE view": "truncate bnx.audit_event",
        "DISABLE TRIGGER ALL": f"alter table {T} disable trigger all", "DISABLE one trigger": f"alter table {T} disable trigger t_append_only",
        "DELETE last rows": f"delete from {T} where seq > (select max(seq) - 3 from {T})", "DELETE via view": "delete from bnx.audit_event",
        "UPDATE": f"update {T} set command = 'x' where seq = 1", "DROP TABLE": f"drop table {T}",
        "DROP SCHEMA bnx_audit": "drop schema bnx_audit cascade", "RENAME": f"alter table {T} rename to audit_event_old",
        "OWNER TO bnx_definer": f"alter table {T} owner to bnx_definer", "SET ROLE audit owner": "set role balnexa_audit_owner",
        "CREATE in bnx_audit": "create table bnx_audit.decoy(i int)", "GRANT TRUNCATE to itself then TRUNCATE":
            f"grant truncate on {T} to bnx_definer; truncate {T}",
        "session_replication_role replica": "set session_replication_role = replica",
    }
    res = {k: as_owner_path(server, db, q) for k, q in attempts.items()}
    # 9011 review R-10: an append that would break the chain is refused at INSERT by the audit owner's t_chain_append
    poisoned = as_owner_path(server, db, "insert into bnx.audit_event(seq, channel, command, subject, payload_sha256, prev_hash, hash, at_hashed) "
                                         f"select max(seq) + 1, 'pwa', 'forged', '{{}}', '\\x00', null, '\\x00', now() from {T}")
    gap = as_owner_path(server, db, f"insert into {T}(seq, channel, command, subject, payload_sha256, prev_hash, hash, at_hashed) "
                                    f"select max(seq) + 5, 'pwa', 'forged', '{{}}', '\\x00', (select hash from {T} order by seq desc limit 1), '\\x00', now() from {T}")
    appended = as_owner_path(server, db, "select bnx.audit(row(null, null, 'system', null, null)::bnx.actor, 'probe', '{}'::jsonb, '{}'::jsonb, null)")
    with C1.migrator(server, db) as cx:
        n1 = cx.execute(f"select count(*) from {T}").fetchone()[0]
        v1 = cx.execute("select bnx.audit_verify()").fetchone()[0]
    rc, vout = verifier(server, db)
    viol = violations(server, db)
    json.dump({"attempts": res, "append": appended, "poisoned_append": poisoned, "gap_append": gap, "rows": [n0, n1], "audit_verify": [v0, v1], "external": vout, "violations": viol},
              open(os.path.join(ev, "AT-G0R-01_owner_path.json"), "w"), indent=1)
    accepted = [k for k, v in res.items() if v == "ACCEPTED"]
    check(not accepted, f"owner path accepted: {accepted}")
    check(n0 == n1 and v0 == 0 and v1 == 0 and rc == 0 and vout.get("verdict") == "INTACT" and viol == [], f"{n0} {n1} {v0} {v1} {rc} {vout} {viol}")
    check(appended == "ACCEPTED", f"append path (bnx.audit) must keep working: {appended}")
    check("AUDIT_CHAIN_APPEND" in poisoned and "AUDIT_CHAIN_APPEND" in gap, f"chain-breaking appends: {poisoned} / {gap}")
    return (f"bnx_migrator -> SET ROLE bnx_definer: all {len(attempts)} attempts refused (TRUNCATE table/view, DISABLE TRIGGER, "
            f"DELETE, UPDATE, DROP TABLE, DROP SCHEMA, RENAME, OWNER TO, SET ROLE, CREATE, self-GRANT then TRUNCATE, "
            f"session_replication_role); bnx.audit() still appends, while a mis-hashed or gapped INSERT is refused at insert "
            f"(AUDIT_CHAIN_APPEND, 9011 review R-10); "
            f"{n1} rows unchanged, audit_verify 0, external verifier INTACT, 0 privilege violations")


# ------------------------------------------------------------------------------------------------ detection of regressions
@test("AT-G0R-02", "G0 F-01 (privilege audit and external verifier detect each weakening; runner exit 7)")
def t_detection(server, ev):
    H = built(server, "bnx_g0r02")
    db = H.db
    H.close()
    cases = {
        "owner back to bnx_definer": (f"alter table {T} owner to bnx_definer", f"alter table {T} owner to balnexa_audit_owner; grant select, insert on {T} to bnx_definer",
                                      "OWNER", "TABLE_OWNER"),
        "TRUNCATE granted to bnx_definer": (f"grant truncate on {T} to bnx_definer", f"revoke truncate on {T} from bnx_definer",
                                            "AUDIT_TABLE_PRIVILEGE", "WRITE_PRIVILEGE"),
        "column UPDATE granted": (f"grant update (command) on {T} to bnx_definer", f"revoke update (command) on {T} from bnx_definer",
                                  "AUDIT_TABLE_PRIVILEGE", "COLUMN_WRITE_PRIVILEGE"),
        "append-only trigger disabled": (f"alter table {T} disable trigger t_append_only", f"alter table {T} enable trigger t_append_only",
                                         "AUDIT_TRIGGER", "TRIGGER"),
        "migrator may SET ROLE audit owner": ("grant balnexa_audit_owner to bnx_migrator with set true, inherit false",
                                              "revoke balnexa_audit_owner from bnx_migrator", "MEMBERSHIP", "AUDIT_OWNER_MEMBER"),
        "audit owner can log in": ("alter role balnexa_audit_owner login", "alter role balnexa_audit_owner nologin",
                                   "AUDIT_OWNER_LOGIN", "AUDIT_OWNER_ROLE"),
        "INSERT granted to bnx_app": (f"grant insert on {T} to bnx_app", f"revoke insert on {T} from bnx_app",
                                      "RUNTIME_TABLE_PRIVILEGE", "INSERT_PRIVILEGE"),
        # 9011 review R-12: implicit rights through a predefined role, and table-shape changes that hide or divert rows
        "pg_write_all_data granted to bnx_definer": ("grant pg_write_all_data to bnx_definer", "revoke pg_write_all_data from bnx_definer",
                                                    "AUDIT_TABLE_PRIVILEGE", "EFFECTIVE_WRITE_PRIVILEGE"),
        "row security with a hiding policy": (f"alter table {T} enable row level security; create policy hide on {T} for select using (seq < 3)",
                                              f"drop policy hide on {T}; alter table {T} disable row level security",
                                              "AUDIT_TABLE_SHAPE", "TABLE_SHAPE"),
        "extra trigger on the chain": (f"create function public.noop_tg() returns trigger language plpgsql as $$ begin return new; end $$; "
                                       f"create trigger zz_extra before insert on {T} for each row execute function public.noop_tg()",
                                       f"drop trigger zz_extra on {T}; drop function public.noop_tg()", "", "EXTRA_TRIGGER"),
        "chain-append check disabled": (f"alter table {T} disable trigger t_chain_append", f"alter table {T} enable trigger t_chain_append",
                                        "AUDIT_TRIGGER", "TRIGGER"),
    }
    out, bad = {}, []
    for name, (do, undo, rule, ext) in cases.items():
        with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as cx:
            cx.execute(do)
        v = violations(server, db)
        rc, vo = verifier(server, db)
        r = h.migrate(server, db, check=False)
        with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as cx:
            cx.execute(undo)
        got_rule = [x["rule"] for x in v]
        got_ext = vo.get("catalog", [])
        out[name] = {"audit_privileges": got_rule, "external": got_ext, "external_exit": rc, "runner_exit": r.returncode}
        # an extra trigger is a verifier-only check (the database audit does not enumerate triggers); runner exit 0 then
        db_ok = (not rule and r.returncode == 0) or (rule and any(rule in g for g in got_rule) and r.returncode == 7)
        if not db_ok or not any(g.startswith(ext) for g in got_ext) or rc != 1:
            bad.append(name)
    clean_v, (clean_rc, _) = violations(server, db), verifier(server, db)
    json.dump(out, open(os.path.join(ev, "AT-G0R-02_detection.json"), "w"), indent=1)
    check(not bad, f"not detected: {bad}: {json.dumps({k: out[k] for k in bad})}")
    check(clean_v == [] and clean_rc == 0, f"after revert: {clean_v} {clean_rc}")
    return (f"{len(cases)} weakenings made by a superuser (owner back to bnx_definer, TRUNCATE or column UPDATE granted, trigger "
            f"disabled, SET membership for bnx_migrator, LOGIN for the audit owner, INSERT for bnx_app, pg_write_all_data for the "
            f"definer, a hiding row-security policy, the chain-append check disabled): each reported by audit_privileges() (runner "
            f"exit 7) and by the external verifier (exit 1); an extra trigger is reported by the verifier; clean again after revert")


# ------------------------------------------------------------------------------------------------ B003 and the runner
@test("AT-G0R-03", "G0 F-01, F-02 (install order: runner stops before 9011 until B003; B003 order and name checks; re-run no-op)")
def t_order(server, ev):
    db = "bnx_g0r03"
    h.bootstrap(server, db)
    r1 = h.migrate(server, db, check=False, b003=False)
    with C1.migrator(server, db) as cx:
        head = cx.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
        kind = cx.execute("select relkind from pg_class where oid = to_regclass('bnx.audit_event')").fetchone()[0]
    check(r1.returncode == 6 and "BOOTSTRAP_MISSING: B003" in r1.stdout and head == "9010" and kind == "r", f"{r1.stdout[-300:]} head={head} kind={kind}")
    # B003 before the audit table exists is refused and changes nothing
    db0 = "bnx_g0r03early"
    h.bootstrap(server, db0)
    e = subprocess.run([h.PSQL, h.dsn(server, "postgres", db0), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1", "-f",
                        os.path.join(ROOT, "db/bootstrap/B003_audit_owner.sql")], capture_output=True, text=True)
    with psycopg.connect(h.dsn(server, "postgres", db0)) as cx:
        sch = cx.execute("select count(*) from pg_namespace where nspname = 'bnx_audit'").fetchone()[0]
    check(e.returncode != 0 and "B003_ORDER" in e.stderr and sch == 0, f"{e.returncode} {e.stderr[-300:]} {sch}")
    # an installer whose name starts with bnx_ is refused with a clear message (F-02)
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute("drop role if exists bnx_g0r_installer"); cx.execute("create role bnx_g0r_installer login superuser")
    try:
        nm = subprocess.run([h.PSQL, h.dsn(server, "bnx_g0r_installer", db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1", "-f",
                             os.path.join(ROOT, "db/bootstrap/B003_audit_owner.sql")], capture_output=True, text=True)
    finally:
        with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
            cx.execute("drop role bnx_g0r_installer")
    check(nm.returncode != 0 and "B003_INSTALLER_NAME" in nm.stderr, nm.stderr[-300:])
    h.run_bootstrap(server, db, "B003_audit_owner.sql")
    again = h.run_bootstrap(server, db, "B003_audit_owner.sql")
    r2 = h.migrate(server, db, check=False, b003=False)
    with C1.migrator(server, db) as cx:
        head2 = cx.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
        reg = cx.execute("select owner, usage_roles, registered_by from bnx.schema_registry where nspname = 'bnx_audit'").fetchone()
    check("already applied" in again.stdout, again.stdout)
    check(r2.returncode == 0 and "privilege_violations=0" in r2.stdout and head2 >= "9011", r2.stdout[-300:])
    check(reg == ("balnexa_audit_owner", ["bnx_backup"], "B003"), f"{reg}")
    out = {"before_b003": r1.stdout.strip().splitlines()[-1], "early_b003": e.stderr.strip().splitlines()[-1][:200],
           "bnx_installer_name": nm.stderr.strip().splitlines()[-1][:200], "rerun": again.stdout.strip(), "after": r2.stdout.strip().splitlines()[-1]}
    json.dump(out, open(os.path.join(ev, "AT-G0R-03_order.json"), "w"), indent=1)
    return ("runner without B003: applies up to 9010 and stops with exit 6 BOOTSTRAP_MISSING naming B003 (audit table still in bnx); "
            "B003 before the migrations -> B003_ORDER, nothing created; installer named bnx_* -> B003_INSTALLER_NAME (F-02); B003 "
            "applied, re-run no-op; runner then applies 9011 with 0 violations; bnx_audit registered (owner balnexa_audit_owner, "
            "USAGE bnx_backup only)")


# ------------------------------------------------------------------------------------------------ F-04 envelope
@test("AT-G0R-04", "G0 F-04 (envelope values: printable ASCII only, locale-independent)")
def t_envelope(server, ev):
    H = built(server, "bnx_g0r04")
    zw = "zero" + chr(0x200B) + "width"
    out = {}
    for label, val, ok in (("zero-width space", zw, False), ("bidi override", "a" + chr(0x202E) + "b", False),
                           ("no-break space", "a" + chr(0xA0) + "b", False), ("non-ASCII letter", "caf" + chr(0xE9), False),
                           ("100 ASCII", "x" * 100, True), ("101 ASCII", "x" * 101, False), ("ASCII punctuation", "Claude Desktop/1.2 (mcp)", True)):
        for field in ("host_profile", "tool_name"):
            try:
                H.app.call("q_whoami", {**H.owner, "envelope": {field: val}}, {})
                got = True
            except psycopg.Error as e:
                got = False if "VALIDATION_FAILED" in (e.diag.message_primary or "") else "error:" + (e.diag.message_primary or "")
            out[f"resolve_actor {field} {label}"] = got == ok
    # sessions that audit without resolve_actor: the GUC is checked again at the point of use (envelope_value)
    for label, val, ok in (("zero-width space", zw, False), ("ASCII", "tool-1.0", True)):
        with psycopg.connect(h.dsn(server, "postgres", H.db)) as cx:
            cx.execute("set role bnx_definer")
            cx.execute("select set_config('bnx.tool_name', %s, false)", (val,))
            try:
                cx.execute("select bnx.audit(row(null, null, 'worker', null, null)::bnx.actor, 'probe', '{}', '{}', null)")
                got = True
            except psycopg.Error as e:
                got = False if e.diag.message_primary == "VALIDATION_FAILED" else "error:" + str(e)
            cx.rollback()
        out[f"worker GUC tool_name {label}"] = got == ok
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-G0R-04_envelope.json"), "w"), indent=1)
    bad = [k for k, v in out.items() if v is not True]
    check(not bad, f"envelope rule mismatches: {bad}")
    return (f"{len(out)} probes: zero-width space, bidi override, no-break space and non-ASCII letters refused (VALIDATION_FAILED) in "
            f"resolve_actor and at audit() for Worker-set GUCs; 100 printable ASCII characters accepted, 101 refused")


# ------------------------------------------------------------------------------------------------ F-06 anchors
@test("AT-G0R-05", "G0 F-06, V8.6, X2 (external verifier; an anchor of seq and head hash detects superuser truncation and rewrites)")
def t_anchor(server, ev):
    H = built(server, "bnx_g0r05")
    db = H.db
    H.close()
    rc0, o0 = verifier(server, db)
    anchor = f"{o0['head']['seq']}:{o0['head']['hash']}"
    res = {"clean": [rc0, o0.get("verdict")]}
    scenarios = {
        "superuser deletes the last 3 rows": [f"set session_replication_role = replica",
                                              f"delete from {T} where seq > (select max(seq) - 3 from {T})"],
        "superuser rewrites seq 2 and recomputes every later hash": [
            "set session_replication_role = replica",
            f"update {T} set command = command || '-rewritten' where seq = 2",
            f"""do $$ declare r record; prev bytea; begin
                  select hash into prev from {T} where seq = 1;
                  for r in select * from {T} where seq >= 2 order by seq loop
                    update {T} set prev_hash = prev,
                      hash = sha256(coalesce(prev, '\\x'::bytea) || case when r.chain_version = 1 then
                        convert_to(concat_ws('|', r.seq, r.member_id, r.connection_id, r.channel, r.command, r.subject::text,
                                   encode(r.payload_sha256, 'hex'), r.ledger_version), 'UTF8')
                        else bnx.audit_canonical_v2(r.seq, r.member_id, r.connection_id, r.channel, r.command, r.subject,
                          encode(r.payload_sha256, 'hex'), r.ledger_version, r.at_hashed, r.chain_version, r.host_profile, r.tool_name,
                          r.tool_version, r.trace_id) end)
                     where seq = r.seq returning hash into prev;
                  end loop; end $$"""],
    }
    for name, stmts in scenarios.items():
        copy = f"{db}_{len(res)}"
        with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
            cx.execute(f'create database "{copy}" template "{db}"')
        with psycopg.connect(h.dsn(server, "postgres", copy)) as cx:
            for q in stmts:
                cx.execute(q)
            cx.commit()
        with C1.migrator(server, copy) as cx:
            av = cx.execute("select bnx.audit_verify()").fetchone()[0]
        rc_n, o_n = verifier(server, copy)
        rc_a, o_a = verifier(server, copy, anchor)
        res[name] = {"audit_verify": av, "without_anchor": [rc_n, o_n.get("verdict")], "with_anchor": [rc_a, o_a.get("verdict"), o_a.get("anchors")]}
        with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
            cx.execute(f'drop database "{copy}" with (force)')
    # a mis-hashed append through the owner path is refused at insert (9011 review R-10); the chain stays intact
    forged = as_owner_path(server, db, f"insert into bnx.audit_event(seq, channel, command, subject, payload_sha256, prev_hash, hash, at_hashed) "
                                       f"select max(seq) + 1, 'pwa', 'forged', '{{}}', '\\x00', (select hash from {T} order by seq desc limit 1), '\\x00', now() from {T}")
    rc_f, o_f = verifier(server, db, anchor)
    res["forged append by the owner path"] = [forged, rc_f, o_f.get("verdict"), o_f.get("chain")]
    # R-14: a malformed anchor is an argument error (exit 2), not a failed check
    rc_m, _o = verifier(server, db, "12:not-a-hash")
    res["malformed anchor exit"] = rc_m
    json.dump(res, open(os.path.join(ev, "AT-G0R-05_anchor.json"), "w"), indent=1)
    t1, t2 = res["superuser deletes the last 3 rows"], res["superuser rewrites seq 2 and recomputes every later hash"]
    check(rc0 == 0 and o0["verdict"] == "INTACT", f"clean: {o0}")
    check(t1["audit_verify"] == 0 and t1["without_anchor"][1] == "INTACT" and t1["with_anchor"][0] == 1
          and any(a.startswith("ANCHOR_MISSING") for a in t1["with_anchor"][2]), f"tail deletion: {t1}")
    check(t2["audit_verify"] == 0 and t2["without_anchor"][1] == "INTACT" and t2["with_anchor"][0] == 1
          and any(a.startswith("ANCHOR_HASH") for a in t2["with_anchor"][2]), f"rewrite: {t2}")
    check("AUDIT_CHAIN_APPEND" in forged and rc_f == 0 and o_f.get("verdict") == "INTACT", f"forged: {res['forged append by the owner path']}")
    check(rc_m == 2, f"malformed anchor exit {rc_m}")
    return (f"clean chain INTACT, head {anchor.split(':')[0]} recorded as anchor; superuser tail deletion (V8.6) and full rewrite with "
            f"recomputed hashes (X2): audit_verify 0 and verifier INTACT without an anchor (documented residual), FAILED with the anchor "
            f"(ANCHOR_MISSING, ANCHOR_HASH); a mis-hashed append through the owner path is refused at insert and the chain stays "
            f"INTACT (R-10); a malformed --anchor exits 2 (R-14)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(ROOT, "EVIDENCE", "s4_core7", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core7_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
