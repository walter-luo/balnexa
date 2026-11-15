# L-R2-1 NULL-guard sweep — method, result and fixes (migration 9040)

`DRAFT — AI-generated` (the author: Claude). Follow-up L-R2-1 of `docs/s4/reviews/G0_IND_R2_REMEDIATION_2026-11-13.md`. Branch `s4/null-guard-sweep`, migration **9040**, release **0.9.6-p2**. Synthetic data only.

## Why

9039 fixed six guards of the form `jsonb_typeof(x) <> 'object'`. When `x` is absent, the expression is NULL rather than true, so PL/pgSQL skips the branch. Those six were found by a pattern search plus probes. The R2 disposition listed a systematic check as the residual: call every command with each key removed in turn. This document records that check.

## Method

| Part | What it does |
|---|---|
| `tests/py/harness.py` (sweep mode, `BNX_NULL_SWEEP=<file>`) | Before every `cmd_*` / `wrk_*` call whose last argument is a JSON object, the harness first repeats the call unchanged. If that succeeds, it repeats the call once per mutation. Each repeat runs in its own rolled-back transaction. Mutations: each top-level key is removed, set to JSON null and, for a non-empty string or array, emptied. Each key of the first object in a list of objects is removed or set to null. `idempotency_key` is skipped. For `wrk_stage_completion` the staged payload is also promoted (`wrk_promote_staged`), so the promoter's checks count. A mutation that ends with the same outcome as the unmutated call counts as **accepted**. Nothing is committed, and the real call that follows is unchanged. Calls inside an open caller transaction, and calls from non-main threads (concurrency tests), are skipped. Each line records the database's migration head |
| `tools/s4/null_guard_sweep.py --server pg16 --out DIR` | Runs `run_g0.py` and every `run_s4_core*.py` in sweep mode, then aggregates. Only calls at the newest migration count; upgrade tests also call older schema versions |
| `tools/s4/null_guard_dispositions.json` | One reviewed verdict per accepted (function, key path) pair: `must_refuse`, `optional`, `fail_closed` or `limitation`, each with a reason. `_not_exercised` holds the functions that have a JSON argument but no suite sweeps, each reviewed by reading |
| Check (exit 1) | The check fails if an accepted pair has no disposition, if a `must_refuse` pair is still accepted, or if a JSON-argument function is neither swept nor reviewed by reading |
| Evidence | `EVIDENCE/null_guard_sweep/<head>/report.md` and `report.json` hold function names, key paths, modes and counts only, with no values. The raw `sweep.jsonl` is not committed |

**What it does not cover.** The sweep sees only calls the suites make. Branches that no suite reaches with a given key are not swept: for example, a staged kind under a job kind that no test leases. The `_not_exercised` list and the static reviews below cover the functions the suites never sweep. A sweep is evidence, not a proof.

## Result before the fix (head 9039)

89 functions swept; 455 (function, key path) pairs tried; 169 accepted with a key absent, null or empty. Review of the 169:

| Verdict | Pairs | Meaning |
|---|---|---|
| `must_refuse` | 15 | A defect. Fixed in 9040 |
| `optional` | 119 | A documented default or an optional field |
| `fail_closed` | 27 | Accepted, but the result is a hold, a FAIL or a later reject |
| `limitation` | 8 | Accepted for now. Listed below for Owner review |

## Result after the fix (head 9040)

All 21 suites pass in sweep mode. 455 pairs tried; 155 accepted; 0 `must_refuse` pairs still accepted; the check exits 0. Evidence: `EVIDENCE/null_guard_sweep/` (before and after).

In the dispositions file 14 pairs keep the verdict `must_refuse`, so a regression fails the check. The fifteenth, `backup_recorded` / `retain_until`, is still accepted for a FAILED backup result, which does not read the key. Its file verdict is therefore `optional`, with the reason recorded. The VERIFIED case is guarded by the AT-BKP-REC case "retention absent".

## The 15 defective pairs and the 9040 fixes

| Function | Key | What happened | 9040 |
|---|---|---|---|
| `plan_create` via `cmd_create_import_plan` | `date_from`, `date_to` | Absent or null gave an unbounded date range. The plan then claimed an unbounded scope: in the test, the next valid plan failed with `SCOPE_CLAIM_CONFLICT`. Its items also skipped the date check | `VALIDATION_FAILED` "date_from and date_to"; `date_from` after `date_to` is refused too |
| `plan_create` | `items[].transaction_date` | An item without a date passed `not between` (NULL) | `VALIDATION_FAILED` "item date outside plan range" |
| `plan_create` via `cmd_draft_create_transaction` | `lines[].currency` | A typed line without a currency passed `lac.currency <> currency` (NULL) | `is distinct from`; `VALIDATION_FAILED` "line ledger account" |
| `cmd_invite_member` | `display_name`, `google_sub` | Empty strings created a member, including an identity whose subject was `''` | `VALIDATION_FAILED`; the role check is NULL-safe too (an absent role was a raw NOT NULL error) |
| `cmd_record_ownership` | `events` | Absent or `[]` bumped the ledger version and wrote an audit entry for nothing | `VALIDATION_FAILED` events |
| `cmd_post_transaction` | `description` | An empty or blank description was posted. The plan path has refused this since 9010 | `VALIDATION_FAILED` description |
| `wrk_capacity_update` | `threshold_pct` | A `budget_notification` without a threshold was recorded with no threshold | `VALIDATION_FAILED` unless 50, 80 or 100 |
| `wrk_backup_recorded` (staged `backup_recorded`) | `retain_until` | For a VERIFIED result the retention check `null < x` was skipped. The tier's retention was stored as the object's, without evidence | `REJECTED` (`RETENTION`) |
| `wrk_doc_discovered` (staged `doc_discovered`) | `source_file_id`, `head_revision_id`, `md5`, `mail_message_id`, `mime_part` | An empty string passed the NOT NULL source-identity CHECKs (absent and null were already refused) | `REJECTED` (`VALIDATION_FAILED`) |

Every changed line in 9040 is marked `-- 9040`; the rest of each body is the latest definition unchanged. 9040 makes no catalog change and no data change.

**Tests (each fails without 9040).**

- **AT-NULL-02** (core18): 14 refused commands and worker calls, and 3 refused discovery results. Before 9040, 8 of the 14 were accepted outright. 3 more failed only with `SCOPE_CLAIM_CONFLICT`, against the unbounded claim the first accepted plan had left. 2 were refused with a raw constraint error instead of `VALIDATION_FAILED`, and 1 (`date_from` after `date_to`) was already refused. All 3 discoveries were promoted. The test checks that nothing is stored (plans, members, ledger version, capacity events, discoveries). It also runs control calls that include the field and must be accepted.
- **AT-BKP-REC** (core13): new case "retention absent", expected `RETENTION`.

## Limitations (accepted by the Owner as they are, 2026-11-15, OD-NULL-1)

| Id | Function / key | Behaviour | Why it is not changed here |
|---|---|---|---|
| L-NULL-1 | `cmd_approve_ai_connection` `resource` | No resource stores NULL, and the B7 resource check is skipped | This is the legacy connection shape, by design. Requiring a resource would change existing connections |
| L-NULL-2 | `wrk_admission_decide` sizing inputs | Absent inputs default to zero | The function is worker-trusted and has no app callers yet. Decide before admission is enforced |
| L-NULL-4 | staged `mail_fetched` `evidence_sha256`, `attachments_expected`, `attachments_fetched` | A FETCHED mail item can be recorded without a body evidence hash, and absent counts mean 0 | The column is nullable, and the update path keeps an earlier hash. Whether the hash is mandatory is a design decision |

(L-NULL-3 is the method limit above: staged kinds are swept only under the job kinds the suites lease.)

## Functions not swept, reviewed by reading

`cmd_confirm_posting_date` (an absent `posting_date` is refused, but by a raw NOT NULL error), `cmd_revoke_session` (reads no field), `wrk_ack_index_record`, `wrk_audit_sin_refusal` (NULL-safe), `wrk_onboarding_step` (free detail object). None needs a change.

## How to re-run

```
BNX_PG16="host=… port=…" python3 tools/s4/null_guard_sweep.py --server pg16 --out /tmp/sweep    # about 20 minutes
python3 tools/s4/null_guard_sweep.py --aggregate /tmp/sweep                                   # re-check after editing dispositions
```

A new migration that adds or changes a command should re-run the sweep and give every new accepted pair a disposition.
