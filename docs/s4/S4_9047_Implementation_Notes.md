# S4 9047 — statement check without storing, merge audit fix: implementation notes

`DRAFT — AI-generated` (Claude). Authoritative once the Owner confirms it.

| Field | Value |
|---|---|
| Migration | `db/migrations/9047_s4_check_statement_merge_audit.sql` |
| Authority | OD-LIVE-3 (`OWNER_DECISIONS_2026-11-16.md`, 2026-11-21 06:27); Addendum A1 Rev 1 guard C2 (SIN in audited payloads) |
| Release | V1.0-R08 (Worker range 9046–9047) |
| Tests | `tests/py/run_s4_core23.py` (AT-CHK-01, AT-CHK-02, AT-SIN-02); AT-INV-01 |

## Findings

| ID | Finding | Fix |
|---|---|---|
| F-LIVE-9 | With skill 0.3.1 loaded, Claude still sent two one-line trial drafts (both void, `BALANCE_CHAIN`) before the real one, and picked the paying account itself (marked for review) instead of asking | `fin.draft.check_statement`: the same checks, nothing stored; skill `balnexa-statement-intake` 0.3.2: "check first, then submit once", "ask, do not pick" |
| F-SIN-2 | `cmd_resolve_account_proposal` put the merge target (a UUID under `merge_into`, a key without an id token) into the audit payload; the SIN guard read it as free text and refused about 0.1% of merges at random (AT-ACP-01-08 failed once on CI pg16) | The audit payload carries the target as `merge_into_id`; the request and its idempotency hash are unchanged. `merge_into` was the only UUID-valued command key without an id token |

## What changes

1. **`fin.draft.check_statement`** (`cmd_check_statement`, tier 1, PWA and MCP, scope `finance.draft`, same accounts rule as the draft). It calls `cmd_draft_statement` with the same arguments inside a subtransaction that it then rolls back, and returns `stored: false`, `kind`, `hold_reasons`, `validation_result` and `continuity`. No draft, audit entry or idempotency record remains; a draft named in `supersedes_plan_id` stays as it was. Refusals are those of the draft.
2. **Catalog generator.** A command that hands its whole input to another command (`bnx.cmd_x(cred, cmd …)`) is treated as reading that command's keys, so the check carries the draft's curated input schema. Only the new entry changed.
3. **Merge audit** as above.

## Decisions taken here

| ID | Decision | Reason |
|---|---|---|
| D-9047-1 `DELEGATED_DECISION` | A separate tool rather than a `dry_run` flag on `fin.draft.create_statement` | The draft's output contract (plan_id, plan_hash …) stays strict; a separate name is easier for an AI to choose |
| D-9047-2 `DELEGATED_DECISION` | The check is not audited | It changes nothing; the audit chain records changes |
| D-9047-3 `DELEGATED_DECISION` | F-SIN-2 is fixed in the one command, not by exempting UUID-shaped values everywhere | The detector spec is Owner-governed (Addendum A1); the narrow fix changes no detection |

## Test method (OD-LIVE-3)

From now on the development session drives the AI side of a functional test through its own Balnexa connection (read the document, propose, check, submit, verify the posting); the Owner approves in the app. A test of how a fresh Claude conversation follows the skills is run by the Owner with a prompt the session writes.
