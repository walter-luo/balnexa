# apps/executor — status (S4 CORE-8)

Status: **PARTIAL (local only).** The package `bnx_exec` now has the job loop and four job kinds (CORE-8, see
`docs/s4/S4_CORE8_Implementation_Notes.md`): lease client (`gateway.py`), runner with SIGTERM handling (`runner.py`),
`REPORT_RENDER` (`render.py`), `BACKUP`, `RESTORE_DRILL` and `EVIDENCE_VERIFY` (`jobs.py`, `restore.py`), object store
(`store.py`, local directory only), `age` and PostgreSQL tool wrappers. 9011a/9011c library code (`sin_detector.py`,
`doc_validator.py`) is unchanged. Exercised by `tests/py/run_s4_core15.py` and `tests/blackbox/api.test.mjs` (BB-EXEC-02).
Run: `python -m bnx_exec run --kind KIND [--item ID ...]` with the `BNX_*` environment listed in `runner.Config`.
Nothing here was run on Cloud Run, GCS, R2 or Neon.

| Item | Owning milestone | Objective acceptance tests (must run before any claim) |
|---|---|---|
| Container images `bnx-exec` / `bnx-backup` (age, pg_dump/pg_restore 16+17, tesseract), Cloud Run Job definitions, job launch from the Worker tick | M0-A (cloud, after authorization) | M0-A-03/04 on Cloud Run: metadata-server ID token accepted by the Gateway; SIGTERM grace behaviour |
| GCS vault store and R2 store (replacing `LocalStore`) | M0-E / M0-B | M0-E-01…07, M0-B-01…07: real upload, generation, retention lock (O-8 only), re-download |
| Neon drill branch provisioner | M0-E | AT-BKP-12/13 on Neon; SECURITY_REVIEW of the Neon API key (D-9016-7) |
| Document, import, index, mail and T1 job handlers | WP-DOC / TAX-5 | AT-DOC-*, M0-B-*, AT-CRA-* (TAX-5 is behind the Owner gate G-CRA-1) |
| Drive second copy + re-hash → `bnx.wrk_record_archive_event` | DOC-1 / M0-B-08 | AT-ARC-02 (G0, passes), M0-B-08 |
