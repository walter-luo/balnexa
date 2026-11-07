# Balnexa — Family Finance Nexus (账知家) — S4 V1.2 Addendum A1: SIN redaction before upload

| Field | Value |
|---|---|
| Amends | `Balnexa_S4_Unified_Architecture_V1.2.zip` (SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f`). The frozen V1.2 files are not modified; this addendum is applied on top of them |
| Supersedes | CRA contract V1.2 §2 row "SIN" (default `sin_entry_mode = per_generation`, optional `sin_fingerprint`); ODR V1.2 row `SIN`; AI-ENTRY V1.2 `operations.tax_preparation.sin_entry_mode`; and the open point "SIN printed on original evidence" in `docs/s4/OWNER_DECISIONS_2026-11-07.md` |
| Decision | Owner, 2026-11-07 12:09 America/Toronto: Option (b), redact the SIN before upload, together with the Owner's six binding requirements (§1) — `OWNER_DECISION` |
| Binds | 9011 (WP-DOC DOC-1…4, WP-AI-HOST AIH-3) and 9014 (WP-TAX TAX-1…6); cross-cutting guards C1–C6 |
| Implementation status | **NOT_IMPLEMENTED**. Nothing here is built until the applicable work package is authorized. PR #1–#4 are unchanged by this addendum |
| Evidence grades | §1 `OWNER_DECISION`; §2–§5 mechanisms `PROPOSAL` unless marked otherwise |

## 1. Owner decision (binding) — `OWNER_DECISION`

1. Original T4, T5, NOA and every other document that carries a SIN are kept by the Owner **outside Balnexa**. The Owner redacts the SIN before any copy is uploaded.
2. Balnexa never receives or stores an unredacted, SIN-bearing original.
3. Balnexa accepts redacted source copies and identifies them as `OWNER_REDACTED_SOURCE`.
4. For each uploaded copy, Balnexa preserves its SHA-256, provenance, document period and redaction status.
5. Balnexa never claims that a redacted copy is byte-identical to the issuing authority's original.
6. SIN values are rejected in structured fields, logs, indexes, AI inputs and generated forms.
7. SIN fields in generated tax forms are left blank; the Owner enters the SIN by hand, outside Balnexa, when filing.
8. Validation checks for hidden PDF text, attachments and metadata that could still hold the SIN after visible redaction.

## 2. Terms

| Term | Meaning |
|---|---|
| SIN candidate | Nine digits, optionally grouped `ddd ddd ddd` or `ddd-ddd-ddd` (any whitespace or hyphen), with digit boundaries on both sides, that pass the SIN check-digit rule (Luhn, mod 10). The detector also flags a nine-digit sequence that fails Luhn when it sits next to a SIN label (`SIN`, `S.I.N.`, `NAS`, `Social Insurance`, `numéro d'assurance sociale`, `社会保险号`). Values are never logged, only the detector result |
| `source_fidelity` | Provenance class of an uploaded copy: `OWNER_REDACTED_SOURCE` (the Owner declared or the class requires redaction) or `AS_RECEIVED_FROM_OWNER` (no redaction declared). **There is no value meaning "issuer original"**, so no copy can claim to be one |
| `redaction_status` | `OWNER_DECLARED_REDACTED`, `NOT_REQUIRED_DECLARED`, `SIN_CHECK_PASSED`, `SIN_CANDIDATE_QUARANTINED`, `OWNER_CONFIRMED_NOT_SIN` (see §6, open item A1-OD-2) |
| SIN-bearing class | Every tax slip (T4, T4A, T4A(P), T4A(OAS), T4E, T4RSP, T4RIF, T5, T3, T5008, T5007, RC62, RRSP contribution receipt), NOA, NOR, CRA correspondence, filed T1 schedules, and any document the Owner tags as SIN-bearing |

## 3. Requirements for 9011 (documents, evidence, renditions) — `PROPOSAL`

| ID | Requirement | Where |
|---|---|---|
| DOC-SIN-01 | **Validate step (DL §4 step 2) runs the SIN scan before anything is archived, parsed, classified or rendered.** Any SIN candidate → `QUARANTINED (SIN_CANDIDATE)`. No `evidence_object`, archive copy, rendition, staging row or index entry is created; the staged payload carries only the detector code and a page/part locator, never the value | Executor `DOC_PROCESS`; `stg_doc_validated` schema; `wrk_doc_validate` |
| DOC-SIN-02 | **Hidden-content checks, PDF:** (a) the full text layer of every page, including text under opaque boxes and annotation-only redactions; (b) every incremental-update revision (each `%%EOF` segment, earlier revisions included); (c) AcroForm/XFA field values and defaults; (d) annotations, comments, popups, form XObjects and optional-content layers (hidden OCGs); (e) embedded files / attachments (`/EmbeddedFiles`, `/FileAttachment`), scanned recursively; (f) Info dictionary and XMP metadata; (g) JavaScript and document actions (rejected outright); (h) OCR of each rendered page for image-only or image-mixed pages. A redaction that only hides text visually fails (a) | Executor validator (Python, OD-02) |
| DOC-SIN-03 | **Hidden-content checks, other formats:** images (EXIF/XMP/IPTC metadata, OCR); XLSX (all sheets incl. hidden and very hidden, cells, comments, defined names, document properties, embedded objects); CSV/TXT/MD (full content); EML (headers, every MIME part, attachments recursively, HTML and plain bodies); OFX/QFX (all fields); archives are not accepted | Executor validator |
| DOC-SIN-04 | Every uploaded copy keeps `sha256` (of the uploaded bytes), provenance (`source_file_id`, `source_mtime`, `md5Checksum`, uploader member, `acquired_via`, module and Inbox path), `document_period`, `source_fidelity`, `redaction_status`, `sin_detector_version`, and the detector result (pass/candidate, no value) | `bnx_doc.document_discovery` / `document_state_event`; `evidence_object` (MODIFY 9011) |
| DOC-SIN-05 | A document of a SIN-bearing class is accepted only with `source_fidelity = OWNER_REDACTED_SOURCE`, declared at upload or set by the class rule, **and** a passed SIN scan | class rules (DL §5); `wrk_doc_classify` |
| DOC-SIN-06 | Wording: DL §2 "byte-identical copies" in `Processed/` means byte-identical **to the uploaded copy**. Every screen, report, export, index artifact and AI tool response that shows a document of `source_fidelity = OWNER_REDACTED_SOURCE` labels it "Owner-redacted copy — not the issuer's original". No text says or implies "original as issued" | PWA, `q_doc_*`, Index artifacts, `doc.item.get_masked` |
| DOC-SIN-07 | The SIN scan runs on **every** class, not only SIN-bearing ones: an unexpected SIN in a bank statement is quarantined the same way | Executor validator |
| DOC-SIN-08 | Quarantine handling: Balnexa is read-only on `Inbox/` (DL §1), so it cannot delete the file. It notifies the Owner once (PWA C1, Owner-only, no value, no file name if the name contains digits) to replace the Inbox file with a redacted copy. The Executor holds the bytes in memory only for the scan; no temp file survives the job; the quarantine record keeps sha256 + locator only | Executor; `bnx_intake.notification` kind `EXCEPTION` |
| DOC-SIN-09 | Masked renditions keep `[MASKED:SIN]` as a second line of defence; a SIN candidate found while rendering (scan miss) aborts the rendition and quarantines the document | AIH-3 |
| DOC-SIN-10 | **Gaps in what is already built:** 9010 staging and intake must get the same guard. `stage_write` scans every string of a staged payload; the shared-index consumer blocks a record whose verbatim columns contain a SIN candidate (`BLOCKED (SIN_CANDIDATE)`, columns not stored, only the record key and hash); the handoff importer already refuses 5+ digit runs in free text. Lands as a 9011 MODIFY of `stage_write` and `wrk_consume_shared_index` | 9011 MODIFY (9010 objects) |

## 4. Requirements for 9014 (tax) — `PROPOSAL` unless marked

| ID | Requirement | Where |
|---|---|---|
| TAX-SIN-01 | `OWNER_DECISION`: no SIN custody of any kind. `sin_entry_mode` has the single value `none`; `taxpayer.sin_fingerprint` is **removed from the schema** (not just left nullable); ODR `SIN` closed | CRA §2, §8 (`taxpayer`); AI-ENTRY `operations.tax_preparation` |
| TAX-SIN-02 | `OWNER_DECISION`: generated official forms leave every SIN field blank. `form_template_registry.field_map` marks SIN fields `owner_manual`; the fill step refuses to write any value into them; post-fill verification (PV-CRA-01) checks that they are **empty**; the fallback package and workpapers carry the checklist line "Enter SIN by hand before filing (outside Balnexa)" | TAX-5; PV-CRA-01 |
| TAX-SIN-03 | Taxpayer identity without SIN: opaque `tp_…` id; slip-to-taxpayer matching uses the legal name on the slip, issuer, tax year and the member's confirmation, never a SIN; ambiguous matches go to the review queue | TAX-1/2 |
| TAX-SIN-04 | Structured tax inputs refuse SIN candidates: taxpayer fields, slip box values and text, fact notes, disclosures, reconciliation explanations, NOA/NOR fields (`VALIDATION_FAILED`, value not echoed) | `cmd_tax_*`, `stg_tax_artifact`, `wrk_tax_*` |
| TAX-SIN-05 | A slip or assessment is accepted only from a document with `source_fidelity = OWNER_REDACTED_SOURCE` and a passed scan (DOC-SIN-05) | TAX-2 |
| TAX-SIN-06 | Rendered artifacts (workpapers, `Official_Forms/`, exports) are scanned before they are written; a SIN candidate aborts the artifact | `T1_RENDER` |
| TAX-SIN-07 | AI tools in the module (`tax.*`, CRA §7) never receive a SIN: their inputs and outputs pass the same detector; a hit is refused and audited without the value | AIH; CRA §7 |

## 5. Cross-cutting guards (every work package from 9011 on) — `PROPOSAL`

| ID | Guard |
|---|---|
| C1 | One shared detector specification and test corpus (synthetic SIN-shaped values that pass Luhn; never a real SIN) used by the Executor (Python), the Worker (JS) and the database (`bnx.sin_candidate(text) → boolean`, SQL) |
| C2 | The database refuses SIN candidates at the entry points that take free text: `plan_create` descriptions, `stage_write` payload strings, audit `request` payloads (value replaced by `[MASKED:SIN]` before hashing), handoff blocks (already 5+ digits), notification metadata (digits already stripped) |
| C3 | Logs: Worker, Gateway and Executor log writers pass a scrubbing filter (SIN candidate → `[MASKED:SIN]`) before output; AT-CRA-07 extended to scan CI and runtime logs |
| C4 | AI inputs: every MCP tool response and every prompt assembled by Balnexa passes the detector (refuse, do not mask silently) |
| C5 | Indexes: Neon operational index and Drive Index artifacts never contain a SIN candidate (scan before write) |
| C6 | CI: a repository scan for SIN candidates (Luhn-valid nine-digit values) runs next to gitleaks; test fixtures use only values from the synthetic corpus |

## 6. Open items created by this addendum

| ID | Question | Default applied | Decide by |
|---|---|---|---|
| A1-OD-1 | Detector strictness: also flag nine-digit sequences that fail Luhn when no SIN label is near | no (Luhn-valid, or labelled) | before 9011 |
| A1-OD-2 | False positive (for example an account number that passes Luhn): may the Owner release a quarantined document with an audited "not a SIN" confirmation (`OWNER_CONFIRMED_NOT_SIN`), or must the file always be re-redacted? | always re-redact (no release) | before 9011 |
| A1-OD-3 | Should SIN-bearing classes also require the Owner to declare at upload that the copy is redacted, or does the scan alone suffice? | declaration **and** scan | before 9011 |

## 7. Tests to add (registered when the work packages are authorized)

| Test | Content |
|---|---|
| AT-SIN-01 | PDF with a visible SIN → quarantined; nothing archived, staged with value, or indexed |
| AT-SIN-02 | PDF with a black box drawn over the SIN but the text left in the text layer → quarantined (hidden-text check) |
| AT-SIN-03 | PDF redacted properly in the last revision but with the SIN in an earlier incremental revision → quarantined |
| AT-SIN-04 | SIN only in XMP/Info metadata, an annotation, a form field, a hidden OCG, or an embedded attachment → quarantined (one fixture each) |
| AT-SIN-05 | Image-only scan with a visible SIN → quarantined (OCR); properly redacted scan → accepted as `OWNER_REDACTED_SOURCE` |
| AT-SIN-06 | XLSX with the SIN in a very hidden sheet, a comment or a document property; EML with the SIN in a nested attachment → quarantined |
| AT-SIN-07 | Redacted T4 accepted: SHA-256, provenance, period, `source_fidelity`, `redaction_status`, detector version stored; every view labels it "Owner-redacted copy" |
| AT-SIN-08 | SIN candidate refused in taxpayer, slip, fact, plan description, staging, audit payload, handoff, notification, MCP response and log output |
| AT-SIN-09 | Generated T1 form: SIN fields blank and verified blank; fill step refuses a value; checklist line present |
| AT-SIN-10 | Schema check: no `sin_fingerprint` column and no SIN-typed column anywhere; `sin_entry_mode` only `none` |
| AT-CRA-07 (extended) | Log, prompt, path, export and CI-log scan finds no SIN candidate |

## 8. Traceability

ODR row `SIN` → closed by this addendum (`Balnexa_S4_Owner_Decision_Register_V1.2-A1.csv`). CRA V1.2 §2 SIN row, §6.4 (fill and PV-CRA-01), §8 (`taxpayer.sin_fingerprint`) and §10 AT-CRA-07 → superseded by §4. DL V1.2 §2 ("byte-identical copies"), §4 step 2 (validate) and §5 (classes) → refined by §3. AI-ENTRY V1.2 `operations.tax_preparation.sin_entry_mode` → `none`. WP matrix TAX-1 Gate column "SIN custody approval" → no longer needed (there is no custody); DOC-2 and AIH-3 gain DOC-SIN-01…10.
