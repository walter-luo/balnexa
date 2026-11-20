# S4 9045 — default categories and accounts proposed from statements: implementation notes

`DRAFT — AI-generated` (Claude). Authoritative once the Owner confirms it.

| Field | Value |
|---|---|
| Migration | `db/migrations/9045_s4_default_categories_account_proposals.sql` |
| Authority | OD-CAT-1, OD-ACC-1 (`OWNER_DECISIONS_2026-11-16.md`, 2026-11-20); OD-AI-1..4, OD-APR-1, C-04 |
| Release | V1.0-R05 (Worker range 9044–9045) |
| Tests | `tests/py/run_s4_core21.py` (AT-CAT-01, AT-ACC-01, AT-ACC-02, AT-CONF-09); PWA AT-ACC-UI-01; AT-INV-01 helper list |

## What it does

1. **Default categories (OD-CAT-1).** `bnx.default_category_tree()` holds the built-in list: 89 categories, 24 top level (17 expense groups, 7 income groups), English and Chinese, modelled on the default lists of Quicken, Monarch and 随手记. `bnx.install_default_categories(currency)` adds the missing ones in a currency (default: the reporting currency). The migration runs it on an installed household; `deploy/install_instance.py` runs it after the install on every run.
2. **Accounts from statements (OD-ACC-1).**
   - Step one: the AI calls `fin.account.propose_from_statement` with the institution (registry id), account type, last 4 digits, currency, holder names as printed, and the earliest statement's period start, printed opening balance and sign convention. Balnexa records an identity signal and a proposal.
   - The member approves on **Review** in the PWA. Approval creates the account (through `cmd_create_account`), sets the opening anchor from the statement (ledger sign: an owed-positive card balance of 250 becomes −250), and adds the account-currency to the proposing AI connection.
   - Step two: the AI submits the statement with `fin.draft.create_statement`; V-11 reports it first in the chain and V-12 finds the opening at its start.
3. **Draft screen.** `fin.draft.get_for_confirmation` returns the account-currency, its label and masked reference, the statement header (period, printed opening and closing, line count), and the name of every line's ledger account in English and Chinese ("Parent › Child" for a subcategory). The PWA shows them; the MCP result carries them too.
4. **PWA.** Review lists open account proposals with the suggested name (editable) and two ticked choices (opening balance, connection access). Quick Entry and Set up accounts list categories as "Parent › Child". Cash and other assets are created without an institution (the database refuses one; the PWA used to send it and showed "Please check the field: ?").

## Decisions taken here

| ID | Decision | Reason |
|---|---|---|
| D-9045-1 `DELEGATED_DECISION` | A member's existing category of the same kind, currency and English name (case-insensitive) is kept and not duplicated; it is not moved under the default parent | Never change a member's data silently; Groceries and Salary entered by hand stay where they are |
| D-9045-2 `DELEGATED_DECISION` | Default categories exist per currency; other currencies are added by the installer function only (no PWA action yet) | Categories are ledger accounts in one currency (0002); a household with USD accounts can be served when one exists (L-9045-1) |
| D-9045-3 `DELEGATED_DECISION` | On approval, "set the opening balance" and "let the AI connection see this account" are **ticked by default**; the member can untick either | OD-ACC-1 makes the two-step flow the normal path; without the grant the AI cannot do step two. Unlike the consent screen (D-AIH-11), the member is approving an account the AI found in a document the member gave it |
| D-9045-4 `DELEGATED_DECISION` | `ACCOUNT_EXISTS` names no account; an AI connection sees only its own proposals | The connection's consent covers specific account-currencies; a proposal must not reveal others |
| D-9045-5 `DELEGATED_DECISION` | A proposal accepts no full number: last 4 digits only, holder names without digit runs | SIN and card-number rules |

## Field findings that led here (2026-11-20, test instance)

- The instance had no accounts and no categories, so the consent screen had nothing to offer ("Accounts it may see" empty).
- The account setup screen sent an institution for a cash account; the database refused it as `VALIDATION_FAILED` without a field, shown as "Please check the field: ?".
- The draft screen showed only "−12 CAD / 12 CAD": no account, no category.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-9045-1 | Default categories in a second currency are added by the installer function only | A PWA action when a household needs it |
| L-9045-2 | Default categories cannot be retired from the PWA yet (members can add only) | With category management |
| L-9045-3 | A proposal is for one currency; a multi-currency account needs one proposal per currency, or the member adds the currency | When a multi-currency statement appears |
