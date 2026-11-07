#!/usr/bin/env python3
"""S4 V1.2 work package CORE-1 tests (B002, run_migrations.py lanes, 9002-9004). Same conventions as run_g0.py:
runtime claims are exercised through the intended roles; the migrator under SET ROLE bnx_definer is used only for installer
steps and defence-in-depth probes; postgres only creates/drops test databases and plays the installer for B001/B002.
Usage: run_s4_core1.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, csv, json, os, re, shutil, subprocess, sys, tempfile, time, traceback, uuid
import psycopg
import harness as h
import fixture as F

RESULTS, TESTS = [], []
ROOT = h.ROOT
MIG = os.path.join(ROOT, "db/migrations")
DIGEST = "a" * 64


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


def expect_err(fn, code, *a, **kw):
    try:
        fn(*a, **kw)
    except psycopg.Error as e:
        m = (e.diag.message_primary or str(e))
        if code not in m:
            raise Fail(f"expected {code}, got {type(e).__name__}: {m}")
        return m
    raise Fail(f"expected {code}, call succeeded")


def r1_dir():
    """The frozen R1 chain only (0002..0109 + 9001): what an installed R1 household has applied."""
    d = tempfile.mkdtemp()
    for f in os.listdir(MIG):
        if re.match(r"^\d{4}_", f) and f[:4] <= "9001":
            shutil.copy(os.path.join(MIG, f), d)
    return d


def migrator(server, db):
    cx = psycopg.connect(h.dsn(server, "bnx_migrator", db))
    cx.execute("set role bnx_definer")
    return cx


def installer_sql(server, db, sql, params=None):
    with migrator(server, db) as cx:
        r = cx.execute(sql, params).fetchall()
        cx.commit()
        return r


MODULES = {"Canada": "YES", "International": "NO", "CRA": "YES"}
POLICY = {"reporting_currency": "CAD", "declared_by": "installer"}


def v2_household(server, db=None, project="synthetic-family-01"):
    """Fresh S4 install through install_household_v2, then the R1 fixture steps (members, account, categories, openings)."""
    db = db or "bnx_" + uuid.uuid4().hex[:8]
    h.bootstrap(server, db); h.migrate(server, db)
    uid = str(uuid.uuid4())
    installer_sql(server, db, "select bnx.install_household_v2('Owner A', %s, 'g-owner', %s, %s, %s::jsonb, %s::jsonb)",
                  (F.ISS, project, uid, json.dumps(MODULES), json.dumps(POLICY)))
    H = object.__new__(F.Household)
    H.server, H.db = server, db
    H.app, H.authn, H.worker = h.Role(server, db, "bnx_app"), h.Role(server, db, "bnx_authn"), h.Role(server, db, "bnx_worker")
    H.owner = H.login("g-owner")
    H.owner_id = str(installer_sql(server, db, "select id from bnx.member where role = 'owner'")[0][0])
    H.member_id = H.cmd(H.owner, "invite_member", display_name="Member B", role="member", google_sub="g-member")["member_id"]
    H.member = H.login("g-member")
    H.project, H.uid = project, uid
    return H


def env(H, modules=None):
    return json.dumps({"project_id": H.project, "instance_uid": H.uid, "modules": modules or MODULES})


FP_SQL = """select encode(sha256(convert_to(concat_ws(E'\\n',
    (select version::text from bnx.ledger_state),
    (select string_agg(concat_ws('|', je.id, je.entry_no, je.economic_type, je.transaction_date, je.posting_date,
                                 je.description, je.original_amount, je.original_currency), E'\\n' order by je.id) from bnx.journal_entry je),
    (select string_agg(concat_ws('|', jl.id, jl.journal_id, jl.ledger_account_id, jl.currency, jl.amount), E'\\n' order by jl.id)
       from bnx.journal_line jl)), 'UTF8')), 'hex')"""


# ------------------------------------------------------------------------------------------------ bootstrap and runner
@test("AT-MIG-09", "S4B-F10, ADO-003; UA §6.1-6.2")
def t_b002_and_unregistered(server, ev):
    db = "bnx_s4mig09"
    h.bootstrap(server, db)
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql")        # second run: idempotent
    h.migrate(server, db)
    with migrator(server, db) as cx:
        n = cx.execute("select count(*) from bnx.schema_bootstrap where version = 'B002'").fetchone()[0]
        roles = sorted(r[0] for r in cx.execute("select rolname from pg_roles where rolname like 'bnx\\_%'"))
        nologin = cx.execute("select array_agg(rolname order by rolname) from pg_roles where rolname in ('bnx_stager','bnx_fed_reader') "
                             "and not rolcanlogin").fetchone()[0]
        audit = cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]
    check(n == 1 and len(roles) == 9 and nologin == ["bnx_fed_reader", "bnx_stager"] and audit == [], f"{n} {roles} {nologin} {audit}")
    # negatives: an unregistered schema owned by bnx_definer, and one a runtime role can use
    with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as cx:
        cx.execute("create schema rogue authorization bnx_definer")
        cx.execute("create schema rogue2; grant usage on schema rogue2 to bnx_app")
        cx.execute("create role bnx_extra nologin")
    with migrator(server, db) as cx:
        v = cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]
    rules = sorted({(x["rule"], x.get("schema") or x.get("extra")) for x in v})
    check(("NEW_SCHEMA_UNREGISTERED", "rogue") in rules and ("NEW_SCHEMA_UNREGISTERED", "rogue2") in rules
          and ("ROLE_INVENTORY", "bnx_extra") in rules, str(rules))
    d = tempfile.mkdtemp()
    for f in os.listdir(MIG):
        shutil.copy(os.path.join(MIG, f), d)
    open(os.path.join(d, "9101_test_noop.sql"), "w").write("set role bnx_definer;\nselect 1;\n")
    r = h.migrate(server, db, check=False, mdir=d, log=os.path.join(ev, "AT-MIG-09_violation_blocks_runner.log"))
    check(r.returncode == 6 and "privilege audit" in r.stdout, r.stdout[-600:])
    with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as cx:
        cx.execute("drop schema rogue; drop schema rogue2; drop role bnx_extra")
    return (f"B002 applied twice -> 1 schema_bootstrap row; 9 roles (bnx_fed_reader, bnx_stager NOLOGIN); 0 violations; "
            f"unregistered schemas and extra role detected {rules}; next migration refused while violations exist (exit 6)")


@test("AT-MIG-11", "S4B-F01/F17; UA §6.2")
def t_bootstrap_missing(server, ev):
    # (a) fresh database without B002: the runner refuses before applying anything (all-or-nothing)
    db0 = "bnx_s4mig11a"
    h.bootstrap(server, db0, b002=False)
    r0 = h.migrate(server, db0, check=False, log=os.path.join(ev, "AT-MIG-11_fresh_no_b002.log"))
    with migrator(server, db0) as cx:
        n0 = cx.execute("select count(*) from bnx.schema_migrations").fetchone()[0]
    check(r0.returncode == 6 and "BOOTSTRAP_MISSING" in r0.stdout and "apply " not in r0.stdout and n0 == 0, r0.stdout[-600:])
    # (b) database at R1 head (an installed R1 household) without B002: 9002 refused, head stays 9001
    db = "bnx_s4mig11"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=r1_dir())
    r = h.migrate(server, db, check=False, log=os.path.join(ev, "AT-MIG-11_no_b002.log"))
    check(r.returncode == 6 and "BOOTSTRAP_MISSING" in r.stdout and "apply " not in r.stdout, r.stdout[-800:])
    with migrator(server, db) as cx:
        head = cx.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
    check(head == "9001", f"head {head}")
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql")
    r = h.migrate(server, db, log=os.path.join(ev, "AT-MIG-11_after_b002.log"))
    check("apply 9002" in r.stdout and "privilege_violations=0" in r.stdout, r.stdout[-400:])
    # lane rules: removed applied extension file -> exit 4; tampered extension file -> exit 5
    d = tempfile.mkdtemp()
    for f in os.listdir(MIG):
        shutil.copy(os.path.join(MIG, f), d)
    os.remove(os.path.join(d, [f for f in os.listdir(d) if f.startswith("9003")][0]))
    r4 = h.migrate(server, db, check=False, mdir=d)
    shutil.copy(os.path.join(MIG, [f for f in os.listdir(MIG) if f.startswith("9003")][0]), d)
    with open(os.path.join(d, [f for f in os.listdir(d) if f.startswith("9004")][0]), "a") as fh:
        fh.write("\n-- tampered\n")
    r5 = h.migrate(server, db, check=False, mdir=d)
    check(r4.returncode == 4 and "extension lane" in r4.stdout and r5.returncode == 5, r4.stdout[-300:] + r5.stdout[-300:])
    # a new core-lane file after extension migrations is applied (lane independence; the R1 prefix rule refused this)
    d2 = tempfile.mkdtemp()
    for f in os.listdir(MIG):
        shutil.copy(os.path.join(MIG, f), d2)
    open(os.path.join(d2, "0110_test_core_after_extension.sql"), "w").write(
        "set role bnx_definer;\ncreate table bnx.t_core_lane(id int primary key);\n")
    r6 = h.migrate(server, db, check=False, mdir=d2, log=os.path.join(ev, "AT-MIG-11_core_after_ext.log"))
    check(r6.returncode == 0 and "apply 0110_test_core_after_extension.sql" in r6.stdout, r6.stdout[-500:])
    return ("without B002: fresh database -> exit 6 BOOTSTRAP_MISSING with 0 migrations applied; R1-head database -> exit 6, "
            "head stays 9001; after B002: 9002..9004 applied, "
            "0 violations; removed applied 9003 -> exit 4 (extension lane); tampered applied 9004 -> exit 5; "
            "core file 0110 after 9004 -> applied (R1 prefix rule would refuse with exit 4)")


DOC_OPTS = "-c createrole_self_grant=set,inherit"   # documented installer procedure (B002 header; F-C1-01 option a)


def nonsuper_install(server, db, inst, opts):
    """Fresh cluster roles; database owned by a non-superuser CREATEROLE installer; B001+B002 run by it with PGOPTIONS."""
    h.drop_all(server)          # roles are cluster-wide: the installer must create them itself
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute(f"drop database if exists {db} with (force)")
        if not cx.execute("select 1 from pg_roles where rolname = %s", (inst,)).fetchone():
            cx.execute(f"create role {inst} login createrole")
        cx.execute(f"create database {db} owner {inst}")
    res = {}
    for name in ("B001_bootstrap.sql", "B002_bootstrap_s4.sql"):
        r = subprocess.run([h.PSQL, h.dsn(server, inst, db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1", "-f",
                            os.path.join(ROOT, "db/bootstrap", name)], capture_output=True, text=True, env={**os.environ, "PGOPTIONS": opts})
        res[name] = {"exit": r.returncode, "error": (r.stderr.strip().splitlines() or [""])[-1][:160]}
        if r.returncode:
            break
    return res


def installer_memberships(server, db, inst):
    with psycopg.connect(h.dsn(server, inst, db)) as cx:
        return cx.execute("select g.rolname, am.admin_option, am.inherit_option, am.set_option, pg_get_userbyid(am.grantor) "
                          "from pg_auth_members am join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member "
                          "where u.rolname = %s order by 1", (inst,)).fetchall()


@test("AT-MIG-11b", "S4B-F17, F-C1-01 option a (non-superuser CREATEROLE installer; Neon semantics remain M0-C-06)")
def t_nonsuper_installer(server, ev):
    """Documented procedure: the installer runs unchanged B001 and B002 with createrole_self_grant=set,inherit; B002 removes
    its SET/INHERIT self-grants; amended 0108 and 9002 accept only the remaining ADMIN-only membership."""
    inst, db = "installer_s4", "bnx_s4mig11b"
    out = {}
    # negative evidence: without the documented option B001 cannot run as a non-superuser installer
    for variant, opts in (("default", ""), ("createrole_self_grant=set", "-c createrole_self_grant=set")):
        out[variant] = nonsuper_install(server, db, inst, opts)
    check(out["default"]["B001_bootstrap.sql"]["exit"] != 0 and out["createrole_self_grant=set"]["B001_bootstrap.sql"]["exit"] != 0,
          f"expected B001 to fail without the documented option: {out}")
    # documented procedure
    res = nonsuper_install(server, db, inst, DOC_OPTS)
    check(all(x["exit"] == 0 for x in res.values()) and len(res) == 2, f"documented bootstrap: {res}")
    mem = installer_memberships(server, db, inst)
    m = h.migrate(server, db, check=False, log=os.path.join(ev, "AT-MIG-11b_migrate_documented.log"))
    with migrator(server, db) as cx:
        v = cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]
    check(m.returncode == 0 and "privilege_violations=0" in m.stdout and v == [], f"migrate exit {m.returncode}: {m.stdout[-600:]} {v}")
    check(len(mem) == 9 and all(x[1] and not x[2] and not x[3] for x in mem), f"installer memberships must be ADMIN-only: {mem}")
    res["memberships"] = [list(x) for x in mem]
    res["migrate"] = m.stdout.strip().splitlines()[-1]
    # the installer can still perform its later steps (role LOGIN switches need ADMIN) ...
    with psycopg.connect(h.dsn(server, inst, db), autocommit=True) as cx:
        cx.execute("alter role bnx_stager login"); cx.execute("alter role bnx_stager nologin")
    # ... but a membership with SET (an installer that can act as bnx_definer) is reported
    with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as cx:
        cx.execute(f"grant bnx_definer to {inst} with inherit false, set true granted by {inst}")
    with migrator(server, db) as cx:
        v2 = cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]
    check(any(x["rule"] == "INSTALLER_MEMBERSHIP" and x["group"] == "bnx_definer" for x in v2), f"SET membership not reported: {v2}")
    out["documented (createrole_self_grant=set,inherit)"] = res
    json.dump(out, open(os.path.join(ev, "AT-MIG-11b_nonsuperuser_installer.json"), "w"), indent=1, default=str)
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute(f"drop database if exists {db} with (force)")
    h.drop_all(server)              # later tests bootstrap with the postgres installer
    return (f"without the option B001 fails ({out['default']['B001_bootstrap.sql']['error'][-60:]}); documented procedure: "
            f"B001+B002 by non-superuser '{inst}', 0002..9004 applied incl. amended 0108, 0 violations, 9 ADMIN-only installer "
            f"memberships (no SET/INHERIT); installer can still toggle LOGIN; an added SET membership is reported (INSTALLER_MEMBERSHIP)")


@test("AT-MIG-11c", "F-C1-01 option a (consequence: R1 0108 checksum changed)")
def t_original_0108(server, ev):
    """A database built with the R1-original 0108 is refused by the amended chain (checksum mismatch, exit 5) before
    anything is applied. Documented consequence of option (a); no real R1 database exists."""
    db = "bnx_s4mig11c"
    d = r1_dir()
    shutil.copy(os.path.join(ROOT, "db/history/r1/0108_grants_and_privilege_audit.R1-original.sql"),
                os.path.join(d, "0108_grants_and_privilege_audit.sql"))
    h.bootstrap(server, db)
    h.migrate(server, db, mdir=d)
    r = h.migrate(server, db, check=False, log=os.path.join(ev, "AT-MIG-11c_original_0108.log"))
    with migrator(server, db) as cx:
        head = cx.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
    check(r.returncode == 5 and "0108_grants_and_privilege_audit.sql" in r.stdout and "apply " not in r.stdout and head == "9001", r.stdout[-500:])
    return "database built with R1-original 0108 -> amended chain refuses with exit 5 (migrations are immutable), nothing applied, head 9001"


# ------------------------------------------------------------------------------------------------ upgrade of an R1 household
@test("AT-MIG-10", "S4B-F01/F18; UA §4.2-4.3, §6.2")
def t_upgrade_r1_head(server, ev):
    db = "bnx_s4mig10"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=r1_dir(), log=os.path.join(ev, "AT-MIG-10_r1_head.log"))
    H = F.Household(server, db)                                    # R1 install_household + R1 fixture data
    H.expense(H.owner, "12.34"); H.expense(H.member, "5.00", date="2026-03-01")
    bal_pre = H.q(H.owner, "balances", as_of="2026-12-31")
    with migrator(server, db) as cx:
        fp_pre = cx.execute(FP_SQL).fetchone()[0]
        audit_pre = cx.execute("select count(*) from bnx.audit_event").fetchone()[0]
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql")
    r = h.migrate(server, db, log=os.path.join(ev, "AT-MIG-10_upgrade.log"))
    check("apply 9002" in r.stdout and "apply 9004" in r.stdout and "privilege_violations=0" in r.stdout, r.stdout[-400:])
    st0 = H.q(H.owner, "config_status")
    check(st0["active"] is None and st0["identity"] is None, f"before adoption: {st0}")
    uid = str(uuid.uuid4())
    cv = installer_sql(server, db, "select bnx.adopt_existing_household('synthetic-upgrade-01', %s, %s::jsonb, %s::jsonb)",
                       (uid, json.dumps(MODULES), json.dumps(POLICY)))[0][0]
    st1 = H.q(H.owner, "config_status")
    check(st1["active"] is None and st1["pending"] == [{"config_version": cv, "state": "PENDING_DEPLOY"}], f"after adoption: {st1}")
    installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                  (cv, DIGEST, json.dumps({"project_id": "synthetic-upgrade-01", "instance_uid": uid, "modules": MODULES})))
    st2 = H.q(H.owner, "config_status")
    # 9006/9007: the R1 free-text institution is PENDING_VERIFICATION and the account's region UNKNOWN (fail closed) until the
    # Owner verifies the institution; balances are hidden meanwhile (scope warning), never altered
    hidden = H.q(H.owner, "balances", as_of="2026-12-31")
    pend = installer_sql(server, db, "select id from bnx.institution where status = 'PENDING_VERIFICATION'")[0][0]
    H.cmd(H.owner, "verify_institution", institution_id=str(pend), evidence_ref="synthetic-statement-header", jurisdiction="CA")
    with migrator(server, db) as cx:
        fp_post = cx.execute(FP_SQL).fetchone()[0]
        fp_fn = cx.execute("select bnx.ledger_fingerprint()").fetchone()[0]
        ev_row = cx.execute("select kind, pre_fingerprint = post_fingerprint, pre_fingerprint from bnx.release_install_event").fetchall()
        av = cx.execute("select bnx.audit_verify()").fetchone()[0]
        audit_post = cx.execute("select count(*) from bnx.audit_event").fetchone()[0]
    bal_post = H.q(H.owner, "balances", as_of="2026-12-31")
    check(st2["active"]["config_version"] == cv and st2["active"]["flags"] == MODULES and st2["active"]["config_sha256"] == DIGEST,
          f"after activation: {st2}")
    check(fp_pre == fp_post == fp_fn and ev_row == [("ADOPT", True, fp_pre)], f"fingerprints {fp_pre} {fp_post} {fp_fn} {ev_row}")
    bal_pre_rows = {k: v for k, v in bal_pre.items() if k != "scope_warnings"} if "scope_warnings" not in bal_pre else bal_pre
    bal_post_rows = {k: v for k, v in bal_post.items() if k != "scope_warnings"}
    check(hidden["balances"] == [] and hidden["scope_warnings"] == ["EXCLUDED_SCOPE:UNKNOWN"], f"before verification: {hidden}")
    check(bal_pre_rows == bal_post_rows and bal_post["scope_warnings"] == [] and av == 0 and audit_post == audit_pre + 3,
          f"balances equal={bal_pre_rows == bal_post_rows} audit={av} {audit_pre}->{audit_post}")
    H.expense(H.owner, "1.00", date="2026-04-01")                 # R1 posting path still works after the upgrade
    H.close()
    json.dump({"fingerprint": fp_pre, "config_status": st2}, open(os.path.join(ev, "AT-MIG-10_result.json"), "w"), indent=1, default=str)
    return (f"R1 head (15 migrations) with data -> B002 -> 9002..9004 (0 violations) -> adopt (PENDING_DEPLOY, not active) -> "
            f"install_activate_config -> ACTIVE v{cv}; ledger fingerprint pre = post = bnx.ledger_fingerprint() ({fp_pre[:12]}…); "
            f"account fail-closed (region UNKNOWN, balances hidden with EXCLUDED_SCOPE:UNKNOWN) until the Owner verifies the R1 free-text "
            f"institution; then q_balances identical to R1; audit chain intact (+2 installer events, +1 verification); R1 posting works afterwards")


# ------------------------------------------------------------------------------------------------ identity and lifecycle
@test("AT-ISO-03", "CROSS-04; UA §4.2-4.3")
def t_identity(server, ev):
    H = v2_household(server, "bnx_s4iso03")
    with migrator(server, H.db) as cx:
        idt = cx.execute("select project_id, product_id, origin from bnx.instance_identity").fetchone()
    check(idt == ("synthetic-family-01", "balnexa", "install_v2"), str(idt))
    msgs = [
        expect_err(installer_sql, "ALREADY_INSTALLED", H.server, H.db,
                   "select bnx.install_household_v2('X', %s, 'g-x', 'p2', %s, %s::jsonb, %s::jsonb)",
                   (F.ISS, str(uuid.uuid4()), json.dumps(MODULES), json.dumps(POLICY))),
        expect_err(installer_sql, "ALREADY_INSTALLED", H.server, H.db, "select bnx.install_household('X', %s, 'g-x')", (F.ISS,)),
        expect_err(installer_sql, "ALREADY_ADOPTED", H.server, H.db,
                   "select bnx.adopt_existing_household('p3', %s, %s::jsonb, %s::jsonb)", (str(uuid.uuid4()), json.dumps(MODULES), json.dumps(POLICY))),
        expect_err(installer_sql, "APPEND_ONLY", H.server, H.db, "update bnx.instance_identity set project_id = 'other'"),
    ]
    db2 = "bnx_s4iso03b"
    h.bootstrap(server, db2); h.migrate(server, db2)
    msgs.append(expect_err(installer_sql, "NOT_ADOPTABLE", server, db2,
                           "select bnx.adopt_existing_household('p4', %s, %s::jsonb, %s::jsonb)", (str(uuid.uuid4()), json.dumps(MODULES), json.dumps(POLICY))))
    msgs.append(expect_err(installer_sql, "instance_identity_check", server, db2,
                           "select bnx.install_household_v2('X', %s, 'g-x', 'balnexa', %s, %s::jsonb, %s::jsonb)",
                           (F.ISS, str(uuid.uuid4()), json.dumps(MODULES), json.dumps(POLICY))))
    msgs.append(expect_err(installer_sql, "VALIDATION_FAILED", server, db2,
                           "select bnx.install_household_v2('X', %s, 'g-x', 'p5', %s, %s::jsonb, %s::jsonb)",
                           (F.ISS, str(uuid.uuid4()), json.dumps({"Canada": "YES", "CRA": "NO"}), json.dumps(POLICY))))
    # installer functions are not executable by runtime roles
    denied = []
    for role in ("bnx_app", "bnx_worker", "bnx_authn", "bnx_stager", "bnx_fed_reader", "bnx_backup"):
        if role in ("bnx_stager", "bnx_fed_reader"):
            continue                                                 # NOLOGIN: cannot connect at all (checked in AT-MIG-09)
        with psycopg.connect(h.dsn(server, role, H.db), autocommit=True) as cx:
            for fn in ("bnx.install_household_v2('X','i','s','p',gen_random_uuid(),'{}','{}')",
                       "bnx.adopt_existing_household('p',gen_random_uuid(),'{}','{}')", "bnx.install_activate_config(1,'x','{}')"):
                try:
                    cx.execute(f"select {fn}"); raise Fail(f"{role} executed {fn}")
                except psycopg.errors.InsufficientPrivilege:
                    denied.append(role)
    H.close()
    return (f"identity written by install_household_v2 {idt}; refused: {[m for m in msgs]}; "
            f"{len(denied)} runtime-role calls to installer functions denied")


@test("AT-CFG-14", "CROSS-05; UA §4.3; AE §5")
def t_lifecycle(server, ev):
    H = v2_household(server, "bnx_s4cfg14")
    st = H.q(H.owner, "config_status")
    check(st["active"] is None and st["pending"] == [{"config_version": 1, "state": "PENDING_DEPLOY"}], f"fresh: {st}")
    # activation binding checks (B1, B2 format, B8) and installer-only execution
    r = [expect_err(installer_sql, "BNX_BINDING_MISMATCH", H.server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)",
                    (DIGEST, json.dumps({"project_id": "wrong", "instance_uid": H.uid, "modules": MODULES}))),
         expect_err(installer_sql, "BNX_FLAG_BINDING_MISMATCH", H.server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)",
                    (DIGEST, env(H, {**MODULES, "CRA": "NO"}))),
         expect_err(installer_sql, "VALIDATION_FAILED", H.server, H.db, "select bnx.install_activate_config(1, 'nothex', %s::jsonb)", (env(H),))]
    try:
        H.app.cx.execute("select bnx.install_activate_config(1, %s, %s::jsonb)", (DIGEST, env(H))); raise Fail("bnx_app activated")
    except psycopg.errors.InsufficientPrivilege:
        r.append("bnx_app: permission denied")
    installer_sql(H.server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)", (DIGEST, env(H)))
    check(H.q(H.owner, "config_status")["active"]["config_version"] == 1, "v1 active")
    # Owner draft -> acceptance -> PENDING_DEPLOY (never ACTIVE) -> installer activation supersedes v1
    d2 = "b" * 64
    mods2 = {"Canada": "YES", "International": "YES", "CRA": "YES"}
    rv = H.cmd(H.owner, "prepare_config_draft", config_sha256=d2, schema="ai-entry/2.1", modules=mods2, deployment_mode="cloud")
    check(rv["state"] == "PENDING_OWNER_ACCEPTANCE" and rv["config_version"] == 2, str(rv))
    r.append(expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "accept_instance_config", config_version=2, config_sha256=d2, modules=mods2))
    r.append(expect_err(H.cmd, "CONFIG_DIGEST_MISMATCH", H.owner, "accept_instance_config", config_version=2, config_sha256="c" * 64, modules=mods2))
    r.append(expect_err(H.cmd, "CONFIG_DIGEST_MISMATCH", H.owner, "accept_instance_config", config_version=2, config_sha256=d2, modules=MODULES))
    r.append(expect_err(installer_sql, "CONFIG_STATE", H.server, H.db, "select bnx.install_activate_config(2, %s, %s::jsonb)", (d2, env(H, mods2))))
    # T3 freshness: a session older than 15 minutes is refused (session age moved back by the installer probe)
    stale = H.login("g-owner")
    installer_sql(H.server, H.db, "update bnx.member_session set created_at = now() - interval '20 minutes' where token_sha256 = sha256(convert_to(%s, 'UTF8')) returning 1", (stale["secret"],))
    r.append(expect_err(H.cmd, "REAUTH_REQUIRED", stale, "accept_instance_config", config_version=2, config_sha256=d2, modules=mods2))
    acc = H.cmd(H.owner, "accept_instance_config", config_version=2, config_sha256=d2, modules=mods2)
    st = H.q(H.owner, "config_status")
    check(acc["state"] == "PENDING_DEPLOY" and st["active"]["config_version"] == 1
          and st["pending"] == [{"config_version": 2, "state": "PENDING_DEPLOY"}], f"acceptance must not activate: {acc} {st}")
    r.append(expect_err(H.cmd, "CONFIG_STATE", H.owner, "accept_instance_config", config_version=2, config_sha256=d2, modules=mods2))
    r.append(expect_err(installer_sql, "BNX_BINDING_MISMATCH", H.server, H.db, "select bnx.install_activate_config(2, %s, %s::jsonb)", (DIGEST, env(H, mods2))))
    installer_sql(H.server, H.db, "select bnx.install_activate_config(2, %s, %s::jsonb)", (d2, env(H, mods2)))
    st = H.q(H.owner, "config_status")
    with migrator(H.server, H.db) as cx:
        states = cx.execute("select config_version, state from bnx.config_version_anchor order by 1").fetchall()
        events = cx.execute("select config_version, from_state, to_state from bnx.config_state_event order by config_version, seq").fetchall()
    check(st["active"]["config_version"] == 2 and st["active"]["flags"] == mods2 and states == [(1, "SUPERSEDED"), (2, "ACTIVE")],
          f"{st} {states}")
    # projection guard and append-only flags (defence-in-depth probes as definer)
    r.append(expect_err(installer_sql, "CONFIG_STATE_PROJECTION", H.server, H.db, "update bnx.config_version_anchor set state = 'REJECTED' where config_version = 2"))
    r.append(expect_err(installer_sql, "APPEND_ONLY", H.server, H.db, "update bnx.instance_module_flag set value = 'NO'"))
    r.append(expect_err(installer_sql, "CONFIG_FLAGS_INCOMPLETE", H.server, H.db,
             "insert into bnx.config_version_anchor(config_version, schema, modules, state, origin, installer_policy) "
             "values (9, 's', '{}', 'PENDING_DEPLOY', 'adopt', '{}') returning 1"))
    # reject path
    rv3 = H.cmd(H.owner, "prepare_config_draft", config_sha256="d" * 64, schema="ai-entry/2.1", modules=MODULES)
    rj = H.cmd(H.owner, "accept_instance_config", config_version=rv3["config_version"], decision="reject", reason="test")
    check(rj["state"] == "REJECTED", str(rj))
    H.close()
    json.dump({"states": states, "events": events}, open(os.path.join(ev, "AT-CFG-14_lifecycle.json"), "w"), indent=1)
    return (f"NONE->PENDING_DEPLOY (install) -> ACTIVE (installer); draft v2 PENDING_OWNER_ACCEPTANCE -> accepted -> PENDING_DEPLOY "
            f"while v1 stays ACTIVE -> installer activation -> v2 ACTIVE, v1 SUPERSEDED; refusals: {r}; reject path -> REJECTED; "
            f"{len(events)} state events")


@test("AT-CFG-15", "UA §4.3 (q_health, q_whoami)")
def t_health_whoami(server, ev):
    H = v2_household(server, "bnx_s4cfg15")
    hl = H.app.call("q_health", None, {})
    who = H.q(H.member, "whoami")
    installer_sql(H.server, H.db, "select bnx.install_activate_config(1, %s, %s::jsonb)", (DIGEST, env(H)))
    hl2 = H.app.call("q_health", None, {})
    r = expect_err(H.app.call, "UNAUTHENTICATED", "q_whoami", {"kind": "session", "secret": "x" * 40}, {})
    H.close()
    check(hl["status"] == "unconfigured" and hl2["status"] == "ok" and set(hl) == {"status", "schema_head", "identity_present"}
          and who["role"] == "member" and who["preference"] == {}, f"{hl} {hl2} {who}")
    return f"q_health without credential: {hl} -> {hl2['status']} after activation (no identity values); q_whoami: role={who['role']}; forged session -> {r}"


# ------------------------------------------------------------------------------------------------ constraint replacements
@test("AT-PLAN-04-DB", "CROSS-03; UA §5.5.2 (database CHECK part; API/PWA part is 9010)")
def t_plan_kinds(server, ev):
    db = "bnx_s4plan04"
    h.bootstrap(server, db); h.migrate(server, db)
    ok, bad = [], []
    with migrator(server, db) as cx:
        for kind in ("import", "onboarding_scope", "reclassification", "account_merge_repost", "ai_draft", "handoff", "onboarding",
                     "member_draft", "migration_replay", "manual"):
            try:
                with cx.transaction():
                    cx.execute("insert into bnx.posting_plan(id, kind, scope, item_count, control_totals, plan_hash, state) "
                               "values (gen_random_uuid(), %s, '{}', 0, '{}', '\\x00', 'draft')", (kind,))
                    raise RuntimeError("rollback")
            except RuntimeError:
                ok.append(kind)
            except psycopg.errors.CheckViolation:
                bad.append(kind)
        cons = cx.execute("select conname, convalidated from pg_constraint where conrelid = 'bnx.posting_plan'::regclass and contype = 'c'").fetchall()
    check(bad == ["manual"] and len(ok) == 9 and ("posting_plan_kind_v2", True) in cons and len([c for c in cons if 'kind' in c[0]]) == 1,
          f"ok={ok} bad={bad} {cons}")
    return f"CHECK posting_plan_kind_v2 (validated, old CHECK dropped) admits {ok}; refuses {bad}"


@test("AT-EV-01-DB", "S4B-F14; UA §5.9 (9004 part: storage_kind, r2_key relaxation, write-once)")
def t_evidence_storage(server, ev):
    db = "bnx_s4ev01"
    h.bootstrap(server, db); h.migrate(server, db)
    out = []
    with migrator(server, db) as cx:
        a = cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state, storage_kind) "
                       "values (gen_random_uuid(), null, 10, 'unverified', 'drive_processed') returning id").fetchone()[0]
        b = cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state) "
                       "values (gen_random_uuid(), 'orig/x', 10, 'unverified') returning id").fetchone()[0]
        cx.commit()
        for sql, code in (("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state, storage_kind) values (gen_random_uuid(), null, 1, 'unverified', 'r2')", "evidence_object_r2_key_ck"),
                          ("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state, storage_kind) values (gen_random_uuid(), 'k2', 1, 'unverified', 'drive_processed')", "evidence_object_r2_key_ck"),
                          ("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state, storage_kind) values (gen_random_uuid(), null, 1, 'unverified', 'nas')", "evidence_object_storage_kind_ck"),
                          (f"update bnx.evidence_object set storage_kind = 'pending', r2_key = null where id = '{b}'", "WRITE_ONCE"),
                          (f"update bnx.evidence_object set r2_key = 'orig/y' where id = '{b}'", "WRITE_ONCE"),
                          (f"update bnx.evidence_object set r2_key = null where id = '{b}'", "WRITE_ONCE")):
            try:
                cx.execute(sql); cx.rollback(); raise Fail("accepted: " + sql)
            except psycopg.Error as e:
                cx.rollback(); cx.execute("set role bnx_definer")
                check(code in str(e), f"{sql}: {e}"); out.append(code)
        cx.execute(f"update bnx.evidence_object set storage_kind = 'r2', r2_key = 'orig/a' where id = '{a}'")
        cx.commit(); cx.execute("set role bnx_definer")
        try:
            cx.execute(f"update bnx.evidence_object set storage_kind = 'drive_processed', r2_key = null where id = '{a}'"); raise Fail("moved back")
        except psycopg.Error as e:
            check("WRITE_ONCE" in str(e), str(e)); out.append("WRITE_ONCE (r2 -> drive_processed)")
    return f"drive_processed without r2_key accepted; drive_processed -> r2 with key accepted; refused: {out}"


@test("AT-SET-01", "OBJ-225; UA §5.1 (cmd_set_household_setting per-key validation)")
def t_settings(server, ev):
    H = v2_household(server, "bnx_s4set01")
    good = [("plan_chunk_size", 200), ("coverage_alert_hours", 48), ("retention_daily", 7), ("retention_weekly", 4),
            ("retention_monthly", 12), ("data_class", "synthetic"), ("authorization_ref", "S6-synthetic-only"),
            ("require_dual_copy_before_approval", False)]
    for k, v in good:
        H.cmd(H.owner, "set_household_setting", setting=k, value=v)
    bad = [("plan_chunk_size", 0), ("plan_chunk_size", 2.5), ("coverage_alert_hours", "48"), ("data_class", "secret"),
           ("retention_daily", 0), ("unknown_key", 1), ("require_dual_copy_before_approval", "yes")]
    refused = [expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_household_setting", setting=k, value=v) and k for k, v in bad]
    r = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_household_setting", setting="plan_chunk_size", value=100)
    with migrator(H.server, H.db) as cx:
        rows = dict(cx.execute("select key, value from bnx.household_setting").fetchall())
    H.close()
    check(len(rows) == len(good) and rows["plan_chunk_size"] == 200, str(rows))
    return f"{len(good)} keys accepted with per-key validation; {len(refused)} invalid values/keys refused; member -> {r}"


# AT-FLG-10 is implemented in run_s4_core2.py (9007).


# ------------------------------------------------------------------------------------------------ inventory
KINDS = {"function", "table", "trigger", "schema", "role", "view", "type", "sequence", "extension"}
IMPLEMENTED = {"—", "", "B002", "9002", "9003", "9004", "9005", "9006", "9007", "9008", "9009", "9010"}
# objects created by this increment that the V1.2 disposition does not list (to be added as OBJ rows; see implementation notes)
HELPERS_NOT_IN_DISPOSITION = {
    "bnx.audit_canonical_v2",
    "bnx.audit_head",
    "bnx.brand_issuer_at",
    "bnx.calling_function",
    "bnx.check_constraint_of",
    "bnx.config_create",
    "bnx.config_modules_valid",
    "bnx.config_transition",
    "bnx.economic_type_check",
    "bnx.economic_type_violation",
    "bnx.envelope_value",
    "bnx.financial_policy_current",
    "bnx.financial_policy_from_installer",
    "bnx.flag_enforcement_matrix",
    "bnx.flag_enforcement_point",
    "bnx.function_scope",
    "bnx.host_profile_redirect",
    "bnx.institution_code_for",
    "bnx.institution_eligible",
    "bnx.ledger_fingerprint",
    "bnx.line_kind",
    "bnx.normalize_institution_name",
    "bnx.oauth_issue",
    "bnx.oauth_revoke_connection",
    "bnx.plan_item_type",
    "bnx.pol_active_config",
    "bnx.pol_enabled_acs",
    "bnx.pol_excluded_scopes",
    "bnx.pol_flag",
    "bnx.pol_region_flag",
    "bnx.pol_require_module_for_account",
    "bnx.pol_require_region",
    "bnx.posting_batch_chunk",
    "bnx.q_registry_review",
    "bnx.region_of_jurisdiction",
    "bnx.require_t3_fresh",
    "bnx.schema_registry",
    "bnx.trg_account_institution_eligible",
    "bnx.trg_account_institution_guard",
    "bnx.trg_account_institution_projection",
    "bnx.trg_audit_chain_version",
    "bnx.trg_config_anchor_projection",
    "bnx.trg_config_flags_complete",
    "bnx.trg_economic_type_rule",
    "bnx.trg_scope_flag",
    # 9010
    "bnx.cmd_handoff_mark_sent",
    "bnx.cmd_handoff_prepare",
    "bnx.cmd_notification_read",
    "bnx.cmd_register_index_source",
    "bnx.draft_kind",
    "bnx.draft_owned",
    "bnx.economic_type_violation_lines",
    "bnx.handoff_text_ok",
    "bnx.index_ack",
    "bnx.intake_exception_new",
    "bnx.intake_item_new",
    "bnx.notify",
    "bnx.plan_create",
    "bnx.plan_item_economic_type",
    "bnx.plan_item_lines",
    "bnx.q_account_proposals",
    "bnx.q_intake_exceptions",
    "bnx.q_notifications",
    "bnx.sender_institution",
    "bnx.stage_jobs",
    "bnx.stage_write",
    "bnx.trg_plan_item_clearing_open",
    "bnx.wrk_intake_housekeeping",
    "bnx.wrk_issue_exec_lease",
    "bnx.wrk_promote_staged",
    "bnx.wrk_record_identity_signal",
    "bnx.wrk_stage_completion",
    "bnx.plan_revalidate",
    "bnx.plan_withdraw",
    "bnx.cmd_validate_plan",
    "bnx.cmd_withdraw_plan",
}


@test("AT-INV-01", "S4B-F02 (scope: migrations implemented so far, B002..9010)")
def t_inventory(server, ev):
    db = "bnx_s4inv01"
    h.bootstrap(server, db); h.migrate(server, db)
    rows = list(csv.DictReader(open(os.path.join(ROOT, "tests/fixtures/s4/Balnexa_S4_R1_Object_Disposition_V1.2.csv"), encoding="utf-8")))
    checked, missing, skipped = [], [], 0
    with migrator(server, db) as cx:
        for r in rows:
            migs = set(re.split(r"[/,; ]+", r["Migration"].strip())) - {""} or {"—"}
            if r["Kind"] not in KINDS or r["Disposition"] in ("DROP", "SUPERSEDED_DEFINITION") or not migs <= IMPLEMENTED \
               or (r["Disposition"] == "NEW" and migs == {"—"}):
                skipped += 1; continue
            o = r["Object"]
            if r["Kind"] == "trigger":
                m = re.match(r"\s*([a-z_0-9]+)\s+ON\s+([a-z_]+\.[a-z_0-9]+)", o)
                if not m:
                    skipped += 1; continue
                ok = cx.execute("select exists (select 1 from pg_trigger where tgname = %s and tgrelid = to_regclass(%s))", m.groups()).fetchone()[0]
            elif r["Kind"] in ("schema", "role", "extension"):
                name = re.match(r"\s*([a-z_0-9]+)", o).group(1)
                q = {"schema": "select exists (select 1 from pg_namespace where nspname = %s)",
                     "role": "select exists (select 1 from pg_roles where rolname = %s)",
                     "extension": "select exists (select 1 from pg_extension where extname = %s)"}[r["Kind"]]
                ok = cx.execute(q, (name,)).fetchone()[0]
            else:
                m = re.match(r"\s*([a-z_]+)\.([a-z_0-9]+)", o)
                if not m:
                    skipped += 1; continue
                q = {"function": "select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = %s and p.proname = %s)",
                     "type": "select exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace where n.nspname = %s and t.typname = %s)"}.get(
                     r["Kind"], "select to_regclass(%s || '.' || %s) is not null")
                ok = cx.execute(q, m.groups()).fetchone()[0]
            (checked if ok else missing).append(f"{r['OBJ_ID']} {o[:60]}")
        # reverse direction: S4 objects in the catalog that the disposition does not list
        text = " ".join(r["Object"] + " " + r["Replacement_Or_Change"] for r in rows)
        listed = {"bnx." + x for x in re.findall(r"(?<![a-z_0-9])(?:bnx\.)?([a-z][a-z_0-9]{2,})", text)}
        created = {f"bnx.{x[0]}" for x in cx.execute(
            "select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' "
            "union select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'bnx' and c.relkind = 'r'")}
    r1db = "bnx_s4inv01_r1"
    h.bootstrap(server, r1db, b002=False); h.migrate(server, r1db, mdir=r1_dir())
    with migrator(server, r1db) as cx:
        r1 = {f"bnx.{x[0]}" for x in cx.execute(
            "select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' "
            "union select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'bnx' and c.relkind = 'r'")}
    new_unlisted = sorted((created - r1) - listed)
    json.dump({"checked": checked, "missing": missing, "skipped": skipped, "new_unlisted": new_unlisted},
              open(os.path.join(ev, "AT-INV-01_inventory.json"), "w"), indent=1)
    check(not missing, f"disposition objects absent from the catalog: {missing}")
    check(set(new_unlisted) == HELPERS_NOT_IN_DISPOSITION, f"unlisted S4 objects differ from the declared helper list: {new_unlisted}")
    return (f"{len(checked)} disposition rows in scope (B002..9010) present in the catalog, 0 missing ({skipped} rows out of scope); "
            f"{len(new_unlisted)} S4 helper objects not yet in the disposition (declared): {new_unlisted}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(ROOT, "EVIDENCE", "s4_core1", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute("drop database if exists bnx_s4mig11b with (force)")
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev)
            status = "SKIP" if isinstance(msg, str) and msg.startswith("SKIP:") else "PASS"
            msg = msg[5:] if status == "SKIP" else msg
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__,
               "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core1_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
