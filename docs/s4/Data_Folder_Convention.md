# Balnexa — data folder convention (source documents outside the repository)

`DRAFT — AI-generated` (Claude). It becomes authoritative once the project Owner confirms it. Decisions: OD-GH-3 and OD-GH-4 (`docs/s4/OWNER_DECISIONS_2026-11-13.md`); OD-DATA-1 to OD-DATA-3 (`docs/s4/OWNER_DECISIONS_2026-11-14.md`).

Balnexa is a general-purpose household finance system. Each household that runs it keeps its **source documents**, such as bank statements, tax slips, notices and receipts, in a folder it controls. That folder may live on a cloud drive (for example Google Drive) or a local disk. It is never kept in this repository: the repository holds code, synthetic test data and test records only (gate O-8).

This document describes how such a folder is laid out and how an AI assistant may work in it. It names no household, person, account or location. A household that adopts it records its own instance, including where the folder is and which names it uses, **privately**, outside this repository.

## 1. Roles

| Role | Who | Writes to | Reads |
|---|---|---|---|
| **Data owner** | The household member who receives and uploads the documents | `20-Inbox` only | everything |
| **AI assistant** | An AI working on the data owner's behalf | every folder except `20-Inbox` | everything |

The roles are a convention. If the AI works through the data owner's own account, the storage cannot tell them apart and cannot enforce the rule. §5 describes how integrity is still checked. A household that wants the rule enforced gives the AI a separate account: read-only on `20-Inbox`, and edit rights on the other folders. Some AI connectors can edit only the files the AI itself created, which enforces the rule in practice; check what the connector in use reports rather than assume it.

## 2. Folders

| Folder | Managed by | Purpose |
|---|---|---|
| `00-Governance` | AI | This instance's README: a pointer to this convention plus any local additions |
| `10-Index` | AI | The index: one row per original in `20-Inbox` (§4) |
| `20-Inbox` | **Data owner** | Originals exactly as received. The AI only reads them: it never renames, moves, edits or deletes |
| `30-Processed` | AI | Byte-identical copies of the originals, renamed and filed (§3) |
| `40-Exports` | AI | Backups and reports exported from Balnexa |
| `90-Review-exchange` | AI | Large review outputs that do not fit in the repository (synthetic data only) |

## 3. Layout and names

```
20-Inbox/<person or Joint>/<year>/<original file name>
30-Processed/<person or Joint>/<year>/<institution>/<YYYY-MM-DD>_<institution>_<last4>_<type>_<period>.<ext>
```

- **`<person>`:** whose document it is, as the household names its members. Use `Joint` for joint accounts and other shared documents. This is the one thing the data owner sorts by hand, because it often cannot be read from the document.
- **`<year>`:** the year of the statement period, or the tax year, not the date received. A statement that spans two years goes under the year its period ends.
- **In `20-Inbox` the data owner keeps the original file names.** Institution and document type are identified by the AI from the content.
- **In `30-Processed`:**
  - `YYYY-MM-DD` is the statement or issue date;
  - `last4` is the last four digits of the account, or `na`;
  - `type` is for example `statement`, `T4`, `T5`, `notice` or `receipt`;
  - `period` is `YYYY-MM`, `YYYY-Qn` or `YYYY`. A statement that covers several months uses `YYYY-MM~YYYY-MM`, from the first month after the previous statement date to the month of its own date.

  Examples: `2026-10-31_BANK_1234_statement_2026-10.pdf`; a statement dated 2026-11-30 that covers June to November: `2026-11-30_BANK_1234_statement_2026-06~2026-11.pdf`.
- **Copy, never move.** A processed file is a byte-identical copy of its original and has the same sha256 (§5 covers a run where sha256 cannot yet be computed).
- **Government identifiers.** Mask any Social Insurance Number (or equivalent) on a document **before** it is uploaded. Balnexa never stores one, and neither does this folder.

## 4. Index

One spreadsheet in `10-Index`, one row per original:

`inbox_path, inbox_file_id, sha256, size_bytes, inbox_modified, person, year, institution, account_last4, doc_type, period, processed_path, processed_file_id, status, checked_at, notes`

`status` is `NEW`, `PROCESSED`, `IMPORTED` (into Balnexa) or `ISSUE`. Account numbers appear as the last four digits only.

## 5. A processing run (AI)

1. List `20-Inbox` and compare it with the index. Look for new originals and for originals that changed or disappeared, by sha256 (or, while it is deferred, by file ID and size) and modified time.
2. For each new original: read it, compute its sha256, and identify the institution, account (last 4), type and period.
3. Copy it to `30-Processed` per §3, and confirm that the copy's sha256 equals the original's.
4. Add or update the index row. Anything that cannot be determined is left unfiled as `ISSUE`, with the question.
5. Report what was filed, what is `ISSUE`, and any original that changed. A changed or missing original is reported, never repaired.

**Batch rule:** for a new batch, the AI first shows the plan (each file, its new name and its folder) and waits for the data owner's confirmation.

**When sha256 cannot be computed (OD-DATA-2).** Some toolchains cannot hash a file without passing its whole content through the AI conversation; a cloud-drive connector that copies files on the server but offers no hashing is an example. Passing every file through the conversation is not acceptable, so with the data owner's approval for the run, sha256 is **deferred**:

- the copy is made on the storage side (server-side copy), never by downloading and uploading through the AI;
- the index records the original's file ID, size and modified time, and the copy's file ID;
- the copy's size must equal the original's; a mismatch is an `ISSUE`;
- `sha256` is left blank and `notes` says that it is deferred and who approved it;
- the status is still `PROCESSED`;
- sha256 is computed for every deferred row, original and copy, once a tool that can hash locally is available (for example the Balnexa Executor, or a script on the data owner's machine). Until then, step 1 detects changed originals by file ID, size and modified time, which is weaker: an edit that keeps the same size and time would go unnoticed.

A size match shows that the copy is complete; it does not prove the bytes are identical. A server-side copy makes a difference unlikely, and the later sha256 check closes the gap. Import into Balnexa (`IMPORTED`) waits until that check has passed.

## 6. Privacy

- The folder and its files are never shared by link.
- An instance's location, its member names and its files are not written in this repository or in any public place.
- Review exchange files (`90-Review-exchange`) hold synthetic data only.
