#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""External verifier of the Balnexa audit chain (G0 findings F-01 and F-06, G0R 2026-11-11).

bnx.audit_verify() and bnx.audit_privileges() are functions owned by bnx_definer, so the owner path (bnx_migrator ->
SET ROLE bnx_definer) could replace them. This tool does not call any bnx function. It reads bnx_audit.audit_event and
the system catalogs in a read-only transaction (connect as bnx_backup), recomputes every hash with PostgreSQL built-in
functions only (search_path pg_catalog), and checks the protections B003 put in place:

  catalog   bnx_audit.audit_event is a table owned by balnexa_audit_owner in schema bnx_audit (owned by balnexa_audit_owner);
            bnx_definer holds exactly SELECT and INSERT; no runtime role holds a write privilege, also through
            predefined roles such as pg_write_all_data (has_table_privilege, 9011 review R-12); the three append
            triggers exist and are enabled, and t_chain_append's function belongs to balnexa_audit_owner; no row
            security, rules, inheritance children or publication on the table; no role can SET or INHERIT
            balnexa_audit_owner; bnx.audit_event is a view
  chain     seq runs 1..N without gaps; each prev_hash equals the previous hash; chain versions never decrease; each
            hash equals sha256(prev_hash || canonical row) for its chain version (v1: 0106, v2: 9005)
  anchors   each --anchor SEQ:HASH (a head recorded earlier, e.g. in a backup header or vault manifest; 9016) still has
            that hash at that seq, and the chain has not become shorter than it

Without an anchor a superuser who deletes the tail or rewrites the chain and recomputes the hashes is not detected
(documented residual V8.6/X2); with an anchor both are. The output ends with the current head, to be recorded as the
next anchor.

Usage: audit_chain_verify.py --dsn "host=... user=bnx_backup dbname=..." [--anchor SEQ:HEX]... [--json FILE]
Exit codes: 0 intact, 1 a check failed, 2 the database could not be read or an argument was malformed.
"""
import argparse, json, sys
import psycopg

V1 = ("convert_to(concat_ws('|', seq, member_id, connection_id, channel, command, subject::text, encode(payload_sha256, 'hex'), "
      "ledger_version), 'UTF8')")
V2 = ("convert_to(jsonb_build_array(seq, member_id, connection_id, channel, command, subject, encode(payload_sha256, 'hex'), "
      "ledger_version, to_char(at_hashed at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), chain_version, host_profile, "
      "tool_name, tool_version, trace_id)::text, 'UTF8')")
CHAIN_SQL = (f"select seq, chain_version, encode(prev_hash, 'hex'), encode(hash, 'hex'), "
             f"hash = sha256(coalesce(prev_hash, '\\x'::bytea) || case when chain_version = 1 then {V1} else {V2} end) "
             f"from bnx_audit.audit_event order by seq")
WRITE_PRIVS = ("UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER")
RUNTIME_ROLES = ("bnx_definer", "bnx_app", "bnx_worker", "bnx_authn", "bnx_auth", "bnx_migrator", "bnx_stager", "bnx_fed_reader",
                 "bnx_backup")
TRIGGERS = ("t_append_only", "t_chain_append", "t_chain_version")


def catalog_checks(cur):
    bad = []
    cur.execute("select c.relkind, pg_get_userbyid(c.relowner), pg_get_userbyid(n.nspowner) from pg_class c "
                "join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'bnx_audit' and c.relname = 'audit_event'")
    row = cur.fetchone()
    if row is None:
        return ["TABLE_MISSING: bnx_audit.audit_event"]
    kind, owner, nsowner = row
    if kind != "r":
        bad.append(f"NOT_A_TABLE: relkind {kind}")
    if owner != "balnexa_audit_owner":
        bad.append(f"TABLE_OWNER: {owner}")
    if nsowner != "balnexa_audit_owner":
        bad.append(f"SCHEMA_OWNER: {nsowner}")
    cur.execute("select r.rolcanlogin, r.rolsuper from pg_roles r where r.rolname = 'balnexa_audit_owner'")
    r = cur.fetchone()
    if r is None or r[0] or r[1]:
        bad.append(f"AUDIT_OWNER_ROLE: {r}")
    for p in ("SELECT", "INSERT"):
        cur.execute("select has_table_privilege('bnx_definer', 'bnx_audit.audit_event', %s)", (p,))
        if not cur.fetchone()[0]:
            bad.append(f"DEFINER_MISSING: {p}")
    cur.execute("select pg_get_userbyid(x.grantee), x.privilege_type from pg_class c, aclexplode(c.relacl) x "
                "where c.oid = 'bnx_audit.audit_event'::regclass and x.grantee <> c.relowner and x.privilege_type = any(%s)",
                (list(WRITE_PRIVS),))
    for grantee, priv in cur.fetchall():
        bad.append(f"WRITE_PRIVILEGE: {grantee} {priv}")
    cur.execute("select pg_get_userbyid(x.grantee), x.privilege_type from pg_class c, aclexplode(c.relacl) x "
                "where c.oid = 'bnx_audit.audit_event'::regclass and x.grantee <> c.relowner and x.privilege_type = 'INSERT' "
                "and pg_get_userbyid(x.grantee) <> 'bnx_definer'")
    for grantee, priv in cur.fetchall():
        bad.append(f"INSERT_PRIVILEGE: {grantee}")
    cur.execute("select count(*) from pg_attribute a, aclexplode(a.attacl) x where a.attrelid = 'bnx_audit.audit_event'::regclass "
                "and x.privilege_type in ('UPDATE', 'REFERENCES')")
    if cur.fetchone()[0]:
        bad.append("COLUMN_WRITE_PRIVILEGE")
    # effective privileges, including those granted through predefined roles (R-12)
    for role in RUNTIME_ROLES:
        cur.execute("select exists (select 1 from pg_roles where rolname = %s)", (role,))
        if not cur.fetchone()[0]:
            continue
        for p in WRITE_PRIVS + (() if role == "bnx_definer" else ("INSERT",)):
            cur.execute("select has_table_privilege(%s, 'bnx_audit.audit_event', %s)", (role, p))
            if cur.fetchone()[0]:
                bad.append(f"EFFECTIVE_WRITE_PRIVILEGE: {role} {p}")
    for tg in TRIGGERS:
        cur.execute("select tgenabled from pg_trigger where tgrelid = 'bnx_audit.audit_event'::regclass and tgname = %s", (tg,))
        t = cur.fetchone()
        if t is None or t[0] != "O":
            bad.append(f"TRIGGER: {tg} {'missing' if t is None else 'state ' + t[0]}")
    cur.execute("select tgname from pg_trigger where tgrelid = 'bnx_audit.audit_event'::regclass and not tgisinternal "
                "and tgname <> all(%s)", (list(TRIGGERS),))
    for (tg,) in cur.fetchall():
        bad.append(f"EXTRA_TRIGGER: {tg}")
    cur.execute("select pg_get_userbyid(f.proowner), f.prosecdef from pg_trigger g join pg_proc f on f.oid = g.tgfoid "
                "where g.tgrelid = 'bnx_audit.audit_event'::regclass and g.tgname = 't_chain_append'")
    t = cur.fetchone()
    if t is not None and (t[0] != "balnexa_audit_owner" or not t[1]):
        bad.append(f"CHAIN_APPEND_FUNCTION: owner {t[0]} security_definer {t[1]}")
    cur.execute("select c.relrowsecurity, c.relhasrules, c.relhassubclass, "
                "exists (select 1 from pg_inherits i where i.inhparent = c.oid), "
                "exists (select 1 from pg_publication_rel pr where pr.prrelid = c.oid), "
                "exists (select 1 from pg_policy pol where pol.polrelid = c.oid) "
                "from pg_class c where c.oid = 'bnx_audit.audit_event'::regclass")
    for name, flag in zip(("ROW_SECURITY", "RULES", "SUBCLASS", "INHERITS", "PUBLICATION", "POLICY"), cur.fetchone()):
        if flag:
            bad.append(f"TABLE_SHAPE: {name}")
    cur.execute("select pg_get_userbyid(member), set_option, inherit_option from pg_auth_members "
                "where roleid = (select oid from pg_roles where rolname = 'balnexa_audit_owner') and (set_option or inherit_option)")
    for m, s, i in cur.fetchall():
        bad.append(f"AUDIT_OWNER_MEMBER: {m} set={s} inherit={i}")
    cur.execute("select relkind from pg_class where oid = to_regclass('bnx.audit_event')")
    v = cur.fetchone()
    if v is not None and v[0] != "v":
        bad.append(f"BNX_AUDIT_EVENT_NOT_VIEW: relkind {v[0]}")
    return bad


def chain_checks(cx):
    bad, prev, expect, cv, n, head = [], None, 1, 1, 0, {"seq": 0, "hash": None}
    with cx.cursor(name="chain") as cur:
        cur.itersize = 5000
        cur.execute(CHAIN_SQL)
        for seq, ver, ph, hh, ok in cur:
            n += 1
            if seq != expect:
                bad.append(f"SEQ_GAP: expected {expect}, found {seq}"); break
            if ph != prev:
                bad.append(f"PREV_HASH: seq {seq}"); break
            if ver < cv:
                bad.append(f"CHAIN_VERSION: seq {seq} v{ver} after v{cv}"); break
            if not ok:
                bad.append(f"HASH: seq {seq}"); break
            prev, expect, cv, head = hh, expect + 1, ver, {"seq": seq, "hash": hh, "chain_version": ver}
    return bad, n, head


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--anchor", action="append", default=[], help="SEQ:HEX recorded earlier")
    ap.add_argument("--json", help="also write the result to this file")
    a = ap.parse_args()
    out = {"tool": "audit_chain_verify", "catalog": [], "chain": [], "anchors": []}
    anchors = []
    for an in a.anchor:                                    # R-14: a malformed anchor is an argument error, exit 2
        seq, sep, hx = an.partition(":")
        if not (sep and seq.isdigit() and len(hx) == 64 and all(c in "0123456789abcdefABCDEF" for c in hx)):
            out["error"] = f"ANCHOR_MALFORMED: expected SEQ:HEX64, got {an[:80]!r}"
            print(json.dumps(out, indent=1)); sys.exit(2)
        anchors.append((int(seq), hx.lower()))
    try:
        with psycopg.connect(a.dsn) as cx:
            cx.execute("set search_path = pg_catalog, pg_temp")
            cx.execute("set transaction read only")
            cur = cx.cursor()
            cur.execute("select current_user, version()")
            out["connected_as"], out["server"] = cur.fetchone()
            out["catalog"] = catalog_checks(cur)
            if not any(x.startswith("TABLE_MISSING") for x in out["catalog"]):
                out["chain"], out["rows"], out["head"] = chain_checks(cx)
                cur = cx.cursor()
                for seq, hx in anchors:
                    cur.execute("select encode(hash, 'hex') from bnx_audit.audit_event where seq = %s", (seq,))
                    r = cur.fetchone()
                    if r is None:
                        out["anchors"].append(f"ANCHOR_MISSING: seq {seq} (chain head {out['head']['seq']})")
                    elif r[0] != hx:
                        out["anchors"].append(f"ANCHOR_HASH: seq {seq}")
            cx.rollback()
    except psycopg.Error as e:
        out["error"] = f"{type(e).__name__}: {str(e).strip().splitlines()[0][:300]}"
        print(json.dumps(out, indent=1)); sys.exit(2)
    out["verdict"] = "INTACT" if not (out["catalog"] or out["chain"] or out["anchors"]) else "FAILED"
    text = json.dumps(out, indent=1, default=str)
    print(text)
    if a.json:
        open(a.json, "w").write(text + "\n")
    sys.exit(0 if out["verdict"] == "INTACT" else 1)


if __name__ == "__main__":
    main()
