#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""G0-09 machine-checked contradiction sweep (R6.2-R1 + AI-first reconciliation).
Usage: contradiction_sweep.py --r1 <R1 package root> --recon <reconciliation root> --d04 <dir with Draft-04 documents>
Each check prints PASS/FAIL with the offending values; exit 1 on any FAIL."""
import argparse, csv, glob, hashlib, json, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--r1", required=True); ap.add_argument("--recon", required=True); ap.add_argument("--d04", required=True)
a = ap.parse_args()
R1, RC, D4 = a.r1, a.recon, a.d04
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")
    if not ok:
        fails.append(name)


rd = lambda *p: open(os.path.join(*p), encoding="utf-8").read()
recon_doc = rd(RC, "Balnexa_AI_First_Reconciliation_R6.2-R1_V1.0.md")
readiness = rd(R1, "RELEASE_READINESS.md")
closure = rd(R1, "README_CLOSURE.md")
delta = rd(R1, "docs/R1_Doc_Delta.md")
selfrev = rd(R1, "CLAUDE_SELF_REVIEW.md")
docs_all = recon_doc + readiness + closure + delta + selfrev + rd(R1, "docs/AUD-048_Acceptance_Matrix.md")
sql = "".join(rd(f) for f in sorted(glob.glob(os.path.join(R1, "db/migrations/*.sql"))) + [os.path.join(R1, "db/bootstrap/B001_bootstrap.sql")])
worker = "".join(rd(f) for f in glob.glob(os.path.join(R1, "apps/worker/src/*.js")))
oracle = rd(RC, "design/r28/r28_oracle.py")

# 1 gate decisions agree between the two documents
def gate(text, label):
    m = re.search(r"\|\s*\*\*" + label + r"[^|]*\|\s*\*\*(PASS|CONDITIONAL|REVISE|BLOCK)\*\*", text)
    return m.group(1) if m else None
pairs = [("G0", gate(readiness, "G0"), gate(recon_doc, "Existing G0")),
         ("M0", gate(readiness, "G1 / M0"), gate(recon_doc, "Authorized synthetic M0")),
         ("G2-proposed", gate(readiness, r"G2\*\* \(proposed"), gate(recon_doc, "Proposed G2")),
         ("Production", gate(readiness, "Production"), gate(recon_doc, "Production"))]
check("gate decisions consistent", all(x and x == y for _, x, y in pairs), json.dumps(pairs))

# 2 role names: every bnx_<role> token in documents is a role created by B001 (or a known non-role identifier)
roles = set(re.findall(r"\('(bnx_[a-z]+)', (?:true|false)\)", rd(R1, "db/bootstrap/B001_bootstrap.sql")))
non_role = {"bnx_rpt", "bnx_session", "bnx_executor"}   # schema, cookie, proposed (flagged as not existing) identity
used = set(re.findall(r"\b(bnx_[a-z]+)\b", docs_all))
check("role names", used <= roles | non_role, f"roles={sorted(roles)} unknown={sorted(used - roles - non_role)}")
check("bnx_executor only mentioned as not existing", all("bnx_executor" not in l or "needs" in l or "proposed" in l.lower() for l in docs_all.splitlines()))

# 3 code facts vs document statements
facts = {
    "backstop 3 h": ("BACKSTOP_HOURS = 3" in worker, "every 3 h" in docs_all),
    "tick 5 min": ("TICK_MINUTES = 5" in worker, "5 min tick" in docs_all),
    "lease 10 min": ("interval '10 minutes'" in sql, "10 min lease" in docs_all),
    "URL TTL 60 s": ("then 60 else" in sql or "else 60 end" in sql, "60 s" in docs_all),
    "access token 15 min": ("'expires_in', 900" in sql, "15 min" in docs_all),
    "session 90 d absolute / 30 d idle": ("interval '90 days'" in sql and "interval '30 days'" in sql, True),
}
check("code facts referenced by documents exist in code", all(c and d for c, d in facts.values()), json.dumps(facts))

# 4 migration list and hashes in README_CLOSURE equal the files
files = sorted(os.path.basename(f) for f in glob.glob(os.path.join(R1, "db/migrations/*.sql")))
listed = re.findall(r"`db/migrations/(\d{4}_[a-z0-9_]+\.sql)`", closure)
check("migration list = README_CLOSURE", files == sorted(set(listed)), f"files-only={set(files)-set(listed)} listed-only={set(listed)-set(files)}")
bad = []
for path, h in re.findall(r"\| `([^`]+)`(?: \(= Draft-04\))? \| `([0-9a-f]{64})` \|", closure):
    p = os.path.join(R1, path)
    if not os.path.exists(p) or hashlib.sha256(open(p, "rb").read()).hexdigest() != h:
        bad.append(path)
check("README_CLOSURE hashes equal files", not bad, str(bad))

# 5 tracker: 54 unique AUD IDs, no CLOSED, vocabulary, identical copies, test IDs exist
tr = list(csv.DictReader(open(os.path.join(R1, "AUD001_054_Master_Tracker.csv"), encoding="utf-8")))
ids = [x["aud_id"] for x in tr if x["aud_id"].startswith("AUD-")]
check("tracker 54 unique AUD IDs", len(ids) == 54 == len(set(ids)) and ids == [f"AUD-{i:03d}" for i in range(1, 55)])
check("tracker has no CLOSED", not any("CLOSED" == x["r1_status"] or x["proposed_closure_for_reviewer"].upper().startswith("CLOSED") for x in tr))
vocab = {"AUTHOR_TESTED_AWAITING_INDEPENDENT_REPRODUCTION", "PARTIALLY_IMPLEMENTED_AUTHOR_TESTED", "UNCHANGED_IN_R1", "DOCUMENTED_MATRIX", "OPEN_RISK", "NOT_EXECUTED"}
check("tracker status vocabulary", {x["r1_status"] for x in tr} <= vocab, str({x["r1_status"] for x in tr} - vocab))
same = hashlib.sha256(open(os.path.join(R1, "AUD001_054_Master_Tracker.csv"), "rb").read()).digest() == \
    hashlib.sha256(open(os.path.join(RC, "AUD001_054_Master_Tracker.csv"), "rb").read()).digest()
check("tracker copies identical", same)
known = set()
for s in ("pg16", "pg17"):
    known |= {r["id"] for r in json.load(open(os.path.join(R1, f"EVIDENCE/{s}/g0_results.json")))["results"]}
known |= set(re.findall(r"(BB-[A-Z]+-\d\d)", rd(R1, "EVIDENCE/blackbox/blackbox_pg16.tap")))
cited = set()
for x in tr:
    if x["r1_status"] != "UNCHANGED_IN_R1":
        for t in re.findall(r"\b(AT-[A-Z]+-\d\d)\b", x["tests"]):
            cited.add(t)
for t in re.findall(r"\b(AT-(?:MIG|BAL|CMD|CONC|PLAN|FAULT|SNAP|OWN|SRC|EVP|ARC|Q|BAK|MUT)-\d\d)\b", docs_all):
    cited.add(t)
missing = sorted(t for t in cited if t not in known and not t.startswith(("AT-SNAP-01", "AT-SNAP-02", "AT-OWN-01", "AT-OWN-02", "AT-OWN-03", "AT-OWN-04")))
check("every cited R1 test ID exists in the executed results", not missing, str(missing))

# 6 executed results match the stated summary
s16 = json.load(open(os.path.join(R1, "EVIDENCE/pg16/g0_results.json"))); s17 = json.load(open(os.path.join(R1, "EVIDENCE/pg17/g0_results.json")))
check("PG16 40/0/0 and PG17 38/0/2 as stated", (s16["pass"], s16["fail"], s16["skip"]) == (40, 0, 0) and (s17["pass"], s17["fail"], s17["skip"]) == (38, 0, 2)
      and "40 PASS / 0 FAIL / 0 SKIP" in closure and "38 PASS / 0 FAIL / 2 SKIP" in closure)
bb = all("# pass 7" in rd(R1, f"EVIDENCE/blackbox/blackbox_{s}.tap") and "# fail 0" in rd(R1, f"EVIDENCE/blackbox/blackbox_{s}.tap") for s in ("pg16", "pg17"))
check("black-box 7/7 on both servers", bb)

# 7 Draft-04 superseded tokens: every occurrence is listed in the doc delta
docmap = {"A": "Balnexa_Unified_Architecture_V1.0_R6.2_Draft04.md", "M": "Balnexa_HA_Platform_Qualification_M0_R6.2_Draft04.md",
          "C": "Balnexa_Cloud_Cost_and_Quota_Model_R6.2_Draft04.md", "B": "Balnexa_Backup_and_Disaster_Recovery_R6.2_Draft04.md"}
tokens = {"work_pending": "D-06", "source_txn_link_event": "D-03", "0001–0007": "D-02", "snapshot_replay_access": "D-04",
          "jl_same_txn": ("D-01", "D-08"), "non-immutability triggers": "D-08"}
rows = {m.group(1): m.group(2) for m in re.finditer(r"^\| (D-\d\d) \| ([^|]*) \|", delta, re.M)}
unlisted = []
for tok, dl in tokens.items():
    dl = dl if isinstance(dl, tuple) else (dl,)
    for k, fn in docmap.items():
        for i, line in enumerate(open(os.path.join(D4, fn), encoding="utf-8"), 1):
            if tok in line and not any(re.search(rf"\b{k}:{i}\b", rows.get(d, "")) for d in dl):
                unlisted.append(f"{tok} {k}:{i}")
check("every Draft-04 occurrence of a superseded token is listed in the delta", not unlisted, str(unlisted))
d07_ok = all(re.search(r"24\s?h|24 hours", open(os.path.join(D4, docmap[k]), encoding="utf-8").read().splitlines()[int(n) - 1])
             for k, n in re.findall(r"\b([AMB]):(\d+)", rows.get("D-07", "")))
check("D-07 listed lines all state the 24 h target", d07_ok)

# 8 crosswalk partition and R28 standalone agree across CSV and document
cw = list(csv.DictReader(open(os.path.join(RC, "design/crosswalk/R01_R34_Crosswalk_R6.2-R1_V1.0.csv"), encoding="utf-8")))
from collections import Counter
cnt = Counter(x["class"] for x in cw)
check("crosswalk 10/13/7/1/3 and R28 STANDALONE", dict(cnt) == {"CORE": 10, "MERGE": 13, "CONTROL": 7, "STANDALONE": 1, "DEFER": 3}
      and next(x for x in cw if x["id"] == "R28")["class"] == "STANDALONE" and "CORE 10 + MERGE 13 + CONTROL 7 + STANDALONE 1 + DEFER 3 = 34" in recon_doc)
oc = sorted(x["id"] for x in cw if x["owner_confirmed"].startswith("YES"))
check("Owner-confirmed rows = R09,R10,R19,R20,R25,R26,R28,R34", oc == ["R09", "R10", "R19", "R20", "R25", "R26", "R28", "R34"], str(oc))

# 9 R28 oracle result and document values agree
log = rd(RC, "design/r28/r28_oracle_run.log")
fx = json.load(open(os.path.join(RC, "design/r28/r28_fixtures.json")))
docvals_ok = all(v.replace(",", "") in recon_doc.replace(" ", "").replace(" ", "") or isinstance(v, (bool, int)) or v is None
                 for f in fx["fixtures"] for k, v in f["expected"].items() if k in ("accrued_interest_total", "accrued_interest") and isinstance(v, str))
check("R28 oracle all PASS and document quotes oracle amounts", "ALL R28 ORACLE FIXTURES PASS" in log and docvals_ok)

# 10 error codes cited in documents exist in code
codes = set(re.findall(r"`([A-Z][A-Z0-9]+(?:_[A-Z0-9]+)+)`", docs_all))
ignore = {"AUTHOR_RUNTIME_EVIDENCE", "TERMS_UNVERIFIED", "DESIGN_RESOLVED", "TEST_PENDING", "OWNER_DECISION_PENDING", "NOT_EXECUTED",
          "NOT_IMPLEMENTED", "M0_PENDING", "OWNER_DECISION_REQUIRED", "PROPOSED_MERGE", "PROPOSED_CONTROL", "CORE_SELECTED",
          "OWNER_CONFIRMED_MERGE", "OWNER_CONFIRMED_DEFER", "OWNER_CONFIRMED_STANDALONE", "BACKUP_CANNOT_READ", "DEFAULT_PRIVILEGE_MISSING",
          "BACKUP_WRITE", "ILLUSTRATIVE", "ACT_365", "REF_HMAC_KEY", "DOCUMENTED_DESIGN", "STATIC_CONFIRMED", "PROVIDER_DOC_VERIFIED"}
unknown = sorted(c for c in codes - ignore if c not in sql and c not in worker and c not in oracle and not c.startswith(("OWNER_", "NOT_")))
check("error codes cited exist in SQL/Worker/oracle", not unknown, str(unknown))

# 11 no forbidden over-claims
over = [l.strip()[:120] for l in docs_all.splitlines()
        if re.search(r"\b(M0|G1|production|provider)[^|]{0,40}\bPASS\b", l) and not re.search(r"NOT_EXECUTED|pending|PENDING|only after|M0_PENDING|signed|PASS/FAIL|readiness", l)]
check("no PASS claimed for M0/production/provider items", not over, str(over[:5]))

print(f"== contradiction sweep: {'PASS' if not fails else 'FAIL'} ({len(fails)} failing checks)")
sys.exit(1 if fails else 0)
