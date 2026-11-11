# Balnexa — Family Finance Nexus (账知家) — S4 V1.2 Addendum A1, Revision 1 (proposal): SIN redaction before upload

| Field | Value |
|---|---|
| Status | **ACCEPTED 2026-11-10** by the Owner's delegation of that date (see `docs/s4/OWNER_DECISIONS_2026-11-10.md`): the Owner's own decisions (§6) are `OWNER_DECISION`; the items Claude decided under the delegation are `DELEGATED_DECISION` (§10). It supersedes `docs/s4/design/Balnexa_S4_V1.2_Addendum_A1_SIN_Redaction.md`, which stays in the repository unchanged as the record of 2026-11-07 |
| Amends | `Balnexa_S4_Unified_Architecture_V1.2.zip` (SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f`); the frozen V1.2 files are not modified |
| Supersedes | Addendum A1 (2026-11-07) in full; CRA contract V1.2 §2 row "SIN"; ODR V1.2 row `SIN`; AI-ENTRY V1.2 `operations.tax_preparation.sin_entry_mode` |
| Decisions | Owner, 2026-11-07 12:09: Option (b) and requirements 1–8 (§1). Owner, 2026-11-10: A1-OD-1 option C with conditions, A1-OD-2 option A, A1-OD-3 option A with conditions (§6) — `OWNER_DECISION` |
| Binds | 9011 (WP-DOC DOC-1…4, WP-AI-HOST AIH-3, MODIFY of the 9010 objects `stage_write` and `wrk_consume_shared_index`) and 9014 (WP-TAX TAX-1…6); cross-cutting guards C1–C6 |
| Implementation status | **NOT_IMPLEMENTED.** 9011 and 9014 are not authorized. Merged baseline `ee13eee` is unchanged |
| Evidence grades | §1 and §6 `OWNER_DECISION`; §10 `DELEGATED_DECISION`; facts in §9 `SOURCE_VERIFIED` (government publication) or `ASSUMPTION` as marked; everything else `PROPOSAL` until implemented |
| Revision 1 resolves | G1 label proximity (§3.4); G2 separate status fields (§2, §4); G3 post-discovery declaration and processing boundary (§5); G4 Business Number handling (§3.5); G5 normalisation (§3.2); Q1 rule verification (§9); Q2 who declares (§6); Q3 review trigger (§6) |

## 1. Owner decision (binding) — `OWNER_DECISION`, unchanged

1. Original T4, T5, NOA and every other document that carries a SIN are kept by the Owner **outside Balnexa**. The Owner redacts the SIN before any copy is uploaded.
2. Balnexa never receives or stores an unredacted, SIN-bearing original.
3. Balnexa accepts redacted source copies and identifies them as `OWNER_REDACTED_SOURCE`.
4. For each accepted copy, Balnexa preserves its SHA-256, provenance, document period and the status of its redaction controls.
5. Balnexa never claims that a redacted copy is byte-identical to the issuing authority's original.
6. SIN values are rejected in structured fields, logs, indexes, AI inputs and generated forms.
7. SIN fields in generated tax forms are left blank; the Owner enters the SIN by hand, outside Balnexa, when filing.
8. Validation checks for hidden PDF text, attachments and metadata that could still hold the SIN after visible redaction.

## 2. Terms

| Term | Meaning |
|---|---|
| SIN candidate | A match of the detector specification in §3. Values are never logged or stored, only the verdict, the rule that matched and a locator |
| Locator | Position of a hit without its value: part (page, sheet, MIME part, attachment path, revision), object kind (text layer, field, annotation, metadata key, OCR region) and an offset or bounding box |
| `source_fidelity` | `OWNER_REDACTED_SOURCE` (the Owner declared the copy redacted) or `AS_RECEIVED_FROM_OWNER` (no declaration required for its class). No value means "issuer original" |
| `declaration_status` | Owner redaction declaration for one exact file identity: `NOT_REQUIRED`, `PENDING`, `DECLARED`, `INVALIDATED` (content or identity changed after declaring) |
| `scan_result` | Outcome of the automated scan for one SHA-256: `PASSED`, `SIN_CANDIDATE` (quarantined), `SCAN_INCOMPLETE` (extraction or classification uncertain; treated like a quarantine, §3.7) |
| `sin_detector_version` | Version of the detector specification and corpus used for that `scan_result`; stored with every scan |
| SIN-bearing class | Every tax slip (T4, T4A, T4A(P), T4A(OAS), T4E, T4RSP, T4RIF, T4FHSA, T5, T3, T5008, T5007, RC62, RRSP contribution receipt), NOA, NOR, CRA correspondence, filed T1 schedules, any document the Owner tags as SIN-bearing, and **any document whose class is uncertain** (§3.7) |

`redaction_status` (Addendum A1, 2026-11-07) is withdrawn. The two controls and the detector version are three separate fields (G2).

## 3. Detector specification (guard C1) — `PROPOSAL` implementing A1-OD-1 option C

One specification and one synthetic corpus are shared by the Executor (Python), the Worker (JS) and the database (`bnx.sin_candidate(text, origin)`). `origin` is `native` (text layer, field values, metadata, file content), `ocr` (text recognised from an image) or `typed` (a person typed it into a Balnexa field).

### 3.1 Base rule (all origins)

A nine-digit sequence is a candidate when it passes the Modulus 10 check-digit formula (§9, F-1, A-1), wherever it occurs.

A *nine-digit sequence* is nine digits, ungrouped or grouped 3-3-3 with one separator between groups, with no digit immediately before or after it. Separators: any Unicode whitespace (after §3.2), hyphen-minus, and the Unicode dashes U+2010–U+2015.

### 3.2 Normalisation before matching (G5)

1. Unicode NFKC: full-width digits (U+FF10–U+FF19) and other compatibility digits become ASCII digits; compatibility spaces become U+0020.
2. Every character of Unicode general category `Nd` (decimal digit, any script) is mapped to its ASCII digit.
3. U+00A0, U+2007, U+2009, U+202F, U+3000 and tabs are treated as spaces; runs of whitespace collapse to one space for matching only.
4. Zero-width characters (U+200B–U+200D, U+2060, U+FEFF) and soft hyphen (U+00AD) are removed before matching.

Locators always refer to the original, not the normalised, text.

### 3.3 OCR rule

In text of origin `ocr`, **every** nine-digit sequence is a candidate, including those that fail the check digit.

In addition, an OCR digit run of 8 or 10 digits is a candidate when any character in it was recognised below the confidence threshold `T_ocr`, or was mapped from a confusable glyph (O→0, o→0, I→1, l→1, |→1, S→5, B→8, Z→2, G→6). `T_ocr` is set in 9011 from the corpus (D-A1-4).

### 3.4 Label proximity (G1)

A nine-digit sequence that fails the check digit is still a candidate when it is *near* a SIN label.

**Labels** are matched after §3.2, case- and accent-insensitive, as whole words:

- English: `SIN`, `S.I.N.`, `Social Insurance Number`, `Social Insurance No`, `Social Insurance #`, `Soc. Ins. No`.
- French: `NAS`, `N.A.S.`, `numéro d'assurance sociale`, `no d'assurance sociale`, `n° d'assurance sociale`.
- Simplified Chinese: `社会保险号`, `社会保险号码`, `社会保障号`.
- Traditional Chinese: `社會保險號`, `社會保險號碼`.

Data keys and field names: any key or name that, after splitting on `_`, `-`, `.`, camelCase and spaces, contains the token `sin`, `nas` or the token pair `social insurance`.

The label list is a versioned part of the corpus. The supported languages for the first release are English, French and Chinese.

**Near** means any one of the following:

| Context | Rule |
|---|---|
| Form fields (AcroForm, XFA) | The value is in a field whose name, alternate name (`/TU`), export name or associated caption contains a label |
| Layout text (PDF text layer, OCR with boxes) | Same table cell or form box as the label; the cell or box immediately to the right of or below the label's; or the same visual line within 64 characters after the label or 32 before it |
| Text without layout (TXT, CSV, MD, e-mail body, metadata values) | Within 64 characters after the label or 32 before it, on the same line or the next non-empty line |
| Spreadsheets (XLSX) | Same cell; the cell to the right of or below a label cell; a column or row whose header cell contains a label; a cell comment or defined name containing a label |
| Structured data (JSON payloads, staged records, MCP arguments, form submissions) | The value is under a key that is a label per the key rule |

Where layout cannot be determined for a part, the text-without-layout rule applies. This is the fail-closed fallback.

### 3.5 CRA Business Number program accounts (G4)

A nine-digit sequence is **not** a candidate by the base rule (§3.1) only when it is part of a complete CRA program account number in the format of §9 F-3:

- nine digits;
- immediately followed (optionally with one space or hyphen) by one of the identifiers RT, RP, RC, RZ, RR, RG, RD, RE, RM, RN, LT, RU, PT, in upper case only (the CRA XML specifications require upper case; a lower-case form is not exempt);
- followed (optionally with one space or hyphen) by exactly four digits;
- no digit or letter immediately before or after the whole.

Constraints from A1-OD-1:

- A **standalone** nine-digit number, including one labelled "Business Number" or "BN", is **not** exempt. It is judged by §3.1–§3.4.
- The exception relies on the **format only**. It does not assume that a BN uses the SIN check digit (§9, F-4).
- **An explicit SIN label takes precedence.** A program-account-shaped value that is near a SIN label (§3.4) is a candidate.
- The exception never applies in text of origin `ocr`. §3.3 governs there, because OCR can merge a SIN with neighbouring text.
- The identifier list is versioned with the corpus and reviewed against the CRA source at each detector version bump.

### 3.6 Individual Tax Number (ITN) — `DELEGATED_DECISION` D-A1-1

The CRA Individual Tax Number is nine digits beginning with 08 or 09 (§9, F-5). It is protected like a SIN (Owner rule: sensitive government identification numbers are never stored or displayed):

1. In every origin, a nine-digit sequence (§3.1 form) whose first two digits are `08` or `09` is a candidate, whether or not it passes Mod 10. No ITN check digit is assumed.
2. `Individual Tax Number` and `ITN` are added to the English labels of §3.4; the label rules then apply as for a SIN. French and Chinese ITN labels are added only after they are verified from a CRA publication (corpus task, 9011).
3. The §3.5 program-account exception does not apply to a value beginning with `08` or `09` that sits near an ITN or SIN label.
4. The Temporary Tax Number and other identifiers are **not** in scope until their format is verified from a CRA publication; any later addition is a detector version bump.

The earlier optional 0/8 first-digit exclusion stays **withdrawn**. Expected cost: about 2 % of random nine-digit numbers additionally become candidates (measured by FP-SIN-01).

### 3.7 Fail closed

The result is `SCAN_INCOMPLETE`, handled like a quarantine (§5.3), when any of the following holds:

- a part cannot be extracted (encrypted or damaged PDF, unsupported embedded object, unreadable image, archive, password-protected file);
- the OCR engine errors or times out;
- the job exceeds its time or memory budget;
- a page is image-only or image-mixed but no OCR result exists.

A document whose class the classifier cannot determine with the configured confidence is treated as SIN-bearing: it needs a declaration (§5).

## 4. Records kept per document (DOC-SIN-04, revised)

| Field | Kept for | Notes |
|---|---|---|
| `sha256` | every scanned file | Of the exact bytes scanned |
| Source identity | every discovered file | Drive: `fileId`, `headRevisionId` (or `version`), `md5Checksum`, `size`, `modifiedTime`. Mail: message id, MIME part path, size |
| Provenance | every accepted file | Uploader member if known, `acquired_via`, module, Inbox path; the file name is stored only after it passes the detector, otherwise a placeholder |
| `document_period` | every accepted file | — |
| `source_fidelity` | every accepted file | §2 |
| `declaration_status` | every discovered file | Plus the declaring member, timestamp and the identity it is bound to (§5.2) |
| `scan_result` | every scanned SHA-256 | Plus `sin_detector_version`, rule codes and locators; never a value |

## 5. Discovery, transient scan and controlled storage (G3) — `PROPOSAL` implementing A1-OD-3

### 5.1 Zones

| Zone | Where | What Balnexa holds | Allowed operations |
|---|---|---|---|
| Z0 External | Drive `Inbox/` (read-only for Balnexa), the Owner's mailbox via mail intake | Nothing | Listing metadata |
| Z1 Transient scan | Executor job memory | The bytes, for the job's duration only | Fetch, SHA-256, extraction, OCR, detector. No disk write (no temp file, no swap-backed cache), no log line with content or file name, no AI call |
| Z2 Pending | Database state | Source identity, SHA-256, `scan_result`, locators, `declaration_status` | Notifications to the Owner (no value; no file name containing digits) |
| Z3 Controlled storage | Evidence archive and its second copy, renditions, operational index, Drive Index artifacts, AI tool inputs and outputs, exports, backups | Accepted documents and their derived data | Ordinary processing |

**No byte and no derived text of a document enters Z3, ordinary logs, indexes, AI processing or exports unless the admission rule of §5.4 holds.**

### 5.2 Declaration (A1-OD-3)

- Only the **Owner** may declare, and only in the PWA, for the first release. Members, AI connections, the Worker, the Executor and the Gateway are refused.
- A declaration is bound to the exact file identity. For Drive: `fileId`, `headRevisionId`, `md5Checksum` and the `sha256` from the Z1 scan. For mail: message id, MIME part path and `sha256`.
- Any change of content or revision sets `declaration_status = INVALIDATED`. The new bytes need a new scan and a new declaration.
- The declaration prompt shows the class, the source identity and the page count. It never shows document content.
- A declaration never overrides a scan result. The order of scan and declaration does not matter; both must hold for the same `sha256`.

### 5.3 States

| State | Entered when | Leaves to |
|---|---|---|
| `DISCOVERED` | Z0 listing finds a new identity | `SCANNING` |
| `SCANNING` | Z1 job starts | `QUARANTINED`, `SCAN_INCOMPLETE`, `PENDING_DECLARATION`, `ADMISSIBLE` |
| `QUARANTINED` | `scan_result = SIN_CANDIDATE` | Terminal for that SHA-256. A new revision restarts at `DISCOVERED` |
| `SCAN_INCOMPLETE` | §3.7 | Terminal for that SHA-256. A retry is allowed only after a detector or engine change (version bump) |
| `PENDING_DECLARATION` | Scan `PASSED`, and the class is SIN-bearing or uncertain | `ADMISSIBLE` on a declaration; `INVALIDATED` on a content change |
| `ADMISSIBLE` | Scan `PASSED`, and the declaration is `DECLARED` or `NOT_REQUIRED` | `ARCHIVED` |
| `ARCHIVED` | §5.4 succeeded | — |

### 5.4 Admission into controlled storage

The archive step fetches the bytes again and recomputes the SHA-256. It writes to Z3 only if all of the following hold:

1. The SHA-256 equals the scanned SHA-256 and the source identity is unchanged. This guards against a file changed between scan and archive.
2. `scan_result = PASSED` under the **current** `sin_detector_version`. Otherwise the file is re-scanned first.
3. `declaration_status ∈ {DECLARED, NOT_REQUIRED}` for that SHA-256.

On any mismatch the document returns to `DISCOVERED`. Nothing is written.

## 6. Owner decisions on the open items — `OWNER_DECISION` (2026-11-10)

| ID | Decision | Conditions recorded |
|---|---|---|
| A1-OD-1 | **Option C, conditionally approved** | OCR: every nine-digit sequence is a candidate, Luhn-failing included (§3.3). Unicode normalisation (§3.2). Complete program-account formats recognised from the current CRA specification (§3.5, §9). No exemption for standalone BNs. No reliance on an unverified BN check digit. Precise label proximity, form-field relations and languages (§3.4). The SIN label takes precedence (§3.5). Fail closed on uncertainty (§3.7). Rules verified against government publications; what could not be verified is documented (§9) |
| A1-OD-2 | **Option A** | A quarantined document is replaced by a newly redacted copy and scanned again. No Owner override that releases a quarantined document into the permanent archive. Any future exception mechanism needs a separate Owner decision. Review trigger: a provisional false-positive rate of **5 %**. It triggers a policy review only, never an automatic relaxation |
| A1-OD-3 | **Option A** | Owner declaration **and** passed scan. Owner only, PWA only, first release. AI connections, Workers and other members may not declare. Bound to the exact file identity, version and SHA-256; any content change invalidates it. Separate `declaration_status`, `scan_result` and `sin_detector_version`; no single `redaction_status` |
| Q2 | Resolved by A1-OD-3 | Owner only |
| Q3 | Resolved by A1-OD-2 | 5 % trigger for review |

**False-positive rate (review trigger), defined:** the share of documents not of a SIN-bearing class, scanned in a calendar quarter, that were quarantined although the Owner records in the quarterly review that the hit was not a SIN. Until real data is authorized it is measured on the synthetic corpus (FP-SIN-01). The review report holds counts only. Reaching 5 % opens a policy review; it changes nothing by itself.

## 7. Requirements for 9011 — `PROPOSAL` (revised)

| ID | Requirement |
|---|---|
| DOC-SIN-01 | The scan (Z1) runs before anything is archived, parsed for posting, classified for storage, rendered or indexed. The class needed for the declaration rule may be computed inside Z1 |
| DOC-SIN-02 | Hidden-content checks, PDF: (a) full text layer, including text under opaque boxes and annotation-only redactions; (b) every incremental-update revision; (c) AcroForm/XFA values and defaults; (d) annotations, comments, popups, form XObjects, optional-content layers; (e) embedded files and attachments, recursively; (f) Info dictionary and XMP; (g) JavaScript and actions: rejected outright; (h) OCR of every page that is image-only or image-mixed |
| DOC-SIN-03 | Hidden-content checks, other formats. Images: EXIF, XMP, IPTC and OCR. XLSX: all sheets including hidden and very hidden, cells, comments, defined names, properties, embedded objects. CSV, TXT, MD: full content. EML: headers, every MIME part, attachments recursively. OFX, QFX: all fields. Archives are not accepted |
| DOC-SIN-04 | Records per §4 |
| DOC-SIN-05 | A SIN-bearing or uncertain-class document is admitted only per §5.4 with `source_fidelity = OWNER_REDACTED_SOURCE` |
| DOC-SIN-06 | Every view, report, export, Index artifact and AI tool response showing an `OWNER_REDACTED_SOURCE` document labels it "Owner-redacted copy — not the issuer's original". "Byte-identical" in DL §2 means byte-identical to the admitted copy |
| DOC-SIN-07 | The scan runs on every class |
| DOC-SIN-08 | Quarantine (§5.3) keeps SHA-256, source identity, rule codes and locators only. One Owner notification per SHA-256, without a value and without a file name containing digits. The Owner replaces the Inbox file with a newly redacted copy |
| DOC-SIN-09 | Masked renditions keep `[MASKED:SIN]` as a second line of defence. A candidate found while rendering aborts the rendition, sets the document back to `QUARANTINED` and raises an incident |
| DOC-SIN-10 | 9011 MODIFY of the 9010 objects. `stage_write` runs the detector over every string of a staged payload (`origin = native`; key rule of §3.4). `wrk_consume_shared_index` blocks a record whose verbatim columns contain a candidate (`BLOCKED (SIN_CANDIDATE)`; the columns are not stored). The handoff importer keeps refusing digit runs of 5 or more in free text |
| DOC-SIN-11 | Owner-only PWA declaration command, refused on MCP and for every role other than the Owner's session; audited with the bound identity, never content |
| DOC-SIN-12 | Admission per §5.4, including the re-fetch SHA-256 check |
| DOC-SIN-13 | No command, tool or job moves a `QUARANTINED` or `SCAN_INCOMPLETE` document to `ADMISSIBLE` (A1-OD-2) |
| DOC-SIN-14 | A detector version bump forces a re-scan of documents not yet `ARCHIVED`, and of archived documents before their next rendition, index write or AI use |

## 8. Requirements for 9014 — `PROPOSAL` unless marked (unchanged except TAX-SIN-05)

| ID | Requirement |
|---|---|
| TAX-SIN-01 | `OWNER_DECISION`: no SIN custody. `sin_entry_mode` has the single value `none`; `taxpayer.sin_fingerprint` is removed from the schema |
| TAX-SIN-02 | `OWNER_DECISION`: SIN fields on generated official forms are left blank and marked `owner_manual`. The fill step refuses a value there; PV-CRA-01 verifies the fields are empty; the checklist says "Enter SIN by hand before filing (outside Balnexa)" |
| TAX-SIN-03 | Taxpayer identity without SIN: opaque `tp_…` id. Matching uses legal name, issuer, tax year and member confirmation |
| TAX-SIN-04 | Structured tax inputs refuse candidates (`origin = typed`): `VALIDATION_FAILED`, with the value never echoed |
| TAX-SIN-05 | A slip or assessment is accepted only from an `ARCHIVED` document with `declaration_status = DECLARED`, `scan_result = PASSED` under the current detector version, and `source_fidelity = OWNER_REDACTED_SOURCE` |
| TAX-SIN-06 | Rendered artifacts are scanned before they are written; a candidate aborts the artifact |
| TAX-SIN-07 | `tax.*` AI tools: inputs and outputs pass the detector; a hit is refused and audited without the value |

Cross-cutting guards C1–C6 are as in Addendum A1 §5, with C1 now meaning §3 of this revision.

## 9. Verified facts and assumptions (Q1)

| ID | Statement | Grade | Source |
|---|---|---|---|
| F-1 | A SIN reported to the CRA must pass the "Modulus 10 (Mod 10) check digit formula"; a failing SIN is rejected | `SOURCE_VERIFIED` | CRA, *Rejected T4FHSA individual records or annual information returns*, error codes 3 and 44 |
| F-2 | The SIN is a unique 9-digit number; SINs beginning with 9 are issued to temporary residents | `SOURCE_VERIFIED` | ESDC, *Social Insurance Number Code of Practice*, §1.1 and §3.1 |
| F-3 | The BN is a 9-digit number. A program account number is the BN, a 2-letter program identifier and a 4-digit reference number. The identifiers are RT, RP, RC, RZ, RR, RG, RD, RE, RM, RN, LT, RU, PT. XML filings write it as 15 characters with upper-case letters | `SOURCE_VERIFIED` | CRA, *Program accounts you may need*; CRA, *T4A … XML specifications (2026)*; CRA, *T619 Electronic Transmittal (2026)* |
| F-4 | No CRA publication found states the BN check-digit algorithm | `NOT_FOUND` | Searched canada.ca 2026-11-10. The library python-stdnum 2.1 validates the BN with Luhn, but that is not a government source. **The design does not rely on it** (§3.5) |
| F-5 | An ITN is a nine-digit number beginning with 08 or 09 | `SOURCE_VERIFIED` | CRA, *Rejected T4FHSA …*, error code 48 |
| A-1 | The CRA's "Modulus 10 check digit formula" for SIN is the Luhn algorithm (alternate digits doubled, digit sum mod 10) | `ASSUMPTION` | Not spelled out in the CRA page. Consistent with python-stdnum. The detector corpus must include CRA-published examples if any are found; otherwise this stays an assumption |
| A-2 | ESDC does not issue SINs with first digit 0 or 8 | `NOT_VERIFIED` | Not found in ESDC sources. Not used: the 0/8 refinement is withdrawn (§3.6) |

## 10. Items decided under the Owner's delegation of 2026-11-10 — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-A1-1 (was O-A1-1) | ITN protected as in §3.6; TTN and others out of scope until their format is verified | The Owner's standing rule covers sensitive government ID numbers; F-5 is verified; fail closed at a measured cost |
| D-A1-2 (was O-A1-3) | Assumption A-1 (CRA Mod 10 = Luhn) accepted. The corpus also contains Mod-10-failing values next to labels and in OCR text, so a wrong assumption cannot open a gap in those paths | All public implementations use Luhn; the label, OCR and ITN rules do not depend on it |
| D-A1-3 | Proximity windows of §3.4 (64 characters after, 32 before) and the EN/FR/ZH label set kept as written | No evidence for different values before the corpus exists; they become corpus-tuned parameters recorded in `sin_detector_version` |
| D-A1-4 (was O-A1-2) | `T_ocr` and the scan time/memory budgets are set by Claude in 9011 from the synthetic corpus, recorded in the detector version and reported in the 9011 implementation notes | Values need measurement; they never relax §3.3 (below threshold means candidate) |

No open item of Addendum A1 remains that blocks 9011.

## 11. Tests to add (registered when 9011/9014 are authorized)

| Test | Content |
|---|---|
| AT-SIN-01…10 | As in Addendum A1 §7. AT-SIN-07 now checks `declaration_status`, `scan_result` and `sin_detector_version` separately |
| AT-SIN-11 | Python, JS and SQL give identical verdicts and rule codes for every corpus entry |
| AT-SIN-12 | Native text: Mod-10-valid unlabelled → candidate. Mod-10-invalid unlabelled → pass. Mod-10-invalid in each proximity context of §3.4, for every label and language → candidate |
| AT-SIN-13 | OCR: Mod-10-invalid nine digits → candidate. An 8- or 10-digit run with a low-confidence or confusable glyph → candidate |
| AT-SIN-14 | A complete program account for each of the 13 identifiers, with and without separators → not a candidate (native). The same value near a SIN label → candidate. A standalone BN, including one labelled "BN" → judged by the base rule. Any program account in OCR text → candidate |
| AT-SIN-15b | ITN: nine digits beginning `08` or `09`, with and without separators, Mod-10-valid and invalid, in native and OCR text → candidate; next to an `ITN` label with a program-account suffix → candidate |
| AT-SIN-15 | Normalisation: full-width and other `Nd` digits, each listed space and dash, zero-width and soft-hyphen insertions → candidate |
| AT-SIN-16 | A detector version bump forces re-scans per DOC-SIN-14 |
| AT-SIN-17 | Catalog check: no function, tool or job moves `QUARANTINED` or `SCAN_INCOMPLETE` to `ADMISSIBLE` |
| AT-SIN-18 | The same bytes again → quarantined, no second notification |
| AT-SIN-19 | A new redacted revision at the same Inbox path → fresh scan and declaration, then admitted |
| AT-SIN-20 | Quarantine record, notification, audit chain, Worker, Gateway and Executor logs, and CI logs hold no value and no file name containing digits |
| AT-SIN-21 | Schema: no `redaction_status`, no `OWNER_CONFIRMED_NOT_SIN`, no SIN-typed column |
| AT-SIN-22 | SIN-bearing or uncertain class, clean scan, no declaration → `PENDING_DECLARATION`; nothing in Z3 |
| AT-SIN-23 | Declaration and clean scan → `ARCHIVED` as `OWNER_REDACTED_SOURCE`; the three fields stored separately |
| AT-SIN-24 | Declaration with a hit → quarantined; the declaration has no effect |
| AT-SIN-25 | A content or revision change after the declaration → `INVALIDATED`; a new declaration is needed |
| AT-SIN-26 | A declaration attempted by a member, through MCP, by the Worker or by the Executor → refused. Owner declarations are audited with the bound identity only |
| AT-SIN-27 | A class that is not SIN-bearing is admitted on the scan alone; Owner tagging as SIN-bearing then requires a declaration |
| AT-SIN-28 | 9014 slip import refuses a document that lacks any one of the TAX-SIN-05 conditions |
| AT-SIN-29 | A file changed between scan and archive (SHA-256 mismatch at re-fetch) → nothing written; back to `DISCOVERED` |
| AT-SIN-30 | Fail closed: encrypted PDF, damaged image, OCR timeout and an uncertain class each give `SCAN_INCOMPLETE` or `PENDING_DECLARATION`, never `ADMISSIBLE` |
| AT-SIN-31 | Z1 leaves no file on disk and no content in any log after success, quarantine, timeout or crash |
| FP-SIN-01 | Measurement (not pass/fail): the false-positive rate per §6 on the synthetic corpus |

## 12. Sources (opened 2026-11-10)

- CRA, *Rejected T4FHSA individual records or annual information returns*: https://www.canada.ca/en/revenue-agency/services/tax/registered-plans-administrators/first-home-savings-account/rejected-t4fhsa-individual-records-annual-information-returns.html
- CRA, *Program accounts you may need*: https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/business-registration/business-number-program-account/need-program-accounts.html
- CRA, *T4A, Statement of Pension, Retirement, Annuity, and Other Income — XML specifications 2026*: https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026/t4a-2026.html
- CRA, *T619, Electronic Transmittal (2026)*: https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026.html
- ESDC, *Social Insurance Number Code of Practice*: https://www.canada.ca/content/dam/esdc-edsc/documents/services/sin/reports/code-of-practice/sin-cop-en.pdf
- python-stdnum 2.1 (PyPI wheel; files `stdnum/ca/sin.py`, `stdnum/ca/bn.py`), consulted as non-authoritative background only
