---
name: balnexa-statement-intake
description: Enter one bank, card or investment statement into Balnexa. Read the document, submit it whole as a statement draft, report the database checks, and file the original. Use when a household member gives you a new statement, or asks you to process the statements waiting in the data folder.
---

# Balnexa statement intake (W1)

`DRAFT — AI-generated`. The household's Owner publishes it before use. Generic copy: it holds no household details. The household's own values, such as folder ids and the instance, come from `00-Governance/BALNEXA-AI-ENTRY.md` in the household's data folder. Read that file first.

## What you do and what Balnexa does

- **You (the runtime AI):**
  - read the statement;
  - copy the printed values;
  - propose a classification for each line;
  - submit the statement;
  - explain the result;
  - file the original.
- **Balnexa (the database):**
  - checks the statement;
  - computes fingerprints and signs;
  - keeps the draft until a member approves it in the Balnexa app.
- **You never approve, post or compute a figure.** If a check fails, the statement or your reading of it is wrong, so look again; do not adjust numbers to make a check pass.

## Never

- Store, repeat or send a full card number, account number or government ID number (SIN). Use the **last 4 digits** only.
- Change, rename, move or delete anything in `20-Inbox`.
- Compute balances or totals yourself and present them as Balnexa figures.
- Approve a draft or ask a member to approve something you have not shown them.

## Tools (Balnexa connector)

The connector lists each tool under its catalog name with `.` replaced by `_` (for example `fin_draft_create_statement`); the catalog name is the tool's title.

| Tool | Use |
|---|---|
| `fin.ledger.accounts` | Find the account-currency of the statement (match institution, product, currency, last 4 digits) and the categories for classification |
| `fin.statements.chain` | See the statements already entered for the account, their periods, balances and continuity |
| `fin.draft.create_statement` | Submit the statement |
| `fin.draft.validate` | Re-run the checks of a draft (after a member explained a gap) |
| `fin.draft.withdraw` | Withdraw your own draft |
| `fin.draft.get_for_confirmation` | Show the member exactly what they will approve |
| `fin.account.propose` | Propose an account that does not exist yet; a member resolves it |

## Steps

1. **Find the statement.** Look for originals in `20-Inbox` that have no row in the index (`10-Index`), or use the file the member gave you. Work on one account at a time, oldest period first.
2. **Read it.** Note the following, all as printed:
   - the institution, the product and the last 4 digits of the account or card;
   - the currency and the period (from and to);
   - the opening (previous) balance and the closing (new) balance;
   - every line: posting date, amount, description and bank reference if any.

   On a multi-page statement, make sure you have every line. If the text is unclear, say so; do not guess an amount.
3. **Find the account.** Call `fin.ledger.accounts`. Match on the institution, the currency and the last 4 digits. A card may be reissued with a new number on the same account: a carried-over balance shows it. If you find no match, propose the account (`fin.account.propose`) and stop until a member resolves it.
4. **Check the history.** Call `fin.statements.chain` for the account. If this statement is older than the first one entered, or there is a gap before it, say so. History is handled by `balnexa-history`.
5. **Classify each line.**
   - Give every line a `counter_ledger_account_id` from the categories, or typed `lines` for a transfer between household accounts (for example a card payment from a chequing account: `economic_type` `card_repayment`, both accounts).
   - Mark a line `needs_review: true` when you are not sure. The member then decides.
6. **Submit.** Call `fin.draft.create_statement` with:
   - `account_currency_id`, `period_from`, `period_to`;
   - `opening_balance` and `closing_balance` as printed;
   - `sign_convention`: `asset_positive` for bank and investment accounts, `owed_positive` for cards and loans as printed;
   - `lines` with amounts in the same convention;
   - `institution`, `account_last4`, and the Drive `source_file_id`.

   For a corrected version of your own open draft, pass `supersedes_plan_id`.
7. **Report the checks** from `validation_result` and `continuity`, in plain words:

   | Check | Meaning | What you do |
   |---|---|---|
   | V-04 `HOLD:BALANCE_CHAIN` | Opening + lines ≠ closing | Re-read the statement: a missed or misread line, or a wrong sign. Correct and resubmit with `supersedes_plan_id` |
   | V-03 `HOLD:DUPLICATE`, V-05 `HOLD:COVERAGE` | The statement or some lines are already entered or pending | Tell the member; usually withdraw your draft |
   | V-11 `HOLD:BALANCE_BREAK` | The opening does not meet the previous closing | Tell the member the dates and both balances. The usual cause is a missing statement. Only a member can record an explanation, in the app |
   | V-11 `FINDING:GAP` | Dates missing between statements, balances match | Usually no activity. Tell the member |
   | V-12 `HOLD:BEFORE_OPENING` | The statement is older than the account's opening | History: use `balnexa-history` |
   | V-09 `HOLD:REVIEW_QUEUE` | Lines marked for review | List them for the member |
8. **Hand over.** Tell the member the draft is ready to approve in the Balnexa app, with the period, the number of lines, the opening and closing balances as printed, and any finding. Use `fin.draft.get_for_confirmation` if they want the exact content.
9. **File the original** after approval (`balnexa-filing`):
   - copy it to `30-Processed/<person>/<year>/<institution>/<date>_<institution>_<last4>_statement_<period>.<ext>`;
   - add the index row;
   - never change the original.

## Output to the member

A short summary in the member's language:
- the account (institution and last 4 digits) and the period;
- the line count;
- the printed balances;
- the check results;
- what they need to do.

Do not paste the whole statement back.
