#!/usr/bin/env python3
"""Clean-database migration test + acceptance tests on a disposable PostgreSQL. Synthetic data only.
Usage: run_tests.py --server "host=<dir> port=<p> user=postgres"   (development/CI tool, §H12)"""
import argparse, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); TOOLS = os.path.join(HERE, "..", "tools")
def sh(args, **kw):
    r = subprocess.run(args, text=True, capture_output=True, **kw)
    return r.returncode, (r.stdout + r.stderr)
def psql(server, db, *extra, stdin=None):
    return sh(["psql", f"{server} dbname={db}", "-X", "-q", "-v", "ON_ERROR_STOP=1", *extra], input=stdin, cwd=HERE)
def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--server", required=True); a = ap.parse_args()
    out, ok = [], True
    def log(s): print(s); out.append(s)
    for db in ("bnx_tpl", "bnx_conv") + tuple(f"bnx_t{n}" for n in (10, 20, 30, 40, 50)):
        psql(a.server, "postgres", "-c", f"drop database if exists {db}")
    psql(a.server, "postgres", "-c", "create database bnx_tpl")
    rc, o = sh([sys.executable, os.path.join(TOOLS, "run_migrations.py"), "--dsn", f"{a.server} dbname=bnx_tpl"])
    log("== clean-database migration (empty PostgreSQL)\n" + o.strip()); ok &= rc == 0
    rc, o = sh([sys.executable, os.path.join(TOOLS, "run_migrations.py"), "--dsn", f"{a.server} dbname=bnx_tpl"])
    log("== re-run (must skip all)\n" + o.strip().splitlines()[-1]); ok &= rc == 0
    rc, o = psql(a.server, "bnx_tpl", "-f", "000_support.sql"); ok &= rc == 0
    if rc: log(o)
    for n, f in ((10, "010_append_only_and_catalog.sql"), (20, "020_temporal.sql"), (30, "030_scope_claims.sql"),
                 (40, "040_ownership.sql"), (50, "050_evidence_and_snapshots.sql")):
        psql(a.server, "postgres", "-c", f"create database bnx_t{n} template bnx_tpl")
        rc, o = psql(a.server, f"bnx_t{n}", "-f", f)
        lines = [l.split("NOTICE:  ")[-1] for l in o.splitlines() if "NOTICE" in l or "ERROR" in l]
        log(f"== {f}: {'OK' if rc == 0 else 'FAILED'}\n" + "\n".join(lines)); ok &= rc == 0
    psql(a.server, "postgres", "-c", "create database bnx_conv")
    rc1, o1 = sh([sys.executable, os.path.join(TOOLS, "run_migrations.py"), "--dsn", f"{a.server} dbname=bnx_conv", "--upto", "0007"])
    rc2, o2 = psql(a.server, "bnx_conv", "-f", "000_support.sql")
    rc3, o3 = psql(a.server, "bnx_conv", "-f", "060_fixture.sql")
    rc4, o4 = sh([sys.executable, os.path.join(TOOLS, "run_migrations.py"), "--dsn", f"{a.server} dbname=bnx_conv"])
    rc5, o5 = psql(a.server, "bnx_conv", "-f", "060_draft02_conversion.sql")
    conv_ok = all(r == 0 for r in (rc1, rc2, rc3, rc4, rc5))
    log("== Draft-02 logical state -> migration 9001: " + ("OK" if conv_ok else "FAILED"))
    log("\n".join(l.split("NOTICE:  ")[-1] for l in (o3 + o4 + o5).splitlines() if "NOTICE" in l or "ERROR" in l or "apply" in l))
    ok &= conv_ok
    log("ALL DATABASE TESTS PASS" if ok else "DATABASE TEST FAILURES")
    open(os.path.join(HERE, "last_run.txt"), "w").write("\n".join(out) + "\n")
    sys.exit(0 if ok else 1)
if __name__ == "__main__":
    main()
