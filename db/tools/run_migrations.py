#!/usr/bin/env python3
"""Balnexa migration runner (R6.2-R1, AUD-049).

Connects as the restricted migrator identity (bnx_migrator: LOGIN, NOINHERIT, member of bnx_definer WITH INHERIT FALSE,
SET TRUE). Every migration runs in ONE transaction:  SET LOCAL ROLE bnx_definer -> file -> schema_migrations row ->
apply_grants() -> audit_privileges() must report zero violations -> COMMIT.  Any error rolls back the whole migration.

Fail-closed rules
  * the connected session must be bnx_migrator (unless --expect-user names another non-superuser identity);
  * the session must not be superuser and must not inherit privileges;
  * applied versions must equal a prefix of the ordered file list and every applied SHA-256 must match its file
    (a tampered or removed applied migration aborts BEFORE anything is applied);
  * Draft-04 0001 (privileged bootstrap) and 0007 (needed RESET ROLE) are refused: they are superseded by
    db/bootstrap/B001_bootstrap.sql and 0101; the originals are kept unchanged in db/history/draft04.

Usage: run_migrations.py --dsn "host=... port=... user=bnx_migrator dbname=..." [--dir DIR] [--upto NNNN]
                         [--inject-failure NNNN] [--log FILE]
"""
import argparse, hashlib, json, os, re, sys
import psycopg

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
        ordered = sorted(bodies)
        applied = sorted(have)
        if applied != ordered[:len(applied)]:
            extra = [v for v in applied if v not in bodies]
            log(fh, f"FAIL applied versions {applied} are not a prefix of files {ordered} (missing files: {extra})"); sys.exit(4)
        for v in applied:
            if have[v] != hashes[v]:
                log(fh, f"FAIL {names[v]}: applied sha256 {have[v][:16]} != file {hashes[v][:16]} (migrations are immutable)")
                sys.exit(5)
            log(fh, f"skip  {names[v]} sha256={hashes[v][:16]} (applied, verified)")
        for v in ordered[len(applied):]:
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
