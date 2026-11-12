# Review prompt — 9011a–c and G0R (SIN/ITN detector, document intake states, Executor validator, G0 remediation)

Paste everything below the line into a new Claude Code session that uses **Claude Sonnet 5.5**. The session has not seen
the author's work. Its result is graded `SAME_FAMILY_VERIFICATION`: a reviewer from the same model family as the author,
under Owner decision D1 as amended on 2026-11-10 (`docs/s4/OWNER_DECISIONS_2026-11-10.md` §5 on branch
`s4/design-addendum-a1`). It is not independent verification.

---

You are reviewing work package 9011 (increments 9011a, 9011b and 9011c) of Balnexa S4 V1.2, and the G0 remediation G0R
that the same migration carries. The repository is
`walter-luo/balnexa` (public). The work is on branch `s4/9011a`, draft PR #5, base `main` at `ee13eee`. The author was a
different Claude session. Your job is to find defects. Do not confirm the author's claims without checking them yourself.

## Ground rules (binding)

1. **Read-only toward the repository.** Do not push, do not comment on or approve PR #5, do not merge, and do not create
   branches on GitHub. Local edits for experiments are allowed only in your own clone, and they are never pushed.
2. **Synthetic data only.** Never type, generate or paste a real Social Insurance Number or any real government ID. Build
   test values only with `tests/py/sin_corpus.py` (`value(kind, seed)`). Never write a generated nine-digit value into
   your report: refer to cases by id, seed and rule code.
3. Do not open, request or look for anything under `requirements/owner_sources/`. It is Owner-private and not in the repo.
4. No cloud resources, no deployment, no real documents and no network fetches of documents. Installing packages from PyPI,
   npm and the Ubuntu archive is allowed.
5. Grade every finding with the evidence you actually produced: `REVIEWER_RUNTIME_EVIDENCE` (you ran it) or
   `REVIEWER_STATIC_READING` (you read it). Never report something as verified when you only read it.

## Sources of truth

- Design: branch `s4/design-addendum-a1`.
  - `docs/s4/design/Balnexa_S4_V1.2_Addendum_A1r1_SIN_Redaction.md` (ACCEPTED): detector §3, zones §4, states §5,
    requirements DOC-SIN §7, tests AT-SIN §8.
  - `Balnexa_S4_V1.2_Addendum_A1_SIN_Redaction.md` §7: the original AT-SIN-01…10.
  - `docs/s4/OWNER_DECISIONS_2026-11-10.md`: Owner decisions A1-OD-1…3 and the delegation boundaries.
- Implementation notes, with every `DELEGATED_DECISION` and known limit: `docs/s4/S4_9011a_Implementation_Notes.md`
  (sections 9011a, 9011b, 9011c).

## What is in scope

| Increment | Files |
|---|---|
| 9011a | `spec/sin-detector/sin_detector_v1.json`, `tools/s4/gen_sin_detector_spec.py`, `apps/executor/bnx_exec/sin_detector.py`, `apps/worker/src/sin_detector.js`, the detector functions and guards in `db/migrations/9011_s4_documents_evidence_renditions.sql`, `tests/fixtures/s4/sin_corpus_v1.json`, `tests/py/sin_corpus.py`, `tools/s4/sin_repo_scan.py`, the CI repository-scan step |
| 9011b | The 9011b block of migration 9011 (the `bnx_doc` tables, state trigger, promoters, declaration and tag commands, queue, rescan, `wrk_audit_sin_refusal`); MODIFYs of `bnx.audit`, `bnx.stage_write`, `bnx.wrk_consume_shared_index` and `bnx.wrk_promote_staged`; the Worker guards C3 and C4 in `apps/worker/src/index.js` |
| G0R | `docs/s4/G0_REMEDIATION_2026-11-11.md` (findings F-01…F-07 of the G0 run of 2026-11-11 and their disposition), `db/bootstrap/B003_audit_owner.sql`, the G0R block at the top of migration 9011, the B003 gate in `db/tools/run_migrations.py`, `tools/s4/audit_chain_verify.py`, `tests/py/run_s4_core7.py`, the `harness.migrate` B003 step and the AT-BAK-01 dump scope |
| 9011c | `apps/executor/bnx_exec/doc_validator.py`, `apps/executor/requirements.txt`, the Z3 registration in `bnx.wrk_doc_archived` and `bnx_doc.document_evidence`, `tests/py/doc_fixtures.py`, `tests/py/doc_z1_probe.py`, `tests/py/run_s4_core6.py`, the CI changes |

## Setup

PostgreSQL 16 and 17 must be reachable the way `tests/py/harness.py` expects: port 55416/55417, socket directory
`/var/lib/postgresql/bnx16` / `bnx17`, user `postgres`, trust auth. `.github/workflows/ci.yml` shows exactly how CI builds
them. You also need `pip install "psycopg[binary]==3.2.3"`, `pip install --require-hashes -r apps/executor/requirements.txt`
(use `--only-binary=:all:`), `apt install tesseract-ocr tesseract-ocr-eng strace`, Node 22, and `npm ci` in `apps/worker`.

Run the full regression on both majors exactly as CI does:
`tests/py/run_g0.py`, every `tests/py/run_s4_core*.py`, `tests/blackbox/api.test.mjs`, `tests/sim/dispatch_sim.mjs`,
`python3 tools/s4/sin_repo_scan.py --all-history`, and gitleaks with `.gitleaks.toml`. Record the pass/fail/skip counts. A
SKIP must have a stated reason.

## Review questions (answer each; findings may go beyond them)

**A. Detector (guard C1).**
1. Do Python, JS and SQL implement the same algorithm as the spec for origins `native`/`typed`? Write at least 20 *new*
   adversarial cases with the corpus generator and compare the three. Cover Unicode digits, separators, zero-width
   characters, labels at the window edges, glued labels, BN15 program accounts, the hex/UUID exemption, and JSON keys.
2. Is the hex/UUID exemption (D-9011a-1: unconditional, even next to a label) exploitable? For example, could a real SIN be
   hidden by making it the start of a 32-character hex run? Judge the risk and propose a bounded fix if there is one.
3. Check the OCR rules (`R_OCR9`, `R_OCR_RUN`, t_ocr 0.90) against Addendum §3.5.

**B. Database guards and states (C2, DOC-SIN-05…14).**
4. Can any path move a document from `QUARANTINED`, `INVALIDATED` or `SCAN_INCOMPLETE` to `ADMISSIBLE`/`ARCHIVED` without
   a new scan under a new detector version? Try direct calls as each runtime role (`bnx_worker`, `bnx_gateway` and the
   others in the migrations), replayed staging payloads, reuse of leases, and races between two promotions.
5. Can a declaration be made by anyone other than the Owner on the PWA channel? Can it be bound to bytes other than the
   scanned SHA-256, or carried over to a new revision?
6. Can a SIN candidate reach a stored column, the audit chain (`bnx.audit_event`), a notification, an intake exception, the
   shared index or an MCP response? Look for unscanned JSON paths, numbers versus strings, and keys.
7. 9011c Z3 registration: can `evidence_object.sha256` be set from anything other than a lease-bound `doc_archived` payload
   whose hash equals the current passing scan? Check the dedupe by SHA-256, the size check, the re-admission path, and
   the write-once triggers (0004, 9004).

**C. Executor validator (Z1, DOC-SIN-01/02/03/07).**
8. Build your own synthetic fixtures (in memory) that hide a corpus value somewhere the validator might miss. Ideas:
   - PDF: a different filter (ASCIIHex, LZW, a filter array), object streams, an XRef stream, a broken xref, a value split
     across TJ elements or across two `Tj` operators, a ToUnicode remapping, form XObjects, Type3 glyphs, a nested
     attachment, a portfolio.
   - XLSX: shared strings versus inline strings, formulas, data validation, pivot caches, charts, custom XML, `.bin`
     parts.
   - EML: encoded-word headers, quoted-printable versus base64, TNEF, a nested message.
   - Images: TIFF, a multi-frame GIF, a large image, a rotated or low-contrast value.

   Each miss is a finding. Say which rule should have fired.
9. Does every failure path fail closed (`SCAN_INCOMPLETE`)? Look for exceptions that are swallowed without `sc.fail`,
   limits that can be bypassed (zip bombs, deep nesting, huge streams, the time budget), and decompression without a
   bound.
10. Z1 hygiene: does any path write a temporary file, log content, or keep content after `validate` returns? Re-run
    AT-SIN-31 and try at least one extra scenario of your own.
11. Can a crafted file make the validator report `PASSED` while it contains a corpus value that the reference detector
    flags in the same extracted text?

**E. G0 remediation (G0R).**
14. F-01: as `bnx_migrator` → `SET ROLE bnx_definer`, and as each runtime role, try every way you know to remove, change,
    reorder or hide rows of `bnx_audit.audit_event` without a superuser. Ideas: DDL on the view, rules, triggers on other
    tables, functions with side effects, `ALTER DEFAULT PRIVILEGES`, publication or subscription objects, `COPY`, large
    objects, `pg_dump` and restore paths, the restore mode GUC. Each success is a BLOCKER.
15. Is `balnexa_audit_owner` reachable? Check memberships, `ADMIN OPTION`, `SECURITY DEFINER` functions owned by it (there
    must be none), and the installer's re-grant window (R-4).
16. Run `tools/s4/audit_chain_verify.py` against your own tampered copies (superuser) with and without `--anchor`. Can a
    tamper pass with an anchor? Can its catalog checks be satisfied while the protection is weakened?
17. Install a fresh database as a non-superuser installer, exactly as the B003 header says. Then install a second database
    in the same cluster with the superuser installer (as `tests/py/harness.py` does). Do both reach 0 violations? (A
    second database by the same non-superuser installer cannot run B001 again; that is the known G0 limitation DEV-08,
    not a finding.)
18. F-04: is the printable-ASCII envelope rule applied on every path that writes envelope values into the audit chain?

**D. Process and evidence.**
12. Do the implementation notes match the code? List each `DELEGATED_DECISION` you disagree with, and say why.
13. Do the CI changes run the new suite on both majors, with hash-pinned dependencies? Did the repository scan stay clean?

## Report (deliver as one ZIP)

Name the ZIP `Balnexa_9011_review_SAME_FAMILY_<yyyy-mm-dd>.zip`. It must contain:

- `REVIEW.md` with:
  - a header: model, date, commit reviewed (`git rev-parse HEAD` of `s4/9011a`) and grade `SAME_FAMILY_VERIFICATION`;
  - a summary verdict: `NO_BLOCKING_FINDINGS` or `BLOCKING_FINDINGS`;
  - a findings table with columns ID (R-01…), Severity (`BLOCKER` / `MAJOR` / `MINOR` / `NOTE`), Area (A–D),
    Requirement (DOC-SIN-x, AT-SIN-x, D-…), Finding, Reproduction (commands and case ids, no values), Evidence grade, and
    Proposed fix;
  - answers to questions 1–18.
- `runs/`: the raw outputs and results JSON of every suite you ran, per major.
- `cases/`: your adversarial fixture builders as code (generators only, no generated values), so the author can re-run
  them.
- `SHA256SUMS` over every file in the ZIP.

Before zipping, run `python3 tools/s4/sin_repo_scan.py` over your report directory (pass it as the path, or copy the
directory into a scratch clone) and make sure it finds no candidate. Then stop. The Owner returns the ZIP to the author.
