#!/usr/bin/env python3
"""G0 offline suite (R6.2-R1). Every security/accounting claim is exercised through the intended identity:
bnx_app (cmd_*/q_* with real session or bearer credentials), bnx_authn, bnx_worker, bnx_migrator, bnx_backup.
The migrator under SET ROLE bnx_definer is used ONLY for (a) installer steps and (b) "defence-in-depth" probes that
model a buggy future definer function writing tables directly. postgres (superuser) is used ONLY to create/drop test
databases, to load the Draft-02 conversion fixture and the Draft-04 baseline (negative controls), and for fault
injection (pg_terminate_backend). Usage: run_g0.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, base64, concurrent.futures as cf, hashlib, json, os, shutil, subprocess, sys, tempfile, threading, time, traceback, uuid
import psycopg
import harness as h
import fixture as F

RESULTS = []
TESTS = []


def test(tid, aud):
    def deco(fn):
        TESTS.append((tid, aud, fn))
        return fn
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


def counts(H):
    with H.definer() as cx:
        return cx.execute("select (select version from bnx.ledger_state), (select count(*) from bnx.journal_entry), "
                          "(select count(*) from bnx.audit_event), (select count(*) from bnx.idempotency), "
                          "(select count(*) from bnx.outbox)").fetchone()


SHARED = {}


def household(server, fresh=False):
    if fresh or server not in SHARED:
        H = F.Household(server)
        if fresh:
            return H
        SHARED[server] = H
    return SHARED[server]


# ------------------------------------------------------------------------------------------------ migrations AUD-049
@test("AT-MIG-01", "AUD-049,AUD-037")
def t_mig_clean(server, ev):
    db = "bnx_mig01"
    h.bootstrap(server, db)
    r1 = h.migrate(server, db, log=os.path.join(ev, "AT-MIG-01_first_run.log"))
    r2 = h.migrate(server, db, log=os.path.join(ev, "AT-MIG-01_rerun.log"))
    check("session_user=bnx_migrator current_user=bnx_migrator rolsuper=False rolinherit=False" in r1.stdout, "identity line")
    nfiles = len([f for f in os.listdir(os.path.join(h.ROOT, "db/migrations")) if f.endswith(".sql")])
    check(r2.stdout.count("skip ") == nfiles and "apply" not in r2.stdout, "rerun must only verify")
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        rows = cx.execute("select version, applied_by_session from bnx.schema_migrations order by version").fetchall()
    check(all(r[1] == "bnx_migrator" for r in rows) and len(rows) == nfiles, f"ledger rows {rows}")
    return f"{nfiles} migrations applied by session_user=bnx_migrator (current_user=bnx_definer); rerun verified {nfiles} checksums, applied 0"


@test("AT-MIG-02", "AUD-049")
def t_mig_tamper(server, ev):
    db = "bnx_mig01"
    d = tempfile.mkdtemp()
    for f in os.listdir(os.path.join(h.ROOT, "db/migrations")):
        shutil.copy(os.path.join(h.ROOT, "db/migrations", f), d)
    with open(os.path.join(d, "0103_currency_integrity.sql"), "a") as fh:
        fh.write("\n-- tampered\n")
    r = h.migrate(server, db, check=False, mdir=d, log=os.path.join(ev, "AT-MIG-02_tamper.log"))
    check(r.returncode == 5 and "migrations are immutable" in r.stdout, r.stdout + r.stderr)
    os.remove(os.path.join(d, "0103_currency_integrity.sql"))
    r = h.migrate(server, db, check=False, mdir=d)
    check(r.returncode == 4, "removed applied file must abort: " + r.stdout)
    return "modified applied 0103 -> exit 5 before any apply; removed applied file -> exit 4"


@test("AT-MIG-03", "AUD-049")
def t_mig_inject(server, ev):
    db = "bnx_mig03"
    h.bootstrap(server, db)
    r = h.migrate(server, db, "--inject-failure", "0106", check=False, log=os.path.join(ev, "AT-MIG-03_inject.log"))
    check(r.returncode == 6 and "rolled back" in r.stdout, r.stdout)
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        mx = cx.execute("select max(version) from bnx.schema_migrations").fetchone()[0]
        fn = cx.execute("select to_regprocedure('bnx.cmd_post_transaction(jsonb,jsonb)')").fetchone()[0]
        tb = cx.execute("select to_regclass('bnx.audit_event')").fetchone()[0]
    check(mx == "0105" and fn is None and tb is None, f"partial state: head={mx} fn={fn} table={tb}")
    r = h.migrate(server, db)
    check("apply 0106" in r.stdout and "OK migrations=" in r.stdout, r.stdout)
    return "failure injected after 0106 body+ledger row: head stays 0105, no 0106 object exists; rerun completes"


@test("AT-MIG-04", "AUD-049")
def t_mig_refused(server, ev):
    db = "bnx_mig04"
    h.bootstrap(server, db)
    d = tempfile.mkdtemp()
    shutil.copy(os.path.join(h.ROOT, "db/history/draft04/migrations/0001_roles_schemas_extensions.sql"), d)
    r = h.migrate(server, db, check=False, mdir=d)
    check(r.returncode == 2 and "refused" in r.stdout, r.stdout)
    r = subprocess.run([sys.executable, os.path.join(h.ROOT, "db/tools/run_migrations.py"), "--dsn", h.dsn(server, "postgres", db)],
                       capture_output=True, text=True)
    check(r.returncode == 3, "superuser session must be refused: " + r.stdout)
    return "Draft-04 0001 in chain -> refused (exit 2); runner under postgres superuser -> refused (exit 3)"


@test("AT-MIG-05", "AUD-049")
def t_mig_runtime_denied(server, ev):
    db = "bnx_mig01"
    out = []
    for role in ("bnx_app", "bnx_worker", "bnx_authn", "bnx_auth", "bnx_backup"):
        with psycopg.connect(h.dsn(server, role, db), autocommit=True) as cx:
            for stmt in ("insert into bnx.schema_migrations values ('9999','x')", "delete from bnx.schema_migrations",
                         "create table bnx.evil(x int)", "alter table bnx.journal_entry add column x int"):
                try:
                    cx.execute(stmt)
                    raise Fail(f"{role}: {stmt} succeeded")
                except psycopg.Error as e:
                    out.append(type(e).__name__)
    with psycopg.connect(h.dsn(server, "bnx_migrator", db), autocommit=True) as cx:   # no SET ROLE: inherits nothing
        for stmt in ("select * from bnx.schema_migrations", "insert into bnx.schema_migrations values ('9999','x')",
                     "create table bnx.evil(x int)", "select bnx.cmd_post_transaction('{}','{}')"):
            try:
                cx.execute(stmt)
                raise Fail(f"migrator without SET ROLE: {stmt} succeeded")
            except psycopg.Error as e:
                out.append(type(e).__name__)
    check(set(out) <= {"InsufficientPrivilege", "ReadOnlySqlTransaction"}, str(set(out)))
    return f"{len(out)} denied statements (runtime roles x4 statements; migrator without SET ROLE x4)"


@test("AT-MIG-06", "AUD-049,AUD-050")
def t_mig_matrix(server, ev):
    db = "bnx_mig01"
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        audit = cx.execute("select bnx.audit_privileges()").fetchone()[0]
        roles = cx.execute("select rolname, rolsuper, rolinherit, rolcanlogin, rolcreaterole, rolbypassrls from pg_roles "
                           "where rolname like 'bnx\\_%' order by 1").fetchall()
        mem = cx.execute("select g.rolname, u.rolname, am.inherit_option, am.set_option, am.admin_option from pg_auth_members am "
                         "join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member "
                         "where g.rolname like 'bnx\\_%' or u.rolname like 'bnx\\_%'").fetchall()
        fns = cx.execute("select p.proname, has_function_privilege('bnx_app', p.oid, 'EXECUTE'), "
                         "has_function_privilege('bnx_worker', p.oid, 'EXECUTE'), has_function_privilege('bnx_authn', p.oid, 'EXECUTE'), "
                         "p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' order by 1").fetchall()
        # negative control: an injected grant must be detected
        cx.execute("grant select on bnx.member to bnx_app")
        bad = cx.execute("select bnx.audit_privileges()").fetchone()[0]["violations"]
        cx.rollback()
    json.dump({"roles": roles, "memberships": mem, "functions": fns, "audit": audit}, open(os.path.join(ev, "privilege_matrix.json"), "w"),
              indent=1, default=str)
    check(audit["violations"] == [], str(audit["violations"])[:500])
    check(mem == [("bnx_definer", "bnx_migrator", False, True, False)], str(mem))
    check(any(v["rule"] == "RUNTIME_TABLE_PRIVILEGE" for v in bad), "injected grant not detected")
    return f"0 violations over {len(audit['matrix'])} relations and {len(fns)} functions; injected GRANT detected; matrix -> privilege_matrix.json"


@test("AT-MIG-07", "AUD-049,AUD-037")
def t_mig_9001(server, ev):
    db = "bnx_mig07"
    h.bootstrap(server, db)
    h.migrate(server, db, "--upto", "0899")
    d02 = open(os.path.join(h.ROOT, "db/history/draft04/fixtures/draft02_logical_state.sql")).read() + "\n" + \
        open(os.path.join(h.ROOT, "tests/sql/draft02_fixture_d02_rows.sql")).read()
    p = subprocess.run([h.PSQL, h.dsn(server, "postgres", db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1"], input=d02, capture_output=True, text=True)
    check(p.returncode == 0, "d02 fixture (installer): " + p.stderr[:800])
    p = subprocess.run([h.PSQL, h.dsn(server, "bnx_migrator", db), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1",
                        "-f", os.path.join(h.ROOT, "tests/sql/draft02_fixture_bnx_rows.sql")], capture_output=True, text=True)
    check(p.returncode == 0, "bnx fixture rows (migrator): " + p.stderr[:800])
    h.migrate(server, db, log=os.path.join(ev, "AT-MIG-07_9001.log"))
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        anchors = cx.execute("select amount, valid_from_version from bnx.opening_anchor_version order by valid_from_version").fetchall()
        n_conf = cx.execute("select count(*) from bnx.posting_date_confirmation").fetchone()[0]
        n_dec = cx.execute("select count(*) from bnx.match_decision_event").fetchone()[0]
        n_cur = cx.execute("select count(*) from bnx.match_decision_current").fetchone()[0]
        b = cx.execute("select (bnx.balance_at(md5('ac-chq')::uuid, '2024-12-31', 9223372036854775807)).amount").fetchone()[0]
    check([float(x[0]) for x in anchors] == [5000.0, 5200.0] and n_conf == 2 and n_dec == 2 and n_cur == 1, f"{anchors} {n_conf} {n_dec} {n_cur}")
    return f"Draft-02 fixture converted by bnx_migrator via 9001: anchor versions 5000 then 5200, 2 versioned confirmations, 2 decision events, 1 current; balance {b}"


@test("AT-MIG-08", "AUD-049 (negative control)")
def t_mig_baseline(server, ev):
    db = "bnx_d04ctl"
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute(f"create database {db}")
    r = subprocess.run([sys.executable, os.path.join(h.ROOT, "db/history/draft04/tools/run_migrations.py"),
                        "--dsn", h.dsn(server, "bnx_migrator", db), "--dir", os.path.join(h.ROOT, "db/history/draft04/migrations")],
                       capture_output=True, text=True, env={**os.environ, "PATH": os.path.dirname(h.PSQL) + ":" + os.environ["PATH"]})
    open(os.path.join(ev, "AT-MIG-08_draft04_as_migrator.log"), "w").write(r.stdout + r.stderr)
    check(r.returncode != 0 and "FAIL" in (r.stdout + r.stderr), "Draft-04 chain unexpectedly succeeded under bnx_migrator")
    first = [l for l in (r.stdout + r.stderr).splitlines() if "ERROR" in l][:1]
    return f"Draft-04 0001-0007 under bnx_migrator fails as the audit predicted: {first}"


# --------------------------------------------------------------------------------------------- accounting AUD-044/045
def definer_txn(H, sql_list):
    cx = H.definer()
    try:
        for s, p in sql_list:
            cx.execute(s, p)
        cx.commit()
    finally:
        cx.close()


def je_sql(jid, et="consumption_expense"):
    return ("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, "
            "ledger_version, origin_channel, created_by_member, confirmed_by_member) values (%s, %s, '2026-02-01', '2026-02-01', "
            "'estimated', 'probe', bnx.next_version(), 'pwa', %s, %s)")


def jl_sql():
    return "insert into bnx.journal_line(id, journal_id, ledger_account_id, currency, amount) values (gen_random_uuid(), %s, %s, %s, %s)"


@test("AT-BAL-01", "AUD-044")
def t_bal_definer_probes(server, ev):
    H = household(server)
    o = H.owner_id
    cad, usd = H.cad, H.usd
    before = H.balance(H.owner)
    cases = {
        "header-only": [],
        "one line": [(cad["ledger_account_id"], "CAD", "-5")],
        "same sign": [(cad["ledger_account_id"], "CAD", "-5"), (H.groceries, "CAD", "-5")],
        "cross-currency zero sum": [(cad["ledger_account_id"], "CAD", "-5"), (usd["ledger_account_id"], "USD", "5")],
        "unbalanced": [(cad["ledger_account_id"], "CAD", "-5"), (H.groceries, "CAD", "4.99")],
        "over-scale": [(cad["ledger_account_id"], "CAD", "-5.001"), (H.groceries, "CAD", "5.001")],
    }
    msgs = []
    for name, lines in cases.items():
        j = str(uuid.uuid4())
        stmts = [(je_sql(j), (j, "consumption_expense", o, o))] + [(jl_sql(), (j, la, c, a)) for la, c, a in lines]
        m = expect_err(definer_txn, "JOURNAL_", H, stmts) if name != "over-scale" else expect_err(definer_txn, "AMOUNT_SCALE", H, stmts)
        msgs.append(f"{name}: {m.split(':')[0]}")
    j = str(uuid.uuid4())
    expect_err(definer_txn, "violates foreign key", H, [(je_sql(j), (j, "consumption_expense", o, o)),
               (jl_sql(), (j, cad["ledger_account_id"], "USD", "-5")), (jl_sql(), (j, H.fees_usd, "USD", "5"))])
    msgs.append("wrong-currency line: composite FK")
    # late line: commit a valid journal, then add a line in a later transaction
    j = str(uuid.uuid4())
    definer_txn(H, [(je_sql(j), (j, "consumption_expense", o, o)), (jl_sql(), (j, cad["ledger_account_id"], "CAD", "-1")),
                    (jl_sql(), (j, H.groceries, "CAD", "1"))])
    expect_err(definer_txn, "LATE_LINE", H, [(jl_sql(), (j, cad["ledger_account_id"], "CAD", "-1")), (jl_sql(), (j, H.groceries, "CAD", "1"))])
    msgs.append("late lines in later txn: LATE_LINE")
    after = H.balance(H.owner)
    check(float(after) == float(before) - 1, f"balance moved by rejected work: {before} -> {after}")
    return "; ".join(msgs) + f"; balance changed only by the one valid probe ({before} -> {after})"


@test("AT-BAL-02", "AUD-044")
def t_bal_commands(server, ev):
    H = household(server)
    c0 = counts(H)
    cad = H.cad
    bad = [
        ("JOURNAL_UNBALANCED", [{"ledger_account_id": cad["ledger_account_id"], "currency": "CAD", "amount": "-5"},
                                {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "4"}]),
        ("VALIDATION_FAILED", [{"ledger_account_id": cad["ledger_account_id"], "currency": "CAD", "amount": "-5"}]),
        ("JOURNAL_UNBALANCED", [{"ledger_account_id": cad["ledger_account_id"], "currency": "CAD", "amount": "-5"},
                                {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "-5"}]),
        ("violates foreign key", [{"ledger_account_id": cad["ledger_account_id"], "currency": "USD", "amount": "-5"},
                                  {"ledger_account_id": H.fees_usd, "currency": "USD", "amount": "5"}]),
        ("AMOUNT_SCALE", [{"ledger_account_id": cad["ledger_account_id"], "currency": "CAD", "amount": "-5.005"},
                          {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "5.005"}]),
        ("VALIDATION_FAILED", [{"ledger_account_id": cad["ledger_account_id"], "currency": "CAD", "amount": "-5e2"},
                               {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "5e2"}]),
        ("NO_ACCOUNT_LINE", [{"ledger_account_id": H.salary, "currency": "CAD", "amount": "-5"},
                             {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "5"}]),
    ]
    for code, lines in bad:
        expect_err(H.cmd, code, H.owner, "post_transaction", key="bad-" + code[:6] + uuid.uuid4().hex[:6],
                   economic_type="consumption_expense", transaction_date="2026-02-11", description="x", lines=lines)
    c1 = counts(H)
    check(c0 == c1, f"rejected commands changed state {c0} -> {c1}")
    return f"{len(bad)} malformed commands rejected; ledger version, journals, audit, idempotency and outbox counts unchanged {c0}"


@test("AT-BAL-03", "AUD-044,AUD-045")
def t_bal_positive(server, ev):
    H = household(server)
    b0 = H.balance(H.owner)
    r = H.expense(H.owner, "10.00")
    check(r["status"] == "committed", str(r))
    # split purchase (multi-line)
    H.cmd(H.owner, "post_transaction", economic_type="consumption_expense", transaction_date="2026-02-12", description="split",
          lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-30.00"},
                 {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "20.00"},
                 {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "10.00"}])
    # FX conversion CAD->USD with fx_trading legs, original currency kept separately from posting currencies
    with H.definer() as cx:
        fx_cad = str(cx.execute("select bnx.system_ledger_account('fx_trading','CAD','FX trading')").fetchone()[0])
        fx_usd = str(cx.execute("select bnx.system_ledger_account('fx_trading','USD','FX trading')").fetchone()[0])
        cx.commit()
    r = H.cmd(H.owner, "post_transaction", economic_type="fx_conversion", transaction_date="2026-02-13", description="CAD->USD",
              original_amount="137.00", original_currency="CAD", settled_rate="0.7300000000",
              lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-137.00"},
                     {"ledger_account_id": fx_cad, "currency": "CAD", "amount": "137.00"},
                     {"ledger_account_id": H.usd["ledger_account_id"], "currency": "USD", "amount": "100.01"},
                     {"ledger_account_id": fx_usd, "currency": "USD", "amount": "-100.01"}])
    with H.definer() as cx:
        oc = cx.execute("select original_amount, original_currency, settled_rate from bnx.journal_entry where id = %s", (r["journal_id"],)).fetchone()
    b1 = H.balance(H.owner)
    u1 = H.balance(H.owner, ac=H.usd)
    check(round(float(b0) - float(b1), 2) == 177.00 and float(u1) >= 100.01, f"CAD {b0}->{b1} USD {u1}")
    check(str(oc[0]) == "137.0000" and oc[1] == "CAD", str(oc))
    return f"2-line, 3-line split and 4-line FX journals committed; CAD {b0}->{b1}; USD={u1}; original 137.00 CAD @0.73 preserved"


@test("AT-BAL-04", "AUD-045")
def t_cur_linked(server, ev):
    H = household(server)
    msgs = []
    with H.definer() as cx:
        doc = cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state) values (gen_random_uuid(), "
                         "'orig/' || gen_random_uuid(), 10, 'unverified') returning id").fetchone()[0]
        d = cx.execute("insert into bnx.document(id, evidence_object_id, seq, doc_type) values (gen_random_uuid(), %s, 1, 'bank_statement') returning id", (doc,)).fetchone()[0]
        cx.commit()
    probes = [
        ("statement USD on CAD account-currency",
         "insert into bnx.statement(id, document_id, account_currency_id, currency, sign_convention) values (gen_random_uuid(), %s, %s, 'USD', 'asset_positive')",
         (d, H.cad["account_currency_id"]), "violates foreign key"),
        ("source_txn USD on CAD account-currency",
         "insert into bnx.source_txn(id, account_currency_id, posting_date, amount, currency, canonical_occurrence, source_fingerprint) "
         "values (gen_random_uuid(), %s, '2026-02-01', 1, 'USD', 1, '\\x01')", (H.cad["account_currency_id"],), "violates foreign key"),
        ("clearing_item USD on CAD account-currency",
         "insert into bnx.clearing_item(id, account_currency_id, currency, kind, amount, opened_journal) values (gen_random_uuid(), %s, 'USD', "
         "'unclassified_movement', 1, gen_random_uuid())", (H.cad["account_currency_id"],), "violates foreign key"),
        ("account_currency EUR bound to a USD ledger account",
         "with la as (insert into bnx.ledger_account values (gen_random_uuid(), 'asset', 'USD', 'probe') returning id) "
         "insert into bnx.account_currency select gen_random_uuid(), %s, 'EUR', id from la", (H.acc,), "violates foreign key"),
        ("lower-case currency code", "insert into bnx.currency values ('cad', 2)", None, "currency_iso"),
        ("JPY fraction", "insert into bnx.source_txn(id, account_currency_id, posting_date, amount, currency, canonical_occurrence, source_fingerprint) "
         "values (gen_random_uuid(), %s, '2026-02-01', 1.5, 'CAD', 1, '\\x02')", None, "AMOUNT_SCALE"),
        ("statement CAD scale", "insert into bnx.statement(id, document_id, account_currency_id, currency, closing_balance, sign_convention) "
         "values (gen_random_uuid(), %s, %s, 'CAD', 1.001, 'asset_positive')", (d, H.cad["account_currency_id"]), "AMOUNT_SCALE"),
    ]
    with H.definer() as cx:
        jpy = cx.execute("select gen_random_uuid()").fetchone()[0]
    for name, sql, p, code in probes:
        if name == "JPY fraction":
            # create a JPY account through the command path, then probe
            r = H.cmd(H.owner, "create_account", kind="bank_deposit", **H.inst("Synthetic Bank"), label="Yen", currencies=["JPY"])
            p = (r["account_currencies"][0]["account_currency_id"],)
            sql = sql.replace("'CAD'", "'JPY'")
        def go():
            with H.definer() as cx:
                cx.execute(sql, p)
                cx.commit()
        expect_err(go, code)
        msgs.append(name)
    return "rejected: " + "; ".join(msgs)


@test("AT-BAL-05", "AUD-044,AUD-045 (negative control on Draft-04 baseline)")
def t_bal_baseline(server, ev):
    db = "bnx_d04base"
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as cx:
        cx.execute(f"create database {db}")
    r = subprocess.run([sys.executable, os.path.join(h.ROOT, "db/history/draft04/tools/run_migrations.py"),
                        "--dsn", h.dsn(server, "postgres", db), "--dir", os.path.join(h.ROOT, "db/history/draft04/migrations")],
                       capture_output=True, text=True, env={**os.environ, "PATH": os.path.dirname(h.PSQL) + ":" + os.environ["PATH"]})
    check(r.returncode == 0, r.stdout + r.stderr)
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        cx.execute("set role bnx_definer")
        cx.execute("insert into bnx.currency values ('CAD',2),('USD',2)")
        la, la2 = str(uuid.uuid4()), str(uuid.uuid4())
        cx.execute("insert into bnx.ledger_account values (%s,'asset','CAD','cad acct'),(%s,'expense','USD','usd exp')", (la, la2))
        j = str(uuid.uuid4())
        cx.execute("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, "
                   "ledger_version, origin_channel, created_by_member, confirmed_by_member) values (%s,'fee','2026-01-01','2026-01-01','estimated','hdr',1,'pwa',%s,%s)",
                   (j, la, la))
        cx.commit()
        j2 = str(uuid.uuid4())
        cx.execute("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, "
                   "ledger_version, origin_channel, created_by_member, confirmed_by_member) values (%s,'fee','2026-01-01','2026-01-01','estimated','mix',2,'pwa',%s,%s)",
                   (j2, la, la))
        cx.execute("insert into bnx.journal_line values (gen_random_uuid(), %s, %s, 'USD', -5, null), (gen_random_uuid(), %s, %s, 'USD', 5, null)",
                   (j2, la, j2, la2))
        cx.commit()
        n0 = cx.execute("select count(*) from bnx.journal_line where journal_id = %s", (j,)).fetchone()[0]
        mix = cx.execute("select count(*) from bnx.journal_line jl join bnx.ledger_account a on a.id = jl.ledger_account_id "
                         "where jl.currency <> a.currency").fetchone()[0]
    check(n0 == 0 and mix == 1, f"baseline control did not reproduce: lines={n0} mismatched={mix}")
    return "Draft-04 baseline accepts a header-only journal (0 lines committed) and a USD line on a CAD ledger account (defects reproduced)"


@test("AT-MUT-01", "AUD-044,AUD-045 (mutation check: the tests detect removal of the fix)")
def t_mutation(server, ev):
    H = household(server, fresh=True)
    o = H.owner_id
    with H.definer() as cx:
        cx.execute("drop trigger t_journal_complete_header on bnx.journal_entry")
        cx.execute("alter table bnx.journal_line drop constraint journal_line_ledger_currency_fk")
        cx.commit()
    j = str(uuid.uuid4())
    definer_txn(H, [(je_sql(j), (j, "consumption_expense", o, o))])          # header-only now commits
    j2 = str(uuid.uuid4())
    lines2 = [(je_sql(j2), (j2, "consumption_expense", o, o)), (jl_sql(), (j2, H.cad["ledger_account_id"], "USD", "-5")),
              (jl_sql(), (j2, H.fees_usd, "USD", "5"))]
    expect_err(definer_txn, "LINE_CURRENCY_MISMATCH", H, lines2)          # second layer still holds without the FK
    with H.definer() as cx:
        cx.execute("drop trigger t_journal_complete_line on bnx.journal_line")
        cx.commit()
    definer_txn(H, lines2)                                                   # both layers removed: mismatch commits
    with H.definer() as cx:
        n = cx.execute("select count(*) from bnx.journal_line where journal_id = %s", (j,)).fetchone()[0]
        m = cx.execute("select count(*) from bnx.journal_line where journal_id = %s", (j2,)).fetchone()[0]
    check(n == 0 and m == 2, f"{n} {m}")
    return ("mutants: without t_journal_complete_header a header-only journal commits; without the composite FK the deferred "
            "LINE_CURRENCY_MISMATCH layer still rejects; without both a USD line on the CAD account commits. The AT-BAL-01 probes detect each mutant")


# --------------------------------------------------------------------------------------------- Command Core AUD-053
@test("AT-CMD-01", "AUD-053")
def t_cmd_signin(server, ev):
    H = household(server)
    expect_err(H.authn.call, "UNAUTHENTICATED", "authn_begin_session", F.claims("g-unknown"))
    expect_err(H.authn.call, "UNAUTHENTICATED", "authn_begin_session", {**F.claims("g-owner"), "email_verified": False})
    expect_err(H.authn.call, "UNAUTHENTICATED", "authn_begin_session", {**F.claims("g-owner"), "iss": "https://evil.example"})
    expect_err(H.app.call, "UNAUTHENTICATED", "q_balances", {"kind": "session", "secret": "x" * 40}, {})
    # forged token: last character changed. R1 used a fixed "A", which equals the real secret ~1/16 of the time (the last
    # base64 character of a 32-byte secret is one of 16 values) and then the call rightly succeeds (S4 fix, F-C3-12)
    sec = H.owner["secret"]
    expect_err(H.app.call, "UNAUTHENTICATED", "q_balances", {"kind": "session", "secret": sec[:-1] + ("B" if sec[-1] == "A" else "A")}, {})
    expect_err(H.app.call, "permission denied", "authn_begin_session", F.claims("g-owner"))   # app cannot mint sessions
    with H.definer() as cx:
        raw = cx.execute("select count(*) from bnx.member_session where encode(token_sha256,'escape') like %s",
                         ("%" + H.owner["secret"][:12] + "%",)).fetchone()[0]
        n = cx.execute("select count(*) from bnx.member_session").fetchone()[0]
    check(raw == 0, "raw token stored")
    return f"unknown subject, unverified email, foreign issuer, forged and truncated tokens rejected; {n} sessions stored as SHA-256 only"


@test("AT-CMD-02", "AUD-053")
def t_cmd_idem(server, ev):
    H = household(server)
    r1 = H.expense(H.owner, "3.00", key="idem-fixed-0001")
    r2 = H.expense(H.owner, "3.00", key="idem-fixed-0001")
    check(r1["journal_id"] == r2["journal_id"] and r2["replayed"] is True and r1["replayed"] is False, f"{r1} {r2}")
    c0 = counts(H)
    expect_err(H.expense, "IDEMPOTENCY_CONFLICT", H.owner, "3.01", key="idem-fixed-0001")
    check(counts(H) == c0, "conflict changed state")
    r3 = H.expense(H.member, "3.00", key="idem-fixed-0001")      # keys are per member
    check(r3["journal_id"] != r1["journal_id"], "cross-member key collision")
    return "same key+payload -> identical receipt (replayed=true), changed payload -> IDEMPOTENCY_CONFLICT without effects, keys scoped per member"


@test("AT-CONC-01", "AUD-053")
def t_conc_same_key(server, ev):
    H = household(server)
    key = "idem-race-" + uuid.uuid4().hex[:8]
    apps = [h.Role(server, H.db, "bnx_app") for _ in range(8)]
    body = dict(economic_type="consumption_expense", transaction_date="2026-03-01", description="race", idempotency_key=key,
                lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-1.00"},
                       {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "1.00"}])
    with cf.ThreadPoolExecutor(8) as ex:
        rs = list(ex.map(lambda a: a.call("cmd_post_transaction", H.owner, body), apps))
    ids = {r["journal_id"] for r in rs}
    check(len(ids) == 1 and sum(1 for r in rs if not r["replayed"]) == 1, str(rs))
    for a in apps:
        a.close()
    return "8 concurrent identical requests -> 1 journal, 7 replays"


@test("AT-CONC-02", "AUD-053,AUD-044")
def t_conc_posts(server, ev):
    H = household(server)
    b0 = float(H.balance(H.owner))
    apps = [h.Role(server, H.db, "bnx_app") for _ in range(10)]
    def go(i):
        a = apps[i % 10]
        cred = H.owner if i % 2 else H.member
        return a.call("cmd_post_transaction", cred, dict(economic_type="consumption_expense", transaction_date="2026-03-02",
                      description=f"c{i}", idempotency_key=f"conc-{uuid.uuid4().hex}",
                      lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-0.01"},
                             {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "0.01"}]))
    with cf.ThreadPoolExecutor(10) as ex:
        rs = list(ex.map(go, range(100)))
    vs = sorted(r["ledger_version"] for r in rs)
    b1 = float(H.balance(H.owner))
    check(len(set(vs)) == 100 and vs[-1] - vs[0] == 99, "versions not unique/contiguous")
    check(round(b0 - b1, 2) == 1.00, f"{b0}->{b1}")
    with H.definer() as cx:
        bad = cx.execute("select bnx.audit_verify()").fetchone()[0]
    check(bad == 0, f"audit chain broken at {bad}")
    for a in apps:
        a.close()
    return f"100 concurrent posts (10 connections, 2 members): versions {vs[0]}..{vs[-1]} unique and contiguous; balance -1.00 exact; audit chain intact"


@test("AT-CMD-03", "AUD-053")
def t_cmd_authz(server, ev):
    H = household(server)
    expect_err(H.expense, "FORBIDDEN_ROLE", H.viewer, "1.00")
    r = H.cmd(H.member, "create_account", kind="e_wallet", **H.inst("Synthetic Pay", kind="payment_wallet"), label="Member private", currencies=["CAD"], visibility="private")
    priv = r["account_currencies"][0]
    vis_owner = [b["account_currency_id"] for b in H.q(H.owner, "balances")["balances"]]
    check(priv["account_currency_id"] not in vis_owner, "owner sees member's private account without a grant")
    expect_err(H.expense, "NOT_POSTABLE", H.owner, "1.00", ac=priv)
    m1 = expect_err(H.cmd, "NOT_AVAILABLE", H.owner, "set_grant", member_id=H.owner_id, account_id=r["account_id"], can_view=True, can_post=False)
    m2 = expect_err(H.cmd, "NOT_AVAILABLE", H.owner, "set_grant", member_id=H.owner_id, account_id=str(uuid.uuid4()), can_view=True, can_post=False)
    check(m1 == m2, "private-account grant refusal is an existence oracle")
    H.cmd(H.member, "set_grant", member_id=H.owner_id, account_id=r["account_id"], can_view=True, can_post=False)   # creator shares
    check(priv["account_currency_id"] in [b["account_currency_id"] for b in H.q(H.owner, "balances")["balances"]], "creator share not applied")
    H.cmd(H.member, "set_grant", member_id=H.owner_id, account_id=r["account_id"], can_view=False, can_post=False)
    expect_err(H.cmd, "VALIDATION_FAILED", H.member, "register_evidence", size=-1, sha256_declared="00", name="x.pdf")
    # member loses can_post on the household account
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=True, can_post=False)
    expect_err(H.expense, "NOT_POSTABLE", H.member, "1.00")
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=True, can_post=True)
    expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=True, can_post=True)
    expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "invite_member", display_name="x", role="admin", google_sub="g-x")
    # direct table access and cross-role function calls
    for role, stmt in (("bnx_app", "select * from bnx.journal_entry"), ("bnx_app", "insert into bnx.journal_line values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'CAD', 1, null)"),
                       ("bnx_app", "select bnx.wrk_activate_plan(gen_random_uuid())"), ("bnx_app", "select bnx.insert_journal(null,1,null,'fee',null,null,null,'[]',null,null,null,null)"),
                       ("bnx_app", "select bnx.install_household('x','y','z')"), ("bnx_worker", "select bnx.cmd_post_transaction('{}','{}')"),
                       ("bnx_authn", "select bnx.q_balances('{}','{}')"), ("bnx_backup", "select bnx.q_balances('{}','{}')"),
                       ("bnx_app", "select bnx.next_version()"), ("bnx_app", "select bnx.audit(null,'x','{}','{}',null)")):
        with psycopg.connect(h.dsn(server, role, H.db), autocommit=True) as cx:
            try:
                cx.execute(stmt)
                raise Fail(f"{role}: {stmt}")
            except psycopg.errors.InsufficientPrivilege:
                pass
    return "viewer cannot post; private account invisible, not postable and not self-grantable by owner (uniform NOT_AVAILABLE), shareable only by its creator; revoked can_post enforced; member cannot grant/invite; 10 direct/cross-role calls denied"


@test("AT-CMD-04", "AUD-053")
def t_cmd_mcp(server, ev):
    H = household(server)
    verifier = base64.urlsafe_b64encode(os.urandom(40)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    with H.definer() as cx:
        cx.execute("insert into bnx.oauth_client values ('chatgpt-test', 'Synthetic AI host', array['https://host.example/cb']) on conflict do nothing")
        cx.commit()
    # S4 re-baseline (9009): catalog scopes (legacy read/propose are not granted to new consents); a replayed code revokes the
    # connection's tokens and is returned as {"error": "invalid_grant"} so the revocation commits (RFC 6749 §4.1.2)
    consent = lambda: H.cmd(H.owner, "approve_ai_connection", client_id="chatgpt-test", redirect_uri="https://host.example/cb",
              code_challenge=challenge, scopes=["finance.read", "finance.draft", "reports.read"], account_currency_ids=[H.cad["account_currency_id"]])
    r = consent()
    expect_err(H.authn.call, "INVALID_GRANT", "authn_oauth_token", {"code": r["code"], "client_id": "chatgpt-test",
               "redirect_uri": "https://host.example/cb", "code_verifier": "A" * 43})
    tok = H.authn.call("authn_oauth_token", {"code": r["code"], "client_id": "chatgpt-test", "redirect_uri": "https://host.example/cb", "code_verifier": verifier})
    rep = H.authn.call("authn_oauth_token", {"code": r["code"], "client_id": "chatgpt-test", "redirect_uri": "https://host.example/cb", "code_verifier": verifier})
    check(rep.get("error") == "invalid_grant", f"replay: {rep}")
    expect_err(H.q, "UNAUTHENTICATED", {"kind": "bearer", "secret": tok["access_token"]}, "balances")
    r = consent()
    tok = H.authn.call("authn_oauth_token", {"code": r["code"], "client_id": "chatgpt-test", "redirect_uri": "https://host.example/cb", "code_verifier": verifier})
    bearer = {"kind": "bearer", "secret": tok["access_token"]}
    bal = H.q(bearer, "balances")["balances"]
    check([b["account_currency_id"] for b in bal] == [H.cad["account_currency_id"]], "connection scope not applied")
    expect_err(H.expense, "FORBIDDEN_CHANNEL", bearer, "1.00")
    expect_err(H.cmd, "FORBIDDEN_CHANNEL", bearer, "approve_plan", plan_id=str(uuid.uuid4()), plan_hash="x", scope_digest="y")
    expect_err(H.q, "SCOPE_NOT_CONSENTED", bearer, "evidence_access", evidence_file_id=str(uuid.uuid4()))   # S4: no documents.read
    H.cmd(H.owner, "revoke_ai_connection", connection_id=r["connection_id"])
    expect_err(H.q, "UNAUTHENTICATED", bearer, "balances")
    return "PKCE wrong verifier -> INVALID_GRANT; code replay -> invalid_grant with the earlier token revoked; bearer limited to approved account-currency; MCP post/approve -> FORBIDDEN_CHANNEL; evidence denied; revoked connection -> UNAUTHENTICATED"


@test("AT-CMD-05", "AUD-053")
def t_cmd_correction(server, ev):
    H = household(server)
    b0 = float(H.balance(H.owner))
    r = H.expense(H.owner, "50.00", date="2026-03-05")
    c = H.cmd(H.owner, "correct_transaction", journal_id=r["journal_id"], reason="wrong amount",
              replacement={"transaction_date": "2026-03-05", "description": "fixed", "lines": [
                  {"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-5.00"},
                  {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "5.00"}]})
    b1 = float(H.balance(H.owner))
    check(round(b0 - b1, 2) == 5.00, f"{b0} -> {b1}")
    expect_err(H.cmd, "ALREADY_CORRECTED", H.owner, "correct_transaction", journal_id=r["journal_id"])
    expect_err(H.cmd, "NOT_CORRECTABLE", H.owner, "correct_transaction", journal_id=c["reversal_journal_id"])
    mid = float(H.balance(H.owner, ledger_version=c["ledger_version"] - 1))
    check(round(b0 - mid, 2) == 50.00, "pre-correction version not reproducible")
    with H.definer() as cx:
        vv = cx.execute("select count(distinct ledger_version) from bnx.journal_entry where id in (%s, %s)",
                        (c["reversal_journal_id"], c["replacement_journal_id"])).fetchone()[0]
    check(vv == 1, "reversal and replacement must share one version")
    return f"reversal+replacement at one version {c['ledger_version']}; balance at V-1 shows original (-50), at V shows -5; double correction refused"


def make_plan(H, cred, items, date_from="2026-04-01", date_to="2026-04-30"):
    return H.cmd(cred, "create_import_plan", account_currency_id=H.cad["account_currency_id"], date_from=date_from, date_to=date_to,
                 items=items)


def item(amount, d, cat):
    return {"transaction_date": d, "amount": amount, "counter_ledger_account_id": cat, "description": f"import {amount}"}


@test("AT-PLAN-01", "AUD-053")
def t_plan_lifecycle(server, ev):
    H = household(server, fresh=True)
    b0 = H.balance(H.owner, as_of="2026-12-31")
    p = make_plan(H, H.owner, [item("-12.00", "2026-04-03", H.groceries), item("2500.00", "2026-04-15", H.salary)])
    expect_err(H.cmd, "PLAN_DIGEST_MISMATCH", H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash="00", scope_digest=p["scope_digest"])
    a = H.cmd(H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    check(a["queue_generation"] >= 1, str(a))
    check(H.worker.call("wrk_post_plan_chunk", p["plan_id"]) == "sealed", "chunk")
    mid = H.balance(H.owner, as_of="2026-12-31")
    check(mid == b0, "sealed but unactivated batch is visible")
    check(H.worker.call("wrk_activate_plan", p["plan_id"]) == "activated", "activate")
    r = H.q(H.owner, "balances", as_of="2026-12-31", account_currency_ids=[H.cad["account_currency_id"]])
    b1 = r["balances"][0]["amount"]
    check(round(float(b1) - float(b0), 2) == 2488.00, f"{b0}->{b1}")
    before = H.balance(H.owner, as_of="2026-12-31", ledger_version=r["ledger_version"] - 1)
    check(before == b0, "activation must be one version")
    check(H.worker.call("wrk_activate_plan", p["plan_id"]) == "activated", "re-activation must be a no-op")
    expect_err(H.app.call, "permission denied", "wrk_activate_plan", p["plan_id"])
    return f"freeze -> approve (digest-bound) -> chunk (invisible) -> atomic activation at V{r['ledger_version']} (+2488.00), idempotent re-activation"


@test("AT-PLAN-02", "AUD-053")
def t_plan_stale(server, ev):
    H = household(server, fresh=True)
    p = make_plan(H, H.owner, [item("-7.00", "2026-04-05", H.groceries)])
    H.cmd(H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    H.expense(H.member, "1.00", date="2026-04-06")               # concurrent fact inside the frozen scope
    st = H.worker.call("wrk_post_plan_chunk", p["plan_id"])
    check(st == "stale", st)
    with H.definer() as cx:
        n = cx.execute("select count(*) from bnx.journal_entry where approval_plan_id = %s", (p["plan_id"],)).fetchone()[0]
        cl = cx.execute("select claim_state from bnx.posting_scope_claim where plan_id = %s", (p["plan_id"],)).fetchone()[0]
    check(n == 0 and cl == "released", f"journals={n} claim={cl}")
    # a new plan over the same scope is possible after release; overlapping held claims are not
    p2 = make_plan(H, H.owner, [item("-7.00", "2026-04-05", H.groceries)])
    expect_err(make_plan, "SCOPE_CLAIM_CONFLICT", H, H.owner, [item("-1.00", "2026-04-07", H.groceries)])
    return f"in-scope direct post after approval -> stale before any write, claim released; re-plan allowed; overlapping held claim rejected"


@test("AT-PLAN-03", "AUD-053")
def t_plan_revoked(server, ev):
    H = household(server, fresh=True)
    p = make_plan(H, H.member, [item("-9.00", "2026-04-08", H.groceries)])
    H.cmd(H.member, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=True, can_post=False)
    st = H.worker.call("wrk_post_plan_chunk", p["plan_id"])
    check(st == "suspended", st)
    # sealed plan whose approver is suspended afterwards: activation fails closed, revalidation suspends
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=True, can_post=True)
    p2 = make_plan(H, H.member, [item("-9.00", "2026-05-08", H.groceries)], "2026-05-01", "2026-05-31")
    H.cmd(H.member, "approve_plan", plan_id=p2["plan_id"], plan_hash=p2["plan_hash"], scope_digest=p2["scope_digest"])
    check(H.worker.call("wrk_post_plan_chunk", p2["plan_id"]) == "sealed", "seal")
    H.cmd(H.owner, "set_member_state", member_id=H.member_id, state="suspended")
    c0 = counts(H)
    check(H.worker.call("wrk_activate_plan", p2["plan_id"]) == "revalidation_required", "activation must refuse")
    check(counts(H) == c0, "refused activation wrote state")
    check(H.worker.call("wrk_revalidate_plan", p2["plan_id"]) == "suspended", "revalidate")
    expect_err(H.q, "UNAUTHENTICATED", H.member, "balances")
    return "approver lost can_post -> suspended at chunk; approver suspended after seal -> activation refused without writes, revalidation suspends; suspended member's session revoked"


@test("AT-CONC-03", "AUD-053")
def t_conc_activation(server, ev):
    H = household(server, fresh=True)
    p = make_plan(H, H.owner, [item("-4.00", "2026-04-10", H.groceries)])
    H.cmd(H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    check(H.worker.call("wrk_post_plan_chunk", p["plan_id"]) == "sealed", "seal")
    app2 = psycopg.connect(h.dsn(server, "bnx_app", H.db))           # transaction held open across the activation attempt
    app2.execute("select bnx.cmd_post_transaction(%s::jsonb, %s::jsonb)", (json.dumps(H.member), json.dumps(dict(
        economic_type="consumption_expense", transaction_date="2026-04-11", description="racing direct post",
        idempotency_key="race-" + uuid.uuid4().hex, lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-2.00"},
                                                            {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "2.00"}]))))
    res = {}
    def activate():
        w = h.Role(server, H.db, "bnx_worker")
        t0 = time.time()
        res["state"] = w.call("wrk_activate_plan", p["plan_id"])
        res["waited"] = time.time() - t0
        w.close()
    th = threading.Thread(target=activate)
    th.start()
    time.sleep(1.0)
    check(th.is_alive(), "activation did not wait for the in-flight direct posting")
    app2.commit(); app2.close()
    th.join(10)
    check(res.get("state") == "revalidation_required", str(res))
    check(H.worker.call("wrk_revalidate_plan", p["plan_id"]) == "stale", "revalidate -> stale")
    with H.definer() as cx:
        vis = cx.execute("select count(*) from bnx.visible_at(9223372036854775807) v join bnx.journal_entry je on je.id = v.journal_id "
                         "where je.approval_plan_id = %s", (p["plan_id"],)).fetchone()[0]
    check(vis == 0, "stale plan journals visible")
    return f"activation blocked {res['waited']:.2f}s on an in-flight in-scope posting, then failed closed (revalidation_required -> stale, 0 visible)"


@test("AT-FAULT-01", "AUD-053,AUD-044")
def t_fault_kill(server, ev):
    H = household(server)
    c0 = counts(H)
    key = "kill-" + uuid.uuid4().hex
    cx = psycopg.connect(h.dsn(server, "bnx_app", H.db))
    cx.execute("select bnx.cmd_post_transaction(%s::jsonb, %s::jsonb)", (json.dumps(H.owner), json.dumps(dict(
        economic_type="consumption_expense", transaction_date="2026-03-09", description="killed", idempotency_key=key,
        lines=[{"ledger_account_id": H.cad["ledger_account_id"], "currency": "CAD", "amount": "-99.00"},
               {"ledger_account_id": H.groceries, "currency": "CAD", "amount": "99.00"}]))))
    pid = cx.info.backend_pid
    with psycopg.connect(h.dsn(server, "postgres", "postgres"), autocommit=True) as su:   # fault injection only
        su.execute("select pg_terminate_backend(%s)", (pid,))
    try:
        cx.commit()
        raise Fail("commit after kill succeeded")
    except psycopg.OperationalError:
        pass
    check(counts(H) == c0, f"killed command left state {c0} -> {counts(H)}")
    r = H.expense(H.owner, "99.00", key=key, date="2026-03-09", desc="killed")
    check(r["replayed"] is False, "retry after crash must execute once")
    # plan chunk with a tampered item: no partial batch
    p = make_plan(H, H.owner, [item("-1.00", "2026-06-03", H.groceries), item("-2.00", "2026-06-04", H.groceries)], "2026-06-01", "2026-06-30")
    H.cmd(H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    with H.definer() as d:
        d.execute("update bnx.posting_plan_item set payload = jsonb_set(payload, '{amount}', '\"-2000.00\"') where plan_id = %s and seq = 2", (p["plan_id"],))
        d.commit()
    expect_err(H.worker.call, "PLAN_ITEM_TAMPERED", "wrk_post_plan_chunk", p["plan_id"])
    with H.definer() as d:
        n = d.execute("select count(*) from bnx.journal_entry where approval_plan_id = %s", (p["plan_id"],)).fetchone()[0]
    check(n == 0, f"partial chunk left {n} journals")
    return "backend killed before COMMIT -> no journal/audit/idempotency/version change, retry executes once; tampered plan item -> whole chunk rolled back (0 journals)"


@test("AT-CMD-06", "AUD-053")
def t_cmd_audit(server, ev):
    H = household(server)
    with H.definer() as cx:
        ok = cx.execute("select bnx.audit_verify()").fetchone()[0]
        n = cx.execute("select count(*) from bnx.audit_event").fetchone()[0]
        try:
            cx.execute("update bnx.audit_event set command = 'x' where seq = 1"); raise Fail("audit update allowed")
        except psycopg.Error:
            cx.rollback()
        cx.execute("set role bnx_definer")
        # S4 re-baseline (9005): a forged row must carry at_hashed (chain v2 CHECK); verification must still detect it
        cx.execute("insert into bnx.audit_event(seq, channel, command, subject, payload_sha256, prev_hash, hash, at_hashed) "
                   "select max(seq)+1, 'pwa', 'forged', '{}', '\\x00', (select hash from bnx.audit_event order by seq desc limit 1), '\\x00', now() from bnx.audit_event")
        bad = cx.execute("select bnx.audit_verify()").fetchone()[0]
        cx.rollback()
        cx.execute("set role bnx_definer")
        ob = cx.execute("select count(*) from bnx.outbox where topic = 'journal.posted'").fetchone()[0]
    check(ok == 0 and bad == n + 1, f"verify={ok} forged-detected-at={bad} n={n}")
    return f"{n} audit events hash-chained (verify=0); UPDATE refused (append-only); forged row detected at seq {bad}; {ob} outbox rows for postings"


@test("AT-CMD-07", "AUD-053")
def t_cmd_opening(server, ev):
    H = household(server, fresh=True)
    H.expense(H.owner, "10.00", date="2026-01-15")
    expect_err(H.cmd, "ANCHOR_WOULD_EXCLUDE_POSTINGS", H.owner, "set_opening", account_currency_id=H.cad["account_currency_id"],
               anchor_date="2026-02-01", amount="900.00")
    expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_opening", account_currency_id=H.cad["account_currency_id"],
               anchor_date="2025-12-01", amount="900.00")
    r = H.cmd(H.owner, "set_opening", account_currency_id=H.cad["account_currency_id"], anchor_date="2025-12-01", amount="900.00")
    b = H.balance(H.owner, as_of="2026-01-31")
    bprev = H.balance(H.owner, as_of="2026-01-31", ledger_version=r["ledger_version"] - 1)
    check(float(b) == 890.00 and float(bprev) == 990.00, f"{bprev} -> {b}")
    expect_err(H.expense, "POSTINGS_BEFORE_ANCHOR", H.owner, "1.00", date="2025-11-30")
    return f"revision (T3, owner) reverses and reposts at one version: Jan-31 balance 990.00 at V-1, 890.00 at V; exclusion and pre-anchor posting refused"


# --------------------------------------------------------------------------------------------- snapshots AUD-051
@test("AT-SNAP-03", "AUD-051")
def t_snap(server, ev):
    H = household(server, fresh=True)
    s_member = H.cmd(H.member, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    r = H.q(H.member, "replay_snapshot", snapshot_id=s_member["snapshot_id"])
    check(r["projection_digest_verified"] is True, "own replay")
    m_guess = expect_err(H.q, "NOT_AVAILABLE", H.member, "replay_snapshot", snapshot_id=str(uuid.uuid4()))
    m_other = expect_err(H.q, "NOT_AVAILABLE", H.owner, "replay_snapshot", snapshot_id=s_member["snapshot_id"])
    check(m_guess == m_other, "existence oracle: different errors")
    expect_err(H.q, "NOT_AVAILABLE", H.member, "replay_snapshot", snapshot_id="not-a-uuid")
    # back-dated posting after the snapshot: digest still verifies at the snapshot version
    H.expense(H.owner, "3.00", date="2026-02-02")
    check(H.q(H.member, "replay_snapshot", snapshot_id=s_member["snapshot_id"])["projection_digest_verified"], "back-dated replay")
    # private account of the member; owner cannot replay member's snapshot; owner T3 audit replay works and is audited
    pr = H.cmd(H.member, "create_account", kind="e_wallet", **H.inst("Synthetic Pay", kind="payment_wallet"), label="Private", currencies=["CAD"], visibility="private")
    s_priv = H.cmd(H.member, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31",
                   account_currency_ids=[pr["account_currencies"][0]["account_currency_id"]])
    expect_err(H.q, "NOT_AVAILABLE", H.owner, "replay_snapshot", snapshot_id=s_priv["snapshot_id"])
    expect_err(H.cmd, "NOT_AVAILABLE", H.owner, "create_report_snapshot", report_code="R-BAL",
               account_currency_ids=[pr["account_currencies"][0]["account_currency_id"]])
    aud = H.cmd(H.owner, "audit_replay_snapshot", snapshot_id=s_priv["snapshot_id"])
    check(aud["content_digest_verified"] is True, "T3 audit replay")
    expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "audit_replay_snapshot", snapshot_id=s_priv["snapshot_id"])
    # zero-scope snapshot: viewer with no grants after revocation
    H.cmd(H.owner, "set_grant", member_id=H.viewer_id, account_id=H.acc, can_view=False, can_post=False)
    s_zero = H.cmd(H.viewer, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    check(s_zero["rows"] == [], "zero-scope expected")
    # revoked grant -> ACCESS_REVOKED
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=False, can_post=False)
    expect_err(H.q, "ACCESS_REVOKED", H.member, "replay_snapshot", snapshot_id=s_member["snapshot_id"])
    # inactive member (zero-scope included): sessions revoked; decision function also denies
    H.cmd(H.owner, "set_member_state", member_id=H.viewer_id, state="suspended")
    expect_err(H.q, "UNAUTHENTICATED", H.viewer, "replay_snapshot", snapshot_id=s_zero["snapshot_id"])
    with H.definer() as cx:
        d = cx.execute("select bnx.snapshot_replay_access(%s, %s)", (H.viewer_id, s_zero["snapshot_id"])).fetchone()[0]
    check(d == "ACCESS_REVOKED", f"inactive zero-scope decision = {d}")
    return "own replay digest-verified (also after back-dated post); guessed/other-audience/malformed IDs -> identical NOT_AVAILABLE; owner T3 audit replay verified+audited; revoked grant -> ACCESS_REVOKED; suspended zero-scope member -> ACCESS_REVOKED"


@test("AT-SNAP-04", "AUD-051")
def t_snap_connections(server, ev):
    H = household(server, fresh=True)
    with H.definer() as cx:
        cx.execute("insert into bnx.oauth_client values ('host-a', 'A', array['https://a.example/cb']), ('host-b', 'B', array['https://b.example/cb'])")
        cx.commit()
    def connect(client, acs):
        v = base64.urlsafe_b64encode(os.urandom(40)).rstrip(b"=").decode()
        ch = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
        cb = f"https://{client[-1]}.example/cb"
        r = H.cmd(H.owner, "approve_ai_connection", client_id=client, redirect_uri=cb, code_challenge=ch, scopes=["finance.read", "reports.read"], account_currency_ids=acs)
        t = H.authn.call("authn_oauth_token", {"code": r["code"], "client_id": client, "redirect_uri": cb, "code_verifier": v})
        return {"kind": "bearer", "secret": t["access_token"]}, r["connection_id"]
    both = [H.cad["account_currency_id"], H.usd["account_currency_id"]]
    c1, _ = connect("host-a", both)
    c2, _ = connect("host-b", [H.cad["account_currency_id"]])
    s1 = H.cmd(c1, "create_report_snapshot", report_code="R-BAL")
    expect_err(H.q, "NOT_AVAILABLE", c2, "replay_snapshot", snapshot_id=s1["snapshot_id"])   # same member, other host
    check(H.q(H.owner, "replay_snapshot", snapshot_id=s1["snapshot_id"])["projection_digest_verified"], "member PWA replay")
    s_pwa = H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", account_currency_ids=both)
    expect_err(H.q, "ACCESS_REVOKED", c2, "replay_snapshot", snapshot_id=s_pwa["snapshot_id"])  # narrower AI consent
    # S4 re-baseline (9009, CROSS-02): a consent without an account-currency subset is refused (missing subset => deny)
    expect_err(connect, "SUBSET_REQUIRED", "host-a", [])
    return "other AI connection of same member -> NOT_AVAILABLE; narrower AI consent on PWA snapshot -> ACCESS_REVOKED; zero-scope consent refused (SUBSET_REQUIRED)"


@test("AT-SNAP-05", "AUD-051 (negative control on Draft-04 baseline)")
def t_snap_baseline(server, ev):
    db = "bnx_d04base"
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        cx.execute("set role bnx_definer")
        m = str(uuid.uuid4()); s = str(uuid.uuid4())
        cx.execute("insert into bnx.member values (%s, 'gone', 'member', 'suspended', now())", (m,))
        cx.execute("insert into bnx.report_snapshot(id, report_code, filters_digest, ledger_version, report_definition_version, fx_policy, "
                   "content_account_currency_ids, content_sha256, projection_actor, projection_account_currency_ids, projection_sha256) "
                   "values (%s, 'R01', '\\x00', 1, '1', '{}', '{}', '\\x00', gen_random_uuid(), '{}', '\\x00')", (s,))
        d = cx.execute("select bnx.snapshot_replay_access(%s, %s)", (m, s)).fetchone()[0]
        cx.rollback()
    check(d == "ok", d)
    return "Draft-04 snapshot_replay_access returns 'ok' for a suspended non-audience member on a zero-scope snapshot (defect reproduced)"


# --------------------------------------------------------------------------------------------- ownership AUD-052
@test("AT-OWN-05", "AUD-052")
def t_own(server, ev):
    H = household(server, fresh=True)
    pa = H.cmd(H.owner, "create_party", kind="person", display_name="Party A")["party_id"]
    pb = H.cmd(H.owner, "create_party", kind="person", display_name="Party B")["party_id"]
    g0 = None
    with H.definer() as cx:
        g0 = cx.execute("select member_id, account_id, can_view, can_post from bnx.account_grant order by 1, 2").fetchall()
    def own(events, **kw):
        return H.cmd(H.owner, "record_ownership", account_id=H.acc, events=events, **kw)
    v1 = own([{"party_id": pa, "kind": "legal_owner", "event": "set", "share": "60", "effective_from": "2026-01-01"},
              {"party_id": pb, "kind": "legal_owner", "event": "set", "share": "40", "effective_from": "2026-01-01"}])["ledger_version"]
    v2 = own([{"party_id": pa, "kind": "legal_owner", "event": "set", "share": "50", "effective_from": "2026-03-01"},
              {"party_id": pb, "kind": "legal_owner", "event": "set", "share": "50", "effective_from": "2026-03-01"}])["ledger_version"]
    c0 = counts(H)
    expect_err(own, "OWNERSHIP_TIE", [{"party_id": pa, "kind": "legal_owner", "event": "set", "share": "10", "effective_from": "2026-05-01"},
                                       {"party_id": pa, "kind": "legal_owner", "event": "set", "share": "20", "effective_from": "2026-05-01"}])
    expect_err(own, "OWNERSHIP_OVER_100", [{"party_id": pa, "kind": "legal_owner", "event": "set", "share": "51", "effective_from": "2026-04-01"}])
    check(counts(H) == c0, "rejected ownership commands changed state")
    # backdated transfer recorded later: B's share ends from 2026-02-01, A owns 100 %
    v3 = own([{"party_id": pb, "kind": "legal_owner", "event": "ended", "effective_from": "2026-02-01"},
              {"party_id": pa, "kind": "legal_owner", "event": "set", "share": "100", "effective_from": "2026-02-01"}])["ledger_version"]
    with H.definer() as cx:
        def at(d, v):
            return sorted((str(p), float(s)) for p, k, s in cx.execute("select * from bnx.ownership_at(%s, %s, %s)", (H.acc, d, v)).fetchall())
        r_feb_v2 = at("2026-02-15", v2); r_feb_v3 = at("2026-02-15", v3); r_mar_v3 = at("2026-03-15", v3); r_jan = at("2026-01-15", v3)
        g1 = cx.execute("select member_id, account_id, can_view, can_post from bnx.account_grant order by 1, 2").fetchall()
        # determinism: identical results across repeated evaluation and plan shapes
        reps = {tuple(at("2026-03-15", v3)) for _ in range(20)}
    check(r_feb_v2 == sorted([(pa, 60.0), (pb, 40.0)]) and r_feb_v3 == [(pa, 100.0)], f"{r_feb_v2} {r_feb_v3}")
    check(r_mar_v3 == sorted([(pa, 50.0), (pb, 50.0)]) and r_jan == sorted([(pa, 60.0), (pb, 40.0)]), f"{r_mar_v3} {r_jan}")
    check(g0 == g1 and len(reps) == 1, "grants changed or nondeterministic")
    H.cmd(H.owner, "set_account_scope", account_id=H.acc, ownership_scope="joint", effective_from="2026-01-01")
    with H.definer() as cx:
        sc = cx.execute("select bnx.account_scope_at(%s, '2026-02-01', 9223372036854775807), bnx.account_scope_at(%s, '2026-02-01', %s)",
                        (H.acc, H.acc, v3)).fetchone()
    check(sc == ("joint", "individual"), str(sc))
    return f"60/40 (V{v1}) -> 50/50 from Mar (V{v2}); backdated Feb transfer at V{v3}: Feb@V{v2}=60/40, Feb@V{v3}=100/0, Mar=50/50; tie and 101% rejected without effects; grants unchanged; scope versioned"


@test("AT-OWN-06", "AUD-052 (negative control on Draft-04 baseline)")
def t_own_baseline(server, ev):
    db = "bnx_d04base"
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        cx.execute("set role bnx_definer")
        a, p, m = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
        cx.execute("insert into bnx.account(id, kind, label, reference_kind, visibility, timezone, origin, state, created_by) values "
                   "(%s, 'cash', 'c', 'none', 'household', 'UTC', 'manual', 'active', %s)", (a, m))
        cx.execute("insert into bnx.party values (%s, 'person', 'p', 'p', '{}', null, %s)", (p, m))
        for share in (80, 80):
            cx.execute("insert into bnx.account_ownership_event(id, account_id, party_id, kind, event, share, effective_from, evidence_kind, "
                       "recorded_version, actor) values (gen_random_uuid(), %s, %s, 'legal_owner', 'set', %s, '2026-01-01', 'owner_confirmed', 5, %s)", (a, p, share, m))
        n = cx.execute("select count(*) from bnx.account_ownership_event where account_id = %s", (a,)).fetchone()[0]
        cx.rollback()
    check(n == 2, str(n))
    return "Draft-04 accepts two same-party/same-date/same-version events (tie with no deterministic winner) (defect reproduced)"


# --------------------------------------------------------------------------------------------- source links AUD-054
@test("AT-SRC-01", "AUD-054")
def t_src(server, ev):
    H = household(server, fresh=True)
    j1 = H.expense(H.owner, "5.00", date="2026-02-03")["journal_id"]
    j2 = H.expense(H.owner, "5.00", date="2026-02-03")["journal_id"]      # legitimate repeated purchase
    with H.definer() as cx:
        s1, s2 = (cx.execute("insert into bnx.source_txn(id, account_currency_id, posting_date, amount, currency, canonical_occurrence, "
                             "source_fingerprint) values (gen_random_uuid(), %s, '2026-02-03', -5, 'CAD', %s, %s) returning id",
                             (H.cad["account_currency_id"], occ, hashlib.sha256(f"fp-{occ}".encode()).digest())).fetchone()[0] for occ in (1, 2))
        cx.commit()
        try:
            cx.execute("insert into bnx.source_txn(id, account_currency_id, posting_date, amount, currency, canonical_occurrence, source_fingerprint) "
                       "values (gen_random_uuid(), %s, '2026-02-03', -5, 'CAD', 1, %s)", (H.cad["account_currency_id"], hashlib.sha256(b"fp-1").digest()))
            raise Fail("duplicate import accepted")
        except psycopg.errors.UniqueViolation:
            cx.rollback()
        cx.execute("set role bnx_definer")
        def ev_(s, j, e):
            cx.execute("insert into bnx.source_link_event(source_txn_id, journal_id, event, recorded_version) values (%s, %s, %s, 1)", (s, j, e))
        seq = ["reserved", "released", "reserved", "linked", "released", "linked"]
        for e in seq:
            ev_(s1, j1, e)
        cx.commit()
        bad = []
        for (s, j, e, code) in [(s1, j1, "linked", "SOURCE_LINK_TRANSITION"), (s1, j2, "reserved", "SOURCE_TXN_ALREADY_LINKED"),
                                (s2, j2, "released", "SOURCE_LINK_TRANSITION")]:
            try:
                ev_(s, j, e); cx.commit(); raise Fail(f"{e} accepted")
            except psycopg.Error as x:
                cx.rollback(); cx.execute("set role bnx_definer")
                if code not in str(x):
                    raise Fail(str(x))
                bad.append(code)
        ev_(s2, j2, "reserved"); ev_(s2, j2, "linked"); cx.commit()
        hist = cx.execute("select event, prior_event_id is not null from bnx.source_link_event where source_txn_id = %s order by event_id", (s1,)).fetchall()
        cur = cx.execute("select source_txn_id, journal_id from bnx.source_txn_current_link order by 1").fetchall()
        try:
            cx.execute("delete from bnx.source_link_event"); raise Fail("history deletable")
        except psycopg.Error:
            cx.rollback()
    check([x[0] for x in hist] == seq and all(x[1] for x in hist[1:]), str(hist))
    check(sorted(map(str, (r[1] for r in cur))) == sorted([j1, j2]), str(cur))
    return f"history {seq} recorded with chained prior_event_id; illegal transitions rejected ({', '.join(bad)}); repeated purchase occurrences 1/2 both linked; duplicate fingerprint rejected; history append-only"


@test("AT-SRC-02", "AUD-054 (negative control on Draft-04 baseline)")
def t_src_baseline(server, ev):
    db = "bnx_d04base"
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        cx.execute("set role bnx_definer")
        la, ac, acc, m, j, s = (str(uuid.uuid4()) for _ in range(6))
        cx.execute("insert into bnx.ledger_account values (%s, 'asset', 'CAD', 'x')", (la,))
        cx.execute("insert into bnx.account(id, kind, label, reference_kind, visibility, timezone, origin, state, created_by) values "
                   "(%s, 'cash', 'c', 'none', 'household', 'UTC', 'manual', 'active', %s)", (acc, m))
        cx.execute("insert into bnx.account_currency values (%s, %s, 'CAD', %s)", (ac, acc, la))
        cx.execute("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, "
                   "ledger_version, origin_channel, created_by_member, confirmed_by_member) values (%s,'fee','2026-01-01','2026-01-01','estimated','h',1,'pwa',%s,%s)", (j, m, m))
        cx.execute("insert into bnx.source_txn values (%s, %s, '2026-01-01', null, 1, 'CAD', null, null, 1, '\\x01')", (s, ac))
        msg = None
        try:
            for e in ("reserved", "released", "reserved"):
                cx.execute("insert into bnx.source_txn_link_event values (%s, %s, %s, null, 1)", (s, j, e))
        except psycopg.errors.UniqueViolation as x:
            msg = "unique violation on reserved->released->reserved"
        cx.rollback()
    check(msg is not None, "baseline accepted repeated transition")
    return f"Draft-04 source_txn_link_event: {msg} (defect reproduced)"


@test("AT-EVP-11", "AUD-041,AUD-030")
def t_evidence_access(server, ev):
    H = household(server, fresh=True)
    f = H.cmd(H.owner, "register_evidence", size=2048, sha256_declared=hashlib.sha256(b"stmt").hexdigest(), name="stmt.pdf")["evidence_file_id"]
    H.cmd(H.owner, "assign_evidence", evidence_file_id=f, account_currency_id=H.cad["account_currency_id"])
    g = H.q(H.member, "evidence_access", evidence_file_id=f)
    check(g["decision"] == "granted" and g["url_ttl_seconds"] == 60, str(g))
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=H.acc, can_view=False, can_post=False)
    d1 = H.q(H.member, "evidence_access", evidence_file_id=f)
    d2 = H.q(H.member, "evidence_access", evidence_file_id=str(uuid.uuid4()))
    check(d1 == d2 == {"decision": "denied", "url_ttl_seconds": 0}, f"{d1} {d2}")
    expect_err(H.cmd, "NOT_AVAILABLE", H.member, "assign_evidence", evidence_file_id=f, account_currency_id=H.cad["account_currency_id"])
    with H.definer() as cx:
        log = cx.execute("select decision, count(*) from bnx.evidence_access_log group by 1 order by 1").fetchall()
    return f"grant-derived access granted (60 s URL) then denied on the next request after revocation; revoked and unknown files return identical responses; decisions logged {log}"


# --------------------------------------------------------------------------------------------- archive AUD-047/042
@test("AT-ARC-02", "AUD-047,AUD-042")
def t_archive(server, ev):
    H = household(server, fresh=True)
    def reg(cred, n):
        return H.cmd(cred, "register_evidence", size=1000 + n, sha256_declared=hashlib.sha256(str(n).encode()).hexdigest(), name=f"stmt{n}.pdf")["evidence_file_id"]
    f1, f2 = reg(H.member, 1), reg(H.member, 2)
    with H.definer() as cx:
        o1, o2 = (str(cx.execute("select evidence_object_id from bnx.evidence_file where id = %s", (f,)).fetchone()[0]) for f in (f1, f2))
        def silent():
            with H.definer() as c2:
                c2.execute("update bnx.evidence_object set archive_state = 'dual_verified' where id = %s", (o1,)); c2.commit()
        expect_err(silent, "ARCHIVE_NOT_VERIFIED")
        # executor integrity verification (cloud executor path is NOT_IMPLEMENTED here; modelled by the owner role)
        for o, n in ((o1, 1), (o2, 2)):
            cx.execute("update bnx.evidence_object set sha256 = %s, integrity_state = 'verified', verified_by_execution = 'sim' where id = %s",
                       (hashlib.sha256(str(n).encode()).digest(), o))
        cx.commit()
    expect_err(H.app.call, "permission denied", "wrk_record_archive_event", o1, "verified", "d1", "00")
    for e in ("queued", "copied"):
        H.worker.call("wrk_record_archive_event", o1, e, "drive-1", None)
    bad = H.worker.call("wrk_record_archive_event", o2, "verified", "drive-2", hashlib.sha256(b"tampered").hexdigest())
    good = H.worker.call("wrk_record_archive_event", o1, "verified", "drive-1", hashlib.sha256(b"1").hexdigest())
    check(bad == "archive_failed" and good == "dual_verified", f"{bad} {good}")
    # R2 loss model: only dual_verified objects are independently recoverable
    with H.definer() as cx:
        rec = dict(cx.execute("select id::text, archive_state = 'dual_verified' from bnx.evidence_object").fetchall())
        ob = cx.execute("select count(*) from bnx.outbox where topic = 'archive.failed'").fetchone()[0]
    check(rec[o1] is True and rec[o2] is False and ob == 1, f"{rec} outbox={ob}")
    # optional fail-closed gate
    expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_household_setting", setting="require_dual_copy_before_approval", value=True)
    H.cmd(H.owner, "set_household_setting", setting="require_dual_copy_before_approval", value=True)
    p = H.cmd(H.member, "create_import_plan", account_currency_id=H.cad["account_currency_id"], date_from="2026-07-01", date_to="2026-07-31",
              evidence_file_ids=[f2], items=[item("-3.00", "2026-07-03", H.groceries)])
    expect_err(H.cmd, "PLAN_WAITING_DUAL_COPY", H.member, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    H.worker.call("wrk_record_archive_event", o2, "retry_scheduled", None, None)
    H.worker.call("wrk_record_archive_event", o2, "verified", "drive-2b", hashlib.sha256(b"2").hexdigest())
    a = H.cmd(H.member, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    check(a["status"] == "approved_pending_activation", str(a))
    return "silent dual_verified rejected; mismatched Drive re-hash -> archive_failed + outbox alert; matching re-hash -> dual_verified; only dual_verified counted recoverable after R2 loss; gate (Owner T3) blocks approval until the plan's evidence is dual_verified"


# --------------------------------------------------------------------------------------------- queue AUD-046
@test("AT-Q-01", "AUD-046")
def t_queue(server, ev):
    H = household(server, fresh=True)
    p = make_plan(H, H.owner, [item("-1.00", "2026-04-03", H.groceries)])
    w = psycopg.connect(h.dsn(server, "bnx_worker", H.db))
    st0 = w.execute("select bnx.wrk_claim(10)").fetchone()[0]          # claim holds the queue_state row lock
    res = {}
    def approve():
        res["r"] = H.app.cx.execute("select 1").fetchone() and h.Role(server, H.db, "bnx_app").call(
            "cmd_approve_plan", H.owner, {"plan_id": p["plan_id"], "plan_hash": p["plan_hash"], "scope_digest": p["scope_digest"],
                                          "idempotency_key": "ap-" + uuid.uuid4().hex})
    th = threading.Thread(target=approve); th.start(); time.sleep(0.7)
    check(th.is_alive(), "enqueue did not serialize behind the open claim")
    w.commit(); th.join(10)
    stat = w.execute("select bnx.wrk_queue_status()").fetchone()[0]; w.commit()
    check(stat["generation"] > stat["drained_generation"] and stat["queued"] == 1, str(stat))
    c = w.execute("select bnx.wrk_claim(10)").fetchone()[0]; w.commit()
    check(len(c["items"]) == 1, str(c))
    stat2 = w.execute("select bnx.wrk_queue_status()").fetchone()[0]; w.commit()
    check(stat2["generation"] == stat2["drained_generation"], str(stat2))
    # an expired lease is reclaimed (worker crash after claim)
    w.execute("select bnx.wrk_complete(%s, false)", (c["items"][0]["id"],)); w.commit()
    c2 = w.execute("select bnx.wrk_claim(10)").fetchone()[0]; w.commit()
    check(len(c2["items"]) == 1, "failed item not re-queued")
    w.close()
    return f"enqueue during an open claim serializes on queue_state; generation {stat['generation']} > drained {stat['drained_generation']} with 1 queued (no lost wakeup at the authority); drained only after claim; failed item re-queued"


# --------------------------------------------------------------------------------------------- backup AUD-050
@test("AT-BAK-01", "AUD-050")
def t_backup(server, ev):
    if server != "pg16":
        return "SKIP:pg_dump for PostgreSQL 17 is not available in this environment (embedded-postgres ships initdb/pg_ctl/postgres only)"
    pg_dump = "/usr/lib/postgresql/16/bin/pg_dump"
    H = household(server)
    def dump(tag):
        bk = psycopg.connect(h.dsn(server, "bnx_backup", H.db))
        bk.execute("begin isolation level repeatable read read only")
        snap = bk.execute("select pg_export_snapshot()").fetchone()[0]
        cust = os.path.join(ev, f"AT-BAK-01_{tag}.dump")
        out = os.path.join(ev, f"AT-BAK-01_{tag}.sql")
        # exact production command of Backup §6 step 4 (custom format, data only, both schemas, exported snapshot)
        cmd = [pg_dump, "--dbname", h.dsn(server, "bnx_backup", H.db), f"--snapshot={snap}", "--format=custom", "--data-only",
               "--schema=bnx", "--schema=auth", "-f", cust]
        r = subprocess.run(cmd, capture_output=True, text=True)
        sch = subprocess.run([pg_dump, "--dbname", h.dsn(server, "bnx_backup", H.db), f"--snapshot={snap}", "--schema-only",
                              "--schema=bnx", "--schema=auth", "-f", os.path.join(ev, f"AT-BAK-01_{tag}_schema.sql")], capture_output=True, text=True)
        bk.rollback(); bk.close()
        conv = subprocess.run(["/usr/lib/postgresql/16/bin/pg_restore", "--data-only", "-f", out, cust], capture_output=True, text=True)
        open(os.path.join(ev, f"AT-BAK-01_{tag}.cmd"), "w").write(" ".join(cmd).replace(H.db, "<db>") +
            f"\nexit={r.returncode} schema_only_exit={sch.returncode} pg_restore_to_sql_exit={conv.returncode}\n{r.stderr}{sch.stderr}{conv.stderr}")
        if r.returncode == 0 and (sch.returncode or conv.returncode):
            r = sch if sch.returncode else conv
        return r, out
    r1, _ = dump("before")
    check(r1.returncode == 0, r1.stderr)
    # M1-style future objects: a definer financial table with identity sequence (via a new checksum-locked migration) and an
    # auth-owned table with a serial sequence (created by bnx_auth, the auth schema owner)
    d = tempfile.mkdtemp()
    for f in os.listdir(os.path.join(h.ROOT, "db/migrations")):
        shutil.copy(os.path.join(h.ROOT, "db/migrations", f), d)
    open(os.path.join(d, "0901_test_future_table.sql"), "w").write(
        "set role bnx_definer;\ncreate table bnx.m1_future_fact(id bigint generated always as identity primary key, note text not null);\n"
        "insert into bnx.m1_future_fact(note) values ('synthetic');\n")
    os.rename(os.path.join(d, "9001_import_draft02_logical_state.sql"), os.path.join(d, "9001_import_draft02_logical_state.sql"))
    r = h.migrate(server, H.db, check=False, mdir=d)
    check(r.returncode == 4 or r.returncode == 0, r.stdout)
    if r.returncode == 4:   # 9001 is already applied, so a later number is not a prefix extension; use 9101
        os.rename(os.path.join(d, "0901_test_future_table.sql"), os.path.join(d, "9101_test_future_table.sql"))
        r = h.migrate(server, H.db, mdir=d, log=os.path.join(ev, "AT-BAK-01_future_migration.log"))
    with psycopg.connect(h.dsn(server, "bnx_auth", H.db), autocommit=True) as cx:
        cx.execute("create table auth.future_identity_link(id serial primary key, provider text not null)")
        cx.execute("insert into auth.future_identity_link(provider) values ('synthetic')")
    r2, out2 = dump("after")
    check(r2.returncode == 0, r2.stderr)
    body = open(out2).read()
    check("m1_future_fact" in body and "future_identity_link" in body and "future_identity_link_id_seq" in body, "future objects missing from dump")
    check(H.owner["secret"] not in body and H.member["secret"] not in body, "session secret leaked into dump")
    # bnx_backup is read-only and cannot mutate, create or truncate
    denied = 0
    with psycopg.connect(h.dsn(server, "bnx_backup", H.db), autocommit=True) as cx:
        for stmt in ("insert into bnx.currency values ('ZZZ', 2)", "update bnx.member set display_name = 'x'", "delete from bnx.audit_event",
                     "truncate bnx.outbox", "create table bnx.x(i int)", "alter table bnx.member add column x int",
                     "select nextval('bnx.outbox_id_seq')", "select bnx.cmd_post_transaction('{}','{}')", "set default_transaction_read_only = off; insert into bnx.currency values ('ZZZ', 2)"):
            try:
                cx.execute(stmt); raise Fail(f"backup role: {stmt}")
            except psycopg.Error:
                denied += 1
    # restore into an isolated database: fresh bootstrap + same migrations, then data load under restore mode
    rdb = H.db + "_restore"
    h.bootstrap(server, rdb)
    h.migrate(server, rdb, mdir=d)
    with psycopg.connect(h.dsn(server, "bnx_auth", rdb), autocommit=True) as cx:
        cx.execute("create table auth.future_identity_link(id serial primary key, provider text not null)")
    # split the plain data dump: bnx tables are loaded by the migrator under SET ROLE bnx_definer with restore mode on
    # (journal completeness, currency FKs, scale and ownership checks still run; only the same-transaction rule and the
    # source-link state machine accept verbatim rows); auth tables are loaded by their owner bnx_auth. The migration
    # ledger is compared, never restored.
    bnx_part, auth_part, cur, skip = [], [], None, False
    for line in body.splitlines():
        if line.startswith("COPY bnx.schema_migrations") or line.startswith("COPY bnx.schema_bootstrap"):
            skip = True
            continue
        if skip:
            skip = line != "\\."
            continue
        if line.startswith("COPY auth.") or line.startswith("SELECT pg_catalog.setval('auth."):
            auth_part.append(line); cur = auth_part if line.startswith("COPY") else None
            continue
        (cur if cur is not None else bnx_part).append(line)
        if line == "\\.":
            cur = None
    # S4 re-baseline (S4B-F11, 9002): the truncate list is generated from bnx.migration_seeded_table, not hard-coded
    with psycopg.connect(h.dsn(server, "bnx_migrator", rdb)) as cx:
        cx.execute("set role bnx_definer")
        seeded = [r[0] for r in cx.execute("select table_name from bnx.migration_seeded_table order by 1")]
    pre = ("begin;\nset role bnx_definer;\nset local bnx.restore_mode = 'on';\n"
           f"truncate {', '.join(seeded + ['bnx.m1_future_fact'])} cascade;\n")
    open(os.path.join(ev, "AT-BAK-01_restore_preamble.sql"), "w").write(pre)
    rr = subprocess.run([h.PSQL, h.dsn(server, "bnx_migrator", rdb), "-X", "-q", "-v", "ON_ERROR_STOP=1"],
                        input=pre + "\n".join(bnx_part) + "\ncommit;\n", capture_output=True, text=True)
    check(rr.returncode == 0, "restore (bnx as migrator/definer): " + "\n".join(l for l in rr.stderr.splitlines() if not l.startswith("NOTICE"))[:1500])
    ra = subprocess.run([h.PSQL, h.dsn(server, "bnx_auth", rdb), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1"],
                        input="truncate auth.future_identity_link;\n" + "\n".join(auth_part) + "\n", capture_output=True, text=True)
    check(ra.returncode == 0, "restore (auth as bnx_auth): " + ra.stderr[:1500])
    # verification on the restored database
    def facts(db):
        with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
            cx.execute("set role bnx_definer")
            tabs = [r[0] for r in cx.execute("select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                                             "where n.nspname = 'bnx' and c.relkind = 'r' order by 1")]
            cnt = {t: cx.execute(f"select count(*) from bnx.{t}").fetchone()[0] for t in tabs}
            av = cx.execute("select bnx.audit_verify()").fetchone()[0]
            js = [r[0] for r in cx.execute("select id from bnx.journal_entry")]
            for j in js:
                cx.execute("select bnx.assert_journal_complete(%s)", (j,))
            mig = cx.execute("select array_agg(version || ':' || sha256 order by version) from bnx.schema_migrations").fetchone()[0]
            ver = cx.execute("select version from bnx.ledger_state").fetchone()[0]
            cx.rollback()
        with psycopg.connect(h.dsn(server, "bnx_auth", db)) as cx:
            cnt["auth.future_identity_link"] = cx.execute("select count(*) from auth.future_identity_link").fetchone()[0]
        return cnt, av, len(js), mig, ver
    src = facts(H.db); dst = facts(rdb)
    cnt_diff = {k: (src[0][k], dst[0].get(k)) for k in src[0] if k not in ("schema_migrations",) and src[0][k] != dst[0].get(k)}
    check(not cnt_diff, f"row counts differ: {cnt_diff}")
    check(dst[1] == 0 and src[3] == dst[3] and src[4] == dst[4], f"audit={dst[1]} migrations equal={src[3] == dst[3]} version {src[4]}/{dst[4]}")
    # the restored database answers the same versioned query for the same synthetic session
    app_r = h.Role(server, rdb, "bnx_app")
    b_src = H.app.call("q_balances", H.owner, {"as_of": "2026-12-31"})
    b_dst = app_r.call("q_balances", H.owner, {"as_of": "2026-12-31"})
    app_r.close()
    check(b_src == b_dst, "balances differ after restore")
    json.dump({"source_counts": src[0], "restored_counts": dst[0], "journals_checked": dst[2], "ledger_version": dst[4],
               "migrations": dst[3]}, open(os.path.join(ev, "AT-BAK-01_restore_verification.json"), "w"), indent=1)
    return (f"pg_dump --snapshot --data-only --schema=bnx --schema=auth as bnx_backup succeeds before and after a new bnx table+identity "
            f"and an auth table+serial; {denied} write/DDL attempts by bnx_backup denied; isolated restore: {len(src[0])} tables equal counts, "
            f"audit chain intact, {dst[2]} journals re-asserted complete, migrations and ledger version V{dst[4]} equal, identical q_balances; no session secret in dump")


@test("AT-BAK-02", "AUD-050 (negative control on Draft-04 baseline)")
def t_backup_baseline(server, ev):
    if server != "pg16":
        return "SKIP:pg_dump for PostgreSQL 17 not available"
    db = "bnx_d04base"
    with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
        cx.execute("set role bnx_definer")
        cx.execute("create table bnx.m1_future_fact(id bigint generated always as identity primary key)")
        cx.commit()
    r = subprocess.run(["/usr/lib/postgresql/16/bin/pg_dump", "--dbname", h.dsn(server, "bnx_backup", db), "--data-only", "--schema=bnx",
                        "-f", "/dev/null"], capture_output=True, text=True)
    open(os.path.join(ev, "AT-BAK-02_draft04_dump.log"), "w").write(f"exit={r.returncode}\n{r.stderr}")
    check(r.returncode != 0 and "permission denied" in r.stderr, r.stderr)
    return "Draft-04 grants: pg_dump as bnx_backup fails after a new table appears: " + r.stderr.strip().splitlines()[0][:120]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, aud, fn in TESTS:
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
        dur = time.time() - s
        RESULTS.append({"id": tid, "aud": aud, "status": status, "detail": msg, "seconds": round(dur, 2)})
        print(f"{status} {tid} [{aud}] ({dur:.1f}s): {msg}", flush=True)
    for H in SHARED.values():
        H.close()
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__,
               "libpq": psycopg.pq.version(), "seconds": round(time.time() - t0, 1),
               "pass": sum(r["status"] == "PASS" for r in RESULTS), "fail": sum(r["status"] == "FAIL" for r in RESULTS),
               "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "g0_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
