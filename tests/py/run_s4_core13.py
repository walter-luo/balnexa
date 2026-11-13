#!/usr/bin/env python3
"""S4 V1.2 increment 13 tests: 9016 backup/DR registries, header facts and the generated restore preamble, restore drills,
key custody (K2 fingerprints), audit anchor (9011R R-11), evidence re-hash, usage ledger, capacity and admission (UA V1.2
§9.2-§9.5; Draft-04 Backup and DR §3-§10; Cloud Cost and Quota Model §5-§7). Synthetic data only; no cloud resource and no
real key is used: fingerprints are SHA-256 values of synthetic strings.
Usage: run_s4_core13.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, datetime as dt, hashlib, json, os, subprocess, sys, time, traceback, uuid
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
import run_s4_core12 as C12
from run_g0 import expect_err, pg_tool

RESULTS, TESTS = [], []
check = C1.check
UTC = dt.timezone.utc


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def fp(label):
    """synthetic recipient fingerprint (never a real age key)"""
    return hashlib.sha256(("synthetic-age-recipient:" + label).encode()).hexdigest()


def hx(label):
    return hashlib.sha256(label.encode()).hexdigest()


def iso(t):
    return t.astimezone(UTC).isoformat()


def definer_one(H, q, p=None):
    with H.definer() as cx:
        return cx.execute(q, p).fetchone()


def facts(server, db, snapshot=None):
    """header facts as bnx_backup inside a REPEATABLE READ READ ONLY transaction (UA §9.3 step 3)"""
    h.role_slot(server, "bnx_backup")   # the limit is 2: wait for a closed backend to exit
    with psycopg.connect(h.dsn(server, "bnx_backup", db)) as cx:
        cx.execute("begin isolation level repeatable read read only")
        if snapshot:
            cx.execute(f"set transaction snapshot '{snapshot}'")
        f = cx.execute("select bnx.bkp_header_facts()").fetchone()[0]
        cx.rollback()
        return f


def compare(server, db, a, b):
    h.role_slot(server, "bnx_backup")   # the limit is 2: wait for a closed backend to exit
    with psycopg.connect(h.dsn(server, "bnx_backup", db)) as cx:
        return cx.execute("select bnx.bkp_header_compare(%s::jsonb, %s::jsonb)", (json.dumps(a), json.dumps(b))).fetchone()[0]


def keys(H, drill="drill-2026a", owner="owner-k2"):
    o = H.cmd(H.owner, "backup_key_register", key_id=owner, role="OWNER", recipient_fingerprint_sha256=fp(owner))
    d = H.cmd(H.owner, "backup_key_register", key_id=drill, role="DRILL", recipient_fingerprint_sha256=fp(drill))
    return o, d


def tier(H, t):
    return definer_one(H, "select bnx.backup_tier(%s::timestamptz)", (iso(t),))[0]


def backup_payload(H, st, drill="drill-2026a", owner="owner-k2", header=None, **over):
    t = tier(H, st)
    run = str(uuid.uuid4())
    p = {"run_id": run, "started_at": iso(st), "ended_at": iso(st + dt.timedelta(seconds=95)), "local_date": t["local_date"],
         "tier": t["tier"], "retain_until": t["retain_until"], "destination": "OFF_PROVIDER", "outcome": "VERIFIED",
         "object": {"generation": "1700000000000001"},
         "sizes": {"compressed_kib": 4_883, "wire_kib": 19_532},
         "dump_sha256": hx("dump" + run), "plaintext_sha256": hx("plain" + run), "header_sha256": hx("header" + run),
         "tools": {"pg_dump": "17.2", "pg_restore": "17.2", "server": "17.11"},
         "verify": {"redownload_sha256_equal": True, "pg_restore_list_ok": True, "decrypted_with": drill},
         "recipients": {"owner_key_id": owner, "owner_fingerprint_sha256": fp(owner), "drill_key_id": drill, "drill_fingerprint_sha256": fp(drill)},
         "header": header if header is not None else facts(H.server, H.db)}
    for k, v in over.items():
        if v is None:
            p.pop(k, None)
        else:
            p[k] = v
    return p


def promote(H, job, kind, payload):
    s = C4.stage(H, job, kind, payload)
    st = H.worker.call("wrk_promote_staged", s["staging_id"])
    res = definer_one(H, "select result from bnx_intake.staging_payload where id = %s", (s["staging_id"],))[0]
    return st, res, s["staging_id"]


def backup(H, st, **kw):
    return promote(H, "BACKUP", "backup_recorded", backup_payload(H, st, **kw))


def drill_payload(H, run_id, key="drill-2026a", header=None, st=None, **over):
    st = st or dt.datetime.now(UTC)
    if header is None:
        header = definer_one(H, "select header_facts from bnx.backup_run where run_id = %s", (run_id,))[0]
    p = {"drill_id": str(uuid.uuid4()), "backup_run_id": run_id, "kind": "DRILL", "target": "ISOLATED_DRILL", "decrypt_key_id": key,
         "started_at": iso(st), "ended_at": iso(st + dt.timedelta(seconds=420)), "outcome": "PASS", "restored_header": header,
         "cleanup_verified": True, "tools": {"pg_restore": "17.2", "server": "17.11"}}
    for k, v in over.items():
        if v is None:
            p.pop(k, None)
        else:
            p[k] = v
    return p


def drill(H, run_id, **kw):
    return promote(H, "RESTORE_DRILL", "restore_drill_recorded", drill_payload(H, run_id, **kw))


def notes(H, kind):
    with H.definer() as cx:
        return [r[0] for r in cx.execute("select minimal_metadata->>'record_key' from bnx_intake.notification where kind = 'EXCEPTION' "
                                         "and minimal_metadata->>'kind' = %s order by created_at", (kind,))]


def world(server, db):
    H = C12.world(server, db)
    return H


# ------------------------------------------------------------------------------------------- consistent backup and restore
def scope_tables(cx):
    return [tuple(r) for r in cx.execute(
        "select ns.nspname, c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace "
        "where ns.nspname in (select nspname from bnx.schema_registry) and c.relkind = 'r' and not c.relispartition "
        "and not (ns.nspname = 'bnx' and c.relname in ('schema_migrations','schema_bootstrap')) order by 1, 2").fetchall()]


def fk_order(cx, tabs):
    """tables ordered so that every FK target is loaded before its referrers (self references are checked per statement)"""
    deps = {t: set() for t in tabs}
    for a, b, c, d in cx.execute("select sn.nspname, s.relname, tn.nspname, t.relname from pg_constraint k "
                                 "join pg_class s on s.oid = k.conrelid join pg_namespace sn on sn.oid = s.relnamespace "
                                 "join pg_class t on t.oid = k.confrelid join pg_namespace tn on tn.oid = t.relnamespace where k.contype = 'f'"):
        if (a, b) in deps and (c, d) in deps and (a, b) != (c, d):
            deps[(a, b)].add((c, d))
    out, done = [], set()
    while len(out) < len(tabs):
        ready = sorted(t for t in tabs if t not in done and deps[t] <= done)
        check(ready, f"FK cycle among {sorted(set(tabs) - done)[:10]}")
        out += ready; done |= set(ready)
    return out


def copy_dump(server, db, snap):
    """data of every in-scope table read with COPY inside the exported snapshot (the same snapshot pg_dump --snapshot uses);
    bnx_audit.audit_event in seq order (R-10); sequence positions"""
    h.role_slot(server, "bnx_backup")   # the limit is 2: wait for a closed backend to exit
    with psycopg.connect(h.dsn(server, "bnx_backup", db)) as cx:
        cx.execute("begin isolation level repeatable read read only")
        cx.execute(f"set transaction snapshot '{snap}'")
        tabs = scope_tables(cx)
        data = {}
        for s, t in tabs:
            order = " order by seq" if (s, t) == ("bnx_audit", "audit_event") else ""
            with cx.cursor().copy(f'copy (select * from "{s}"."{t}"{order}) to stdout') as cp:
                data[(s, t)] = b"".join(bytes(b) for b in cp)
        seqs = {}
        for s, q in cx.execute("select ns.nspname, c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace "
                               "where ns.nspname in (select nspname from bnx.schema_registry) and c.relkind = 'S' order by 1, 2").fetchall():
            seqs[(s, q)] = cx.execute(f'select last_value, is_called from "{s}"."{q}"').fetchone()
        cx.rollback()
    return data, seqs


def new_target(server, db):
    h.bootstrap(server, db)
    h.migrate(server, db)


def copy_restore(server, rdb, data, seqs):
    with psycopg.connect(h.dsn(server, "bnx_migrator", rdb)) as cx:
        cx.execute("set role bnx_definer")
        pre = cx.execute("select bnx.restore_preamble()").fetchone()[0]
        cx.rollback()
        cx.execute(pre["sql"])
        order = fk_order(cx, [t for t in data if t[0] != "auth"])
        for s, t in order:
            if data[(s, t)]:
                with cx.cursor().copy(f'copy "{s}"."{t}" from stdin') as cp:
                    cp.write(data[(s, t)])
        n_seq = 0
        for (s, q), (last, called) in seqs.items():
            if s != "auth" and cx.execute("select pg_get_userbyid(relowner) = 'bnx_definer' from pg_class where oid = to_regclass(%s)",
                                          (f'"{s}"."{q}"',)).fetchone()[0]:
                cx.execute("select setval(%s::regclass, %s, %s)", (f'"{s}"."{q}"', last, called)); n_seq += 1
        cx.commit()
    auth = [t for t in data if t[0] == "auth" and data[t]]
    if auth:
        with psycopg.connect(h.dsn(server, "bnx_auth", rdb)) as cx:
            for s, t in auth:
                with cx.cursor().copy(f'copy "{s}"."{t}" from stdin') as cp:
                    cp.write(data[(s, t)])
            cx.commit()
    return pre, n_seq


def pgdump_restore(server, db, rdb, snap, ev):
    """the UA §9.3 step 4 command (pg_dump --snapshot, custom, data only, every registered schema) + pg_restore of the same
    major; loaded with the generated preamble (R-10 seq order for the audit chain)"""
    pg_dump, pg_restore = pg_tool(server, "pg_dump"), pg_tool(server, "pg_restore")
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        pre = cx.execute("select bnx.restore_preamble()").fetchone()[0]
    cust, out = os.path.join(ev, "AT-BAK-04_data.dump"), os.path.join(ev, "AT-BAK-04_data.sql")
    h.role_slot(server, "bnx_backup")   # the limit is 2: wait for a closed backend to exit
    r = subprocess.run([pg_dump, "--dbname", h.dsn(server, "bnx_backup", db), f"--snapshot={snap}", *pre["pg_dump_args"], "-f", cust],
                       capture_output=True, text=True)
    check(r.returncode == 0, "pg_dump: " + r.stderr[:600])
    lst = subprocess.run([pg_restore, "--list", cust], capture_output=True, text=True)
    conv = subprocess.run([pg_restore, "--data-only", "-f", out, cust], capture_output=True, text=True)
    check(lst.returncode == 0 and conv.returncode == 0, lst.stderr + conv.stderr)
    lines, body, k = open(out).read().splitlines(), [], 0
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
    bnx_part, auth_part, skip, cur = [], [], False, None
    never = tuple("COPY " + t + " " for t in pre["never_load"])
    for line in body:
        if line.startswith(never):
            skip = True; continue
        if skip:
            skip = line != "\\."; continue
        if line.startswith("COPY auth.") or line.startswith("SELECT pg_catalog.setval('auth."):
            auth_part.append(line); cur = auth_part if line.startswith("COPY") else None; continue
        (cur if cur is not None else bnx_part).append(line)
        if line == "\\.":
            cur = None
    rr = subprocess.run([h.PSQL, h.dsn(server, "bnx_migrator", rdb), "-X", "-q", "-v", "ON_ERROR_STOP=1"],
                        input="begin;\n" + pre["sql"] + "\n".join(bnx_part) + "\ncommit;\n", capture_output=True, text=True)
    check(rr.returncode == 0, "restore: " + "\n".join(l for l in rr.stderr.splitlines() if not l.startswith("NOTICE"))[:1500])
    if auth_part:
        ra = subprocess.run([h.PSQL, h.dsn(server, "bnx_auth", rdb), "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1"], input="\n".join(auth_part) + "\n",
                            capture_output=True, text=True)
        check(ra.returncode == 0, "restore auth: " + ra.stderr[:800])
    return {"pg_dump": subprocess.run([pg_dump, "--version"], capture_output=True, text=True).stdout.strip(),
            "pg_restore_list_entries": len([l for l in lst.stdout.splitlines() if l and not l.startswith(";")])}


def post_checks(server, rdb):
    with psycopg.connect(h.dsn(server, "bnx_migrator", rdb)) as cx:
        cx.execute("set role bnx_definer")
        av = cx.execute("select bnx.audit_verify()").fetchone()[0]
        js = [r[0] for r in cx.execute("select id from bnx.journal_entry")]
        for j in js:
            cx.execute("select bnx.assert_journal_complete(%s)", (j,))
        cx.rollback()
    return av, len(js)


@test("AT-BAK-04", "S4B-F10/F11; UA V1.2 §9.3 steps 2-4, 6, 9 (header facts in the snapshot; concurrent write; generated preamble; all schemas)")
def t_consistent(server, ev):
    H = world(server, "bnx_c13bak")
    H.cmd(H.owner, "register_evidence", size=2048, sha256_declared=hx("stmt"), name="stmt.pdf")
    bal_before = H.app.call("q_balances", H.owner, {"as_of": "2026-12-31"})
    # steps 1-3: bnx_backup, REPEATABLE READ READ ONLY, exported snapshot, header facts in that transaction
    h.role_slot(server, "bnx_backup")
    bk = psycopg.connect(h.dsn(server, "bnx_backup", H.db))
    bk.execute("begin isolation level repeatable read read only")
    snap = bk.execute("select pg_export_snapshot()").fetchone()[0]
    header = bk.execute("select bnx.bkp_header_facts()").fetchone()[0]
    # a concurrent posting after the snapshot (committed while the export transaction stays open)
    C12.post(H, "consumption_expense", "2026-02-02", [(H.groceries, "7.00"), (H.cad["ledger_account_id"], "-7.00")])
    live = facts(server, H.db)
    paths = {}
    data, seqs = copy_dump(server, H.db, snap)
    pgd = None
    if os.path.exists(pg_tool(server, "pg_dump")) and os.path.exists(pg_tool(server, "pg_restore")):
        rdb2 = H.db + "_pgd"
        new_target(server, rdb2)
        pgd = pgdump_restore(server, H.db, rdb2, snap, ev)
    bk.rollback(); bk.close()   # step 6: the exporting transaction ends only after every dump finished
    # restore through the generated preamble (copy path; both majors) and, when available, the pg_dump path
    rdb = H.db + "_cp"
    new_target(server, rdb)
    pre, n_seq = copy_restore(server, rdb, data, seqs)
    restored = {"copy": rdb} | ({"pg_dump": H.db + "_pgd"} if pgd else {})
    for name, db in restored.items():
        f = facts(server, db)
        paths[name] = {"mismatch": compare(server, db, header, f), "post": post_checks(server, db)}
        app_r = h.Role(server, db, "bnx_app")
        paths[name]["balances_equal"] = app_r.call("q_balances", H.owner, {"as_of": "2026-12-31"}) == bal_before
        app_r.close()
    # the preamble refuses a database that holds data (it never overwrites a live instance)
    with psycopg.connect(h.dsn(server, "bnx_migrator", H.db)) as cx:
        try:
            cx.execute(pre["sql"]); refused = "accepted"
        except psycopg.Error as e:
            refused = (e.diag.message_primary or str(e))[:60]
        cx.rollback()
    H.close()
    json.dump({"header": header, "live_mismatch_vs_header": compare(server, rdb, header, live), "paths": paths, "preamble": pre,
               "pg_dump": pgd, "refused": refused}, open(os.path.join(ev, "AT-BAK-04.json"), "w"), indent=1, default=str)
    lm = compare(server, rdb, header, live)
    check("ledger_version" in lm and "tables.bnx.journal_line" in lm, f"concurrent write not visible in the live facts: {lm}")
    for name, r in paths.items():
        check(r["mismatch"] == [] and r["post"][0] == 0 and r["balances_equal"], f"{name}: {r}")
    check(set(header["schemas"]) == {"auth", "bnx", "bnx_audit", "bnx_doc", "bnx_fed", "bnx_intake", "bnx_rpt", "bnx_tax"}
          and len(pre["pg_dump_args"]) == 10 and "bnx.cost_policy" in pre["truncate"] and refused.startswith("RESTORE_TARGET_NOT_EMPTY"), f"{pre} {refused}")
    return (f"header facts read by bnx_backup in the exported snapshot ({len(header['tables'])} tables, {header['row_total']} rows, ledger V{header['ledger_version']}, "
            f"audit head {header['audit_head']['seq']}); a posting committed during the dump changes the live facts ({lm[:3]}...) but not the dump; "
            f"restored via the generated preamble ({len(pre['truncate'])} seeded tables truncated, {len(pre['schemas'])} schemas, {n_seq} sequences set) "
            f"on paths {sorted(paths)}: recomputed facts equal the header (bkp_header_compare = []), audit_verify 0, "
            f"{paths['copy']['post'][1]} journals re-asserted, q_balances equal to the pre-write state; "
            + (f"pg_dump path {pgd['pg_dump']} ({pgd['pg_restore_list_entries']} pg_restore --list entries); " if pgd else
               f"pg_dump path SKIPPED: pg_dump {server[2:]} not available here (CI runs it); ")
            + f"preamble on a live database -> {refused}")


@test("AT-BAK-03", "ADO-004; UA V1.2 §9.3 step 9 (restore mode is the migrator's only; a runtime role with the GUC is still refused)")
def t_restore_mode_negative(server, ev):
    H = C4.v2_full(server, "bnx_c13rm")        # International = NO
    out = {}
    for role in ("bnx_app",):
        R = h.Role(server, H.db, role)
        R.cx.execute("set bnx.restore_mode = 'on'")
        out[role + " create CN account"] = expect_err(R.call, "SCOPE_DISABLED", "cmd_create_account", H.owner,
                                                      {"kind": "bank_deposit", "institution_code": "BOC", "label": "x", "currencies": ["CNY"],
                                                       "idempotency_key": C4.F.new_key()})
        R.close()
    W = h.Role(server, H.db, "bnx_worker")
    W.cx.execute("set bnx.restore_mode = 'on'")
    out["bnx_worker staging promote of a forged id"] = W.call("wrk_promote_staged", str(uuid.uuid4()))
    W.close()
    with psycopg.connect(h.dsn(server, "bnx_migrator", H.db)) as cx:
        cx.execute("set role bnx_definer")
        on_without = cx.execute("select bnx.restore_mode()").fetchone()[0]
        cx.execute("set bnx.restore_mode = 'on'")
        on_with = cx.execute("select bnx.restore_mode()").fetchone()[0]
    H.close()
    check(on_without is False and on_with is True and out["bnx_worker staging promote of a forged id"] == "not_found", f"{out} {on_without} {on_with}")
    return f"with bnx.restore_mode = on in a bnx_app session the S4 flag trigger still refuses ({out['bnx_app create CN account'][:40]}); restore_mode() is true only for the migrator with the GUC ({on_without} -> {on_with})"


# ------------------------------------------------------------------------------------------- backup promoter (K2, anchor)
@test("AT-BKP-REC", "UA V1.2 §9.3 steps 7-8; S4B-F24; R-11; AT-NEON-04 (backup_recorded promoter: K2 recipients, majors, verification, anchor)")
def t_backup_recorded(server, ev):
    H = world(server, "bnx_c13rec")
    out = {"due without keys": H.worker.call("wrk_backup_due", {})["reason"]}
    out["member registers a key"] = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "backup_key_register", key_id="drill-x", role="DRILL", recipient_fingerprint_sha256=fp("x"))
    out["key material refused"] = expect_err(H.cmd, "KEY_MATERIAL_REFUSED", H.owner, "backup_key_register", key_id="drill-y", role="DRILL",
                                             recipient_fingerprint_sha256=fp("y"), note="AGE-SECRET-KEY-1SYNTHETICNOTAKEY")
    out["bad fingerprint"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "backup_key_register", key_id="drill-z", role="DRILL", recipient_fingerprint_sha256="abc")
    keys(H)
    due = H.worker.call("wrk_backup_due", {})
    now = dt.datetime.now(UTC)
    neg = {}
    hdr_full = facts(server, H.db)
    for name, over, code in (
            ("unknown field", {"secret": "x"}, "UNKNOWN_FIELD"),
            ("header without format", {"header": {k: v for k, v in hdr_full.items() if k != "format"}}, "HEADER"),            # 9039
            ("header without audit_head", {"header": {k: v for k, v in hdr_full.items() if k != "audit_head"}}, "HEADER"),    # 9039
            ("private key in payload", {"object": {"generation": "AGE-SECRET-KEY-1SYNTHETIC"}}, "KEY_MATERIAL_REFUSED"),
            ("object path sent", {"object": {"name": "bnx-vault-backups/x.age", "generation": "1"}}, "UNKNOWN_FIELD"),
            ("size in bytes", {"sizes": {"compressed_bytes": 5_000_000}}, "UNKNOWN_FIELD"),
            ("tier mismatch", {"tier": "MONTHLY" if tier(H, now)["tier"] != "MONTHLY" else "DAILY"}, "TIER_MISMATCH"),
            ("retention shorter", {"retain_until": iso(now + dt.timedelta(days=1))}, "RETENTION_SHORT"),
            ("pg_dump 16 on server 17", {"tools": {"pg_dump": "16.4", "pg_restore": "16.4", "server": "17.11"}}, "TOOL_MAJOR"),
            ("pg_restore of another major", {"tools": {"pg_dump": "17.2", "pg_restore": "16.4", "server": "17.11"}}, "TOOL_MAJOR"),
            ("not re-downloaded", {"verify": {"redownload_sha256_equal": False, "pg_restore_list_ok": True, "decrypted_with": "drill-2026a"}}, "NOT_VERIFIED"),
            ("decrypted with the Owner key", {"verify": {"redownload_sha256_equal": True, "pg_restore_list_ok": True, "decrypted_with": "owner-k2"}}, "NOT_VERIFIED"),
            ("no drill recipient", {"recipients": {"owner_key_id": "owner-k2", "owner_fingerprint_sha256": fp("owner-k2")}}, "RECIPIENTS"),
            ("wrong drill fingerprint", {"recipients": {"owner_key_id": "owner-k2", "owner_fingerprint_sha256": fp("owner-k2"), "drill_key_id": "drill-2026a",
                                                        "drill_fingerprint_sha256": fp("other")}}, "RECIPIENTS")):
        st, res, _ = backup(H, now, **over)
        neg[name] = (st, res.get("reason"))
        check(st == "rejected" and res.get("reason") == code, f"{name}: {st} {res}")
    # result contract vs the 9011 staging SIN guard (D-9016-5): 120 synthetic results with random run ids, digests, fingerprints
    # and KiB sizes -> 0 hits (bare 9-digit byte counts and UUID-bearing paths would be refused about 1 in 10 / 1 in 700 times)
    import random
    hdr0 = facts(server, H.db)
    with H.definer() as cx:
        fuzz = 0
        for i in range(120):
            k = f"drill-{uuid.uuid4().hex[:8]}"
            p = backup_payload(H, now, drill=k, header=hdr0, sizes={"compressed_kib": random.randint(1, 50_000_000), "wire_kib": random.randint(1, 99_999_999)},
                               recipients={"owner_key_id": "owner-k2", "owner_fingerprint_sha256": fp(k + "o"), "drill_key_id": k, "drill_fingerprint_sha256": fp(k)})
            fuzz += cx.execute("select jsonb_array_length(bnx.sin_scan_json(%s::jsonb))", (json.dumps(p),)).fetchone()[0]
    check(fuzz == 0, f"result contract trips the SIN guard: {fuzz} hits")
    st, res, sid = backup(H, now)
    run = res["run_id"]
    dup = backup(H, now)
    row = definer_one(H, "select anchor_check, anchor_seq, tier, policy, header_facts_sha256 is not null, owner_key_id, drill_key_id from bnx.backup_run where run_id = %s", (run,))
    # tampered anchor: the header records a head hash the live chain does not hold
    hdr = facts(server, H.db)
    hdr["audit_head"]["hash"] = "0" * 64
    st_t, res_t, _ = backup(H, now + dt.timedelta(days=1), header=hdr)
    # FAILED run: recorded, never VERIFIED, alert (AT-NEON-04)
    st_f, res_f, _ = backup(H, now + dt.timedelta(days=2), outcome="FAILED", failure_reason="neon transfer interrupted", object=None,
                            dump_sha256=None, plaintext_sha256=None, header_sha256=None, verify=None, recipients=None)
    due_after = H.worker.call("wrk_backup_due", {})
    status = H.app.call("q_backup_status", H.owner, {})
    member_status = expect_err(H.app.call, "FORBIDDEN_ROLE", "q_backup_status", H.member, {})
    alerts = {k: notes(H, k) for k in ("BACKUP_KEY_MATERIAL_IN_PAYLOAD", "AUDIT_ANCHOR_MISMATCH", "BACKUP_FAILED", "BACKUP_DUPLICATE_LOCAL_DATE")}
    H.close()
    out |= {"due": due, "negatives": neg, "verified": res, "duplicate": dup[:2], "row": row, "tampered": res_t, "failed": res_f,
            "due_after": due_after, "member_status": member_status, "alerts": alerts}
    json.dump(out, open(os.path.join(ev, "AT-BKP-REC.json"), "w"), indent=1, default=str)
    check(out["due without keys"] == "K2_RECIPIENTS_MISSING" and due["due"] and due["recipients"]["drill_key_id"] == "drill-2026a", f"{due}")
    check(st == "promoted" and res["anchor_check"] == "MATCH" and row[0] == "MATCH" and row[1] > 0 and row[3] == "P-A" and row[5:] == ("owner-k2", "drill-2026a"), f"{res} {row}")
    check(dup[0] == "rejected" and dup[1]["reason"] == "DUPLICATE_LOCAL_DATE", f"{dup}")
    check(st_t == "promoted" and res_t["anchor_check"] == "MISMATCH" and st_f == "promoted" and res_f["outcome"] == "FAILED", f"{res_t} {res_f}")
    check(due_after["reason"] == "DONE_FOR_LOCAL_DATE" and [r["outcome"] for r in status["runs"]] == ["FAILED", "VERIFIED", "VERIFIED"]
          and not status["real_data_anchor_precondition"]["met"], f"{due_after} {status['runs']}")
    check(all(alerts[k] for k in alerts), f"{alerts}")
    return (f"no K2 recipients -> due=false ({out['due without keys']}); key registration Owner-only, key material and bad fingerprints refused; "
            f"120 randomized results pass the staging SIN guard (KiB sizes, derived object path, _sha256 keys); {len(neg)} invalid results REJECTED ({sorted(set(r for _, r in neg.values()))}); a verified run is promoted with tier {row[2]}, "
            f"policy {row[3]}, anchor MATCH at seq {row[1]}; a second verified point for the same local date REJECTED; a header whose head hash "
            f"the live chain does not hold -> anchor MISMATCH + Owner alert; a FAILED run is recorded but never verified; every case alerts the Owner")


# ------------------------------------------------------------------------------------------- restore drills
@test("AT-BKP-DRILL", "UA V1.2 §9.3 step 9; Backup §7-§8; AT-BKP-15/20; S4B-F24 (drill outcome is the database's; restorable; authorization)")
def t_drills(server, ev):
    H = world(server, "bnx_c13drl")
    keys(H)
    now = dt.datetime.now(UTC)
    _, r1, _ = backup(H, now)
    run = r1["run_id"]
    out = {"restorable before any drill": definer_one(H, "select bnx.backup_restorable(%s)", (run,))[0]}
    d_ok = drill(H, run)
    out["pass"] = d_ok[1]
    hdr = definer_one(H, "select header_facts from bnx.backup_run where run_id = %s", (run,))[0]
    bad = json.loads(json.dumps(hdr)); bad["tables"]["bnx.journal_line"]["rows"] += 1
    out["owner key used by the drill job"] = drill(H, run, key="owner-k2")[1]
    H.cmd(H.owner, "backup_key_register", key_id="drill-2026b", role="DRILL", recipient_fingerprint_sha256=fp("drill-2026b"))
    out["key that is not a recipient"] = drill(H, run, key="drill-2026b")[1]
    out["cleanup not verified"] = drill(H, run, cleanup_verified=False)[1]
    out["header facts differ"] = drill(H, run, header=bad)[1]
    # 9039: a result without restored_header is NO_RESTORED_HEADER (it was recorded as HEADER_FACTS_DIFFER)
    out["no restored header"] = drill(H, run, outcome="FAIL", failure_reason="migration runner exit 1: ModuleNotFoundError", restored_header=None)[1]
    out["restorable after a later failed drill"] = definer_one(H, "select bnx.backup_restorable(%s)", (run,))[0]
    out["pass again"] = drill(H, run)[1]
    out["production without authorization"] = drill(H, run, kind="RESTORE_SAME_IDENTITY", target="PRODUCTION")
    auth = H.cmd(H.owner, "authorize_restore", backup_run_id=run, target="PRODUCTION", reason="synthetic disaster drill")
    out["member authorizes"] = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "authorize_restore", backup_run_id=run, target="PRODUCTION", reason="x")
    p = drill_payload(H, run, kind="RESTORE_SAME_IDENTITY", target="PRODUCTION", authorization_id=auth["authorization_id"])
    out["production with authorization"] = promote(H, "RESTORE_DRILL", "restore_drill_recorded", p)[1]
    p2 = drill_payload(H, run, kind="RESTORE_SAME_IDENTITY", target="PRODUCTION", authorization_id=auth["authorization_id"])
    out["authorization reused"] = promote(H, "RESTORE_DRILL", "restore_drill_recorded", p2)[:2]
    out["drill lease used for a backup result"] = expect_err(C4.stage, "LEASE_KIND_MISMATCH", H, "RESTORE_DRILL", "backup_recorded", {"x": 1})
    rie = definer_one(H, "select count(*) from bnx.release_install_event where kind = 'RESTORE'")[0]
    out["restorable"] = definer_one(H, "select bnx.backup_restorable(%s)", (run,))[0]
    H.close()
    json.dump(out, open(os.path.join(ev, "AT-BKP-DRILL.json"), "w"), indent=1, default=str)
    check(out["restorable before any drill"] is False and out["pass"]["outcome"] == "PASS" and out["pass"]["restorable"] is True, f"{out['pass']}")
    for k, reason in (("owner key used by the drill job", "DRILL_WITH_OWNER_KEY"), ("key that is not a recipient", "KEY_NOT_RECIPIENT"),
                      ("cleanup not verified", "CLEANUP_NOT_VERIFIED"), ("header facts differ", "HEADER_FACTS_DIFFER")):
        check(out[k]["outcome"] == "FAIL" and reason in out[k]["reasons"], f"{k}: {out[k]}")
    check(out["no restored header"]["outcome"] == "FAIL" and "NO_RESTORED_HEADER" in out["no restored header"]["reasons"]
          and "HEADER_FACTS_DIFFER" not in out["no restored header"]["reasons"], f"{out['no restored header']}")
    check(out["restorable after a later failed drill"] is False and out["pass again"]["restorable"] is True, f"{out}")
    check(out["production without authorization"][0] == "rejected" and out["production without authorization"][1]["reason"] == "RESTORE_NOT_AUTHORIZED"
          and out["production with authorization"]["outcome"] == "PASS" and out["authorization reused"][1]["reason"] == "RESTORE_NOT_AUTHORIZED" and rie == 1, f"{out}")
    return (f"a verified run is not restorable until a drill passes; the drill outcome is the database's: owner key in a drill job, a key that is not "
            f"a recipient, unverified cleanup and differing header facts each FAIL (job reported PASS); a result without restored header facts "
            f"is FAIL NO_RESTORED_HEADER, not HEADER_FACTS_DIFFER (9039); a later failure blocks restorability until the "
            f"next pass; a production restore needs a one-time Owner authorization (without -> REJECTED + alert; reuse REJECTED; with -> PASS and "
            f"release_install_event RESTORE); lease kind binding holds")


# ------------------------------------------------------------------------------------------- retention, DST, policy
@test("AT-BKP-12-16", "Backup §3, AT-BKP-12/16 (7D+4W+12M: one object per run, longest tier wins, retained count, DST-safe local dates)")
def t_retention(server, ev):
    H = C4.household(server, "bnx_c13ret")
    # two simulated years of daily runs at 07:00 UTC (the hourly UTC cron's first due tick after local midnight in Toronto)
    with H.definer() as cx:
        rows = cx.execute("""
          with runs as (select g as at, bnx.backup_tier(g) t from generate_series('2026-01-01 07:00Z'::timestamptz, '2027-12-31 07:00Z', interval '1 day') g)
          select at, (t->>'local_date')::date, t->>'tier', (t->>'retain_until')::timestamptz from runs order by at""").fetchall()
        dst = cx.execute("""select count(*), count(distinct (bnx.backup_tier(g)->>'local_date'))
                              from generate_series('2026-03-01 07:00Z'::timestamptz, '2026-03-15 07:00Z', interval '1 day') g""").fetchone()
        dst2 = cx.execute("""select count(*), count(distinct (bnx.backup_tier(g)->>'local_date'))
                              from generate_series('2026-10-25 07:00Z'::timestamptz, '2026-11-08 07:00Z', interval '1 day') g""").fetchone()
        late = cx.execute("select bnx.backup_tier('2026-11-01 03:30Z')->>'local_date', bnx.backup_tier('2026-11-01 04:30Z')->>'local_date'").fetchone()
    H.close()
    dates = [r[1] for r in rows]
    retained = []
    for i, r in enumerate(rows):
        now = r[0]
        retained.append(sum(1 for x in rows[:i + 1] if x[3] > now))
    steady = retained[400:]
    tiers = {t: sum(1 for r in rows if r[2] == t) for t in ("DAILY", "WEEKLY", "MONTHLY")}
    first = [r for r in rows if r[1].day == 1 and r[1].weekday() == 6][:1]
    json.dump({"retained_steady_min": min(steady), "retained_steady_max": max(steady), "avg": sum(steady) / len(steady), "tiers": tiers,
               "dst": [dst, dst2], "late": late}, open(os.path.join(ev, "AT-BKP-12-16.json"), "w"), indent=1, default=str)
    check(len(dates) == len(set(dates)) == len(rows), "a local date has two points")
    check(21 <= min(steady) and max(steady) <= 22, f"retained {min(steady)}..{max(steady)}")
    check(tiers["MONTHLY"] == 24 and dst[0] == dst[1] and dst2[0] == dst2[1] and late == ("2026-10-31", "2026-11-01"), f"{tiers} {dst} {dst2} {late}")
    check(not first or first[0][2] == "MONTHLY", f"a 1st that is a Sunday must be MONTHLY (longest wins): {first}")
    return (f"730 daily runs: one object per local date; tiers {tiers} (a 1st falling on a Sunday is MONTHLY, the longest wins); "
            f"retained objects in steady state {min(steady)}..{max(steady)} (avg {sum(steady) / len(steady):.1f}; Draft-04 simulation 21-22, avg 21.7); "
            f"DST weeks (Mar 8, Nov 1 2026): {dst[0]} and {dst2[0]} runs -> as many distinct local dates; 03:30Z/04:30Z on Nov 1 -> {late}")


@test("AT-BKP-13", "Backup §5; AT-BKP-13, AT-NEON-03 (egress-aware policy switch, alert, daily gap, Neon egress budget)")
def t_policy(server, ev):
    H = world(server, "bnx_c13pol")
    keys(H)
    t0 = dt.datetime.now(UTC)
    out = {"no measurement": H.worker.call("wrk_backup_due", {})["policy"]}
    _, r1, _ = backup(H, t0, sizes={"compressed_kib": 4_883, "wire_kib": 48_829})        # 30 x 50 MB <= 3 GiB budget -> P-A
    _, r2, _ = backup(H, t0 + dt.timedelta(days=1), sizes={"compressed_kib": 48_829, "wire_kib": 195_313})   # 30 x 200 MB > budget -> P-B
    # next daily / Sunday / 1st of month after the switch
    def nxt(pred):
        d = t0 + dt.timedelta(days=2)
        while not pred(tier(H, d)):
            d += dt.timedelta(days=1)
        return H.worker.call("wrk_backup_due", {"now": iso(d)})
    out["P-B daily"] = nxt(lambda t: t["tier"] == "DAILY")
    out["P-B weekly"] = nxt(lambda t: t["tier"] == "WEEKLY")
    out["P-B monthly"] = nxt(lambda t: t["tier"] == "MONTHLY")
    _, r3, _ = backup(H, t0 + dt.timedelta(days=40), sizes={"compressed_kib": 878_907, "wire_kib": 1_953_125})   # 3 x 2 GB > budget -> P-D
    out["P-D weekly"] = H.worker.call("wrk_backup_due", {"now": iso(next(t0 + dt.timedelta(days=41 + i) for i in range(8)
                                                                          if tier(H, t0 + dt.timedelta(days=41 + i))["tier"] == "WEEKLY"))})
    alerts = notes(H, "BACKUP_POLICY_CHANGED")
    H.close()
    # Neon egress near the budget (P-A, small W): daily off-provider dumps stop, weekly and monthly continue
    H2 = world(server, "bnx_c13egr")
    keys(H2)
    t0 = dt.datetime.now(UTC)                      # after this household's keys were activated
    st1, s1, _ = backup(H2, t0, sizes={"compressed_kib": 1_954, "wire_kib": 9_766})
    check(st1 == "promoted", f"{s1}")
    # this month's Neon egress so far: 3.22 GB; with W = 10 MB the next dump would pass 60 % of 5 GiB (3.2212e9 bytes)
    d = t0 + dt.timedelta(days=1)
    while tier(H2, d)["tier"] != "DAILY":
        d += dt.timedelta(days=1)
    m = d.replace(day=1, hour=12, minute=0, second=0, microsecond=0)
    H2.worker.call("wrk_cloud_usage_record", {"execution_id": "neon-meter-1", "phase": "ACTUAL", "provider": "NEON", "project": "neon", "job": "NEON_METER",
                                              "started_at": iso(m), "egress_bytes": 3_220_000_000})
    out["Neon egress at budget, daily"] = H2.worker.call("wrk_backup_due", {"now": iso(d)})
    H2.close()
    json.dump(out | {"alerts": alerts, "runs": [r1, r2, r3]}, open(os.path.join(ev, "AT-BKP-13.json"), "w"), indent=1, default=str)
    check(out["no measurement"] == "P-A" and r1["policy"] == "P-A" and r2["policy"] == "P-A", f"{r1} {r2}")
    check(out["P-B daily"]["policy"] == "P-B" and out["P-B daily"]["reason"] == "DAILY_TIER_NEON_BRANCH_UNAVAILABLE"
          and out["P-B weekly"]["due"] and out["P-B monthly"]["due"], f"{out}")
    check(r3["policy"] == "P-B" and out["P-D weekly"]["policy"] == "P-D" and out["P-D weekly"]["reason"] == "WEEKLY_TIER_NOT_IN_POLICY"
          and alerts == ["P-B", "P-D"], f"{r3} {out['P-D weekly']} {alerts}")
    check(out["Neon egress at budget, daily"]["reason"] == "NEON_EGRESS_BUDGET", f"{out['Neon egress at budget, daily']}")
    return (f"policy from the measured wire size: none/50 MB -> P-A; 200 MB -> P-B (alert); daily tier then reported as a gap "
            f"({out['P-B daily']['reason']}; Neon branch restore points need the reviewed Neon API key), weekly and monthly stay due; 2 GB -> P-D "
            f"(alert; weekly {out['P-D weekly']['reason']}); Neon egress at the 60 % budget stops the daily off-provider dump (NEON_EGRESS_BUDGET)")


# ------------------------------------------------------------------------------------------- keyring and compromise
@test("AT-BKP-17-19", "Backup §10.4; AT-BKP-17/18/19 (keyring survival over quarterly rotations, pruning, compromise handling)")
def t_keyring(server, ev):
    H = world(server, "bnx_c13key")
    hdr = facts(server, H.db)
    owner = H.owner_id
    base = dt.datetime(2025, 1, 1, 9, tzinfo=UTC)
    # 13 monthly runs (Jan 2025 ... Jan 2026), drill key rotated every quarter (4 rotations); history written as the definer
    # with controlled timestamps (the promoters are covered by AT-BKP-REC; this is the keyring arithmetic)
    with H.definer() as cx:
        cx.execute("insert into bnx.backup_key_registry values ('owner-k2', 'OWNER', %s, null, %s, %s)", (fp("owner-k2"), owner, base - dt.timedelta(days=1)))
        cx.execute("insert into bnx.backup_key_event(key_id, seq, event, by_member, at) values ('owner-k2', 1, 'ACTIVATED', %s, %s)", (owner, base - dt.timedelta(days=1)))
        rot = [base - dt.timedelta(days=1)] + [dt.datetime(2025, m, 15, tzinfo=UTC) for m in (3, 6, 9, 12)]
        for i, at in enumerate(rot):
            k = f"drill-q{i}"
            cx.execute("insert into bnx.backup_key_registry values (%s, 'DRILL', %s, null, %s, %s)", (k, fp(k), owner, at))
            if i:
                cx.execute("insert into bnx.backup_key_event(key_id, seq, event, by_member, at) values (%s, 2, 'RETIRED', %s, %s)", (f"drill-q{i - 1}", owner, at))
            cx.execute("insert into bnx.backup_key_event(key_id, seq, event, by_member, at) values (%s, 1, 'ACTIVATED', %s, %s)", (k, owner, at))
        runs = []
        for mth in range(13):
            st = dt.datetime(2025 + mth // 12, mth % 12 + 1, 1, 9, tzinfo=UTC)
            runs.append((st, cx.execute("select bnx.backup_key_active('DRILL', %s)", (st,)).fetchone()[0]))
    # the runs themselves go through the real promoter (leases, staging, K2 checks against the key active at each start)
    rid = []
    for st, k in runs:
        p = backup_payload(H, st, drill=k, header=hdr)
        sres = C4.stage(H, "BACKUP", "backup_recorded", p)
        rid.append((H.worker.call("wrk_promote_staged", sres["staging_id"]), p["run_id"], k, st))
    # monthly drills of every run with the key it was encrypted to (as of mid-January 2026)
    jan = dt.datetime(2026, 1, 20, tzinfo=UTC)
    dres = [drill(H, r, key=k, st=jan)[1] for _, r, k, _ in rid]
    # pruning: the retired q0 is still needed by the Jan 2025 monthly run (retained 366 days) -> premature; active key refused
    out = {"premature": expect_err(H.worker.call, "PRUNE_PREMATURE", "wrk_backup_key_pruned", {"key_id": "drill-q0", "now": iso(jan)}),
           "active": expect_err(H.worker.call, "PRUNE_REFUSED", "wrk_backup_key_pruned", {"key_id": "drill-q4", "now": iso(jan)})}
    pa = definer_one(H, "select bnx.backup_key_prune_after('drill-q0')")[0]
    out["after prune_after"] = H.worker.call("wrk_backup_key_pruned", {"key_id": "drill-q0", "now": iso(pa + dt.timedelta(minutes=1))})
    out["drill with the pruned key"] = drill(H, rid[0][1], key="drill-q0")[1]
    # compromise (Owner decision at the time): KEEP_FOR_DRILLS keeps drills working; OWNER_KEY_TEST_ONLY routes them to the Owner-key test
    H.cmd(H.owner, "backup_key_mark_compromised", key_id="drill-q3", handling="KEEP_FOR_DRILLS")
    q3 = next(r for _, r, k, _ in rid if k == "drill-q3")
    out["compromised, keep for drills"] = drill(H, q3, key="drill-q3")[1]
    H.cmd(H.owner, "backup_key_mark_compromised", key_id="drill-q2", handling="OWNER_KEY_TEST_ONLY")
    q2 = next(r for _, r, k, _ in rid if k == "drill-q2")
    out["compromised, owner-key test only"] = drill(H, q2, key="drill-q2")[1]
    out["second compromise mark"] = expect_err(H.cmd, "KEY_STATE", H.owner, "backup_key_mark_compromised", key_id="drill-q2", handling="KEEP_FOR_DRILLS")
    st_ = H.app.call("q_backup_status", H.owner, {"limit": 50})
    alerts = notes(H, "BACKUP_KEY_COMPROMISED")
    H.close()
    json.dump(out | {"runs": [(a, b, c, str(d)) for a, b, c, d in rid], "drills": dres, "keys": st_["keys"]},
              open(os.path.join(ev, "AT-BKP-17-19.json"), "w"), indent=1, default=str)
    used = sorted({k for _, _, k, _ in rid})
    check(all(r[0] == "promoted" for r in rid) and used == ["drill-q0", "drill-q1", "drill-q2", "drill-q3", "drill-q4"], f"{rid}")
    check(all(d["outcome"] == "PASS" for d in dres), f"{[d['reasons'] for d in dres]}")
    check(out["after prune_after"]["state"] == "PRUNED" and "KEY_PRUNED" in out["drill with the pruned key"]["reasons"], f"{out}")
    check(out["compromised, keep for drills"]["outcome"] == "PASS" and "KEY_COMPROMISED_OWNER_TEST_ONLY" in out["compromised, owner-key test only"]["reasons"]
          and alerts == ["drill-q3", "drill-q2"], f"{out} {alerts}")
    return (f"13 monthly runs over 4 quarterly drill-key rotations; each run lists the drill key active at its start ({used}); every retained run "
            f"drilled in January 2026 with its own key -> 13 PASS (keyring survival); pruning q0 before prune_after ({pa:%Y-%m-%d}) -> PRUNE_PREMATURE, "
            f"the active key -> PRUNE_REFUSED, after prune_after -> PRUNED and a drill with it FAILs (KEY_PRUNED); compromise: KEEP_FOR_DRILLS drill PASS, "
            f"OWNER_KEY_TEST_ONLY drill FAIL; each compromise alerts the Owner")


# ------------------------------------------------------------------------------------------- audit anchor and evidence
@test("AT-ANCHOR-01", "9011R R-11 (O-8 precondition), G0R F-06: anchor in the backup header; worker tick and external verifier")
def t_anchor(server, ev):
    H = world(server, "bnx_c13anc")
    out = {"tick, no backup": H.worker.call("wrk_audit_verified", {})}
    keys(H)
    _, r, _ = backup(H, dt.datetime.now(UTC))
    run = definer_one(H, "select anchor_seq, anchor_hash from bnx.backup_run where run_id = %s", (r["run_id"],))
    out["tick"] = H.worker.call("wrk_audit_verified", {})
    out["status before external"] = H.app.call("q_backup_status", H.owner, {})["real_data_anchor_precondition"]["met"]
    vr = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools/s4/audit_chain_verify.py"), "--dsn", h.dsn(server, "bnx_backup", H.db),
                         "--anchor", f"{run[0]}:{run[1]}"], capture_output=True, text=True)
    verdict = json.loads(vr.stdout)["verdict"]
    out["external"] = H.worker.call("wrk_audit_verified", {"source": "EXTERNAL_VERIFIER", "result": verdict, "anchor_seq": run[0], "anchor_hash": run[1],
                                                           "tool_version": "audit_chain_verify"})
    out["status"] = H.app.call("q_backup_status", H.owner, {})["real_data_anchor_precondition"]
    out["external, unknown anchor"] = H.worker.call("wrk_audit_verified", {"source": "EXTERNAL_VERIFIER", "result": "INTACT", "anchor_seq": run[0],
                                                                         "anchor_hash": "f" * 64})
    # a superuser rewrite of the anchored row (V8.6/X2 residual) is detected against the anchor
    with psycopg.connect(h.dsn(server, "postgres", H.db), autocommit=True) as su:
        su.execute("set session_replication_role = replica")
        su.execute("update bnx_audit.audit_event set hash = sha256(hash) where seq = %s", (run[0],))
    out["tick after rewrite"] = H.worker.call("wrk_audit_verified", {})
    vr2 = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools/s4/audit_chain_verify.py"), "--dsn", h.dsn(server, "bnx_backup", H.db),
                          "--anchor", f"{run[0]}:{run[1]}"], capture_output=True, text=True)
    out["external tool after rewrite"] = json.loads(vr2.stdout)["verdict"]
    out["bad report"] = expect_err(H.worker.call, "VALIDATION_FAILED", "wrk_audit_verified", {"source": "EXTERNAL_VERIFIER", "extra": 1})
    alerts = notes(H, "AUDIT_VERIFY_FAILED")
    H.close()
    json.dump(out | {"alerts": alerts}, open(os.path.join(ev, "AT-ANCHOR-01.json"), "w"), indent=1, default=str)
    check(out["tick, no backup"]["anchor_result"] == "NO_ANCHOR" and out["tick, no backup"]["result"] == "INTACT", f"{out['tick, no backup']}")
    check(out["tick"]["anchor_result"] == "MATCH" and out["status before external"] is False and verdict == "INTACT"
          and out["external"]["result"] == "INTACT" and out["status"]["met"] is True, f"{out}")
    check(out["external, unknown anchor"]["anchor_result"] == "UNKNOWN_ANCHOR" and out["tick after rewrite"]["result"] == "FAILED"
          and out["external tool after rewrite"] == "FAILED" and len(alerts) == 2, f"{out} {alerts}")
    return (f"tick without a backup: NO_ANCHOR; the verified backup header records (seq {run[0]}, head hash) -> tick MATCH; the external verifier "
            f"(tools/s4/audit_chain_verify.py --anchor) INTACT with that anchor -> O-8 anchor precondition met (reported only; the gate stays with the Owner); "
            f"an unknown anchor -> UNKNOWN_ANCHOR; a superuser rewrite of the anchored row -> tick FAILED and the tool FAILED; failures alert the Owner")


@test("AT-BKP-10", "Draft-04 §7 R8; AT-BKP-10; 9011R R-09 (evidence re-hash through EVIDENCE_VERIFY; status read via evidence_status)")
def t_evidence(server, ev):
    H = world(server, "bnx_c13evd")
    good, bad, unref = hashlib.sha256(b"synthetic statement A").digest(), hashlib.sha256(b"synthetic statement B").digest(), None
    with H.definer() as cx:
        ids = [cx.execute("insert into bnx.evidence_object(id, r2_key, size_bytes, sha256, integrity_state) values (gen_random_uuid(), %s, 100, %s, %s) returning id",
                          (k, s, "verified" if s else "unverified")).fetchone()[0] for k, s in (("r2/a", good), ("r2/b", bad), ("r2/c", unref))]
    items = [{"evidence_object_id": str(ids[0]), "copy": "R2", "observed_sha256": good.hex()},
             {"evidence_object_id": str(ids[0]), "copy": "DRIVE", "observed_sha256": good.hex()},
             {"evidence_object_id": str(ids[1]), "copy": "DRIVE", "observed_sha256": hx("tampered")},
             {"evidence_object_id": str(ids[2]), "copy": "R2", "observed_sha256": hx("x")}]
    st, res, sid = promote(H, "EVIDENCE_VERIFY", "backup_recorded", {"items": items})
    with H.definer() as cx:
        rows = cx.execute("select copy, result, evidence_status from bnx.evidence_verification where staging_id = %s order by id", (sid,)).fetchall()
    rej = {"unknown object": promote(H, "EVIDENCE_VERIFY", "backup_recorded", {"items": [{"evidence_object_id": str(uuid.uuid4()), "copy": "R2", "observed_sha256": good.hex()}]})[1],
           "bad copy": promote(H, "EVIDENCE_VERIFY", "backup_recorded", {"items": [items[0] | {"copy": "NAS"}]})[1],
           "items on a BACKUP lease": promote(H, "BACKUP", "backup_recorded", {"items": items})[1],
           "no items": promote(H, "EVIDENCE_VERIFY", "backup_recorded", {"started_at": "2026-11-13T00:00:00Z"})[1]}      # 9039
    summary = H.app.call("q_backup_status", H.owner, {})["evidence_verification"]
    alerts = notes(H, "EVIDENCE_HASH_MISMATCH")
    H.close()
    json.dump({"result": res, "rows": rows, "rejected": rej, "summary": summary, "alerts": alerts}, open(os.path.join(ev, "AT-BKP-10.json"), "w"), indent=1, default=str)
    check(st == "promoted" and res["verified"] == 4 and res["mismatches"] == 1 and [r[1] for r in rows] == ["MATCH", "MATCH", "MISMATCH", "NO_REFERENCE"], f"{res} {rows}")
    check(all(r[2] == "UNSCANNED" for r in rows) and rej["unknown object"]["reason"] == "UNKNOWN_EVIDENCE" and rej["bad copy"]["reason"] == "ITEM"
          and rej["items on a BACKUP lease"]["reason"] == "UNKNOWN_FIELD" and rej["no items"]["reason"] == "ITEMS" and summary["mismatches"] == 1 and alerts == [str(ids[1])], f"{rows} {rej} {summary} {alerts}")
    return (f"EVIDENCE_VERIFY result promoted: R2 and Drive copies MATCH, a tampered copy MISMATCH (Owner alert), an object never hashed by the executor "
            f"NO_REFERENCE (not a mismatch); each row stores evidence_status ({rows[0][2]}, R-09); unknown object, unknown copy kind, items on a "
            f"BACKUP lease and a result without items (9039) are REJECTED")


# ------------------------------------------------------------------------------------------- usage, capacity, admission
@test("AT-SPEND-ADM", "Cost §6.2-§6.3, §7; AT-SPEND-01/03/04/05/06/09, AT-NEON-01/02 (database part: usage ledger, capacity, admission)")
def t_admission(server, ev):
    H = C4.household(server, "bnx_c13adm")
    W = H.worker
    m0 = dt.datetime(2026, 5, 3, 12, tzinfo=UTC)
    adm = lambda cls, now=m0, **kw: W.call("wrk_admission_decide", {"job": {"backup": "BACKUP", "drill": "RESTORE_DRILL"}.get(cls, "DOC_PROCESS"),
                                                                    "admission_class": cls, "now": iso(now), "planned_items": kw.get("items", 1),
                                                                    "estimated_instance_seconds": kw.get("secs", 300), "gib": kw.get("gib", 2)})
    use = lambda eid, project, gross, now=m0, **kw: W.call("wrk_cloud_usage_record", {"execution_id": eid, "phase": kw.get("phase", "ACTUAL"),
        "provider": "NEON" if project == "neon" else "GCP_RUN", "project": project, "job": kw.get("job", "DOC_PROCESS"), "started_at": iso(now),
        "gross_estimate": str(gross), **{k: v for k, v in kw.items() if k in ("storage_bytes", "cu_hours", "egress_bytes")}})
    out = {"interactive, empty month": adm("interactive")}
    use("x-1", "bnx-exec", "0.30", phase="EXPECTED"); use("x-1", "bnx-exec", "0.50")            # ACTUAL supersedes EXPECTED
    out["duplicate usage"] = expect_err(use, "USAGE_DUPLICATE", "x-1", "bnx-exec", "0.50")
    out["interactive below ceiling"] = adm("interactive")                                          # 0.50 + 0.0079 <= 0.595
    use("x-2", "bnx-exec", "0.10")                                                                  # 0.60 > 0.595 -> usage ledger throttle
    out["interactive above ceiling"] = adm("interactive")
    out["backup within reserve"] = adm("backup", gib=1)
    use("x-3", "bnx-exec", "0.09")                                                                  # 0.69 + est > 0.695
    out["backup beyond reserve"] = adm("backup", gib=1, secs=600)
    out["drill (vault)"] = adm("drill")
    use("v-1", "bnx-vault", "0.10", job="RESTORE_DRILL")
    out["drill above vault ceiling"] = adm("drill")
    # next month: notifications and the cap (Pub/Sub path), then the refused-launch path alone (AT-SPEND-09)
    m1 = dt.datetime(2026, 6, 2, 12, tzinfo=UTC)
    cap = lambda sig, now, **kw: W.call("wrk_capacity_update", {"scope": "bnx-exec", "signal": sig, "now": iso(now), **kw})
    out["june interactive"] = adm("interactive", m1)
    out["50 %"] = cap("budget_notification", m1, threshold_pct=50)
    out["50 % interactive"] = adm("interactive", m1)
    out["80 %"] = cap("budget_notification", m1 + dt.timedelta(hours=1), threshold_pct=80)
    out["80 % interactive"] = adm("interactive", m1 + dt.timedelta(hours=2))
    out["80 % backup"] = adm("backup", m1 + dt.timedelta(hours=2), gib=1)
    out["100 %"] = cap("budget_notification", m1 + dt.timedelta(hours=3), threshold_pct=100)
    out["100 % backup (until refused)"] = adm("backup", m1 + dt.timedelta(hours=4), gib=1)
    out["launch refused"] = cap("launch_refused", m1 + dt.timedelta(hours=5))
    out["capped backup"] = adm("backup", m1 + dt.timedelta(hours=6), gib=1)
    # period reset: one-item probe only; failure backs off 6 h; success resumes
    m2 = dt.datetime(2026, 7, 1, 8, tzinfo=UTC)
    out["july bulk 5 items"] = adm("bulk", m2, items=5)
    out["july probe"] = adm("interactive", m2)
    out["probe failed"] = cap("probe_result", m2 + dt.timedelta(minutes=10), ok=False)
    out["during back-off"] = adm("interactive", m2 + dt.timedelta(hours=1))
    out["after back-off"] = adm("interactive", m2 + dt.timedelta(hours=7))
    out["probe ok"] = cap("probe_result", m2 + dt.timedelta(hours=7, minutes=5), ok=True)
    out["july bulk after probe"] = adm("bulk", m2 + dt.timedelta(hours=8), items=5)
    # Neon meters (AT-NEON-01/02, database part): storage >= 80 % or CU-hours >= 80 % pause bulk onboarding, not interactive work
    use("n-1", "neon", "0", m2, job="NEON_METER", storage_bytes=900_000_000)
    out["neon storage bulk"] = adm("bulk", m2 + dt.timedelta(hours=9), items=5)
    out["neon storage interactive"] = adm("interactive", m2 + dt.timedelta(hours=9))
    m3 = dt.datetime(2026, 8, 2, 8, tzinfo=UTC)
    use("n-2", "neon", "0", m3, job="NEON_METER", cu_hours="85")
    out["neon compute bulk"] = adm("bulk", m3, items=3)
    # AT-SPEND-06 (database part): caps are Owner decisions; runtime roles cannot write the policy
    out["member sets cost policy"] = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "set_cost_policy", exec_allocation="2.00", note="x")
    out["SC-V2 by the Owner"] = H.cmd(H.owner, "set_cost_policy", spend_cap_variant="SC-V2", exec_allocation="0.85", vault_allocation="0.15",
                                      note="synthetic: console refused sub-dollar caps; application ceiling keeps USD 1 combined")
    out["policy key outside the allowlist"] = expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "set_cost_policy", neon_cu_hours="1000", note="x")
    denied = {}
    for role in ("bnx_app", "bnx_worker"):
        R = h.Role(server, H.db, role)
        try:
            R.sql("insert into bnx.cost_policy(version) values (99)"); denied[role] = "ALLOWED"
        except psycopg.Error as e:
            denied[role] = (e.diag.message_primary or "")[:30]
        R.close()
    cs = H.app.call("q_cost_status", H.owner, {"month": "2026-05-01"})
    H.close()
    json.dump(out | {"denied": denied, "cost_status": cs}, open(os.path.join(ev, "AT-SPEND-ADM.json"), "w"), indent=1, default=str)
    R = lambda k: (out[k]["admitted"], out[k]["reason"])
    check(R("interactive, empty month") == (True, "ADMITTED") and R("interactive below ceiling") == (True, "ADMITTED")
          and R("interactive above ceiling") == (False, "THROTTLED_INTERNAL") and R("backup within reserve") == (True, "ADMITTED")
          and R("backup beyond reserve") == (False, "BACKUP_RESERVE_EXHAUSTED") and R("drill (vault)") == (True, "ADMITTED")
          and R("drill above vault ceiling") == (False, "VAULT_CEILING_NEXT_MONTH"), f"{out}")
    check(R("june interactive") == (True, "ADMITTED") and out["50 %"]["state"] == "normal" and R("50 % interactive") == (True, "ADMITTED")
          and out["80 %"]["state"] == "throttled_internal" and R("80 % interactive") == (False, "THROTTLED_INTERNAL") and R("80 % backup")[0]
          and out["100 %"]["state"] == "provider_capped" and R("100 % backup (until refused)") == (True, "ADMITTED_CAPPED_NOTICE_BACKUP_RESERVE")
          and R("capped backup") == (False, "PROVIDER_CAPPED"), f"{out}")
    check(R("july bulk 5 items") == (False, "PROBE_PENDING_ONE_ITEM_ONLY") and R("july probe") == (True, "PERIOD_RESET_PROBE")
          and R("during back-off") == (False, "PROBE_BACKOFF") and R("after back-off") == (True, "PERIOD_RESET_PROBE")
          and out["probe ok"]["state"] == "normal" and R("july bulk after probe") == (True, "ADMITTED"), f"{out}")
    check(R("neon storage bulk") == (False, "NEON_STORAGE") and R("neon storage interactive") == (True, "ADMITTED") and R("neon compute bulk") == (False, "NEON_COMPUTE"), f"{out}")
    check(out["SC-V2 by the Owner"]["version"] == 2 and all(v.startswith("permission denied") for v in denied.values())
          and cs["usage"]["bnx-exec"]["gross_estimate"] == "0.690000" and cs["capacity"]["bnx-exec"]["state"] == "normal", f"{denied} {cs['usage']} {cs['capacity']}")
    return ("usage ledger (highest phase per execution; duplicates refused) drives the 70 % exec ceiling (USD 0.595): interactive throttled, backups within "
            "the USD 0.10 reserve, then BACKUP_RESERVE_EXHAUSTED; vault ceiling defers drills; notices 50 % logged, 80 % throttles extraction, 100 % caps "
            "(backups still tried within the reserve until a launch is refused, then everything waits); next month: one-item probe only, failure -> "
            "6 h back-off, success -> normal; Neon storage/CU >= 80 % pause bulk onboarding only; caps are Owner-only versions (SC-V2 recorded with the "
            f"Owner as declarer), runtime roles cannot write the policy ({denied})")


# ------------------------------------------------------------------------------------------- privileges and registration
@test("AT-BKP-PRIV", "S4B-F10 c (USAGE-revoked negative); UA V1.2 §6.1, §9.3 step 1 (bnx_backup executes bkp_* invokers only); catalog")
def t_privileges(server, ev):
    db = "bnx_c13priv"
    h.bootstrap(server, db); h.migrate(server, db)
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        bak = [r[0] for r in cx.execute("select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in "
                                        "(select nspname from bnx.schema_registry) and has_function_privilege('bnx_backup', p.oid, 'EXECUTE') order by 1")]
        v0 = cx.execute("select bnx.audit_privileges()->'violations'").fetchone()[0]
        # an unsafe bkp_ function (SECURITY DEFINER) is never granted and is reported
        cx.execute("create function bnx.bkp_unsafe_probe() returns int language sql stable security definer set search_path = pg_catalog, pg_temp as 'select 1'")
        cx.execute("select bnx.apply_grants()")
        granted = cx.execute("select has_function_privilege('bnx_backup', 'bnx.bkp_unsafe_probe()', 'EXECUTE')").fetchone()[0]
        v1 = [x["rule"] for x in cx.execute("select bnx.audit_privileges()->'violations'").fetchone()[0]]
        cx.execute("grant execute on function bnx.bkp_unsafe_probe() to bnx_backup")
        v2 = sorted({x["rule"] for x in cx.execute("select bnx.audit_privileges()->'violations'").fetchone()[0]})
        cx.rollback()
        cx.execute("set role bnx_definer")
        newt = [r[0] for r in cx.execute("select table_name from bnx.table_class where table_name in ('backup_run','restore_drill','cloud_usage','backup_key_registry',"
                                         "'backup_key_event','restore_authorization','evidence_verification','audit_verification','cost_policy','capacity_event',"
                                         "'admission_decision') order by 1")]
    with psycopg.connect(h.dsn(server, "postgres", db), autocommit=True) as su:
        su.execute("revoke usage on schema bnx_doc from bnx_backup")
        with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
            cx.execute("set role bnx_definer")
            v3 = [x for x in cx.execute("select bnx.audit_privileges()->'violations'").fetchone()[0] if x["rule"] == "BACKUP_SCHEMA_USAGE"]
        su.execute("grant usage on schema bnx_doc to bnx_backup")
    denied = {}
    for role in ("bnx_app", "bnx_worker", "bnx_backup"):
        with psycopg.connect(h.dsn(server, role, db), autocommit=True) as cx:
            for q in ("select count(*) from bnx.backup_run", "insert into bnx.cloud_usage(execution_id) values ('x')",
                      "select bnx.restore_preamble()", "select bnx.backup_policy()"):
                try:
                    cx.execute(q); denied[f"{role}: {q[:40]}"] = "ALLOWED"
                except psycopg.Error as e:
                    denied[f"{role}: {q[:40]}"] = "denied"
    allowed_backup_reads = [k for k, v in denied.items() if v == "ALLOWED"]
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        cx.execute("set role bnx_definer")
        cat = {r[0] for r in cx.execute("select function_name from bnx.function_scope where function_name in ('q_backup_status','q_cost_status',"
                                        "'cmd_backup_key_register','cmd_authorize_restore','cmd_set_cost_policy','cmd_backup_key_mark_compromised')")}
        seeded = cx.execute("select truncate_on_restore from bnx.migration_seeded_table where table_name = 'bnx.cost_policy'").fetchone()
    json.dump({"backup_execute": bak, "v0": v0, "unsafe_granted": granted, "v1": v1, "v2": v2, "v3": v3, "denied": denied, "catalog": sorted(cat),
               "table_class": newt}, open(os.path.join(ev, "AT-BKP-PRIV.json"), "w"), indent=1)
    check(bak == ["bkp_header_compare", "bkp_header_facts"] and v0 == [], f"{bak} {v0}")
    check(granted is False and "BACKUP_FUNCTION_UNSAFE" in v1 and v2 == ["BACKUP_FUNCTION_UNSAFE", "EXECUTE_GRANT"], f"{granted} {v1} {v2}")
    check(len(v3) == 1 and v3[0]["schema"] == "bnx_doc", f"{v3}")
    check(allowed_backup_reads == ["bnx_backup: select count(*) from bnx.backup_run"], f"{denied}")
    check(not cat and seeded == (True,) and len(newt) == 11, f"{cat} {seeded} {newt}")
    return (f"bnx_backup may EXECUTE exactly {bak} (SECURITY INVOKER, not volatile); 0 violations; a SECURITY DEFINER bkp_ function is not granted and is "
            f"reported (BACKUP_FUNCTION_UNSAFE), granting it anyway adds EXECUTE_GRANT; USAGE on bnx_doc revoked from bnx_backup -> BACKUP_SCHEMA_USAGE; "
            f"runtime roles cannot read or write the registries or call the preamble/policy helpers (bnx_backup reads only); backup and cost "
            f"functions are outside the MCP catalog; 11 append-only tables classed; cost_policy is a seeded table (truncate_on_restore)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core13", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core13_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
