# G0 independent run — prompt for a reviewer that is not the author

`DRAFT — AI-generated` (author: Claude, the author of the code under review). Owner: Walter Luo.

## For the Owner: how to use this file

1. Give the reviewer this file's URL on branch `s4/g0-remediation-2`, or paste the section "Prompt" below:
   `https://github.com/walter-luo/balnexa/blob/s4/g0-remediation-2/docs/s4/reviews/G0_INDEPENDENT_RUN_PROMPT.md`
2. **Who counts.** Only a reviewer of **another model family** (for example ChatGPT/Codex) or a human can produce `VERIFIED_INDEPENDENT` evidence, which is what closes gate G0 (doc 03 §6). A fresh Claude chat, in any mode, is the same family: its result is `SAME_FAMILY_VERIFICATION`. That is useful as a second opinion, but it does not close G0.
3. **Execution.** Runtime evidence needs a reviewer that can run commands, such as a code-execution sandbox or a cloud dev environment. A reviewer that can only read the repository can still do Parts C and D. It must mark Parts A and B `NOT_EXECUTED`.
4. **Getting results back** (OD-GH-2: exchange through GitHub, the Owner as dispatcher, no GitHub Actions automation). The reviewer pushes a report branch and opens a draft PR (return path R1). If it cannot push, it gives you the report in its answer (return path R2), and you hand that answer to the next Claude session to commit unchanged.
5. **Large data files.** Data files belong in Google Drive (OD-GH-3), but that directory does not exist yet. The report and raw text outputs (under about 20 MB) go in the repository; anything larger is left out and only listed.

---

## Prompt

You are the **independent G0 runner** for the open-source repository `walter-luo/balnexa` (public, Apache-2.0). Balnexa is a household finance system: a PostgreSQL 16/17 core in `db/migrations`, a Cloudflare-Worker Gateway in `apps/worker`, a Python Executor in `apps/executor`, and a PWA in `apps/pwa`. You did not write this code. Work adversarially: your job is to find out whether the author's claims hold, not to confirm them.

### Target

- **Code under test:** the head of branch `s4/g0-remediation-2` (draft PR #40, the top of the stacked PRs #17 → #40). It contains the remediation of the first independent run (`docs/s4/reviews/G0_IND_REMEDIATION_2026-11-13.md`, migration 9038) and of the first re-run (`docs/s4/reviews/G0_IND_R2_REMEDIATION_2026-11-13.md`, migration 9039).
- The first run tested `69138694a3c896b58c076a130738a328b1873075` (#37); its report is `docs/s4/reviews/g0/20261113_chatgpt-codex/REPORT.md`. The first re-run tested `109a6c7254de0acceebb43f37619226d89f808fc` (#39); its report is `docs/s4/reviews/g0/20261113_chatgpt-codex-r2/REPORT.md`. A re-run checks the remediation and repeats every part.
- **Base of the stack:** `main` at `9edbed7` (PRs #1–#16 merged).
- Verify the SHA you test (`git rev-parse HEAD`) and state it in your report.

### Rules (all mandatory)

1. **Do not change the code under test.** Do not edit, merge, rebase, force-push, approve, comment on or close any existing branch or PR. Do not delete branches.
2. Write only the files of your report, under `docs/s4/reviews/g0/<YYYYMMDD>_<runner>/`. Use a short runner id, such as `chatgpt-codex` or `human-wl`.
3. **Synthetic data only.** Never write a Social Insurance Number or any other government ID, real or SIN-shaped, into a file, log, commit or your report. The tests build SIN-shaped values at run time (`tests/py/sin_corpus.py`); keep it that way. If you need one in a case of your own, build it at run time and report only "a Luhn-valid 9-digit value".
4. No secrets: no tokens or passwords in files or in your answer. No cloud resources, no deployment, no spend. Use local PostgreSQL only.
5. Owner-private material is out of scope: `requirements/owner_sources/`, the S3 package and the V1.2 design ZIP. You do not need them.
6. Grade every verdict with exactly one of:
   - `VERIFIED_INDEPENDENT`: you executed it, and you are not a Claude/Anthropic model;
   - `SAME_FAMILY_VERIFICATION`: you executed it, and you are a Claude model;
   - `NOT_EXECUTED`: you only read it, or could not run it.

   State your model family and platform at the top of the report. Do not upgrade a grade.
7. Never run two database suites at the same time. The suites drop cluster-wide roles. Name any database you create yourself `bnx_g0_*`.

### Environment (authoritative recipe: `.github/workflows/ci.yml`; summary in `docs/s4/handoff/03_Balnexa_S4_Platform_Handoff_2026-11-12.md` §5)

**Supported platform: Linux x86-64** (natively, in WSL2, or in a Docker/VM Linux guest). The Executor's pinned wheels are manylinux only, and the test harness is not supported on native Windows or macOS. If you only have native Windows, stop and report `NOT_EXECUTED` with that reason, rather than adapting the set-up.


- **PostgreSQL 16 and 17 with client tools of the same major** (`pg_dump`/`pg_restore` 16 and 17). Get them from PGDG apt (`postgresql-16`, `postgresql-17`) or any equivalent.
- **Clusters.** Start one cluster per major with exactly these sockets and ports, which `tests/py/harness.py` expects:

  ```bash
  for V in 16 17; do
    D=/var/lib/postgresql/ci$V; S=/var/lib/postgresql/bnx$V
    sudo install -d -o postgres -g postgres -m 0755 "$D" "$S"
    sudo -u postgres /usr/lib/postgresql/$V/bin/initdb -D "$D/data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8
    sudo -u postgres /usr/lib/postgresql/$V/bin/pg_ctl -D "$D/data" -o "-p 554$V -k $S -c listen_addresses=" -l "$D/server.log" -w start
  done
  ```

  If your paths differ, set `BNX_PG16` / `BNX_PG17` to libpq DSNs, for example `host=/path/to/socket port=55416`.
- **Python 3.12 or 3.13:**

  ```bash
  pip install "psycopg[binary]==3.2.3"
  pip install --only-binary=:all: "cryptography==50.0.1"
  pip install --require-hashes --only-binary=:all: -r apps/executor/requirements.txt
  ```
- **OS packages:** `tesseract-ocr`, `tesseract-ocr-eng`, `strace`, `age`.
- **Node 22:** run `npm ci` in `apps/worker` and in `tests/pwa`, then `npx playwright install --with-deps chromium` (Playwright 1.63.0).
  If that download is blocked, use an installed Chromium instead (for example from the system package manager) and set `BNX_CHROMIUM` to its executable; the PWA suite prints the browser it used. See `docs/s4/reviews/G0_PWA_RUN_PROMPT.md`.
- **Secret scan:** gitleaks 8.21.2 with `.gitleaks.toml`.

If a tool cannot be installed on your platform, say which one and grade the affected parts `NOT_EXECUTED`. Do not substitute a weaker check silently.

### Part A — reproduce the full regression (runtime)

Run sequentially from the repository root:

```bash
S=/tmp/g0run; mkdir -p $S
for srv in pg16 pg17; do
  python3 tests/py/run_g0.py --server $srv --evidence $S/ev/$srv/run_g0 > $S/$srv.run_g0.txt 2>&1
  for f in tests/py/run_s4_core*.py; do n=$(basename $f .py)
    python3 $f --server $srv --evidence $S/ev/$srv/$n > $S/$srv.$n.txt 2>&1; done
done
BNX_PY="$(which python3)" node --test tests/blackbox/api.test.mjs tests/blackbox/unit.test.mjs > $S/blackbox.txt 2>&1
node tests/sim/dispatch_sim.mjs > $S/sim.txt 2>&1
for srv in pg16 pg17; do (cd tests/pwa && BNX_SERVER=$srv BNX_PY="$(which python3)" node --test --test-concurrency=1 pwa.test.mjs) > $S/pwa_$srv.txt 2>&1; done
```

**Author's claim at this commit:**

| Run | Claimed result |
|---|---|
| PG16 Python suites (`run_g0` + 20 `run_s4_core*`) | 196 tests, 0 fail, 0 skip |
| PG17 Python suites | 196 tests, 0 fail. The author's local runs skip 3 (`pg_dump` 17 is missing there); CI runs them with `pg_dump` 17.12 and they pass. **With `pg_dump` 17 you should see 0 skips** |
| Black-box and unit (Node) | 35 pass, 0 fail |
| PWA (Playwright), each major | 23 pass, 0 fail |
| Dispatcher simulation | `"result": "PASS"` |
| **Total with `pg_dump` 17** | **474 pass, 0 fail, 0 skip** |

The claim holds for **any default collation** of your clusters: byte order (`C.UTF-8`, as in the recipe) and linguistic (for example ICU en-US). If you can, run Part A on both and report both.

Each suite ends with a line `== pgNN: X PASS, Y FAIL, Z SKIP`. Report the actual numbers per suite, and every FAIL or SKIP with its test id and the first error line.

Optionally, run `python3 tools/s4/record_regression.py --from $S --sha $(git rev-parse HEAD) --branch g0-independent` to tabulate the results. It writes a folder into `EVIDENCE/regression/` and a row into its `README.md`. Copy the table into your report, then **discard those changes** (`git checkout -- EVIDENCE/regression/README.md` and remove the new folder). Never commit them.

### Part B — migration and privilege gate (runtime)

On a fresh database per major (the harness does this; `run_g0.py` covers R1), check independently with your own SQL. Do not rely only on the suites:

1. **Clean install:** every migration in `db/migrations` applies in order on PG16 and PG17 from an empty cluster. Report any warning or notice that indicates a problem.
2. **Committed migrations are never edited.** A migration counts as committed once it has landed on `main` (its introducing PR is merged) or been applied to a persistent database; from then on a change is a MODIFY in a new migration. Commits inside the introducing PR before its merge are ordinary development and are allowed. For each `db/migrations/9*.sql`:
   - list the commits that touched it (`git log --format='%h %s' -- <file>`);
   - find the merge into `main` that landed it (`git log --first-parent origin/main`);
   - flag every touch after that merge.

   For files not yet on `main` (the open draft stack), flag every touch by a PR other than the introducing one.
3. **Privileges.** After a full install, list:
   - every `SECURITY DEFINER` function without a fixed `search_path`;
   - every function `EXECUTE`-able by `PUBLIC`;
   - every table or sequence with privileges for the application login roles (see `bnx.apply_grants()` and the role names the harness creates);
   - any role, other than the definer, that owns objects.

   Explain each finding or call it out as a defect. The design intent is that application roles reach data only through `bnx.q_*` / `bnx.cmd_*` / `bnx.wrk_*` functions, never through direct table DML.
4. **Catalog:** `python3 tools/s4/catalog_build.py --server pg16 --db <a migrated db> --check` must report every entry matching.
5. **Release manifest:** `python3 tools/s4/release_manifest.py --check` and `python3 tools/s4/release_sign.py check-files`.

### Part C — test integrity (read; execute where you can)

1. Is any test skipped, disabled, made conditional or weakened in a way the claims above do not disclose? Search for skip markers, early returns, `if False`, empty assertions, broad `except`, and tests that assert only "no exception".
2. The harness output contract: `tests/py/harness.py` must call `jsonschema_lite.check_output` on every `bnx_app` call. Check that `tests/py/jsonschema_lite.py` behaves like the Gateway validator `apps/worker/src/schema.js`. Pick at least five schema keywords and give a case where each validator accepts or rejects, and show they agree.
3. CI (`.github/workflows/ci.yml`): `set -o pipefail` wherever output is piped; no `continue-on-error` on test steps; the same suites as Part A.
4. **Secret and SIN scans over the full history:**
   - `gitleaks git --no-banner --config .gitleaks.toml .`
   - `python3 tools/s4/sin_repo_scan.py --all-history`
   - `git log --all --name-only --format= | grep -c owner_sources` (expected 0)

### Part D — independent review of the most recent stages (read)

Review PRs #33–#37 (migrations 9034–9037: curated output schemas, enforced by the Gateway). For each schema in `db/catalog/bnx-tools-1.0.overrides.json` (`schemas.*.output`) that changed in 9035–9037, pick at least **three tools or report families**. Compare the schema against the function body it describes (the latest `create or replace function bnx.<name>` in `db/migrations`). Look for:

- a key the body always returns but the schema does not require, or the reverse (a `required` key the body can omit, for example inside `jsonb_strip_nulls`);
- a value the body can make null where the schema does not allow null, or the reverse;
- an `enum` missing a value the body or a CHECK constraint can produce;
- a pattern, such as the decimal pattern `^-?[0-9]+(\.[0-9]+)?$`, that a real value can violate (for example scientific notation or `NaN` from numeric text casts).

A schema that is too strict makes the Gateway refuse correct results (`OUTPUT_SCHEMA_MISMATCH`) in production. Treat that as a defect.

### Report

Write `docs/s4/reviews/g0/<YYYYMMDD>_<runner>/REPORT.md` with:

1. **Header.** Runner: model family, version and platform. Date. Tested SHA. Tools and versions: PostgreSQL 16/17 server and client, Python, Node, Playwright, gitleaks.
2. **Verdict table:**

   | Gate | Verdict | Grade |
   |---|---|---|
   | A regression PG16 | PASS / FAIL / PARTIAL | grade |
   | A regression PG17 | … | … |
   | A black-box, PWA, simulation | … | … |
   | B migrations | … | … |
   | B privileges | … | … |
   | B catalog / manifest | … | … |
   | C test integrity | … | … |
   | C scans | … | … |
   | D schema review | … | … |

   Verdicts are PASS, FAIL or PARTIAL; grades are as in rule 6.
3. **Findings.** Number them `G0-IND-01`, `G0-IND-02`, …. Each has: severity (blocker, major, minor, note), file:line, what you saw, why it matters, and how to reproduce (a command or SQL). Do not fix code.
4. **Differences from the author's claims**, if any, with the numbers.
5. **What you could not do, and why.**

Put raw outputs (the `*.txt` files of Part A, your SQL and its output) in a `raw/` folder beside `REPORT.md`. Keep the total under about 20 MB. Raw outputs must contain no SIN-shaped values; the suites do not print them. Scan your folder with `python3 tools/s4/sin_repo_scan.py` before you commit.

### Return the result

- **R1 (you can push):**
  1. Create branch `review/g0-<runner>-<YYYYMMDD>` from the tested commit.
  2. Commit only your report folder.
  3. Push, and open a **draft** PR into `s4/g0-remediation-2`, titled `G0 independent run — <runner> — <date>`.
  4. Put the verdict table in the PR body.
- **R2 (you cannot push):** reply with the full `REPORT.md` in one fenced block, and list the raw files you produced, with their most important lines. The Owner will hand this to the author's next session, which commits it unchanged under your runner id.
