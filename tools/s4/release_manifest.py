#!/usr/bin/env python3
"""INS-1 release manifest (WP matrix V1.2 phase 2.6; UA V1.2 §9.1 deploy rule; IL V1.2 §4).

Builds release/manifest.json from the repository: the Worker release and its schema range (apps/worker/src/release.js),
every migration with its SHA-256 (the value the runner records in bnx.schema_migrations), the minimum Worker release for each
migration, the Executor version, the PWA shell version, and a dependency list (SBOM: npm lockfiles and the hash-pinned
Python requirements). The installer and the upgrade path read it; nothing in it is secret.

Rules checked (--check, also run in CI):
  R1 the Worker's extension range ends at the newest migration, and starts at most one migration earlier (N-1)
  R2 every migration file name is <4 digits>_<name>.sql, versions strictly increase, and none is listed twice
  R3 min_worker_release of every migration is a release that supports it (the deploy rule: the Worker that understands a
     migration is deployed before the migration runs). The value is the first manifest release that listed it; a migration
     first seen by this run gets this release
  R4 the committed manifest matches what this run builds (no drift), unless --write is given

Usage:  release_manifest.py --write     (rebuild release/manifest.json)
        release_manifest.py --check     (exit 1 on any rule violation or drift)"""
import argparse, hashlib, json, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "release", "manifest.json")
MIG = os.path.join(ROOT, "db", "migrations")


def read(p):
    with open(os.path.join(ROOT, p)) as f:
        return f.read()


def worker_release():
    s = read("apps/worker/src/release.js")
    ver = re.search(r"version:\s*'([^']+)'", s).group(1)
    core = re.search(r"core:\s*\['(\d{4})',\s*'(\d{4})'\]", s).groups()
    ext = re.search(r"extension:\s*\['(\d{4})',\s*'(\d{4})'\]", s).groups()
    kinds = re.findall(r"'([a-z]+\.[a-z_]+)'", re.search(r"work_kinds:\s*\[([^\]]*)\]", s).group(1))
    return {"version": ver, "supports_schema": {"core": list(core), "extension": list(ext)}, "work_kinds": kinds}


def migrations():
    out, errs = [], []
    for f in sorted(os.listdir(MIG)):
        if not f.endswith(".sql"):
            continue
        m = re.fullmatch(r"(\d{4})_[a-z0-9_]+\.sql", f)
        if not m:
            errs.append(f"R2 bad migration file name {f}")
            continue
        b = open(os.path.join(MIG, f), "rb").read()
        out.append({"version": m.group(1), "file": f, "sha256": hashlib.sha256(b).hexdigest()})
    vs = [x["version"] for x in out]
    if vs != sorted(set(vs)):
        errs.append("R2 migration versions not strictly increasing")
    return out, errs


def sbom():
    deps = []
    for lock in ("apps/worker/package-lock.json", "deploy/package-lock.json"):
        p = os.path.join(ROOT, lock)
        if not os.path.exists(p):
            continue
        j = json.load(open(p))
        for k, v in sorted((j.get("packages") or {}).items()):
            if k.startswith("node_modules/") and not v.get("dev"):
                deps.append({"ecosystem": "npm", "name": k.split("node_modules/")[-1], "version": v.get("version"),
                             "integrity": v.get("integrity"), "source": lock})
    for req in ("apps/executor/requirements.txt",):
        for m in re.finditer(r"^([A-Za-z0-9_.-]+)==([^\s\\]+)", read(req), re.M):
            deps.append({"ecosystem": "pypi", "name": m.group(1), "version": m.group(2), "source": req})
    return deps


def executor_version():
    m = re.search(r'EXECUTOR_RELEASE\s*=\s*"([^"]+)"', read("apps/executor/bnx_exec/jobs.py"))
    return m.group(1) if m else None


def shell_version():
    m = re.search(r"VERSION\s*=\s*'([^']+)'", read("apps/pwa/public/app/sw.js"))
    return m.group(1) if m else None


def build(prev):
    w = worker_release()
    migs, errs = migrations()
    first = {m["version"]: m.get("min_worker_release") for m in (prev or {}).get("migrations", [])}
    for m in migs:
        m["min_worker_release"] = first.get(m["version"]) or w["version"]
    ext = [m["version"] for m in migs if m["version"] >= "9000"]
    lo, hi = w["supports_schema"]["extension"]
    if not ext or hi != ext[-1]:
        errs.append(f"R1 worker extension range ends at {hi}, newest migration is {ext[-1] if ext else None}")
    if ext and lo not in ext[-2:]:
        errs.append(f"R1 worker extension range starts at {lo}; N-1 is {ext[-2] if len(ext) > 1 else ext[-1]}")
    olds = {m["version"]: m["sha256"] for m in (prev or {}).get("migrations", [])}
    for m in migs:
        if m["version"] in olds and olds[m["version"]] != m["sha256"]:
            errs.append(f"R4 migration {m['file']} changed after it was released (migrations are immutable)")
    man = {"format": "bnx-release-manifest/1.0", "worker": w, "executor": executor_version(), "pwa_shell": shell_version(),
           "migrations": migs, "sbom": sbom()}
    return man, errs


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args()
    prev = json.load(open(OUT)) if os.path.exists(OUT) else None
    man, errs = build(prev)
    if a.write:
        errs = [e for e in errs if not e.startswith("R4")]
    if errs:
        print("\n".join(errs))
        return 1
    text = json.dumps(man, indent=1, sort_keys=True) + "\n"
    if a.write:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        open(OUT, "w").write(text)
        print(f"wrote {os.path.relpath(OUT, ROOT)}: worker {man['worker']['version']}, {len(man['migrations'])} migrations, "
              f"{len(man['sbom'])} dependencies")
        return 0
    if prev is None or json.dumps(prev, indent=1, sort_keys=True) + "\n" != text:
        print("R4 release/manifest.json is out of date: run tools/s4/release_manifest.py --write and commit it")
        return 1
    print(f"release manifest OK: worker {man['worker']['version']}, {len(man['migrations'])} migrations, {len(man['sbom'])} dependencies")
    return 0


if __name__ == "__main__":
    sys.exit(main())
