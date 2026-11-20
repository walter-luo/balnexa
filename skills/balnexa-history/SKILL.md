---
name: balnexa-history
description: Enter and verify a household's past statements in Balnexa, account by account and oldest first, then report the coverage, gaps and breaks of each account's history. Use when a household member asks to load their history, back-fill past months or years, or check that an account's statements form a complete chain.
---

# Balnexa history entry and verification (W6)

`DRAFT — AI-generated`. The household's Owner publishes it before use. Generic copy: it holds no household details. The household's own values come from `00-Governance/BALNEXA-AI-ENTRY.md` in the household's data folder. Read that file first.

History entry is `balnexa-statement-intake` (W1) run over a whole history, oldest first. Every rule of that skill applies here, above all:
- last 4 digits only;
- nothing in `20-Inbox` is changed;
- you never approve, and you never compute a figure that you present as Balnexa's.

## Tools (Balnexa connector)

Each tool is listed under its catalog name with `.` replaced by `_`.

| Tool | Use |
|---|---|
| `fin.ledger.accounts` | The accounts this connection may see, and the categories |
| `fin.statements.chain` | One account-currency's statements in period order, with continuity and the recorded gap explanations |
| `fin.draft.create_statement` | Submit one statement |
| `fin.draft.validate` | Re-run the checks of a draft after a member recorded an explanation |
| `fin.balances.as_of` | Balances from the database, for the report |

The member does these in the Balnexa app; you cannot do them:
- set or move an account's opening;
- explain a gap;
- approve a statement.

## Steps

1. **Inventory.** List every original you have for the household, grouped by account. For each, give the institution, the last 4 digits, the currency and the period.

   Report per account:
   - the earliest and the latest period;
   - statements that cover more than one month;
   - possible duplicates (same account and period twice);
   - card reissues: a new card number whose first statement carries over the old card's balance. Treat both numbers as one account.

   Ask the member to confirm the list before you submit anything.
2. **Match the accounts.** Call `fin.ledger.accounts`. An account that is not there must be created or resolved by a member first (`balnexa-statement-intake` step 3).
3. **Opening point.** Call `fin.statements.chain` for the account. The opening must sit at the start of the earliest statement you will enter. If it does not, tell the member exactly what to enter in the app (menu **2. Accounts, currencies and balances** → **Set starting balance**):
   - the date: the earliest statement's period start;
   - the amount: that statement's opening balance as printed, with its sign as the app asks.

   Wait for the member to confirm. If a statement is submitted first, the database holds it with `BEFORE_OPENING` (V-12); nothing is lost, and you can re-validate it after the opening is set.
4. **Statements in order.** Submit each statement of the account with `fin.draft.create_statement`, oldest first, one at a time. Read each result before the next:
   - a `BALANCE_CHAIN` hold means your reading of that statement is wrong. Fix it before you go on.
   - a `BALANCE_BREAK` or a `GAP` is about the history, not the statement. Note it and continue.

   A period with no statement because there was no activity has no lines. Do not submit it: it is a gap, which the member explains in step 6.
5. **Check the chain.** When the account is done, call `fin.statements.chain` and compare it with your inventory. Look for:
   - every expected period present;
   - no statement left on hold that you have not explained to the member;
   - no overlap reported (V-05 `COVERAGE`).
6. **Gaps and breaks.** For each one, tell the member the dates, and the balances on both sides as printed. Give your reading of the case:
   - no activity (for example a card whose next statement starts from 0.00);
   - a missing statement;
   - an account opened or closed;
   - other.

   The member records the explanation in the app, and decides whether to look for a missing statement. After that, call `fin.draft.validate` on the held drafts.
7. **Approval.** Tell the member which statements are ready to approve in the app (menu **4. Drafts and approval**) and which still have findings. Approval is theirs.
8. **History report** per account, by `balnexa-reports` rules: every figure comes from a Balnexa query, and the report is saved with its queries. It covers:
   - the coverage, from the first to the last period;
   - the explained gaps and the open gaps;
   - every break and how it was resolved;
   - the duplicates found;
   - the opening balance, and the current balance from `fin.balances.as_of`.

## What to say when you stop

If you stop before an account is finished, say:
- which statement was entered last;
- which ones are waiting for the member;
- what the member needs to do next.

The next session continues from `fin.statements.chain`, not from your memory.
