#!/usr/bin/env python3
"""S4 V1.2 increment 16 tests: CORE-9 database support in migration 9019 (q_ledger_accounts for PWA Quick Entry) and the
catalog delta blocks (D-CORE9-2). The PWA itself is tested headless by tests/pwa/pwa.test.mjs. Synthetic data only.
Usage: run_s4_core16.py --server pg16|pg17 [--only PREFIX] [--evidence DIR]"""
import argparse, json, os, re, subprocess, sys, time, traceback
import psycopg
import harness as h
import run_s4_core1 as C1
import run_s4_core4 as C4
from run_g0 import expect_err

RESULTS, TESTS = [], []
check = C1.check


def test(tid, ref):
    def deco(fn):
        TESTS.append((tid, ref, fn)); return fn
    return deco


@test("AT-PWA-LA-01", "UA V1.2 §12.1; Draft-04 C1 W-M01…W-M03 (Quick Entry ledger accounts: visibility, can_post, categories; PWA only)")
def t_ledger(server, ev):
    H = C4.household(server, "bnx_c16la")
    o = H.q(H.owner, "ledger_accounts")
    d_id = H.cmd(H.owner, "invite_member", display_name="Member D", role="member", google_sub="g-member-d")["member_id"]
    H.cmd(H.owner, "set_grant", member_id=d_id, account_id=H.acc, can_view=True, can_post=False)
    D = H.login("g-member-d")
    d = H.q(D, "ledger_accounts")
    v_id = H.cmd(H.owner, "invite_member", display_name="Viewer V", role="viewer", google_sub="g-viewer-v")["member_id"]
    H.cmd(H.owner, "set_grant", member_id=v_id, account_id=H.acc, can_view=True, can_post=True)
    V = H.login("g-viewer-v")
    vv = H.q(V, "ledger_accounts")
    B = C4.bearer(H, ["finance.read"], acs=[H.cad["account_currency_id"]])
    mcp = expect_err(H.q, "SCOPE_NOT_CONSENTED", B, "ledger_accounts")
    H.close()
    json.dump({"owner": o, "member": d, "viewer": vv, "bearer": mcp}, open(os.path.join(ev, "AT-PWA-LA-01.json"), "w"), indent=1)
    check(o["accounts"] and all(a["can_post"] for a in o["accounts"]) and all(a["ledger_account_id"] for a in o["accounts"]), f"{o}")
    check({a["account_id"] for a in d["accounts"]} == {H.acc} and not any(a["can_post"] for a in d["accounts"]), f"{d}")
    check(not any(a["can_post"] for a in vv["accounts"]), f"viewer never posts even with a can_post grant: {vv}")
    check(any(c["ledger_account_id"] == H.groceries and c["kind"] == "expense" for c in o["categories"]) and d["categories"] == o["categories"], f"{o['categories']}")
    return (f"owner: {len(o['accounts'])} account-currencies, all postable; member without can_post: only the granted account, can_post false; "
            f"viewer: can_post false even with a can_post grant (role rule); {len(o['categories'])} active categories for everyone; an AI bearer "
            f"is refused ({mcp.split(':')[0]}) - the query is not an MCP tool")


@test("AT-CAT-02", "D-CORE9-2 (catalog delta blocks: committed migrations are never edited; merged blocks = derivation)")
def t_delta(server, ev):
    H = C1.v2_household(server, "bnx_c16cat")
    db = H.db
    H.close()
    gen = subprocess.run([sys.executable, os.path.join(h.ROOT, "tools/s4/catalog_build.py"), "--server", server, "--db", db, "--check"],
                         capture_output=True, text=True)
    blocks = {}
    for f in sorted(os.listdir(os.path.join(h.ROOT, "db", "migrations"))):
        src = open(os.path.join(h.ROOT, "db", "migrations", f)).read()
        if "@@CATALOG-BEGIN" in src:
            blocks[f[:4]] = len(re.findall(r"^comment on function ", src, re.M))
    with psycopg.connect(h.dsn(server, "bnx_migrator", db)) as cx:
        live = cx.execute("select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                          "where n.nspname = 'bnx' and obj_description(p.oid, 'pg_proc') like '{\"channels\"%'").fetchone()[0]
    json.dump({"check": gen.stdout, "blocks": blocks, "live_comments": live}, open(os.path.join(ev, "AT-CAT-02.json"), "w"), indent=1)
    check(gen.returncode == 0 and "OK" in gen.stdout, gen.stdout + gen.stderr)
    check(blocks.get("9017") == 113 and blocks.get("9019") == 1 and live == 114, f"{blocks} {live}")
    return f"{gen.stdout.strip()}; blocks per migration {blocks}; {live} catalogued functions in the database"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True)
    ap.add_argument("--only")
    ap.add_argument("--evidence", default=None)
    a = ap.parse_args()
    ev = a.evidence or os.path.join(h.ROOT, "EVIDENCE", "s4_core16", a.server)
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
    json.dump(summary, open(os.path.join(ev, "s4_core16_results.json"), "w"), indent=1)
    print(f"== {a.server}: {summary['pass']} PASS, {summary['fail']} FAIL, 0 SKIP in {summary['seconds']}s")
    sys.exit(1 if summary["fail"] else 0)


if __name__ == "__main__":
    main()
