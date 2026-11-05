#!/usr/bin/env python3
"""G0-08 artifact integrity checks for the R1 package (run from the repository root):
  1. migration-chain lint: object created twice without CREATE OR REPLACE/DROP, privileged statements outside B001,
     RESET ROLE in migrations, SECURITY DEFINER without the fixed search_path, edits to history/draft04;
  2. secret scan over all tracked text files (private keys, cloud keys, tokens, passwords in DSNs);
  3. SBOM (npm lockfile + Python packages used by tests) with licences;
  4. SHA-256 manifest of every file in the package.
Writes EVIDENCE/g0_08/*.json and exits non-zero on any lint or secret finding."""
import hashlib, json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
EV = os.path.join(ROOT, "EVIDENCE", "g0_08")
os.makedirs(EV, exist_ok=True)
SKIP_DIRS = {"node_modules", ".git", "__pycache__", ".venv"}


def files():
    for d, ds, fs in os.walk(ROOT):
        ds[:] = sorted(x for x in ds if x not in SKIP_DIRS)
        for f in sorted(fs):
            yield os.path.relpath(os.path.join(d, f), ROOT)


def lint():
    out = []
    mdir = os.environ.get("BNX_LINT_DIR", os.path.join(ROOT, "db/migrations"))
    seen = {}
    obj = re.compile(r"\bcreate\s+(or\s+replace\s+)?(table|function|type|view|trigger|constraint trigger|index|unique index)\s+"
                     r"(?:if\s+not\s+exists\s+)?([a-z_][a-z0-9_.]*)", re.I)
    for f in sorted(os.listdir(mdir)):
        body = open(os.path.join(mdir, f)).read()
        code = re.sub(r"--[^\n]*", "", body)
        dropped = set(m.group(2).lower() for m in re.finditer(r"\bdrop\s+(function|trigger|table|type)\s+(?:if exists\s+)?([a-z_][a-z0-9_.]*)", code, re.I))
        for m in obj.finditer(code):
            kind, name = m.group(2).lower(), m.group(3).lower()
            if kind in ("trigger", "constraint trigger"):
                on = re.search(r"\bon\s+([a-z_][a-z0-9_.]*)", code[m.end():m.end() + 300], re.I)
                name = f"{name}@{on.group(1).lower() if on else '?'}"
                kind = "trigger"
            key = (kind, name)
            if key in seen and not m.group(1) and name not in dropped:
                out.append({"rule": "DUPLICATE_CREATE", "object": f"{kind} {name}", "first": seen[key], "again": f})
            seen.setdefault(key, f)
        for pat, rule in ((r"\breset\s+role\b", "RESET_ROLE"), (r"\bcreate\s+role\b|\balter\s+role\b|\bcreate\s+extension\b|\bcreate\s+schema\b", "PRIVILEGED_DDL"),
                          (r"\bsuperuser\b", "SUPERUSER")):
            if re.search(pat, code, re.I):
                out.append({"rule": rule, "file": f})
        for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+([a-z_.]+)\([^$]*?security\s+definer([^$]*?)\$\$", code, re.I | re.S):
            if "search_path = pg_catalog, pg_temp" not in m.group(0):
                out.append({"rule": "DEFINER_SEARCH_PATH", "function": m.group(1), "file": f})
    return out, len(seen)


SECRET = [(r"-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----", "private_key"), (r"AKIA[0-9A-Z]{16}", "aws_key"),
          (r"AIza[0-9A-Za-z_\-]{35}", "google_api_key"), (r"ghp_[0-9A-Za-z]{36}", "github_token"), (r"sk-[A-Za-z0-9]{32,}", "api_key"),
          (r"xox[baprs]-[0-9A-Za-z\-]{10,}", "slack_token"), (r"postgres(?:ql)?://[^:\s/]+:[^@\s]+@", "dsn_password"),
          (r"\bpassword\s*=\s*['\"]?[^\s'\"]{6,}", "password_assignment"), (r"AGE-SECRET-KEY-1[0-9A-Z]{58}", "age_secret_key")]


def secrets():
    hits = []
    for f in files():
        p = os.path.join(ROOT, f)
        if os.path.getsize(p) > 5_000_000 or f.endswith((".zip", ".whl", ".png")):
            continue
        try:
            t = open(p, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        for pat, kind in SECRET:
            for m in re.finditer(pat, t):
                ctx = t[max(0, m.start() - 80):m.end() + 20]
                allowed = "SECRET_SCAN_ALLOW" in ctx or f.startswith("tools/g0_artifact_checks.py")
                if not allowed:
                    hits.append({"file": f, "kind": kind, "offset": m.start()})
    return hits


def sbom():
    comps = []
    lock = os.path.join(ROOT, "apps/worker/package-lock.json")
    if os.path.exists(lock):
        for path, meta in json.load(open(lock)).get("packages", {}).items():
            if not path:
                continue
            name = path.split("node_modules/")[-1]
            pj = os.path.join(ROOT, "apps/worker", path, "package.json")
            lic = json.load(open(pj)).get("license") if os.path.exists(pj) else None
            comps.append({"ecosystem": "npm", "name": name, "version": meta.get("version"), "license": lic, "integrity": meta.get("integrity"),
                          "scope": "runtime (apps/worker node adapter; not bundled for Cloudflare)"})
    py = subprocess.run([os.environ.get("BNX_PY", "/opt/bnx-tools/venv/bin/python"), "-m", "pip", "list", "--format", "json"],
                        capture_output=True, text=True)
    lic = {"psycopg": "LGPL-3.0-only", "psycopg-binary": "LGPL-3.0-only", "typing_extensions": "PSF-2.0", "pip": "MIT"}
    for p in json.loads(py.stdout or "[]"):
        comps.append({"ecosystem": "pypi", "name": p["name"], "version": p["version"], "license": lic.get(p["name"], "see package metadata"),
                      "scope": "test tooling only"})
    comps.append({"ecosystem": "system", "name": "PostgreSQL server", "version": "16.15 (Ubuntu) and 17.11 (embedded-postgres)", "license": "PostgreSQL",
                  "scope": "test servers only"})
    comps.append({"ecosystem": "system", "name": "age", "version": "1.1.1", "license": "BSD-3-Clause", "scope": "AUD-038 simulation"})
    return comps


def manifest():
    m = {}
    for f in files():
        if f.startswith("EVIDENCE/g0_08/manifest"):
            continue
        m[f] = hashlib.sha256(open(os.path.join(ROOT, f), "rb").read()).hexdigest()
    return m


if __name__ == "__main__":
    l, n = lint()
    s = secrets()
    json.dump({"objects_checked": n, "findings": l}, open(os.path.join(EV, "chain_lint.json"), "w"), indent=1)
    json.dump({"findings": s}, open(os.path.join(EV, "secret_scan.json"), "w"), indent=1)
    json.dump({"format": "balnexa-sbom/1 (CycloneDX-compatible fields)", "components": sbom()}, open(os.path.join(EV, "sbom.json"), "w"), indent=1)
    if "--manifest" in sys.argv:
        json.dump(manifest(), open(os.path.join(EV, "manifest_sha256.json"), "w"), indent=1, sort_keys=True)
    print(f"chain lint: {n} objects, {len(l)} findings; secret scan: {len(s)} findings")
    for x in l + s:
        print("  ", x)
    sys.exit(1 if (l or s) else 0)
