# Balnexa S4 — Increment 4 (9010) — Implementation Notes V1.0

| Field | Value |
|---|---|
| Design baseline | `Balnexa_S4_Unified_Architecture_V1.2.zip`, SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f` (S5 waived by the Owner, `OWNER_WAIVER_S5_2026-11-05.md`) |
| Builds on | branch `s4/core-3` (PR #3, stacked on PR #2 and PR #1) |
| Scope | migration `9010_s4_intake_drafts_validation_lease.sql` (OBJ-025, OBJ-227, OBJ-228, OBJ-376, OBJ-377); Gateway lease routes and dispatcher kind; suite `tests/py/run_s4_core4.py`; black-box test BB-EXEC-01 |
| Not in this increment | document pipeline and its promoters (9011), tax (9014), backup registry (9016); Gateway JSON Schemas per job kind; Executor jobs themselves |
| Data | synthetic only, local disposable clusters; no cloud resource, mailbox, index file, credential or real data was touched |
| Evidence grade of every PASS | `AUTHOR_RUNTIME_EVIDENCE` (author-run; nothing is `VERIFIED_INDEPENDENT`) |

## 1. What was built

| Part | Content | Design reference |
|---|---|---|
| Plans | `posting_plan` + `origin_channel`, `origin_ai_connection_id`, `created_by`, `validation_result`, `hold_reasons`, `validated_at_version`; `intake_validate(plan)` V-01…V-10 at freeze; `economic_type_violation_lines()` (B6.1 over a line set) and 9008 `economic_type_violation()` MODIFY delegating to it (one rule implementation); `plan_create()` shared by all kinds; `cmd_create_import_plan` MODIFY (kinds `import`, `handoff`, `onboarding`; typed items; 0109 behaviour kept incl. `evidence_file_ids`; `manual` and draft kinds refused); `cmd_approve_plan` MODIFY (0109 body kept: digests, scope delta, dual-copy gate; plus `PLAN_HELD:<reason>` when not validated at the frozen version or any hold is present; the V-set is re-run at approval) | UA §5.5.2–§5.5.3; S4B-F21; CROSS-03 |
| Drafts | `cmd_draft_create_transaction`, `cmd_draft_create_transfer` (both legs typed), `cmd_draft_revise` (new version, old one `superseded`, approval invalidated), `cmd_draft_validate`, `cmd_draft_withdraw`, `q_draft_get_for_confirmation`; kind `ai_draft` on the MCP channel, `member_draft` for PWA members (approved by a member with `can_post`); `q_review_queue`; `cmd_validate_plan` / `cmd_withdraw_plan` (F-C4-09); MCP catalog rows (`finance.draft`; legacy `propose` reaches create / confirmation view / withdraw only) | UA §5.5.1–§5.5.2; AIH §2 |
| Executor lease and staging | `bnx.exec_lease` (job kind, pinned `sub`/`email`/`azp`, SHA-256 of the one-time nonce, TTL ≤ 20 min by CHECK, one completion); `wrk_issue_exec_lease`; `bnx_intake.staging_payload`; ten `stg_*` functions (EXECUTE `bnx_stager` only) and `wrk_stage_completion` (Gateway path, `bnx_worker`) sharing one staging writer (lease, kind binding, size cap, field allowlist); `wrk_promote_staged` (Worker tick; kinds whose promoter is in a later migration wait as `AWAITING_PROMOTER`); Gateway `POST /exec/v1/lease`, `POST /exec/v1/complete` with `verifyJobToken` (jwt.js); dispatcher kind `staging.promote` | UA §9.2; S4B-F12; OBJ-371, OBJ-376, OBJ-377 |
| Intake schema | `bnx_intake`: `intake_item`, `intake_exception`, `external_index_source` (location is a Secret Manager reference by CHECK), `external_index_record`, `index_consumer_cursor`, `index_record_ack`, `mail_source` (address Owner-only), `mail_folder_route`, `mail_route_rule`, `mail_item` (no subject/body column), `project_handoff_message`, `notification` (C1 PWA only by CHECK; metadata allowlist; no digits in the subject), `account_identity_signal` (append-only; ≤ 4 visible digits by CHECK), `account_proposal`; `t_scope_flag_intake_item` registered in `flag_enforcement_point` (new `schema_name` column; matrix MODIFY covers `bnx_intake`) | UA §5.11; BNX-S2-02 §6; SI §2–§10 |
| Shared index consumer | `cmd_register_index_source` (Owner); `wrk_consume_shared_index` (15-column header check, stable keys incl. `WEAK_KEY`, version hash, routing fail closed, availability, Balnexa-side ack in the same transaction, upstream open items, CRA notices and `NOTICE_BURST`, cursor); `wrk_ack_index_record`; dead-letter after 5 attempts | SI §2.2–§2.4, §3, §5, §6, §7.1 |
| Mail exact retrieval | `cmd_register_mail_source` (Owner; starts `not_authorized`); `wrk_mail_evidence_registered` (credential gate, sender validation against verified `SENDER_DOMAIN` identifiers, incomplete attachments → one refetch → exception); `wrk_mail_move_result` | SI §4, §10 |
| Handoff | `cmd_handoff_prepare` (deterministic `bnx-project-handoff/1.0` block + prompt text; forbidden content refused), `cmd_handoff_mark_sent`, `cmd_handoff_import` (only the single fenced JSON block is data; dedupe and replay guard; major-version guard; PROPOSAL/REVERSAL → plan kind `handoff`, one item `transfer_to_clearing` against the `PROJECT_HANDOFF <cur>` clearing account; ACK → `MATCHED` only against a posted local leg with equal amount/currency; STATUS → `AWAITING_PEER`), `q_handoff_status`; `t_plan_item_clearing_open` opens the `clearing_item` (kind in the event payload) when the item posts | UA §12.2; BNX-S2-07; CROSS-07 |
| Account proposals | `wrk_record_identity_signal`; `cmd_propose_account` (ID-1, ID-2, ID-3, ID-4, ID-5, ID-7, ID-8); `cmd_resolve_account_proposal` (approve → `cmd_create_account`; reject; merge); `q_account_proposals` | UA §5.5.4; Draft-04 B5.4 |
| Coverage and notifications | `q_intake_coverage`, `q_intake_exceptions`, `q_notifications`, `cmd_notification_read`, `wrk_intake_housekeeping` (> 14 days non-terminal → `STALE_NON_TERMINAL`; stale coverage → one `COVERAGE_ALERT` per source and day) | SI §6; BNX-S2-02 §6 |

### 1.1 V-01 … V-10 as implemented

| Check | Hold | Condition (PROPOSAL where the design names only the intent) |
|---|---|---|
| V-01 | `IDENTITY` | account not `active`, or its institution not eligible and the account not grandfathered (re-run at approval) |
| V-02 | `CURRENCY` | a line's currency differs from its ledger account, or an item currency differs from the plan account |
| V-03 | `DUPLICATE` | `source_fingerprint` repeated in the plan, already imported (`source_txn`), or in another live plan of the same account-currency; `evidence_sha256` repeated in the plan |
| V-04 | `BALANCE_CHAIN` | `scope.statement`: opening + Σ items ≠ closing |
| V-05 | `COVERAGE` | statement period overlaps an approved/executing/sealed/activated statement plan of the same account-currency |
| V-06 | `FINGERPRINT` | `require_fingerprints` set and an import item without `source_fingerprint` |
| V-07 | `ECONOMIC_TYPE` | B6.1 pre-check on the lines each item will post (typed items as given; R1 items typed as in 9008) |
| V-08 | `TRANSFER_PAIR` | `internal_transfer`/`card_repayment` item without two household account-currencies and without a clearing leg |
| V-09 | `REVIEW_QUEUE` | item marked `needs_review` (or without counter account/lines) |
| V-10 | `SCOPE` | module flag of the plan account's region (9007) (re-run at approval) |

## 2. Results (raw output in `EVIDENCE/s4_core4/`)

| Suite | PG16 16.15 | PG17 17.11 (embedded-postgres beta) |
|---|---|---|
| R1 suite on B002 + 9002–9010 (re-baselined fixtures) | 40 / 0 / 0 | 38 / 0 / 2 SKIP (no `pg_dump` 17) |
| CORE-1 suite | 12 / 0 / 0 | 12 / 0 / 0 |
| Increment-2 suite | 12 / 0 / 0 | 12 / 0 / 0 |
| Increment-3 suite | 9 / 0 / 0 | 9 / 0 / 0 |
| Increment-4 suite (`run_s4_core4.py`, incl. AT-REV-01-07) | 11 / 0 / 0 | 11 / 0 / 0 |
| Black-box API (incl. BB-EXEC-01) | 8 / 8 | 8 / 8 |
| R1 dispatch simulation | PASS | — |

Increment-4 tests: AT-PLAN-04 (member_draft, ai_draft and onboarding pass validation, approval, chunked posting and activation; the drafter cannot approve, AI approval `FORBIDDEN_CHANNEL`; `manual` refused by the API and by the CHECK; revision supersedes an approved version; withdrawal; another member cannot withdraw); AT-PLAN-05 (each of DUPLICATE, BALANCE_CHAIN, COVERAGE, FINGERPRINT, ECONOMIC_TYPE, TRANSFER_PAIR, REVIEW_QUEUE, CURRENCY, IDENTITY and NOT_VALIDATED blocks approval with `PLAN_HELD` naming the hold; release after fix by withdraw + corrected plan and by re-validation; review queue); AT-PLAN-05b (V-10 at approval after the flag is switched off; released after it is switched on and the plan re-validated); AT-EXEC-01 (one-time nonce stored as a hash, forged/expired/used nonce, job-kind binding, size cap, TTL CHECK, worker-only issue); AT-EXEC-02 (`bnx_stager` stages and can do nothing else; the Worker cannot call `stg_*`; staging never posts; zero privilege-audit violations); AT-EML-01-04 (header contract, stable/weak keys, routing CA/CRA consumed, CN with International off skipped, unknown country and corporate owner blocked, other domain skipped, availability, ack idempotency, dead-letter after 5, edited record re-consumed, open items, digits stripped from the CRA notice, index location never returned); AT-EML-06,COV (NOTICE_BURST, housekeeping dedupe, coverage alert, Owner-only notifications); AT-MAIL-02-04 (credential gate, subject/body refused at staging, verified vs look-alike sender, incomplete attachments → exception, move, address Owner-only); AT-HX-01-08 (prepare, forbidden content, import of one block among injected text, clearing leg posted through the Owner Gate with the clearing item opened, duplicate, replay mismatch, two/no blocks, version 2.0, ACK match/mismatch, STATUS, reversal without original, MCP `handoff.prepare` allowed and MCP import refused); AT-ACP-01-08 (ID rules, full number refused, signal reuse refused, AI proposes but cannot resolve, approval creates the account, merge, reject, no automatic approval); BB-EXEC-01 (Gateway: another service account, other `azp`, PWA audience, unconfigured job kind, wrong key and no token → 401; lease; completion → staged; reuse 409; kind mismatch 403; > 300 kB 413; the scheduled dispatcher promotes the staging row; the CRA notice appears in the PWA inbox).

### 2.1 After the same-family review (2026-11-07)

The Fable review of PR #1–#4 found 3 P1 and 6 P2 defects (no P0), see `S4_Same_Family_Review_2026-11-07.md`. Finding 4 was first fixed only at the chunk stage. It is complete since F-C4-21 (§2.2), whose test passes. Changes in this increment:

- `plan_create` rebuilds every item from an allowlist and requires a description;
- reserved economic types are refused;
- a typed item's amount is computed from its plan-account line, and every household line must be visible to the caller;
- `clearing_open` is accepted only on handoff legs;
- `cmd_create_import_plan` no longer accepts kind `handoff`;
- the approval digests are compared with `is distinct from`;
- `cmd_withdraw_plan` also accepts `approved`.

New test AT-REV-01-07. AT-PLAN-05 reaches the CURRENCY hold through an R1 item, because typed lines with a wrong currency are now refused at creation. CI (`.github/workflows/ci.yml`) runs every suite on PGDG PostgreSQL 16 and 17; with `pg_dump` 17 available, AT-BAK-01/02 now pass on PG17 in CI (locally they still skip on the embedded PG17 build).

### 2.2 F-C4-21: authority re-check at activation (Owner decision 2026-11-07, Option A)

`wrk_activate_plan` (R1 0106) is redefined in 9010. The effective R1 body is kept line for line (all 24 R1 lines present, in order). Added before activation:

1. The approver's member row and every involved `account_grant` row are locked `FOR SHARE`. The involved rows are the plan account plus every household account on any typed line of any item, posted or not.
2. The R1 plan-account check stays as it was (`revalidation_required`, after which `wrk_revalidate_plan` suspends).
3. The approver's current `can_post` is checked on every household account of every typed item. A failure calls `plan_terminate(…, 'suspended', …)`: the batch is voided, so its journals stay in the ledger tables but never become visible; plan_event `suspended`, audit `plan_suspended` and outbox `plan.suspended` are written.

Transaction and concurrency semantics (READ COMMITTED):

- A revocation (`cmd_set_grant` UPDATE/DELETE, `cmd_set_member_state` UPDATE) that has **committed** before the activation reads the grants is seen, and the plan is suspended.
- A revocation that is **in flight** (row lock held, not committed) makes the activation wait. When the revocation commits, the activation re-reads the new row version and suspends.
- A revocation that arrives while the **activation holds its locks** waits until the activation commits. It then applies to later plans only; this plan was activated while the approver was still authorised.
- An activation that **rolls back** leaves the plan and batch `sealed`, nothing visible, and no audit row.
- No new deadlock path: the worker takes the ledger advisory lock and the plan row first, then the grant rows; `cmd_set_grant` takes only grant rows.

Regression (AT-REV-01-07, part 4b; `AUTHOR_RUNTIME_EVIDENCE`):

| Case | Result |
|---|---|
| control (no revocation) | `activated`; batch `active`; journals visible; events frozen → approved → activated; audit `activate_plan`; outbox `plan.activated` |
| revocation after sealing, before activation | `suspended`; batch `void`; 1 journal kept, 0 visible; audit `plan_suspended`; outbox `plan.suspended`; a second activation call returns `suspended` |
| activation rolled back | plan and batch stay `sealed`; 0 visible; 0 new audit rows |
| race, revocation first (uncommitted) | the activation waits, then `suspended`, batch `void`, 0 visible |
| race, activation first (uncommitted) | the revocation is blocked (`lock_timeout`); after the activation commits it applies; plan `activated` |
| R1 plan-account path (approver suspended) | `revalidation_required`, then `wrk_revalidate_plan` → `suspended`, batch `void` (R1 behaviour) |
| audit chain | `audit_verify()` = 0 |

Before the change, the same "after sealing" case activated the plan and made the journal visible: a throwaway reproduction on 2026-11-07 against PR #4 head `7cb7d37` gave `sealed → activated`, 1 visible journal.

**Checksum and compatibility.** 9010 changed from `7dcacb0ec358b55e555362ecae1f2c3d5a4589aaa60cce93e9275e7bd9121289` (PR #4 head `7cb7d37`) to `eecc2e0a19dbf112a68db65dc913af5258fa04180379fa735ae9f624ec575c7e`. Any database that applied an earlier 9010 is refused by the runner with exit 5 and has no in-place upgrade path. Only disposable test databases ever applied 9010; no deployment exists. `bnx.schema_migrations` is never edited. The R1 object disposition (test fixture copy) records `wrk_activate_plan` as MODIFY in 9010 (OBJ-207); the frozen V1.2 design CSV is not changed.

## 3. Findings and decisions

Severity: **O** = Owner should confirm; **D** = design text incomplete or inconsistent, implementation choice as stated; **N** = note.

| ID | Sev | Finding | What was done |
|---|---|---|---|
| F-C4-01 | D | UA §9.2 says the Gateway writes completions "through `stg_*` functions as `bnx_worker`", but the 9002 privilege rule (UA §6.1) grants `stg_` only to `bnx_stager` and `bnx_worker` only `wrk_` (EXECUTE_GRANT / STAGER_NO_POSTING) | Gateway path = `wrk_stage_completion` (`bnx_worker`), direct path = `stg_*` (`bnx_stager`); both run the same staging writer and neither posts. The prefix-to-role rule stays exact |
| F-C4-02 | D | Where the "configured job service account" lives | The Gateway pins `sub`, `email` and `azp` per job kind from its configuration (`EXEC_JOBS`, `EXEC_AUDIENCE`; AI-ENTRY projection); the lease row records the identity used. No database-side registry of job identities (PROPOSAL; it can be added with the Executor work package) |
| F-C4-03 | D | UA §5.6 stores the clearing kind `PROJECT_HANDOFF_LEG` in `clearing_item_event.payload`, which R1 does not have | Nullable column added (expand-only); R1 kinds unchanged (`unclassified_movement`). The clearing item opens when the plan item posts (`t_plan_item_clearing_open`); `recorded_version` = ledger version at posting, because batch journals have no `ledger_version` before activation |
| F-C4-04 | D | UA §12.2 says "the member's `PROJECT_HANDOFF` clearing account" | One household clearing account per currency (`PROJECT_HANDOFF CAD`, R1 `system_ledger_account`); per-member accounts would need a member reference on `ledger_account` |
| F-C4-05 | D | SI §2.3: `record_version_hash` = SHA-256 of the RFC 8785 JCS of the 15 columns; PostgreSQL has no JCS | SHA-256 of a JSON array of the 15 values in contract order (deterministic, independent of key order). Any external verifier must use the same form |
| **F-C4-06** | **O → decided 2026-11-06: accepted as implemented** | SI §3 names the inputs of the derived fields but no rule table | Owner type: Tags `Corporate`/`Business` → `CORPORATE`, `Owner:Unknown` → `UNKNOWN`, otherwise `PERSONAL`; CRA from `Type`/`Tags` containing `CRA`; region from the institution of a **verified** `SENDER_DOMAIN` identifier, else `UNKNOWN` → `BLOCKED (COUNTRY_UNKNOWN)`. Owner: is "no owner tag ⇒ PERSONAL" acceptable, or should it be `UNKNOWN` (blocked) until tagged? |
| F-C4-07 | N | Taxpayer resolution belongs to 9014 | Until then every CRA notice is an Owner-only `UNASSIGNED_TAX_NOTICE`, never an assessment, with the "may not contain the full CRA document" caveat |
| F-C4-08 | D | Scope claims for single-journal plans | Drafts and handoff legs claim no range (narrow `[d, d+1)` digest); import plans keep the R1 ±10-day claim; `cmd_draft_validate` refreshes the version and digest the approver must echo |
| **F-C4-09** | **O → decided 2026-11-06: both commands kept** | A held import plan keeps its scope claim; V1.2 names no command to withdraw or re-validate a non-draft plan, so a typo in a statement would block its date range | Added `cmd_withdraw_plan` and `cmd_validate_plan` (PWA, T2, `can_post` on the plan account). Owner should confirm these two commands |
| F-C4-10 | D | UA §5.5.3 re-runs V-01 and V-10 at approval | The whole V-set is re-run and any hold refuses (a duplicate approved meanwhile also holds); the refresh rolls back with the refusal |
| F-C4-11 | N | Plans frozen before 9010 have no validation | `PLAN_HELD (NOT_VALIDATED)` until re-validated with `cmd_validate_plan`; no real data exists |
| F-C4-12 | D | Approval of typed items | The approver must be able to post on every household account line of the item (not only the plan account), otherwise `NOT_POSTABLE` |
| F-C4-13 | N | "JSON Schema per job kind" at the Gateway is not implemented | Size cap (Gateway 300 kB body, database 256 KiB payload), job-kind binding, and a field allowlist for the two kinds promoted in 9010 (unknown fields refused; mail subject/body are never staged). Schemas belong to the Executor work package |
| F-C4-14 | N | `stg_doc_*`, `stg_render_done`, `stg_backup_recorded`, `stg_restore_drill_recorded`, `stg_tax_artifact` stage now; their promoters are in 9011/9014/9016 | `wrk_promote_staged` marks them `AWAITING_PROMOTER`; nothing is lost or posted |
| F-C4-15 | D | Account proposals not covered | ID-6 (card replacement), split, and the ID-5 `duplicate_candidate` pair are not implemented (ID-5 is recorded in `match_trace`); the reference fingerprint is supplied by the caller (HMAC with `REF_HMAC_KEY` happens before it reaches the database) |
| F-C4-16 | D | Handoff function names | `handoff.prepare` writes a `PREPARED` row, so it is `cmd_handoff_prepare` (R1 `q_` functions never write), plus `cmd_handoff_mark_sent`; `cmd_handoff_import` is PWA-only because the 9009 catalog has no `handoff.import` scope (MCP: `SCOPE_NOT_CONSENTED`) |
| F-C4-17 | N | Mail evidence | Evidence objects and documents are created by the 9011 pipeline (`wrk_doc_register`); 9010 keeps the `mail_item` metadata and the intake item only |
| F-C4-18 | N | Dispatcher | `staging.promote` added to the known kinds. The S4B-F13 rule (unknown kinds stay queued with backoff) is still pending; until it lands, a Worker older than 9010 would complete `staging.promote` items as no-ops — the staging rows stay `STAGED` and can be promoted later (deploy rule: Worker before migration) |
| F-C4-19 | D | `intake_item` terminal states | `DONE`, `SKIPPED`, `DEAD_LETTER`; `BLOCKED` and `EXCEPTION` need a resolution and become `STALE_NON_TERMINAL` exceptions after 14 days |
| F-C4-20 | N | Notification channels | Only C1 (PWA inbox), enforced by CHECK; C2/C3 need the separate Owner approval (SI §7.2, OR-EML-06-CH) |
| F-C4-21 | D (Owner decision 2026-11-07, Option A) | Same-family finding 4: at activation the approver's authority was re-checked only on the plan account (R1 `wrk_activate_plan`), so a revocation between sealing and activation was not honoured for typed multi-account items | `wrk_activate_plan` MODIFY in 9010 (§2.2): every account of every typed item re-checked under `FOR SHARE` locks; revocation → `suspended`, batch void. Disposition OBJ-207 REUSE → MODIFY. AT-REV-01-07 part 4b |

## 4. Re-baselined tests

| Test | Change | Why |
|---|---|---|
| `run_s4_core3.py` AT-PLAN-06,07 | the unclassifiable item is now held at approval (`PLAN_HELD`, V-07); the Worker check `PLAN_ITEM_UNTYPED` is still exercised by bypassing the hold directly as `bnx_definer` | 9010 moves the refusal earlier; the defence in depth stays tested |
| `run_s4_core2.py` AT-FLG-11 | `intake_item` accepted as an additional enforcement point | 9010 adds its own point (F-C2-07) |
| `run_s4_core1.py` AT-INV-01 | 9010 in scope; the 9010 helper functions declared | inventory check |

Every re-baselined test still asserts the behaviour it was written for. No R1 file was changed.

## 5. Environment

As increment 1: PG16 16.15 (Ubuntu); PG17 17.11 embedded-postgres beta (not the PGDG build S4B-F19 requires; no `pg_dump` 17); Python 3.13, psycopg 3.2.3; Node 22. `bnx_stager` LOGIN is enabled only inside AT-EXEC-02 and reset to NOLOGIN in a `finally` block.

## 6. Next increment (proposed)

9011 documents, evidence and renditions (`document_discovery`, `document_state_event`, `wrk_doc_*` promoters for the staged `stg_doc_*` rows), then 9012 observations/loans/cards. The Worker S4B-F13 unknown-kind rule should land before any migration that enqueues a new kind.
