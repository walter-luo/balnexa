# G0 independent re-run (R3) 2026-11-13 — disposition

`DRAFT — AI-generated` (the author: Claude). Report: `docs/s4/reviews/g0/20261113_chatgpt-codex-r3/REPORT.md`. Runner: GPT-5 Codex, graded `VERIFIED_INDEPENDENT`; the PWA run is `NOT_EXECUTED`. Code under test: `846db8e` (top of #40, migration head 9039, release 0.9.5-p2).

## Result

| Part | Reviewer | Author's comparison |
|---|---|---|
| A Python suites | PG16 196/0/0, PG17 196/0/0. `pg_dump` matched each server (16.16, 17.12) | Matches the expected 196 per major. These are the first independent runs with zero skips on both majors |
| A Node | 35/0/0; simulation PASS | Matches |
| A PWA | `NOT_EXECUTED` (Chromium download blocked, HTTP 403) | Same limitation as R1 and R2 |
| B migrations, privileges, catalog, manifest | PASS: 51 migrations, head 9039, 0 violations, 119 entries; manifest 0.9.5-p2 | Matches |
| C integrity and scans | PASS: gitleaks (115 commits), SIN scan (2367 files) | Matches |
| D schema review | PASS: six schemas from 9035–9037 checked against their bodies | — |

The R2 remediation checks named in the report all passed on both majors: the decoy `python3`, `NO_RESTORED_HEADER`, `AT-NULL-01` and `AT-OUT-06`.

## Findings

| ID | Reviewer | Author's verdict | Action |
|---|---|---|---|
| R3-01: PWA browser unavailable | note | **Agreed: an environment limitation, not a product defect** | No code change. The PWA gap is below |

The reviewer also reported fixing issues in its own container before the corrected runs: a socket mount, the PostgreSQL client path, Git safe-directory and the pip invocation. These are not findings against the code, and the reviewer re-ran the affected tests.

## Status of the independent G0 verification

| Gate | Status after R3 | Evidence grade |
|---|---|---|
| Database regression, PG16 and PG17 (C collation) | PASS | `VERIFIED_INDEPENDENT` (R3) |
| Database regression under ICU en-US | PASS on the previous code. R3 did not repeat the ICU lane; 9039 has not been run on ICU by an independent reviewer | `VERIFIED_INDEPENDENT` (R2, `109a6c7`) for the earlier code. For `846db8e`: the author's local run plus CI (`db-tests (17, icu-en-US)` 196/0/0) |
| Node black-box, unit and simulation | PASS | `VERIFIED_INDEPENDENT` |
| **PWA (23 tests per major)** | **Not independently executed in any of R1–R3** | `AUTHOR_RUNTIME_EVIDENCE` plus CI only |
| Migrations, privileges, catalog, manifest, scans, schema review | PASS | `VERIFIED_INDEPENDENT` |

**Open for the Owner (G0-PWA-1): how to close the PWA gap.** The reviewer's cloud workspace cannot download a browser, so repeating the same prompt will not change this. The options are:

1. **Accept the gap.** G0 is recorded as passed with the PWA at `AUTHOR_RUNTIME_EVIDENCE` + CI. CI runs the PWA suite on every push: on GitHub runners, not in an independent environment, and from the author's workflow file.
2. **An independent run in an environment that has a browser.** For example, a reviewer workspace with Chromium pre-installed, or the Owner running `tests/pwa` on a machine with Node.
3. **A clean Claude chat.** This is the same model family, so it grades `SAME_FAMILY_VERIFICATION`, not `VERIFIED_INDEPENDENT`.

The author recommends option 1 for now, with option 2 before production use. The PWA tests exercise the shell and handshakes; the database authority beneath them is independently verified.
