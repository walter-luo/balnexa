# S4 9046 — hold texts, line review of statement drafts, opening amount: implementation notes

`DRAFT — AI-generated` (Claude). Authoritative once the Owner confirms it.

| Field | Value |
|---|---|
| Migration | `db/migrations/9046_s4_hold_details_statement_review.sql` |
| Authority | OD-LIVE-1 (`OWNER_DECISIONS_2026-11-16.md`, 2026-11-20 15:53); G3 of `S4_AI_First_Workflows_Design_2026-11-16.md`; C-04, OD-APR-1 |
| Release | V1.0-R06 (Worker range 9045–9046) |
| Tests | `tests/py/run_s4_core22.py` (AT-HOLD-01, AT-REV-01, AT-REV-02, AT-OPEN-02); PWA AT-REV-UI-01; AT-STM-01 (V-04 text); AT-INV-01 |

## The live run (2026-11-20, synthetic test instance)

Claude read a synthetic Canadian Tire card statement (October 2026, ••••7712). The two-step approval of 9045 worked: the account was proposed, approved on Review with its opening (−250 at 10-01), and the statement was submitted. Findings:

| ID | Finding | Fix |
|---|---|---|
| F-LIVE-1 | Holds were codes only. `BEFORE_OPENING` did not say which line or account; Claude could not explain it and the PWA showed "Held: …" only | V-04, V-09 and V-12 texts say where (below); the PWA shows each hold as a sentence with that text |
| F-LIVE-2 | The member could not change a line's category or clear `needs_review` on a statement draft; a held statement went back to the AI | `cmd_review_statement_items` and the **Review the lines** section of the draft screen (G3) |
| F-LIVE-3 | Claude sent six one-line trial drafts to learn the signs (all void) | `balnexa-statement-intake` 0.3.0: worked card example, "submit once" |
| F-LIVE-4 | Claude chose a payment account that opened after the payment date | skill: check the other account with `fin.balances.as_of`; ask the member; `balnexa-history` 0.3.0: openings of both sides of a transfer |
| F-LIVE-5 | `set_opening` had no `amount` in its catalog schema; the PWA form could set it only through raw JSON | `catalog_build.py` reads keys taken with `bnx.dec(cmd, 'k')` |
| F-LIVE-6 | An open claude.ai conversation kept the pre-release tool list | runbook note |

## What changes

1. **Hold texts (V-04, V-09, V-12).** The hold codes in `hold_reasons` are unchanged; the `validation_result` texts gain a bracket:
   - `HOLD:BALANCE_CHAIN (ledger sign: opening -100 + lines -20 = -120, closing -999)`;
   - `HOLD:REVIEW_QUEUE (seq 1, 2, 3)`;
   - `HOLD:BEFORE_OPENING (seq 1 2026-02-10 before opening 2026-03-01)`.
   The PWA lists each hold with a sentence (`hold.<CODE>`, English and Chinese) and the bracket.
2. **Line review (G3).** On the draft screen of a statement draft, a member who may post to the account sees **Review the lines**: per line a category or another household account, and **Reviewed** where the AI marked the line. Saving calls `cmd_review_statement_items` (tier 2, PWA only) with the `plan_hash` the member saw. Balnexa rebuilds the items, terminates that version as superseded and creates the new version, which is validated as usual; the screen then shows it for approval.
3. **Opening amount.** The catalog generator reads `bnx.dec(cmd, 'k')` as a decimal key: `cmd_set_opening` gets `amount` and `cmd_post_transaction`'s `original_amount` becomes a decimal. The menu task **Set starting balance** therefore offers the account picker, the date and the amount, also for an existing account (moving an opening earlier is refused only when postings would fall before it).

## Decisions taken here

| ID | Decision | Reason |
|---|---|---|
| D-9046-1 `DELEGATED_DECISION` | The hold codes stay; the detail goes into the `validation_result` text. V-12 names the line and the opening date, not the other account | Codes are an interface (skills, tests). An AI connection may not see the other account |
| D-9046-2 `DELEGATED_DECISION` | A reviewed version keeps the kind (`ai_draft`) and the AI connection of the version it replaces; its creator is the reviewing member | The AI can still read and report its draft; an `ai_draft` claims no posting range, so reviewing several months does not conflict |
| D-9046-3 `DELEGATED_DECISION` | Line review cannot change dates, amounts, descriptions or fingerprints | They are the statement's; a misread is corrected by the AI's resubmission (`supersedes_plan_id`) |
| D-9046-4 `DELEGATED_DECISION` | Line review needs tier 2 and the right to post to the account, as approval does | It prepares what the same member then approves |
| D-9046-5 `DELEGATED_DECISION` | Another household account as a line's counterpart becomes typed lines; the type defaults to `card_repayment` between a card and an asset account, `internal_transfer` otherwise; the member may set another type | The common cases need no choice; V-07 still checks the type |
| D-9046-6 `DELEGATED_DECISION` | F-LIVE-5 is fixed in the generator, not with a new screen | The generic form already has the account picker; the missing piece was the schema |

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-9046-1 | A line can have one counterpart in the review (no splits); a split stays as the AI submitted it | When a split is needed in the app |
| L-9046-2 | Batch approval of several statements (rest of G3) is not in this release | With the history work (W6) |
