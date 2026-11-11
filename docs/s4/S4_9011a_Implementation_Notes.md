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
