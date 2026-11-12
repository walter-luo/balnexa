# Balnexa (账知家) — S4 Platform Handoff — 2026-11-12

**Status:** `DRAFT — AI-generated`. It becomes authoritative once the Owner confirms it.

**Purpose:** let any development platform (another AI coding agent, another model family, or human developers) continue Balnexa without this session's context. It supersedes, as the entry point, the earlier handoffs:
- `Balnexa_S4_Session_Handoff_2026-11-11.md`;
- `…_2026-11-12_9016.md`;
- `…_2026-11-12_CORE7_CORE8.md`.

Those stay valid as history and are kept in the claude.ai Project "Balnexa - Development II".

## 0. Reading order for the new platform

1. This document: rules, environment, conventions and first steps.
2. `02_Balnexa_S4_Status_and_Plan_2026-11-12.md`: where things stand and what comes next.
3. `01_Balnexa_S4_Design_and_Development_Compendium_2026-11-12.md`: what is built and why. The appendices list every migration, decision, limit and test.
4. The per-stage notes in `docs/s4/S4_*_Implementation_Notes.md`, for the stage you touch.
5. The design package (V1.2), which is Owner-private: see §4.

## 1. Owner, governance, delegation

- **Owner:** Walter Luo. He writes in Chinese or English; reply in the language he writes. Repository files, documents, commits and PR bodies are in **English**.
- **Governance:** AI-generated content is a DRAFT until the Owner confirms it. Requirement authority order (V1.2):

  > Delta 2026-11-03 + Addendum 2026-11-05 > Amendment 03 §2 > Amendment 02 + seed > Owner Requirements Book V1.2 > Baseline V1.2.

- **Delegation history (verbatim).** Each one applied to the stage it was given in. None lifts the constraints in §2.

  | Date | Instruction | Meaning |
  |---|---|---|
  | 2026-11-11 | "AI替我做主回答问题" | "AI answers the questions for me" |
  | 2026-11-12 | "接手后一步做到底，需要owner决定的由你深思决定" | "Once you take over, carry it through in one go; think carefully and decide what needs an Owner decision" |
  | 2026-11-12 | "你做出判断和决定，继续推进开发直至完成" | "Make the judgments and decisions; keep developing until it is complete" |

  Decisions taken under these are tagged `DELEGATED_DECISION` in the stage notes.
- **Current state:** the Owner paused development on 2026-11-12 at 11:54 ("开发暂停", "development paused"). Do not start new development until the Owner resumes it on the new platform.

## 2. Standing constraints (all in force)

1. Never store or display a SIN or any other government identification number: not in files, logs, test data, evidence, commit messages or responses. Tests build SIN-shaped values at run time only (`tests/py/sin_corpus.py`). CI and guard C6 reject any Luhn-valid 9-digit run in tracked files and history.
2. **Synthetic data only.** No real financial, tax or personal data.
3. Owner-private sources are **never committed or linked** from the repository: `requirements/owner_sources/`, the S3 package, Design Inputs B, Draft-04 and review ZIPs. CI fails on any `owner_sources` path in the history.
4. Before every push, both must be clean:
   - `gitleaks git --no-banner .`
   - `python3 tools/s4/sin_repo_scan.py --all-history`
5. **No merge to `main` by a developer or agent.** The Owner merges. The one-time override for #5–#8 on 2026-11-11 is not standing.
6. No cloud resources, deployment or spend (gate O-7). No real data or production (O-8).
7. No change to gates O-8 or G-CRA-1. **9014 (Tax Core and SIN custody) must not start without an explicit Owner decision.**
8. No irreversible action without the Owner. Do not delete `s4/*` branches unless asked.
9. A committed migration is never edited: changes are MODIFYs in a new migration.

## 3. Repository

- **Remote:** `https://github.com/walter-luo/balnexa` (public; Apache-2.0).
- **`main`:** `fff6db5`. It contains R1 + CORE-1…6, 9011, 9012, 9013 and 9016 (PRs #1–#8, merged).
- **Open draft PRs:**

  | PR | Head → base | Head SHA | Stage |
  |---|---|---|---|
  | #9 | `s4/core-7` → `main` | `2ff0591` | Gateway, 9017 |
  | #10 | `s4/core-8` → `s4/core-7` | `74f97fa` | Executor, 9018 |
  | #11 | `s4/core-9` → `s4/core-8` | `6d4d138` | PWA, 9019 |
  | #12 | `s4/core-10` → `s4/core-9` | `123c113` | handoff screens and audit trail, 9020 |
  | #13 | `s4/aih` → `s4/core-10` | `f2cddc7` | OAuth for AI hosts, MCP server, 9021 |
  | #14 | `s4/aih-4` → `s4/aih` | `1db6445` | confirmation card, 9022 |
  | #15 | `s4/aih-r` → `s4/aih-4` | `6571164` | review remediation, 9023 |
  | (to open) | `s4/handoff` → `s4/aih-r` | see branch | this handoff set |

- **Merge procedure (Owner):** merge #9 into `main` with a merge commit. Retarget #10 to `main`; GitHub does this automatically if the merged head branch is deleted, but branches are kept by policy, so retarget manually. Repeat for each PR in order.
- **Other branch:** `s4/design-addendum-a1` holds Design Addendum A1 Rev 1 and the Owner decisions of 2026-11-10, referenced by 9011. Keep it.
- **GitHub API notes from the previous platform:** GraphQL was blocked by the session proxy, so REST worked (`gh api repos/walter-luo/balnexa/...`). Draft → ready was done with REST.

## 4. Sources outside the repository (re-attach on the new platform)

| Source | Identity | Used for |
|---|---|---|
| S4 Unified Architecture V1.2 package | `Balnexa_S4_Unified_Architecture_V1.2.zip`, SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f`. Contains the UA, the AIH, CRA, DL, SI, IL and AE contracts, the WP matrix, the test register, the migration register, the disposition, the Owner decision register and the traceability CSVs. | Design authority; WP rows; test IDs |
| S3 reconciliation package | `Balnexa_S3_Reconciliation_V1.0.zip`, SHA-256 `8d2ceab547bc92d1e3d5496de1c089b57be0b3a03edf4f4b077f32f961a4fdd0`. Includes Design B Draft-04 (UA SHA-256 prefix `4ad49225`) and `verify_ai_entry.py`. | Draft-04 references; **ENT-1 verifier** |
| Design Inputs B | `Balnexa_S4_Design_Inputs_B_2026-11-11.zip`, SHA-256 `5bb061b0993877d2ba4c0dc6284793ee8ac1449bce271e07261447be18ee7a2f`. Includes `requirements/`: Owner Requirements Book V1.2, amendments and owner sources. | Requirements |
| 9011 same-family review | `Balnexa_9011_review_SAME_FAMILY_2026-11-11.zip`, SHA-256 `4e01c441b741eee0dcd82f7fed49d5a3cdea7834a2621563faba86756247a05a` | 9011R history (case builders are vendored in `tests/py/review9011/`) |
| Registry seed | `institution_registry_seed_V1.0.json`, SHA-256 `263a4bef4c23b502c11fca979eefc56be404660b261b4d053c9a381a22f8c7bc` | regenerating the 9006 seed SQL (`tools/s4/gen_registry_seed_sql.py`) |

Unpack these outside the repository working tree. Never `git add` them.

## 5. Environment recipe

The authoritative recipe is `.github/workflows/ci.yml`; this section reproduces it locally.

### 5.1 PostgreSQL 16 and 17

- **Source:** PGDG apt (`postgresql-16`, `postgresql-17`). Where PGDG is unreachable, the previous platform used the distro PG16, plus PG17 from npm `@embedded-postgres/linux-x64@17.11.0-beta.19` copied to `/opt/pg17`, run with `LD_LIBRARY_PATH=/opt/pg17/lib`.
- **Clusters:** `tests/py/harness.py` expects exactly these sockets and ports:

  ```bash
  for V in 16 17; do
    D=/var/lib/postgresql/ci$V; S=/var/lib/postgresql/bnx$V
    sudo install -d -o postgres -g postgres -m 0755 "$D" "$S"
    sudo -u postgres /usr/lib/postgresql/$V/bin/initdb -D "$D/data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8
    sudo -u postgres /usr/lib/postgresql/$V/bin/pg_ctl -D "$D/data" -o "-p 554$V -k $S -c listen_addresses=" -l "$D/server.log" -w start
  done
  ```

- **Restarts:** remove stale `.s.PGSQL.*` socket files first. Clusters were found stopped between sessions; check `postmaster.opts` for the exact start options.
- **Backup tests:** `pg_dump`/`pg_restore` of the same major are needed. The previous platform skipped them for PG17 locally (3 SKIPs); CI ran them.

### 5.2 Tools

- **Python 3.12** (CI; 3.13 also works):

  ```bash
  pip install "psycopg[binary]==3.2.3"
  pip install --require-hashes --only-binary=:all: -r apps/executor/requirements.txt
  ```

- **OS packages:** `tesseract-ocr`, `tesseract-ocr-eng`, `strace`, `age`.
- **Node 22:**
  - `npm ci` in `apps/worker`;
  - `npm ci` in `tests/pwa`;
  - `npx playwright install --with-deps chromium` (Playwright 1.63.0 pinned; or point `PLAYWRIGHT_BROWSERS_PATH` at an existing Chromium).
- **Secret scan:** gitleaks 8.21.2 (CI uses the container `ghcr.io/gitleaks/gitleaks:v8.21.2` with `.gitleaks.toml`).

### 5.3 Full regression (sequential; never two database suites at once)

```bash
# usage: regrun.sh <worktree> <outdir>
W="$1"; S="$2"; cd "$W"; rm -f "$S/done"; mkdir -p "$S"
for srv in pg16 pg17; do
  python3 tests/py/run_g0.py --server $srv --evidence $S/ev/$srv/run_g0 > $S/$srv.run_g0.txt 2>&1
  for f in tests/py/run_s4_core*.py; do n=$(basename $f .py)
    python3 $f --server $srv --evidence $S/ev/$srv/$n > $S/$srv.$n.txt 2>&1; done
done
BNX_PY="$(which python3)" node --test tests/blackbox/api.test.mjs tests/blackbox/unit.test.mjs > $S/blackbox.txt 2>&1
node tests/sim/dispatch_sim.mjs > $S/sim.txt 2>&1
for srv in pg16 pg17; do (cd tests/pwa && BNX_SERVER=$srv BNX_PY="$(which python3)" node --test --test-concurrency=1 pwa.test.mjs) > $S/pwa_$srv.txt 2>&1; done
echo DONE > $S/done
```

**Expected at `6571164`:**

| Run | Expected result |
|---|---|
| PG16 database suites | 179 PASS / 0 FAIL / 0 SKIP |
| PG17 database suites | 176 PASS / 0 FAIL / 3 SKIP (local, no `pg_dump` 17); in CI 179/0/0 |
| Black-box and unit | 32 |
| PWA | 19 per major |
| Simulator | PASS |

Pass `--evidence` outside the repository. The default evidence path is `EVIDENCE/s4_coreNN/…`, which is not committed for stages after core4.

## 6. How a stage is built (conventions)

1. **Branch:** `s4/<stage>` from the top of the current stack. Open a **draft** PR against that branch.
2. **Migration** (when needed): `db/migrations/90NN_s4_<topic>.sql`.
   - Expand-only. Start with `set role bnx_definer;` and end with `select bnx.apply_grants();`.
   - A header comment lists NEW and MODIFY objects and the authority.
   - A MODIFY repeats the previous body and marks every changed line with `-- 90NN`.
3. **Catalog:**
   - every new `q_`/`cmd_` function needs a catalog entry;
   - add names and descriptions to `db/catalog/bnx-tools-1.0.overrides.json`;
   - add empty `@@CATALOG-BEGIN`/`@@CATALOG-END` markers to the new migration;
   - create a migrated database and run `tools/s4/catalog_build.py --server pg16 --db <db> --write`, then `--check`.

   The tool refuses to write when the newest migration lacks markers.
4. **Register new objects:**
   - `bnx.table_class`;
   - `flag_enforcement_point` with `trg_scope_flag` for module-scoped tables;
   - `bnx.function_scope` for anything AI-callable;
   - the AT-INV-01 `HELPERS` list in `tests/py/run_s4_core1.py`.
5. **Schema range:** bump `apps/worker/src/release.js` (`version`, `supports_schema.extension` = [N-1, N]) and the mocks in `tests/blackbox/unit.test.mjs` and `tests/py/sin_worker_guard.mjs`. Bump `sw.js` `VERSION` when PWA files change.
6. **Tests:** add `tests/py/run_s4_coreNN.py` (same structure as core17) and/or black-box and PWA tests. Build any SIN-shaped value at run time.
7. **Notes:** write `docs/s4/S4_<STAGE>_Implementation_Notes.md` with status, evidence grade, authority, what was built, decisions (`D-<STAGE>-n`), tests and limits (`L-<STAGE>-n`, each with a follow-up).
8. **Before pushing:** full regression (§5.3), gitleaks, SIN scan.
9. **Commit** with a clear English message. The previous platform used:
   - author `Claude (Balnexa CORE-1) <noreply@anthropic.com>`;
   - trailer lines `Co-Authored-By:` and `Claude-Session:`.

   A new platform uses its own attribution.
10. **PR body:** what changed, decisions, tests, the local regression and CI results, and the merge order.
11. **Independent review** when the change is security-relevant: write `docs/s4/reviews/<STAGE>_REVIEW_PROMPT.md`, have a fresh reviewer run it read-only, and record the disposition in `docs/s4/S4_<STAGE>_Review_Remediation_<date>.md`.

**Evidence-grade vocabulary:**

| Grade | Meaning |
|---|---|
| `AUTHOR_RUNTIME_EVIDENCE` | the author ran it |
| `SAME_FAMILY_VERIFICATION` | an independent agent of the same model family |
| `VERIFIED_INDEPENDENT` | an independent runner of another family or a human; only this counts for gates |
| `NOT_EXECUTED` | not run |

## 7. Known pitfalls (learned the hard way)

- **PL/pgSQL:**
  - `text[] || 'lit'` is array concatenation; use `array_append`.
  - Variables that clash with column names cause errors (e.g. `role` in `q_audit_trail`; renamed `rl`).
  - CHECK passes on NULL: wrap in `coalesce(…, false)`.
  - Regex repetition is capped at 255.
  - `jsonb_agg(x order by …)`.
  - Composite `IS NOT NULL` is true only when every field is non-null.
- **Audit guard C2 refuses digit runs in audited payloads.** Idempotency keys, OAuth `state` and similar client values must never reach `bnx.audit` raw. The Gateway normalizes keys to letters, and `state` stays at the Gateway.
- **catalog_build `--write`** once rewrote an older migration's block. It is now guarded; still check `git status` after `--write`.
- **CI pipes:** keep `set -o pipefail` and `rc` accumulation. A failing suite was once hidden by `| tee`.
- **Tests:**
  - **PWA navigation:** after a navigation to a blocked external URL the page shows an error document, so continue in a fresh page.
  - **PWA hidden elements:** `[hidden]` needs `display:none !important` against component CSS.
  - **Black-box API:** `fetch` follows redirects unless `redirect: 'manual'` is set.
- **PGDG mirror sync** occasionally breaks `apt-get update` in CI. The cause is the apt index, not the code; one re-run is allowed.
- **Black-box rate limits:** DCR is limited per `cf-connecting-ip`, so tests pass a distinct address per registration.

## 8. Document map

| Location | Documents |
|---|---|
| `docs/s4/handoff/` | 01 compendium, 02 status and plan, 03 this handoff |
| `docs/s4/` | stage notes CORE1–4, 9011a, 9011R, 9012, 9013, 9016, CORE7–10, AIH, AIH4, AIH review remediation; Owner decisions and waiver; G0 remediation; PR review guide; same-family review 2026-11-07 |
| `docs/s4/reviews/` | 9011 review prompts; AIH review prompt and report |
| `apps/*/NOT_IMPLEMENTED.md` | per-component gaps with their owning milestone and acceptance tests |
| claude.ai Project "Balnexa - Development II" | session handoffs 2026-11-11, 2026-11-12 (9016), 2026-11-12 (CORE-7…AIH review), and copies of 01–03 |
| Owner storage (not in the repository) | V1.2 package, S3 package, Design Inputs B, review ZIPs, registry seed (§4) |

## 9. First steps on the new platform

1. Clone the repository. Check out `s4/handoff` (or `s4/aih-r` if the handoff PR is merged). Check that the head SHAs in §3 match.
2. Re-attach the §4 packages outside the working tree and check their SHA-256 values.
3. Build the environment (§5). Run the full regression and compare it with the expected results.
4. Read 02 §6, then ask the Owner which phase to run. Until the Owner resumes development, do not change code.
5. If the Owner has merged the stack, base new work on `main`; otherwise stack on the top branch.

### Suggested first message to the new platform (edit as needed)

> Continue Balnexa S4 from `walter-luo/balnexa`. Read `docs/s4/handoff/03_Balnexa_S4_Platform_Handoff_2026-11-12.md` first, then 02 and 01. All constraints in 03 §2 apply (no SIN, synthetic data only, no merge, no cloud, 9014 blocked). Rebuild the PG16/PG17 environment per 03 §5 and run the full regression; report the result against the expected totals. Then propose the next phase from 02 §6 and wait for my decision.
