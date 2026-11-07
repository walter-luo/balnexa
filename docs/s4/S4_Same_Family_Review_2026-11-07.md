# Balnexa S4 — same-family review of PR #1–#4 and its disposition (2026-11-07)

| Field | Value |
|---|---|
| Reviewer | Claude Fable, run as a separate agent (Owner decision of 2026-11-07). It saw the diff and the V1.2 design but not the author's reasoning, and read the implementation notes only at the end, to check what was already disclosed |
| Independence | **Same vendor and model family as the author.** Not an independent review; nothing here is `VERIFIED_INDEPENDENT` |
| Method of the reviewer | Read the high-risk files. Built a throwaway database (PG16) with the full chain and a synthetic household, entering through the production functions. Probed the runtime roles, OAuth, MCP, drafts/plans/worker and the audit chain. Ran negative tests of `audit_privileges()`. All of this ran in a disposable local cluster |
| Result | No P0. 3 × P1, 6 × P2. All are accepted and fixed in the PR where the code originates, each fix with a regression test (`AUTHOR_RUNTIME_EVIDENCE`). **Correction (2026-11-07):** this record first called finding 4 fixed when only the chunk stage was. It is complete since F-C4-21, whose test passes |

## Findings and disposition

| # | Sev | Finding (reviewer, condensed) | Verdict | Fix | PR | Test |
|---|---|---|---|---|---|---|
| 1 | P1 | The plan path accepted economic types the direct path refuses (`opening_balance`, `correction_*`, `interledger_transfer`). A member with `can_post` could post an opening balance through a self-approved draft, outside the anchor logic | Confirmed | `plan_create` refuses `opening_balance`, `correction_reversal`, `correction_replacement`, `interledger_transfer` and `clearing_resolution`. `wrk_post_plan_chunk` refuses them again before posting (`PLAN_ITEM_TYPE_FORBIDDEN`) | #4 (9010), #3 (9008) | AT-REV-01-07 |
| 2 | P1 | `cmd_draft_revise` stored the caller's item verbatim. Two consequences: an item without a description stuck the plan in `approved`; a forged `clearing_open` and a caller-supplied amount produced a 999,999 clearing item behind a 1.00 expense | Confirmed | `plan_create` rebuilds every item from an allowlist of keys. A non-empty description is required. `clearing_open` is accepted only on `handoff` plans, and those are created only by `cmd_handoff_import` (`cmd_create_import_plan` no longer accepts kind `handoff`). A typed item's amount is computed from its plan-account line. `cmd_withdraw_plan` also accepts `approved`, so a plan that has not started cannot get stuck | #4 | AT-REV-01-07 |
| 3 | P1 | `cmd_approve_plan` accepted an approval without `plan_hash`/`scope_digest`: R1 compared with `<>`, so missing keys gave NULL and the check passed | Confirmed (inherited from R1, re-issued by 9010) | `is distinct from` | #4 | AT-REV-01-07 |
| 4 | P2 | At execution, the approver's authority was re-checked only on the plan account, not on the other line accounts | Confirmed | Two stages. (1) Chunk: `wrk_post_plan_chunk` checks every household account on the remaining typed lines and suspends on failure (#3, 9008). (2) Activation, F-C4-21 (Owner decision 2026-11-07, Option A): `wrk_activate_plan` MODIFY in 9010 re-checks every account of every typed item, posted or not, under `FOR SHARE` locks; a revocation suspends the plan and voids the batch, so its journals never become visible. Stage 2 was missing until F-C4-21; the earlier text of this row described stage 1 only | #3 (9008), #4 (9010) | AT-REV-01-07 (chunk, after-seal, rollback, two races, R1 path) |
| 5 | P2 | An AI draft could reference accounts outside the connection's consent subset, through typed lines | Confirmed | `plan_create` requires every household account line to be visible to the caller (`actor_visible_acs`); applies to every channel | #4 | AT-REV-01-07 |
| 6 | P2 | Audit envelope values were validated only in `resolve_actor`. Worker and authn sessions could set the GUCs directly | Confirmed | `envelope_value()` enforces the same rule (≤ 100 printable characters) at `audit()` | #2 (9005) | AT-CMD-06x |
| 7 | P2 | `audit_privileges()` did not see column-level grants or bnx-owned objects in schema `public` | Confirmed | New rules `RUNTIME_COLUMN_PRIVILEGE`, `BACKUP_WRITE (COLUMN)`, `PUBLIC_SCHEMA_OBJECT` | #1 (9002) | AT-MIG-09 |
| 8 | P2 | (a) The installer self-revoke in B002 does not remove the ADMIN-only membership, so a non-superuser installer can grant itself SET again. (b) B002 could not be re-run by that installer. (c) The fresh-install order must be B001 → B002 → migrations | (a) Accepted residual of F-C1-01 option a (Owner decision 2026-11-05): ADMIN is what the installer needs for its later role steps. `audit_privileges()` reports any SET/INHERIT membership whenever it runs (AT-MIG-11b). (b), (c) Confirmed | B002 re-run guard (no-op when all its schemas and roles exist). The order is documented in the B002 header | #1 (B002) | AT-MIG-11b |
| 9 | P2 | OAuth DCR/CIMD (not routed yet): the caller chose `environment`, and could overwrite the `redirect_uris` of an existing CIMD client | Confirmed | Environment derived from `household_setting.data_class` (loopback only on a `synthetic` instance). An existing client is never overwritten; an identical CIMD re-registration is idempotent. Fetching CIMD metadata from the `client_id` URL remains Gateway work for when the route is enabled | #3 (9009) | BB-OAUTH-03 |

## Areas the reviewer checked and found sound

- Runtime roles cannot `SET ROLE` to or inherit `bnx_definer`, and hold no table privileges; EXECUTE grants match function prefixes exactly.
- OAuth: code replay (including concurrent), refresh rotation and reuse revoking the connection, exact redirect match, PKCE S256.
- `require()`/`calling_function()`: the innermost `bnx.(cmd|q)_` frame wins; unlisted functions fail closed; tier ≥ 2 is refused on MCP.
- Plans: approval while held is refused; state transitions are serialised by `FOR UPDATE`; no double posting.
- Lease and staging: one completion per nonce, expiry, kind binding, size cap; `bnx_stager` cannot reach `wrk_`/`cmd_`.
- Audit chain: v1/v2 boundary, forged v2 row, TimeZone independence, UPDATE/DELETE refused; `bnx_app` envelope injection neutralised.
