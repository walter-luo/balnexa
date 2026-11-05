# Balnexa R6.2-R1 — One-Pass Remediation Package (README_CLOSURE)

| Field | Value |
|---|---|
| Package | `Balnexa_R6.2-R1_Remediation_Package_V1.0` (git commit recorded in `EVIDENCE/git_commit.txt`) |
| Responds to | `BNX-FINAL-AUD-HANDOFF-R6.2-D04-V1.0` (SHA-256 `9a2940d56019a5dc8c4aed18ccb3ca8c2fe328db779f966de1d591875aa6ac29`) |
| Baseline | R6.2-Draft-04 (unchanged; DB zip `19465e7e…` byte-identical copy in `db/history/draft04/`, verified by `diff -r`) |
| Scope | G0 only (local, synthetic, offline). **No cloud resource, account, billing, real data or key was touched. Nothing was deployed or pushed.** |
| Evidence grade of every PASS here | `AUTHOR_RUNTIME_EVIDENCE` — awaiting independent reproduction. Nothing is `CLOSED`. |
| Implementation freeze | Implementation source (`db/`, `apps/`, `tests/`) was frozen when the Owner's 2026-10-30 23:30 reconciliation prompt (`BNX-CLAUDE-ONE-PASS-AI-FIRST-2026-10-30-V1.0`) arrived; only documentation/traceability files were written afterwards (see §7). |

## 1. What changed (Draft-04 → R1)

| AUD | Change | Files / objects |
|---|---|---|
| AUD-049 (P0) | Privileged bootstrap split from migrations; `bnx_migrator` LOGIN NOINHERIT, member of `bnx_definer` WITH INHERIT FALSE, SET TRUE; new runner (identity check, prefix + checksum verification, one transaction per migration incl. ledger row, injected-failure option, privilege audit after every migration) | `db/bootstrap/B001_bootstrap.sql`, `db/tools/run_migrations.py`, `0101`, `0108` |
| AUD-050 (P0) | `ALTER DEFAULT PRIVILEGES` for `bnx_definer` (bnx, bnx_rpt) and `bnx_auth` (auth), tables **and** sequences → `bnx_backup`; audit rules `BACKUP_CANNOT_READ`, `DEFAULT_PRIVILEGE_MISSING`, `BACKUP_WRITE` | `B001`, `0108 bnx.audit_privileges()` |
| AUD-044 (P0) | Deferred COMMIT-time `bnx.assert_journal_complete` fired by the **header** insert and every line insert; ≥ 2 lines, debit and credit per currency, zero sum per currency, line currency = ledger-account currency, scale, same-transaction lines (`LATE_LINE`) | `0102` |
| AUD-045 (P0) | Composite `(id, currency)` FKs across ledger_account / account_currency / journal_line / statement / source_txn / clearing_item; ISO check; per-currency scale triggers; original vs posting currency pair check; `balance_at` currency filter | `0103` |
| AUD-052 | `event_seq` tie-breaker, unique same-version ties, deferred share total ≤ 100 % | `0104` |
| AUD-054 | `bnx.source_link_event` (immutable event id, enforced state machine, chained `prior_event_id`); Draft-04 table retired read-only | `0105` |
| AUD-053 | Command Core vertical slice: sessions, OAuth code + PKCE S256, actor/tier/channel policy, idempotency with request hash, hash-chained audit, outbox, queue, accounts, categories, parties, grants, posting, correction, posting-date confirmation, openings, ownership, evidence registration/access, import plans (freeze/approve/chunk/activate/stale/suspend), versioned balances | `0106`, `0108 wrk_revalidate_plan`, `apps/worker` |
| AUD-051 | Audience-bound snapshot decision; uniform `NOT_AVAILABLE`; `ACCESS_REVOKED`; Owner T3 audit replay | `0107` |
| AUD-046 | Neon queue authority with generation counters; KV hint never cleared; unconditional backstop every 3 h | `0106` queue, `apps/worker/src/dispatch.js`, `tests/sim/dispatch_sim.mjs` |
| AUD-047/042 | No silent `dual_verified`; worker archive events; optional fail-closed `require_dual_copy_before_approval`; capacity model | `0109`, `tests/sim/archive_capacity.py` |
| AUD-048 | Three-axis acceptance matrix (OWN-01 unchanged) | `docs/AUD-048_Acceptance_Matrix.md` |
| NEW-048…052 | Defects found during execution/adversarial review (see `CLAUDE_SELF_REVIEW.md`) | tracker |

Draft-04 `0002…0006` and `9001` are byte-identical in the clean chain. Draft-04 `0001` and `0007` are not edited; they remain only in `db/history/draft04/` and the runner refuses them.

## 2. Source manifest (SHA-256)

| File | SHA-256 |
|---|---|
| `db/bootstrap/B001_bootstrap.sql` | `9d3654378cc92a96719e91b0a704bc55459c49857a014a8e67aab2e8ac70c7dd` |
| `db/migrations/0002_reference_and_accounts.sql` (= Draft-04) | `705660726d0ae9fee82f1777aae7f6b14f3e1eeff6d60613895be8a80c071ed0` |
| `db/migrations/0003_ledger.sql` (= Draft-04) | `0da834f92271feec302abbea7fcb25f3475a28d098c85e99a6dcba31520f9e6b` |
| `db/migrations/0004_evidence.sql` (= Draft-04) | `f0fe79fa984d48c8ccf639ac8809a264e02795c00fbb7bc54ecaa278cc57498b` |
| `db/migrations/0005_matching.sql` (= Draft-04) | `b69a31fe480cde2ffe0b50f5a03b5615c44d0c1612a9d4d3c7b227db3ee73d79` |
| `db/migrations/0006_version_aware_readers.sql` (= Draft-04) | `f4626897b7cf903be23d426aa17acea06f305f920b7ac1b1cd23745fa26f2a53` |
| `db/migrations/0101_grants_r1.sql` | `6e215cac6626a2255f92f862363ad164eca7ba2b4ab2c38518ec5cd610b9be01` |
| `db/migrations/0102_journal_completeness.sql` | `f9a2d524ad6f3bb907ce7ab91d565e7c3d5acd635830383c2eae171960998c2c` |
| `db/migrations/0103_currency_integrity.sql` | `623df431fc8c794ff71c0d17062554d8ccde213848ea0053a7383b58de0eabfd` |
| `db/migrations/0104_ownership_determinism.sql` | `958d7443f7c61f0fd2519dae24ed3da09696eba04f2c17c90d6d462397e51c23` |
| `db/migrations/0105_source_link_events.sql` | `0c0ae8e1bcc6d36178630183d38c92a51346dbad0148c034a8c01c1bfcaf6fdc` |
| `db/migrations/0106_command_core.sql` | `413621fb8e68312c9b77e77508b07eb3910a1248c2e562375453d6b38e059ad0` |
| `db/migrations/0107_snapshot_authz.sql` | `c60c02c0ba66183925852545a5c18e3878cb4e5cb9d77a2a55b38d96e202d088` |
| `db/migrations/0108_grants_and_privilege_audit.sql` | `4fc92f2b9b3dda0a14b2863fa3c7e53c2723e8eaa3d295d4997a42da8bc8ce6f` |
| `db/migrations/0109_archive_integrity_and_dual_copy_gate.sql` | `82ace89c511b9b795efc49421d42a37e6b90bfa299c65eaec56dc3a6c7db4733` |
| `db/migrations/9001_import_draft02_logical_state.sql` (= Draft-04) | `48ef95fc696746873f2193627baa6fa24ad828171ef3c8d18241b8661c9a4773` |
| `db/tools/run_migrations.py` | `152f6e0b725fc7a049388c88af7ad8b423c4437d0ed497cf1ba53eb3b61dd2f3` |
| `apps/worker/src/index.js` | `97dc0071ce5c5da52ea4b9992580a26c3b99574aebbcf14065816b69ccc2a251` |
| `apps/worker/src/jwt.js` | `175302fd0b31ca6fc538787a96ee85d34bb8bcb73969640ecf5e82e7513a6af3` |
| `apps/worker/src/dispatch.js` | `f66c94da125a2c692ef77063c48f37df6daf1421178983602cbfcab215933a69` |

Every file of the package is hashed in `EVIDENCE/g0_08/manifest_sha256.json`.

## 3. Dependencies (as executed)

PostgreSQL 16.15 (Ubuntu) and 17.11 (embedded-postgres 17.11.0-beta.19); psql/pg_dump/pg_restore 16.15; Python 3.13.18 with psycopg 3.2.3 (libpq 16.0.15); Node v22.23.4, npm 10.9.9, `pg` 8.13.1; age 1.1.1. No Docker image was used. Full list: `EVIDENCE/environment.txt`, `EVIDENCE/g0_08/sbom.json`.

## 4. Run order (fresh, disposable clusters only)

```bash
# 1 privileged bootstrap, once per database, by the installer identity (local: postgres; Neon: project owner — M0-C-06)
psql "host=<sock> port=<port> user=postgres dbname=<db>" -X -v ON_ERROR_STOP=1 -1 -f db/bootstrap/B001_bootstrap.sql
# 2 migrations, always by the restricted migrator
python3 db/tools/run_migrations.py --dsn "host=<sock> port=<port> user=bnx_migrator dbname=<db>"
# 3 installer step (migrator under SET ROLE): select bnx.install_household('<name>', 'https://accounts.google.com', '<google sub>');
# 4 tests (the harness creates and drops bnx_* databases and roles on the target cluster: never point it at a real cluster)
python3 tests/py/run_g0.py --server pg16      # and --server pg17
BNX_SERVER=pg16 node --test tests/blackbox/api.test.mjs
node tests/sim/dispatch_sim.mjs ; python3 tests/sim/archive_capacity.py
python3 tools/g0_artifact_checks.py --manifest ; python3 docs/contradiction_sweep.py
```

`tests/py/harness.py` holds the socket paths of the two local test clusters (`/var/lib/postgresql/bnx16`, port 55416; `/var/lib/postgresql/bnx17`, port 55417).

## 5. Results summary (author runs; raw logs in `EVIDENCE/`)

| Suite | PG16 | PG17 |
|---|---|---|
| `tests/py/run_g0.py` (40 tests: migrations, accounting, Command Core, concurrency, faults, snapshots, ownership, source links, evidence, archive, queue, backup, 6 Draft-04 negative controls, 1 mutation check) | **40 PASS / 0 FAIL / 0 SKIP** | **38 PASS / 0 FAIL / 2 SKIP** (AT-BAK-01/02: pg_dump 17 not available → NOT_EXECUTED) |
| `tests/blackbox/api.test.mjs` (Worker module over HTTP; 7 tests) | 7/7 | 7/7 |
| `tests/sim/dispatch_sim.mjs` (AUD-046) | PASS: 0 lost of 12 000 items, 0 bound violations; Draft-04 flag protocol lost 57 | — |
| `tests/sim/archive_capacity.py` (AUD-047) | model output (not a pass/fail claim) | — |
| AI-ENTRY verifier + 15 negatives (re-run, unchanged Draft-04 companions) | ALL FIXTURES PASS | — |
| AUD-038 keyring simulation (re-run, unchanged) | KEYRING SIMULATION PASS | — |
| Chain lint / secret scan | 0 findings / 0 findings (Draft-04 control: 2 lint findings) | — |
| Repeat runs (flakiness) | 2 further PG16 runs 40/40 | — |

A post-freeze re-run with the frozen sources is recorded in `EVIDENCE/rerun_2026-10-31/` together with the manifest hash it ran against.

## 6. Compatibility and rollback

- Fresh installations use B001 + R1 chain. A Draft-04 database is **not** upgraded in place by this package (no Draft-04 database exists; Draft-02 logical state is converted by 9001, AT-MIG-07).
- Rollback = drop the disposable database; migrations are forward-only and checksum-locked. A failing migration rolls back atomically (AT-MIG-03).
- PostgreSQL 16+ is required (`GRANT … WITH INHERIT FALSE, SET TRUE`). Neon role semantics are M0-C-06 (`M0_PENDING`).

## 7. Files written after the implementation freeze (documentation/traceability only)

`README_CLOSURE.md`, `RELEASE_READINESS.md`, `CLAUDE_SELF_REVIEW.md`, `docs/R1_Doc_Delta.md`, `docs/contradiction_sweep.py`, `tools/build_tracker.py` (AI-first impact columns), `AUD001_054_Master_Tracker.csv`, `EVIDENCE/rerun_2026-10-31/*`, `EVIDENCE/g0_08/manifest_sha256.json`, `EVIDENCE/git_commit.txt`.

## 8. Unavailable inputs

Not supplied and therefore not inspected: the seeded `AUD001_054_Master_Tracker.csv` (`86272ff8…`), Round-05 review (`a63d6196…`), Comprehensive audit (`f41b2fe4…`), Deep Research digest (`07faa20a…`), Draft-04 Audit Test Pack zip, governance files `01…06`, and `Balnexa_AI_First_Input_Output_Conversation_Handoff_V1.0_2026-10-30.md` (`1a55abcb…`). The tracker here is built from the Draft-04 Traceability (`111f86ee…`) and the final audit; any claim unique to the missing files is NOT_EXECUTED.
