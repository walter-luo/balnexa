# Independent G0 PWA run - 2026-11-13

## Header

- Runner: OpenAI Codex, GPT-5 family (exact serving version not exposed)
- Grade eligibility: independent of Claude/Anthropic
- Platform: ChatGPT Work Mode on Windows 11 x86-64 (`Microsoft Windows NT 10.0.26300.0`)
- Date: 2026-11-13, America/Toronto
- Tested branch: `s4/pwa-system-chromium`
- Tested SHA: `15e5eb03a790c5914e7edbf018b39ff79aa151e6`
- PostgreSQL: 16.16 and 17.12, EDB Windows x86-64 binaries, fresh local clusters using locale `C`
- Python: 3.12.10
- Node: 22.23.5
- npm: 10.9.9
- Playwright: 1.63.0
- Browser executable requested: `C:\Program Files\Google\Chrome\Application\chrome.exe`
- `BNX_CHROMIUM`: set to the executable above
- Browser line: **not emitted**; the database bootstrap failed before `chromium.launch()` was reached

## Verdict

| Item | Verdict | Grade | Evidence |
|---|---|---|---|
| A PWA PG16 | PARTIAL | NOT_EXECUTED | The Node suite was invoked, but its `before()` hook failed in database preparation before Chromium launched. TAP consequently records 0 pass / 23 fail, all caused by the same hook failure; these are not 23 executed PWA test failures. |
| A PWA PG17 | PARTIAL | NOT_EXECUTED | The Node suite was invoked, but its `before()` hook failed in database preparation before Chromium launched. TAP consequently records 0 pass / 23 fail, all caused by the same hook failure; these are not 23 executed PWA test failures. |

The author's claim of 23 pass / 0 fail on each PostgreSQL major is neither verified nor contradicted by this run.

## Findings

### G0-PWA-01 - BLOCKER (independent verification environment/harness)

- Location: `tests/pwa/harness.mjs:15`; `tests/py/harness.py:48-51`; `db/bootstrap/B001_bootstrap.sql:7-37`
- Observed on both PostgreSQL majors: `prepare_db.py` created a fresh `bnx_bb_*` database, but the subsequent migration connection failed with `FATAL: role "bnx_migrator" does not exist`.
- A read-only post-run inspection found no `bnx_*` roles and no `bnx.schema_bootstrap` table in either created database. Thus B001 had no persisted effect, although `run_bootstrap()` did not surface a failure before the harness proceeded to migration.
- A focused direct `run_bootstrap()` probe created its diagnostic database and then did not return for more than five minutes; it was interrupted. This is consistent with a native-Windows bootstrap execution incompatibility or hang, not with a PWA assertion failure.
- Reproduce:

  ```powershell
  $env:BNX_PG16 = 'host=127.0.0.1 port=55416'
  $env:BNX_PG17 = 'host=127.0.0.1 port=55417'
  $env:BNX_PSQL = '<PG16-bin>\psql.exe'
  $env:BNX_CHROMIUM = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
  $env:BNX_PY = '<venv>\Scripts\python.exe'
  <Node-22>\node.exe --test --test-concurrency=1 pwa.test.mjs
  ```

  Inspect the cluster afterward as `postgres`: no `bnx_migrator` role exists and the created `bnx_bb_*` database has no `bnx.schema_bootstrap` table.

### G0-PWA-02 - MEDIUM (mandatory setup not portable to this Windows runner)

- Location: `apps/executor/requirements.txt:11-13`
- The mandatory `pip install --require-hashes --only-binary=:all:` step rejected the Windows CPython 3.12 Pillow 12.3.0 wheel.
- Expected hashes in the file: `0847a763...` or `78cb2c68...`; downloaded Windows wheel hash: `a2b55dd6...`.
- The hash check was not bypassed or edited. The failure was recorded separately. It was not the immediate cause of the PWA hook failure because the PWA bootstrap reached PostgreSQL using the installed `psycopg[binary]==3.2.3`.

## What could not be done

- Chromium did not launch, so no `browser:` line or browser version was produced by the suite.
- No PWA assertion ran to completion; accessibility, offline, menu, consent, and no-external-request behavior remain unverified.
- The complete executor requirements set could not be installed with the repository's required hashes on Windows.
- A Linux runner matching the prompt's `/usr/lib/postgresql/...` layout was not available. WSL and Docker were absent; no cloud resource was used, in accordance with the prompt.

## Scope and integrity

- Code under test was not modified.
- Only synthetic test data was used.
- No secrets or cloud resources were used.
- Raw TAP output is preserved unchanged in `raw/pwa_pg16.txt` and `raw/pwa_pg17.txt`.

