# G0 independent re-run — PR #39

| Field | Value |
|---|---|
| Runner | GPT-5 Codex, OpenAI/Codex model family; cloud execution workspace with Docker |
| Date | 2026-11-13 |
| Repository | `walter-luo/balnexa` |
| Base | `origin/main` `9edbed74c2b29633c85a141a63025ed910ba7f7f` |
| Tested branch | `s4/g0-remediation` / draft PR #39 |
| Tested SHA | `109a6c7254de0acceebb43f37619226d89f808fc` |
| Previous SHA | `69138694a3c896b58c076a130738a328b1873075` |
| Data policy | Synthetic test data only; no cloud resources or deployment |

## Verdict

| Gate | Verdict | Grade |
|---|---|---|
| A regression PG16, C locale | PASS — 195 pass, 0 fail, 0 skip | `VERIFIED_INDEPENDENT` |
| A regression PG17, C locale, with pg_dump17 | FAIL — 194 pass, 1 fail, 0 skip | `VERIFIED_INDEPENDENT` |
| A regression PG17, ICU en-US | FAIL — 194 pass, 1 fail, 0 skip | `VERIFIED_INDEPENDENT` |
| A black-box and simulation | PASS — 35/35 black-box; simulation result PASS | `VERIFIED_INDEPENDENT` |
| A PWA Playwright suite | NOT EXECUTED — browser download blocked by CDN policy; attempted output is 0/23 hook failures | `NOT_EXECUTED` |
| B migrations | PASS — fresh PG16 and PG17 installs, 50 migrations, head 9038 | `VERIFIED_INDEPENDENT` |
| B privileges | PASS — zero audit violations; explicit checks empty | `VERIFIED_INDEPENDENT` |
| B catalog / manifest | PASS — 119 catalog entries; manifest and signed-file checks pass | `VERIFIED_INDEPENDENT` |
| C test integrity | PASS — harness parity, CI review, no undisclosed weakening found | `VERIFIED_INDEPENDENT` |
| C scans | PASS — gitleaks clean; SIN repository scan clean; no `owner_sources` history match | `VERIFIED_INDEPENDENT` |
| D schema review | PASS — reviewed selected 9035–9037 output schemas against bodies; no defect found | `VERIFIED_INDEPENDENT` |

## Finding G0-IND-01 — blocker: PG17 restore drill rejects its own pg_dump17 restore

Severity: **blocker** for the stated cross-major claim.

Files: `apps/executor/bnx_exec/jobs.py:194-202`, `apps/executor/bnx_exec/restore.py:95-108`, `db/migrations/9016_s4_backup_registry_cloud_usage.sql:636-640`, and the assertion in `tests/py/run_s4_core15.py:255-292`.

With the exact PG17 client tools available, `AT-BKP-DRILL-EXEC` fails on both a C-locale PG17 cluster and an ICU `en-US` PG17 cluster. The backup itself is recorded as `VERIFIED` with `pg_dump 17.12`, but the isolated restore drill is promoted as `FAIL` with `HEADER_FACTS_DIFFER`; the test then fails because it requires the drill outcome to be `PASS`. The same suite passes on PG16 with `pg_dump 16.16`.

Reproduction, using the authoritative suite and a PG17 socket/client setup:

```text
python tests/py/run_s4_core15.py --server pg17 --evidence <evidence-dir>
```

The first error line is:

```text
FAIL AT-BKP-DRILL-EXEC ... ('FAIL', ['migration runner exit 1: ', 'HEADER_FACTS_DIFFER'], ...)
```

The relevant path is unconditional once same-major dump tools are present: `jobs.py` loads the dump, recomputes restored header facts, compares them with the backup header, and sets `HEADER_MISMATCH`. The database promoter independently records `HEADER_FACTS_DIFFER` when the submitted restored header differs. This is not the author’s documented “pg_dump 17 missing” skip path: in this run `/usr/lib/postgresql/17/bin/pg_dump` and `pg_restore` were present and version 17.12.

The failure also reproduces on the ICU cluster (`datlocprovider=i`, `datcollate=en_US.utf8`), so migration 9038’s collation fixes do not explain or remove it. The report does not claim the exact differing header key because the worker intentionally returns only the bounded failure reason; the observable contract failure is sufficient to block the claimed 472-pass result.

## Part A — suite results

The corrected PG16 run used Node 22.23.5, the locked executor Python dependencies, Tesseract 5.5.0, a Git worktree with its administrative directory available, and `age`. The initial environment-only failures were discarded from the result; the corrected raw files are named with `node22`, `full_deps_ocr`, or `*_git` where applicable.

| Suite | PG16 C | PG17 C | PG17 ICU en-US |
|---|---:|---:|---:|
| `run_g0` | 40/0/0 | 40/0/0 | 40/0/0 |
| `run_s4_core1` | 12/0/0 | 12/0/0 | 12/0/0 |
| `run_s4_core2` | 12/0/0 | 12/0/0 | 12/0/0 |
| `run_s4_core3` | 9/0/0 | 9/0/0 | 9/0/0 |
| `run_s4_core4` | 11/0/0 | 11/0/0 | 11/0/0 |
| `run_s4_core5` | 8/0/0 | 8/0/0 | 8/0/0 |
| `run_s4_core6` | 8/0/0 | 8/0/0 | 8/0/0 |
| `run_s4_core7` | 5/0/0 | 5/0/0 | 5/0/0 |
| `run_s4_core8` | 8/0/0 | 8/0/0 | 8/0/0 |
| `run_s4_core9` | 4/0/0 | 4/0/0 | 4/0/0 |
| `run_s4_core10` | 7/0/0 | 7/0/0 | 7/0/0 |
| `run_s4_core11` | 5/0/0 | 5/0/0 | 5/0/0 |
| `run_s4_core12` | 8/0/0 | 8/0/0 | 8/0/0 |
| `run_s4_core13` | 11/0/0 | 11/0/0 | 11/0/0 |
| `run_s4_core14` | 5/0/0 | 5/0/0 | 5/0/0 |
| `run_s4_core15` | 7/0/0 | 6/1/0 | 6/1/0 |
| `run_s4_core16` | 3/0/0 | 3/0/0 | 3/0/0 |
| `run_s4_core17` | 6/0/0 | 6/0/0 | 6/0/0 |
| `run_s4_core18` | 8/0/0 | 8/0/0 | 8/0/0 |
| `run_s4_core19` | 7/0/0 | 7/0/0 | 7/0/0 |
| `run_s4_core_9011r` | 11/0/0 | 11/0/0 | 11/0/0 |
| **Total** | **195/0/0** | **194/1/0** | **194/1/0** |

Entries are `PASS/FAIL/SKIP`. The only failure in each PG17 lane is `AT-BKP-DRILL-EXEC`, described above. There were no Python-suite skips in the corrected runs.

Black-box and simulation evidence:

- `tests/blackbox/api.test.mjs` plus `unit.test.mjs`: Node `v22.23.5`, **35 pass, 0 fail, 0 skip**.
- `tests/sim/dispatch_sim.mjs`: result **`PASS`**.
- PWA setup attempted `npx playwright install --with-deps chromium`; the Playwright CDN returned HTTP 403 “Domain forbidden”. The follow-up run therefore produced **23 hook failures**, all because Chromium was absent. Per the prompt this is `NOT_EXECUTED`, not a product failure.

## Part B — migrations and privileges

On fresh reviewer databases `bnx_g0_r2_v2_pg16` and `bnx_g0_r2_v2_pg17`:

- B001 and B002 were applied.
- The first migration pass intentionally stopped at the B003 gate with exit 6 before 9011.
- B003 was then applied as the installer step.
- The second pass applied all remaining migrations and reported `OK migrations=50 head=9038 privilege_violations=0` on both majors.
- `bnx_audit.audit_event` is owned by `balnexa_audit_owner`.
- `bnx.audit_privileges()` returned `violations: []` on both databases.

Migration history review found no forbidden post-commit edit. The older 9xxx files’ follow-up commits are within the introducing stacked PR before that PR’s merge into `main`; the open-stack files have their touches in their introducing sequence. `9038` is touched only by `6660054` (`G0 remediation: collation independence...`), its introducing PR #39 commit, and is not on `main`.

Explicit PG16 catalog queries reported:

```text
SECURITY_DEFINER_WITHOUT_FIXED_SEARCH_PATH
[]
PUBLIC_EXECUTABLE_FUNCTIONS_IN_BNX_SCHEMAS
[]
NON_STANDARD_OWNERS_IN_REGISTERED_SCHEMAS
[]
```

The intended audit-owner exception is separately confirmed for `bnx_audit.audit_event`; application data access remains through the audited function surface. `tools/s4/catalog_build.py --server pg16 --db bnx_g0_r2_v2_pg16 --check` reported `OK, 119 entries match`. `tools/s4/release_manifest.py --check` reported worker `0.9.4-p2`, 50 migrations, 27 dependencies, and `release_sign.py check-files` reported `migration files match the manifest`.

## Part C — test integrity and scans

- `tests/py/harness.py` routes `bnx_app` output through `jsonschema_lite.check_output`; the new `AT-OUT-06` in `core19` independently exercised parity against the Node validator. The completed core19 result was 7/0/0 on all three database lanes.
- The parity coverage includes type, required, additionalProperties, enum, pattern, format, items, minItems/maxItems, minLength/maxLength, minimum and maximum; the Python and Gateway results matched paths and reasons.
- CI has `set -o pipefail`, no `continue-on-error` on test steps, and runs the same Python suites, black-box/unit tests, PWA test, and simulation. The new PG17 ICU `en-US` matrix lane is present.
- `gitleaks` 8.21.2 over the repository history: **112 commits scanned, no leaks found**.
- `tools/s4/sin_repo_scan.py`: **2007 files scanned, 0 hits, 31 machine tokens not counted, 0 reviewed history entries allowed**.
- `git log --all --name-only --format= | grep -c owner_sources`: 0.
- `git diff --check`: clean.

## Part D — schema review

I reviewed representative output schemas and latest function bodies from 9035–9037, including `q_r28_loan_position`, `q_replay_snapshot`, `q_f1_balances`, `q_cashflow_statement`, and `q_evidence_trace`. The report-envelope schemas consistently require the common envelope while allowing nullable report fields where the SQL body can strip nulls; the scalar/detail schemas match the keys and enums emitted by their functions. The automated output-contract tests and catalog check also passed. No schema strictness defect was found in the sampled tools/report families.

## Differences from the author’s claims

1. The claimed PG17 result is **195 pass, 0 fail, 0 skip with pg_dump17**. The independent run with pg_dump17.12 is **194 pass, 1 fail, 0 skip**; the same failure occurs under ICU en-US.
2. The author’s evidence describes the PG17 backup drill as skipped when pg_dump17 is unavailable. That is not equivalent to the updated prompt’s required zero-failure result with pg_dump17 present.
3. The PWA claim of 23 pass could not be independently executed because the required Playwright Chromium download was blocked with HTTP 403. It is therefore `NOT_EXECUTED` here.

## Raw evidence

All raw evidence is beside this report in `raw/` and is about 16 MB. Key files and lines:

- `raw/c/pg16.run_g0.txt`, `raw/c/pg16.run_s4_core*.txt`, and corrected `raw/c/pg16.run_s4_core_9011r_node22_full_deps_ocr.txt`: PG16 suite totals, including 195/0/0.
- `raw/c/pg17.run_g0.txt`, `raw/c/pg17.run_s4_core*.txt`, `raw/c/pg17.run_s4_core15_age.txt`, and `raw/c/pg17.run_s4_core_9011r.txt`: PG17 totals and the `HEADER_FACTS_DIFFER` failure.
- `raw/icu.pg17.*.txt` and `raw/icu.pg17.collation.txt`: full ICU `en-US` lane and `i|en_US.utf8|en_US.utf8`.
- `raw/blackbox.txt`, `raw/sim.txt`, `raw/pwa_browser_install.txt`, `raw/pwa_tests.txt`: Node, simulation, and PWA execution evidence.
- `raw/partB_independent_v2.txt`, `raw/privilege_explicit_pg16.txt`, `raw/catalog_pg16.txt`, `raw/release_manifest.txt`, `raw/release_sign_check_files.txt`: fresh-install, privilege, catalog, and release checks.
- `raw/migration_history.txt`, `raw/ci_and_remediation.txt`, `raw/partD_static_review.txt`, `raw/schema_review_current.txt`, `raw/test_integrity_search.txt`: history, CI, and read-only reviews.
- `raw/gitleaks.txt` and `raw/sin_repo_scan.txt`: full-history secret and SIN scans.
- `raw/report_folder_sin_scan.txt`: the complete report folder, including this report and raw outputs, scanned with 0 hits.

No code, existing branch, PR, or GitHub state was changed. No report was pushed or opened as a PR; this is the R2 handoff.
