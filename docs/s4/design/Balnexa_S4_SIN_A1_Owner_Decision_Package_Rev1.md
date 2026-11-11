> Repository copy, 2026-11-10. This package was prepared for Owner review at 18:42 and accepted under the Owner delegation of 19:04 (`docs/s4/OWNER_DECISIONS_2026-11-10.md`). Statements below that the files are "not committed" describe the state at review time. The processing-boundary diagram exists only in the Claude Doc version.

# Balnexa S4 — SIN Addendum A1 Owner Decision Package (Rev 1)

Nov 10, 2026 · @Walter Luo

## Status

You decided all three items on 2026-11-10: A1-OD-1 option C with conditions, A1-OD-2 option A, A1-OD-3 option A with conditions. This revision records the decisions and shows where each condition is met. Gaps G1–G5 and questions Q1–Q3 are resolved; three narrower open items remain.

The Option (b) decision is preserved unchanged: **SIN-bearing originals remain outside Balnexa; only Owner-redacted copies may be accepted.**

| Deliverable | Form | Status |
| --- | --- | --- |
| This package (Rev 1) | This doc | For Owner review. It supersedes the first package, which stays unchanged as the record you reviewed |
| Addendum A1 Revision 1 | `Balnexa_S4_V1.2_Addendum_A1r1_SIN_Redaction.md` | `PROPOSAL`; not committed |
| Owner Decision Register | `Balnexa_S4_Owner_Decision_Register_V1.2-A1r1.csv` | `PROPOSAL`; not committed |
| Change log | `Balnexa_S4_A1r1_G0r1_Change_Log.md` | Covers this package and the G0 plan |

Nothing was implemented, committed or pushed. 9011 and 9014 remain unauthorized.

## A1-OD-1 — Option C, conditionally approved

Every condition you set is met in Addendum A1 Revision 1, §3. One proposal from the first package is withdrawn: the optional exclusion of first digits 0 and 8. The CRA's Individual Tax Number begins with 08 or 09, so that exclusion would have blinded the detector to another government identifier.

| Owner condition | Where it is met | How |
| --- | --- | --- |
| Every nine-digit OCR sequence is a candidate, Luhn-failing included | §3.3 | Plus 8- and 10-digit OCR runs that contain a low-confidence or confusable glyph (O/0, I/1, S/5, B/8 …), because OCR can drop or add a digit |
| Normalise Unicode digits and spacing | §3.2 | NFKC; every Unicode decimal digit mapped to ASCII; listed spaces and dashes as separators; zero-width characters and soft hyphens removed. Locators still refer to the original text |
| Recognise complete CRA program-account formats from the current CRA specification | §3.5, §9 F-3 | Nine digits + one of the 13 CRA identifiers (RT, RP, RC, RZ, RR, RG, RD, RE, RM, RN, LT, RU, PT), upper case only, + four digits |
| No exemption for standalone BNs | §3.5 | A bare nine-digit number is judged by the base rule, even when labelled "BN" |
| No reliance on an unverified BN check digit | §3.5, §9 F-4 | The exception uses format only. No CRA publication states the BN check digit |
| Precise label proximity, form-field relations, languages | §3.4 | Label list for English, French, Simplified and Traditional Chinese, plus a key rule for structured data. Proximity is defined per context: form fields, layout text, plain text, spreadsheets, structured payloads |
| An explicit SIN label overrides the BN exception | §3.5 | A program-account-shaped value near a SIN label is a candidate. The exception never applies to OCR text |
| Fail closed when uncertain | §3.7 | New result `SCAN_INCOMPLETE`, handled like a quarantine. An uncertain class is treated as SIN-bearing |
| Verify against government publications; document the rest | §9 | Facts F-1, F-2, F-3 and F-5 come from CRA and ESDC pages. F-4 was not found. A-1 and A-2 are recorded as assumptions; A-2 is not used |

## A1-OD-2 and A1-OD-3 — Option A, approved

**A1-OD-2:** a quarantined document is replaced by a newly redacted copy and scanned again. No Owner override admits a quarantined document into the permanent archive; any future exception needs a separate Owner decision. The 5 % false-positive rate triggers a policy review only.

| Owner condition | Where it is met |
| --- | --- |
| Replace and re-scan; no override into the archive | DOC-SIN-08, DOC-SIN-13; AT-SIN-17, 18, 19 |
| `OWNER_CONFIRMED_NOT_SIN` gone | §2; AT-SIN-21 |
| 5 % is a review trigger, never an automatic relaxation | §6 defines the rate: the quarterly share of non-SIN-bearing documents quarantined for a hit the Owner records as not a SIN; counts only, measured on synthetic data until real data is authorized |

**A1-OD-3:** both an explicit Owner declaration and a passed scan are required.

| Owner condition | Where it is met |
| --- | --- |
| Owner only, PWA only, first release; AI connections, Workers and members refused | §5.2, DOC-SIN-11; AT-SIN-26 (also refuses the Executor) |
| Bound to exact file identity, version and SHA-256; any change invalidates | §5.2. Drive binding: `fileId`, `headRevisionId`, `md5Checksum` and the scanned `sha256`. Mail binding: message id, MIME part path and `sha256`. Test AT-SIN-25 |
| Separate `declaration_status`, `scan_result`, `sin_detector_version`; no single `redaction_status` | §2, §4; AT-SIN-21, AT-SIN-23 |
| Post-discovery PWA declaration with `PENDING_DECLARATION` | §5.3 |
| Boundary between discovery, transient scanning and controlled storage | §5.1 and §5.4, summarised in the next section |
| No unverified bytes in evidence storage, indexes, AI processing, logs or exports | §5.1 admission rule; DOC-SIN-12; AT-SIN-29, AT-SIN-31 |

## Processing boundary (Addendum A1 Rev 1 §5)

&#91;embedded content: Processing boundary · 4 zones, 1 admission check\]

Document bytes exist inside Balnexa only in Executor memory during a scan, until all three admission conditions hold. If the bytes changed between scan and archive, nothing is written and the document goes back to `DISCOVERED`. A quarantined or incomplete scan is terminal for that SHA-256; only a newly redacted revision starts again.

## G1–G5 and Q1–Q3 resolved

| Item | Resolution | Addendum A1 Rev 1 |
| --- | --- | --- |
| G1 Label proximity undefined | Labels in EN, FR and ZH (simplified and traditional), whole-word, case- and accent-insensitive, plus a key rule. Proximity per context: form field name or caption; same cell or box, right or below; same line within 64 characters after or 32 before; spreadsheet header row or column. Fail-closed character window when layout is unknown | §3.4 |
| G2 One status field for two controls | `redaction_status` withdrawn; separate `declaration_status`, `scan_result`, `sin_detector_version` | §2, §4 |
| G3 No upload step inside Balnexa | Zones Z0–Z3, states from `DISCOVERED` to `ARCHIVED`, post-discovery declaration, admission re-check | §5 |
| G4 Every BN looked like a SIN candidate | Format-only exception for complete program accounts, 13 CRA identifiers, upper case; never for standalone BNs, OCR text, or values near a SIN label | §3.5 |
| G5 Unicode undefined | NFKC plus digit, space, dash and zero-width rules | §3.2 |
| Q1 Verify the rules from government sources | Done where sources exist; see the facts table below | §9 |
| Q2 Who declares | Owner only, by your decision | §5.2 |
| Q3 Review threshold | 5 %, review trigger only, defined precisely | §6 |

## Verified facts and assumptions

| ID | Statement | Grade | Source |
| --- | --- | --- | --- |
| F-1 | A SIN must pass the "Modulus 10 (Mod 10) check digit formula"; a failing SIN is rejected | Verified | [CRA, Rejected T4FHSA records](https://www.canada.ca/en/revenue-agency/services/tax/registered-plans-administrators/first-home-savings-account/rejected-t4fhsa-individual-records-annual-information-returns.html), error codes 3, 44 |
| F-2 | The SIN is a unique 9-digit number; SINs beginning with 9 go to temporary residents | Verified | [ESDC, SIN Code of Practice](https://www.canada.ca/content/dam/esdc-edsc/documents/services/sin/reports/code-of-practice/sin-cop-en.pdf), §1.1, §3.1 |
| F-3 | Program account = 9-digit BN + 2-letter identifier + 4-digit reference; the 13 identifiers; XML uses 15 characters, upper case | Verified | [CRA, Program accounts you may need](https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/business-registration/business-number-program-account/need-program-accounts.html); [CRA, T4A XML specifications 2026](https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026/t4a-2026.html); [CRA, T619 2026](https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026.html) |
| F-4 | BN check-digit algorithm | Not found in CRA sources | The design does not depend on it |
| F-5 | An ITN is a nine-digit number beginning with 08 or 09 | Verified | [CRA, Rejected T4FHSA records](https://www.canada.ca/en/revenue-agency/services/tax/registered-plans-administrators/first-home-savings-account/rejected-t4fhsa-individual-records-annual-information-returns.html), error code 48 |
| A-1 | CRA's "Mod 10 formula" for SIN is the Luhn algorithm | Assumption | Not spelled out by the CRA; the detector uses Luhn (open item O-A1-3) |
| A-2 | No SIN is issued with first digit 0 or 8 | Not verified | Not used; the exclusion is withdrawn |

## Remaining open items

| ID | Question | Default until decided | Decide by |
| --- | --- | --- | --- |
| O-A1-1 | Should the detector also protect the ITN, TTN or other individual tax identifiers? Your standing rule is never to store or display sensitive government ID numbers | No first-digit exclusion. A Mod-10-failing, unlabelled ITN is not detected | Before 9011 |
| O-A1-2 | OCR confidence threshold `T_ocr`, and scan time and memory budgets | Set in the 9011 design review from the synthetic corpus | 9011 design review |
| O-A1-3 | Accept A-1 (Mod 10 = Luhn) as an assumption, or require CRA/ESDC confirmation | Accepted as an assumption | Before real data |

The updated Owner Decision Register records A1-OD-1–3 as decided on 2026-11-10, adds O-A1-1–3, and adds the G0 decisions G0-D1–D4.

## Sources

Opened 2026-11-10:

- [CRA, Rejected T4FHSA individual records or annual information returns](https://www.canada.ca/en/revenue-agency/services/tax/registered-plans-administrators/first-home-savings-account/rejected-t4fhsa-individual-records-annual-information-returns.html)
- [CRA, Program accounts you may need](https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/business-registration/business-number-program-account/need-program-accounts.html)
- [CRA, T4A XML specifications 2026](https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026/t4a-2026.html)
- [CRA, T619 Electronic Transmittal 2026](https://www.canada.ca/en/revenue-agency/services/e-services/filing-information-returns-electronically-t4-t5-other-types-returns-overview/t619-2026.html)
- [ESDC, Social Insurance Number Code of Practice](https://www.canada.ca/content/dam/esdc-edsc/documents/services/sin/reports/code-of-practice/sin-cop-en.pdf)

Internal: branch `s4/design-addendum-a1` at `9b5c007`.
