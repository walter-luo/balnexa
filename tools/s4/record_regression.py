#!/usr/bin/env python3
"""Keep the record of one full local regression run in the repository (Owner instruction 2026-11-12 16:08: "自我测试不要减少，
测试记录要保留，保留在GitHub" — do not reduce self-testing; keep the test records, in GitHub, so that tests are not repeated
after go-live).

Input: the output directory of one regression run (scratchpad regrun.sh: <suite>.txt per server and suite, blackbox.txt,
pwa_<server>.txt, sim.txt, ev/<server>/<suite>/*_results.json). Output: EVIDENCE/regression/<date>_<short sha>/ with the raw
outputs, the per-suite result JSON files and INDEX.md (commit, branch, time, per-suite pass/fail/skip, totals).

Only text outputs and result JSON are kept (database dumps and other large artefacts are not); files over 2 MiB are skipped
and listed. The repository SIN scan (guard C6) must stay clean before the record is committed.

Usage: record_regression.py --from DIR --sha FULLSHA --branch NAME [--note TEXT]"""
import argparse, datetime as dt, glob, json, os, re, shutil, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAX = 2 * 1024 * 1024


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--branch", required=True)
    ap.add_argument("--note", default="")
    a = ap.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", a.sha):
        sys.exit("--sha must be a full commit id")
    if not os.path.exists(os.path.join(a.src, "done")):
        sys.exit("the run is not complete (no 'done' marker)")
    when = dt.datetime.fromtimestamp(os.path.getmtime(os.path.join(a.src, "done")), dt.timezone.utc)
    out = os.path.join(ROOT, "EVIDENCE", "regression", f"{when:%Y-%m-%d}_{a.sha[:7]}")
    os.makedirs(out, exist_ok=True)
    rows, skipped, tot = [], [], {"pass": 0, "fail": 0, "skip": 0}
    for p in sorted(glob.glob(os.path.join(a.src, "*.txt"))):
        name = os.path.basename(p)
        if os.path.getsize(p) > MAX:
            skipped.append(name); continue
        shutil.copyfile(p, os.path.join(out, name))
        t = open(p, errors="replace").read()
        m = re.search(r"== (pg1[67]): (\d+) PASS, (\d+) FAIL, (\d+) SKIP", t)
        if m:
            pa, fa, sk = int(m.group(2)), int(m.group(3)), int(m.group(4))
        else:
            mp, mf = re.findall(r"^# pass (\d+)$", t, re.M), re.findall(r"^# fail (\d+)$", t, re.M)
            if mp:
                pa, fa, sk = int(mp[-1]), int(mf[-1]) if mf else 0, 0
            elif '"result": "PASS"' in t:
                pa, fa, sk = 1, 0, 0
            else:
                pa, fa, sk = 0, 1, 0
        for k, v in (("pass", pa), ("fail", fa), ("skip", sk)):
            tot[k] += v
        rows.append((name[:-4], pa, fa, sk))
    for p in sorted(glob.glob(os.path.join(a.src, "ev", "*", "*", "*results*.json"))):
        if os.path.getsize(p) > MAX:
            skipped.append(os.path.relpath(p, a.src)); continue
        rel = os.path.relpath(p, os.path.join(a.src, "ev"))
        os.makedirs(os.path.join(out, "results", os.path.dirname(rel)), exist_ok=True)
        shutil.copyfile(p, os.path.join(out, "results", rel))
    lines = [f"# Regression record {when:%Y-%m-%d %H:%M} UTC — commit `{a.sha}`", "",
             f"- Branch: `{a.branch}`", f"- Commit: `{a.sha}`", f"- Finished: {when.isoformat()}",
             "- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 and 17, Node black-box and Playwright PWA suites, "
             "dispatcher simulation (scratchpad `regrun.sh`)", f"- Note: {a.note}" if a.note else "", "",
             f"**Totals:** {tot['pass']} pass, {tot['fail']} fail, {tot['skip']} skip", "",
             "| Suite | Pass | Fail | Skip |", "|---|---|---|---|"]
    lines += [f"| {n} | {p} | {f} | {s} |" for n, p, f, s in rows]
    if skipped:
        lines += ["", "Not kept (over 2 MiB): " + ", ".join(skipped)]
    lines += ["", "Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`."]
    open(os.path.join(out, "INDEX.md"), "w").write("\n".join(x for x in lines if x is not None) + "\n")
    idx = os.path.join(ROOT, "EVIDENCE", "regression", "README.md")
    entry = f"| {when:%Y-%m-%d %H:%M} | `{a.sha[:7]}` | `{a.branch}` | {tot['pass']} | {tot['fail']} | {tot['skip']} | [{os.path.basename(out)}]({os.path.basename(out)}/INDEX.md) |"
    head = ["# Regression records", "", "One row per full local regression run kept in the repository (Owner instruction 2026-11-12).", "",
            "| Finished (UTC) | Commit | Branch | Pass | Fail | Skip | Record |", "|---|---|---|---|---|---|---|"]
    body = [l for l in (open(idx).read().splitlines()[len(head):] if os.path.exists(idx) else []) if l.strip() and f"`{a.sha[:7]}`" not in l]
    open(idx, "w").write("\n".join(head + sorted(body + [entry])) + "\n")
    print(f"recorded {os.path.relpath(out, ROOT)}: {tot['pass']} pass, {tot['fail']} fail, {tot['skip']} skip")
    return 1 if tot["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
