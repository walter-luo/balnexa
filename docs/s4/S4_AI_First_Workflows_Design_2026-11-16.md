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

**Withdrawn by OD-AI-1:**
- the Executor's document and import handlers (`DOC_*`, `IMPORT_PARSE`);
- a statement parser;
- any new fixed report family.

The functions already built stay, and the AI uses them as tools.

## 2. Roles

| Part | Role |
|---|---|
| **AI host** (Claude, Pro plan) with **skills** | Runs every workflow. It reads documents from Drive or from an upload, extracts the content, calls Balnexa tools through the custom connector, writes reports, and files documents. A skill is the written procedure and checklist for one workflow |
| **Balnexa Gateway + database** | Tools (MCP and REST), validation, drafts, approval, posting, the audit trail and the guards. No document parsing and no report logic |
| **PWA** | Viewing, the approval queue, manual entry and settings. It contains no AI (AI in the PWA would need the paid API) |
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

### W4 Reports (monthly, annual, ad hoc)

1. **Choose the content.** The AI decides what the report needs: balances, income and expense, net worth, cards, investments, or a question the member asked.
2. **Fetch every figure through read tools (B1):**
   - `q_f1_balances` … `q_f7_reconciliation`, `q_f2_transactions`, `q_cashflow_statement`;
   - `cmd_create_report_snapshot` for figures that must be reproducible.
3. **Write the narrative.** The AI writes the report text: findings, changes, unusual items and questions for the member.
4. **Save (B4).** The AI saves the report in `40-Exports/<year>/`, with an appendix listing every tool call (name, arguments) and the snapshot ids. A snapshot can be replayed with `q_replay_snapshot`.

No report program is added.

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

**Not needed:** a statement parser, an import job, report programs, or an AI inside the PWA.

## 5. Skills

| Skill | Workflow | Writes |
|---|---|---|
| `balnexa-statement-intake` | W1 | statement drafts; after approval, filing (W5) |
| `balnexa-entry` | W2 | transaction and transfer drafts |
| `balnexa-reconcile` | W3 | an explanation for the member; no writes |
| `balnexa-report` | W4 | a report and an appendix in `40-Exports` |
| `balnexa-filing` | W5 | `30-Processed`, the index |

Each skill states:
- the tools it calls;
- the checks it expects from the database;
- what it must never do (compute report figures, post, approve, store a full card number or a SIN, change `20-Inbox`).

The repository keeps a generic copy of each skill under `skills/` for every Balnexa user. Each member saves them to their own Claude account.

## 6. Order

1. G4 and G1 (one migration), with their tests (refusals, the balance and continuity checks, the duplicate checks, guard parity) and the full regression.
2. G3 in the PWA, with tests.
3. The `balnexa-statement-intake` skill. An end-to-end run on **synthetic** statements on the test instance, once it is upgraded and connected (G5).
4. G2, then `balnexa-entry`, `balnexa-report`, `balnexa-reconcile` and `balnexa-filing`.

## 7. Open questions for the Owner

| Id | Question | Recommendation |
|---|---|---|
| Q1 | G2: may a statement be approved while its evidence is still `unverified` (hash pending)? | Yes for synthetic testing. Decide again before real data |
| Q2 | Where do skills live: only in the Owner's Claude account, or also as a public copy in the repository? | Both. The public copy is generic, with no instance details |
