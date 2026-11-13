# G0 independent run — R2 remediation

Runner: OpenAI GPT-5 Codex (not Claude/Anthropic), Codex cloud execution workspace, Linux containers
Date: 2026-11-13
Tested SHA: `846db8e32b3940e6ac446b058cc2a7038c7adb6a`
Target: draft PR #40, branch `s4/g0-remediation-2`, base `main` `9edbed7`

Tools: PostgreSQL server 16.16 and 17.12; matching `psql`, `pg_dump`, and `pg_restore` 16.16/17.12; Python 3.13; Node `v22.23.5`; Playwright `1.63.0`; gitleaks `8.21.2`. All test data was synthetic. No code, branch, or PR was changed.

## Verdicts

| Gate | Verdict | Grade |
|---|---|---|
| A regression PG16 | PASS — 196 pass, 0 fail, 0 skip | VERIFIED_INDEPENDENT |
| A regression PG17 | PASS — 196 pass, 0 fail, 0 skip | VERIFIED_INDEPENDENT |
| A black-box and unit | PASS — 35 pass, 0 fail, 0 skip | VERIFIED_INDEPENDENT |
| A PWA PG16 | NOT EXECUTED — browser unavailable | NOT_EXECUTED |
| A PWA PG17 | NOT EXECUTED — browser unavailable | NOT_EXECUTED |
| A dispatcher simulation | PASS — result `PASS` | VERIFIED_INDEPENDENT |
| B migrations | PASS — 51 migrations, head 9039, 0 privilege violations | VERIFIED_INDEPENDENT |
| B privileges | PASS — no unsafe findings; expected backup read grants only | VERIFIED_INDEPENDENT |
| B catalog / manifest | PASS — 119 entries match; manifest and signature checks pass | VERIFIED_INDEPENDENT |
| C test integrity | PASS | VERIFIED_INDEPENDENT |
| C scans | PASS — gitleaks and SIN scans clean | VERIFIED_INDEPENDENT |
| D schema review | PASS — six representative schemas reviewed against bodies; no mismatch found | VERIFIED_INDEPENDENT |

## Part A — runtime regression

| Suite | PG16 | PG17 |
|---|---:|---:|
| `run_g0` | 40/0/0 | 40/0/0 |
| `run_s4_core1` | 12/0/0 | 12/0/0 |
| `run_s4_core2` | 12/0/0 | 12/0/0 |
| `run_s4_core3` | 9/0/0 | 9/0/0 |
| `run_s4_core4` | 11/0/0 | 11/0/0 |
| `run_s4_core5` | 8/0/0 | 8/0/0 |
| `run_s4_core6` | 8/0/0 | 8/0/0 |
| `run_s4_core7` | 5/0/0 | 5/0/0 |
| `run_s4_core8` | 8/0/0 | 8/0/0 |
| `run_s4_core9` | 4/0/0 | 4/0/0 |
| `run_s4_core10` | 7/0/0 | 7/0/0 |
| `run_s4_core11` | 5/0/0 | 5/0/0 |
| `run_s4_core12` | 8/0/0 | 8/0/0 |
| `run_s4_core13` | 11/0/0 | 11/0/0 |
| `run_s4_core14` | 5/0/0 | 5/0/0 |
| `run_s4_core15` | 7/0/0 | 7/0/0 |
| `run_s4_core16` | 3/0/0 | 3/0/0 |
| `run_s4_core17` | 6/0/0 | 6/0/0 |
| `run_s4_core18` | 9/0/0 | 9/0/0 |
| `run_s4_core19` | 7/0/0 | 7/0/0 |
| `run_s4_core_9011r` | 11/0/0 | 11/0/0 |
| **Total** | **196/0/0** | **196/0/0** |

Key remediation checks passed on both majors:

- `AT-BKP-DRILL-EXEC` passed with a deliberately failing `python3` first on `PATH`.
- Missing restored header now reports `NO_RESTORED_HEADER`, not `HEADER_FACTS_DIFFER`.
- `AT-NULL-01` passed for absent, null, and empty required fields.
- `AT-OUT-06` passed 43 validator-parity cases over 15 schema keywords.
- PG16 used `pg_dump 16.16`; PG17 used `pg_dump 17.12`.

Black-box/unit testing passed all 35 tests. The dispatcher simulation returned `"result": "PASS"`.

PWA setup failed because the Playwright CDN returned HTTP 403 `Domain forbidden` while downloading Chromium. Both PWA runs therefore had 23 browser-launch hook failures. No PWA application behavior was executed; this is `NOT_EXECUTED`, not a product failure.

## Part B — migration and privilege gate

Fresh databases `bnx_g0_r3_pg16` and `bnx_g0_r3_pg17` were independently bootstrapped and migrated.

- 51 migrations applied in order.
- Head: `9039`.
- Migration stderr warnings: none.
- `privilege_violations=0`.
- No SECURITY DEFINER functions without fixed `search_path`.
- No bnx functions executable by `PUBLIC`.
- No direct table privileges for `bnx_app`, `bnx_auth`, `bnx_authn`, or `bnx_worker`.
- Expected SELECT grants for `bnx_backup`.
- No unexpected object owners.

`catalog_build.py --check` reported `119 entries match`.

`release_manifest.py --check` reported worker `0.9.5-p2`, 51 migrations, and 27 dependencies.

`release_sign.py check-files` reported that migration files match the manifest.

## Part C — integrity and scans

The CI workflow includes `set -o pipefail`, has no `continue-on-error` on test steps, and includes R1, all `run_s4_core*.py` suites, black-box/unit, PWA, and simulation.

`harness.Role.call` invokes `jsonschema_lite.check_output` for every `bnx_app` call. `AT-OUT-06` compared the Python validator with the Gateway validator over 43 cases and 15 keywords; all results, paths, and reasons matched.

Scans:

- gitleaks 8.21.2: 115 commits scanned, no leaks.
- `sin_repo_scan.py --all-history`: 2367 files, 0 hits.
- `owner_sources` history count: 0.
- Report-folder SIN/ITN scan: 396 files, 0 hits.

## Part D — schema review

Six schemas changed by 9035–9037 were compared against their latest function bodies:

1. `q_investment_position`: stable top-level keys are always returned; nullable reporting and valuation fields match the use of `jsonb_strip_nulls`.
2. `q_card_fee_progress`: no-policy output contains the required identity/status fields and allows optional policy, progress, fee, issuer, and calculation fields to be absent or null.
3. `q_f1_balances`: required row identity/currency/holder/status fields match the body; optional balance and reporting fields may be absent.
4. `q_cashflow_statement`: opening, closing, and reconciliation may be null when balances are unavailable, matching the schema.
5. `q_evidence_trace`: source rows always contain stable identifiers, date, and amount; linked journal and replacement fields are nullable/optional as appropriate.
6. `q_r30_review_queue`: all body-produced queue kinds are represented, while kind-specific detail fields remain optional.

No required key was found that the body can omit, no nullable body value was typed as non-null, and no enum or decimal pattern contradicted the exercised bodies or CHECK constraints.

## Findings

### G0-IND-01 — note — PWA browser unavailable

Chromium installation failed with HTTP 403 `Domain forbidden` from `cdn.playwright.dev`. Both PWA runs failed at `browserType.launch` because the executable was absent. This prevents a PWA behavior verdict in this environment, so the grade is `NOT_EXECUTED`.

Reproduce:

```bash
cd tests/pwa
npx playwright install --with-deps chromium
```

## Differences from the author's claims

- The runnable portion of the author's claim is reproduced: 196 PG16 + 196 PG17 + 35 black-box/unit + simulation PASS.
- PWA remains unexecuted because the environment blocks the required Chromium download.
- No runtime defect was found in the 9039 remediation or independently reviewed gates.
- Initial local attempts exposed only execution-container issues: missing socket mount, exact PostgreSQL client path, Git safe-directory, and pip invocation. These were corrected and affected tests were rerun.

## Raw evidence

Raw output was produced under `raw/`:

- `pg16.run_g0.txt`, `pg16.run_s4_core*.txt`, and corresponding `pg17.*` files.
- Generated suite evidence under `raw/ev/`.
- `blackbox.txt`, `sim.txt`, `pwa_install.txt`, `pwa_pg16.txt`, and `pwa_pg17.txt`.
- `b/part_b.txt`, `b/catalog_check.txt`, `b/release_manifest_check.txt`, and `b/release_sign_check.txt`.
- `c/integrity_review.txt`, `c/gitleaks_git.txt`, `c/sin_repo_scan_all_history.txt`, and `c/owner_sources_count.txt`.

This is return path R2. I could not push or open a GitHub PR from this environment.
