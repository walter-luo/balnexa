# Changelog

Each release lists its changes with the issue numbers they fix (`#n`), the migrations it adds, and any action an operator must take. The process is described in `docs/s4/Issue_and_Release_Process.md`. Releases up to 0.9.9-p2 came before the public issue record, so they reference design items instead of issues.

The release string is `V<major>.<minor>-R<nn>` since V1.0-R02 (Owner, 2026-11-16); before that it was `0.<minor>.<patch>-p2` (S4 phase 2). A release supports the schema range in `apps/worker/src/release.js` and has the migration digests in `release/manifest.json`.

## Unreleased

- **Holds say where (9046, F-LIVE-1).** `validation_result` texts name the figures (V-04, ledger sign), the line numbers (V-09) and the line, date and opening date (V-12); hold codes unchanged. The draft screen lists each hold as a sentence.
- **Line review of statement drafts (9046, F-LIVE-2, G3).** On the draft screen of a statement, a member who may post to the account picks a category or the other account (card payment, transfer) per line and ticks Reviewed; saving makes a new version for approval (`cmd_review_statement_items`, PWA only). Dates, amounts and descriptions stay the statement's.
- **Starting balance amount (F-LIVE-5).** The catalog generator reads `bnx.dec` keys, so **Set starting balance** has its amount field, also for existing accounts.
- Skills `balnexa-statement-intake` and `balnexa-history` 0.3.0: card sign example, submit once, check the other account of a transfer, transfer openings in history.
- Runbook: release order for one migration; open AI conversations keep their old tool list (F-LIVE-6).
- **Default categories (9045, OD-CAT-1).** 89 built-in categories in two levels, English and Chinese, modelled on common household finance software; added on upgrade and by the installer, never duplicating a member's own category. Quick Entry and Set up accounts show "Parent › Child".
- **Accounts from statements (9045, OD-ACC-1, two-step approval).** New MCP tool `fin.account.propose_from_statement`: the AI proposes an account read from a statement; the member approves it on Review, which also sets the opening balance from that statement and lets the AI connection see the account; the AI then submits the statement. An AI connection sees only its own proposals; an existing account is refused without naming it.
- **Draft screen.** Account, statement header and the name of every line's account or category (also in the MCP result).
- Cash and other-asset accounts are created without an institution (was refused as "Please check the field: ?").
- Skills `balnexa-statement-intake` and `balnexa-history` 0.2.0.
- **Claude can connect (9044).** Claude's custom connector identifies itself with a Client ID Metadata Document, `https://claude.ai/oauth/mcp-oauth-client-metadata`, which was not allowlisted, so the first real connection stopped at "Unknown client or unregistered redirect URI". 9044 allowlists it and adds Claude's announced `claude.com` callback. The 401 scope hint now names `finance.draft`, because Claude requests exactly the hinted scopes; the consent screen still starts with drafting unticked. Tests AT-AIH-06c, BB-OAUTH-03 (claude.com), UT-BIND-01.
- **Skills: index, entry template and life cycle** (AI-first design §5). `skills/README.md` describes the three copies of a skill (this repository, the household's data folder, the member's AI account) and the life cycle candidate → active → retired. `skills/INDEX.csv` records version, status, size and SHA-256 per skill; `tools/s4/skill_index.py --check` (in CI) refuses a stale row, a malformed skill or an instance detail in a generic skill. `skills/BALNEXA-AI-ENTRY.template.md` is the template of the entry file an AI reads first in the data folder. Skills `balnexa-statement-intake` and `balnexa-history` 0.1.0 (candidates).
- Data folder convention: `40-Reports/<year>/<month>/` for AI reports (OD-IO-4), `50-Skills` and the entry file (§7). Input and output design OD-IO-1..5 recorded in `docs/s4/OWNER_DECISIONS_2026-11-16.md`.
- Runbook: the installer's secrets file nests the Worker connection strings under `runtime`; extract that object before `wrangler secret bulk`.
- Migrations: 9044, 9045, 9046. Release string V1.0-R06 (proposed; the Owner decides). V1.0-R04 and V1.0-R05 are deployed on the test instance but not published.
- **Operator action:** deploy the Worker first, then migrate (one migration per step, no gap).

## V1.0-R03 — 2026-11-17

- **AI-first statement intake, database part (9043).** The AI submits a statement as printed, with its period, opening and closing balances and every line (`fin.draft.create_statement`). The database checks it: opening + lines = closing, duplicates, coverage, continuity with the previous statement (V-11), and the opening anchor (V-12). A member approves it in the PWA. New read tools for the AI: `fin.statements.chain` and `fin.ledger.accounts`. A member can explain a gap or a balance break (PWA). Design: `docs/s4/S4_AI_First_Workflows_Design_2026-11-16.md`.
- V-12 holds a plan with an item before the opening anchor, before approval. Before this change, the posting worker refused it after approval.
- Migrations: 9043.
- **Operator action:** deploy the Worker first, then migrate to 9043.

## V1.0-R02 — 2026-11-16

First release under the release naming of 2026-11-16: `V<major>.<minor>-R<nn>`. R counts releases, and V changes only when the Owner decides on a larger functional step. Releases up to 0.9.9-p2 keep their old names.

- **Idle cron ticks no longer touch the database** (#52). The cron handler decides from KV first and runs the binding check only on a tick that will read the database (work hinted, or a backstop tick every 3 hours). Before, the binding check queried the database on nearly every one-minute tick, so a Neon compute never suspended: about 6 CU-hours a day at 0.25 CU, which uses up the Free plan's 100 CU-hours per project in about 16 days. New test BB-PLAN-03.
- Migrations: none. Schema range unchanged.
- **Operator action:** deploy the Worker.

## 0.9.9-p2 — public issue record

- **Public issue record.** The GitHub issue forms are: problem report, wrongly refused (SIN or card-number guard), idea, question. Blank issues are off.
- **Private reports.** Security reports go through private vulnerability reporting (`SECURITY.md`).
- **Labels.** The label scheme is in `.github/labels.json`, applied with `tools/s4/sync_labels.py`. Each release has one milestone.
- **Privacy guard for issues.** `issue-guard` redacts a SIN-like or full card number from new and edited issues and comments, and labels the issue `privacy:redacted`.
- **PWA.** Settings shows the version and links to the problem form, with the release prefilled.
- Migrations: none. Schema range: 9041–9042, unchanged.
- **Operator action:** deploy the Worker. The PWA shell cache name changes, so browsers load the new Settings screen.

## 0.9.8-p2 — card-number detector v1.1.0 (OD-PAN-1)

- Any 16–19 digit number that passes the Luhn check counts as a card number, whatever its prefix. Debit prefixes differ by bank.
- Storage object generations (`generation`, `object_generation`) are exempt by key.
- Migration 9042.

## 0.9.7-p2 — card-number guard (D-PAN-1)

- A full card number is never stored. Commands, audit entries and staged results that hold one are refused with `PAN_CANDIDATE`, and index records keep the last 4 digits.
- The repository is scanned in CI.
- Migration 9041.

## 0.9.6-p2 — NULL-guard sweep (L-R2-1)

- Fixes 15 places where a missing, null or empty field was accepted. Examples: import plans without dates, members with an empty name, backups without retention.
- The sweep tool and its dispositions are kept.
- Migration 9040.

## Earlier releases

| Release | Migration | Change |
|---|---|---|
| 0.9.5-p2 | 9039 | G0 remediation R2: NULL-safe guards |
| 0.9.4-p2 | 9038 | G0 remediation: collation independence |
| 0.9.3-p2 | 9037 | Output schemas, part 8 |
| 0.9.2-p2 | 9036 | Output schemas, part 7 |
| 0.9.1-p2 | 9035 | Output schemas, part 6 |
| 0.9.0-p2 | 9034 | Output schemas, part 5 |
| 0.8.9-p2 | 9033 | Output schemas, part 4 |
| 0.8.8-p2 | — | PWA account setup screen |
| 0.8.7-p2 | 9032 | Curated MCP output schemas and signed releases |
| 0.8.6-p2 | 9031 | MCP tool descriptions |
| 0.8.5-p2 | 9030 | Audit subject keys of corrections |

For releases before 0.8.5-p2, see `git log` and `docs/s4/S4_Migration_Register_Addendum_9017_9032.md`.
