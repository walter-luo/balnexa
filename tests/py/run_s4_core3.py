#!/usr/bin/env python3
"""S4 V1.2 increment 3 tests: 9008 economic-type rules and chunked plan posting, 9009 OAuth (fixes, refresh, DCR, legacy
scope boundary). Conventions as run_g0.py. Usage: run_s4_core3.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, base64, hashlib, json, os, sys, threading, time, traceback, uuid
import psycopg
import harness as h
import fixture as F
import run_s4_core1 as C1
import run_s4_core2 as C2

RESULTS, TESTS = [], []
check, expect_err, Fail = C1.check, C1.expect_err, C1.Fail
ALL_YES = C2.ALL_YES


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def one(H, q, p=None):
    return C2.one(H, q, p)


def ledger(H, kind, cur, name):
    return str(one(H, "select bnx.system_ledger_account(%s, %s, %s)", (kind, cur, name))[0])


def journal(H, et, lines, commit=True):
    """Defence-in-depth probe: one journal written directly as bnx_definer; the deferred rule fires at COMMIT."""
    jid = str(uuid.uuid4())
    cx = H.definer()
    try:
        cx.execute("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, "
                   "ledger_version, origin_channel, created_by_member, confirmed_by_member) values (%s, %s, '2026-02-01', '2026-02-01', "
                   "'estimated', 'probe', bnx.next_version(), 'pwa', %s, %s)", (jid, et, H.owner_id, H.owner_id))
        for la, cur, amt in lines:
            cx.execute("insert into bnx.journal_line(id, journal_id, ledger_account_id, currency, amount) values (gen_random_uuid(), %s, %s, %s, %s)",
                       (jid, la, cur, amt))
        cx.commit() if commit else cx.rollback()
    finally:
        cx.close()
    return jid


def household(server, db):
    """Phase-2 fixture household (R1 fixture + adopt/activate + registry) with a credit card and an investment account."""
    H = F.Household(server, h.fresh(server, db))
    card = H.cmd(H.owner, "create_account", kind="credit_card", **H.inst("Synthetic Bank"), label="Card", currencies=["CAD"])
    inv = H.cmd(H.owner, "create_account", kind="investment", **H.inst("Synthetic Bank"), label="Brokerage", currencies=["CAD"])
    H.card = card["account_currencies"][0]["ledger_account_id"]
    H.inv = inv["account_currencies"][0]["ledger_account_id"]
    return H


# ------------------------------------------------------------------------------------------------ 9008
@test("AT-ECON-01-04", "S4B-F15; UA §5.3.4; Draft-04 B6.1")
def t_econ(server, ev):
    H = household(server, "bnx_s4c3econ")
    bank, usd = H.cad["ledger_account_id"], H.usd["ledger_account_id"]
    eq = ledger(H, "equity", "CAD", "Opening Balances")
    clr = ledger(H, "clearing", "CAD", "Transfers in transit")
    fxc, fxu = ledger(H, "fx_trading", "CAD", "FX CAD"), ledger(H, "fx_trading", "USD", "FX USD")
    ok = {
        "consumption_expense": [(H.groceries, "CAD", "10.00"), (bank, "CAD", "-10.00")],
        "card_spend": [(H.groceries, "CAD", "20.00"), (H.card, "CAD", "-20.00")],
        "refund": [(bank, "CAD", "5.00"), (H.groceries, "CAD", "-5.00")],
        "income": [(bank, "CAD", "100.00"), (H.salary, "CAD", "-100.00")],
        "card_repayment": [(H.card, "CAD", "20.00"), (bank, "CAD", "-20.00")],
        "investment_subscription": [(H.inv, "CAD", "50.00"), (bank, "CAD", "-50.00")],
        "transfer_to_clearing": [(clr, "CAD", "7.00"), (bank, "CAD", "-7.00")],
        "fx_conversion": [(bank, "CAD", "-137.00"), (fxc, "CAD", "137.00"), (fxu, "USD", "-100.00"), (usd, "USD", "100.00")],
        "opening_balance": [(bank, "CAD", "1.00"), (eq, "CAD", "-1.00")],
    }
    bad = {
        "consumption_expense": [(H.salary, "CAD", "10.00"), (bank, "CAD", "-10.00")],       # income line in an expense
        "card_spend": [(H.groceries, "CAD", "20.00"), (bank, "CAD", "-20.00")],             # spend not on a card
        "income": [(bank, "CAD", "-100.00"), (H.salary, "CAD", "100.00")],                  # wrong signs
        "card_repayment": [(H.groceries, "CAD", "20.00"), (bank, "CAD", "-20.00")],         # no card leg
        "fx_conversion": [(bank, "CAD", "-10.00"), (H.groceries, "CAD", "10.00")],          # no fx_trading legs
        "transfer_to_clearing": [(H.groceries, "CAD", "7.00"), (bank, "CAD", "-7.00")],     # no clearing leg
        "opening_balance": [(bank, "CAD", "1.00"), (H.salary, "CAD", "-1.00")],             # no equity leg
        "internal_transfer": [(bank, "CAD", "3.00"), (H.groceries, "CAD", "-3.00")],        # one account-currency only
    }
    for et, lines in ok.items():
        journal(H, et, lines)
    refused = []
    for et, lines in bad.items():
        m = expect_err(journal, "ECONOMIC_TYPE_RULE_VIOLATION", H, et, lines)
        refused.append(et)
    # R1 completeness errors keep precedence over the rule (header-only, unbalanced)
    pre = [expect_err(journal, "JOURNAL_INCOMPLETE", H, "card_spend", []),
           expect_err(journal, "JOURNAL_UNBALANCED", H, "card_spend", [(H.groceries, "CAD", "20.00"), (bank, "CAD", "-19.00")])]
    n = one(H, "select count(*) from bnx.economic_type_rule")[0]
    H.close()
    check(n == 26 and len(refused) == len(bad), f"{n} {refused}")
    return f"26 B6.1 rules seeded; {len(ok)} valid journals commit ({sorted(ok)}); refused at COMMIT: {refused}; R1 completeness errors keep precedence {pre}"


@test("AT-ECON-05", "S4B-F15 (historical journals are not re-judged)")
def t_econ_history(server, ev):
    db = "bnx_s4c3econ5"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=C1.r1_dir())
    H = F.Household(server, db)
    old = journal(H, "consumption_expense", [(H.salary, "CAD", "10.00"), (H.cad["ledger_account_id"], "CAD", "-10.00")])  # violates B6.1
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql"); h.migrate(server, db)
    uid = str(uuid.uuid4())
    cv = C1.installer_sql(server, db, "select bnx.adopt_existing_household('econ5', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(ALL_YES)))[0][0]
    C1.installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                     (cv, C1.DIGEST, json.dumps({"project_id": "econ5", "instance_uid": uid, "modules": ALL_YES})))
    pend = C1.installer_sql(server, db, "select id from bnx.institution where status = 'PENDING_VERIFICATION'")[0][0]
    H.s4_registry = True
    H.cmd(H.owner, "verify_institution", institution_id=str(pend), evidence_ref="synthetic", jurisdiction="CA")
    st = one(H, "select bnx.economic_type_check(%s)", (old,))[0]
    m = expect_err(journal, "ECONOMIC_TYPE_RULE_VIOLATION", H, "consumption_expense", [(H.salary, "CAD", "10.00"), (H.cad["ledger_account_id"], "CAD", "-10.00")])
    good = journal(H, "consumption_expense", [(H.groceries, "CAD", "1.00"), (H.cad["ledger_account_id"], "CAD", "-1.00")])
    st2 = one(H, "select bnx.economic_type_check(%s)", (good,))[0]
    H.close()
    check(st == "NOT_APPLICABLE" and st2 == "OK", f"{st} {st2}")
    return f"pre-9008 journal violating B6.1 stays and is reported {st}; the same journal after 9008 is refused; a valid new journal -> {st2}"


@test("AT-PLAN-06,07", "S4B-F12/F15; UA §5.5.5 (chunking, typed items)")
def t_chunks(server, ev):
    H = household(server, "bnx_s4c3plan")
    H.cmd(H.owner, "set_household_setting", setting="plan_chunk_size", value=2)
    items = [{"transaction_date": "2026-04-0%d" % (i + 1), "amount": a, "counter_ledger_account_id": H.groceries, "description": f"imp {i}"}
             for i, a in enumerate(["-10.00", "-20.00", "5.00", "-30.00"])]
    items.append({"transaction_date": "2026-04-06", "amount": "100.00", "counter_ledger_account_id": H.salary, "description": "pay"})
    p = H.cmd(H.owner, "create_import_plan", account_currency_id=H.cad["account_currency_id"], date_from="2026-04-01", date_to="2026-04-30", items=items)
    H.cmd(H.owner, "approve_plan", plan_id=p["plan_id"], plan_hash=p["plan_hash"], scope_digest=p["scope_digest"])
    b0 = H.balance(H.owner, as_of="2026-12-31")
    states = [H.worker.call("wrk_post_plan_chunk", p["plan_id"]) for _ in range(3)]
    mid = H.balance(H.owner, as_of="2026-12-31")
    act = H.worker.call("wrk_activate_plan", p["plan_id"])
    b1 = H.balance(H.owner, as_of="2026-12-31")
    with H.definer() as cx:
        chunks = cx.execute("select chunk_no, posted, remaining from bnx.posting_batch_chunk c join bnx.posting_batch b on b.id = c.batch_id "
                            "where b.plan_id = %s order by chunk_no", (p["plan_id"],)).fetchall()
        types = [r[0] for r in cx.execute("select je.economic_type::text from bnx.journal_entry je where je.approval_plan_id = %s order by je.transaction_date",
                                          (p["plan_id"],))]
    # untyped item that cannot be classified (income counter with an outflow) fails closed; nothing of the chunk posts
    bad = [{"transaction_date": "2026-05-02", "amount": "-1.00", "counter_ledger_account_id": H.salary, "description": "?"}]
    p2 = H.cmd(H.owner, "create_import_plan", account_currency_id=H.cad["account_currency_id"], date_from="2026-05-01", date_to="2026-05-31", items=bad)
    H.cmd(H.owner, "approve_plan", plan_id=p2["plan_id"], plan_hash=p2["plan_hash"], scope_digest=p2["scope_digest"])
    u = expect_err(H.worker.call, "PLAN_ITEM_UNTYPED", "wrk_post_plan_chunk", p2["plan_id"])
    n2 = one(H, "select count(*) from bnx.journal_entry where approval_plan_id = %s", (p2["plan_id"],))[0]
    H.close()
    check(states == ["executing", "executing", "sealed"] and mid == b0 and act == "activated" and float(b1) == float(b0) + 45.0
          and chunks == [(1, 2, 3), (2, 2, 1), (3, 1, 0)] and types == ["consumption_expense", "consumption_expense", "refund", "consumption_expense", "income"]
          and n2 == 0, f"{states} {b0} {mid} {b1} {chunks} {types} {n2}")
    return (f"5 items with chunk size 2 -> {states}, chunk log {chunks}; nothing visible before activation, all 5 at once after (+45.00); "
            f"untyped items typed from the counter kind and sign {types}; an unclassifiable item -> {u}, chunk rolled back")


@test("AT-MUT-03", "S4B-F15 (mutation: removal of t_economic_type_rule is detected)")
def t_mut(server, ev):
    H = household(server, "bnx_s4c3mut")
    bad = [(H.salary, "CAD", "10.00"), (H.cad["ledger_account_id"], "CAD", "-10.00")]
    expect_err(journal, "ECONOMIC_TYPE_RULE_VIOLATION", H, "consumption_expense", bad)
    cx = H.definer()
    cx.execute("drop trigger t_economic_type_rule on bnx.journal_entry")
    jid = str(uuid.uuid4())
    cx.execute("insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description, ledger_version, "
               "origin_channel, created_by_member, confirmed_by_member) values (%s, 'consumption_expense', '2026-02-01', '2026-02-01', 'estimated', "
               "'mutant', bnx.next_version(), 'pwa', %s, %s)", (jid, H.owner_id, H.owner_id))
    for la, cur, amt in bad:
        cx.execute("insert into bnx.journal_line(id, journal_id, ledger_account_id, currency, amount) values (gen_random_uuid(), %s, %s, %s, %s)", (jid, la, cur, amt))
    cx.execute("set constraints all immediate")       # the mutant commits the violating journal (checked, then rolled back)
    n = cx.execute("select count(*) from bnx.journal_entry where id = %s", (jid,)).fetchone()[0]
    cx.rollback(); cx.close(); H.close()
    check(n == 1, "mutant did not commit")
    return "with the trigger the violating journal is refused; with t_economic_type_rule dropped the same journal passes all constraints (mutant detected); rolled back"


# ------------------------------------------------------------------------------------------------ 9009
def pkce():
    v = base64.urlsafe_b64encode(os.urandom(40)).rstrip(b"=").decode()
    return v, base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()


def client(H, cid="host-t", cb="https://t.example/cb"):
    with H.definer() as cx:
        cx.execute("insert into bnx.oauth_client(client_id, display_name, redirect_uris) values (%s, 'T', array[%s]) on conflict do nothing", (cid, cb))
        cx.commit()
    return cid, cb


def consent(H, scopes, acs=None, cid="host-t", cb="https://t.example/cb", **extra):
    v, ch = pkce()
    r = H.cmd(H.owner, "approve_ai_connection", client_id=cid, redirect_uri=cb, code_challenge=ch, scopes=scopes,
              account_currency_ids=acs if acs is not None else [H.cad["account_currency_id"]], **extra)
    return r, v


def token(H, r, v, cid="host-t", cb="https://t.example/cb"):
    return H.authn.call("authn_oauth_token", {"code": r["code"], "client_id": cid, "redirect_uri": cb, "code_verifier": v})


@test("BB-OAUTH-01x,04", "S4B-F09; UA §7.2.1 (NULL fail-closed, single-use, concurrent redemption)")
def t_oauth_fix(server, ev):
    H = household(server, "bnx_s4c3oauth")
    client(H)
    r, v = consent(H, ["finance.read"])
    nulls = [expect_err(H.authn.call, "INVALID_GRANT", "authn_oauth_token", {"code": r["code"], "redirect_uri": "https://t.example/cb", "code_verifier": v}),
             expect_err(H.authn.call, "INVALID_GRANT", "authn_oauth_token", {"code": r["code"], "client_id": "host-t", "code_verifier": v})]
    res, barrier = [], threading.Barrier(2)
    def redeem():
        a = h.Role(server, H.db, "bnx_authn")
        barrier.wait()
        try:
            res.append(a.call("authn_oauth_token", {"code": r["code"], "client_id": "host-t", "redirect_uri": "https://t.example/cb", "code_verifier": v}))
        except psycopg.Error as e:
            res.append({"exception": e.diag.message_primary})
        a.close()
    ts = [threading.Thread(target=redeem) for _ in range(2)]
    [t.start() for t in ts]; [t.join() for t in ts]
    issued = [x for x in res if "access_token" in x]
    replays = [x for x in res if x.get("error") == "invalid_grant"]
    n_tok, n_live = one(H, "select count(*), count(*) filter (where revoked_at is null) from bnx.ai_connection_token where connection_id = %s", (r["connection_id"],))
    H.close()
    check(len(issued) == 1 and len(replays) == 1 and n_tok == 1 and n_live == 0, f"{res} {n_tok} {n_live}")
    return (f"missing client_id / redirect_uri -> {nulls}; two concurrent redemptions -> exactly 1 token issued and 1 invalid_grant, "
            f"and the replay revoked the issued token (RFC 6749 §4.1.2)")


@test("AT-CMD-04x", "S4B-F09 (owner-scoped token revoke)")
def t_revoke_scope(server, ev):
    H = household(server, "bnx_s4c3rev")
    client(H)
    r, v = consent(H, ["finance.read"])
    tok = token(H, r, v)
    m = expect_err(H.cmd, "NOT_AVAILABLE", H.member, "revoke_ai_connection", connection_id=r["connection_id"])
    live = one(H, "select count(*) from bnx.ai_connection_token where connection_id = %s and revoked_at is null", (r["connection_id"],))[0]
    bal = H.q({"kind": "bearer", "secret": tok["access_token"]}, "balances")
    H.close()
    check(live == 1 and len(bal["balances"]) == 1, f"{live} {bal}")
    return f"another member revoking the owner's connection -> {m}; the owner's token stays valid (R1 revoked it: cross-member token revoke)"


@test("BB-OAUTH-02", "UA §7.2.2-7.2.3 (refresh rotation; reuse; none for legacy)")
def t_refresh(server, ev):
    H = household(server, "bnx_s4c3ref")
    client(H)
    r, v = consent(H, ["finance.read", "offline_access"])
    t1 = token(H, r, v)
    t2 = H.authn.call("authn_oauth_refresh", {"refresh_token": t1["refresh_token"], "client_id": "host-t"})
    reuse = H.authn.call("authn_oauth_refresh", {"refresh_token": t1["refresh_token"], "client_id": "host-t"})
    after = expect_err(H.q, "UNAUTHENTICATED", {"kind": "bearer", "secret": t2["access_token"]}, "balances")
    conn = one(H, "select revoked_at is not null from bnx.ai_connection where id = %s", (r["connection_id"],))[0]
    r2, v2 = consent(H, ["finance.read"])
    t3 = token(H, r2, v2)
    wrong = expect_err(H.authn.call, "INVALID_GRANT", "authn_oauth_refresh", {"refresh_token": "x" * 43, "client_id": "host-t"})
    H.authn.call("authn_oauth_revoke", {"token": t3["access_token"], "client_id": "host-t"})
    rv = expect_err(H.q, "UNAUTHENTICATED", {"kind": "bearer", "secret": t3["access_token"]}, "balances")
    H.close()
    check("refresh_token" in t1 and "refresh_token" in t2 and t2["refresh_token"] != t1["refresh_token"] and reuse.get("error") == "invalid_grant"
          and conn is True and "refresh_token" not in t3, f"{t1.keys()} {t2.keys()} {reuse} {conn} {t3.keys()}")
    return (f"offline_access -> refresh token; rotation issues a new pair; reuse of the rotated token -> invalid_grant, connection revoked "
            f"(new access token -> {after}); no offline_access -> no refresh token; unknown refresh -> {wrong}; RFC 7009 revoke -> {rv}")


@test("BB-OAUTH-03", "AIH §4.4 (DCR / CIMD against host-profile allowlists)")
def t_dcr(server, ev):
    H = household(server, "bnx_s4c3dcr")
    ok = H.authn.call("authn_register_client", {"host_profile": "claude_remote_mcp", "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"], "client_name": "Claude"})
    cimd = H.authn.call("authn_register_client", {"host_profile": "chatgpt_plugin_mcp", "registration_kind": "CIMD", "client_id": "https://chatgpt.com/oauth/abc123/client.json",
                                                  "redirect_uris": ["https://chatgpt.com/connector/oauth/abc123"]})
    # the environment is the instance's (data_class), never the caller's (same-family review finding 9)
    bad = [expect_err(H.authn.call, "INVALID_REDIRECT_URI", "authn_register_client", {"host_profile": "claude_remote_mcp", "redirect_uris": ["https://evil.example/cb"]}),
           expect_err(H.authn.call, "INVALID_REDIRECT_URI", "authn_register_client", {"host_profile": "claude_remote_mcp", "redirect_uris": ["http://localhost:8080/cb"]}),
           expect_err(H.authn.call, "INVALID_REDIRECT_URI", "authn_register_client", {"host_profile": "claude_remote_mcp", "redirect_uris": ["http://localhost:8080/cb"],
                      "environment": "development"}),
           # an existing CIMD client cannot be re-pointed by an unauthenticated registration
           expect_err(H.authn.call, "INVALID_CLIENT_METADATA", "authn_register_client", {"host_profile": "chatgpt_plugin_mcp", "registration_kind": "CIMD",
                      "client_id": "https://chatgpt.com/oauth/abc123/client.json", "redirect_uris": ["https://chatgpt.com/connector_platform_oauth_redirect"]}),
           expect_err(H.authn.call, "INVALID_REDIRECT_URI", "authn_register_client", {"host_profile": "chatgpt_plugin_mcp", "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"]}),
           expect_err(H.authn.call, "INVALID_CLIENT_METADATA", "authn_register_client", {"host_profile": "chatgpt_plugin_mcp", "registration_kind": "CIMD",
                      "client_id": "https://evil.example/client.json", "redirect_uris": ["https://chatgpt.com/connector_platform_oauth_redirect"]}),
           expect_err(H.authn.call, "INVALID_CLIENT_METADATA", "authn_register_client", {"host_profile": "unknown", "redirect_uris": ["https://x.example"]})]
    same = H.authn.call("authn_register_client", {"host_profile": "chatgpt_plugin_mcp", "registration_kind": "CIMD", "client_id": "https://chatgpt.com/oauth/abc123/client.json",
                                                  "redirect_uris": ["https://chatgpt.com/connector/oauth/abc123"]})
    redirect = C2.one(H, "select redirect_uris from bnx.oauth_client where client_id = 'https://chatgpt.com/oauth/abc123/client.json'")[0]
    H.cmd(H.owner, "set_household_setting", setting="data_class", value="synthetic")
    dev = H.authn.call("authn_register_client", {"host_profile": "claude_remote_mcp", "redirect_uris": ["http://localhost:8080/cb"]})
    kinds = dict(C2.sql(H, "select client_id, registration_kind || '/' || host_profile from bnx.oauth_client where registration_kind <> 'PREREGISTERED'"))
    H.close()
    check(ok["client_id"].startswith("dcr-") and cimd["client_id"] == "https://chatgpt.com/oauth/abc123/client.json" and len(kinds) == 3
          and same["client_id"] == cimd["client_id"] and redirect == ["https://chatgpt.com/connector/oauth/abc123"] and dev["client_id"].startswith("dcr-"),
          f"{ok} {cimd} {kinds} {same} {redirect}")
    return (f"DCR (Claude callback) and CIMD (ChatGPT client.json) accepted; identical CIMD re-registration idempotent, re-pointing refused; "
            f"loopback refused on a production instance even when the caller claims development, accepted once data_class = synthetic; refused: {bad}")


@test("AT-AIH-13-15", "CROSS-02; UA §7.2.3 (legacy R1 connections after the upgrade)")
def t_legacy(server, ev):
    db = "bnx_s4c3legacy"
    h.bootstrap(server, db, b002=False)
    h.migrate(server, db, mdir=C1.r1_dir())
    H = F.Household(server, db)
    with H.definer() as cx:
        cx.execute("insert into bnx.oauth_client values ('host-t', 'T', array['https://t.example/cb'])"); cx.commit()
    r1, v1 = consent(H, ["read", "propose"])                      # R1 consent (legacy scopes are valid at R1 head)
    t_r1 = token(H, r1, v1)
    r0, v0 = consent(H, ["read"], acs=[])                         # R1 zero-subset connection
    t_r0 = token(H, r0, v0)
    s = H.cmd(H.owner, "create_report_snapshot", report_code="R-BAL")
    rp, vp = consent(H, ["read"])                                 # code issued under R1, redeemed after the upgrade
    h.run_bootstrap(server, db, "B002_bootstrap_s4.sql"); h.migrate(server, db)
    uid = str(uuid.uuid4())
    cv = C1.installer_sql(server, db, "select bnx.adopt_existing_household('legacy', %s, %s::jsonb, '{}'::jsonb)", (uid, json.dumps(ALL_YES)))[0][0]
    C1.installer_sql(server, db, "select bnx.install_activate_config(%s, %s, %s::jsonb)",
                     (cv, C1.DIGEST, json.dumps({"project_id": "legacy", "instance_uid": uid, "modules": ALL_YES})))
    pend = C1.installer_sql(server, db, "select id from bnx.institution where status = 'PENDING_VERIFICATION'")[0][0]
    H.s4_registry = True
    H.cmd(H.owner, "verify_institution", institution_id=str(pend), evidence_ref="synthetic", jurisdiction="CA")
    b = {"kind": "bearer", "secret": t_r1["access_token"]}
    bal = H.q(b, "balances")                                      # issued R1 access token: legacy read semantics
    snap_mcp = H.cmd(b, "create_report_snapshot", report_code="R-BAL")
    rep = H.q(b, "replay_snapshot", snapshot_id=snap_mcp["snapshot_id"])
    out = {"q_evidence_access": expect_err(H.q, "SCOPE_NOT_CONSENTED", b, "evidence_access", evidence_file_id=str(uuid.uuid4())),
           "q_institutions_search": expect_err(H.q, "SCOPE_NOT_CONSENTED", b, "institutions_search", text="bank"),
           "cmd_register_evidence (legacy propose)": expect_err(H.cmd, "SCOPE_NOT_CONSENTED", b, "register_evidence", size=1, mime="application/pdf",
                                                              sha256="00" * 32, original_name="x.pdf"),
           "q_config_status (unlisted)": expect_err(H.q, "SCOPE_NOT_CONSENTED", b, "config_status"),
           "zero-subset legacy read": expect_err(H.q, "NOT_AVAILABLE", {"kind": "bearer", "secret": t_r0["access_token"]}, "balances")}
    with H.definer() as cx:                                       # a legacy read replay of a non-R-BAL/F1 snapshot -> NOT_AVAILABLE
        cx.execute("insert into bnx.report_snapshot(id, report_code, filters_digest, ledger_version, report_definition_version, fx_policy, "
                   "content_account_currency_ids, content_sha256, projection_actor, projection_account_currency_ids, projection_sha256, "
                   "projection_channel, projection_connection_id, projection_requested_acs, filters) "
                   "select gen_random_uuid(), 'F3', '\\x00', 1, 'F3/1', '{}', '{}', '\\x00', %s, '{}', '\\x00', 'mcp', %s, '{}', '{}' returning id",
                   (H.owner_id, r1["connection_id"]))
        f3 = cx.execute("select id from bnx.report_snapshot where report_code = 'F3'").fetchone()[0]
        cx.commit()
    out["F3 replay (legacy read)"] = expect_err(H.q, "NOT_AVAILABLE", b, "replay_snapshot", snapshot_id=str(f3))
    late = token(H, rp, vp)                                       # legacy connection: never a refresh token
    new_legacy = expect_err(consent, "VALIDATION_FAILED", H, ["read"])
    sub = [expect_err(consent, "SUBSET_REQUIRED", H, ["tax.read"], acs=[]), expect_err(consent, "SUBSET_REQUIRED", H, ["documents.read"], acs=[]),
           expect_err(consent, "SUBSET_REQUIRED", H, ["finance.read"], acs=[])]
    legacy_rows = C2.sql(H, "select legacy, refresh_eligible from bnx.ai_connection where id = %s", (r1["connection_id"],))
    H.close()
    check(len(bal["balances"]) == 1 and rep["projection_digest_verified"] and "refresh_token" not in late and legacy_rows == [(True, False)],
          f"{bal} {rep} {late.keys()} {legacy_rows}")
    return (f"R1 connections stay legacy (never upgraded in place); the issued R1 access token keeps legacy read: balances and R-BAL "
            f"snapshot + replay work; refused: {out}; a code issued under R1 redeems without a refresh token; new consents cannot use "
            f"legacy scopes ({new_legacy}); missing subsets -> {sub}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core3", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core3_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, {summary['skip']} SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
