# G0 independent re-run (R2) 2026-11-13 — disposition and remediation

`DRAFT — AI-generated` (the author: Claude). Report: `docs/s4/reviews/g0/20261113_chatgpt-codex-r2/REPORT.md`. Runner: GPT-5 Codex, graded `VERIFIED_INDEPENDENT`; the PWA run is `NOT_EXECUTED`. Code under test: `109a6c7` (top of #39). Remediation: branch `s4/g0-remediation-2` (PR #40), migration **9039**, release **0.9.5-p2**.

## Summary

| Finding / observation | Reviewer | Author's verdict | Action |
|---|---|---|---|
| R2-01 PG17 drill fails (`'migration runner exit 1: '`, `HEADER_FACTS_DIFFER`) | blocker | **Confirmed as a defect, but not PG17-specific and not a header difference.** The drill provisioner ran the migration runner as a bare `python3` from `PATH`. In the reviewer's PG17 shell that interpreter evidently lacked `psycopg`. Reproduced exactly on PG16 | Executor: the runner uses the Executor's own interpreter; the failure reason names the exception class |
| `HEADER_FACTS_DIFFER` in the same result | (part of R2-01) | **Confirmed database defect.** The result had no restored header. The guard `jsonb_typeof(x) <> 'object'` is NULL, not true, for an absent field, so `NO_RESTORED_HEADER` never fired | Fixed in 9039 |
| Same pattern elsewhere (author's audit after R2-01) | — | Five more functions accepted an absent field. Each one was probed and confirmed | Fixed in 9039 |
| Other gates (B, C, D) | PASS | Agreed | none |
| PWA not executed | limitation | Environment: the Playwright CDN was blocked | none; local runs and CI cover it |

## R2-01 — what failed, and why

**The reviewer's reading.** The reviewer read the result as a PG17 restore whose header facts differ from the backup's. It noted that the exact differing key was not visible.

**The actual cause** has two parts.

1. **The drill target was never built.** `LocalProvisioner.create` (`apps/executor/bnx_exec/restore.py`) started `db/tools/run_migrations.py` with the command `["python3", …]`. That resolves `python3` on `PATH`. The runner imports `psycopg` on its first line. An interpreter without it exits 1 with a traceback on stderr and nothing on stdout. The provisioner reported only stdout, so the reason became `migration runner exit 1: ` with nothing after the colon. Every other refusal of the runner has its own exit code (2–7) and a stdout line, so exit 1 with empty stdout can only be an uncaught Python error before any output.
2. **The database mislabelled it.** The job reports no `restored_header` when it fails before the restore. The promoter `bnx.wrk_restore_drill_recorded` (9016) tested `if jsonb_typeof(pl->'restored_header') <> 'object'`. For an absent key that expression is NULL, so PL/pgSQL takes the `else` branch. It then compared the backup header with NULL and recorded `HEADER_FACTS_DIFFER`, with a meaningless mismatch list. The outcome was still FAIL, so no drill could pass wrongly. Only the reason was wrong, and it pointed the reviewer at a header difference that did not exist.

**Evidence.**

- *Exact reproduction on PG16.* The author ran `run_s4_core15.py --server pg16` with the venv's Python, and with `PATH` limited to `/usr/local/bin:/usr/bin:/bin`, where `python3` has no `psycopg`. The result was `FAIL AT-BKP-DRILL-EXEC … ('FAIL', ['migration runner exit 1: ', 'HEADER_FACTS_DIFFER'], 'drill-k2a', True)`. That is the reviewer's line, character for character, on the other major.
- *PG17 itself is fine.* CI job `db-tests (17, c)` on the same commit `109a6c7` (run 43463139046) ran with server and `pg_dump` **17.12** and logged `PASS AT-BKP-DRILL-EXEC`. That run executed the drill; it was not the local skip. CI installs `psycopg` into the `python3` on `PATH`, which is why the defect never showed there.
- *Inference, not verified.* The reviewer's PG16 lane passed, apparently because that shell had the locked dependencies on `PATH` (its report mentions corrected PG16 runs with "the locked executor Python dependencies"). The `raw/` folder that would show this was not relayed.

**Fix (Executor).**

- The provisioner runs the migration runner with `sys.executable`, the interpreter the Executor itself runs under, never a `python3` found on `PATH`.
- When the runner fails without stdout, the reason names the exception class from the last stderr line, such as `ModuleNotFoundError`. It never includes the message, which can quote a DSN or row values.

**Fix (database, 9039 MODIFY `bnx.wrk_restore_drill_recorded`).** The guard is now `is distinct from 'object'`, so a result without restored header facts is `NO_RESTORED_HEADER`.

## The same defect class elsewhere — audit and fixes (9039)

The author searched every migration for guards of the form `jsonb_typeof(…) <> '…'`, and for `->>` / `#>>` values compared with `<>` or `not in`. For each guard, the author checked whether the operand can be SQL NULL, meaning an absent key and not JSON `null`. The latest definition of each function was checked. Guards protected by `?`, `is null`, `coalesce` or an earlier `is distinct from` were cleared. So were values that come from `jsonb_array_elements`, which never yields SQL NULL. Each remaining candidate was **probed** on PG16 with a synthetic input:

| Function (latest) | Input probed | Before 9039 | After 9039 |
|---|---|---|---|
| `wrk_restore_drill_recorded` (9016) | drill result without `restored_header` | FAIL, `HEADER_FACTS_DIFFER` | FAIL, `NO_RESTORED_HEADER` |
| `wrk_backup_recorded` (9016) | backup header without `format` | **promoted, run VERIFIED** | REJECTED `HEADER` |
| `wrk_backup_recorded` (9016) | backup header without `audit_head` | (same guard) | REJECTED `HEADER` |
| `wrk_evidence_state` (9016) | EVIDENCE_VERIFY result without `items` | promoted, "verified 0" | REJECTED `ITEMS` |
| `install_activate_config` (9029) | `worker_supports_extension: []` | **configuration ACTIVE; B3 range check skipped** | `BNX_BINDING_MISMATCH` B3; the range must be exactly two 4-digit versions |
| `plan_create` (9010), through `create_import_plan` | command without `items` | **empty plan created** | `VALIDATION_FAILED` items |
| `cmd_create_account` (9006) | command without `currencies` | **account with no currency created** | `VALIDATION_FAILED` account |
| `cmd_create_account` (9006) | command without `kind` | (same guard pattern) | `VALIDATION_FAILED` account |

**Reachability.** The two commands are reachable by an authenticated household member through `POST /api/v1/commands/…`. Their derived catalog input schemas are permissive (no `required`), so the Gateway passes such a body to the database, and the database is the only validator. The promoters need an Executor lease, and the activation needs the installer role. Those are trusted paths, but the database is meant to be the authority on them too.

Every changed line in 9039 is marked `-- 9039`, and the rest of each body is the latest definition unchanged. 9039 makes no catalog change and no data change.

**Residual (not done here).** The audit was a pattern search plus probes. It was not a proof over every expression. A systematic check, such as calling every `cmd_*` with each top-level key removed in turn, would give stronger assurance. It is listed as follow-up **L-R2-1**.

## Tests (each fails without the fix and passes with it)

| Test | New check |
|---|---|
| AT-BKP-DRILL-EXEC (core15) | The drill runs with a decoy `python3` placed first on `PATH`; the decoy always fails. Also checks the exception-class-only reason |
| AT-BKP-DRILL (core13) | A result without restored header facts gives `NO_RESTORED_HEADER` and not `HEADER_FACTS_DIFFER` |
| AT-BKP-REC (core13) | A header without `format`, or without `audit_head`, is REJECTED `HEADER` |
| AT-BKP-10 (core13) | An EVIDENCE_VERIFY result without `items` is REJECTED `ITEMS` |
| AT-DPL-01 (core18) | Five malformed worker ranges are refused with B3 |
| **AT-NULL-01** (core18, new) | Plan with `items` absent, null or `[]`, and account without `currencies` or `kind`: each gives `VALIDATION_FAILED` and stores nothing |

The author ran the new checks against the old code first (9039 removed, the old `restore.py`) on PG16. AT-BKP-REC, AT-BKP-DRILL, AT-BKP-10, AT-BKP-DRILL-EXEC, AT-DPL-01 and AT-NULL-01 all failed. All pass with the fix.

Counts: one new test (AT-NULL-01), so the Python suites have 196 tests per major. The total with `pg_dump` 17 becomes **474**.

## What the next re-run should show

In the reviewer's environment, `AT-BKP-DRILL-EXEC` should now pass on PG17 whichever `python3` is first on `PATH`. The other expected figures are in the updated prompt: 196 per major, 35 Node, the simulation, and 23 PWA per major where a browser is available. That is 474 with `pg_dump` 17, under either collation.
