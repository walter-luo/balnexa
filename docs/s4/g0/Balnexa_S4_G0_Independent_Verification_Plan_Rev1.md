# Balnexa S4 — Independent G0 Verification Plan (Rev 1, main ee13eee)

2026-11-10 · Owner: Walter Luo · Status: accepted under the Owner delegation of 2026-11-10 (`docs/s4/OWNER_DECISIONS_2026-11-10.md`)

## Purpose, baseline and independence

In G0, an independent verifier reproduces the merged `main` baseline on PostgreSQL 16 and 17, and adds checks the author's suites never made. Nothing in this plan has been executed. Execution is authorized under the Owner delegation of 2026-11-10 and starts when the Owner hands `docs/s4/g0/G0_VERIFIER_BRIEF.md` to the verifier.

| Item | Value |
| --- | --- |
| Baseline | Commit `ee13eee451a4969eef58ae8cac24ca0c905d5059`, tree `96b13ff4670fecfcc0d9f7360c73f62aa4e1c932` |
| Scope | B001, B002; R1 migrations 0002–0109 (0108 amended); S4 migrations 9001–9010; `db/tools/run_migrations.py`; the Worker code exercised by the black-box and simulation tests |
| Reference checksums | 0108 amended `4615ba8de2bf8f8fc445cc57efe10c97d677b15788f75e94f356670d735c8b49`; R1-original 0108 `4fc92f2b9b3dda0a14b2863fa3c7e53c2723e8eaa3d295d4997a42da8bc8ce6f` (must be refused); 9010 `eecc2e0a19dbf112a68db65dc913af5258fa04180379fa735ae9f624ec575c7e` |
| Out of scope | Neon semantics (M0-C-06), Workers runtime, Cloud Run, Drive, Gateway CIMD fetch, 9011 and later, performance, real data |

**Independence (decision D1, 2026-11-10).** The verifier is OpenAI Codex or a qualified human reviewer who did not take part in the Claude implementation. Model-vendor separation alone is not enough. Independence requires all four of the following:

1. **Environment:** a fresh clone, on infrastructure the author has never accessed, built from this plan.
2. **Expected results:** taken from the V1.2 design, the Owner decisions and this plan, and written down before execution. Never taken from the author's `EVIDENCE/` or CI logs.
3. **Execution:** run by the verifier only. The author does not touch the environment and answers questions only in writing. Every answer and every deviation goes into the report.
4. **Evidence review:** the verifier records each verdict before comparing it with the author's evidence. A GitHub Actions re-run is supporting evidence only.

If Codex is the verifier, a person must check that the four conditions held: the run log, the expected-results file with its timestamp before execution, and the evidence hashes.

| Evidence grade | Meaning |
| --- | --- |
| `AUTHOR_RUNTIME_EVIDENCE` | Run by the author, locally or in CI. Everything that exists today has this grade |
| `VERIFIED_INDEPENDENT` | Reproduced, or newly run, by the verifier under the four conditions |
| `DEFERRED_BACKUP_GAP` | Known incomplete backup coverage, deferred to 9016 (decision D2). Never reported as PASS |
| `NOT_IMPLEMENTED` | A test registered in the design but absent from the baseline. Never reported as PASS |
| `NOT_VERIFIED` | Depends on M0, Neon, cloud or later work packages |

**Safety:** synthetic data only, on a disposable local cluster with no TCP listener. `tests/py/harness.py` drops every `bnx_*` database and role in the target cluster.

**Changes from the first plan:** G0-01 (installer sequence), G0-02 (V3.12 split), G0-03 (V9.2 split plus a 9016 test specification), G0-04 (AT-BAK-03 is `NOT_IMPLEMENTED`), D1–D4 recorded. One more correction came out of checking the evidence: V4.3. The author's AT-MIG-11b test re-granted the installer's SET membership as the superuser (`granted by` the installer), not as the installer itself.

## Environment and run modes

G0 runs on one Linux machine with two local clusters, PostgreSQL 16 and 17, each with the client tools of the same major. There are two run modes:

- **M1** reproduces the author's harness. Most of its suites bootstrap as the superuser; only AT-MIG-11b uses a non-superuser installer.
- **M2** is the production path. It uses a non-superuser installer and no harness, and serves V3 to V5.

| Component | Requirement | Record in `environment.txt` |
| --- | --- | --- |
| OS | Ubuntu 24.04, or any Linux with PGDG packages | `uname -a`, distribution release |
| PostgreSQL | Latest PGDG 16.x and 17.x, including the contrib modules (the author's CI used 16.15 and 17.11) | `select version()` for each |
| Clusters | `initdb -E UTF8 --locale=C.UTF-8 --auth=trust`; Unix socket only (`listen_addresses=''`); sockets `/var/lib/postgresql/bnx16` and `bnx17`, ports 55416 and 55417 (constants in `tests/py/harness.py`) | `initdb` command line, `postgresql.conf` deltas |
| Python | 3.12 with `psycopg[binary]==3.2.3` | `python -VV`, `pip freeze` |
| Node | 22.x; `npm ci` in `apps/worker` with the committed lockfile | `node -v`, lockfile SHA-256 |
| Client tools | `pg_dump` and `pg_restore` of the server's major | `--version` for each major |

### M2 installer sequence (G0-01)

The non-superuser installer is created **before** B001. The same installer identity runs B001 and B002. Migrations then run as `bnx_migrator`. The superuser is used only in step S0 and in the tamper checks that say so (V4.3b, V8.5, V8.6).

**Prerequisites:**

- The cluster holds **no** `bnx_*` role. Roles are cluster-wide. B001 skips roles that already exist, and an installer that did not create a role does not hold ADMIN on it.
- `pgcrypto` and `btree_gist` are installed and trusted (`pg_available_extension_versions.trusted = true`). B001 creates them as the database owner.
- The installer is `LOGIN CREATEROLE NOSUPERUSER NOCREATEDB NOREPLICATION NOBYPASSRLS`. It owns the target database.
- Every installer session runs with `PGOPTIONS='-c createrole_self_grant=set,inherit'`, the documented procedure (B002 header; F-C1-01 option a).

| Step | Identity | Action | Check |
| --- | --- | --- | --- |
| S0 | superuser | `initdb`; `create role bnx_installer login createrole`; `create database bnx_g0 owner bnx_installer` | `\du bnx_installer` shows only LOGIN and CREATEROLE |
| S0n | `bnx_installer` | Negative check: run B001 with no `PGOPTIONS`, then with `createrole_self_grant=set` only; drop and recreate the database after each | B001 fails both times (AT-MIG-11b) |
| S1 | `bnx_installer` | `psql -X -v ON_ERROR_STOP=1 -1 -f db/bootstrap/B001_bootstrap.sql` with the documented `PGOPTIONS` | Exit 0; roles and extensions exist; `schema_bootstrap` has B001 |
| S2 | `bnx_installer` | Same command for `db/bootstrap/B002_bootstrap_s4.sql` | Exit 0; four S4 schemas owned by `bnx_definer`; `schema_bootstrap` has B002 |
| S3 | `bnx_installer` | Read its own rows in `pg_auth_members` | Every membership has `admin_option = true`, `inherit_option = false` and `set_option = false` (V4.2) |
| S4 | — | Authentication for `bnx_migrator` and the runtime roles: trust on the Unix socket in the test cluster. Anywhere else the installer sets passwords out of band (B001 header) | Recorded in `environment.txt` |
| S5 | `bnx_migrator` | `python db/tools/run_migrations.py --dsn "host=<socket> port=<port> user=bnx_migrator dbname=bnx_g0" --log m2.log` | Exit 0; `privilege_violations=0` |

### Procedure

1. Fresh clone. `git rev-parse HEAD` and `git rev-parse HEAD^{tree}` must equal the baseline.
2. Compute SHA-256 of every file in `db/bootstrap/` and `db/migrations/` into `checksums.txt`.
3. Write `expected_results.md` (every check ID with its pass criterion from this plan) and hash it **before** step 4.
4. M1: run the commands of the `.github/workflows/ci.yml` steps "R1 suite and S4 suites", "Black-box API" and "Dispatch simulation" once per major.
5. M2: run S0–S5 per major, then V3 to V5.
6. Repeat the audit checks (V8) under session `TimeZone` UTC, America/Toronto and Asia/Shanghai.
7. Run everything twice per major, starting from `initdb` each time. Differing verdicts are a finding (flakiness), not grounds for a retry.

Every command goes into one timestamped log. The report lists the SHA-256 of every evidence file.

## Verification areas V1–V5

Every check runs on PostgreSQL 16 **and** 17. In G0 a SKIP counts as a failure. Check types:

- **R** — reproduces an existing author test.
- **N** — a new check with no author evidence.
- **R+N** — reproduces an existing test and extends it.

### V1 — Baseline and repository integrity

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V1.1 | N | Commit and tree hash | Equal to the baseline |
| V1.2 | N | SHA-256 of 0108 and 9010 | Equal to the reference checksums |
| V1.3 | N | `git diff d0d1365..ee13eee` over the R1 migrations and B001 | Only 0108 differs from the R1 import |
| V1.4 | R | No `owner_sources` path in the history; gitleaks v8.21.2 with `.gitleaks.toml` | No hit. The verifier reviews the two listed false positives |

### V2 — Suite reproduction (M1)

| ID | Type | Suite | Pass criterion, each major |
| --- | --- | --- | --- |
| V2.1 | R | `tests/py/run_g0.py` (R1 suite) | 40 PASS / 0 FAIL / 0 SKIP |
| V2.2 | R | `run_s4_core1.py` | 12 / 0 / 0 |
| V2.3 | R | `run_s4_core2.py` | 12 / 0 / 0 |
| V2.4 | R | `run_s4_core3.py` | 9 / 0 / 0 |
| V2.5 | R | `run_s4_core4.py` | 11 / 0 / 0 |
| V2.6 | R | `tests/blackbox/api.test.mjs` | 8 / 8 |
| V2.7 | R+N | `tests/sim/dispatch_sim.mjs` (CI runs it on PG16 only) | Exit 0 on both majors |

### V3 — Migration integrity (M2)

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V3.1 | N | S0–S5 on an empty cluster | `schema_migrations` holds 0002–0109 and 9001–9010, each with the SHA-256 in `checksums.txt`; zero privilege violations |
| V3.2 | R | Run the runner again | Nothing applied; exit 0 |
| V3.3 | R | Change one byte of an applied file | Exit 5; nothing applied |
| V3.4 | R | Remove an applied file | Exit 4 |
| V3.5 | R | Add Draft-04 `0001` or `0007` | Exit 2 |
| V3.6 | R | Connect as a superuser, then as an inheriting role | Exit 3 each time |
| V3.7 | R | 9002+ pending without B002 | Exit 6 `BOOTSTRAP_MISSING`; nothing applied |
| V3.8 | R | `--inject-failure 9010` | Exit 6; no 9010 row or object; earlier migrations intact |
| V3.9 | R | 9001 pending after 9002+ applied | Exit 4 `CONVERSION_AFTER_EXTENSION` |
| V3.10 | R | A database built with the R1-original 0108 (`db/history/r1/`) | Exit 5; database unchanged (AT-MIG-11c) |
| V3.11 | N | R1 baseline with amended 0108 and synthetic data, upgraded to 9010 | Row counts and balances preserved; module flags fail closed until activation (AT-FLG-10); R1 accounts in region UNKNOWN (F-C2-04) |
| V3.12a | N | **Observation only.** The non-superuser installer follows the UA §6.2 order: B001 → 0002–0109 → 9001 → B002 | The verifier records the actual exit code, the failing migration and the last applied version. The author's notes (F-C1-17) expect exit 7 at 0108, with the database stopping at 0107. That expectation is not assumed: any fail-closed outcome with nothing partially applied is acceptable. A partial apply is a finding |
| V3.12b | N | **Recovery**, from the V3.12a end state: run B002, then the runner | Clean install to 9010 with zero violations, **without editing migration history**. Rows recorded before recovery are unchanged (version, SHA-256, `applied_at`); only new rows are appended. No manual `schema_migrations` change is made or needed |

### V4 — Installer and role model (M2)

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V4.1 | N | Attributes of every `bnx_*` role | Match B001, B002 and the design. No role is SUPERUSER, CREATEDB, CREATEROLE, REPLICATION or BYPASSRLS. `bnx_stager` and `bnx_fed_reader` are NOLOGIN. Connection limits and timeouts are as in B001. `bnx_backup` defaults to read-only |
| V4.2 | R | Installer memberships after B002 (S3) | ADMIN only, no SET, no INHERIT |
| V4.3a | N | **Corrected.** The installer itself runs `grant bnx_definer to bnx_installer with inherit false, set true` | The outcome is recorded either way. The review claimed this succeeds; the author never tested it as the installer |
| V4.3b | R | The superuser adds the same membership `granted by bnx_installer` (as AT-MIG-11b did) | `audit_privileges()` reports `INSTALLER_MEMBERSHIP`, and the runner exits 7 |
| V4.4 | R | B002 re-run by the installer | "B002 already applied: no change" |
| V4.5 | N | `bnx_migrator` without `SET ROLE` | Cannot read or write any `bnx` table |
| V4.6 | N | Each runtime role attempts `SET ROLE bnx_definer` | Refused |

### V5 — Privilege boundaries

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V5.1 | N | The verifier's own catalog queries, written without reading `audit_privileges()` | Runtime roles hold no table, sequence or column privilege. EXECUTE goes only by prefix: `cmd_`/`q_` → app, `wrk_` → worker, `authn_` → authn, `stg_` → stager, `fed_` → fed\_reader; `install_*` and `pol_*` to nobody. No PUBLIC EXECUTE. Every SECURITY DEFINER function is owned by `bnx_definer` with a pinned `search_path`. No `bnx`-owned object in `public` |
| V5.2 | N | V5.1 compared with `audit_privileges()` | Both report zero violations |
| V5.3 | R+N | Mutations: table grant to `bnx_app`, column grant, PUBLIC EXECUTE, object in `public`, write on any table for `bnx_backup`, an unregistered schema | Each is reported under its rule, and the runner exits 7 |
| V5.4 | R | `bnx_stager` calls `wrk_` or `cmd_`; a staging row reaches posting | Refused; nothing posts (AT-EXEC-02) |
| V5.5 | R | An unlisted function through `require()`; tier ≥ 2 on MCP | Fails closed |
| V5.6 | N | `bnx_backup` reads every table in every schema and writes none | Reads succeed; every write and DDL is denied |

## Verification areas V6–V9

### V6 — Approval controls

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V6.1 | R | Plan kinds and channels (AT-PLAN-04) | Every kind passes the same gates; `manual` refused; an AI connection drafts but never approves |
| V6.2 | R | Holds and the V-10 re-run (AT-PLAN-05, 05b) | Each hold blocks approval; a module flag switched off after the freeze blocks approval |
| V6.3 | R+N | Approval digest (review finding 3): `plan_hash` or `scope_digest` missing, NULL, wrong, or from an older plan version | Refused in every variant |
| V6.4 | R | `plan_create` allowlist (findings 1, 2, 5) | Reserved types, extra keys, empty description, `clearing_open` outside a handoff plan, caller-supplied amounts and accounts outside the AI consent subset are all refused or rebuilt |
| V6.5 | R | `cmd_withdraw_plan` on `approved`; `cmd_validate_plan` | Withdrawal succeeds before activation |
| V6.6 | N | Forced interleavings in two sessions: approve/approve, approve/withdraw, approve/revise (verifier-side helper code, D4) | One outcome; no double posting; no unresolved deadlock; state consistent with the audit chain |

### V7 — Activation authorization (F-C4-21)

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V7.1 | R | `activation_cases()` in AT-REV-01-07 (7 cases) | All pass |
| V7.2 | N | `can_post` revoked on a non-plan line account after some chunks are posted, before activation | Plan `suspended`, batch void, no journal visible through any `q_` function or `bnx_rpt` view |
| V7.3 | N | Approver's membership removed; approver's role downgraded | Same as V7.2 |
| V7.4 | N | Revocation committed while activation waits on `FOR SHARE` (D4 helper) | Activation never completes on a revoked grant |
| V7.5 | R | Chunk-stage check (9008) | A revocation between chunks suspends the plan |
| V7.6 | R | R1 plan-account branch | Keeps `revalidation_required` |

### V8 — Audit integrity

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V8.1 | N | `audit_verify()` after V2–V7 | Zero breaks |
| V8.2 | N | Same under TimeZone UTC, America/Toronto, Asia/Shanghai (F-C2-01) | Identical result and `audit_head()` |
| V8.3 | R | v1/v2 boundary | v1 events verify byte for byte |
| V8.4 | R+N | UPDATE, DELETE, TRUNCATE on the audit table | Refused for every runtime role and `bnx_backup`. For `bnx_definer` (the owner, via the migrator) the result is recorded, and a successful TRUNCATE or trigger disable is a finding |
| V8.5 | N | Superuser tamper: change a field, forge a v2 row, swap two rows | `audit_verify()` reports the first broken sequence |
| V8.6 | N | Superuser deletes the last N rows | Expected to go **undetected** without the external anchor that 9016 adds. Recorded as a known residual, not a PASS |
| V8.7 | R | Envelope values over 100 characters or non-printable, through each role's GUC path | Refused or neutralised (AT-CMD-06x) |

### V9 — Backup and restore

The overall result for full-system backup coverage is `DEFERRED_BACKUP_GAP` (decision D2). It is **never** reported as PASS. Checks V9.1, V9.4, V9.5 and V9.6 verify only the scope they name.

| ID | Type | Check | Pass criterion |
| --- | --- | --- | --- |
| V9.1 | R | AT-BAK-01 and AT-BAK-02 (`tests/py/run_g0.py`) with same-major tools | Pass on both majors, no SKIP. **Scope: schemas `bnx` and `auth` only** (`--schema=bnx --schema=auth`) |
| V9.2 | — | **AT-BAK-03 inventory (G0-04).** "`bnx_app` with GUC `bnx.restore_mode=on` still refused" is registered as OBJ-334 in the disposition fixture: target 9016, status `NOT_IMPLEMENTED`. The only code reference is a comment at `tests/py/run_s4_core2.py:376`, inside AT-FLG-01-09. The code there exercises only the installer-side bypass, not the `bnx_app` refusal | Reported as `NOT_IMPLEMENTED`; not counted |
| V9.2n | N | The verifier's own probe: `bnx_app` sets `bnx.restore_mode = 'on'` and then calls `cmd_` functions whose enforcement gates restore mode would bypass for the installer (for example a post on a disabled region). Direct table writes don't count: they fail on privileges alone | The gate still applies (for example \`SCOPE\_DISABLED\`). This grades the probe `VERIFIED_INDEPENDENT`; AT-BAK-03 itself stays `NOT_IMPLEMENTED` |
| V9.3a | N | **Reproduce the coverage gap (G0-03 part 1).** Fill every table in the four S4 schemas with synthetic rows (today only the 15 `bnx_intake` tables exist). Run the AT-BAK-01 command and restore into an isolated database | The gap is reproduced and documented: per table, source vs. restored row counts; `bnx_intake` rows absent. Result `DEFERRED_BACKUP_GAP` |
| V9.3b | — | **Future complete backup/restore test (G0-03 part 2).** Specified in the next section | Not executed in G0; acceptance test for 9016 |
| V9.4 | R+N | Restore preconditions, scope `bnx`+`auth`: restore mode only for the installer identity; `audit_verify()` passes on the restored database; balances and versioned queries equal | As stated |
| V9.5 | N | Snapshot consistency, scope `bnx`+`auth`: dump with `pg_export_snapshot()` while plans are posted | No half-activated batch; the audit chain verifies |
| V9.6 | N | Cross-major: dump on PG16, restore into PG17, scope `bnx`+`auth` | Equal counts and hashes; `audit_verify()` passes |
| V9.7 | N | `pg_dump` 16 against a PG17 server | Refused |
| V9.8 | — | Encryption (age), key custody K2, retention, offsite copy, drill keyring | `NOT_VERIFIED` (CORE-8/9016, gate O-8) |

## V9.3b — Complete backup/restore acceptance test for 9016 (specification, not executed)

This test closes `DEFERRED_BACKUP_GAP`. Under decision D2, real-data ingestion and production deployment stay blocked until it passes on both majors. Proposed ID: AT-BAK-FULL. AT-BAK-03 is implemented in the same work package.

**Inventory from the catalog, not from a list.** Before every run, the test enumerates every relation and sequence owned by `bnx_definer` or `bnx_auth` in `bnx`, `auth`, `bnx_rpt`, `bnx_doc`, `bnx_intake`, `bnx_tax` and `bnx_fed`, plus `schema_migrations` and `schema_bootstrap`. A 9016 policy table gives each one exactly one class. If any relation has no class, the test fails, so a new table can never drop out of the backup unnoticed.

| Class | Meaning | Example (to be fixed in 9016 and reviewed by the Owner) |
| --- | --- | --- |
| `RESTORE` | Data restored exactly | Ledger, journals, audit, plans, accounts, registry, intake items, mail routes, notifications |
| `RESET` | Operational state deliberately not carried over; the post-restore behaviour is documented | Lease nonces (all invalid after restore), possibly OAuth access tokens |
| `DERIVED` | Rebuilt from restored data by a documented step | Report tables or caches, if any |

**Procedure:** a production-path backup as `bnx_backup` under an exported snapshot, encrypted per K2 with the drill keyring, never the Owner key. Then the documented restore into an isolated database: fresh B001 and B002, migrations to the same version, data load in installer-only restore mode. The source database is populated beforehand with synthetic rows in every table, and with plans in every state (draft, held, approved, active with chunks posted, suspended).

| # | Pass criterion |
| --- | --- |
| 1 | Every `RESTORE` relation: identical row count and identical hash over its rows in primary-key order |
| 2 | Sequences and identity columns: each next value is greater than every existing key |
| 3 | Dependencies: every foreign key, CHECK and deferred constraint (including the B6.1 economic-type check) is validated after load. Nothing is left `NOT VALID` or disabled; every trigger is enabled |
| 4 | Audit: `audit_verify()` passes; `audit_head()` equals the source head at the snapshot **and** the head recorded in the backup header. A truncated tail is therefore detected (it closes residual V8.6) |
| 5 | Operational state: every `RESET` relation behaves as documented. No half-activated batch. Cursors resume without re-consuming or skipping records |
| 6 | Configuration: the active config version, module flags, `schema_migrations` and `schema_bootstrap` are equal; `audit_privileges()` reports zero violations |
| 7 | Equivalence: balances, versioned queries and snapshot replays are equal for the same synthetic sessions |
| 8 | Negatives: a restore by a non-installer identity is refused; AT-BAK-03 (`bnx_app` with `restore_mode`) is refused |
| 9 | Runs on PG16 and PG17, plus cross-major 16 → 17 |

## Existing evidence vs. independent reproduction

All existing evidence is `AUTHOR_RUNTIME_EVIDENCE`. The same-family review of 2026-11-07 is also author-side.

| Area | Existing `AUTHOR_RUNTIME_EVIDENCE` | Reproduce independently | New checks | Not countable |
| --- | --- | --- | --- | --- |
| V1 | CI secret-scan on `ee13eee`; CORE-1 notes §1.1; the author's post-merge diff | V1.4 | V1.1–V1.3 | — |
| V2 | CI run 42426384390: 40/12/12/9/11 and black-box 8/8 on both majors | V2.1–V2.6 | V2.7 on PG17 | — |
| V3 | AT-MIG-01–11c, AT-FLG-10, AT-REG-17 | V3.2–V3.10 | V3.1, V3.11, V3.12a, V3.12b | — |
| V4 | AT-MIG-11, 11b | V4.2, V4.3b, V4.4 | V4.1, V4.3a, V4.5, V4.6 | — |
| V5 | AT-MIG-09, AT-INV-01, AT-EXEC-02 | V5.3–V5.5 | V5.1, V5.2, V5.6 | — |
| V6 | AT-PLAN-04, 05, 05b, AT-REV-01-07; AT-CONC-01–03 (R1) | V6.1–V6.5 | V6.3 extensions, V6.6 | — |
| V7 | `activation_cases()` | V7.1, V7.5, V7.6 | V7.2–V7.4 | — |
| V8 | AT-CMD-06, 06x; the 9005 checks | V8.3, V8.4 (runtime roles), V8.7 | V8.1, V8.2, V8.5 | V8.6 (known residual) |
| V9 | AT-BAK-01, 02 (scope `bnx`+`auth`) | V9.1, V9.4 (installer part) | V9.2n, V9.3a, V9.4 (`bnx_app` part), V9.5–V9.7 | AT-BAK-03 `NOT_IMPLEMENTED`; full coverage `DEFERRED_BACKUP_GAP`; V9.8 `NOT_VERIFIED` |

When a reproduced check passes, that one claim becomes `VERIFIED_INDEPENDENT`. A new check that passes adds a claim. Nothing in the "Not countable" column can be reported as PASS.

## D3 — CI evidence inventory and proposed destination

The two evidence artifacts of run 42426384390 expire on **2026-12-07 at about 23:43 UTC** (18:43 Toronto time). These are the timestamps the GitHub API reported on 2026-11-10. Claude read the metadata through the GitHub API on 2026-11-10.

**Run:** [42426384390](https://github.com/walter-luo/balnexa/actions/runs/42426384390), push to `main`, head `ee13eee451a4969eef58ae8cac24ca0c905d5059`, attempt 1. Created 2026-11-07 23:41:27Z, completed 23:43:36Z, conclusion success.

| Item | GitHub id | Size (bytes) | Digest (GitHub) | Created (UTC) | Expires (UTC) |
| --- | --- | --- | --- | --- | --- |
| Artifact `evidence-pg16` | 13596110119 | 346,735 | `sha256:c9b985c7e86f757a8e2d56f635cfbff58d867121c446dc930e22c49bc1f9dbb1` | 2026-11-07 23:43:33 | 2026-12-07 23:43:33 |
| Artifact `evidence-pg17` | 13595238111 | 346,445 | `sha256:c4c03e50625dd2650338e848b283de95a1cc1d89fbac07e48e64cadefc0fe74c` | 2026-11-07 23:43:00 | 2026-12-07 23:42:59 |
| Job log `db-tests (16)` | 128565502196 | — | — | 2026-11-07 23:41:45 | Repository log retention; see below |
| Job log `db-tests (17)` | 128565502385 | — | — | 2026-11-07 23:41:45 | Same |
| Job log `secret-scan` | 128565502402 | — | — | 2026-11-07 23:41:45 | Same |

**Log retention: not confirmed.** The proxy refused the repository's retention-settings endpoint. GitHub's default for logs is 90 days, but I could not confirm the setting for this repository. Archive the logs together with the artifacts.

**Expected artifact contents.** These come from `ci.yml` and are to be confirmed at download:

- `ci-evidence/run_g0.txt` and `ci-evidence/run_s4_core1.txt` to `ci-evidence/run_s4_core4.txt`, which hold the suite summaries;
- the per-suite evidence directories (JSON, logs, SQL);
- dump files (`*.dump`) are **excluded** by the workflow.

**Archive package** (D3, completed under the delegation as far as Claude's environment allows): the three job logs were downloaded by Claude on 2026-11-10 and archived with a SHA-256 manifest (`Balnexa_CI_run-42426384390_logs_2026-11-10.zip`, delivered to the Owner; not committed). The two artifact zips could not be downloaded from Claude's environment (the artifact storage host refused the request) and must be downloaded by the Owner from the run page before expiry. Steps for the complete package:

1. Download both artifacts and the three job logs.
2. Verify each artifact zip against the GitHub digest above.
3. Write a `MANIFEST.sha256` covering every file inside, plus `run.json` (run and job metadata as listed here).
4. Store the package unchanged, never overwriting an existing copy.

**Proposed destination:** your Google Drive, in the Balnexa project area, under `Evidence/CI/run-42426384390/`. Drive is your authoritative store, and the package stays outside the public repository. The exact folder is your choice.

## Known items G0 will record

| Item | Expected G0 record | Fix owner |
| --- | --- | --- |
| Backup covers `bnx`+`auth` only (V9.3a) | `DEFERRED_BACKUP_GAP` | 9016 (V9.3b) |
| AT-BAK-03 absent (V9.2) | `NOT_IMPLEMENTED` | 9016 |
| No external audit anchor (V8.6) | Truncation undetected; known residual | 9016 (V9.3b criterion 4) |
| UA §6.2 install order (V3.12a/b) | First observed outcome and recovery result | Documentation, or a runner change if recovery needs history edits |
| F-C1-01(a) installer SET re-grant (V4.3a/b) | First test by the installer itself; audit detection reproduced | Accepted 2026-11-05 |
| S4B-F13, Gateway CIMD fetch, DOC-SIN-10 | Not tested | Later work packages |

## Deliverables and exit criteria

Deliverables:

1. A G0 report giving each check ID a verdict per major. Allowed verdicts: PASS, FAIL, `DEFERRED_BACKUP_GAP`, `NOT_IMPLEMENTED`, `NOT_VERIFIED`. The verifier signs it.
2. `environment.txt`, `checksums.txt`, `expected_results.md` (hashed before execution), the raw logs and evidence, and the SHA-256 of every evidence file.
3. A deviation and question log, including the author's written answers.
4. Findings graded P0–P3, each with reproduction steps on synthetic data.

G0 exits when all of the following hold:

- every reproduction check passes on both majors with no SKIP, with identical verdicts across the two runs;
- every new check passes or has an Owner-decided finding;
- no P0 or P1 finding is open;
- the non-countable items are reported exactly as classified.

Passing G0 does **not** open real data. Gate O-8, the security review (ODQ-22) and V9.3b remain.

## Owner decisions recorded (2026-11-10)

| ID | Decision |
| --- | --- |
| D1 | Approved: Codex or a qualified human who did not take part in the Claude implementation; environment, expected results, execution and evidence review independent of the author; vendor separation alone is insufficient |
| D2 | Approved with conditions: the `bnx_intake` gap is deferred to 9016 as `DEFERRED_BACKUP_GAP`; never PASS; no real data or production until V9.3b passes; the restore covers all schemas, tables, sequences, dependencies, audit records and operational state |
| D3 | Approved in principle: inventory and destination above; no transfer without separate authorization |
| D4 | Approved: test-only helper code in an isolated workspace once execution is authorized; never in the production repository, protected branches, original migrations or production environments |

## Sources

- Repository `walter-luo/balnexa` at `ee13eee`: `.github/workflows/ci.yml`, `db/tools/run_migrations.py`, `db/bootstrap/B001_bootstrap.sql`, `B002_bootstrap_s4.sql`, `tests/py/harness.py`, `run_g0.py`, `run_s4_core1.py` (AT-MIG-11b, `nonsuper_install`), `run_s4_core2.py` (line 376), `tests/fixtures/s4/Balnexa_S4_R1_Object_Disposition_V1.2.csv` (OBJ-334), `docs/s4/S4_CORE1_Implementation_Notes.md` (§1.2, F-C1-17).
- GitHub REST API, run 42426384390 with its artifacts and jobs, read 2026-11-10.
