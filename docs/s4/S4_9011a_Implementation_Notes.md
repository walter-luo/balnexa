# Balnexa S4 — 9011a implementation notes: SIN/ITN detector and database guards

| Field | Value |
|---|---|
| Stage | 9011a, the first of three sub-stages of WP-DOC migration 9011 (D-ST-2). 9011b adds intake states, the declaration command and the admission check; 9011c adds the Executor validators |
| Authority | Addendum A1 Rev 1 (branch `s4/design-addendum-a1`): §3 detector, §7 DOC-SIN-10, guards C1, C2 and C6. Owner decisions A1-OD-1…3 and the delegation of 2026-11-10 (`docs/s4/OWNER_DECISIONS_2026-11-10.md`) |
| Base | `main` at `ee13eee` |
| Evidence grade | Every PASS below is `AUTHOR_RUNTIME_EVIDENCE` |
| Data | Synthetic only. The corpus holds templates; nine-digit values are generated at test time and never written to the repository or to evidence |
| Migration 9011 | `db/migrations/9011_s4_documents_evidence_renditions.sql`, SHA-256 `3f217bac59ab1c39a385322041b38e1e01685136de50a9bd10e78c1bdaa798e6` at this stage. **This checksum changes in 9011b and 9011c.** That is safe only because 9011 has not been applied to any persistent database. It is merged once, after 9011c |

## 1. What was built

| Item | Where |
|---|---|
| Detector specification v1.0.0 (labels EN/FR/ZH, proximity windows, separators, Unicode digit table, CRA program identifiers, ITN prefixes, OCR parameters), with a generator and a check mode | `spec/sin-detector/sin_detector_v1.json`, `tools/s4/gen_sin_detector_spec.py` |
| Reference implementation, all origins including `ocr` | `apps/executor/bnx_exec/sin_detector.py` |
| Worker implementation (`native`, `typed`; `ocr` refused) | `apps/worker/src/sin_detector.js` |
| SQL implementation (`native`, `typed`; `ocr` refused): `sin_detector_spec`, `sin_luhn`, `sin_normalize`, `sin_fold`, `sin_scan`, `sin_candidate`, `sin_key_is_label`, `sin_scan_json`, `sin_json_has`, `sin_mask_json`. Internal functions, not granted to any runtime role | Migration 9011 |
| Guard C2 in `bnx.audit` (MODIFY of 9005): a candidate in any audited payload or subject refuses the command with `SIN_CANDIDATE`; the value is never echoed | Migration 9011 |
| DOC-SIN-10 in `bnx.stage_write` (MODIFY of 9010): `index_consumed` payloads are masked; every other staging kind is refused | Migration 9011 |
| DOC-SIN-10 in `bnx.wrk_consume_shared_index` (MODIFY of 9010): a masked record is `BLOCKED` with reason `SIN_CANDIDATE`; no columns are stored for it, only the record key and version hash; an Owner-only exception is raised | Migration 9011 |
| Intake exception class `SIN_CANDIDATE` | Migration 9011 (constraint replaced) |
| Synthetic corpus (92 cases) and generator | `tests/fixtures/s4/sin_corpus_v1.json`, `tests/py/sin_corpus.py` |
| Tests | `tests/py/run_s4_core5.py` (CI picks it up through `run_s4_core*.py`), `tests/py/sin_js_runner.mjs` |
| Guard C6: repository scan of tracked files and the full history | `tools/s4/sin_repo_scan.py`; CI job `secret-scan` |
| Inventory | `tests/py/run_s4_core1.py` AT-INV-01 declares the 10 detector helpers. 9011 is only partly implemented, so its disposition rows stay out of scope until 9011c |

## 2. Decisions taken under the Owner delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9011a-1 | A nine-digit sequence that **starts inside** a hex token of at least 32 characters, or inside a UUID, is not a candidate, even next to a label. Shorter hex tokens get no exemption | SHA-256 values, bytea dumps and UUIDs contain Mod-10-valid digit runs often enough (about one hash in ten) to block staging and audits. They are machine data, not a SIN written as text. Two real false positives came out of this repository: a dump column break, and a manifest line naming a "SIN" file. This rule is not in Addendum A1 Rev 1 §3 and is to be folded into its next revision |
| D-9011a-2 | Shared-index payloads are masked at `stage_write` instead of refused | One record with a candidate must not stall a whole index run. Masking keeps the value out of staging, and the consumer blocks exactly that record (DOC-SIN-10) |
| D-9011a-3 | `bnx.audit` refuses (it does not mask) any audited payload or subject containing a candidate. This is the single generic C2 guard for every audited command | Requirement 6 says SIN values are rejected in structured fields. Refusing at the one function every mutating command passes through covers all entry points, including those C2 does not list (category names, account labels, transaction descriptions). Masking would let the command store the value elsewhere |
| D-9011a-4 | The `ocr` origin exists only in the Python reference. SQL and JS refuse it | Only the Executor runs OCR. Refusing elsewhere is fail-closed |
| D-9011a-5 | Separators: one dash, or one or more spaces after normalisation; no whitespace collapsing | Code-point positions stay stable across the three languages. The matching behaviour is the same as collapsing |
| D-9011a-6 | Label word boundaries are broken only by an ASCII letter (after folding), not by a digit, so a label glued to digits (`SIN` immediately followed by the number) still counts. Chinese labels match as substrings | Fail closed |

## 3. Test results — `AUTHOR_RUNTIME_EVIDENCE`

Local runs on 2026-11-10, PostgreSQL 16.15 and 17.11, Python 3.13, Node 22.

| Suite | PG16 | PG17 |
|---|---|---|
| R1 `run_g0.py` | 40/0/0 | 38/0/2 (AT-BAK-01/02: no local pg_dump 17; CI runs them) |
| `run_s4_core1.py` | 12/0/0 | 12/0/0 |
| `run_s4_core2.py` | 12/0/0 | 12/0/0 |
| `run_s4_core3.py` | 9/0/0 | 9/0/0 |
| `run_s4_core4.py` | 11/0/0 | 11/0/0 |
| `run_s4_core5.py` (new) | 5/0/0 | 5/0/0 |
| Black-box API | 8/8 | 8/8 |
| Dispatch simulation | exit 0 | — |
| `sin_repo_scan.py --all-history` | 0 hits | |

New tests:

| Test | Shows |
|---|---|
| AT-SIN-11 | Python, JS and SQL give identical hits (rule, start, end, path) on all 84 native/typed cases (57 hits). The embedded spec equals the spec file. The generator check is clean. `ocr` is refused by SQL and JS |
| AT-SIN-12-15b | Expected rules for every corpus case: base rule, labels in four scripts, proximity windows, boundaries, BN program accounts for all 13 identifiers and their negatives, Unicode normalisation (13 cases), ITN, machine tokens, OCR (Python) |
| AT-SIN-08a | Refusal with `SIN_CANDIDATE` and no echo for a direct posting description, a category name, an import plan item description and a `doc_validated` staging payload (no row, lease unused). In the shared index, records with candidates are blocked and store no columns, while the clean record is consumed. No value appears anywhere in the database. `audit_verify` is 0 |
| AT-MUT-04 | With the audit guard removed, the same posting is accepted, so the tests detect the guard's absence |
| AT-SIN-C6 | The repository scan is clean |

## 4. Known limits and consequences

| ID | Item | Handling |
|---|---|---|
| L-1 | **Operational false positives.** A transaction description or reference containing a nine-digit number that happens to pass Mod 10 (about 1 in 10 random nine-digit numbers), or that begins 08/09, is now refused. This also applies to imported bank lines | Intended (fail closed, A1-OD-1). FP-SIN-01 measures the rate; the 5 % review trigger of A1-OD-2 applies |
| L-2 | Guard C4 (MCP tool responses and assembled prompts) and C3 (log scrubbing) are not wired into the Worker yet; the JS detector is ready | 9011b |
| L-3 | The OCR rules exist in the reference implementation only. No OCR engine is connected; `T_ocr` = 0.90 is provisional | 9011c (D-A1-4) |
| L-4 | NFKC is taken from each runtime's Unicode tables (Python 15.x, Node ICU, PostgreSQL). The spec pins the decimal-digit table; rare compatibility characters could normalise differently between runtimes | The corpus covers the characters that matter; AT-SIN-11 fails on any divergence it sees |
| L-5 | Audits now scan their payload. A cheap pre-filter skips the full scan when no nine-digit pattern exists, and suite timings did not change measurably | Watch in 9011b/c |
| L-6 | D-9011a-1 is a design refinement made under the delegation | Fold into Addendum A1 Rev 2 |

---

# 9011b — discovery, scan verdicts, declaration and admission

| Field | Value |
|---|---|
| Authority | Addendum A1 Rev 1 §2, §4, §5, §7 (DOC-SIN-04/05/06/08/11/12/13/14), guards C3 and C4; Owner decisions A1-OD-2 and A1-OD-3 |
| Evidence grade | Every PASS below is `AUTHOR_RUNTIME_EVIDENCE` |
| Scope boundary | Document bytes never reach the database. The Executor stages identities, verdicts and re-fetched hashes only. Registration in Z3 (`bnx.evidence_object`, `bnx.document`, `bnx_doc.document_revision`, Drive archive copy) and the Executor validators follow in 9011c |

## 1. What was built (migration 9011, same file)

| Item | Detail |
|---|---|
| `bnx_doc.document_discovery` | Source identity per revision. Drive: `source_file_id`, `head_revision_id`, `md5`, `size_bytes`, `source_mtime`. Mail: `mail_message_id`, `mime_part`. Also module, period, and the original name or `name_withheld`. Append-only |
| `bnx_doc.document_scan` | One row per verdict: `sha256`, `sin_detector_version`, `scan_result` (`PASSED`, `SIN_CANDIDATE`, `SCAN_INCOMPLETE`), rule codes, locators (positions only; validated), class, `class_uncertain`, `sin_bearing`. Append-only |
| `bnx_doc.document_declaration` | The Owner's declaration bound to discovery, SHA-256, revision and source identity. Append-only |
| `bnx_doc.document_state_event` | `DISCOVERED`, `SCANNING`, `QUARANTINED`, `SCAN_INCOMPLETE`, `PENDING_DECLARATION`, `ADMISSIBLE`, `ARCHIVED`, `INVALIDATED`. Append-only, with a transition trigger (`trg_doc_state_transition`). `QUARANTINED` and `INVALIDATED` are terminal. `SCAN_INCOMPLETE` can only be scanned again under a new detector version |
| `bnx_doc.document_current` | View: state, latest scan, `declaration_status` (`NOT_REQUIRED`, `PENDING`, `DECLARED`, `INVALIDATED`) and `source_fidelity`. The three controls are separate fields; there is no `redaction_status` |
| Promoters | `wrk_doc_discovered` (a new revision invalidates earlier unarchived ones), `wrk_doc_validated` (verdict, state, Owner notification), `wrk_doc_archived` (the admission gate). They are dispatched by `wrk_promote_staged` (MODIFY of 9010) |
| Commands | `cmd_doc_declare_redacted` and `cmd_doc_tag_sin_bearing`: Owner only, PWA channel only, tier 3. Not in the MCP catalog, not executable by the worker |
| Query | `q_doc_redaction_queue` (Owner): pending, quarantined and admissible documents, labelled "Owner-redacted copy — not the issuer's original" where applicable. No locators, no content |
| Re-scan | `wrk_doc_rescan_due` lists documents whose last scan predates the current detector version (including archived ones). `doc_scan_current` is the gate that later renditions, indexes and AI use must check |
| Worker C4 | `get_balances` and every other MCP tool response passes `scanJson`. A hit returns `SIN_CANDIDATE_REFUSED`, and the refusal is audited through `wrk_audit_sin_refusal` with the tool name and rule codes only |
| Worker / Executor C3 | `scrub()` in both detector implementations; the Worker's error log passes it |

## 2. Decisions taken under the delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9011b-1 | The no-release rule of A1-OD-2 is enforced by a transition trigger, not only by the absence of a command | It holds for every present and future function, including direct inserts by the definer (tested) |
| D-9011b-2 | A verdict computed under any detector version other than the current one is rejected (`DETECTOR_VERSION_STALE`). Admission also requires a scan under the current version | DOC-SIN-14 without a grace window |
| D-9011b-3 | When admission fails (identity changed, hash mismatch, scan not current, declaration missing), the document returns to `DISCOVERED` with the reason and nothing is written. Re-scan and, where needed, a new declaration follow | Addendum §5.4 |
| D-9011b-4 | Notification metadata uses the fixed 9010 keys: `record_key` = discovery id, `source_id` = module, `masked_subject` = file name. The file name is included only when it contains no digit at all | DOC-SIN-08 and the 9010 notification contract |
| D-9011b-5 | A file name that contains a candidate never reaches the database: `stage_write` refuses the whole discovery. The Executor must send `name_withheld` instead (9011c) | Fail closed; the Executor change is recorded for 9011c |
| D-9011b-6 | The SIN-bearing class list is held in the database (`doc_class_sin_bearing`). The Executor's `sin_bearing` flag can only add to it, and an uncertain class always requires a declaration | Addendum §2 and §3.7 |

## 3. Test results — `AUTHOR_RUNTIME_EVIDENCE`

Local runs, PG16.15 and PG17.11. All suites: R1 40/0/0 (PG16), 38/0/2 (PG17; pg_dump 17 is not installed locally); core1 12, core2 12, core3 9, core4 11 and core5 8 on both majors, all passing; black-box 8/8 on both; simulation exit 0.

| Test | Shows |
|---|---|
| AT-SIN-22-27 | T4: `PENDING_DECLARATION`, and archive is refused before the declaration. The declaration is refused for a member, through MCP, for the worker (no EXECUTE) and with a wrong hash. The Owner's declaration makes the document admissible and labelled; it is then archived as `DECLARED` / `OWNER_REDACTED_SOURCE`. Quarantine is terminal: the same bytes and a later PASSED verdict are rejected, the declaration is refused, and five direct state inserts are refused by the trigger even for the definer. There is one notification, without a digit-bearing name. A new revision invalidates the old one. A changed hash or identity at re-fetch sends the document back to `DISCOVERED`. A bank statement is admissible on the scan alone; an Owner tag or an uncertain class requires a declaration. `audit_verify` is 0 |
| AT-SIN-16,30 | `SCAN_INCOMPLETE` is not re-scannable under the same detector. Stale-version verdicts, unknown fields and text in locators are rejected, and a file name with a candidate is refused at staging. After a simulated detector bump, documents are due for re-scan, admission on an old scan is refused, and an incomplete scan may be retried |
| AT-SIN-C4 | The real Worker module with a mocked database: responses carrying a Mod-10 value or an ITN are refused, each audited with rule codes only; a clean response passes; log lines are scrubbed |

## 4. Limits

| ID | Item | Handling |
|---|---|---|
| L-7 | `ARCHIVED` is recorded as a state; the Z3 writes (evidence object, document row, Drive copy and re-hash, second copy) are not implemented yet | 9011c |
| L-8 | No Executor exists yet. The verdict, discovery and archive payloads are the contract the Executor must produce | 9011c |
| L-9 | An archived document found by a later re-scan to contain a candidate moves `ARCHIVED → SCANNING → QUARANTINED`. Removing the archived copies is an incident procedure that does not exist yet | 9011c notes; the erasure command (DL §9) is later |

# 9011c — Executor document validator (Z1) and Z3 registration at admission

Scope: Addendum A1 Rev 1 §3, §4 (zone Z1), §5.4, §7 DOC-SIN-01/02/03/07/12 and tests AT-SIN-01…07, 13, 29, 30, 31.
Synthetic fixtures only, built in memory at test time (`tests/py/doc_fixtures.py`). No real document was downloaded or used.
No cloud resource was touched. Libraries come from PyPI only, pinned with hashes (`apps/executor/requirements.txt`). The
OCR engine and strace come from the Ubuntu archive.

## 1. What was built

| Part | Content |
|---|---|
| `apps/executor/bnx_exec/doc_validator.py` | `validate(bytes, name)` returns the verdict only: `sha256`, `sin_detector_version`, `scan_result`, rule codes and positional locators. No text, value or file name leaves it. It writes no file, opens no network connection and silences library logging (guard C3) |
| Formats | Detected from magic bytes, not from the name. PDF, PNG, JPEG, XLSX, EML, CSV/TXT/MD and OFX/QFX are read. ZIP, gzip, bzip2, 7z, RAR, tar, macro workbooks (`vbaProject.bin`), embedded OLE objects, encrypted PDFs or ZIP members, PDFs with JavaScript or Launch actions, and unknown binaries are refused with a rule code (`SCAN_INCOMPLETE`) |
| PDF, pass 1 (carve) | Independent of any cross-reference table, so objects that no revision references any more are included. Covers string operands (literal and hex) in the file and in every decoded stream, XMP and other metadata streams, and embedded files, which are validated recursively. Plain text hidden in an untyped stream is scanned. Graphics operands, font programs and CMaps are not scanned |
| PDF, pass 2 (structure, per revision) | For every `%%EOF` prefix: the text layer of each page (this includes hidden optional-content layers and text under drawn boxes), annotations, form fields, Info, attachments, and OCR of each page image. A form field named or described as a SIN field is labelled |
| Images | EXIF, XMP, PNG text and IPTC metadata. OCR through the `tesseract` binary on stdin/stdout, with word confidences, under origin `ocr` (rules `R_OCR9` and `R_OCR_RUN`). If OCR is missing, fails or times out, the result is `SCAN_INCOMPLETE` |
| XLSX | Every sheet, including hidden and very hidden sheets, row by row. Also comments, defined names, document properties, and the raw text of every XML part. Embedded media are validated recursively. A column whose header is a SIN label is judged as labelled |
| EML | Every header and every MIME part, including HTML. Attachments and attached messages are validated recursively |
| Limits | 25 MiB per file, nesting depth 3, at most 2,000 ZIP members and 100 MiB uncompressed, 120 s per file. Exceeding any limit gives `SCAN_INCOMPLETE` |
| Staging payloads | `discovered_payload` omits the file name when it holds a candidate, so the database records `name_withheld` (D-9011b-5). `validated_payload` builds the 9011b verdict. `archived_payload` carries the SHA-256, size and type of the re-fetched bytes |
| Z3 registration (migration 9011) | In the admission gate `wrk_doc_archived`: `bnx.evidence_object` (the SHA-256 the Executor computed over the re-fetched bytes, `integrity_state = verified`, `storage_kind = drive_processed`, `r2_key` NULL, `archive_state = single_copy`), `bnx.evidence_file` (`drive_inbox` or `mail_exact_fetch`, the MIME type, `archived`), and the new write-once link table `bnx_doc.document_evidence`. The link records `source_fidelity`, the declaration (when one is required), the scan and the Drive file id of the Processed copy. Identical bytes share one evidence object. Re-admission after a re-scan writes no new rows |
| Database change | A scan with no document class now needs a declaration (`doc_needs_declaration`). `doc_archived` requires `size_bytes` and an allowlisted `mime` |

## 2. Decisions taken under the delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-9011c-1 | The validator fails closed. Any extraction failure, refused format, limit or OCR failure adds a rule code and gives `SCAN_INCOMPLETE`. A hit takes precedence and gives `SIN_CANDIDATE` | §3.7. A partial scan must never pass |
| D-9011c-2 | PDFs are not scanned as raw bytes. Pass 1 extracts string operands; pass 2 reads the structure revision by revision | A raw byte scan flagged an annotation rectangle: three three-digit coordinates separated by spaces form a nine-digit sequence, and that one passed Mod 10. Coordinates and widths are not text. Hidden places (old revisions, orphan objects, metadata, embedded files) stay covered by the carve pass |
| D-9011c-3 | D-A1-4 resolved: `t_ocr` stays at 0.90. The lowest word confidence on clean synthetic digit lines was 0.926–0.950 at 18–44 px (AT-SIN-13 evidence). The spec file is unchanged at 1.0.0; its "provisional" note will be updated with the next version bump, so that the spec content does not change without a version change | Clean readings stay above the threshold; the confusable glyphs S, B, G, Z and the pipe character produce `R_OCR_RUN` |
| D-9011c-4 | OCR runs the `tesseract` binary directly over stdin/stdout, with a minimal environment, one thread, and a timeout equal to the remaining time budget. `pytesseract` is not used | `pytesseract` writes temporary image files. AT-SIN-31 traces the OCR child too |
| D-9011c-5 | A verdict without a document class counts as uncertain, so it needs the Owner's declaration. The validator's default is `class_uncertain = true` until a classifier exists | Fail closed (§3.7, D-9011b-6) |
| D-9011c-6 | The trusted SHA-256 writer for these documents is the lease-bound `doc_archived` staging payload, promoted by the worker. `verified_by_execution` records `executor:doc_archived:<staging id>`. `acquired_by` is the active Owner, meaning "uploaded by" only (INV-33) | R1 rule: `evidence_object.sha256` is set only from the Executor's hash. The Executor's cloud identity is M0-B |
| D-9011c-7 | Text from separate cells, XML elements, PDF strings or HTML elements is joined with " \| ". No nine-digit sequence can span two cells, but label proximity still can | Three-digit numbers in adjacent cells would otherwise read as one nine-digit number (tested). Labels next to a value in the neighbouring cell are still found |
| D-9011c-8 | The tests are a new suite, `run_s4_core6.py`, picked up by the CI loop. CI installs the hash-pinned wheels plus `tesseract-ocr`, `tesseract-ocr-eng` and `strace` | One suite per increment, as for core1–core5 |

## 3. Test results — `AUTHOR_RUNTIME_EVIDENCE`

Local runs, PG16.15 and PG17.11, pypdf 6.17.0, openpyxl 3.1.5, Pillow 12.3.0, tesseract 5.3.4. All suites: R1 40/0/0 (PG16), 38/0/2 (PG17; pg_dump 17 is not installed locally); core1 12, core2 12, core3 9, core4 11, core5 8 and core6 8 on both majors, all passing; black-box 8/8 on both; simulation exit 0; repository scan 0 hits.

| Test | Shows |
|---|---|
| AT-SIN-01-04 | 11 synthetic PDFs. These give `SIN_CANDIDATE`, each through its own extraction path: a visible value; a value under a black box (text layer); a value only in revision 0 of an incremental update (the last revision alone is clean); and a value only in Info, XMP, an annotation, a form field, a hidden optional-content layer or an embedded file. Clean and properly redacted PDFs give `PASSED`. A field named `sin` labels its value. Graphics coordinates are not read as numbers. End to end: `QUARANTINED`, archive refused, no Z3 row, and no value in staging, scans, notifications or audit |
| AT-SIN-05,07 | OCR: a visible value in a PNG scan and in an image-only PDF gives `R_OCR9`. The same scans with a box over the number pass. End to end, the visible scan is quarantined. The redacted T4 waits in `PENDING_DECLARATION`; the Owner declares it; the queue labels it; and admission writes `evidence_object`, `evidence_file` and `document_evidence` (`OWNER_REDACTED_SOURCE`, declaration linked). `declaration_status`, `scan_result` and `sin_detector_version` are separate fields. The Z3 rows are write-once |
| AT-SIN-06 | XLSX values in a very hidden sheet, a comment, a property, and under a `SIN` column header (Mod-10-invalid) are found. Adjacent three-digit cells stay clean. An EML value in an attachment of an attached message is found. CSV and OFX are scanned |
| AT-SIN-13 | Real tesseract. Mod-10-invalid nine digits give `R_OCR9`. 8- and 10-digit runs with a confusable glyph give `R_OCR_RUN`. A clean 8-digit run gives no hit. The t_ocr measurement for D-9011c-3 |
| AT-SIN-29 | Bytes changed between scan and archive give `HASH_MISMATCH`: the document returns to `DISCOVERED` and no Z3 row is written. After a fresh scan the statement is admitted as `AS_RECEIVED_FROM_OWNER`. The same bytes arriving by mail share the evidence object |
| AT-SIN-30 | These all give `SCAN_INCOMPLETE`, each with its own rule code: encrypted PDF, damaged image, OCR timeout, missing OCR engine, JavaScript, ZIP, macro workbook, unknown binary, oversize file and truncated PDF. End to end, the encrypted PDF stays `SCAN_INCOMPLETE`, and an uncertain or missing class stays `PENDING_DECLARATION`; archive is refused |
| AT-SIN-31 | Four runs in a fresh process under `strace -f`: success, quarantine, OCR timeout, and SIGKILL during OCR. No file was created or written, TMPDIR, HOME and the working directory stayed empty, and stdout and stderr held no value |
| AT-SIN-11c | All 73 native corpus cases written as UTF-8 text files give the same verdict, rule codes and hit count as `sin_detector.scan` |

## 4. Limits

| ID | Item | Handling |
|---|---|---|
| L-7 | Now partly closed. Z3 registration is done (evidence object, evidence file, link). Still open: the Drive Processed copy and re-hash (`wrk_record_archive_event`, 0109), the second copy (`dual_verified`), and `bnx.document` rows (statement segmentation) | Drive copy: M1/M0-B-08. Segmentation: the statement work packages |
| L-8 | Now partly closed. The validator exists as library code. There is no Executor job runner, Drive or mail fetcher, lease client or cloud identity | M1 / M0-B |
| L-9 | Unchanged. A re-scan that quarantines an `ARCHIVED` document leaves its write-once Z3 rows in place. Every later use must check `doc_scan_current` and the state | Incident and erasure procedure (DL §9), later |
| L-10 | OCR misreadings made with high confidence are not flagged: `l`, `I` and `O` read as digits give a clean 8- or 10-digit run. A nine-digit value is always flagged (`R_OCR9`), even when misread | Inherent to OCR; documented for the Owner |
| L-11 | Pages are not rasterised. Text drawn as vector outlines, or set in a font without a usable Unicode mapping, can be missed when the page has no image to OCR | Needs a PDF rasteriser (poppler or pdfium) in the Executor container: M1 |
| L-12 | Anything outside the format allowlist (DOCX, HEIC, TIFF, JBIG2 or CCITT page images, and others) gives `SCAN_INCOMPLETE`. The Owner converts such a file and drops it in again | Fail closed by design |
| L-13 | There is no document classifier. Every document without an Owner-supplied class needs a declaration | Safe, at the cost of more Owner work; a classifier is a later increment |
| L-14 | AT-SIN-07 "every view labels it": the label is in the redaction queue and `source_fidelity` is stored with the evidence. The evidence and rendition views do not exist yet | 9016 renditions and the PWA must show the label from `bnx_doc.document_evidence.source_fidelity` |
