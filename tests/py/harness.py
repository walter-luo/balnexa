# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Shared test harness: fresh database = privileged bootstrap B001 (installer identity) + migration chain applied by the
restricted bnx_migrator through db/tools/run_migrations.py. Tests then connect ONLY as the intended runtime roles."""
import json, os, subprocess, sys, threading, uuid
import psycopg
import jsonschema_lite

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PSQL = os.environ.get("BNX_PSQL", "/usr/lib/postgresql/16/bin/psql")
SERVERS = {
    "pg16": os.environ.get("BNX_PG16", "host=/var/lib/postgresql/bnx16 port=55416"),
    "pg17": os.environ.get("BNX_PG17", "host=/var/lib/postgresql/bnx17 port=55417"),
}   # BNX_PG16 / BNX_PG17 point a run at a second cluster pair, so a regression and development tests can run side by side


def dsn(server, user, db):
    return f"{SERVERS[server]} user={user} dbname={db}"


def role_slot(server, role, timeout=10.0):
    """wait until `role` has a free connection slot. A closed client connection frees its slot only when the server backend
    has exited, which can lag the close; a role with a small connection limit (bnx_backup: 2) can then refuse an immediate
    reconnect ("too many connections for role"). Tests that hold one connection and open another call this first."""
    import time
    end = time.monotonic() + timeout
    with psycopg.connect(dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        while True:
            lim, used = cx.execute("select r.rolconnlimit, (select count(*) from pg_stat_activity a where a.usename = r.rolname) "
                                   "from pg_roles r where r.rolname = %s", (role,)).fetchone()
            if lim < 0 or used < lim or time.monotonic() > end:
                return
            time.sleep(0.02)


def drop_all(server):
    with psycopg.connect(dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        dbs = [r[0] for r in cx.execute("select datname from pg_database where datname like 'bnx\\_%'")]
        for d in dbs:
            cx.execute(f'drop database "{d}" with (force)')
        roles = [r[0] for r in cx.execute("select rolname from pg_roles where rolname like 'bnx\\_%' or rolname = 'balnexa_audit_owner'")]
        for r in roles:
            cx.execute(f'drop role "{r}"')


def run_bootstrap(server, db, name, user="postgres"):
    """run one bootstrap file with psql as the installer, then confirm it took effect: a psql that exits 0 without having
    applied the file (seen on a native-Windows runner, G0-PWA-01) must fail here, not later as a missing role."""
    try:
        r = subprocess.run([PSQL, dsn(server, user, db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1",
                            "-f", os.path.join(ROOT, "db", "bootstrap", name)], capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=300)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"{name}: psql did not finish within 300 s ({PSQL})") from e
    if r.returncode:
        raise RuntimeError(f"{name} failed: " + r.stderr)
    version = name.split("_", 1)[0]
    with psycopg.connect(dsn(server, "postgres", db), autocommit=True) as cx:
        has_table = cx.execute("select to_regclass('bnx.schema_bootstrap') is not null").fetchone()[0]
        done = has_table and cx.execute("select exists (select 1 from bnx.schema_bootstrap where version = %s)",
                                        (version,)).fetchone()[0]
    if not done:
        raise RuntimeError(f"{name}: psql exited 0 but {version} is not recorded in bnx.schema_bootstrap ({PSQL}); "
                           f"stdout: {r.stdout[-300:]!r} stderr: {r.stderr[-300:]!r}")
    return r


def bootstrap(server, db, b002=True):
    """B001 and (S4, default) B002 by the installer identity. b002=False reproduces an R1-only database."""
    with psycopg.connect(dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute(f'create database "{db}"')
    run_bootstrap(server, db, "B001_bootstrap.sql")
    if b002:
        run_bootstrap(server, db, "B002_bootstrap_s4.sql")


def migrate(server, db, *extra, check=True, log=None, mdir=None, b003=True):
    """Run the migrator. b003=True (default) performs the documented installer step: when the runner stops before 9011
    with BOOTSTRAP_MISSING for B003, run db/bootstrap/B003_audit_owner.sql as the installer and run the runner again.
    The returned stdout holds both runs."""
    cmd = [sys.executable, os.path.join(ROOT, "db/tools/run_migrations.py"), "--dsn", dsn(server, "bnx_migrator", db)]
    if mdir:
        cmd += ["--dir", mdir]
    if log:
        cmd += ["--log", log]
    cmd += list(extra)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if b003 and r.returncode == 6 and "BOOTSTRAP_MISSING: B003" in r.stdout:
        run_bootstrap(server, db, "B003_audit_owner.sql")
        r2 = subprocess.run(cmd, capture_output=True, text=True)
        r = subprocess.CompletedProcess(r2.args, r2.returncode, r.stdout + r2.stdout, r.stderr + r2.stderr)
    if check and r.returncode:
        raise RuntimeError("migrations failed:\n" + r.stdout + r.stderr)
    return r


def fresh(server, db=None):
    db = db or "bnx_" + uuid.uuid4().hex[:8]
    bootstrap(server, db)
    migrate(server, db)
    return db


def as_definer_via_migrator(server, db, sql, params=None):
    """Installer step executed by the migrator identity under SET ROLE (never a runtime role)."""
    with psycopg.connect(dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        r = cx.execute(sql, params).fetchall() if params is not None else cx.execute(sql).fetchall()
        cx.commit()
        return r


_SWEEP = os.environ.get("BNX_NULL_SWEEP")   # L-R2-1: tools/s4/null_guard_sweep.py sets it; never set in a normal regression


def _mutations(body):
    """(path, mode, mutated body) for every top-level key (absent / null / empty) and every key of the first object of an
    array of objects (absent / null)."""
    for k, v in body.items():
        if k == "idempotency_key":
            continue
        yield k, "absent", {x: y for x, y in body.items() if x != k}
        if v is not None:
            yield k, "null", {**body, k: None}
        if isinstance(v, list) and v:
            yield k, "empty", {**body, k: []}
        if isinstance(v, str) and v:
            yield k, "empty", {**body, k: ""}
        if isinstance(v, list) and v and isinstance(v[0], dict):
            for k2 in v[0]:
                el = {x: y for x, y in v[0].items() if x != k2}
                yield f"{k}[0].{k2}", "absent", {**body, k: [el] + v[1:]}
                if v[0][k2] is not None:
                    yield f"{k}[0].{k2}", "null", {**body, k: [{**v[0], k2: None}] + v[1:]}


def _attempt(cx, sql, conv, promote=False):
    """Run one call in a transaction that is always rolled back; return 'ok' or the error's SQLSTATE and message. With
    promote, the call is wrk_stage_completion and the staged payload is promoted in the same transaction (the validation
    of a staged completion runs at promotion): a promotion that ends REJECTED or AWAITING_PROMOTER is not 'ok'."""
    try:
        with cx.transaction(force_rollback=True):
            r = cx.execute(sql, conv).fetchone()[0]
            st = r.get("status") if isinstance(r, dict) else None
            if promote:
                st = cx.execute("select bnx.wrk_promote_staged(%s)", (r["staging_id"],)).fetchone()[0]
                if st in ("rejected", "awaiting_promoter", "not_found"):
                    return f"promotion {st}"
        return "ok" if st is None else f"ok {st}"
    except psycopg.Error as e:
        return f"{e.sqlstate} {(e.diag.message_primary or '')[:80]}"


def _head(server, db):
    """Highest applied migration of the database (suites also call functions on older schema versions; the sweep report
    keeps only calls made at the newest migration). A short connection per call: a cached one would hold the database
    open and block suites that drop or copy it."""
    try:
        with psycopg.connect(dsn(server, "postgres", db), autocommit=True) as c:
            return c.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
    except psycopg.Error:
        return None


def null_sweep(cx, fn, ph, conv, body, head=None):
    """L-R2-1 sweep: before the real call, try the call as given and then once per mutation of its last JSON argument, each
    in a rolled-back transaction; append one JSON line per mutation to $BNX_NULL_SWEEP when the unmutated call succeeds.
    Nothing is committed and the real call that follows is unchanged. Synthetic test data only; the output is not committed
    raw (the report keeps function names, key paths and outcomes only, no values)."""
    sql = f"select bnx.{fn}({ph})"
    if cx.info.transaction_status != psycopg.pq.TransactionStatus.IDLE:   # the caller holds a transaction: do not touch it
        return
    if threading.current_thread() is not threading.main_thread():     # concurrency tests share connections across threads
        return
    promote = fn == "wrk_stage_completion"
    if promote:
        fn = f"{fn}:{conv[1]}"                       # one entry per staged kind
    base = _attempt(cx, sql, conv, promote)
    if not base.startswith("ok"):
        return
    rows = []
    for path, mode, mut in _mutations(body):
        c2 = list(conv)
        c2[-1] = json.dumps(mut)
        o = _attempt(cx, sql, c2, promote)
        # accepted = the mutation succeeds with the same reported status as the unmutated call (a different status, e.g.
        # FAILED instead of VERIFIED, means the gap was noticed and recorded)
        rows.append({"fn": fn, "path": path, "mode": mode, "outcome": "ok" if o == base else o, "base": base})
    with open(_SWEEP, "a") as f:
        f.write(json.dumps({"fn": fn, "head": head, "keys": sorted(body), "results": rows}) + "\n")


class Role:
    """A connection as a real runtime role; calls definer functions with JSON arguments."""
    def __init__(self, server, db, role):
        self.role = role
        self.server, self.db = server, db
        self.cx = psycopg.connect(dsn(server, role, db), autocommit=True)

    def call(self, fn, *args):
        ph = ", ".join(["%s::jsonb" if isinstance(a, (dict, list)) else "%s" for a in args])
        conv = [json.dumps(a) if isinstance(a, (dict, list)) else a for a in args]
        if _SWEEP and fn.startswith(("cmd_", "wrk_")) and args and isinstance(args[-1], dict):
            null_sweep(self.cx, fn, ph, conv, args[-1], _head(self.server, self.db))
        r = self.cx.execute(f"select bnx.{fn}({ph})", conv).fetchone()[0]
        if self.role == "bnx_app":                    # output contract (2.8): curated tools conform in every suite
            jsonschema_lite.check_output(fn, r)
        return r

    def sql(self, q, p=None):
        return self.cx.execute(q, p).fetchall()

    def close(self):
        self.cx.close()
