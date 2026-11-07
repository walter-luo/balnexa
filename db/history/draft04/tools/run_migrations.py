#!/usr/bin/env python3
"""Apply db/migrations/NNNN_*.sql in order, each in ONE transaction together with its schema_migrations row.
Refuses to continue if an applied migration's SHA-256 differs from the file (immutable migrations).
Usage: run_migrations.py --dsn "<libpq conninfo>" [--dir db/migrations] [--upto NNNN]
Development and CI tool only (§H12); production migrations run from CI with the migrator credential."""
import argparse, hashlib, os, re, subprocess, sys

def psql(dsn, sql, capture=False):
    r = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-1", "-At", "-f", "-"],
                       input=sql, text=True, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"FAIL\n{r.stderr.strip()}")
    return r.stdout.strip()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--dir", default=os.path.join(os.path.dirname(__file__), "..", "migrations"))
    ap.add_argument("--upto")
    a = ap.parse_args()
    files = sorted(f for f in os.listdir(a.dir) if re.match(r"^\d{4}_.*\.sql$", f))
    have = {}
    exists = psql(a.dsn, "select to_regclass('bnx.schema_migrations') is not null;", True)
    if exists == "t":
        for line in psql(a.dsn, "select version||'|'||sha256 from bnx.schema_migrations;", True).splitlines():
            v, h = line.split("|"); have[v] = h
    for f in files:
        v = f[:4]
        if a.upto and v > a.upto:
            break
        body = open(os.path.join(a.dir, f), encoding="utf-8").read()
        h = hashlib.sha256(body.encode()).hexdigest()
        if v in have:
            if have[v] != h:
                sys.exit(f"FAIL {f}: applied checksum {have[v][:12]} != file {h[:12]} (migrations are immutable)")
            print(f"skip  {f} (applied)")
            continue
        psql(a.dsn, body + f"\nreset role;\ninsert into bnx.schema_migrations(version, sha256) values ('{v}', '{h}');\n")
        print(f"apply {f} sha256={h[:12]}")
    print("OK")

if __name__ == "__main__":
    main()
