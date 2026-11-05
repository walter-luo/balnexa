# Balnexa S4 — Work Package CORE-1 — Implementation Notes V1.0

| Field | Value |
|---|---|
| Design baseline | `Balnexa_S4_Unified_Architecture_V1.2.zip`, SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f` |
| Process | S5 independent review **waived by the Owner** on 2026-11-05 (see `OWNER_WAIVER_S5_2026-11-05.md`); development started by the Owner's instruction |
| Code baseline | R1 commit `5e39b6a` (Balnexa R6.2-R1 one-pass G0 remediation, synthetic, local only); branch `s4/core-1` |
| Scope of this increment | `run_migrations.py` two lanes; bootstrap B002; migrations 9002, 9003, 9004; tests |
| Data | synthetic only; local disposable PostgreSQL clusters; no cloud resource, account, credential or real data touched |
| Evidence grade of every PASS | `AUTHOR_RUNTIME_EVIDENCE` (the author ran the tests). Nothing here is `VERIFIED_INDEPENDENT`. |

## 1. What was built

| Item | File | Design reference |
|---|---|---|
| Two-lane runner (core 0001–8999 prefix rule unchanged; extension 9000–9999 prefix rule per lane; B002 assertion before any 9002+ file) | `db/tools/run_migrations.py` (MODIFY) | UA §6.2; S4B-F01 |
| Bootstrap B002: schemas `bnx_doc`, `bnx_intake`, `bnx_tax`, `bnx_fed`; roles `bnx_fed_reader`, `bnx_stager` NOLOGIN; USAGE grants; backup default privileges; idempotent | `db/bootstrap/B002_bootstrap_s4.sql` (NEW) | IL §3; OBJ-002 |
| 9002: B002 assertion; `schema_registry`; `migration_seeded_table`; `rule_activation_version`; `apply_grants()` and `audit_privileges()` MODIFY for nine roles and seven schemas (rules ROLE_INVENTORY, INSTALLER_MEMBERSHIP, NEW_SCHEMA_UNREGISTERED, SCHEMA_OWNER, BACKUP_SCHEMA_USAGE, RUNTIME_SCHEMA_USAGE, STAGER_NO_POSTING, fed_ grants) | `db/migrations/9002_…` | UA §6.1, §6.3; CROSS-01; S4B-F10/F17 |
| 9003: `instance_identity`, `config_version_anchor`, `config_state_event`, `instance_module_flag`, `release_install_event`, `member.preference`; `install_household_v2`, `adopt_existing_household`, `install_activate_config` (installer-only); `cmd_prepare_config_draft`, `cmd_accept_instance_config`, `q_config_status`, `q_health`, `q_whoami` | `db/migrations/9003_…` | UA §4.2–§4.3; AE §5; CROSS-04/05; S4B-F18 |
| 9004: constraint replacements (`posting_plan.kind` incl. `member_draft`, `manual` refused; `household_setting.key`; `evidence_file.acquired_via`; `document.doc_type`); `evidence_object.storage_kind` + `r2_key` NOT NULL relaxed; write-once guard NULL-safe; `cmd_set_household_setting` MODIFY | `db/migrations/9004_…` | UA §5.5.2, §5.9, §6.3; CROSS-03; S4B-F03/F14 |
| Test harness: B002 run by the installer after B001 (option `b002=False` reproduces an R1-only database) | `tests/py/harness.py` (MODIFY) | — |
| CORE-1 tests (12) | `tests/py/run_s4_core1.py` (NEW) | Test Register V1.2 |
| AT-BAK-01 re-baseline: the restore truncate list is generated from `bnx.migration_seeded_table` | `tests/py/run_g0.py` (MODIFY, 1 hunk) | S4B-F11 (partial; the full 9-step procedure is 9016) |

R1 migrations `0002`–`0109`, `9001` and `B001` are byte-identical to R1 (checksums verified by every runner invocation).

## 2. Results (raw output in `EVIDENCE/s4_core1/`)

| Suite | PG16 16.15 (Ubuntu) | PG17 17.11 (embedded-postgres beta, see §5) |
|---|---|---|
| G0 phase 1 — frozen R1 suite at R1 head (commit `5e39b6a`, before any change) | 40 PASS / 0 FAIL / 0 SKIP | 38 PASS / 0 FAIL / 2 SKIP (AT-BAK-01/02: no pg_dump 17) |
| G0 phase 2 — R1 suite on B002 + 9002–9004 | 40 PASS / 0 FAIL / 0 SKIP | 38 PASS / 0 FAIL / 2 SKIP (same reason) |
| R1 black-box API (`tests/blackbox/api.test.mjs`) on the extended chain | 7 / 7 | 7 / 7 |
| R1 dispatch simulation | PASS | — |
| CORE-1 suite (`run_s4_core1.py`) | 10 PASS / **1 FAIL** / 1 SKIP | 10 PASS / **1 FAIL** / 1 SKIP |

CORE-1 suite detail:

| Test | Result | What it shows |
|---|---|---|
| AT-MIG-09 | PASS | B002 idempotent; 9 roles; 0 violations; an unregistered `bnx_definer` schema, a schema usable by `bnx_app` and an extra `bnx_*` role are detected; the runner refuses the next migration while a violation exists |
| AT-MIG-10 | PASS | R1 head with data → B002 → 9002–9004 → `adopt_existing_household` (PENDING_DEPLOY, not active) → `install_activate_config` → ACTIVE; ledger fingerprint pre = post; `q_balances` identical; audit chain intact; R1 posting works afterwards |
| AT-MIG-11 | PASS | without B002 the runner refuses (exit 6 `BOOTSTRAP_MISSING`) before applying anything; R1-head database stays at 9001; removed/tampered extension files → exit 4/5; a core-lane file after 9004 applies (lane independence) |
| **AT-MIG-11b** | **FAIL (finding F-C1-01)** | the frozen R1 chain cannot be installed by a non-superuser CREATEROLE installer under any of four procedures tried |
| AT-ISO-03 | PASS | identity written by `install_household_v2`; re-install, R1 re-install, re-adoption, identity update, `project_id = product_id`, invalid modules refused; 12 runtime-role calls to installer functions denied |
| AT-CFG-14 | PASS | lifecycle: acceptance leaves PENDING_DEPLOY while the previous version stays ACTIVE; only `install_activate_config` activates; B1/B2/B8 mismatches, non-owner, wrong digest/modules, stale (> 15 min) session, double acceptance, `bnx_app` activation, direct state update, flag update and incomplete flags all refused; reject path |
| AT-CFG-15 | PASS | `q_health` answers without a credential and reveals no identity values; `q_whoami` |
| AT-PLAN-04-DB | PASS | CHECK admits the nine kinds incl. `member_draft`; refuses `manual` (database part only; API/PWA part is 9010) |
| AT-EV-01-DB | PASS | `drive_processed` without `r2_key`; forward move to `r2`; inconsistent pairs, unknown kind, backward moves and `r2_key` rewrites refused |
| AT-SET-01 | PASS | 8 keys with per-key validation; 7 invalid values/keys refused; member refused |
| AT-FLG-10 | SKIP (NOT_EXECUTED) | needs 9007 enforcement, which depends on 9006 (finding F-C1-02) |
| AT-INV-01 | PASS (CORE-1 scope) | 173 disposition rows in scope present in the catalog, 0 missing; 9 S4 helper objects not yet listed in the disposition (F-C1-11) |

## 3. Findings (design defects and decisions taken during implementation)

Severity: **B** = blocks a later gate until the Owner decides; **D** = design text inconsistent, implementation chose as stated; **N** = note.

| ID | Sev | Finding | What was done | Needs |
|---|---|---|---|---|
| F-C1-01 | **B** | **S4B-F17 cannot be closed with the frozen R1 chain.** Run as a non-superuser CREATEROLE installer that owns the database (the Neon project-owner situation), with files unchanged: (1) defaults → B001 line 39 `CREATE SCHEMA … AUTHORIZATION bnx_definer` fails (`must be able to SET ROLE`); (2) `createrole_self_grant=set` → B001 line 44 `REVOKE … ON SCHEMA bnx` fails; (3) `createrole_self_grant=set,inherit` → B001/B002 succeed, 0002–0107 apply, then **R1 0108's own audit** refuses the installer memberships (`UNEXPECTED_MEMBERSHIP`); (4) as (3) plus self-revoke after bootstrap → PostgreSQL keeps the implicit ADMIN-only grant from the bootstrap superuser, and 0108 still refuses. 9002's `INSTALLER_MEMBERSHIP` rule would accept the ADMIN-only grant, but 0108 runs first. | AT-MIG-11b records all four variants and fails. | **Owner decision:** (a) amend R1 `0108` to accept the B001 installer's ADMIN-only membership (changes an R1 checksum; no real R1 database exists), or (b) keep R1 frozen and require M0-C-06 to show that Neon's owner role behaves differently (it is a member of `neon_superuser`, which this local test does not model), or (c) require a superuser-capable installer (not available on Neon). |
| F-C1-02 | D | WP matrix CORE-1 lists 9007 and 9005, but the migration register makes 9007 depend on 9006 (CORE-2). | 9007 deferred to after 9006; AT-FLG-10 NOT_EXECUTED. 9005 (audit v2) not started (outside this increment's stated scope). | Next increment order: 9005, 9006, 9007. |
| F-C1-03 | D | UA §6.1 lists `bnx_auth` as NOLOGIN; R1 B001 creates it LOGIN. | R1 kept (B001 frozen); audit rule DEFINER_LOGIN applies to `bnx_definer` only, as in R1. | Correct UA §6.1. |
| F-C1-04 | D | UA §6.1 says `bnx_worker` executes `wrk_`/`q_`; R1 grants `q_` only to `bnx_app`. | R1 behaviour kept. | Correct UA §6.1. |
| F-C1-05 | D | UA §6.3 lists a `balance_checkpoint.kind` replacement in 9004, but V1.2 keeps `balance_checkpoint` untouched (S4B-F04, OBJ-077 REUSE) and gives no value list. | Not replaced. | Remove from UA §6.3. |
| F-C1-06 | D | OBJ-066 says `posting_plan.kind` changes in 9010 with a list lacking `member_draft`; UA §5.5.2 (normative for CROSS-03) says 9004 with `member_draft`. | UA §5.5.2 implemented. | Correct OBJ-066. |
| F-C1-07 | D | `adopt_existing_household` is to write a `financial_policy` row, but that table is created in 9006. | Policy stored as `config_version_anchor.installer_policy` (required for installer-created versions); 9006 will materialize it. | Accept or redirect. |
| F-C1-08 | D | `install_activate_config(config_version, deployed_digest)` must check B1/B8 against the deployed env, which the two-argument signature cannot carry. | Third argument `p_deployed_env jsonb` (`project_id`, `instance_uid`, `modules`). `min_worker_release` check not implemented (no release registry yet). | Accept signature. |
| F-C1-09 | D | Installer-created versions (fresh install, adoption) have no Owner-supplied digest. | `config_sha256` NULL until activation binds the deployed digest once (recorded in the state event); Owner drafts always carry a digest. | Accept or require an Owner acceptance after adoption. |
| F-C1-10 | N | `bnx.restore_mode()` already exists in R1 (0102) with the required semantics. | Reused, not redefined. | Mark REUSE in the disposition. |
| F-C1-11 | N | 9 implementation helpers are not listed in the disposition: `schema_registry`, `check_constraint_of`, `config_transition`, `config_create`, `config_modules_valid`, `ledger_fingerprint`, `require_t3_fresh`, `trg_config_anchor_projection`, `trg_config_flags_complete`. | Declared in AT-INV-01. | Add OBJ rows. |
| F-C1-12 | D | `household_setting` key `data_class` has no value list; `document.doc_type` must admit the DL classes, which are upper-case in BNX-S2-09 §5 while R1 values are lower-case. | `data_class ∈ {synthetic, owner_test, real}` (PROPOSAL); DL classes added in lower case; R1 values kept; retention keys named `retention_daily/weekly/monthly`; `plan_chunk_size` 1–2000. | Owner/design confirmation of `data_class` values. |
| F-C1-13 | N | Runner: "before applying 9002" read as "before applying anything when any 9002+ file is pending". | All-or-nothing refusal (stricter). | — |
| F-C1-14 | D | `NEW_SCHEMA_UNREGISTERED` as literally stated rejected the Draft-02 conversion source schema `d02` (installer-owned, read by `bnx_definer` in 9001; AT-MIG-07). | Rule applies to unregistered schemas owned by, containing objects of, or usable by `bnx_*` runtime roles. | Accept. |
| F-C1-15 | N | R1 AT-BAK-01 hard-codes the restore truncate list; 9002 seeds new tables, so the restore duplicated rows. | Test re-baselined to the generated list from `migration_seeded_table` (the S4B-F11 mechanism). | Full procedure in 9016. |
| F-C1-16 | D | 9004 relaxes `r2_key` NOT NULL, but the write-once trigger's `<>` comparison is NULL-unsafe; the design places the trigger MODIFY in 9011. | Trigger MODIFY moved forward into 9004 (NULL-safe, forward-only `storage_kind`); otherwise a database stopped after 9004 would allow `r2_key` to be cleared. | 9011 builds on it. |

## 4. Not done in this increment

9005–9016; Worker/Gateway, PWA, AI-host, Executor work; AT-FLG-*; AT-CFG-13 (AI-ENTRY verifier fixtures N16–N22, lives with the AI-ENTRY verifier); M0/Neon checks; independent G0 reproduction.

## 5. Environment and deviations from the gate definition

- PostgreSQL 16.15 (Ubuntu package); PostgreSQL 17.11 from `@embedded-postgres/linux-x64@17.11.0-beta.19` (the same build R1 used). This is **not** the official PGDG build S4B-F19 asks for, and it ships no `pg_dump`, so AT-BAK-01/02 are NOT_EXECUTED on PG17.
- Python 3.13.18, psycopg 3.2.3; Node 22.23.4, `pg` 8.13.1.
- The author executed every test; G0 requires an independent reproduction (S4B-F19). The Owner waived S5; the waiver does not convert any result into `VERIFIED_INDEPENDENT`.

## 6. Reproduce

```bash
# disposable clusters only (the harness creates and drops bnx_* databases AND roles cluster-wide)
python3 tests/py/run_g0.py --server pg16          # R1 suite on the extended chain
python3 tests/py/run_s4_core1.py --server pg16    # CORE-1 suite
BNX_PY=$(which python3) BNX_SERVER=pg16 node --test tests/blackbox/api.test.mjs
```
