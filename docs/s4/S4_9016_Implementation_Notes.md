# S4 9016 — Backup/DR registries, cloud usage and admission, restore preamble generator — Implementation notes

Status: implemented in `db/migrations/9016_s4_backup_registry_cloud_usage.sql`, branch `s4/9016` (stacked on `s4/9013`).
Evidence grade: `AUTHOR_RUNTIME_EVIDENCE` (author's local runs on PG16.15 and PG17.11; CI pending on the draft PR); not independently reviewed.

Authority: UA V1.2 §6.3 (row 9016), §9.2 (Executor trust: results arrive as staging rows), §9.3 (normative backup procedure, nine
steps), §9.4 (K2 key custody), §9.5 (cost governance "as V1.0"); Draft-04 Backup and Disaster Recovery R6.2-Draft-04 §3–§10 and §12;
Draft-04 Cloud Cost and Quota Model R6.2-Draft-04 §5–§7; disposition OBJ-030, OBJ-256, OBJ-257, OBJ-334, OBJ-344; S4b findings
S4B-F10, S4B-F11, S4B-F24; requirements recorded for 9016 by 9011R (R-09, R-10, R-11) and G0R (F-06, backup scope).
Sources: `Balnexa_S4_Unified_Architecture_V1.2.zip` (SHA-256 `0f4bc6b7…6c3f`, verified) and the Design Inputs B package, whose
`B/design_B_opus/Balnexa_Unified_Architecture_V1.0_R6.2_Draft04.md` has SHA-256 prefix `4ad49225` (the baseline named in
`docs/R1_Doc_Delta.md`). Both are Owner-private and are not committed.

Synthetic data only. No cloud resource, key, bucket or billing setting is created, configured or contacted. Fingerprints in tests are
SHA-256 values of synthetic strings.

## What was built

| Object | Content |
|---|---|
| `bnx.bkp_header_facts()` | The header facts of UA §9.3 step 3, read **inside the exported snapshot by `bnx_backup`**: `ledger_version`; audit head (seq, hash, chain version) from `bnx_audit.audit_event`; `schema_migrations` versions and SHA-256; ACTIVE config version and digest; `instance_identity`; trial balance per currency (line count, sum, debits); and, for every table of every registered schema (8, including `bnx_audit`), the row count and a SHA-256 over the canonical row text (rows sorted with collation "C"; time zone, date style, interval style, bytea output and float digits pinned by the function). No clock, server version or session setting enters the value, so the same function on the restored database must return the same JSON (AT-BAK-04). SECURITY INVOKER and STABLE: it runs with `bnx_backup`'s own read-only rights |
| `bnx.bkp_header_compare(a, b)` | The keys (and `tables.<name>` entries) whose values differ; `[]` = equal. Used by the drill promoter and by restore post-checks |
| `bnx.restore_preamble()` | **Generated** restore preamble (S4B-F10 b): dump scope (`pg_dump` arguments for every registered schema), the seeded tables to truncate (from `bnx.migration_seeded_table` where `truncate_on_restore`), tables never loaded (`schema_migrations`, `schema_bootstrap`), load identities (`auth` as `bnx_auth`; the rest as `bnx_migrator` under `SET ROLE bnx_definer` with `bnx.restore_mode = on`), ordered loads (`bnx_audit.audit_event` by seq, R-10), post-checks, and the SQL part. The SQL refuses a target that holds any non-seeded row (`RESTORE_TARGET_NOT_EMPTY`): a restore never overwrites a live database (Draft-04 INV-45) |
| `bnx.migration_seeded_table.truncate_on_restore` | New column (UA V1.2 §5.1), default true; `bnx.cost_policy` registered as seeded |
| `bnx.backup_key_registry`, `bnx.backup_key_event` | K2 custody, fingerprints only (SEC-K): `key_id`, role `OWNER`/`DRILL`, SHA-256 of the age recipient; events `ACTIVATED`, `RETIRED` (rotation retires the role's previous key in the same transaction), `COMPROMISED` (with the Owner's handling choice, Backup §10.4 option a `KEEP_FOR_DRILLS` / option b `OWNER_KEY_TEST_ONLY`), `PRUNED`. Anything resembling age secret-key material is refused everywhere |
| `bnx.backup_run` | One row per reported run (append-only): local date and tier, retain-until, policy, outcome `VERIFIED`/`FAILED`, derived object name, generation, digests, sizes, tool versions, K2 key ids, the full header facts and their SHA-256, the migrations digest, ledger version and the **audit anchor** (seq, hash) with `anchor_check` `MATCH`/`MISMATCH`/`EMPTY_CHAIN`. At most one VERIFIED point per local date (unique index) |
| `bnx.restore_drill`, `bnx.restore_authorization` | Drill and restore results with the **database's** outcome and reasons, the decrypting key, header mismatches, cleanup flag; Owner restore authorizations (target `PRODUCTION`/`NEW_PROJECT`, 24 h, single use) |
| `bnx.evidence_verification` | Re-hash results of `EVIDENCE_VERIFY` (copy `R2`/`DRIVE`, `MATCH`/`MISMATCH`/`NO_REFERENCE`) with the `bnx.evidence_status` value at the time (R-09) |
| `bnx.audit_verification` | Worker-tick and external-verifier results against the latest backup anchor (R-11, G0R F-06) |
| `bnx.cloud_usage` | Usage ledger (Cost §6.1): one row per execution and phase (`EXPECTED` < `ACTUAL` < `RECONCILED`; the highest counts), provider, project (`bnx-exec`, `bnx-vault`, `neon`, `r2`), instance-seconds, gross estimate, egress, CU-hours, storage, UTC billing month |
| `bnx.cost_policy` | Versioned caps and ceilings; v1 seeded with the Cost §5–§6 design defaults (SC-V1: exec USD 0.85, vault 0.15; internal ceiling 70 %; backup reserve USD 0.10; Neon 5 GiB egress with 60 % backup budget, 1 GiB storage pause at 80 %, 100 CU-h pause at 80 %; probe back-off 6 h) |
| `bnx.capacity_event`, `bnx.admission_decision` | Capacity states (`normal`, `throttled_internal`, `provider_capped`, `provider_error`; a month after a capped month starts in `probe_pending`) and every admission decision with its reason and priority |
| Promoters | `wrk_backup_recorded` (BACKUP results; routes EVIDENCE_VERIFY results to `wrk_evidence_state`), `wrk_restore_drill_recorded`; `wrk_promote_staged` MODIFY dispatches `backup_recorded` and `restore_drill_recorded` (rows staged earlier as `AWAITING_PROMOTER` are promoted on the next tick) |
| Worker functions | `wrk_backup_due` (hourly C2: due/not due with the reason, tier, retain-until, policy, K2 recipients, `pg_dump` arguments, result contract), `wrk_backup_key_pruned`, `wrk_audit_verified`, `wrk_cloud_usage_record`, `wrk_capacity_update`, `wrk_admission_decide` |
| Owner commands (T3, Owner only) | `cmd_backup_key_register`, `cmd_backup_key_mark_compromised`, `cmd_authorize_restore`, `cmd_set_cost_policy` |
| Queries (Owner and admin) | `q_backup_status` (policy, retained objects, runs with `restorable`, drills, keys with state and `prune_after`, evidence verification summary, latest audit verification, and the **O-8 anchor precondition**), `q_cost_status` (usage by project, ceilings, capacity, admissions) |
| `apply_grants` / `audit_privileges` MODIFY | `bnx_backup` may EXECUTE exactly the `bkp_*` functions that are SECURITY INVOKER and not VOLATILE; a `bkp_*` function that is SECURITY DEFINER or VOLATILE is never granted and is reported (`BACKUP_FUNCTION_UNSAFE`); any other EXECUTE by `bnx_backup` stays an `EXECUTE_GRANT` violation. The `audit_privileges` body is the 9011 body changed only where marked "9016" |

### Rules the promoters enforce

- **BACKUP** (UA §9.3 steps 7–8): field allowlist; no key material; local date and tier recomputed from `started_at` in the household
  time zone and compared; retain-until not shorter than the tier's (1 h tolerance); one VERIFIED point per local date; `pg_dump` major ≥
  server major and `pg_restore` of the same major as `pg_dump`; K2 recipients = the Owner key and the drill key that were ACTIVE at the
  start, fingerprints equal to the registry (an archive without a drill recipient is refused, S4B-F24); re-download hash equal,
  `pg_restore --list` OK, decrypted with the drill identity; header facts present. The anchor (header audit seq and hash) must be the live
  chain's row at that seq: otherwise the run is stored with `anchor_check = MISMATCH` and the Owner is alerted. A FAILED run is recorded
  with its reason and alerts the Owner; it is never VERIFIED (AT-NEON-04).
- **RESTORE_DRILL** (§9.3 step 9; Backup §7–§8): the stored outcome is the database's. PASS only if the job reports PASS, the restored
  header facts equal the backup's (`bkp_header_compare = []`), the decrypting key is a recipient of that run, a `DRILL` job used a `DRILL`
  key (the drill identity never opens an Owner-only path, AT-BKP-20), the key was not pruned and is not a compromised key routed to the
  Owner-key test, and the cleanup was verified. A production or new-project target needs an unused, unexpired Owner authorization of that
  run (AT-BKP-15); a passing authorized restore writes `release_install_event(kind = RESTORE)`.
- **Restorable** (Backup §6 step 8, §8) is derived, never stored: a VERIFIED run with a passing drill of itself or of a later run with the
  same migrations digest, and no failed drill on that migrations digest after the latest pass.
- **Retention** (Backup §3): local 1st of month → MONTHLY 366 d; local Sunday → WEEKLY 28 d; else DAILY 7 d; the longest wins; one object
  per run.
- **Policy** (Backup §5): from the latest measured wire size W against 60 % of the Neon monthly egress: P-A (30 W fits), P-B (5 W), P-C
  (3 W), else P-D. A change alerts the Owner.

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's delegation of 2026-11-11 ("接手后一步做到底，需要owner决定的由你深思决定"). Each is reversible: nothing is deployed and
no persistent instance exists.

| ID | Decision | Reason |
|---|---|---|
| D-9016-1 | Ship 9016 now, before 9014 (tax, Owner-gated) and 9015 (federation, deferred), with the register numbers unchanged | The handoff names 9016 as the last migration V1-CORE depends on. The runner's prefix rule means a database already at 9016 cannot later accept 9014/9015 (exit 4). No persistent instance exists, so the cost today is zero; the constraint is recorded as L-9016-8 |
| D-9016-2 | UA §6.3 names `wrk_backup_recorded` / `wrk_restore_drill_recorded`; UA §9.2 says results arrive through `stg_backup_recorded` / `stg_restore_drill_recorded` via the lease. Both hold: the `stg_*` functions (9010) stage, the `wrk_*` functions are their promoters, dispatched by `wrk_promote_staged` | Keeps the trust boundary of §9.2 (the Executor never holds a posting-capable credential) and the names of §6.3 and OBJ-257 |
| D-9016-3 | Header facts are a database function executed by `bnx_backup` itself, enabled by a narrow privilege rule (`bkp_*` + SECURITY INVOKER + not VOLATILE) | Step 3 requires the facts inside the backup's snapshot, and the restore post-check must recompute the same value. A client-side query would duplicate the definition; a SECURITY DEFINER function would give `bnx_backup` more than SELECT. The audit makes the rule machine-checked (AT-BKP-PRIV) |
| D-9016-4 | Header facts cover every registered schema (8, including `bnx_audit`) and every table except `schema_migrations` / `schema_bootstrap` (migrations are listed separately; bootstrap rows are recreated) | UA §9.3 step 4 dumps every S4 schema; G0R requires `bnx_audit` in the scope |
| D-9016-5 | **Result contract**: staged results carry sizes in KiB (`compressed_kib`, `wire_kib`; usage `egress_kib`, `storage_kib`), never a bare byte count; the object name is derived from `run_id` (`bnx-vault-backups/<UTC yyyy/mm>/<run_id>.age`) and never sent; hex values travel only under keys ending in `_sha256` (e.g. `drill_fingerprint_sha256`) | Found by the tests: the 9011 staging SIN guard (a deliberate Owner rule, 2026-11-07) refuses any Luhn-valid 9-digit run. Measured: a 9-digit byte count (every dump of 100 MB–1 GB) is refused about 1 in 10 times, a UUID-bearing path about 1 in 700, a 64-hex fingerprint under a non-exempt key about 1 in 25. The contract avoids every case without weakening the guard; 120 randomized results produce 0 hits (AT-BKP-REC) |
| D-9016-6 | K2 only (OBJ-344 design default): every VERIFIED run lists an Owner and a drill recipient; K1 (Owner key only) is not supported by this migration | OBJ-344 records K2 as the design default with conditional approval; supporting K1 would change the drill rules and is an Owner choice (SEC-K) |
| D-9016-7 | Neon branch restore points (the P-B…P-D daily tier) are not taken; `wrk_backup_due` reports `DAILY_TIER_NEON_BRANCH_UNAVAILABLE` | They need a Neon API key that Backup §5 marks SECURITY_REVIEW_REQUIRED and REQUIRES_M0_EVIDENCE; an honest gap is better than an unreviewed key. P-C "every second Sunday" uses ISO-week parity |
| D-9016-8 | Key registration, compromise handling, restore authorization and cost-policy changes are Owner-only T3 commands; admins may read the status queries; none of these functions is in the MCP catalog | Backup §10 and Cost §5 make these Owner decisions; the database refuses posting-class commands on an AI connection |
| D-9016-9 | Owner alerts use the existing notification kind `EXCEPTION` with `metadata.kind` (e.g. `AUDIT_ANCHOR_MISMATCH`, `RESTORE_DRILL_FAILED`, `BACKUP_POLICY_CHANGED`) | Avoids a constraint replacement on `bnx_intake.notification` for this increment |
| D-9016-10 | Billing month = UTC calendar month for all estimates | Neon resets on UTC months; Google budget periods follow Pacific time — the difference is an estimate error that M0-F measures (Cost §10) |
| D-9016-11 | A 100 % budget notice sets `provider_capped` but backups are still admitted within the reserve until a launch is refused; a refused launch or a killed task caps everything; after a month change (or after the 6 h back-off of a failed probe) only one-item probes are admitted | AT-SPEND-03, -05, -09; Cost §7 |
| D-9016-12 | The O-8 anchor precondition (R-11) is **reported** by `q_backup_status.real_data_anchor_precondition` (a VERIFIED backup with anchor MATCH and an external-verifier INTACT result for that anchor); gate O-8 itself is not changed or opened | The handoff forbids any change to O-8; R-11 asks only that the precondition exist and be checkable |
| D-9016-13 | Evidence that the Executor never hashed is reported `NO_REFERENCE`, not `MISMATCH` | A missing reference is not evidence of tampering |
| D-9016-14 | The `COPY` restore path (used when `pg_dump` of the server's major is missing) loads tables in FK topological order inside one transaction with restore mode on | Same snapshot and same preamble as the `pg_dump` path; lets the PG17 database logic be exercised where `pg_dump` 17 is unavailable |

## Test results — `AUTHOR_RUNTIME_EVIDENCE`

New suite `tests/py/run_s4_core13.py` (11 tests), on PG16.15 and PG17.11:

| Test | What it proves |
|---|---|
| AT-BAK-04 | Header facts read by `bnx_backup` in the exported snapshot; a posting committed during the dump changes the live facts but not the dump; restore through the generated preamble (all 8 schemas, seeded tables truncated, sequences set) recomputes facts equal to the header (`[]`), `audit_verify` 0, journals re-asserted, `q_balances` equal; PG16 also runs the real `pg_dump --snapshot` + `pg_restore` path; the preamble refuses a live database |
| AT-BAK-03 | `bnx.restore_mode = on` in a `bnx_app` session does not bypass the S4 flag trigger (`SCOPE_DISABLED`); restore mode is true only for the migrator with the GUC |
| AT-BKP-REC | K2 recipients required; Owner-only key registration; key material and bad fingerprints refused; 12 invalid results REJECTED; the result contract passes the SIN guard; a verified run is promoted with anchor MATCH; duplicate local date REJECTED; anchor MISMATCH stored and alerted; FAILED recorded, never VERIFIED |
| AT-BKP-DRILL | Restorable only after a passing drill; owner key in a drill job, non-recipient key, unverified cleanup and differing header facts FAIL although the job reported PASS; a later failure blocks restorability; production restore only with a single-use Owner authorization (writes `release_install_event RESTORE`) |
| AT-BKP-12-16 | 730 simulated daily runs: one point per local date; steady-state retained objects 21–22, average 21.7 (independently reproduces the Draft-04 simulation); DST weeks give one point per local date |
| AT-BKP-13 | Policy switches P-A → P-B → P-D from the measured wire size with Owner alerts; daily gap under P-B; weekly not in P-D; Neon egress at the 60 % budget stops the daily dump (AT-NEON-03) |
| AT-BKP-17-19 | 13 monthly runs over 4 quarterly drill-key rotations, all drilled with their own keys (keyring survival); premature prune refused, active key refused, prune after `prune_after` accepted and a drill with the pruned key FAILs; compromise options a/b |
| AT-ANCHOR-01 | Anchor in the backup header; worker tick MATCH; `tools/s4/audit_chain_verify.py --anchor` INTACT → O-8 precondition met; unknown anchor and a superuser rewrite of the anchored row → FAILED with alerts |
| AT-BKP-10 | EVIDENCE_VERIFY re-hash: MATCH, MISMATCH (alert), NO_REFERENCE; evidence status recorded; invalid items rejected without partial writes |
| AT-SPEND-ADM | Usage ledger, 70 % ceiling, backup reserve, vault ceiling, 50/80/100 % notices, refused launch, period-reset probe and back-off, Neon storage/CU pause of bulk onboarding, Owner-only cost-policy versions (SC-V2 needs the Owner as declarer) |
| AT-BKP-PRIV | `bnx_backup` executes exactly `bkp_header_compare`, `bkp_header_facts`; 0 violations; an unsafe `bkp_` function is not granted and is reported; USAGE revoked → `BACKUP_SCHEMA_USAGE`; runtime roles cannot read or write the registries; backup/cost functions outside the MCP catalog |

Regression changed: `run_s4_core1.py` AT-INV-01 declares the 35 objects that the disposition does not name yet (L-9016-1).
Full regression (R1 suite, every S4 suite, black-box API, dispatch simulation) on both majors: see the PR description for the run.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-9016-1 | The disposition names only `backup_run`, `backup_key_registry`, `restore_drill`, `cloud_usage` and the `wrk_`/`q_` functions of OBJ-030, OBJ-256 and OBJ-257; 35 further objects, the `bkp_` privilege rule (MODIFY of `apply_grants`/`audit_privileges` in 9016) and the result contract (D-9016-5) need OBJ rows | Register update with the next disposition revision |
| L-9016-2 | The Executor side is not built: the `bnx-backup` job (`pg_dump`, age encryption, upload with retention, re-download), the vault registry files, the `bnx-drill` job, the semi-annual Owner-key test (AT-BKP-20 is enforced only as the database rule that a drill job never uses the Owner key) | CORE-8 (Executor), M0-E |
| L-9016-3 | `pg_dump`/`pg_restore` 17 are not available in this container: the real `pg_dump` path of AT-BAK-04 ran on PG16 only; PG17 ran the COPY path. CI installs both majors and runs both paths | NEW-052 closes when CI is green on PG17 |
| L-9016-4 | `bkp_header_facts` aggregates each table's row text in memory | Fine within Neon Free (1 GB); a streaming digest is needed for larger instances |
| L-9016-5 | AT-NEON-01/02/05/06 and AT-SPEND-02/07/08 are Worker, Executor or M0 behaviour; only the database parts are implemented (admission refusals, meters, capacity states). AT-SPEND-06's IAM half is M0 | CORE-7/CORE-8, M0-F |
| L-9016-6 | Restore-as-new (new `instance_identity` with origin `restore_as_new`, fingerprints re-keyed, sessions invalidated) is only recognised as a drill kind | INS-3 |
| L-9016-7 | AT-BKP-11 (refuse a restore into a different migration version) surfaces as `HEADER_FACTS_DIFFER` at the drill, not as an up-front refusal | The Executor's restore step R3 checks the header's migrations before loading (CORE-8) |
| L-9016-8 | Numbering (D-9016-1): no persistent instance may be installed at 9016 before 9014 and 9015 exist; otherwise they must be renumbered after 9016 | Owner, before the first real install |
| L-9016-9 | "Alert after 2 failed days" (Draft-04 §H11) is a Worker rule; the database alerts on each FAILED run | CORE-8 |
| L-9016-10 | Cost figures remain Draft-04 estimates (rates, overhead, W ≈ 4 C) until M0-F measurements replace them through `cmd_set_cost_policy` | M0-F |

## Owner items

None blocks this increment. For information: real key generation and custody (SEC-K), Locked retention, the vault's separate Google
identity, the Neon API key review for branch restore points, and the spend-cap variant (SC-V1 vs SC-V2) remain Owner decisions before
production (Backup §13, Cost §5); this migration records them as data when they are made and never makes them itself.
