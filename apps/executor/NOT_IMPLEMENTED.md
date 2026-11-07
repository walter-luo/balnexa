# apps/executor — NOT_IMPLEMENTED (R6.2-R1)

Status: **NOT_IMPLEMENTED.** No executor code exists in this package. Nothing here was run on Cloud Run.

| Item | Owning milestone | Objective acceptance tests (must run before any claim) |
|---|---|---|
| Container `bnx-exec` (hash_and_classify, OCR eng/chi_sim/chi_tra, parsers CSV/XLSX/OFX/QFX/PDF) | M1 (local), M0-B (cloud, after authorization) | M0-B-01…07: R2 direct PUT/multipart, MD5/SHA-256 tamper cases, OCR oracle with zero unflagged wrong amounts/dates, resume after SIGTERM, source dedup |
| Trusted SHA-256 writer for `evidence_object.sha256` / `integrity_state = 'verified'` | M1 | write-once trigger (0004) already enforced; executor identity must be the only writer — needs a `bnx_executor` path (today modelled in AT-ARC-02 by the owner role, labelled as such) |
| Drive second copy + re-hash → `bnx.wrk_record_archive_event` (implemented in 0109) | M1 / M0-B-08 | AT-ARC-02 (G0, passes), M0-B-08 real copy/egress/latency; capacity model `tests/sim/archive_capacity.py` |
| Backup job `bnx-backup` (pg_dump → age K2/K1 → GCS) | M1 / M0-E | AT-BAK-01 (G0, passes for the dump/restore path on PG16), AUD-038 keyring sim (re-run, passes), M0-E-01…07 |

Dependencies already present in the database: `wrk_*` worker functions, `bnx_worker` role, archive guard (0109), queue (0106).
