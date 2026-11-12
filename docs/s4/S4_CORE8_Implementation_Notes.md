# S4 CORE-8 — Executor: lease client, job loop, render, backup, restore drill, evidence re-hash — Implementation notes

Status: implemented on branch `s4/core-8` (stacked on `s4/core-7`, PR #9): Python package `apps/executor/bnx_exec/`, database
support in `db/migrations/9018_s4_executor_work_orders.sql`, Gateway completion schemas and the artifact proxy in `apps/worker/src/`.
Evidence grade: `AUTHOR_RUNTIME_EVIDENCE` (author's local runs on PG16.15 and PG17.11; CI on the PR); not independently reviewed.
Nothing ran on Cloud Run, GCS, R2 or Neon: no cloud resource, identity, key or bucket was created or contacted (M0-A, M0-E).

Authority: WP matrix V1.2 row CORE-8 ("Executor (Python 3.12 per OD-02): lease API client, job loop, hashing, parsers,
report/index rendering, backup/restore drills (R1 backup procedure + header + manifest + K2 + drills)"); UA V1.2 §9.2 (Executor
placement and trust: lease, nonce, staging only), §9.3 (normative backup procedure, steps 1–9), §9.4 (K2), §5.8.2 (snapshot
artifacts) and §3 (`pg_dump`/`pg_restore` 16 and 17 in the image); 9013 limit L-9013-2 (Executor `REPORT_RENDER`, artifact
proxy); 9016 result contract (D-9016-5). Acceptance: AT-EXEC-01/02, AT-BAK-01/03/04, AT-BKP-20, M0-A-03/04 (shape only).

## What was built

| Part | Content |
|---|---|
| `bnx.exec_work_order` (9018) | The input of one job, built by `wrk_issue_exec_lease` **before** the lease row (a refused order leaves no lease) and returned as `input`. `REPORT_RENDER`: the snapshot's projection rows **as digested** (`rows_text`), refused (`SNAPSHOT_DIGEST_MISMATCH`) unless their SHA-256 equals `projection_sha256`; source revision (= ledger version), ownership revision, account labels, object prefix. `BACKUP`: `wrk_backup_due` (advisory). `RESTORE_DRILL`: the facts of the VERIFIED run named by `item_id` (object, generation, digests, drill key and fingerprint, migrations, header facts). `EVIDENCE_VERIFY`: up to 50 hashed evidence objects with their R2 keys, least recently verified first. Document and mail kinds: `null` (their 9010/9011 contracts) |
| `bnx.wrk_render_done` (9018) | `REPORT_RENDER` promoter: field allowlist; payload bound to the leased snapshot (`ITEM_MISMATCH`); projection digest and both revisions recomputed (`PROJECTION_DIGEST`, `REVISION`); artifact reference **derived** (`r2:bnx-artifacts/rpt/<snapshot>/<sha256>.html`, never sent); then `wrk_snapshot_artifact` (9013). `wrk_promote_staged` MODIFY dispatches it for `render_done` of a `REPORT_RENDER` lease only; `INDEX_RENDER`/`T1_RENDER` stay `AWAITING_PROMOTER` |
| `gateway.py` | `GatewayClient` (`/exec/v1/lease`, `/exec/v1/complete`): retries network errors and 5xx/429 with back-off, never 4xx; a completion retried after a lost response that gets `409 LEASE_USED` counts as staged (the nonce is one-time and held only by this job). `MetadataTokenProvider` (Cloud Run metadata server, audience = `EXEC_AUDIENCE`), `StaticTokenProvider` (file, local runs). `StagerCompleter`: direct completion through `bnx.stg_<kind>` as `bnx_stager`. Payloads over 256 KiB are refused locally. The nonce never appears in a `repr`, a log line or a file |
| `runner.py` | One job kind over a list of items: lease → handler → staging-guard pre-check → completion; one failing item never stops the others. **SIGTERM/SIGINT**: no new item, the running child (`pg_dump`, `pg_restore`, `age`, `psql`) is terminated, the current item is abandoned **without a completion** (its lease expires; the next run retries it). JSON log lines on stderr with no nonce, token, DSN or content. Exit codes 0 / 2 config / 3 item not staged / 4 terminated |
| Staging-guard pre-check | The reference detector (`sin_detector.scan_json`, 9011) runs on every payload before the completion, so a payload the database guard would refuse (`SIN_CANDIDATE`) is never sent and the nonce is not spent |
| `render.py` (`REPORT_RENDER`) | R-BAL as one self-contained HTML document; renders only rows whose SHA-256 equals `projection_sha256`; a pure function of the work order (no clock, host or random value), so a re-render is byte-identical and lands on the same content-addressed object. Coverage (row count, statuses) and warnings (`STATUS_<s>` for rows not `ok`) |
| `jobs.backup` (UA §9.3 steps 1–8) | Runs only when the order says `due`. Checks that its configured Owner and drill recipients have the registry's fingerprints; as `bnx_backup`: `REPEATABLE READ READ ONLY`, `pg_export_snapshot()`, `bkp_header_facts()` and the server version in that transaction; the lowest installed `pg_dump` major ≥ the server's (none → `FAILED TOOL_MAJOR`); one `pg_dump --snapshot` with the generated arguments (every registered schema, custom, data only, single job); `pg_restore --list`; the transaction ends after the dump. `backup_header.json` (format, run, release, instance, config, tools, dump SHA-256, recipient ids and fingerprints, header facts); deterministic tar of header + dump; `age` to both K2 recipients; upload to the derived object name; re-download; decrypt with the **drill identity**; members, digests and `pg_restore --list` re-checked. Result per the 9016 contract (KiB sizes, `_sha256` keys, derived name); any failure is staged as `FAILED` with a reason (driver/I-O errors: the exception type only) |
| `jobs.restore_drill` (§9.3 step 9) | Checks that the drill identity's recipient has the run's drill fingerprint (`DRILL_KEY_NOT_RECIPIENT` otherwise — the drill job never opens an Owner-only path, AT-BKP-20); downloads, checks the generation, decrypts, checks plaintext/dump/header digests; provisions an isolated target (`LocalProvisioner`: database, B001/B002(/B003), runner `--upto` the recorded head), requires the target's migrations (versions and SHA-256) to equal the recorded ones; loads through the target's generated preamble (`restore.py`: audit chain in seq order, never-load tables skipped, `auth` by `bnx_auth`, the rest by `bnx_migrator` with restore mode); post-checks (`audit_verify() = 0`, every journal re-asserted, header facts recomputed by `bnx_backup`); drops the target and reports `cleanup_verified`. The database decides PASS (9016 promoter) |
| `jobs.evidence_verify` | Re-hashes the R2 copy of each object in the order; staged as `backup_recorded` of an `EVIDENCE_VERIFY` lease (9016 `wrk_evidence_state`: MATCH / MISMATCH with Owner alert / NO_REFERENCE) |
| `store.py` | `LocalStore`: write-once objects in a directory tree with a sidecar (generation, size, SHA-256, MD5); an existing name with the same content is an idempotent write, different content is refused |
| `agecli.py`, `pgtools.py`, `hashing.py` | `age` binary wrapper (public recipients only on the command line; stderr never propagated); fingerprint = SHA-256 of the recipient string (the registry value); tool discovery per major (`BNX_PG_BINDIR_<n>`); streaming SHA-256/MD5; KiB rounding |
| Gateway (`index.js`, `exec_schemas.js`) | `/exec/v1/complete` validates the payload against the JSON Schema of its (job kind, staging kind) before the database (render_done, BACKUP and EVIDENCE_VERIFY backup_recorded, restore_drill_recorded); other pairs keep their database contracts. **`GET /api/v1/artifacts/{snapshot_id}`** (closes the proxy part of L-9013-2 and L-CORE7-7): `q_snapshot_artifact` decides with the caller's current grant; revoked → `403 ACCESS_REVOKED` with only the status header; the bytes come from the `ARTIFACTS` R2 binding and are served only if their SHA-256 equals the recorded digest (`502 ARTIFACT_INTEGRITY` otherwise); headers `X-BNX-Snapshot-Status`, `X-BNX-Artifact-SHA256`, a `default-src 'none'` CSP, `no-store`. `release.js` 0.3.0-core8, extension range 9017…9018 (N-1…N) |
| Node adapter | `makeR2(dir)`: an R2 binding over the Executor's `LocalStore` tree (tests) |
| Dependencies | `requirements.txt`: psycopg 3.2.3, psycopg-binary 3.2.3 (CPython 3.12 and 3.13 wheels), typing_extensions 4.12.2, all with hashes; CI installs the `age` package |

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's delegation ("接手后一步做到底，需要owner决定的由你深思决定"; "继续完成到底", 2026-11-11). All reversible: nothing is deployed.

| ID | Decision | Reason |
|---|---|---|
| D-CORE8-1 | Add migration **9018** outside the V1.2 register (as 9017, D-CORE7-1) | UA §9.2 gives the render jobs no database credential, so their input must come with the lease; `render_done` had no promoter, so a rendered artifact could never be recorded. Both need database code |
| D-CORE8-2 | The work order is returned with the lease (one round trip), not by a separate input route | The lease is already the one-time, identity-pinned, 20-minute authorization of exactly one job on one item; binding the input to it adds no new trust path |
| D-CORE8-3 | The `BACKUP` order is advisory (`due` flag); the job stops (nothing staged) when not due. `RESTORE_DRILL` without `item_id` gets no order | The 9016 promoters stay the authority on every field; existing database tests stage synthetic results on such leases |
| D-CORE8-4 | Artifacts are content-addressed (`bnx-artifacts/rpt/<snapshot>/<sha256>.html`) and the reference is derived by the database | Keeps the 9016 result contract (no path in a staged payload, D-9016-5); a re-render is idempotent |
| D-CORE8-5 | The renderer is deterministic and verifies the projection digest itself | An artifact must show exactly the attested figures; byte-identical re-renders make tampering and drift visible |
| D-CORE8-6 | Archive = deterministic tar of `backup_header.json` + `data.dump`, encrypted once to both K2 recipients; `plaintext_sha256` = the tar, `header_sha256` = the header file, `dump_sha256` = the dump | One object per run (Backup §3); the header travels inside the encrypted archive, so header and dump cannot be separated |
| D-CORE8-7 | `wire_kib` = size of the plain-SQL rendering of the dump (`pg_restore -f -`) | The bytes `pg_dump` pulled from the server are not observable from the client; the SQL rendering is a close, reproducible upper estimate for the egress policy |
| D-CORE8-8 | `pg_dump` choice = the lowest installed major ≥ the server's (with its `pg_restore`) | §9.3 step 7; avoids a newer-than-needed tool when both are installed |
| D-CORE8-9 | A job never stages a half-done result: SIGTERM abandons the item; tool stderr and driver messages never enter a payload (step names or exception types only); restore load errors carry only the primary message | Payloads are durable database rows; stderr and DETAIL lines can quote row values or connection details |
| D-CORE8-10 | Drill targets are provisioned by a local provisioner on a server the drill identity administers | The Neon drill branch (M0-E) needs a Neon API key under security review (D-9016-7); the local provisioner has the same steps and is what the tests run |
| D-CORE8-11 | The Gateway's completion schemas are selected by the job kind the client names; the database still binds the lease's real kind (`LEASE_KIND_MISMATCH`) and its promoter re-validates | The job identity is pinned per job kind, so naming another kind needs another identity; shapes are a pre-filter, not the authority |

## Test results — `AUTHOR_RUNTIME_EVIDENCE`

- `tests/py/run_s4_core15.py` (7 tests): AT-EXEC-03 (work orders; no lease on a refused order), AT-RND-01 (render end to end,
  byte-identical re-render, promoter rejections), AT-BAK-01-EXEC (real `pg_dump`/`age`; not due before K2 keys or after a
  VERIFIED run the same local date; wrong drill recipient → FAILED), AT-BKP-DRILL-EXEC (drill PASS into an isolated database,
  cleanup verified, run restorable; Owner identity → FAIL; tampered object → FAIL), AT-EVV-01 (MATCH / MISMATCH + alert, missing
  copy logged and first in the next order), AT-EXEC-04 (SIGTERM abandon, guard pre-check, replay, no 4xx retry, nonce hidden, CLI
  config exit), AT-EXEC-02-STG (completion as `bnx_stager`). PG16: 7/7. PG17 locally: 6 PASS + AT-BKP-DRILL-EXEC SKIP and
  AT-BAK-01-EXEC on its FAILED `TOOL_MAJOR` branch, because `pg_dump` 17 is not installable here; CI runs both full paths on PG17.
- Black box `BB-EXEC-02`: the real Executor process over HTTP against the Worker (Node adapter): lease with work order, a wrong
  completion shape refused by the Gateway (422), render, completion, promotion by the scheduled dispatcher, artifact served by the
  proxy with status `CURRENT` and a matching digest, a tampered stored object → `502 ARTIFACT_INTEGRITY`, anonymous → 401.
  Unit `UT-EXEC-SCHEMA-01`. Black box + unit 21/21.
- Full regression on both majors (author, before the fix below): PG16 170 PASS / 1 FAIL, PG17 167 PASS / 1 FAIL / 3 SKIP
  (`pg_dump` 17 is CI-only). The one failure, AT-ISO-BF (core14), asserted the extension head literally as 9017; it now derives the
  head from `db/migrations` (5/5 on both majors after the fix). Black box + unit 21/21; dispatch simulation PASS.
- **CI finding**: the suite step piped every suite through `tee` without `pipefail`, so a failing suite did not fail the job (the
  first CI run of this PR showed AT-ISO-BF red inside a green job). The step now sets `pipefail`, runs every suite and fails if any
  failed. The earlier runs of #9 and `main` were re-checked from their logs: no hidden failure (0 FAIL lines).

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-CORE8-1 | 9018 and its four objects need register and disposition rows (as L-CORE7-1) | Next register revision |
| L-CORE8-2 | Cloud stores are not implemented: GCS vault (`bnx-<project_id>-vault`, retention lock only with O-8), R2 artifact/evidence bucket; `LocalStore` only | M0-A / M0-E with the authorized identities |
| L-CORE8-3 | No container image (`bnx-exec`, `bnx-backup`), no Cloud Run Job definitions, no launch of jobs by the Worker tick (the hourly `wrk_backup_due` → job launch) | M0-A |
| L-CORE8-4 | The drill target provisioner is local; the Neon drill branch and its API key are not implemented | M0-E; SECURITY_REVIEW of the Neon key (D-9016-7) |
| L-CORE8-5 | Document, import, index, mail and T1 jobs (`DOC_*`, `IMPORT_PARSE`, `INDEX_*`, `MAIL_*`, `T1_RENDER`) have no handler in the loop yet; the 9011 validator library exists. `INDEX_RENDER` / `T1_RENDER` have no promoter | WP-DOC (DOC-1/2), TAX-5 (Owner gate) |
| L-CORE8-6 | `EVIDENCE_VERIFY` cannot report a **missing** copy: the 9016 item contract has no such result, so the job logs it and the object comes first in the next order | Add a `MISSING` result to `wrk_evidence_state` |
| L-CORE8-7 | Usage rows (`cloud_usage`) are not reported by the jobs; billing-export reconciliation is M0-F | M0-F |
| L-CORE8-8 | `local_date`/`tier` come from the lease-time order; a run that crosses local midnight between lease and start is rejected by the promoter (`TIER_MISMATCH`) and retried | Acceptable (hourly C2 schedule) |
| L-CORE8-9 | Drive second copy (archive writer) is not part of this stage | DOC-1 / PV-DRV-01 (Drive identity review) |
