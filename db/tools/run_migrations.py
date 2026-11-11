#!/usr/bin/env python3
"""Balnexa migration runner (R6.2-R1, AUD-049).

Connects as the restricted migrator identity (bnx_migrator: LOGIN, NOINHERIT, member of bnx_definer WITH INHERIT FALSE,
SET TRUE). Every migration runs in ONE transaction:  SET LOCAL ROLE bnx_definer -> file -> schema_migrations row ->
apply_grants() -> audit_privileges() must report zero violations -> COMMIT.  Any error rolls back the whole migration.

Fail-closed rules
  * the connected session must be bnx_migrator (unless --expect-user names another non-superuser identity);
  * the session must not be superuser and must not inherit privileges;
  * two ordered lanes (S4 V1.2 UA §6.2, S4B-F01): the core lane 0001-8999 and the conversion/extension lane 9000-9999.
    Within each lane the applied versions must equal a prefix of that lane's ordered file list and every applied SHA-256
    must match its file (a tampered or removed applied migration aborts BEFORE anything is applied). Pending core files
    are applied first, then pending lane-9 files; a lane-9 file may therefore follow any core version;
  * the conversion migration 9001 is never applied after an extension migration 9002+ (CONVERSION_AFTER_EXTENSION);
  * before the first extension migration (9002+) is applied, bootstrap B002 must be present: bnx.schema_bootstrap has
    'B002', the four S4 schemas exist owned by bnx_definer and bnx_backup holds USAGE on them (else BOOTSTRAP_MISSING);
  * before 9011 is applied, bootstrap B003 must be present: bnx.schema_bootstrap has 'B003' and bnx.audit_event is
    owned by balnexa_audit_owner (G0 finding F-01). Pending migrations before 9011 are applied first; the runner then stops
    with BOOTSTRAP_MISSING (exit 6) and names the file to run;
  * Draft-04 0001 (privileged bootstrap) and 0007 (needed RESET ROLE) are refused: they are superseded by
    db/bootstrap/B001_bootstrap.sql and 0101; the originals are kept unchanged in db/history/draft04.

Usage: run_migrations.py --dsn "host=... port=... user=bnx_migrator dbname=..." [--dir DIR] [--upto NNNN]
                         [--inject-failure NNNN] [--log FILE]
"""
import argparse, hashlib, json, os, re, sys
import psycopg

EXT_FROM = "9000"          # first version of the conversion/extension lane
S4_FROM = "9002"           # first S4 extension migration (needs bootstrap B002)
S4_SCHEMAS = ("bnx_doc", "bnx_intake", "bnx_tax", "bnx_fed")
B003_FROM = "9011"         # first migration that needs bootstrap B003 (audit table owned by balnexa_audit_owner)
REFUSED = {"0001": "superseded by db/bootstrap/B001_bootstrap.sql", "0007": "superseded by 0101_grants_r1.sql"}


def log(fh, msg):
    print(msg)
    if fh:
        fh.write(msg + "\n"); fh.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "migrations"))
    ap.add_argument("--upto")
    ap.add_argument("--inject-failure", help="raise after applying this version's body (atomicity test)")
    ap.add_argument("--expect-user", default="bnx_migrator")
    ap.add_argument("--log")
    a = ap.parse_args()
    fh = open(a.log, "a", encoding="utf-8") if a.log else None

    files = sorted(f for f in os.listdir(a.dir) if re.match(r"^\d{4}_.*\.sql$", f))
    for f in files:
        if f[:4] in REFUSED:
            log(fh, f"FAIL refused migration {f}: {REFUSED[f[:4]]}"); sys.exit(2)
    if a.upto:
        files = [f for f in files if f[:4] <= a.upto]
    bodies = {f[:4]: open(os.path.join(a.dir, f), "rb").read() for f in files}
    hashes = {v: hashlib.sha256(b).hexdigest() for v, b in bodies.items()}
    names = {f[:4]: f for f in files}

    with psycopg.connect(a.dsn, autocommit=False) as cx:
        cur = cx.cursor()
        cur.execute("select session_user, current_user, r.rolsuper, r.rolinherit, version() from pg_roles r "
                    "where r.rolname = session_user")
        su, cu, sup, inh, ver = cur.fetchone()
        log(fh, f"session_user={su} current_user={cu} rolsuper={sup} rolinherit={inh}")
        log(fh, f"server={ver}")
        if su != a.expect_user or sup or inh:
            log(fh, f"FAIL identity: expected non-superuser NOINHERIT {a.expect_user}"); sys.exit(3)
        cur.execute("set local role bnx_definer")
        cur.execute("select version, sha256 from bnx.schema_migrations order by version")
        have = dict(cur.fetchall())
        cx.rollback()
        core_files = sorted(v for v in bodies if v < EXT_FROM)
        ext_files = sorted(v for v in bodies if v >= EXT_FROM)
        core_applied = sorted(v for v in have if v < EXT_FROM)
        ext_applied = sorted(v for v in have if v >= EXT_FROM)
        for lane, files_, applied_ in (("core", core_files, core_applied), ("extension", ext_files, ext_applied)):
            if applied_ != files_[:len(applied_)]:
                extra = [v for v in applied_ if v not in bodies]
                code = "CONVERSION_AFTER_EXTENSION " if lane == "extension" and "9001" in files_ and "9001" not in applied_ else ""
                log(fh, f"FAIL {code}{lane} lane: applied versions {applied_} are not a prefix of files {files_} "
                        f"(missing files: {extra})"); sys.exit(4)
        applied = core_applied + ext_applied
        for v in applied:
            if have[v] != hashes[v]:
                log(fh, f"FAIL {names[v]}: applied sha256 {have[v][:16]} != file {hashes[v][:16]} (migrations are immutable)")
                sys.exit(5)
            log(fh, f"skip  {names[v]} sha256={hashes[v][:16]} (applied, verified)")
        pending = core_files[len(core_applied):] + ext_files[len(ext_applied):]
        if any(v >= S4_FROM for v in pending):
            cur.execute("set local role bnx_definer")
            cur.execute("select exists (select 1 from bnx.schema_bootstrap where version = 'B002')")
            b002 = cur.fetchone()[0]
            cur.execute("select count(*) from pg_namespace where nspname = any(%s) and pg_get_userbyid(nspowner) = 'bnx_definer' "
                        "and has_schema_privilege('bnx_backup', oid, 'USAGE')", (list(S4_SCHEMAS),))
            nsch = cur.fetchone()[0]
            cx.rollback()
            if not b002 or nsch != len(S4_SCHEMAS):
                log(fh, f"FAIL BOOTSTRAP_MISSING: B002 row={b002}, S4 schemas owned by bnx_definer with backup USAGE={nsch}/"
                        f"{len(S4_SCHEMAS)}; run db/bootstrap/B002_bootstrap_s4.sql as the installer first"); sys.exit(6)
        b003_checked = False
        for v in pending:
            if v >= B003_FROM and not b003_checked:
                cur.execute("set local role bnx_definer")
                cur.execute("select exists (select 1 from bnx.schema_bootstrap where version = 'B003'), "
                            "coalesce((select pg_get_userbyid(relowner) from pg_class where oid = to_regclass('bnx_audit.audit_event')), '')")
                b003, aowner = cur.fetchone()
                cx.rollback()
                if not b003 or aowner != "balnexa_audit_owner":
                    log(fh, f"FAIL BOOTSTRAP_MISSING: B003 row={b003}, bnx_audit.audit_event owner={aowner or 'none'} (expected balnexa_audit_owner); "
                            f"migrations before {v} are applied; run db/bootstrap/B003_audit_owner.sql as the installer, then run "
                            f"this runner again"); sys.exit(6)
                b003_checked = True
            try:
                cur.execute("select pg_advisory_xact_lock(hashtext('bnx.migrations'))")
                cur.execute("set local role bnx_definer")
                cur.execute("select count(*) from bnx.schema_migrations where version = %s", (v,))
                if cur.fetchone()[0]:
                    raise RuntimeError(f"{v} applied concurrently")
                cur.execute(bodies[v].decode("utf-8"))
                cur.execute("set local role bnx_definer")   # a file may not leave the session in another role
                cur.execute("insert into bnx.schema_migrations(version, sha256) values (%s, %s)", (v, hashes[v]))
                if a.inject_failure == v:
                    cur.execute("select 1/0  -- injected failure")
                cur.execute("select to_regprocedure('bnx.apply_grants()') is not null")
                if cur.fetchone()[0]:
                    cur.execute("select bnx.apply_grants()")
                    cur.execute("select bnx.audit_privileges()")
                    audit = cur.fetchone()[0]
                    if audit["violations"]:
                        raise RuntimeError("privilege audit: " + json.dumps(audit["violations"])[:2000])
                cur.execute("select session_user, current_user")
                s2, c2 = cur.fetchone()
                cx.commit()
                log(fh, f"apply {names[v]} sha256={hashes[v][:16]} session_user={s2} current_user={c2}")
            except Exception as e:  # noqa: BLE001 - every failure is fatal and rolled back
                cx.rollback()
                log(fh, f"FAIL {names[v]}: {type(e).__name__}: {str(e).strip().splitlines()[0][:400]} (rolled back)")
                sys.exit(6)
        cur.execute("set local role bnx_definer")
        cur.execute("select count(*), max(version) from bnx.schema_migrations")
        n, mx = cur.fetchone()
        audit = None
        cur.execute("select to_regprocedure('bnx.audit_privileges()') is not null")
        if cur.fetchone()[0]:
            cur.execute("select bnx.audit_privileges()")
            audit = cur.fetchone()[0]
        cx.rollback()
        if audit and audit["violations"]:
            log(fh, "FAIL privilege audit: " + json.dumps(audit["violations"])[:2000]); sys.exit(7)
        log(fh, f"OK migrations={n} head={mx} privilege_violations={len(audit['violations']) if audit else 'n/a'}")


if __name__ == "__main__":
    main()
