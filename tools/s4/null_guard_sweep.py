#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""L-R2-1: systematic NULL-guard sweep over every command and worker step the Python suites exercise.

The suites run unchanged with BNX_NULL_SWEEP set (tests/py/harness.py). Before every cmd_*/wrk_* call whose last argument
is a JSON object, the harness repeats the call in a rolled-back transaction once as given and, when that succeeds, once
per mutation of the object: each top-level key removed, set to null and (for a non-empty string or array) emptied, and
each key of the first object of an array of objects removed or set to null. Nothing is committed; the real call that
follows is unchanged.

This tool runs the suites on one server, then aggregates the mutations the database *accepted* per (function, key path,
mode). An accepted mutation is not necessarily a defect (many keys are optional); every accepted pair is listed in the
report for a reviewed disposition (tools/s4/null_guard_dispositions.json). The check fails when an accepted pair has no
disposition, when a pair dispositioned as `must_refuse` is still accepted, or when a function with a JSON argument is
neither exercised by a suite nor listed as reviewed by reading (`_not_exercised` in the dispositions file).

Usage:
  null_guard_sweep.py --server pg16 --out DIR              # run every suite with the sweep, then aggregate
  null_guard_sweep.py --aggregate DIR [--head 9039]        # aggregate an earlier run again (at the head it was taken at)
Output (DIR): sweep.jsonl (raw; function names, key paths and outcomes only, no values), report.json, report.md.
"""
import argparse, collections, glob, json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PY = os.path.join(ROOT, "tests", "py")
DISP = os.path.join(ROOT, "tools", "s4", "null_guard_dispositions.json")


def suites():
    return [os.path.join(PY, "run_g0.py")] + sorted(glob.glob(os.path.join(PY, "run_s4_core*.py")))


def run(server, out):
    os.makedirs(out, exist_ok=True)
    raw = os.path.join(out, "sweep.jsonl")
    if os.path.exists(raw):
        os.remove(raw)
    env = {**os.environ, "BNX_NULL_SWEEP": raw}
    status = {}
    for s in suites():
        name = os.path.basename(s)[:-3]
        with open(os.path.join(out, f"{name}.txt"), "w") as log:
            r = subprocess.run([sys.executable, s, "--server", server, "--evidence", os.path.join(out, "ev", name)],
                               cwd=PY, env=env, stdout=log, stderr=subprocess.STDOUT)
        status[name] = r.returncode
        print(f"{name}: exit {r.returncode}", flush=True)
    json.dump(status, open(os.path.join(out, "suite_status.json"), "w"), indent=1)


def latest_migration():
    return max(f[:4] for f in os.listdir(os.path.join(ROOT, "db", "migrations")) if f[:4].isdigit() and f.endswith(".sql"))


def aggregate(out, head=None):
    raw = os.path.join(out, "sweep.jsonl")
    head = head or latest_migration()       # --head: re-read an earlier run at the head it was taken at
    calls, tried, older = collections.Counter(), collections.Counter(), 0
    accepted = collections.defaultdict(lambda: collections.Counter())
    for line in open(raw):
        r = json.loads(line)
        if r.get("head") != head:            # a call on an older schema version (upgrade tests): not the current code
            older += 1
            continue
        calls[r["fn"]] += 1
        for x in r["results"]:
            key = (x["fn"], x["path"])
            tried[key] += 1
            if x["outcome"] == "ok":
                accepted[key][x["mode"]] += 1
    disp = json.load(open(DISP)) if os.path.exists(DISP) else {}
    rows, undisposed, regressions = [], [], []
    for (fn, path), modes in sorted(accepted.items()):
        d = disp.get(fn, {}).get(path)
        rows.append({"function": fn, "path": path, "accepted_modes": dict(modes), "tried": tried[(fn, path)],
                     "disposition": d["verdict"] if d else None, "reason": d["reason"] if d else None})
        if d is None:
            undisposed.append(f"{fn} {path}")
        elif d["verdict"] == "must_refuse":
            regressions.append(f"{fn} {path} {dict(modes)}")
    defined = set()
    for f in os.listdir(os.path.join(ROOT, "db", "migrations")):
        if f.endswith(".sql"):
            for name, args in re.findall(r"create (?:or replace )?function bnx\.((?:cmd|wrk)_[a-z0-9_]+)\(([^)]*)\)", open(os.path.join(ROOT, "db", "migrations", f)).read()):
                if "jsonb" in args:          # the sweep mutates a JSON argument; functions without one are out of scope
                    defined.add(name)
    exercised = {c.split(":")[0] for c in calls}
    static = disp.get("_not_exercised", {})          # functions no suite calls with a JSON argument: reviewed by reading
    rep = {"migration_head": head, "not_exercised": sorted(defined - exercised - set(static)),
           "reviewed_statically": {k: static[k] for k in sorted(set(static) & (defined - exercised))}, "calls_on_older_versions_skipped": older, "functions_exercised": len(calls), "calls_swept": sum(calls.values()), "pairs_tried": len(tried),
           "pairs_accepted": len(rows), "undisposed": undisposed, "must_refuse_still_accepted": regressions,
           "functions": sorted(calls), "accepted": rows}
    json.dump(rep, open(os.path.join(out, "report.json"), "w"), indent=1)
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write(f"# NULL-guard sweep (L-R2-1)\n\nMigration head: {head}. Undisposed pairs: {len(undisposed)}; must_refuse pairs still "
                f"accepted: {len(regressions)} {regressions}; JSON-argument functions neither swept nor reviewed by reading: "
                f"{len(rep['not_exercised'])}; reviewed by reading: {', '.join(rep['reviewed_statically']) or 'none'}.\n\n"
                f"Functions exercised: {rep['functions_exercised']}; calls swept: "
                f"{rep['calls_swept']}; (function, key path) pairs tried: {rep['pairs_tried']}; accepted with a key "
                f"absent, null or empty: {rep['pairs_accepted']}.\n\n| Function | Key path | Accepted modes | Disposition | Reason |\n"
                "|---|---|---|---|---|\n")
        for r in rows:
            f.write(f"| `{r['function']}` | `{r['path']}` | {', '.join(f'{k} {v}' for k, v in sorted(r['accepted_modes'].items()))} "
                    f"| {r['disposition'] or '**none**'} | {r['reason'] or ''} |\n")
    print(f"not exercised by any suite and not reviewed statically: {len(rep['not_exercised'])} {rep['not_exercised']}; "
          f"reviewed statically: {len(rep['reviewed_statically'])}")
    print(f"functions {rep['functions_exercised']}, pairs tried {rep['pairs_tried']}, accepted {rep['pairs_accepted']}, "
          f"undisposed {len(undisposed)}, must_refuse still accepted {len(regressions)}")
    return 1 if (undisposed or regressions or rep["not_exercised"]) else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server")
    ap.add_argument("--out")
    ap.add_argument("--aggregate")
    ap.add_argument("--head", help="with --aggregate: the migration head the run was taken at (default: the newest migration)")
    a = ap.parse_args()
    if a.aggregate:
        sys.exit(aggregate(a.aggregate, a.head))
    if not (a.server and a.out):
        ap.error("--server and --out, or --aggregate DIR")
    run(a.server, a.out)
    sys.exit(aggregate(a.out))


if __name__ == "__main__":
    main()
