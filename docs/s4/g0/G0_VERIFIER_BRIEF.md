# Balnexa — Independent G0 verification: brief for the verifier

You are the independent verifier for Balnexa G0. You did not write this code. Your job is to establish, on your own environment, whether the merged baseline behaves as specified, and to report exactly what you observed. You are not asked to fix anything.

## 1. Inputs

| Item | Where |
|---|---|
| Repository | `https://github.com/walter-luo/balnexa` (public) |
| Baseline to verify | Commit `ee13eee451a4969eef58ae8cac24ca0c905d5059`, tree `96b13ff4670fecfcc0d9f7360c73f62aa4e1c932` |
| The plan (authoritative for what to check and the pass criteria) | `docs/s4/g0/Balnexa_S4_G0_Independent_Verification_Plan_Rev1.md` on branch `s4/design-addendum-a1` |
| Design and decisions you may consult | `docs/s4/` on `main`, and the branch above |

Do **not** read or use the author's evidence (`EVIDENCE/` in the repository, CI logs and artifacts) before you have recorded your own verdicts. After recording them you may compare, and you must report any difference.

## 2. Rules

1. Use only synthetic data. Nothing in this work involves real personal or financial data.
2. Use a disposable machine or container with local PostgreSQL clusters only. `tests/py/harness.py` drops every database and role named `bnx_*` in the cluster it targets.
3. Do not push to the repository, open pull requests, or change any branch. Helper code you need (for example, for forced interleavings in V6.6 and V7.4) lives only in your own workspace.
4. Write `expected_results.md` (each check ID from the plan, with its pass criterion in your own words) **before** executing anything, and record its SHA-256 and a timestamp in your log.
5. Log every command with a timestamp. Run the full sequence twice per PostgreSQL major, starting from `initdb` each time.
6. If something in the plan is unclear or impossible, record it as a deviation, choose the most conservative reading, and continue. Questions for the author go in writing through the Owner; log each answer.
7. A SKIP is a failure. Items the plan classifies as `DEFERRED_BACKUP_GAP`, `NOT_IMPLEMENTED` or `NOT_VERIFIED` are reported with that label, never as PASS.

## 3. What to deliver (one ZIP)

| File | Content |
|---|---|
| `G0_REPORT.md` | Per check ID and per major (PG16, PG17): the verdict (`PASS`, `FAIL`, `DEFERRED_BACKUP_GAP`, `NOT_IMPLEMENTED`, `NOT_VERIFIED`), one line of evidence, and the evidence file name. Then findings graded P0–P3 with reproduction steps, and a statement of how each of the four independence conditions (plan, section "Purpose, baseline and independence") was met. Signed with your name or tool identity and the date |
| `environment.txt`, `checksums.txt`, `expected_results.md` | As described in the plan |
| `logs/`, `evidence/` | Raw command logs and outputs |
| `deviations.md` | Deviations from the plan, questions asked and answers received |
| `MANIFEST.sha256` | SHA-256 of every file in the ZIP |

## 4. Severity guide

| Grade | Meaning |
|---|---|
| P0 | Data loss or corruption, privilege escalation, a bypass of approval or activation authorization, or audit tampering that goes undetected (other than the documented V8.6 residual) |
| P1 | A security or integrity control missing or failing in a reachable path; a migration-integrity rule that does not hold |
| P2 | Incorrect behaviour without a direct security impact; reproducibility failure (different verdicts between runs) |
| P3 | Documentation mismatch, cosmetic issue |
