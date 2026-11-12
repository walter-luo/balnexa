"""Restore of a ``pg_dump --format=custom --data-only`` archive into a prepared target (UA V1.2 §9.3 step 9).

The target is bootstrapped (B001, B002, B003) and migrated by the runner to exactly the recorded migration versions before
anything is loaded. The load follows the target's **generated** preamble (``bnx.restore_preamble()``, 9016): the preamble
SQL refuses a target that holds any non-seeded row (``RESTORE_TARGET_NOT_EMPTY``) and truncates the seeded tables; the data
is loaded by ``bnx_migrator`` under ``SET ROLE bnx_definer`` with ``bnx.restore_mode = on`` in one transaction, the audit chain
in seq order (R-10); tables the preamble lists as never loaded are skipped; ``auth`` rows are loaded by ``bnx_auth``.
Post-checks: header facts recomputed by ``bnx_backup`` on the target, ``audit_verify() = 0`` and every journal re-asserted.
"""
import os
import subprocess

import psycopg

from . import pgtools


class RestoreError(Exception):
    pass


class Target:
    """connection strings of one restore target (same server; one database)"""
    def __init__(self, conninfo, db):
        self.conninfo, self.db = conninfo, db

    def dsn(self, user):
        return f"{self.conninfo} user={user} dbname={self.db}"


def _psql(dsn, sql, single=False):
    args = [pgtools.psql(), dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"] + (["-1"] if single else [])
    r = subprocess.run(args, input=sql, capture_output=True, text=True)
    if r.returncode:
        # only the primary message: DETAIL/CONTEXT lines can quote row values, which never leave the drill
        err = next((l for l in r.stderr.splitlines() if "ERROR:" in l), "psql failed")
        raise RestoreError("LOAD_FAILED: " + err.split("ERROR:", 1)[-1].strip()[:80])


def preamble(target):
    with psycopg.connect(target.dsn("bnx_migrator")) as cx:
        cx.execute("set role bnx_definer")
        pre = cx.execute("select bnx.restore_preamble()").fetchone()[0]
        cx.rollback()
    return pre


def split_sql(text, pre):
    """pg_restore SQL output -> (definer part, auth part): audit chain rows sorted by seq, never-load tables dropped"""
    lines, body, k = text.splitlines(), [], 0
    while k < len(lines):
        body.append(lines[k])
        if lines[k].startswith("COPY bnx_audit.audit_event "):
            blk = []
            k += 1
            while lines[k] != "\\.":
                blk.append(lines[k]); k += 1
            body += sorted(blk, key=lambda x: int(x.split("\t", 1)[0]))
            body.append(lines[k])
        k += 1
    main, auth, skip, cur = [], [], False, None
    never = tuple("COPY " + t + " " for t in pre["never_load"])
    for line in body:
        if line.startswith(never):
            skip = True; continue
        if skip:
            skip = line != "\\."; continue
        if line.startswith("COPY auth.") or line.startswith("SELECT pg_catalog.setval('auth."):
            auth.append(line); cur = auth if line.startswith("COPY") else None; continue
        (cur if cur is not None else main).append(line)
        if line == "\\.":
            cur = None
    return main, auth


def load_dump(target, dump_path, restore_major):
    pg_restore = pgtools.tool("pg_restore", restore_major)
    if not pg_restore:
        raise RestoreError(f"pg_restore {restore_major} not available")
    lst = subprocess.run([pg_restore, "--list", dump_path], capture_output=True, text=True)
    if lst.returncode:
        raise RestoreError("pg_restore --list failed")
    conv = subprocess.run([pg_restore, "--data-only", "-f", "-", dump_path], capture_output=True, text=True)
    if conv.returncode:
        raise RestoreError("pg_restore failed")
    pre = preamble(target)
    main, auth = split_sql(conv.stdout, pre)
    _psql(target.dsn("bnx_migrator"), "begin;\n" + pre["sql"] + "\n".join(main) + "\ncommit;\n")
    if auth:
        _psql(target.dsn("bnx_auth"), "\n".join(auth) + "\n", single=True)
    return {"pg_restore": pgtools.version(pg_restore),
            "list_entries": len([l for l in lst.stdout.splitlines() if l and not l.startswith(";")]), "truncated": len(pre["truncate"])}


def header_facts(dsn_backup, snapshot=None):
    with psycopg.connect(dsn_backup) as cx:
        cx.execute("begin isolation level repeatable read read only")
        if snapshot:
            cx.execute(f"set transaction snapshot '{snapshot}'")
        f = cx.execute("select bnx.bkp_header_facts()").fetchone()[0]
        cx.rollback()
    return f


def header_compare(dsn_backup, a, b):
    import json
    with psycopg.connect(dsn_backup) as cx:
        return cx.execute("select bnx.bkp_header_compare(%s::jsonb, %s::jsonb)", (json.dumps(a), json.dumps(b))).fetchone()[0]


def post_checks(target):
    with psycopg.connect(target.dsn("bnx_migrator")) as cx:
        cx.execute("set role bnx_definer")
        av = cx.execute("select bnx.audit_verify()").fetchone()[0]
        js = [r[0] for r in cx.execute("select id from bnx.journal_entry")]
        for j in js:
            cx.execute("select bnx.assert_journal_complete(%s)", (j,))
        cx.rollback()
    return {"audit_verify": av, "journals_asserted": len(js)}


def applied_migrations(target):
    with psycopg.connect(target.dsn("bnx_migrator")) as cx:
        return [r[0] for r in cx.execute("select version from bnx.schema_migrations order by version")]


class LocalProvisioner:
    """Isolated drill database on a PostgreSQL server the drill identity administers (local runs, tests, and the shape of
    the Neon drill branch of M0-E). Creates the database, runs the bootstrap files as the installer and the migration runner
    as bnx_migrator up to the recorded head; drops it afterwards."""
    def __init__(self, conninfo, admin_user, db_dir, prefix="bnx_drill_"):
        self.conninfo, self.admin, self.db_dir, self.prefix = conninfo, admin_user, os.path.abspath(db_dir), prefix

    def _admin(self):
        return psycopg.connect(f"{self.conninfo} user={self.admin} dbname=postgres", autocommit=True)

    def create(self, name, upto):
        if not name.startswith(self.prefix):
            raise RestoreError("drill target name")
        with self._admin() as cx:
            cx.execute(f'create database "{name}"')
        t = Target(self.conninfo, name)
        for f in ("B001_bootstrap.sql", "B002_bootstrap_s4.sql"):
            _psql(t.dsn(self.admin), open(os.path.join(self.db_dir, "bootstrap", f)).read(), single=True)
        cmd = ["python3", os.path.join(self.db_dir, "tools", "run_migrations.py"), "--dsn", t.dsn("bnx_migrator"),
               "--dir", os.path.join(self.db_dir, "migrations"), "--upto", upto]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode == 6 and "BOOTSTRAP_MISSING: B003" in r.stdout:      # documented installer step (harness.migrate)
            _psql(t.dsn(self.admin), open(os.path.join(self.db_dir, "bootstrap", "B003_audit_owner.sql")).read(), single=True)
            r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode:
            raise RestoreError("migration runner exit " + str(r.returncode) + ": " + r.stdout[-300:])
        return t

    def drop(self, name):
        if not name.startswith(self.prefix):
            raise RestoreError("drill target name")
        with self._admin() as cx:
            cx.execute(f'drop database if exists "{name}" with (force)')
            return cx.execute("select count(*) from pg_database where datname = %s", (name,)).fetchone()[0] == 0
