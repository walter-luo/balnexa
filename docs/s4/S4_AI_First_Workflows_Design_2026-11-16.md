# AI-first workflows — design and gap list (2026-11-16)

`DRAFT — AI-generated` (Claude). It becomes authoritative once the project Owner confirms it.

## 1. Direction

These Owner decisions of 2026-11-16 govern the design.

**OD-AI-1** (the project is AI-first):
- AI reads the documents, reconciles the accounts, writes the reports and runs the workflows.
- The database and the Drive data folder are the permanent stores.
- The PWA is developed further.

**OD-AI-2** (where programs stop):
- The architecture is unchanged: Gateway, database, MCP and PWA.
- Whatever an AI with a skill can do is not programmed.
- Programs exist for the database, validation, and the transaction flow (draft → approval → posting).
- Reports are produced by AI.

**Boundaries B1–B4** (confirmed by the Owner):

| Id | Rule |
|---|---|
| B1 | Every figure in an AI report comes from a database query made through a read tool. The AI never computes a figure itself |
| B2 | The database keeps its integrity rules: double entry, balance continuity, duplicate checks, the SIN and card-number guards, and the audit chain. Whatever the AI sends, a wrong entry cannot get in |
| B3 | C-04 stays: the AI drafts, and a member approves in the PWA. The AI never posts or approves |
| B4 | Every AI report is saved to the data folder together with the queries or report snapshots it used, so that it can be checked and reproduced |

**OD-AI-3** (Owner, 2026-11-16 22:04):
- The project's functions are delivered through AI skills: reconciling a statement, finding the transactions of a period, and so on.
- Balnexa supports **entering and verifying historical data**: years of past statements per account, not only new ones (W6).

**Withdrawn by OD-AI-1:**
- the Executor's document and import handlers (`DOC_*`, `IMPORT_PARSE`);
- a statement parser;
- any new fixed report family.

The functions already built stay, and the AI uses them as tools.

## 2. Roles

**What Balnexa is (Owner, 2026-11-17 06:51).** Balnexa is not a traditional app. It is a project that **runs on an AI platform**:
- its functions depend on the AI and on AI skills;
- the database work is done by code that the AI calls.

**Two AI platforms (dual AI):**
- **Runtime AI:** the platform the household chooses to run Balnexa on (Claude or ChatGPT). It runs the workflows.
- **Reviewer AI:** the other platform, chosen by the Owner. It reviews and never runs the workflows:
  - its connection is consented with read scopes only;
  - it reads drafts, reports and the history checks through the same tools;
  - it writes its findings as review notes in the data folder;
  - it cannot draft, post or approve.


| Part | Role |
|---|---|
| **Runtime AI** (Claude or ChatGPT, the household's choice) with **skills** | Runs every workflow. It reads documents from Drive or from an upload, extracts the content, calls Balnexa tools through the custom connector, writes reports, and files documents. A skill is the written procedure and checklist for one workflow |
| **Balnexa Gateway + database** | Tools (MCP and REST), validation, drafts, approval, posting, the audit trail and the guards. No document parsing and no report logic |
| **Reviewer AI** (the other platform, the Owner's choice) | Read-only review of drafts, reports and history checks; review notes in the data folder |
| **PWA** (phone, including offline, and web) | Only data work: queries, data entry and viewing reports. The approval of AI drafts counts as data entry (to be confirmed by the Owner). It contains no AI |
| **Drive data folder** | Originals in `20-Inbox` (the data owner's), processed copies in `30-Processed`, the index in `10-Index`, and AI reports in `40-Exports` (`Data_Folder_Convention.md`) |
| **Member (Owner)** | Uploads originals, asks the AI, and approves in the PWA |

## 3. Workflows

Each workflow becomes one skill. The steps marked **[DB]** are program checks; everything else is AI work.

### W1 Statement intake (bank, card and investment statements)

1. **Find and read.** The AI finds new originals in `20-Inbox`, or takes a file the member uploads, and reads it. It identifies the account by institution, product and last 4 digits, the period, the opening and closing balances, and the lines.
2. **Match the account.** The AI calls `q_balances` / `q_ledger_accounts` to find the account-currency. When there is none, it calls `cmd_propose_account`, and the member resolves the proposal in the PWA.
3. **Register the evidence.** The AI calls `cmd_register_evidence` with the Drive file identity (G2).
4. **Submit the statement.** The AI calls **`cmd_draft_statement`** (new, G1) with the header and every line. It reproduces the printed values exactly and computes no derived figures.
5. **[DB] Check the statement.** The checks run when the draft is submitted, and again before approval:
   - the opening balance plus the lines equals the closing balance (`STATEMENT_NOT_BALANCED`, which shows the printed and summed values);
   - the opening balance equals the closing balance of the previous statement of the same account-currency, or a gap is reported with its dates (`STATEMENT_GAP`, a finding, not a refusal);
   - the same account and period is not already submitted (`STATEMENT_DUPLICATE`);
   - no line repeats an existing `source_txn` fingerprint (INV-44; such lines are listed as duplicates);
   - the SIN and card-number guards (9041/9042): a card number keeps its last 4 digits only;
   - all amounts carry the same currency as the account-currency.
6. **Propose classification.** For each line the AI proposes an economic type and a category, and marks transfers between household accounts. The database stores these as proposals (`classification_source = 'ai'`).
7. **Approve.** The member sees the statement in the PWA approval queue (G3): the header, the lines, the check results and the AI's proposals. Approving creates the statement, its `source_txn` rows, the balance observation and the journals, through the existing plan, approval and posting path. Rejecting withdraws the draft.
8. **File.** The AI copies the original to `30-Processed/<person>/<year>/<institution>/` under the naming convention, and adds the index row. The original in `20-Inbox` is never changed.

### W2 Receipts and one-off entries

1. **Read the input.** The AI reads a photo, a receipt or a sentence such as "lunch 23.40 on the Visa".
2. **Draft the entry.** The AI calls `cmd_draft_create_transaction` or `cmd_draft_create_transfer` with the evidence. Both exist today.
3. **[DB] Validate.** The draft is validated and then approved in the PWA.

### W3 Reconciliation

1. **Find the open items.** The AI reads `q_reconciliation_coverage`, `q_reconciliation_exceptions`, `q_transfer_matching` and `q_r30_review_queue`.
2. **Explain each exception, citing evidence.** For each exception the AI gives the likely cause and a proposed action, and it cites the evidence through `q_evidence_trace`.
3. **Decide.** The member sets the exception states and decides the matches in the PWA, which already has these commands. A later step may add AI proposals for exception states (G6).

### W4 Reports and questions (monthly, annual, ad hoc, "what did we spend on X between …")

1. **Choose the content.** The AI decides what the report needs: balances, income and expense, net worth, cards, investments, or a question the member asked.
2. **Fetch every figure through read tools (B1):**
   - `q_f1_balances` … `q_f7_reconciliation`, `q_f2_transactions`, `q_cashflow_statement`;
   - `cmd_create_report_snapshot` for figures that must be reproducible.
3. **Write the narrative.** The AI writes the report text: findings, changes, unusual items and questions for the member.
4. **Save (B4).** The AI saves the report in `40-Exports/<year>/`, with an appendix listing every tool call (name, arguments) and the snapshot ids. A snapshot can be replayed with `q_replay_snapshot`.

No report program is added.

### W6 Historical data: entry and verification (OD-AI-3)

A household that starts using Balnexa brings years of past statements per account. W6 is W1 run over a whole history, oldest first, with checks across the full chain.

1. **Inventory.** The AI lists, per account, every original it has (institution, last 4 digits, period). It reports:
   - the earliest and latest periods;
   - multi-month statements;
   - card reissues: a new card number on the same account, as shown by a carried-over balance;
   - possible duplicates.

   The member confirms the account list.
2. **Opening point.** For each account, the opening balance of the earliest statement becomes the account's opening (`cmd_set_opening`, approved by the member).
3. **Statements in order.** The AI submits each statement through W1, oldest first, so that each one's continuity check runs against its predecessor.
4. **[DB] Chain checks** across the whole history: balance continuity, gaps between periods, overlapping periods, and duplicate statements or lines.
5. **Gaps.** For each gap the AI reports what the neighbouring statements show. The member decides the case:
   - no activity, so no statement was issued: the gap is recorded as explained (e.g. a card with a previous balance of 0.00);
   - a statement is missing: the member uploads it later;
   - an account was opened or closed.
6. **Batch approval.** Statements whose checks all pass can be approved together per account in the PWA (G7). Statements with findings are approved one by one. C-04 still holds: the member approves; only the number of clicks changes.
7. **Verification report.** For each account, the AI writes a history report (W4 rules, B1/B4). It covers:
   - the coverage from the first to the last statement;
   - the explained and open gaps;
   - every continuity break and how it was resolved;
   - the duplicates found;
   - the opening and current balances, read from the database.

### W5 Filing and the index

The AI keeps the folder structure, the copies in `30-Processed` and the index sheet (`Data_Folder_Convention.md`). This work was done by hand in runs 1 and 2; the skill writes it down. Under OD-DATA-7 it starts after go-live.

## 4. Gap list (program work under OD-AI-2)

| Id | Gap | Kind | Size |
|---|---|---|---|
| **G1** | **`cmd_draft_statement`** (RC-DRAFT, MCP + PWA, scope `finance.draft`). Input: account-currency, document/evidence reference, period, printed opening and closing balances, sign convention, lines (dates, amount, description, bank reference) and optional AI proposals. It stores a statement draft and returns the W1-5 check results. A new migration adds the draft tables, the checks and the approval path. On approval it writes `statement`, `statement_event`, `source_txn` and the balance observation, then posts through the existing plan path. The statement table and `source_txn` exist since R1 but have no writer today | migration + catalog | large |
| **G2** | **Evidence identity for Drive files.** The AI cannot compute a SHA-256 of a Drive file. Proposal: register the Drive file id, size and modified time as declared by the AI (state `unverified`); the Executor's `EVIDENCE_VERIFY` job, which today re-hashes R2 copies, is extended to read the Drive file and set the SHA-256 and `verified`. Approval does not wait for it; OD-DATA-5 (no import with deferred SHA-256) is reconsidered by the Owner when real data starts | migration + Executor store | medium |
| **G3** | **PWA statement approval screen:** header, lines, check results, AI proposals, approve and reject. A queue entry per open statement draft | PWA | medium |
| **G4** | **Read tools for the AI:** expose `q_ledger_accounts`, `q_review_queue`, `q_intake_exceptions` and `q_notifications` on MCP (read scopes). These are catalog and scope rows only | migration (small) | small |
| **G5** | **Connector setup guide** for the member: add the Balnexa connector in Claude (web, once); use it on the phone | doc | small |
| G6 | Later: AI proposals for reconciliation exception states and match decisions (RC-DRAFT) | migration | later |
| **G7** | **History support (W6):**
- statement drafts may be submitted for any past period;
- the continuity check uses the nearest earlier **approved or pending** statement of the account-currency, so that a batch submitted oldest-first is checked in order;
- a gap can be recorded as explained (no activity / account opened or closed), with the member's reason;
- the PWA approves all clean statement drafts of one account in one action (each approval is still audited per statement);
- a read tool lists the statement chain of an account with its gaps and breaks | migration + PWA | medium |

**Not needed:** a statement parser, an import job, report programs, or an AI inside the PWA.

### 4a. Skills replace the main development (Owner, 2026-11-16 22:07: "skill替代主要代码开发")

The main development effort goes into **skills**, not code. The program work is cut to what an AI cannot do safely or cannot reach:

| Stays code | Why it cannot be a skill | Kept small by |
|---|---|---|
| G1 + G7 database part | The AI needs a tool to write a statement at all. The balance, continuity and duplicate checks must hold whatever the AI sends (B2) | One `cmd_draft_statement` tool that writes into the existing `statement`/`source_txn` tables through the existing plan path. The checks are SQL inside the same migration |
| G3 + G7 batch approval | Approval is the member's (C-04), and the PWA is the only place it happens | Reusing the existing Draft Confirm screen (`#/confirm/<plan>`): a statement draft is a plan, so the screen gains a statement view, not a new screen |
| G4 | The AI cannot call a function the catalog does not expose | Catalog and scope rows only |
| G2 | The AI cannot hash a Drive file | Deferred until real data (Q1) |

**Everything else is a skill:**
- reading and understanding documents;
- classification;
- the order of a historical import;
- explaining gaps and exceptions;
- reports and answers to questions;
- filing and the index;
- the inventory of a history.

**Not built:** parsers, import jobs, report programs, classification rules in code.

## 5. Skills and how they are distributed

| Skill | Workflow | Writes |
|---|---|---|
| `balnexa-statement-intake` | W1 | statement drafts; after approval, filing (W5) |
| `balnexa-history` | W6 | inventory, opening proposals, ordered statement drafts, gap notes, the history report |
| `balnexa-entry` | W2 | transaction and transfer drafts |
| `balnexa-reconcile` | W3 | an explanation for the member; no writes |
| `balnexa-report` | W4 | reports and answers; a report and its appendix in `40-Exports` |
| `balnexa-filing` | W5 | `30-Processed`, the index |

Each skill states:
- the tools it calls;
- the checks it expects from the database;
- what it must never do: compute report figures, post or approve, store a full card number or a SIN, or change `20-Inbox`.

**Distribution (Owner decision Q2, 2026-11-16).** The same skill text exists in three places:

1. **The household's data folder, which is Balnexa's own Drive directory (the instance copy).** Any AI host can load it, including one that cannot install native skills, such as ChatGPT. The pattern is a Drive-hosted entry and skill index. Balnexa keeps it entirely inside its own folder and never reads or writes the folder of another project:
   - `00-Governance/BALNEXA-AI-ENTRY.md`: the entry an AI reads first. It holds the folder map, the access rules, the Balnexa instance and connector, the B1–B4/C-04 rules, and pointers to the skill index;
   - `50-Skills/Active/<skill>/SKILL.md`: published skills only;
   - `50-Skills/Validation/`: candidates that are not yet published;
   - `10-Index/Skill-Index`: one row per published skill, with name, version, path and SHA-256.

   An AI host without native skills reads the entry, then the skill index, then the `SKILL.md` it needs. It checks the SHA-256 against the index before using the skill.
2. **The member's Claude account (native skills).** Claude proposes each skill and the member saves it from the review card. The text is identical to the Drive copy.
3. **This repository, under `skills/`.** This is a generic copy for every Balnexa user and holds no instance details. Instance values (folder ids, the instance URL) live only in the entry file in the data folder.

A skill is written as a candidate in `50-Skills/Validation/`. It moves to `Active` only when the member publishes it (AI output stays a draft until a person approves it). The data folder convention gains `50-Skills` and the entry file.

## 6. Order

1. G4, G1 and the database part of G7 (one migration), with their tests (refusals, the balance, continuity and chain checks, the duplicate checks, guard parity) and the full regression.
2. G3 and the batch approval of G7 in the PWA, with tests.
3. The data-folder entry and `50-Skills` layout, then the `balnexa-statement-intake` and `balnexa-history` skills. An end-to-end run on **synthetic** statements on the test instance, once it is upgraded and connected (G5).
4. G2, then `balnexa-entry`, `balnexa-report`, `balnexa-reconcile` and `balnexa-filing`.

## 7. Owner decisions on the open questions (2026-11-16 22:04)

| Id | Question | Decision |
|---|---|---|
| Q1 | G2: may a statement be approved while its evidence is still `unverified` (hash pending)? | **Yes** for synthetic testing; decided again before real data |
| Q2 | Where do skills live? | **The household's data folder (Drive), the member's Claude account, and a generic copy in this repository** (§5). The Drive copy is required because some AI hosts (ChatGPT Plus) cannot use native skills, but can load one from Drive |
