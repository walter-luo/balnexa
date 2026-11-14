"""Shared test harness: fresh database = privileged bootstrap B001 (installer identity) + migration chain applied by the
restricted bnx_migrator through db/tools/run_migrations.py. Tests then connect ONLY as the intended runtime roles."""
import json, os, subprocess, sys, uuid
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


class Role:
    """A connection as a real runtime role; calls definer functions with JSON arguments."""
    def __init__(self, server, db, role):
        self.role = role
        self.cx = psycopg.connect(dsn(server, role, db), autocommit=True)

    def call(self, fn, *args):
        ph = ", ".join(["%s::jsonb" if isinstance(a, (dict, list)) else "%s" for a in args])
        conv = [json.dumps(a) if isinstance(a, (dict, list)) else a for a in args]
        r = self.cx.execute(f"select bnx.{fn}({ph})", conv).fetchone()[0]
        if self.role == "bnx_app":                    # output contract (2.8): curated tools conform in every suite
            jsonschema_lite.check_output(fn, r)
        return r

    def sql(self, q, p=None):
        return self.cx.execute(q, p).fetchall()

    def close(self):
        self.cx.close()
