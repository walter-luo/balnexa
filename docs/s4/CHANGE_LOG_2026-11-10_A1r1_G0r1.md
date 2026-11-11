# Balnexa S4 — Change log: SIN Addendum A1 Revision 1 and Independent G0 Plan Revision 1

| Field | Value |
|---|---|
| Date | 2026-11-10 (America/Toronto) |
| Trigger | Owner decisions and required revisions of 2026-11-10 (A1-OD-1…3, D1–D4, G0-01…G0-04) |
| Baseline | `main` at `ee13eee451a4969eef58ae8cac24ca0c905d5059`, unchanged. Branch `s4/design-addendum-a1` at `9b5c007`, unchanged |
| Repository changes | None. No commit, push, PR, migration, test execution, deployment or real-data access |
| Status | Sections 1–5: prepared for Owner review at 18:42. Section 6: accepted under the Owner delegation of 19:04 |

## Deliverables

| # | Deliverable | Form |
|---|---|---|
| 1 | SIN Addendum A1 Owner Decision Package (Rev 1) | Claude Doc. The first package is kept unchanged as the reviewed record |
| 2 | Addendum A1 Revision 1 proposal | `Balnexa_S4_V1.2_Addendum_A1r1_SIN_Redaction.md` |
| 3 | Independent G0 Verification Plan (Rev 1) | Claude Doc. The first plan is kept unchanged |
| 4 | Owner Decision Register V1.2-A1r1 proposal | `Balnexa_S4_Owner_Decision_Register_V1.2-A1r1.csv` (32 rows; base: branch file at `9b5c007`) |
| 5 | This change log | `Balnexa_S4_A1r1_G0r1_Change_Log.md` |

## 1. Confirmed facts (checked 2026-11-10)

| ID | Fact | Basis |
|---|---|---|
| CF-1 | A SIN must pass the CRA "Modulus 10 (Mod 10) check digit formula" | CRA, *Rejected T4FHSA records*, error codes 3 and 44 |
| CF-2 | The SIN is 9 digits; SINs beginning with 9 are issued to temporary residents | ESDC, *SIN Code of Practice*, §1.1 and §3.1 |
| CF-3 | A CRA program account is the 9-digit BN, a 2-letter identifier and a 4-digit reference. There are 13 identifiers: RT, RP, RC, RZ, RR, RG, RD, RE, RM, RN, LT, RU, PT. XML filings require upper case | CRA, *Program accounts you may need*; CRA T4A and T619 XML specifications 2026 |
| CF-4 | The CRA ITN is 9 digits beginning with 08 or 09 | CRA, *Rejected T4FHSA records*, error code 48 |
| CF-5 | AT-BAK-03 is not implemented in `ee13eee`. It is registered as OBJ-334 (target 9016, `NOT_IMPLEMENTED`); the only code reference is a comment at `tests/py/run_s4_core2.py:376` | Repository at `ee13eee` |
| CF-6 | The author's AT-MIG-11b re-granted the installer's SET membership as the superuser (`granted by` the installer), not as the installer itself | `tests/py/run_s4_core1.py`, AT-MIG-11b |
| CF-7 | With the UA §6.2 order, the author's notes record exit 7 at 0108, with the database stopping at 0107. Recovery is untested | `docs/s4/S4_CORE1_Implementation_Notes.md` §1.2, F-C1-17 |
| CF-8 | The non-superuser install path is: installer created with LOGIN CREATEROLE and owning the database; B001 and B002 run by that installer with `createrole_self_grant=set,inherit`; B001 fails without that option | `tests/py/run_s4_core1.py` (`nonsuper_install`, AT-MIG-11b); B001 and B002 headers |
| CF-9 | Artifacts of CI run 42426384390 expire at 2026-12-07T23:43:33Z (`evidence-pg16`) and 2026-12-07T23:42:59Z (`evidence-pg17`); digests recorded | GitHub REST API, read only |
| CF-10 | AT-BAK-01 dumps only `--schema=bnx --schema=auth`; the 15 `bnx_intake` tables are outside it | `tests/py/run_g0.py` |

## 2. Owner decisions recorded (2026-11-10)

| ID | Decision | Recorded in |
|---|---|---|
| A1-OD-1 | Option C, conditionally approved, with eight conditions | Addendum Rev 1 §3, §6; ODR |
| A1-OD-2 | Option A; no archive override; a 5 % false-positive rate is a review trigger only | Addendum Rev 1 §6, DOC-SIN-13; ODR |
| A1-OD-3 | Option A; Owner-only PWA declaration bound to identity, revision and SHA-256; three separate fields | Addendum Rev 1 §2, §4, §5; ODR |
| D1 | An independent verifier (Codex or a qualified human); four independence conditions; vendor separation alone is not sufficient | G0 Rev 1; ODR G0-D1 |
| D2 | Backup gap deferred to 9016 as `DEFERRED_BACKUP_GAP`; never PASS; no real data or production until full coverage is verified | G0 Rev 1 V9; ODR G0-D2 |
| D3 | CI evidence preserved in principle; inventory and destination prepared; no transfer authorized | G0 Rev 1 D3 section; ODR G0-D3 |
| D4 | Verifier helper code allowed in an isolated workspace only | G0 Rev 1; ODR G0-D4 |
| Baseline | Option (b) preserved: SIN-bearing originals stay outside Balnexa; only Owner-redacted copies are accepted | Addendum Rev 1 §1 |

## 3. Design corrections

| ID | Correction | Where |
|---|---|---|
| G1 | Label list (EN, FR, ZH) and proximity rules per context, with a fail-closed fallback | Addendum Rev 1 §3.4 |
| G2 | `redaction_status` withdrawn; replaced by `declaration_status`, `scan_result` and `sin_detector_version` | §2, §4 |
| G3 | Zones Z0–Z3, states, post-discovery declaration, admission re-check with re-fetched SHA-256 | §5 |
| G4 | Format-only exception for complete program accounts; no standalone-BN exemption; the SIN label takes precedence; no exception in OCR text | §3.5 |
| G5 | Unicode normalisation rules | §3.2 |
| New | `SCAN_INCOMPLETE` result and fail-closed rules; an uncertain class is treated as SIN-bearing | §3.7 |
| New | 8- and 10-digit OCR runs with low-confidence or confusable glyphs become candidates | §3.3 |
| Withdrawn | The optional first-digit 0/8 exclusion (CF-4: the ITN begins with 08 or 09) | §3.6 |
| G0-01 | M2 installer sequence S0–S5 with prerequisites; the installer exists before B001 | G0 Rev 1, environment section |
| G0-02 | V3.12 split: V3.12a records the actual failure; V3.12b checks recovery without editing history | G0 Rev 1 V3 |
| G0-03 | V9.3a reproduces the gap as `DEFERRED_BACKUP_GAP`; V9.3b specifies the 9016 acceptance test | G0 Rev 1 V9, V9.3b section |
| G0-04 | AT-BAK-03 is `NOT_IMPLEMENTED` (V9.2); separate verifier probe V9.2n; AT-BAK-01 and AT-BAK-02 scoped to `bnx`+`auth` | G0 Rev 1 V9 |
| V4.3 | Split: V4.3a tests the installer re-granting SET to itself (never tested before); V4.3b reproduces the superuser variant | G0 Rev 1 V4 |
| Errata, first plan | The first plan listed AT-BAK-03 under V9.1 and as existing author evidence. It also stated that the installer self-re-grant "succeeds" and that V3.12 exits 6. All three are corrected in Rev 1 | G0 Rev 1 |

## 4. Assumptions and unverified points

| ID | Statement | Treatment |
|---|---|---|
| A-1 | The CRA "Mod 10 formula" for the SIN is the Luhn algorithm | `ASSUMPTION`; open item O-A1-3 |
| A-2 | ESDC never issues SINs beginning with 0 or 8 | `NOT_VERIFIED`; not used |
| F-4 | BN check-digit algorithm | Not found in CRA sources; the design does not depend on it |
| L-1 | GitHub job-log retention for this repository | Not confirmed (the proxy refused the settings endpoint); the default of 90 days is unconfirmed |
| E-1 | Contents of the CI artifacts | Expected from `ci.yml`; confirmed only on download |

## 5. Outstanding items and execution gates

| Item | Needed before |
|---|---|
| Owner acceptance of the five deliverables | Committing the Addendum Rev 1 and ODR to `s4/design-addendum-a1` (separate authorization) |
| O-A1-1: should ITN, TTN and other tax identifiers be in detector scope? | 9011 |
| O-A1-2: OCR threshold and scan budgets | 9011 design review |
| O-A1-3: accept or confirm A-1 | Real data |
| Authorization to transfer the CI evidence (D3) | 2026-12-07 23:42 UTC |
| Independent G0 execution authorization | G0 |
| 9011 start | Owner decision after G0 is accepted |
| 9016: V9.3b complete backup/restore test passing on both majors | Real data and production (D2) |
| Gate O-8, security review ODQ-22, CPA G-CRA-1 | Real data and tax output |
| Still open from earlier: S4B-F13, Gateway CIMD fetch, DOC-SIN-10 guards; R1-0108 attestation for environments outside my access | As previously reported |

## 6. Update 2026-11-10 19:04 onward — Owner delegation

| Item | Change |
|---|---|
| Delegation | Owner instruction of 19:04 recorded in `docs/s4/OWNER_DECISIONS_2026-11-10.md`. Claude decides open items (`DELEGATED_DECISION`), completes each stage in one step, and keeps the boundaries in §3 of that record |
| O-A1-1…3 | Decided as D-A1-1 (ITN protected), D-A1-4 (OCR parameters set in 9011), D-A1-2 (A-1 accepted). D-A1-3 keeps the proximity windows |
| Deliverables 1–5 | Accepted (D-A1-5) and committed to branch `s4/design-addendum-a1`. They merge into `main` with the 9011 PR |
| D3 | Job logs archived with a manifest (`Balnexa_CI_run-42426384390_logs_2026-11-10.zip`). Artifact zips could not be downloaded from Claude's environment; the Owner downloads them before 2026-12-07 23:42 UTC |
| G0 | Plan accepted; verifier brief `docs/s4/g0/G0_VERIFIER_BRIEF.md` written. The Owner hands it to Codex or a human verifier |
| Next stage | 9011a (detector, corpus, database guards) on its own branch from `main`, in parallel with G0 |
