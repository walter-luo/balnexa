# Balnexa S4 phase 2 — TST-5 mock providers, DOC-2 document pipeline, INT-2 index consumer, INT-3 mail retrieval (migration 9025)

| Field | Value |
|---|---|
| Status | `DRAFT — AI-generated`; becomes authoritative once the Owner confirms it |
| Date | 2026-11-12 |
| Authority | Owner instruction 2026-11-12 13:24: "你继续做完后面的功能，后面再测试" ("continue and finish the remaining features; testing later"). The plan is document 02 §6 phase 2, items 2.1, 2.2 and 2.3 |
| Scope tags | TST-5 (all), DOC-2 (EXT-DOC; statements are V1-CORE), INT-2 and INT-3 (V1-CORE channels) |
| Evidence grade | `AUTHOR_RUNTIME_EVIDENCE` (local PG16 and PG17), plus CI on the PR |
| Data | Synthetic only. No cloud resource, Drive, mailbox or sheet was contacted |

## 1. What was built

| Part | Content |
|---|---|
| `apps/executor/bnx_exec/providers.py` (TST-5) | Narrow provider interfaces with directory-backed mocks under `BNX_MOCK_ROOT`. **Drive:** Inbox with revisions and md5, exact-revision fetch, head, an idempotent Processed copy, read-back. **Shared index:** Records, Open_Items and Run_Log read from JSON, CSV (`CSV_IN_DRIVE`) or a Markdown table (`MARKDOWN_TABLE`). **Mailbox:** exact fetch by RFC 5322 Message-ID, folder move, `.eml` builder for fixtures. The real clients (`GoogleDrive`, `GoogleSheetsIndex`, `GmailMailbox`, `GraphMailbox`) raise `ProviderNotConfigured` until M0-B authorizes their identities |
| `apps/executor/bnx_exec/docjobs.py` (DOC-2) | `DOC_DISCOVER`: one lease per Inbox file (`drive:<file_id>`). It stages the identity only (`doc_discovered`), and the file name only when it holds no candidate. `DOC_PROCESS`: the lease input names the step. **VALIDATE** fetches exactly the discovered revision, checks the md5, scans it in the isolated validator and stages the verdict. **ARCHIVE** fetches again, writes the Processed copy, re-hashes the copy and stages hash, size and type. Mail attachments are addressed by Message-ID and part number (`mail_part`, `mail_attachments`; the same numbering is used by INT-3) |
| Migration 9025 | `bnx.exec_work_order` MODIFY: a `DOC_PROCESS` lease for a discovery carries source identity, state and step. A discovery with nothing to do gets step `NONE` and the Executor stages nothing. 9025 adds no new lease refusal: an unknown item still gets a null work order, as before, and the promoters stay the validators of record. NEW `bnx.wrk_exec_due(p)`: the discoveries to validate (new, or re-scan due after a detector change) and the admissible ones to archive |
| `apps/executor/bnx_exec/intjobs.py` (INT-2, INT-3) | `INDEX_CONSUME` (item = source id): reads the upstream index through the mock (JSON, CSV or Markdown). It keeps the 15-column contract and marks a record `FILED_VERIFIED` only when its File ID is readable in the instance's Drive. It masks candidates (the database masks again), sends records in Processed Date order within a 200 kB budget and stages `index_consumed`. `MAIL_EXACT_FETCH` (item = `<source_ref>\|<Message-ID>`): fetches exactly that message and keeps the `.eml` as content-addressed evidence. It stages `mail_fetched` with the canonical key, sender domain, counts and evidence hash, never the subject or body. `MAIL_MOVE` (item = canonical key): moves the message to the folder the route names. `DOC_DISCOVER` also takes `mail:<source_ref>\|<Message-ID>\|<part>` for attachments |
| Migration 9025, intake part | Work orders: `INDEX_CONSUME` (adapter, location reference, cursor), `MAIL_EXACT_FETCH` and the mail-attachment `DOC_DISCOVER` (provider and credential state; the Executor stages nothing unless it is `authorized`), `MAIL_MOVE` (the route's folder, absent when there is no route or nothing to do). NEW `bnx.mail_route_folder`: the institution route on the received date, else the coverage-home rule. The due list adds `INDEX_CONSUME` (enabled sources) and `MAIL_MOVE` (fetched, verified, routed elsewhere) |
| Gateway | `POST /exec/v1/due` with the same pinned job identity as `/exec/v1/lease`; `bnx_worker` calls `bnx.wrk_exec_due` |
| Executor CLI | `python -m bnx_exec run --kind DOC_DISCOVER` lists the Inbox; `--kind DOC_PROCESS` asks the Gateway for the due list. `--item` still overrides both |

## 2. Decisions taken under the delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-DOC2-1 | 9025 is outside the V1.2 migration register, like 9017–9024 | Register rows are owed (document 02 §6 phase 0) |
| D-DOC2-2 | Discovery stays in the Executor (it lists the Drive Inbox); the database only knows what was staged. The due list covers `DOC_PROCESS` only | The database holds no Drive credential. The promoter already dedupes repeated revisions (`new = false`) |
| D-DOC2-3 | A changed hash at ARCHIVE is still staged. The admission gate returns the document to `DISCOVERED` (`HASH_MISMATCH`) | The gate is the authority (D-9011b-3); the Executor must not decide admission |
| D-DOC2-4 | An md5 mismatch at fetch (the bytes behind the discovered revision changed) is not staged. The item fails with `MD5_MISMATCH` and the next discovery picks up the new revision | No verdict is ever recorded for bytes other than the discovered ones |
| D-DOC2-5 | No document class is assigned, so every verdict is `class_uncertain` and the Owner declares | There is no classifier (L-13, D-9011c-5) |
| D-DOC2-6 | Ids the mocks generate, and the archive id of a mail part, carry no digit | The staging guard refuses Luhn-valid runs outside exact hex or UUID values (F-M0A-01) |

## 3. Tests — `AUTHOR_RUNTIME_EVIDENCE`

| Test | Shows |
|---|---|
| AT-DOC2-01 (`run_s4_core18.py`) | Three files on the mock Drive, run through the real Executor handlers with a database shim. **Discover** stages identities; repeats are promoted as known. **Validate:** the clean CSV statement goes to `PENDING_DECLARATION`, a PDF with a visible value goes to `QUARANTINED`, and a ZIP goes to `SCAN_INCOMPLETE`. Nothing else is due, and a run for the quarantined document stages nothing (`NOTHING_TO_DO`). After the Owner's declaration the statement is due for ARCHIVE: the Processed copy is written and re-hashed, the document is `ARCHIVED` and its evidence `USABLE`. Changed bytes behind an identity give `MD5_MISMATCH` and are not staged. A new revision is a new discovery, and the archived document is kept. No value reaches staging; `audit_verify` is 0 |
| AT-TST5-01 | Mock contracts: Drive revisions, `REVISION_GONE`, idempotent Processed copy; the index read back from JSON, CSV and Markdown; mailbox exact fetch, attachment numbering and move; the real providers refuse until M0-B; generated ids carry no digit |
| AT-INT-01 | The index household's source is due; one lease stages the masked index; 3 records are stored. The record whose File ID is in the Drive is `FILED_VERIFIED`, the other is not. A CRA notice produces a notification. A value in Notes never reaches staging or the record table. A second run replays |
| AT-INT-02 | Exact fetch by Message-ID is staged without subject or body, and the `.eml` is kept as evidence. A missing message gives `MESSAGE_NOT_FOUND`. A mailbox without an authorized credential stages nothing. The PDF attachment is discovered as `MAIL_ATTACHMENT` part 1 and validated through the mailbox. No move is due before a route; with the institution route the message moves and the item is `MOVED`; then nothing is due |
| BB-EXEC-03 | `POST /exec/v1/due` over HTTP: the pinned identity is required; `DOC_PROCESS` returns `{items: []}` on an empty household; an unsupported kind gives `VALIDATION_FAILED` |

## 4. Limits

| ID | Item | Handling |
|---|---|---|
| L-DOC2-1 | Real Drive file and revision ids contain digits. One holding a Luhn-valid 9-digit run would be refused by the staging guard (`head_revision_id` and `source_file_id` are not exact hex) | Qualify at M0-B with PV-DRV-01. The likely fix is a digest-keyed exemption for provider ids, which is a guard-spec change (D-9011R-1) and needs the Owner |
| L-DOC2-2 | The Worker tick does not launch Executor jobs yet (Cloud Run is M0-A). Runs are manual or scheduled outside the Worker | M0-A |
| L-DOC2-3 | `bnx.document` rows (statement segmentation) and the second copy (`dual_verified`) are not written | Statement work packages; M0-B-08 |
| L-INT-1 | Real Message-IDs often contain long digit runs. `message_id` is not exact hex, so a Luhn-valid run is refused by the staging guard, and the canonical key alone cannot carry the fetch. The mocks use digit-free ids | Owner decision with L-DOC2-1 (guard exemption for provider identifiers, or staging only digests of them) before real mail |
| L-INT-2 | There is no command to create mail folder routes or route rules yet; the tables exist (9010) | PWA mail settings, with INS-2 |
| L-INT-3 | Nothing yet creates `MAIL_EXACT_FETCH` requests automatically from index records; the Executor takes them as items | Index-to-mail linking needs the record contract for message ids (SI) |
| L-DOC2-4 | No Documents screen in the PWA beyond the redaction queue | DOC-5 |
