# apps/executor — NOT_IMPLEMENTED (R6.2-R1)

Status: **PARTIAL (local only).** 9011a/9011c added `bnx_exec/sin_detector.py` (SIN/ITN detector, reference
implementation) and `bnx_exec/doc_validator.py` (transient Z1 document validator: format allowlist, in-memory extraction,
OCR through the tesseract binary, verdict-only staging payloads). Both are library code exercised by the local test suites
(`tests/py/run_s4_core5.py`, `tests/py/run_s4_core6.py`). There is no container, no job runner, no Drive or mail fetcher
and no cloud identity yet. Nothing here was run on Cloud Run.

| Item | Owning milestone | Objective acceptance tests (must run before any claim) |
|---|---|---|
| Container `bnx-exec` (hash_and_classify, OCR eng/chi_sim/chi_tra, parsers CSV/XLSX/OFX/QFX/PDF) | M1 (local), M0-B (cloud, after authorization) | M0-B-01…07: R2 direct PUT/multipart, MD5/SHA-256 tamper cases, OCR oracle with zero unflagged wrong amounts/dates, resume after SIGTERM, source dedup |
| Trusted SHA-256 writer for `evidence_object.sha256` / `integrity_state = 'verified'` | M1 | write-once trigger (0004) already enforced. 9011c: for Inbox and mail documents the hash reaches `evidence_object` only through a lease-bound `doc_archived` staging payload promoted by `bnx.wrk_doc_archived` (AT-SIN-05,07, AT-SIN-29). The cloud identity of the Executor (who may hold a lease) is still open — M0-B |
| Drive second copy + re-hash → `bnx.wrk_record_archive_event` (implemented in 0109) | M1 / M0-B-08 | AT-ARC-02 (G0, passes), M0-B-08 real copy/egress/latency; capacity model `tests/sim/archive_capacity.py` |
| Backup job `bnx-backup` (pg_dump → age K2/K1 → GCS) | M1 / M0-E | AT-BAK-01 (G0, passes for the dump/restore path on PG16), AUD-038 keyring sim (re-run, passes), M0-E-01…07 |

Dependencies already present in the database: `wrk_*` worker functions, `bnx_worker` role, archive guard (0109), queue (0106).
