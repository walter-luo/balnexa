#!/usr/bin/env python3
"""S4 V1.2 increment 2 tests: 9005 audit chain v2, 9006 registry/policy/accounts, 9007 module-flag enforcement.
Conventions as run_g0.py / run_s4_core1.py. Usage: run_s4_core2.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, sys, time, traceback, uuid
import psycopg
import harness as h
import fixture as F
import run_s4_core1 as C1

RESULTS, TESTS = [], []
REPLAY_FN = "q_replay_snapshot"
check, expect_err, Fail = C1.check, C1.expect_err, C1.Fail
ALL_YES = {"Canada": "YES", "International": "YES", "CRA": "YES"}


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def sql(H, q, p=None, commit=True):
    with C1.migrator(H.server, H.db) as cx:
        c = cx.execute(q, p)
        r = c.fetchall() if c.description else []
        if commit:
            cx.commit()
        return r


def one(H, q, p=None):
    with C1.migrator(H.server, H.db) as cx:
        return cx.execute(q, p).fetchone()


def active_household(server, db, modules=None):
    """install_household_v2 + activation with the given modules; owner, member; verified 'Synthetic Bank' (CA)."""
    H = C1.v2_household(server, db)
    C1.installer_sql(server, db, "select bnx.install_activate_config(1, %s, %s::jsonb)", (C1.DIGEST, C1.env(H, C1.MODULES)))
    H.s4_config, H.s4_registry, H._inst = True, True, {}
    if modules and modules != C1.MODULES:
        set_modules(H, modules, "9" * 64)
    return H


def set_modules(H, modules, digest):
    """New configuration version: Owner draft -> acceptance -> installer activation (the only path)."""
    cv = H.cmd(H.owner, "prepare_config_draft", config_sha256=digest, schema="ai-entry/2.1", modules=modules)["config_version"]
    H.cmd(H.owner, "accept_instance_config", config_version=cv, config_sha256=digest, modules=modules)
    C1.installer_sql(H.server, H.db, "select bnx.install_activate_config(%s, %s, %s::jsonb)", (cv, digest, C1.env(H, modules)))
    return cv


def replay(H, snap):
    """R1 replay entry point; returns 'ok' or the refusal code."""
    try:
        r = H.app.call(REPLAY_FN, H.owner, {"snapshot_id": snap})
        return "ok" if r.get("projection_digest_verified") is True else json.dumps(r)
    except psycopg.Error as e:
        return e.diag.message_primary


# ------------------------------------------------------------------------------------------------ 9005 audit chain v2
@test("AT-CMD-06x", "S4B-F08; UA §5.10 (AT-CMD-06 extended)")
def t_audit_v2(server, ev):
    db = "bnx_s4c2aud"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=C1.r1_dir())                       # R1 head: v1 chain
    H = F.Household(server, db)
    H.expense(H.owner, "3.00")
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql")
    h.migrate(server, db)
    n_v1 = one(H, "select count(*) from bnx.audit_event where chain_version = 1")[0]
    uid = str(uuid.uuid4())
    cv = C1.installer_sql(server, db, "select bnx.adopt_existing_household('aud-test', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(ALL_YES)))[0][0]
    C1.installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                     (cv, C1.DIGEST, json.dumps({"project_id": "aud-test", "instance_uid": uid, "modules": ALL_YES})))
    env_cred = {**H.owner, "envelope": {"host_profile": "claude-desktop", "tool_name": "fin.balances", "tool_version": "1.2.0", "trace_id": "t-123"}}
    H.app.call("q_whoami", env_cred, {})
    H.cmd(env_cred, "create_category", kind="expense", currency="CAD", name_en="Audit test", name_zh="审计")
    r = one(H, "select (select min(seq) from bnx.audit_event where chain_version = 2), bnx.audit_verify(), "
               "(select row(host_profile, tool_name, tool_version, trace_id)::text from bnx.audit_event where command = 'create_category' order by seq desc limit 1)")
    first_v2, verify, envrow = r
    check(first_v2 == n_v1 + 1 and verify == 0 and envrow == "(claude-desktop,fin.balances,1.2.0,t-123)", f"{r} n_v1={n_v1}")
    with C1.migrator(server, db) as cx:                           # verification does not depend on the session TimeZone
        cx.execute("set timezone = 'Asia/Shanghai'")
        tz_ok = cx.execute("select bnx.audit_verify()").fetchone()[0]
        # field binding: swapping member/connection or editing the subject of a v2 row changes the hash
        swap = cx.execute("select hash = sha256(coalesce(prev_hash, '\\x'::bytea) || bnx.audit_canonical_v2(seq, connection_id, member_id, channel, command, subject, "
                          "encode(payload_sha256,'hex'), ledger_version, at_hashed, chain_version, host_profile, tool_name, tool_version, trace_id)) "
                          "from bnx.audit_event where chain_version = 2 and member_id is not null order by seq desc limit 1").fetchone()[0]
        # v1 boundary ambiguity (documented limit): concat_ws drops NULLs; v2 does not
        amb = cx.execute("select concat_ws('|', 1, null, 'x') = concat_ws('|', 1, 'x', null), "
                         "bnx.audit_canonical_v2(1, null, null, 'x', 'c', '{}', 'h', null, now(), 2::smallint, null, null, null, null) = "
                         "bnx.audit_canonical_v2(1, null, null, null, 'x', '{}', 'h', null, now(), 2::smallint, null, null, null, null)").fetchone()
        cx.execute("insert into bnx.audit_event(seq, channel, command, subject, payload_sha256, prev_hash, hash, chain_version, at_hashed) "
                   "select max(seq)+1, 'pwa', 'forged', '{}', '\\x00', (select hash from bnx.audit_event order by seq desc limit 1), '\\x00', 2, now() from bnx.audit_event")
        forged = cx.execute("select bnx.audit_verify(), (select max(seq) from bnx.audit_event)").fetchone()
        cx.rollback()
        cx.execute("set role bnx_definer")
        try:
            cx.execute("insert into bnx.audit_event(seq, channel, command, subject, payload_sha256, prev_hash, hash, chain_version) "
                       "select max(seq)+1, 'pwa', 'v1-late', '{}', '\\x00', null, '\\x00', 1 from bnx.audit_event")
            raise Fail("v1 row after v2 accepted")
        except psycopg.Error as e:
            check("AUDIT_CHAIN_VERSION" in str(e), str(e)); late = "AUDIT_CHAIN_VERSION"
            cx.rollback()
    bad_env = expect_err(H.app.call, "VALIDATION_FAILED", "q_whoami", {**H.owner, "envelope": {"trace_id": "x" * 101}}, {})
    # sessions that audit without resolve_actor (Worker, authn) cannot inject an envelope either (same-family review finding 6)
    direct = []
    for name, val in (("host_profile", "bad\nprofile"), ("tool_name", "t" * 5000)):
        with psycopg.connect(h.dsn(server, "postgres", db)) as cx:
            cx.execute("set role bnx_definer")
            cx.execute("select set_config(%s, %s, false)", ("bnx." + name, val))
            try:
                cx.execute("select bnx.audit(row(null, null, 'worker', null, null)::bnx.actor, 'probe', '{}', '{}', null)")
                raise Fail(f"audit accepted envelope {name}")
            except psycopg.Error as e:
                check(e.diag.message_primary == "VALIDATION_FAILED", str(e)); direct.append(e.diag.message_detail)
    head = one(H, "select bnx.audit_head()")[0]
    H.close()
    check(tz_ok == 0 and swap is False and amb == (True, False) and forged[0] == forged[1], f"tz={tz_ok} swap={swap} amb={amb} forged={forged}")
    return (f"{n_v1} R1 v1 events verify unchanged; first v2 seq {first_v2} (boundary); verify=0 also under TimeZone Asia/Shanghai; "
            f"envelope recorded and hashed; member/connection swap changes the v2 hash; v1 concat_ws ambiguity reproduced, v2 unambiguous; "
            f"forged v2 row detected at seq {forged[0]}; v1-after-v2 refused ({late}); oversized envelope -> {bad_env}; envelope GUCs set "
            f"directly in a session are refused at audit() too {direct}; head {head['seq']}")


# ------------------------------------------------------------------------------------------------ 9006 registry
@test("AT-REG-01-03,09", "Amendment 02 §2 tests 1-3, 9")
def t_seed(server, ev):
    db = "bnx_s4c2seed"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        r = cx.execute("select count(*) filter (where seed_set = 'CN_TRADITIONAL_FIVE'), count(*) filter (where seed_set = 'CN_JOINT_STOCK_TWELVE'), "
                       "count(*) filter (where status = 'ACTIVE_SEED'), count(distinct code), count(*) from bnx.institution").fetchone()
        psbc = cx.execute("select exists (select 1 from bnx.institution where code = 'PSBC'), exists (select 1 from bnx.retired_code where code = 'PSBC')").fetchone()
        hsbc = cx.execute("select array_agg(code || ':' || jurisdiction order by code) from bnx.institution where code like 'HSBC%'").fetchone()[0]
        try:
            cx.execute("insert into bnx.institution(id, code, kind, jurisdiction, classification, seed_set, status) "
                       "values (gen_random_uuid(), 'PSBC', 'bank', 'CN', 'CN_NATIONWIDE_JOINT_STOCK_COMMERCIAL', null, 'VERIFIED_ACTIVE')")
            raise Fail("PSBC as joint-stock accepted")
        except psycopg.errors.CheckViolation:
            cx.rollback(); cx.execute("set role bnx_definer")
        cur = sorted(x[0] for x in cx.execute("select code from bnx.currency"))
        prov = dict(cx.execute("select code, jurisdiction from bnx.institution where kind like 'payment%%' order by code").fetchall())
    check(r[0] == 5 and r[1] == 12 and r[3] == r[4] == r[2] and psbc == (False, True) and hsbc == ["HSBC_CN:CN", "HSBC_HK:HK"]
          and {"HKD", "GBP", "AUD", "SGD", "CHF"} <= set(cur)
          and prov == {"ALIPAY": "CN", "APPLE_PAY": "CA", "PAYPAL": "CA", "UNIONPAY": "CN", "WECHAT_PAY": "CN"}, f"{r} {psbc} {hsbc} {cur} {prov}")
    return (f"5 traditional + 12 joint-stock CN banks; {r[2]} seed institutions with {r[3]} unique codes; PSBC not seeded, code reserved, "
            f"never joint-stock (CHECK); HSBC_HK/HSBC_CN separate jurisdictions; currencies {cur}; provider jurisdictions (F-C2-05) {prov}")


@test("AT-REG-07,08", "Amendment 02 tests 7-8 (brand issuer history)")
def t_brands(server, ev):
    db = "bnx_s4c2brand"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        q = lambda b, d: cx.execute("select i.code from bnx.institution i where i.id = bnx.brand_issuer_at(%s, %s)", (b, d)).fetchone()
        r = {"PC_FINANCIAL_BANKING@2015": q("PC_FINANCIAL_BANKING", "2015-06-01"), "PC_FINANCIAL_BANKING@2018": q("PC_FINANCIAL_BANKING", "2018-06-01"),
             "SIMPLII@2020": q("SIMPLII", "2020-01-01"), "PC_FINANCIAL_CARDS@2026-08": q("PC_FINANCIAL_CARDS", "2026-08-01"),
             "TRIANGLE@2024": q("TRIANGLE", "2024-05-01")}
        rel = cx.execute("select i.code, j.code, e.kind, e.effective_from::text from bnx.institution_relationship_event e "
                         "join bnx.institution i on i.id = e.institution_id join bnx.institution j on j.id = e.related_institution_id").fetchall()
    check(r["PC_FINANCIAL_BANKING@2015"] == ("CIBC",) and r["PC_FINANCIAL_BANKING@2018"] is None and r["SIMPLII@2020"] == ("CIBC",)
          and r["PC_FINANCIAL_CARDS@2026-08"] == ("PC_BANK",) and r["TRIANGLE@2024"] == ("CTB",)
          and rel == [("PC_BANK", "EQB", "acquired_by", "2026-07-02")], f"{r} {rel}")
    return f"brand issuers {r}; EQB acquisition recorded as a relationship {rel[0]} and does not rewrite the PC cards issuer"


@test("AT-REG-15", "UA §5.4.4; Amendment 02 §3 step 8 (negatives)")
def t_account_eligibility(server, ev):
    H = active_household(server, "bnx_s4c2reg15", C1.MODULES | {"International": "YES"})
    c = H.cmd(H.owner, "propose_institution_candidate", name_en="Unknown Credit Union", jurisdiction="CA")
    check(c["result"] == "PENDING_VERIFICATION", str(c))
    out = [expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "create_account", kind="bank_deposit", institution="Synthetic Bank", label="x", currencies=["CAD"]),
           expect_err(H.cmd, "INSTITUTION_NOT_ELIGIBLE", H.owner, "create_account", kind="bank_deposit", institution_code="PSBC", label="x", currencies=["CAD"]),
           expect_err(H.cmd, "INSTITUTION_NOT_ELIGIBLE", H.owner, "create_account", kind="bank_deposit", institution_id=c["candidate_id"], label="x", currencies=["CAD"]),
           expect_err(H.cmd, "JURISDICTION_REQUIRED", H.owner, "create_account", kind="cash", label="x", currencies=["CAD"], region_scope="UNKNOWN")]
    ok = [H.cmd(H.owner, "create_account", kind="bank_deposit", institution_code="CMB", label="CMB", currencies=["CNY"])["region_scope"],
          H.cmd(H.owner, "create_account", kind="e_wallet", institution_code="PAYPAL", label="PayPal", currencies=["USD"], region_scope="OTHER:US")["region_scope"],
          H.cmd(H.owner, "create_account", kind="e_wallet", institution_code="ALIPAY", label="Alipay", currencies=["CNY"])["region_scope"],
          H.cmd(H.owner, "create_account", kind="cash", label="Wallet", currencies=["CAD"])["region_scope"],
          H.cmd(H.owner, "create_account", kind="bank_deposit", institution_code="CTB", label="HKD", currencies=["HKD"])["region_scope"]]
    pend = one(H, "select id from bnx.institution where status = 'ACTIVE_SEED' limit 1")[0]
    with C1.migrator(H.server, H.db) as cx:                     # defence in depth: no path creates an account on an ineligible institution
        cx.execute("update bnx.institution set status = 'REJECTED' where code = 'HXB'")
        try:
            cx.execute("insert into bnx.account(id, kind, institution_id, label, reference_kind, visibility, timezone, origin, state, created_by, region_scope) "
                       "select gen_random_uuid(), 'bank_deposit', id, 'direct', 'managed', 'household', 'UTC', 'manual', 'active', gen_random_uuid(), 'CN' "
                       "from bnx.institution where code = 'HXB'")
            raise Fail("direct insert accepted")
        except psycopg.Error as e:
            check("INSTITUTION_NOT_ELIGIBLE" in str(e), str(e)); out.append("trigger: INSTITUTION_NOT_ELIGIBLE")
            cx.rollback()
    tz = one(H, "select distinct timezone from bnx.account")[0]
    H.close()
    check(ok == ["CN", "CA", "CN", "NONE", "CA"] and tz == "America/Toronto", f"{ok} {tz}")
    return (f"refused: {out}; accepted regions {ok} (CMB; PayPal CA by Owner decision F-C2-05, declared region ignored; Alipay CN; cash; "
            f"CTB in HKD); timezone from financial_policy = {tz}")


@test("AT-REG-04-06", "Amendment 02 §3 steps 2-5, 8 (discovery candidates)")
def t_candidates(server, ev):
    H = active_household(server, "bnx_s4c2cand")
    a = H.cmd(H.owner, "propose_institution_candidate", name_en="Maple Ridge Credit Union Ltd.", jurisdiction="CA")
    b = H.cmd(H.member, "propose_institution_candidate", name_en="MAPLE RIDGE CREDIT UNION", jurisdiction="CA", evidence=[{"doc": "2"}])
    m = H.cmd(H.owner, "propose_institution_candidate", name_zh="招商銀行", name_en=None)
    m2 = H.cmd(H.owner, "propose_institution_candidate", name_en="China Merchants Bank Co., Ltd.")
    # two verified institutions with the same normalized name -> ambiguous
    for j in ("CA", "US"):
        c = H.cmd(H.owner, "propose_institution_candidate", name_en="Northern Trust Bank", jurisdiction=j)
        H.cmd(H.owner, "verify_institution", candidate_id=c["candidate_id"], evidence_ref="synthetic", kind="bank")
    amb = H.cmd(H.owner, "propose_institution_candidate", name_en="Northern Trust Bank")
    n = one(H, "select count(*), (select jsonb_array_length(evidence) from bnx.institution_discovery_candidate where id = %s) "
               "from bnx.institution_discovery_candidate where candidate_key like 'mapleridgecreditunion%%'", (a["candidate_id"],))
    rq = H.q(H.owner, "registry_review")
    codes = [x["code"] for x in H.q(H.owner, "institutions_search", text="Northern Trust")["institutions"]]
    r = expect_err(H.cmd, "INSTITUTION_NOT_ELIGIBLE", H.owner, "create_account", kind="bank_deposit", institution_id=a["candidate_id"], label="x", currencies=["CAD"])
    H.close()
    check(a["result"] == "PENDING_VERIFICATION" and b["candidate_id"] == a["candidate_id"] and n == (1, 1)
          and m["result"] == "MATCHED" and m2["result"] == "MATCHED" and m["institution_id"] == m2["institution_id"]
          and amb["result"] == "AMBIGUOUS" and len([c for c in rq["candidates"] if c["state"] in ("PENDING_VERIFICATION", "AMBIGUOUS")]) == 2
          and codes == ["NORTHERN_TRUST_BANK", "NORTHERN_TRUST_BANK_US"], f"{a} {b} {n} {m} {m2} {amb} {codes}")
    return (f"unknown bank -> one PENDING candidate, reused by a later variant spelling (no duplicate); traditional-Chinese and legal-suffix "
            f"variants match CMB; same name in CA and US -> codes {codes}, unqualified proposal -> AMBIGUOUS; candidate cannot hold an account ({r})")


@test("AT-REG-17", "S4B-F05; UA §5.4.2 data migration (upgrade of free-text institutions)")
def t_registry_upgrade(server, ev):
    db = "bnx_s4c2reg17"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=C1.r1_dir())
    H = F.Household(server, db)                                    # R1: "Synthetic Bank" free text
    accs = {}
    for name in ("Industrial and Commercial Bank of China Limited", "中國工商銀行", "SYNTHETIC BANK.", "Rogue Credit Union"):
        accs[name] = H.cmd(H.owner, "create_account", kind="bank_deposit", institution=name, label=name, currencies=["CAD"])["account_id"]
    H.expense(H.owner, "7.00")
    bal_pre = H.balance(H.owner)
    with C1.migrator(server, db) as cx:
        fp_pre = cx.execute(C1.FP_SQL).fetchone()[0]
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql"); h.migrate(server, db)
    rows = dict((r[0], r[1:]) for r in sql(H, "select coalesce(name_en, name_zh), status, code, merged_into_id is not null from bnx.institution "
                                             "where coalesce(name_en, name_zh) in ('Industrial and Commercial Bank of China Limited', '中國工商銀行', "
                                             "'Synthetic Bank', 'SYNTHETIC BANK.', 'Rogue Credit Union')"))
    acc = dict((r[0], r[1:]) for r in sql(H, "select label, region_scope, institution_grandfathered, (select count(*) from bnx.account_institution_event e where e.account_id = a.id), "
                                             "(select i.code from bnx.institution i where i.id = a.institution_id) from bnx.account a"))
    st = {k: v[0] for k, v in rows.items()}
    check(st["Industrial and Commercial Bank of China Limited"] == "ACTIVE_SEED" and rows["Industrial and Commercial Bank of China Limited"][1] == "ICBC"
          and st["中國工商銀行"] == "MERGED_INTO" and st["Rogue Credit Union"] == "PENDING_VERIFICATION"
          and {st["Synthetic Bank"], st["SYNTHETIC BANK."]} == {"PENDING_VERIFICATION", "MERGED_INTO"}, str(rows))
    check(acc["中國工商銀行"][3] == "ICBC" and acc["中國工商銀行"][2] == 2 and acc["中國工商銀行"][0] == "CN"
          and acc["Rogue Credit Union"][:2] == ("UNKNOWN", True) and acc["Joint chequing"][:2] == ("UNKNOWN", True), str(acc))
    uid = str(uuid.uuid4())
    cv = C1.installer_sql(server, db, "select bnx.adopt_existing_household('reg-upgrade', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(ALL_YES)))[0][0]
    C1.installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                     (cv, C1.DIGEST, json.dumps({"project_id": "reg-upgrade", "instance_uid": uid, "modules": ALL_YES})))
    # grandfathered account with UNKNOWN region: fail closed until the Owner verifies the institution
    blocked = expect_err(H.expense, "SCOPE_DISABLED", H.owner, "1.00", date="2026-04-01")
    warn = H.q(H.owner, "balances")["scope_warnings"]
    review = H.q(H.owner, "registry_review")
    syn = one(H, "select id from bnx.institution where coalesce(name_en,'') in ('Synthetic Bank','SYNTHETIC BANK.') and status = 'PENDING_VERIFICATION'")[0]
    H.cmd(H.owner, "verify_institution", institution_id=str(syn), evidence_ref="synthetic-statement-header", jurisdiction="CA")
    H.expense(H.owner, "1.00", date="2026-04-01")
    bal_post = H.balance(H.owner)
    with C1.migrator(server, db) as cx:
        fp_mid = cx.execute("select bnx.ledger_fingerprint()").fetchone()[0]
        ev_pre = cx.execute("select pre_fingerprint from bnx.release_install_event where kind = 'ADOPT'").fetchone()[0]
    H.close()
    check(fp_pre == ev_pre and warn == ["EXCLUDED_SCOPE:UNKNOWN"] and len(review["grandfathered_accounts"]) >= 2
          and float(bal_post) == float(bal_pre) - 1.0, f"fp {fp_pre} {ev_pre}; {warn}; {review}; {bal_pre}->{bal_post}")
    return (f"free text -> ICBC linked by legal-name normalization; traditional 中國工商銀行 merged into it (account re-pointed: INITIAL+MERGE events, "
            f"region CN); 'Synthetic Bank'/'SYNTHETIC BANK.' collapsed; unmatched rows PENDING_VERIFICATION, accounts grandfathered with region UNKNOWN; "
            f"ledger untouched by the upgrade (fingerprint); after activation the UNKNOWN account is fail-closed (posting {blocked}, balances {warn}) "
            f"until the Owner verifies the institution (jurisdiction CA) -> posting works")


@test("AT-REG-18", "RR-02; UA §5.4.5 (reassignment, history, drift, rollback)")
def t_reassign(server, ev):
    H = active_household(server, "bnx_s4c2reg18", ALL_YES)
    acc = H.cmd(H.owner, "create_account", kind="credit_card", institution_code="CTB", label="Triangle card", currencies=["CAD"])
    v0 = acc["ledger_version"]
    tgt = one(H, "select id from bnx.institution where code = 'PC_BANK'")[0]
    hx = one(H, "select id from bnx.institution where code = 'HSBC_HK'")[0]
    out = [expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "reassign_account_institution", account_id=acc["account_id"], institution_id=str(tgt), authorization_ref="x"),
           expect_err(H.cmd, "VALIDATION_FAILED", H.owner, "reassign_account_institution", account_id=acc["account_id"], institution_id=str(tgt))]
    with C1.migrator(H.server, H.db) as cx:
        cx.execute("update bnx.institution set status = 'REJECTED' where code = 'EQB'")
        cx.commit()
    eqb = one(H, "select id from bnx.institution where code = 'EQB'")[0]
    out.append(expect_err(H.cmd, "INSTITUTION_NOT_ELIGIBLE", H.owner, "reassign_account_institution", account_id=acc["account_id"], institution_id=str(eqb), authorization_ref="x"))
    n_ev = one(H, "select count(*) from bnx.account_institution_event where account_id = %s", (acc["account_id"],))[0]
    r = H.cmd(H.owner, "reassign_account_institution", account_id=acc["account_id"], institution_id=str(tgt), authorization_ref="owner-T3-2026-11-05",
              reason="CORRECTION")
    r2 = H.cmd(H.owner, "reassign_account_institution", account_id=acc["account_id"], institution_id=str(hx), authorization_ref="owner-T3-b")
    with C1.migrator(H.server, H.db) as cx:
        hist = cx.execute("select (select code from bnx.institution where id = bnx.institution_at(%s, current_date - 1, 9223372036854775807)), "
                          "(select code from bnx.institution where id = bnx.institution_at(%s, current_date, %s)), "
                          "(select code from bnx.institution where id = bnx.institution_at(%s, current_date, %s)), "
                          "(select code from bnx.institution where id = bnx.institution_at(%s, current_date, 9223372036854775807)), "
                          "(select region_scope from bnx.account where id = %s)",
                          (acc["account_id"], acc["account_id"], v0, acc["account_id"], r["ledger_version"], acc["account_id"], acc["account_id"])).fetchone()
        try:
            cx.execute("update bnx.account set institution_id = %s where id = %s", (tgt, acc["account_id"])); raise Fail("direct update accepted")
        except psycopg.Error as e:
            check("INSTITUTION_REASSIGN_REQUIRED" in str(e), str(e)); out.append("direct UPDATE: INSTITUTION_REASSIGN_REQUIRED"); cx.rollback()
        cx.execute("set role bnx_definer")
        cx.execute("select set_config('bnx.institution_reassign', pg_current_xact_id()::text, true)")
        cx.execute("update bnx.account set institution_id = %s where id = %s", (tgt, acc["account_id"]))
        try:
            cx.commit(); raise Fail("drift committed")
        except psycopg.Error as e:
            check("PROJECTION_DRIFT" in str(e), str(e)); out.append("projection without event: PROJECTION_DRIFT at commit")
    n_after = one(H, "select count(*) from bnx.account_institution_event where account_id = %s", (acc["account_id"],))[0]
    H.close()
    check(n_ev == 1 and n_after == 3 and hist[0] is None and hist[1] == "CTB" and hist[2] == "PC_BANK" and hist[3] == "HSBC_HK" and hist[4] == "HK",
          f"{n_ev} {n_after} {hist}")
    return (f"refused (no partial event/projection): {out}; events INITIAL -> CORRECTION -> CORRECTION; institution_at: before the account existed none, "
            f"at the old ledger version CTB, at the new version PC_BANK, now HSBC_HK; region follows (HK)")


@test("AT-POL-01", "UA §5.4.1 (financial policy)")
def t_policy(server, ev):
    H = active_household(server, "bnx_s4c2pol", ALL_YES)
    p0 = one(H, "select version, declared_by, confirmed_by is null from bnx.financial_policy order by version desc limit 1")
    rq = H.q(H.owner, "registry_review")["financial_policy_unconfirmed"]
    r = expect_err(H.cmd, "FORBIDDEN_ROLE", H.member, "declare_financial_policy", household_timezone="Asia/Shanghai")
    H.cmd(H.owner, "declare_financial_policy", household_timezone="Asia/Shanghai", reporting_currency="CAD")
    acc = H.cmd(H.owner, "create_account", kind="bank_deposit", institution_code="BOC", label="BOC", currencies=["CNY"])
    tz = one(H, "select timezone from bnx.account where id = %s", (acc["account_id"],))[0]
    p1 = one(H, "select version, declared_by, confirmed_by is not null from bnx.financial_policy order by version desc limit 1")
    upd = expect_err(C1.installer_sql, "APPEND_ONLY", H.server, H.db, "update bnx.financial_policy set household_timezone = 'UTC'")
    H.close()
    check(p0 == (1, "installer", True) and rq is True and p1 == (2, "owner", True) and tz == "Asia/Shanghai", f"{p0} {rq} {p1} {tz}")
    return f"installer policy v1 (unconfirmed, in the Owner queue); member refused ({r}); Owner declaration v2; new account timezone {tz}; history append-only ({upd})"


# ------------------------------------------------------------------------------------------------ 9007 module flags
@test("AT-FLG-01-09", "S4B-F06/F07; UA §4.4.1; BNX-S2-01 §5.2-5.4")
def t_flags(server, ev):
    H = active_household(server, "bnx_s4c2flg", ALL_YES)
    ca = H.cmd(H.owner, "create_account", kind="bank_deposit", institution_code="CTB", label="CA", currencies=["CAD"])
    cn = H.cmd(H.owner, "create_account", kind="bank_deposit", institution_code="ICBC", label="CN", currencies=["CNY"])
    cash = H.cmd(H.owner, "create_account", kind="cash", label="Cash", currencies=["CAD"])
    eq_ca = H.cmd(H.owner, "create_category", kind="expense", currency="CAD", name_en="Exp CAD", name_zh="支出")["ledger_account_id"]
    eq_cn = H.cmd(H.owner, "create_category", kind="expense", currency="CNY", name_en="Exp CNY", name_zh="支出")["ledger_account_id"]
    acs = lambda r: r["account_currencies"][0]
    for a, cat, amt in ((ca, eq_ca, "10.00"), (cn, eq_cn, "20.00")):
        H.expense(H.owner, amt, ac=acs(a), cat=cat)
    snap = H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    n_rows = one(H, "select count(*) from bnx.journal_line")[0]
    set_modules(H, {"Canada": "YES", "International": "NO", "CRA": "YES"}, "1" * 64)
    out = {}
    out["create CN account"] = expect_err(H.cmd, "SCOPE_DISABLED", H.owner, "create_account", kind="bank_deposit", institution_code="BOC", label="x", currencies=["CNY"])
    out["post on CN"] = expect_err(H.expense, "SCOPE_DISABLED", H.owner, "1.00", ac=acs(cn), cat=eq_cn)
    out["widen grant on CN"] = expect_err(H.cmd, "SCOPE_DISABLED", H.owner, "set_grant", member_id=H.member_id, account_id=cn["account_id"], can_view=True, can_post=True)
    # F-C2-13 (Owner 2026-11-06): reductions are allowed while the region is off. Full revocation is a DELETE in R1
    # cmd_set_grant (never gated); a partial reduction (keep view, drop post) is an upsert and is now allowed too.
    H.cmd(H.owner, "set_grant", member_id=H.owner_id, account_id=cn["account_id"], can_view=True, can_post=False)
    H.cmd(H.owner, "set_grant", member_id=H.member_id, account_id=cn["account_id"], can_view=False, can_post=False)
    g = dict((str(r[0]), r[1:]) for r in sql(H, "select member_id, can_view, can_post from bnx.account_grant where account_id = %s", (cn["account_id"],)))
    revoked = g.get(str(H.owner_id)) == (True, False) and str(H.member_id) not in g
    H.expense(H.owner, "1.00", ac=acs(ca), cat=eq_ca)                # CA still works
    H.expense(H.owner, "2.00", ac=acs(cash), cat=eq_ca)              # NONE is never gated
    b = H.q(H.owner, "balances")
    vis = {x["account_currency_id"] for x in b["balances"]}
    rep = replay(H, snap["snapshot_id"])
    n_rows2 = one(H, "select count(*) from bnx.journal_line")[0]
    set_modules(H, ALL_YES, "2" * 64)                                # re-enabling needs no migration
    rep2 = replay(H, snap["snapshot_id"])
    b2 = H.q(H.owner, "balances")
    set_modules(H, {"Canada": "NO", "International": "NO", "CRA": "NO"}, "3" * 64)
    out["post on CA (all NO)"] = expect_err(H.expense, "SCOPE_DISABLED", H.owner, "1.00", ac=acs(ca), cat=eq_ca)
    H.expense(H.owner, "1.00", ac=acs(cash), cat=eq_ca)              # empty-scope instance: cash with NONE only
    b3 = H.q(H.owner, "balances")
    # restore mode (installer identity only) bypasses the gate; bnx_app with the GUC does not (AT-BAK-03 pattern)
    with C1.migrator(H.server, H.db) as cx:
        cx.execute("set bnx.restore_mode = 'on'")
        cx.execute("insert into bnx.account_scope_event(id, account_id, ownership_scope, effective_from, recorded_version, actor) "
                   "values (gen_random_uuid(), %s, 'joint', '2026-01-01', 1, gen_random_uuid())", (ca["account_id"],))
        cx.rollback()
    H.close()
    check(revoked is True, f"reductions on a disabled region must succeed (F-C2-13): {g}")
    check(acs(cn)["account_currency_id"] not in vis and acs(ca)["account_currency_id"] in vis
          and b["scope_warnings"] == ["EXCLUDED_SCOPE:International"] and rep == "ACCESS_REVOKED", f"{b} {rep}")
    check(n_rows2 == n_rows + 4 and acs(cn)["account_currency_id"] in {x["account_currency_id"] for x in b2["balances"]} and b2["scope_warnings"] == []
          and rep2 == "ok" and b3["scope_warnings"] == ["EXCLUDED_SCOPE:Canada", "EXCLUDED_SCOPE:International"]
          and {x["account_currency_id"] for x in b3["balances"]} == {acs(cash)["account_currency_id"]}, f"{n_rows} {n_rows2} {b2} {rep2} {b3}")
    return (f"International=NO: refused {list(out)} -> SCOPE_DISABLED; partial reduction (owner post removed) and full revocation (member) allowed (F-C2-13); CA and cash (NONE) post; balances exclude CN with "
            f"scope_warnings {b['scope_warnings']}; snapshot made under YES replays ACCESS_REVOKED, verifies again after re-enabling (digest "
            f"untouched); nothing deleted; NO/NO/NO: only the NONE cash account is reachable ({b3['scope_warnings']}); restore mode bypasses")


@test("AT-FLG-10", "S4B-F06/F18 (upgrade fails closed until activation)")
def t_failclosed(server, ev):
    db = "bnx_s4c2flg10"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=C1.r1_dir())
    H = F.Household(server, db)
    acc = H.cmd(H.owner, "create_account", kind="bank_deposit", institution="Industrial and Commercial Bank of China", label="ICBC", currencies=["CNY"])
    cat = H.cmd(H.owner, "create_category", kind="expense", currency="CNY", name_en="E", name_zh="E")["ledger_account_id"]
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql"); h.migrate(server, db)
    ac = acc["account_currencies"][0]
    out = [expect_err(H.expense, "SCOPE_UNCONFIGURED", H.owner, "1.00", ac=ac, cat=cat),
           expect_err(H.q, "SCOPE_UNCONFIGURED", H.owner, "balances"),
           expect_err(H.cmd, "SCOPE_UNCONFIGURED", H.owner, "create_report_snapshot", report_code="R-BAL")]
    uid = str(uuid.uuid4())
    cv = C1.installer_sql(server, db, "select bnx.adopt_existing_household('flg10', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(ALL_YES)))[0][0]
    out.append(expect_err(H.expense, "SCOPE_UNCONFIGURED", H.owner, "1.00", ac=ac, cat=cat))   # adopted but not yet activated
    C1.installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                     (cv, C1.DIGEST, json.dumps({"project_id": "flg10", "instance_uid": uid, "modules": ALL_YES})))
    H.expense(H.owner, "1.00", ac=ac, cat=cat)
    H.close()
    return f"after upgrade (R1 account linked to ICBC, region CN): {out} until install_activate_config; then posting works (no implicit YES)"


@test("AT-FLG-11", "S4B-F06; UA §4.4.1 (generated matrix = design, for tables that exist)")
def t_matrix(server, ev):
    db = "bnx_s4c2flg11"
    h.bootstrap(server, db); h.migrate(server, db)
    with C1.migrator(server, db) as cx:
        m = cx.execute("select bnx.flag_enforcement_matrix()").fetchone()[0]
        exist = {r[0] for r in cx.execute("select table_name from information_schema.tables where table_schema = 'bnx'")}
    design = ["account", "account_currency", "journal_line", "posting_date_confirmation", "account_ownership_event", "account_scope_event",
              "account_grant", "evidence_file", "statement", "source_txn", "clearing_item", "posting_scope_claim", "balance_observation_event",
              "loan", "card_fee_event"]
    present = sorted(t for t in design if t in exist)
    absent = sorted(t for t in design if t not in exist)
    got = sorted(x["table"] for x in m)
    extra = sorted(set(got) - set(design))
    check(set(present) <= set(got) and extra == ["account_holder_event", "ai_connection", "card_link_event", "posting_plan"], f"{got} vs {present}; extra {extra}")
    return (f"generated matrix covers all {len(present)} §4.4.1 tables that exist; not yet created (trigger due in their migration): {absent}; "
            f"additional enforcement points: {extra} (prologue rows of §4.4.1 enforced at table level, F-C2-06)")


@test("AT-MUT-02", "S4B-F06 (mutation: the tests detect removal of the gate)")
def t_mutation(server, ev):
    H = active_household(server, "bnx_s4c2mut", {"Canada": "YES", "International": "NO", "CRA": "NO"})
    with C1.migrator(H.server, H.db) as cx:
        try:
            cx.execute("insert into bnx.account(id, kind, institution_id, label, reference_kind, visibility, timezone, origin, state, created_by, region_scope) "
                       "select gen_random_uuid(), 'bank_deposit', id, 'm', 'managed', 'household', 'UTC', 'manual', 'active', gen_random_uuid(), 'CN' "
                       "from bnx.institution where code = 'ICBC'")
            raise Fail("gate missing")
        except psycopg.Error as e:
            check("SCOPE_DISABLED" in str(e), str(e)); cx.rollback()
        cx.execute("set role bnx_definer")
        cx.execute("drop trigger t_scope_flag_account on bnx.account")
        cx.execute("insert into bnx.account(id, kind, institution_id, label, reference_kind, visibility, timezone, origin, state, created_by, region_scope) "
                   "select gen_random_uuid(), 'bank_deposit', id, 'm', 'managed', 'household', 'UTC', 'manual', 'active', gen_random_uuid(), 'CN' "
                   "from bnx.institution where code = 'ICBC'")
        cx.rollback()
    H.close()
    return "with t_scope_flag_account a CN account insert is refused (SCOPE_DISABLED); with the trigger dropped the same insert commits (mutant detected); rolled back"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core2", a.server)
    os.makedirs(ev, exist_ok=True)
    h.drop_all(a.server)
    t0 = time.time()
    for tid, ref, fn in TESTS:
        if a.only and not tid.startswith(a.only):
            continue
        s = time.time()
        try:
            msg = fn(a.server, ev); status = "SKIP" if isinstance(msg, str) and msg.startswith("SKIP:") else "PASS"
            msg = msg[5:] if status == "SKIP" else msg
        except Exception as e:  # noqa: BLE001
            status, msg = "FAIL", f"{type(e).__name__}: {e}"
            traceback.print_exc()
        RESULTS.append({"id": tid, "ref": ref, "status": status, "detail": msg, "seconds": round(time.time() - s, 2)})
        print(f"{status} {tid} [{ref}] ({time.time() - s:.1f}s): {msg}", flush=True)
    with psycopg.connect(h.dsn(a.server, "postgres", "postgres")) as cx:
        ver = cx.execute("select version()").fetchone()[0]
    summary = {"server": a.server, "version": ver, "python": sys.version.split()[0], "psycopg": psycopg.__version__, "seconds": round(time.time() - t0, 1),
               "pass": sum(r["status"] == "PASS" for r in RESULTS), "fail": sum(r["status"] == "FAIL" for r in RESULTS),
               "skip": sum(r["status"] == "SKIP" for r in RESULTS), "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core2_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
