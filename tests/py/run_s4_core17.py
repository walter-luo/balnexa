#!/usr/bin/env python3
"""S4 V1.2 increment 17 tests: AIH-1/AIH-2 database support in migration 9021 (client and redirect check, host-profile inference
for DCR/CIMD, the PWA connection list, host provenance from the connection). The HTTP surface (OAuth endpoints, MCP server,
consent) is tested by tests/blackbox/api.test.mjs and tests/pwa/pwa.test.mjs. Synthetic data only.
Usage: run_s4_core17.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, time, traceback
import harness as h
import run_s4_core1 as C1
import run_s4_core2 as C2
import run_s4_core3 as C3
import run_s4_core4 as C4
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check
CLAUDE_CB, CHATGPT_CB = "https://claude.ai/api/mcp/auth_callback", "https://chatgpt.com/connector_platform_oauth_redirect"


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


def reg(H, **kw):
    return H.authn.call("authn_register_client", kw)


@test("AT-AIH-REG-01", "AIH §4.2/§4.4; 9021 authn_register_client MODIFY (host profile inferred from the redirect URIs; environment from the instance)")
def t_infer(server, ev):
    H = C4.household(server, "bnx_c17reg")
    out = {
        "claude": reg(H, redirect_uris=[CLAUDE_CB], client_name="Claude"),
        "chatgpt": reg(H, redirect_uris=[CHATGPT_CB, "https://chatgpt.com/connector/oauth/cbAbc"]),
        "loopback_production": expect_err(reg, "INVALID_REDIRECT_URI", H, redirect_uris=["http://localhost:6274/cb"]),
        "mixed": expect_err(reg, "INVALID_REDIRECT_URI", H, redirect_uris=[CLAUDE_CB, CHATGPT_CB]),
        "unknown_host": expect_err(reg, "INVALID_REDIRECT_URI", H, redirect_uris=["https://evil.example/cb"]),
        "explicit_mismatch": expect_err(reg, "INVALID_REDIRECT_URI", H, host_profile="chatgpt_plugin_mcp", redirect_uris=[CLAUDE_CB]),
        "too_many": expect_err(reg, "INVALID_CLIENT_METADATA", H, redirect_uris=[CLAUDE_CB] * 11),
        "not_array": expect_err(reg, "INVALID_CLIENT_METADATA", H, redirect_uris=CLAUDE_CB),
        "cimd": reg(H, registration_kind="CIMD", client_id="https://chatgpt.com/oauth/client.json", redirect_uris=[CHATGPT_CB], client_name="ChatGPT"),
        "cimd_foreign_redirect": expect_err(reg, "INVALID_REDIRECT_URI", H, registration_kind="CIMD", client_id="https://chatgpt.com/oauth/x1/client.json",
                                            redirect_uris=["https://evil.example/cb"]),
        "cimd_foreign_id": expect_err(reg, "INVALID_CLIENT_METADATA", H, registration_kind="CIMD", client_id="https://evil.example/client.json",
                                      redirect_uris=[CHATGPT_CB]),
    }
    H.cmd(H.owner, "set_household_setting", setting="data_class", value="synthetic")
    out["loopback_synthetic"] = reg(H, redirect_uris=["http://localhost:6274/cb", "http://127.0.0.1:33418/callback"])
    kinds = dict(C2.sql(H, "select client_id, registration_kind || '/' || host_profile || '/' || display_name from bnx.oauth_client "
                           "where registration_kind <> 'PREREGISTERED'"))
    H.close()
    json.dump({"out": out, "kinds": kinds}, open(os.path.join(ev, "AT-AIH-REG-01.json"), "w"), indent=1)
    check(out["claude"]["host_profile"] == "claude_remote_mcp" and out["chatgpt"]["host_profile"] == "chatgpt_plugin_mcp"
          and out["cimd"]["host_profile"] == "chatgpt_plugin_mcp" and out["loopback_synthetic"]["host_profile"] == "claude_remote_mcp", f"{out}")
    check(kinds[out["claude"]["client_id"]] == "DCR/claude_remote_mcp/Claude" and kinds["https://chatgpt.com/oauth/client.json"] == "CIMD/chatgpt_plugin_mcp/ChatGPT", f"{kinds}")
    refused = {k: v.split(":")[0] for k, v in out.items() if isinstance(v, str)}
    return (f"inferred: Claude callback -> claude_remote_mcp, ChatGPT callbacks -> chatgpt_plugin_mcp, CIMD -> chatgpt_plugin_mcp, loopback -> "
            f"claude_remote_mcp only once data_class = synthetic; refused: {refused}")


@test("AT-AIH-CLI-01", "RFC 6749 §4.1.2.1; AIH §4.2 CIMD; 9021 authn_oauth_client (checked before any redirect; no credential)")
def t_client(server, ev):
    H = C4.household(server, "bnx_c17cli")
    C3.client(H)
    c = lambda cid, ru=None: H.authn.call("authn_oauth_client", {"client_id": cid, **({"redirect_uri": ru} if ru else {})})
    out = {"known_ok": c("host-t", "https://t.example/cb"), "known_bad_redirect": c("host-t", "https://evil.example/cb"),
           "known_no_redirect": c("host-t"), "unknown": c("dcr-none"), "cimd_candidate": c("https://chatgpt.com/oauth/client.json"),
           "cimd_foreign": c("https://evil.example/client.json"), "control_chars": c("host-t\n"), "too_long": c("x" * 301), "none": H.authn.call("authn_oauth_client", {})}
    grants = C2.sql(H, "select r.rolname from pg_proc p join pg_namespace n on n.oid = p.pronamespace cross join pg_roles r "
                       "where n.nspname = 'bnx' and p.proname = 'authn_oauth_client' and r.rolname like 'bnx\\_%' and has_function_privilege(r.oid, p.oid, 'EXECUTE') "
                       "and not r.rolsuper order by 1")
    H.close()
    json.dump({"out": out, "grants": grants}, open(os.path.join(ev, "AT-AIH-CLI-01.json"), "w"), indent=1)
    check(out["known_ok"] == {"known": True, "client_id": "host-t", "client_name": "T", "host_profile": None, "registration_kind": "PREREGISTERED", "redirect_ok": True}, f"{out}")
    check(out["known_bad_redirect"]["redirect_ok"] is False and out["known_no_redirect"]["redirect_ok"] is False, f"{out}")
    check(out["unknown"] == {"known": False, "cimd_allowed": False} and out["cimd_candidate"] == {"known": False, "cimd_allowed": True}
          and out["cimd_foreign"]["cimd_allowed"] is False and out["control_chars"]["known"] is False and out["too_long"]["known"] is False
          and out["none"]["known"] is False, f"{out}")
    check({g[0] for g in grants} <= {"bnx_authn", "bnx_definer", "bnx_migrator"} and ("bnx_authn",) in grants, f"{grants}")
    return ("registered client + its redirect -> redirect_ok; another redirect -> false; unknown id -> not known; an https id is a CIMD "
            f"candidate only on the allowlist; malformed ids rejected; executable by {[g[0] for g in grants]}")


@test("AT-AIH-PROV-01", "AIH §4.5; UA §5.10; 9021 resolve_actor MODIFY (host_profile from the connection, never from the envelope)")
def t_prov(server, ev):
    H = C4.household(server, "bnx_c17prov")
    cid = reg(H, redirect_uris=[CLAUDE_CB], client_name="Claude")["client_id"]
    r, v = C3.consent(H, ["finance.read", "reports.read"], cid=cid, cb=CLAUDE_CB)
    tok = C3.token(H, r, v, cid=cid, cb=CLAUDE_CB)["access_token"]
    env = {"host_profile": "chatgpt_plugin_mcp", "tool_name": "fin.reports.create_snapshot", "tool_version": "1.0.0", "trace_id": "tr-abcdefghijklmnopqrstuvwx"}
    B = {"kind": "bearer", "secret": tok, "envelope": env}
    H.cmd(B, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    H.cmd({**H.owner, "envelope": {"host_profile": "pwa-test", "tool_name": "manual"}}, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    # a preregistered client without a profile records none (never a claimed one)
    C3.client(H)
    r2, v2 = C3.consent(H, ["finance.read", "reports.read"])
    B2 = {"kind": "bearer", "secret": C3.token(H, r2, v2)["access_token"], "envelope": env}
    H.cmd(B2, "create_report_snapshot", report_code="R-BAL", as_of="2026-12-31")
    rows = C2.sql(H, "select channel, host_profile, tool_name, tool_version, trace_id from bnx_audit.audit_event "
                     "where command = 'create_report_snapshot' order by seq")
    trail = H.q(H.owner, "audit_trail", command="create_report_snapshot")
    H.close()
    json.dump({"rows": rows, "trail": trail}, open(os.path.join(ev, "AT-AIH-PROV-01.json"), "w"), indent=1, default=str)
    check(rows[0] == ("mcp", "claude_remote_mcp", "fin.reports.create_snapshot", "1.0.0", "tr-abcdefghijklmnopqrstuvwx"), f"{rows}")
    check(rows[1][:3] == ("pwa", "pwa-test", "manual") and rows[2][:2] == ("mcp", None), f"{rows}")
    check(trail["events"][-1]["host_profile"] == "claude_remote_mcp", f"{trail}")
    return ("bearer call claiming chatgpt_plugin_mcp in its envelope is audited as claude_remote_mcp (the connection's client); tool name, "
            "version and trace id kept from the Gateway envelope; a session's envelope is unchanged; a client without a profile records none")


@test("AT-AIH-CONN-01", "OR-M-05; PV-AIH-03; 9021 q_ai_connections (own connections only; PWA only; revocation visible)")
def t_conn(server, ev):
    H = C4.household(server, "bnx_c17conn")
    C3.client(H)
    cad = H.cad["account_currency_id"]
    r1, _ = C3.consent(H, ["finance.read", "offline_access"], resource="https://bnx.example/mcp")
    r2, _ = C3.consent(H, ["finance.read"])
    H.cmd(H.owner, "revoke_ai_connection", connection_id=r2["connection_id"])
    d_id = H.cmd(H.owner, "invite_member", display_name="Member D", role="member", google_sub="g-member-d")["member_id"]
    H.cmd(H.owner, "set_grant", member_id=d_id, account_id=H.acc, can_view=True, can_post=True)
    D = H.login("g-member-d")
    v, ch = C3.pkce()
    rd = H.cmd(D, "approve_ai_connection", client_id="host-t", redirect_uri="https://t.example/cb", code_challenge=ch, scopes=["finance.read"],
               account_currency_ids=[cad])
    o = H.q(H.owner, "ai_connections")
    d = H.q(D, "ai_connections")
    B = C4.bearer(H, ["finance.read"], acs=[cad])
    mcp = expect_err(H.q, "SCOPE_NOT_CONSENTED", B, "ai_connections")
    H.close()
    json.dump({"owner": o, "member": d}, open(os.path.join(ev, "AT-AIH-CONN-01.json"), "w"), indent=1, default=str)
    oc = {c["connection_id"]: c for c in o["connections"]}
    check(set(oc) >= {r1["connection_id"], r2["connection_id"]} and rd["connection_id"] not in oc, f"{list(oc)}")
    a, b = oc[r1["connection_id"]], oc[r2["connection_id"]]
    check(a["state"] == "active" and a["refresh_eligible"] is True and a["resource"] == "https://bnx.example/mcp" and a["account_currency_ids"] == [cad]
          and a["client_name"] == "T" and a["legacy"] is False, f"{a}")
    check(b["state"] == "revoked" and b["revoked_at"] and b["refresh_eligible"] is False, f"{b}")
    check([c["connection_id"] for c in d["connections"]] == [rd["connection_id"]], f"{d}")
    return (f"Owner sees {len(o['connections'])} own connections (active with resource, subset and refresh eligibility; revoked with its time), "
            f"not the member's; the member sees only theirs; an AI bearer is refused ({mcp.split(':')[0]})")


@test("AT-AIH-ENV-01", "RV-AIH-07; 9023 authn_oauth_client MODIFY (a redirect URI is usable only while its host-profile rule holds on this environment)")
def t_env(server, ev):
    H = C4.household(server, "bnx_c17env")
    H.cmd(H.owner, "set_household_setting", setting="data_class", value="synthetic")
    lb = reg(H, redirect_uris=["http://localhost:6274/cb"])["client_id"]
    cl = reg(H, redirect_uris=[CLAUDE_CB])["client_id"]
    C3.client(H)
    c = lambda cid, ru: H.authn.call("authn_oauth_client", {"client_id": cid, "redirect_uri": ru})["redirect_ok"]
    before = {"loopback": c(lb, "http://localhost:6274/cb"), "claude": c(cl, CLAUDE_CB), "prereg": c("host-t", "https://t.example/cb")}
    H.cmd(H.owner, "set_household_setting", setting="data_class", value="real")
    after = {"loopback": c(lb, "http://localhost:6274/cb"), "claude": c(cl, CLAUDE_CB), "prereg": c("host-t", "https://t.example/cb")}
    H.close()
    json.dump({"before": before, "after": after}, open(os.path.join(ev, "AT-AIH-ENV-01.json"), "w"), indent=1)
    check(before == {"loopback": True, "claude": True, "prereg": True} and after == {"loopback": False, "claude": True, "prereg": True}, f"{before} {after}")
    return ("a loopback client registered on a synthetic instance is refused (redirect_ok false) once data_class is real; a production "
            "host redirect and a preregistered client are unaffected")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core17", a.server)
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
    summary = {"server": a.server, "seconds": round(time.time() - t0, 1), "pass": sum(r["status"] == "PASS" for r in RESULTS),
               "fail": sum(r["status"] == "FAIL" for r in RESULTS), "skip": 0, "results": RESULTS}
    json.dump(summary, open(os.path.join(ev, "s4_core17_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    import sys
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
