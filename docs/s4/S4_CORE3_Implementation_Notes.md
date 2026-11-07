# Balnexa S4 — Increment 3 (9008, 9009) — Implementation Notes V1.0

| Field | Value |
|---|---|
| Design baseline | `Balnexa_S4_Unified_Architecture_V1.2.zip`, SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f` (S5 waived by the Owner) |
| Builds on | branch `s4/core-2` (PR #2, stacked on PR #1) |
| Scope | 9008 economic-type rules and chunked plan posting; 9009 OAuth fixes, refresh tokens, DCR/CIMD, catalog scopes and the legacy scope boundary; dispatcher and token-endpoint changes in the Worker; suite `tests/py/run_s4_core3.py` |
| Not in this increment | 9010 (intake, drafts, validations, approval holds, lease/staging) and later |
| Data | synthetic only, local disposable clusters |
| Evidence grade of every PASS | `AUTHOR_RUNTIME_EVIDENCE` |

## 1. What was built

| Item | Content | Design reference |
|---|---|---|
| 9008 | `economic_type_rule` (26 rows from Draft-04 B6.1: line pattern, extras, flow_class, budget/R09 effect); `t_economic_type_rule` deferred SECURITY DEFINER constraint trigger on `journal_entry` (restore-aware; leaves incomplete/unbalanced journals to the R1 completeness trigger); `economic_type_check()` re-judging tool (`NOT_APPLICABLE` before the activation version); `rule_activation_version('economic_type_rule')`; `wrk_post_plan_chunk` MODIFY (chunk size from `plan_chunk_size`, default 200; typed items; deterministic typing of untyped R1 items; `PLAN_ITEM_UNTYPED`); `posting_batch_chunk` log | UA §5.3.4, §5.5.5; S4B-F12/F15 |
| 9009 | `authn_oauth_token` MODIFY (NULL fail-closed; single-use `UPDATE … RETURNING`; replay revokes tokens; resource audience; refresh issuance); `authn_oauth_refresh` (30-day sliding rotation; reuse revokes the connection); `authn_oauth_revoke` (RFC 7009); `authn_register_client` (DCR/CIMD against `host_profile_redirect` allowlists); `cmd_approve_ai_connection` MODIFY (catalog scopes only; subsets; `SUBSET_REQUIRED`); `cmd_revoke_ai_connection` MODIFY (owner-scoped token revoke); `ai_connection.scopes` CHECK replaced; `legacy` / `refresh_eligible` generated columns; `ai_connection_subset`; `require()` MODIFY with the `function_scope` catalog; `snapshot_decision()` MODIFY | UA §7.2; AIH §4; S4B-F09; CROSS-02 |
| Worker | `dispatch.js`: continues a plan returning `executing` up to 4 chunks per item and tick, then re-queues; `index.js`: `/oauth/token` accepts `refresh_token` grants and maps returned `{error}` to HTTP 400 | UA §5.5.5, §7.2 |

## 2. Results (raw output in `EVIDENCE/s4_core3/`)

| Suite | PG16 16.15 | PG17 17.11 (embedded-postgres beta) |
|---|---|---|
| R1 suite on B002 + 9002–9009 | 40 / 0 / 0 | 38 / 0 / 2 SKIP (no `pg_dump` 17) |
| CORE-1 suite | 12 / 0 / 0 | 12 / 0 / 0 |
| Increment-2 suite | 12 / 0 / 0 | 12 / 0 / 0 |
| Increment-3 suite | 9 / 0 / 0 | 9 / 0 / 0 |
| R1 black-box API | 7 / 7 | 7 / 7 |
| R1 dispatch simulation | PASS | — |

Increment-3 tests: AT-ECON-01-04 (9 valid patterns commit; 8 violations refused at COMMIT; R1 completeness errors keep precedence); AT-ECON-05 (a pre-9008 violating journal stays, reported `NOT_APPLICABLE`; the same journal after 9008 is refused); AT-PLAN-06,07 (5 items, chunk size 2 → `executing, executing, sealed`; nothing visible before activation, all at once after; typed from counter kind and sign; unclassifiable item → `PLAN_ITEM_UNTYPED`, chunk rolled back); AT-MUT-03 (trigger removal detected); BB-OAUTH-01x,04 (missing `client_id`/`redirect_uri` refused; two concurrent redemptions → one token issued, one `invalid_grant`, and that token revoked); AT-CMD-04x (cross-member revoke refused); BB-OAUTH-02 (refresh rotation, reuse revokes the connection, no refresh without `offline_access`, RFC 7009 revoke); BB-OAUTH-03 (DCR/CIMD allowlists, loopback only outside production); AT-AIH-13-15 (R1 connections after the upgrade: legacy read keeps balances and R-BAL snapshots only; documents, registry, unlisted functions, legacy propose, zero-subset and an F3 replay refused; no refresh for legacy; new consents cannot use legacy scopes; missing subsets refused).

## 3. Findings and decisions

Severity: **O** = Owner should confirm; **D** = design gap, choice as stated; **N** = note.

| ID | Sev | Finding | What was done |
|---|---|---|---|
| F-C3-01 | D | UA §5.5.5 records `chunk_no` in `posting_batch_event`, but that R1 table is append-only with primary key `(batch_id, event)` and a fixed event list | Side table `posting_batch_chunk(batch_id, chunk_no, posted, remaining)`; R1 table untouched |
| F-C3-02 | D | UA §5.5.5 says `wrk_post_plan_chunk` returns `{posted, remaining}`; a same-signature MODIFY cannot change the return type | Returns `executing` / `sealed` (text, R1-compatible); counts are in `posting_batch_chunk`; the dispatcher loops on `executing` |
| F-C3-03 | D | "No sign heuristic" for untyped R1 plan items | Typing from the counter ledger account kind **and** the sign (expense: outflow `consumption_expense`, inflow `refund`; income inflow `income`; clearing `transfer_to_clearing`); anything else `PLAN_ITEM_UNTYPED`. Items carrying `economic_type` (+ `lines`) are posted as given; their V-07 validation arrives with `intake_validate` (9010) |
| F-C3-04 | D | Trigger placement | On `journal_entry` only (R1 forbids lines in a later transaction, `LATE_LINE`); incomplete or unbalanced journals are left to the R1 completeness trigger so R1 error codes keep precedence |
| F-C3-05 | O → decided 2026-11-06: accepted | B6.1 gives R09 effects (`excluded`, `fee only`, `per policy`), not `flow_class` values | Mapping PROPOSAL: operating types → `OPERATING`; transfers, clearing, opening, fx → `TRANSFER`; card repayment → `CARD_REPAYMENT`; loans → `FINANCING` / `LOAN_PRINCIPAL`; investments → `INVESTING`; corrections → `CORRECTION`. The intra-household loan rule is approximated (receivable + liability legs) until R28 (9012) |
| F-C3-06 | D | Replay must revoke tokens, but raising an error rolls the revocation back | Replay (and refresh reuse) **returns** `{"error":"invalid_grant"}` after revoking; the Worker maps it to 400. A concurrent second redemption is a replay and revokes the token just issued (RFC 6749 §4.1.2): "exactly one token" refers to issuance |
| F-C3-07 | D | UA §7.2.3 places scope checks in each function prologue (`require_scope`) | Central catalog `bnx.function_scope` (function → scope, legacy allowances, subset requirement); `require()` identifies the calling function from the PL/pgSQL call stack; an unlisted function is refused on the MCP channel (fail closed). Every later migration that adds an AI-callable function must add its row |
| F-C3-08 | D | Whether new consents may still request `read`/`propose` | Refused (`VALIDATION_FAILED`); scopes are now required (R1 defaulted to `["read"]`). Only rows created under R1 are legacy |
| F-C3-09 | N | R1 tests re-baselined for the new consent rules | AT-CMD-04 (catalog scopes; replay returns the error and revokes the earlier token; evidence → `SCOPE_NOT_CONSENTED`); AT-SNAP-04 (zero-subset consent → `SUBSET_REQUIRED`); BB-OAUTH-01 (catalog scopes; earlier token revoked by the replay; fresh consent) |
| F-C3-10 | N | Worker routes `/oauth/register`, `/oauth/revoke`, `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource/*` | Not added; the database functions exist. They belong to work package AIH-1 |
| F-C3-11 | N | Loopback redirects (non-production only) | The environment is passed by the caller; there is no instance-level environment setting yet |
| F-C3-12 | N | Latent R1 test defect found during the merge regression: AT-CMD-01 forged a session token by replacing the last character with `A`, which equals the real secret about 1/16 of the time (the last base64 character of a 32-byte secret has 16 possible values), so the test failed intermittently | The forgery now always differs from the real secret; nothing skipped. Assertion unchanged |
| F-C2-04, F-C2-05, F-C2-13, F-C1-12 | — | From earlier increments | Decided 2026-11-06 (`OWNER_DECISIONS_2026-11-06.md`); F-C2-05 and F-C2-13 implemented on `s4/core-2` and merged here |

## 4. Next increment (proposed)

9010: intake schema, `intake_validate` (V-01…V-10), drafts incl. `member_draft`, `cmd_create_import_plan` / `cmd_approve_plan` MODIFY (approval holds), handoff via `transfer_to_clearing`, `exec_lease` and `stg_*` staging (Executor without posting credential). It is the largest migration of the chain and will likely be split into two increments.
