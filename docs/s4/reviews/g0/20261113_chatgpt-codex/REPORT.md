# G0 independent review

Runner: GPT-5/Codex, OpenAI API platform (not Claude)

Date: 2026-11-13 UTC

Code under test: `69138694a3c896b58c076a130738a328b1873075` (`s4/report-rows-2`)

Review branch head: `117ed42154d3533e9290e0bf06c71481c68452f3` (`s4/g0-review`)

Base: `9edbed74c2b29633c85a141a63025ed910ba7f7` (`main`)

Tools: PostgreSQL server/client 16.16 and 17.12; Python 3.13.18; Node 22.23.5; Playwright 1.63.0; Gitleaks v8.21.2.

## Verdicts

| Gate | Verdict | Grade |
|---|---|---|
| A regression PG16 | FAIL | VERIFIED_INDEPENDENT |
| A regression PG17 | FAIL | VERIFIED_INDEPENDENT |
| A black-box | FAIL | VERIFIED_INDEPENDENT |
| A PWA | PARTIAL — browser could not be installed; hooks failed before launch | NOT_EXECUTED |
| A dispatch simulation | PASS | VERIFIED_INDEPENDENT |
| B migrations | FAIL — install completed, but history immutability audit found post-introduction edits | VERIFIED_INDEPENDENT |
| B privileges | PASS after B003 audit-owner bootstrap | VERIFIED_INDEPENDENT |
| B catalog / manifest | PASS | VERIFIED_INDEPENDENT |
| C test integrity | PARTIAL — harness contract is present, but the Python validator is not feature-parity complete | VERIFIED_INDEPENDENT |
| C scans | PASS | VERIFIED_INDEPENDENT |
| D schema review | PASS for the sampled families/tools | VERIFIED_INDEPENDENT |

## Part A results

PG16 and PG17 produced identical suite counts. Each row is `PASS / FAIL / SKIP`.

| Suite | PG16 | PG17 |
|---|---:|---:|
| `run_g0.py` | 13 / 27 / 0 | 13 / 27 / 0 |
| `run_s4_core1.py` | 7 / 5 / 0 | 7 / 5 / 0 |
| `run_s4_core2.py` | 3 / 9 / 0 | 3 / 9 / 0 |
| `run_s4_core3.py` | 0 / 9 / 0 | 0 / 9 / 0 |
| `run_s4_core4.py` | 0 / 11 / 0 | 0 / 11 / 0 |
| `run_s4_core5.py` | 3 / 5 / 0 | 3 / 5 / 0 |
| `run_s4_core6.py` | 4 / 4 / 0 | 4 / 4 / 0 |
| `run_s4_core7.py` | 1 / 4 / 0 | 1 / 4 / 0 |
| `run_s4_core8.py` | 2 / 6 / 0 | 2 / 6 / 0 |
| `run_s4_core9.py` | 0 / 4 / 0 | 0 / 4 / 0 |
| `run_s4_core10.py` | 0 / 7 / 0 | 0 / 7 / 0 |
| `run_s4_core11.py` | 1 / 4 / 0 | 1 / 4 / 0 |
| `run_s4_core12.py` | 0 / 8 / 0 | 0 / 8 / 0 |
| `run_s4_core13.py` | 1 / 10 / 0 | 1 / 10 / 0 |
| `run_s4_core14.py` | 1 / 4 / 0 | 1 / 4 / 0 |
| `run_s4_core15.py` | 0 / 7 / 0 | 0 / 7 / 0 |
| `run_s4_core16.py` | 0 / 3 / 0 | 0 / 3 / 0 |
| `run_s4_core17.py` | 0 / 6 / 0 | 0 / 6 / 0 |
| `run_s4_core18.py` | 2 / 6 / 0 | 2 / 6 / 0 |
| `run_s4_core19.py` | 2 / 4 / 0 | 2 / 4 / 0 |
| `run_s4_core_9011r.py` | 4 / 7 / 0 | 4 / 7 / 0 |
| **Total** | **44 / 150 / 0** | **44 / 150 / 0** |

For every listed failure other than the two noted below, the first error line was `ProgrammingError: VALIDATION_FAILED`, followed by `DETAIL: modules`. The complete per-test lines are in `raw/failure_index.txt`.

The failure IDs were the following on both majors:

* `run_g0`: AT-BAL-01, AT-BAL-02, AT-BAL-03, AT-BAL-04, AT-MUT-01, AT-CMD-01, AT-CMD-02, AT-CONC-01, AT-CONC-02, AT-CMD-03, AT-CMD-04, AT-CMD-05, AT-PLAN-01, AT-PLAN-02, AT-PLAN-03, AT-CONC-03, AT-FAULT-01, AT-CMD-06, AT-CMD-07, AT-SNAP-03, AT-SNAP-04, AT-OWN-05, AT-SRC-01, AT-EVP-11, AT-ARC-02, AT-Q-01, AT-BAK-01.
* `core1`: AT-MIG-10, AT-ISO-03, AT-CFG-14, AT-CFG-15, AT-SET-01.
* `core2`: AT-CMD-06x, AT-REG-15, AT-REG-04-06, AT-REG-17, AT-REG-18, AT-POL-01, AT-FLG-01-09, AT-FLG-10, AT-MUT-02.
* `core3`: AT-ECON-01-04, AT-ECON-05, AT-PLAN-06,07, AT-MUT-03, BB-OAUTH-01x,04, AT-CMD-04x, BB-OAUTH-02, BB-OAUTH-03, AT-AIH-13-15.
* `core4`: AT-PLAN-04, AT-PLAN-05, AT-PLAN-05b, AT-REV-01-07, AT-EXEC-01, AT-EXEC-02, AT-EML-01-04, AT-EML-06,COV, AT-MAIL-02-04, AT-HX-01-08, AT-ACP-01-08.
* `core5`: AT-SIN-08a, AT-MUT-04, AT-SIN-22-27, AT-SIN-16,30, AT-SIN-C6. The first four had `ProgrammingError: VALIDATION_FAILED`; AT-SIN-C6 had `Fail: repository scan found candidates:` with empty captured stdout. An independent host scan was clean.
* `core6`: AT-SIN-01-04, AT-SIN-05,07, AT-SIN-29, AT-SIN-30.
* `core7`: AT-G0R-01, AT-G0R-02, AT-G0R-04, AT-G0R-05.
* `core8`: AT-R28-HIST-01, AT-R28-05,20, AT-R28-09, AT-R28-11, AT-R28-CONS, AT-R28-FAM.
* `core9`: AT-FX-01, AT-INVL-01, AT-P0-R19, AT-9012b-CAT.
* `core10`: AT-OBS-01, AT-STP-01, AT-RCN-01, AT-RCN-02, AT-RCN-03, AT-RCX-01, AT-9012c-CAT.
* `core11`: AT-MR-01, AT-MR-02, AT-ONB-01, AT-IMP-PAY-01.
* `core12`: AT-F1, AT-F2-F3, AT-P0-R09, AT-F4-F5-F6, AT-F7-P0, AT-RPT-STALE, AT-ARCH-ACL, AT-9013-CAT. The first seven had `ProgrammingError: VALIDATION_FAILED`; AT-9013-CAT had `Fail: ['F1/1', ..., 'R-BAL/1'] 13` because the test's expected ordering disagreed with the database ordering.
* `core13`: AT-BAK-04, AT-BAK-03, AT-BKP-REC, AT-BKP-DRILL, AT-BKP-12-16, AT-BKP-13, AT-BKP-17-19, AT-ANCHOR-01, AT-BKP-10, AT-SPEND-ADM.
* `core14`: AT-ISO-BF, AT-B7-01, AT-Q-02-DB, AT-EV-01-DB.
* `core15`: AT-EXEC-03, AT-RND-01, AT-BAK-01-EXEC, AT-BKP-DRILL-EXEC, AT-EVV-01, AT-EXEC-04, AT-EXEC-02-STG.
* `core16`: AT-PWA-LA-01, AT-AUD-TRAIL-01, AT-CAT-02.
* `core17`: AT-AIH-REG-01, AT-AIH-CLI-01, AT-AIH-PROV-01, AT-AIH-CONN-01, AT-AIH-ENV-01, AT-ID-01.
* `core18`: AT-DOC2-01, AT-INT-01, AT-INT-02, AT-TST1-01, AT-DPL-01, AT-AUD-01.
* `core19`: AT-OUT-01, AT-OUT-03, AT-OUT-04, AT-OUT-05.
* `core_9011r`: AT-9011R-E2E, AT-9011R-07, AT-9011R-08, AT-9011R-09, AT-SIN-17, AT-SIN-19, AT-SIN-20.

Node black-box/unit: 35 total, 12 pass, 23 fail, 0 skipped. The failed IDs were BB-AUTH-01, BB-API-01, BB-API-02, BB-OAUTH-01, BB-PLAN-01, BB-PLAN-02, BB-EXEC-01, BB-CAT-01, BB-SCHEMA-01, BB-ISO-04, BB-B7-01, BB-UP-01, BB-EXEC-02, BB-EXEC-03, AT-AIH-06, BB-OAUTH-03, AT-AIH-07, BB-OAUTH-02, AT-AIH-04, AT-AIH-06b, AT-CONF-04, RV-AIH-01…12, BB-AUTH-02. Each failed during `prepare_db.py` with `VALIDATION_FAILED` / `DETAIL: modules`; the 12 passing tests were the unit/presigning/MCP-output tests.

PWA: 23 total, 0 pass, 23 fail, 0 skipped on each major. All failed in the database preparation hook with `VALIDATION_FAILED` / `DETAIL: modules`; no browser test launched. Chromium installation failed with HTTP 403 `Domain forbidden` from `cdn.playwright.dev`.

Dispatch simulation passed with `"result": "PASS"`.

## Part B

The clean migration run applied 49 migrations through 9037 on both majors under `session_user=bnx_migrator`, `current_user=bnx_definer`, with no migration stderr warning. The documented B003 boundary was encountered and then satisfied on the reviewer-owned databases. Post-bootstrap checks showed `bnx_audit.audit_event` owned by `balnexa_audit_owner`, 49 ledger rows, and head 9037.

Privilege checks found no non-system `SECURITY DEFINER` function without a fixed search path and no `bnx.*` function executable by PUBLIC. Application table grants were limited to the expected `bnx_backup` SELECT surface; no application sequence grants were found. The only non-definer object owners were the expected `bnx_audit` audit table, primary key and trigger function owned by `balnexa_audit_owner`; extension functions in `public` are noted in the raw output and are not application objects.

Catalog and release checks passed:

* `catalog_build`: 119 entries match.
* Release manifest: worker `0.9.3-p2`, 49 migrations, 27 dependencies.
* `release_sign.py check-files`: migration files match the manifest.

## Findings

### G0-IND-01 — blocker

File: `db/migrations/9003_s4_identity_config_release.sql:118-123`.

`config_modules_valid()` computes `array_agg(k order by k)`, which is `['Canada','CRA','International']`, but compares it to `array['CRA','Canada','International']`. A valid JSON module object therefore returns false. The S4 fixtures pass all three valid YES flags at `tests/py/fixture.py:37-41`, and the failure propagates through `config_create()` as `VALIDATION_FAILED`, `DETAIL: modules`.

Reproduction:

```sql
select bnx.config_modules_valid('{"Canada":"YES","International":"YES","CRA":"YES"}'::jsonb);
-- false
```

This reproduced on PostgreSQL 16 and 17 and accounts for the 150 Python failures per major, the 23 black-box failures, and the PWA setup failures.

### G0-IND-02 — major

The committed-migration history rule is violated. Post-introduction body edits were found in 9002, 9005, 9006, 9007, 9008, 9009, 9010, 9011 and 9012. Examples include 9005 modified by `4f47faf`, 9010 modified by `11e4694` and `fe65891`, 9011 modified by `02b349f`, `3fc22c4`, `acb050c`, `982a4ba` and `45b05b8`, and 9012 modified by its incremental feature commits through `c5fee35`. These are not catalog-only fills. The later 9032 change was treated as the permitted generated catalog-block update.

Reproduction: `git log --follow --format='%h %s' -- db/migrations/<file>`; complete output is in `raw/migration_touch_details.txt` and `raw/migration_touch_commits.txt`.

### G0-IND-03 — minor

The Python validator port omits `minItems`, `maxItems`, `minimum` and `maximum` at `tests/py/jsonschema_lite.py:49-53`, while the Gateway implements them at `apps/worker/src/schema.js:60-68`. Direct parity cases agree for type, required, additionalProperties, enum, pattern, format and items, but the four omitted keywords return `null` in Python while the Gateway rejects the same invalid values. Current curated output schemas do not use these four keywords, so this is a latent contract gap rather than the cause of the observed regression.

## Part C integrity

`tests/py/harness.py:88-93` invokes `jsonschema_lite.check_output()` on every `bnx_app` call. Skip paths are dependency-conditional (`pg_dump`/OCR); with the required tools installed, the executed suites reported zero skips. Broad exception handlers in the runners convert exceptions into explicit FAIL records. CI uses `set -o pipefail`, has no `continue-on-error` on test steps, and contains the Part A suites.

Independent scans passed:

* Gitleaks: 109 commits, no leaks.
* `sin_repo_scan.py --all-history`: 1,825 files scanned, zero hits.
* `owner_sources` history path count: zero.
* Reviewer raw-folder detector scan: 183 files scanned, zero hits.

## Part D schema review

Static comparisons covered more than the required three families/tools: 9035 included `q_r28_loan_position`, `q_card_fee_progress` and `q_replay_snapshot`; 9036 included F1, F6 and F7; 9037 included R09, R30 and R31. Required envelope keys match `rpt_envelope()`; nested required fields and nullable branches matched the selected function bodies. The sampled status/warning enums and decimal-string patterns also matched the body branches. No independent schema defect was found in these samples.

## Differences from the author's claims

The protocol claims 194 passing Python tests per major, 35 passing Node tests and 23 passing PWA tests. Independent execution produced 44 pass / 150 fail / 0 skip per PostgreSQL major, 12 pass / 23 fail / 0 skip for Node, and PWA was not executed because Chromium was unavailable; its 23 hooks failed during database preparation. The dispatch simulation alone matched the claim.

## Not executed / limitations

The Playwright browser binary could not be downloaded because the environment denied the CDN domain, so no browser interaction was observed. No product code, migration, branch, commit, PR, or external resource was modified or pushed. Only this report folder was created.

Raw evidence is in the adjacent `raw/` folder, including the per-suite logs, `failure_index.txt`, clean-install/privilege SQL output, migration history, validator parity outputs, schema-body review, scan results, and Playwright installation log.
