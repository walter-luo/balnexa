# Re-review prompt — 9011R (remediation of the 9011/G0R review of 2026-11-11)

You are reviewing the Balnexa repository `walter-luo/balnexa`, branch `s4/9011a` (draft PR #5), at the commit named by the
Owner when this prompt is handed over. Work in your own clone, read-only: push nothing, comment on nothing, approve nothing.
Synthetic data only: build every value at run time with `tests/py/sin_corpus.py` and never write one into a file, a log or
your report. `requirements/owner_sources/` is out of scope. Grade every verdict `SAME_FAMILY_VERIFICATION` unless you are a
different model family.

## Inputs

1. `docs/s4/S4_9011R_Remediation_2026-11-11.md`: the author's disposition of all 45 findings (R-01…R-45), the delegated
   decisions D-9011R-1…6, the cases that keep their verdict by design (§3) and the residual limits (§7).
2. Your earlier report `Balnexa_9011_review_SAME_FAMILY_2026-11-11.zip` (the Owner provides it). Its case builders are
   vendored in `tests/py/review9011/` (only the repository path and one coordinate notation changed; see the file headers).
3. `docs/s4/reviews/9011_REVIEW_PROMPT.md` (the original questions Q1–Q18).

## Environment

PostgreSQL 16 **and 17** (PGDG: `apt.postgresql.org`, `www.postgresql.org`; if your session cannot reach them, say so and mark
PG17 `NOT_VERIFIED`). Python 3.12 with `pip install --require-hashes --only-binary=:all: -r apps/executor/requirements.txt`
(now includes `pypdfium2`), `tesseract-ocr`, `tesseract-ocr-eng`, `strace`, Node 22 (`npm ci` in `apps/worker`).

## Tasks

1. **Regression:** the CI commands (`.github/workflows/ci.yml`) on both majors, including the new
   `tests/py/run_s4_core_9011r.py`. Report PASS/FAIL/SKIP per suite.
2. **Your own cases again:** run every case of your earlier ZIP against this commit (detector parity, end-to-end evasion,
   shared index, document states and races, owner-path attacks, verifier tamper copies, install orders, the validator light
   and heavy sets, the Z1 probes with the real OCR engine and DEBUG logging, the differential oracle). For every finding R-xx
   state: closed, partly closed, or open, with the case ids that show it.
3. **Bypass attempts on the new code:** in particular
   - the JSON machine-data exemption (D-9011R-1): can a value reach a stored column under an id, hash, key, nonce or token key,
     or by any other key-name trick;
   - the separator and grouping rules (D-9011R-2): a printed form a person would use that is still not a sequence;
   - the audit chain-append trigger (R-10): any INSERT path that breaks the chain, and the restore order;
   - the validator child process (R-18…R-21): any way to make content reach stderr, a log or disk, to escape the memory or
     time limit, or to leave an OCR process behind;
   - the PDF object parser, the rendering pass and the per-variant reading (R-23…R-30): any hiding place that is neither read
     nor failed closed.
4. **False positives:** run `tests/py/fp_corpus.py` and judge whether the measured cost (FP-SIN-01) and the decisions that
   bound it are acceptable; report any benign form you find that v1.1 flags.
5. **Disagreements:** name every delegated decision you disagree with, and why.

## Report

A ZIP named `Balnexa_9011R_review_<GRADE>_<date>.zip` with `REVIEW.md` (header table, regression table per major, finding
table with ID, severity, area, requirement, finding, reproduction without values, evidence grade, proposed fix, and the status
of R-01…R-45), `cases/`, `runs/`, and `SHA256SUMS`. Run `tools/s4/sin_repo_scan.py` over the report directory before
sealing it. Verdict: `CLEAN`, `NON_BLOCKING_FINDINGS` or `BLOCKING_FINDINGS`.
