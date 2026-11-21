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
| `fin.balances.as_of` | Check that another household account a line touches already exists in Balnexa on that date (status `BEFORE_OPENING` means it does not) |
| `fin.ledger.accounts` | Find the account-currency of the statement (match institution, currency and the last 4 digits in `reference_display`) and the categories for classification (`parent_id` links a subcategory to its category) |
| `fin.statements.chain` | See the statements already entered for the account, their periods, balances and continuity |
| `fin.draft.create_statement` | Submit the statement |
| `fin.draft.validate` | Re-run the checks of a draft (after a member explained a gap) |
| `fin.draft.withdraw` | Withdraw your own draft |
| `fin.draft.get_for_confirmation` | Show the member exactly what they will approve |
| `reg.institutions.search` | Find the institution's id for a new account |
| `fin.account.propose_from_statement` | Propose a new account read from the statement; a member approves it in the app |
| `fin.account.proposals` | See your proposals and whether a member decided them |

## Steps

1. **Find the statement.** Look for originals in `20-Inbox` that have no row in the index (`10-Index`), or use the file the member gave you. Work on one account at a time, oldest period first.
2. **Read it.** Note the following, all as printed:
   - the institution, the product and the last 4 digits of the account or card;
   - the currency and the period (from and to);
   - the opening (previous) balance and the closing (new) balance;
   - every line: posting date, amount, description and bank reference if any.

   On a multi-page statement, make sure you have every line. If the text is unclear, say so; do not guess an amount.
3. **Find the account.** Call `fin.ledger.accounts`. Match on the institution, the currency and the last 4 digits (`reference_display`). A card may be reissued with a new number on the same account: a carried-over balance shows it; ask the member before treating it as a new account.

   **No match: propose the account (step one of two).**
   - Find the institution with `reg.institutions.search`. If it is not in the registry, tell the member; only a member can add an institution.
   - Call `fin.account.propose_from_statement` with the institution id, the account type (`bank_deposit`, `credit_card`, `investment`, `loan_payable`, …), the last 4 digits, the currency, the holder names as printed, and, from the **earliest** statement you will enter for this account, `period_from`, `opening_balance` as printed and `sign_convention`.
   - `ACCOUNT_EXISTS` means the household already has this account but this connection may not see it: ask the member to let you see it (Settings → AI connections), do not propose it again.
   - Tell the member to approve the new account on **Review** in the Balnexa app. Approving creates the account, sets its opening balance from the statement, and lets you see it. Stop here until `fin.account.proposals` shows the proposal `APPROVED` and `fin.ledger.accounts` lists the account; then continue with step 4 (step two: the statement).
4. **Check the history.** Call `fin.statements.chain` for the account. If this statement is older than the first one entered, or there is a gap before it, say so. History is handled by `balnexa-history`.
5. **Classify each line.**
   - Give every line a `counter_ledger_account_id` from the categories, or typed `lines` for a transfer between household accounts (for example a card payment from a chequing account: `economic_type` `card_repayment`, both accounts).
   - **The other account of a transfer must already exist on the line's date.** Call `fin.balances.as_of` for that account on the line's date. If its status is `BEFORE_OPENING` (or the account is not visible to you), do not guess: ask the member which account paid, and tell them it opens later in Balnexa. They can enter that account's earlier statement first, or move its opening date earlier in the app (menu **2. Accounts, currencies and balances** → **Set starting balance**).
   - **A card payment or transfer whose other account you do not know is not a category.** Never put it under an expense or income category (for example "Other Expense") to get the draft through: Balnexa would post it as a refund or income. Ask the member which account paid **before** you submit, then use typed `lines` with that account. Only if the member cannot say now, submit the line with `needs_review: true` and tell them plainly that, in the app, they must pick the paying account for that line (not just tick Reviewed).
   - Mark a line `needs_review: true` when you are not sure. The member then decides, line by line, in the app; lines marked for review stand out there with their type.
6. **Submit.** Call `fin.draft.create_statement` with:
   - `account_currency_id`, `period_from`, `period_to`;
   - `opening_balance` and `closing_balance` as printed;
   - `sign_convention`: `asset_positive` for bank and investment accounts, `owed_positive` for cards and loans as printed;
   - `lines` with amounts in the same convention;
   - `institution`, `account_last4`, and the Drive `source_file_id`.

   For a corrected version of your own open draft, pass `supersedes_plan_id`.

   **Signs, worked example (card, `owed_positive`).** Copy amounts exactly as printed; Balnexa turns them to the ledger sign. A card statement prints purchases positive and payments negative:

   | Printed line | `amount` you send | Classification |
   |---|---|---|
   | `LOBLAWS … 85.40` | `"85.40"` | Groceries (`card_spend`) |
   | `PAYMENT - THANK YOU -250.00` | `"-250.00"` | typed `lines`, `card_repayment`: card `+250.00`, chequing `-250.00` (typed lines are in the **ledger sign**: money into the card account reduces what is owed) |

   With `opening_balance` `250.00` (owed) and `closing_balance` as printed, V-04 checks opening + lines = closing. A bank statement (`asset_positive`) prints deposits positive and withdrawals negative; send them as printed.

   **Submit once.** Do not send trial drafts to find out how signs work: each one is stored and must be withdrawn. If a check fails, its text says where (step 7); fix your reading and resubmit with `supersedes_plan_id`.
7. **Report the checks** from `validation_result` and `continuity`, in plain words:

   | Check | Meaning | What you do |
   |---|---|---|
   | V-04 `HOLD:BALANCE_CHAIN (ledger sign: opening … + lines … = …, closing …)` | Opening + lines ≠ closing; the figures are in the ledger sign | Re-read the statement: a missed or misread line, or a wrong sign. Correct and resubmit with `supersedes_plan_id` |
   | V-03 `HOLD:DUPLICATE`, V-05 `HOLD:COVERAGE` | The statement or some lines are already entered or pending | Tell the member; usually withdraw your draft |
   | V-11 `HOLD:BALANCE_BREAK` | The opening does not meet the previous closing | Tell the member the dates and both balances. The usual cause is a missing statement. Only a member can record an explanation, in the app (menu **4. Drafts and approval** → **Explain a statement gap**) |
   | V-11 `FINDING:GAP` | Dates missing between statements, balances match | Usually no activity. Tell the member |
   | V-12 `HOLD:BEFORE_OPENING (seq N date before opening D)` | Line N is dated before the opening date D of an account it touches: this account (older statement: use `balnexa-history`) or the other account of a transfer | Tell the member which line and date. For the other account: enter its earlier statement first, or the member moves its opening date earlier in the app (menu **2. Accounts, currencies and balances** → **Set starting balance**); then resubmit |
   | V-09 `HOLD:REVIEW_QUEUE (seq …)` | Lines marked for review | List them for the member. The member reviews them in the app (**Review the lines** on the draft screen); you need not resubmit |
   | V-07 `HOLD:ECONOMIC_TYPE (seq …)` | A line's type does not fit its accounts | Check the category or the transfer lines of that line |
8. **Hand over.** Tell the member the draft is ready to approve in the Balnexa app, with the period, the number of lines, the opening and closing balances as printed, and any finding. Use `fin.draft.get_for_confirmation` if they want the exact content.

   In the app the member may change a line's category or mark it reviewed. That makes a new version, which supersedes yours (`fin.statements.chain` shows it); you can still read it with `fin.draft.get_for_confirmation`. Do not resubmit over a member's review unless they ask.
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
