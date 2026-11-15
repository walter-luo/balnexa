# Changelog

Each release lists its changes with the issue numbers they fix (`#n`), the migrations it adds, and any action an operator must take. The process is described in `docs/s4/Issue_and_Release_Process.md`. Releases up to 0.9.9-p2 came before the public issue record, so they reference design items instead of issues.

The release string is `<major>.<minor>.<patch>-p2` (S4 phase 2). A release supports the schema range in `apps/worker/src/release.js` and has the migration digests in `release/manifest.json`.

## Unreleased

Nothing yet.

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
