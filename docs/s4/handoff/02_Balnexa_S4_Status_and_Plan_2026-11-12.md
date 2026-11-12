# Balnexa (账知家) — S4 Status, Implementation Coverage and Plan to Go-Live — 2026-11-12

**Status:** `DRAFT — AI-generated`; it becomes authoritative once the Owner confirms it.

**As of:** 2026-11-12 11:54 America/Toronto. The Owner paused development at this point: "开发暂停" ("development paused").

**Code:**
- `main` = `fff6db5`;
- open draft stack #9 → #15, top `s4/aih-r` @ `6571164`;
- this document on `s4/handoff`.

**Evidence grades:**
- `AUTHOR_RUNTIME_EVIDENCE` plus green CI everywhere;
- `SAME_FAMILY_VERIFICATION` for 9011 and AIH-1/2/4;
- no independent G0 runner yet;
- nothing deployed.

---

## 1. Executive summary

**Built and tested locally (PG16 and PG17, synthetic data):**
- **Finance Core** (R1 kernel plus migrations 9002–9013 and 9016–9023): ledger, accounts and registry, flags, plans and approvals, intake, documents and the SIN guards, observations and reconciliation, FX, cards and loans, report families and snapshots, backup and DR registries.
- **Gateway** (REST, catalog, binding checks, OAuth 2.1 for AI hosts, a catalog-generated MCP server and a confirmation card).
- **Executor** (lease client; render, backup, restore-drill and evidence-verify jobs).
- **PWA** (daily screens, closed menu, Draft Confirm, handoff, audit trail, AI consent and connections).

**Tests:**
- 179 database tests on each PostgreSQL major in CI;
- 32 black-box and unit tests;
- 19 headless PWA tests;
- the dispatcher simulation.

**Not done:**
- **Tax Core** (9014): Owner gate G-CRA-1 and the SIN custody decision.
- **Federation** (9015).
- **The document pipeline at runtime** (WP-DOC 2–5).
- **Shared-index and mail consumers at runtime** (INT-2/3).
- **AI-ENTRY** (ENT-1/3, which need the Owner-private verifier).
- **The installer** (INS-2–4).
- **Every cloud deployment** (M0) and **real AI-host qualification** (AIH-5).
- **The independent G0 run.**

V1 cannot go live until the Owner opens gates O-7/M0-AUTH (cloud), POC-AUTH (hosts) and O-8 (real data). §6 sets out the path.

## 2. Code state

| PR | Branch → base | Content | Migration | CI on head | State |
|---|---|---|---|---|---|
| #1–#8 | — | CORE-1…6, 9011 (incl. 9011R), 9012, 9013, 9016 | 9002–9013, 9016 | green | **merged** into `main` (`fff6db5`) |
| #9 | `s4/core-7` → `main` | Gateway: catalog, dispatch, B1/B2/B3/B8, JWKS, presign | 9017 | green (`2ff0591`) | draft |
| #10 | `s4/core-8` → `s4/core-7` | Executor jobs, work orders, artifact proxy | 9018 | green (`74f97fa`) | draft |
| #11 | `s4/core-9` → `s4/core-8` | PWA, catalog delta blocks | 9019 | green (`6d4d138`) | draft |
| #12 | `s4/core-10` → `s4/core-9` | Handoff screens, audit trail, key normalization | 9020 | green (`123c113`) | draft |
| #13 | `s4/aih` → `s4/core-10` | OAuth 2.1 for AI hosts, catalog MCP server, consent and connections | 9021 | green (`f2cddc7`) | draft |
| #14 | `s4/aih-4` → `s4/aih` | MCP App confirmation card | 9022 | green (`1db6445`) | draft |
| #15 | `s4/aih-r` → `s4/aih-4` | Independent-review remediation RV-AIH-01…14 | 9023 | green (`6571164`) | draft |
| #16 | `s4/handoff` → `s4/aih-r` | This handoff set (documents only) | — | docs only | draft |

**Merge order:** #9 → #10 → … → #15 → #16. After each merge, retarget the next PR to `main`.

Each PR description records its local regression and CI results. All PRs are `mergeable_state = clean`.

## 3. Work-package coverage (WP matrix V1.2)

Status values:
- **DONE** — built and tested locally, CI green; not deployed.
- **PARTIAL** — some parts built (the "Next" column says which remain).
- **NOT STARTED**
- **GATED** — waiting on an Owner gate.
- **DEFERRED**

| WP item | Scope tag | Status | Built (where) | Next / remaining | Gate |
|---|---|---|---|---|---|
| CORE-1 | V1-CORE | DONE | runner lanes, B002, 9002–9004 (PR #1) | — | G0 independent run |
| CORE-2 | V1-CORE | DONE | registry + seed, 9006 (PR #2) | — | G0 |
| CORE-3 | V1-CORE | DONE | accounts, holders, fingerprints, events (9006; PR #2) | Worker HMAC key custody at deploy (OD-10 default: Worker secret) | G0, M0 |
| CORE-4 | V1-CORE | DONE | economic rules 9008, plans, drafts, approvals, holds, lease 9010 | — | G0 |
| CORE-5 | V1-CORE | DONE | 9012 (FX, valuations, lots, cards, loans, R28) | R28 fixture file V1.2 is issued with TST-2 | G0 |
| CORE-6 | V1-CORE | DONE | 9013 (F1–F7, R09, snapshots, status, artifacts) | — | G0 |
| CORE-7 | V1-CORE | DONE (draft PR) | Gateway catalog/dispatch/bindings, 9017 (PR #9) | curated input/output schemas (L-CORE7-2) | G0 |
| CORE-8 | V1-CORE | DONE locally (draft PR) | `bnx_exec` jobs, 9018 (PR #10) | container images, Cloud Run, GCS/R2 stores | M0-A/E (O-7) |
| CORE-9 | V1-CORE | PARTIAL (draft PR) | PWA shell, screens, menu, Draft Confirm, i18n, a11y (PR #11) | dedicated onboarding screens (Draft-04 C5), evidence upload widget (R2), IndexedDB queue, device checks | M0-A/B (O-7) |
| CORE-10 | V1-CORE | DONE (draft PR) | handoff screens, audit trail 9020 (PR #12) | real peer test at M0 | — |
| AIH-1 | AIHOST-QUAL | DONE locally (draft PR) | OAuth AS/RS, DCR/CIMD, consent, 9021 (PR #13, #15) | qualification on real hosts | POC-AUTH |
| AIH-2 | AIHOST-QUAL | DONE locally (draft PR) | catalog MCP server (PR #13, #15) | qualification on real hosts | POC-AUTH |
| AIH-3 | V1-CORE (O-3) | PARTIAL | 9011 renditions schema, detector, guards, validator | Executor rendition pipeline, `doc.item.get_masked`, per-document override UI | after DOC-2 |
| AIH-4 | AIHOST-QUAL | DONE locally (draft PR) | card resource, 9022 (PR #14) | PV-UI-01…03 on real hosts | POC-AUTH |
| AIH-5 | AIHOST-QUAL | GATED | — | Claude Pro connector, ChatGPT A1/A3 PoCs | POC-AUTH + a deployed instance |
| ENT-1 | V1-CORE | NOT STARTED | — | AI-ENTRY 2.1 schema + verifier 3.1.0 | needs `verify_ai_entry.py` from the Owner-private S3 package |
| ENT-2 | V1-CORE | PARTIAL | config lifecycle 9003, flags 9007, B1/B2/B3/B8 at the Gateway | B8 rendering into Worker env at install, B9 | after ENT-1 / INS-2 |
| ENT-3 | V1-CORE | NOT STARTED | — | regeneration of AI-ENTRY projections, Settings read-only view | after ENT-1/2 |
| DOC-1 | EXT-DOC | PARTIAL | `bnx_doc` schema (9011) | managed-folder registry, B9 ancestry, dedicated Drive identity | OD-50, M0-B |
| DOC-2 | EXT-DOC (statements V1-CORE) | PARTIAL | `doc_validator.py` (9011c) | discover/validate/classify/archive pipeline jobs | M0-B for Drive; mocks first (TST-5) |
| DOC-3 / DOC-4 / DOC-5 | EXT-DOC | NOT STARTED | — | classification, index, Documents screens | after DOC-2 |
| INT-1 | V1-CORE | DONE | `bnx_intake` 9010 | — | G0 |
| INT-2 | V1-CORE channel | PARTIAL | intake records and acks (9010; AT-EML-*) | Executor consumer for GSHEET/CSV/Markdown index | real index needs Owner authorization |
| INT-3 | V1-CORE | NOT STARTED (DB side in 9010) | mail-source registration | exact retrieval, `.eml` upload, Outlook move, with mock providers | mail credential authorization |
| INT-4 | EXT-CRA | GATED | — | — | G-CRA-1 |
| INT-5 | EXT-DOC (optional) | NOT PLANNED | — | — | PUSH decision (default no) |
| TAX-1…6 | EXT-CRA | GATED | — | 9014 Tax Core | **SIN custody decision + G-CRA-1** |
| INS-1 | EXT-INSTALL | PARTIAL | CI on PG16/17, secret scan, chain lint (C6), cost model + admission (9016), `release.js` | release-manifest tooling, SBOM, `min_worker_release` per migration | — |
| INS-2 / INS-3 / INS-4 | EXT-INSTALL | NOT STARTED | — | installer validator, wizard, CLI, upgrade, decommission | — |
| FED-1 / FED-2 | EXT-FED | DEFERRED | — | 9015 | needs INS-2 (two instances) |
| TST-1 | all | PARTIAL | harness fixtures (`tests/py`, `prepare_db.py`) | generator for documents, index sheets, tax slips | — |
| TST-2 | V1-CORE | PARTIAL | F1–F7, R28 and P0 tests (core8, core12) | `r28_fixtures_V1.2.json`, BAL01–12 oracle set | — |
| TST-3 | V1-CORE | DONE | `tests/pwa` AT-NOAI suite (19 tests) | extend with each new screen | — |
| TST-4 | V1-CORE | DONE | role-restricted PG16/17 harness; `pg_dump` 17 in CI | — | — |
| TST-5 | all | PARTIAL | KV, R2 and assets mocks in the node adapter | Drive, Sheets, Gmail, Graph, Cloud Run, GCS mocks; PV-DRV-01 harness | — |
| TST-6 | all | PARTIAL | same-family reviews 9011R and RV-AIH | **independent G0 run** on PG16+PG17 by a runner other than the author | G0 |

## 4. Gates and milestones

| Gate / milestone | Meaning | Status |
|---|---|---|
| G0 | migration, privilege and test gate on PG16+PG17, run by an executor other than the author | **OPEN**. Author runs and CI are green; the independent run is not done. |
| G1 | integration with mock providers | OPEN (TST-5 partial) |
| G2 | functional acceptance (PWA axis A1-01…14 on a deployed instance) | OPEN (needs M0) |
| M0-A…F | platform qualification: Workers/Neon/Cloud Run, Drive/R2, Neon roles, backup/restore drill, cost admission | **OPEN — needs O-7 / M0-AUTH** |
| AIHOST-QUAL | PV-AIH-01…08, PV-UI-01…03 on Claude and ChatGPT | **OPEN — needs POC-AUTH** plus a deployed instance |
| G-CRA-1 | tax work | **CLOSED gate** (not opened) |
| O-7 | cloud resources and spend | closed |
| O-8 | real data, production, key custody, locked retention | closed |
| ODQ-22 | security review before real data | open |

## 5. Owner decisions (register V1.2, 22 rows)

S4 runs on the defaults. Rows that block the next phases:

| ID | Question | Default applied | Blocks |
|---|---|---|---|
| **M0-AUTH / O-7** | authorize M0 platform qualification and cloud spend | not now | every deployment (§6 phase 3) |
| **POC-AUTH** | account PoCs on ChatGPT Plus and Claude Pro (synthetic) | not now | AIH-5, AIHOST-QUAL |
| **O-8** | real data / production | closed | go-live |
| **SIN** | SIN custody (per-generation entry vs stored fingerprint) | per_generation | 9014 Tax Core |
| **G-CRA-1** | open tax work | closed | WP-TAX, INT-4 |
| ODQ-22 | security review before real data | accept with mitigations | go-live |
| SEC-K | backup key custody K2 | confirm K2 | O-8 |
| RET-01 | retention 7D + 4W + 12M | confirm | O-8 |
| OD-50 | Drive identity (dedicated instance identity) | A | DOC-1, M0-B |
| OD-02 | Executor language | Python 3.12 (as built) | — |
| OD-20 | artifact streaming to AI hosts | status only (as built) | — |
| OD-21 | DCR + CIMD, DCR rate-limited | both (as built) | — |
| OD-22 | loopback redirects on production | no (as built) | — |
| OD-40 | in-card confirmation | disabled (as built) | — |
| OD-41 | in-card editing | allowed (default); **built display-only** (D-AIH4-3), so it needs the Owner's confirmation | AIH-4 follow-up |

The remaining rows (OD-01, OD-03, OD-10, OD-100, A2, PUSH, OR-EML-06-CH) keep their defaults and block nothing in V1-CORE.

**Owed register work:** 9017–9023 are outside the V1.2 migration register. They need register and disposition rows (D-CORE7-1, D-CORE8-1, D-CORE9-1, D-CORE10-1, D-AIH-1, D-AIH4-1, D-AIHR-1).

## 6. Plan to completion and go-live

The phases are ordered by dependency. No calendar dates are given: each phase starts when its entry conditions hold.

### Phase 0 — Consolidate (Owner, no development)

1. Merge #9 → #15 and the handoff PR in order.
2. Confirm or amend this handoff set. Until then it stays a DRAFT.
3. Add register and disposition rows for 9017–9023.
4. Decide the numbering of 9014/9015 (L-9016-8): implement them, or commit documented no-op reservations before any persistent install.

### Phase 1 — Independent G0 (TST-6)

- **Who:** a runner that is not the author (another platform or model family). It runs the CI recipe on PG16 and PG17 and the review prompts (`docs/s4/reviews/`).
- **Exit:** G0 report with `VERIFIED_INDEPENDENT` results; open findings fixed forward.

### Phase 2 — Remaining V1-CORE development (no Owner gate needed)

| Order | Item | Content | Dependencies |
|---|---|---|---|
| 2.1 | TST-5 | Mock Drive, Sheets, Gmail, Graph, GCS and Cloud Run providers in the node adapter and the Executor | — |
| 2.2 | DOC-2 + AIH-3 | Executor document pipeline (discover, validate, classify, archive copy and re-hash); masked renditions; `doc.item.get_masked`; override UI | 2.1 |
| 2.3 | INT-2 / INT-3 | shared-index consumer and exact mail retrieval against the mocks | 2.1 |
| 2.4 | ENT-1 → ENT-2 → ENT-3 | AI-ENTRY schema and verifier; B8/B9 rendering; Settings view | Owner supplies `verify_ai_entry.py` from the S3 package |
| 2.5 | CORE-9 remainder | onboarding screens; upload widget against the mock R2; IndexedDB queue | 2.1 |
| 2.6 | INS-1 completion, then INS-2 | release manifest + SBOM + `min_worker_release`; installer validator, plan, CLI, wizard (setup mode) | 2.4 |
| 2.7 | TST-1 / TST-2 completion | fixture generator; R28 fixture file V1.2; BAL01–12 oracles | — |
| 2.8 | Curated tool schemas | Hand-written input/output schemas for the AI-exposed tools (L-CORE7-2, L-AIH-7) | — |
| 2.9 | DOC-1/3/4/5 (EXT-DOC) | When the Owner wants the document extension in V1 | 2.2, OD-50 |

**Exit:** G1 (integration with mocks) green; G0 re-run green.

### Phase 3 — M0 platform qualification (needs O-7 / M0-AUTH with a budget)

| Milestone | Content |
|---|---|
| M0-A | Cloudflare Worker deploy with static assets; Neon database (B001/B002 with the installer identity, M0-C-06); Executor image (`age`, `pg_dump`/`pg_restore` 16+17, tesseract) as a Cloud Run Job; lease with a metadata-server ID token |
| M0-B | dedicated Drive identity (OD-50); R2 bucket for evidence uploads; PV-DRV-01 |
| M0-C | Neon roles and privileges; ODQ-22 mitigations (in-database RS256 option) |
| M0-E | backup to GCS vault with K2 keys (SEC-K); restore drill on a Neon branch; retention (RET-01) without a lock until O-8 |
| M0-F | cost admission against real quotas |

**Exit:** a synthetic instance deployed end to end; M0 reports.

### Phase 4 — AI-host qualification (needs POC-AUTH)

- AIH-5 on the deployed synthetic instance:
  - Claude Pro custom connector (DCR, `claude_remote_mcp`);
  - ChatGPT A1 custom MCP (CIMD/DCR);
  - ChatGPT A3 Sites shim (`/api` resource).
- Run PV-AIH-01…08 and PV-UI-01…03. Fix forward.
- Re-verify the platform facts (MCP Apps message names, ChatGPT globals, tool-name rules).

**Exit:** AIHOST-QUAL report.

### Phase 5 — G2 acceptance and security review

- PWA axis A1-01…14 on phones.
- Full functional acceptance on the deployed synthetic instance.
- Security review (ODQ-22).
- A same-family or independent review of the deployed configuration.

**Exit:** G2 PASS; security review accepted.

### Phase 6 — Go-live (needs O-8)

1. Owner decisions SEC-K and RET-01 confirmed; O-8 opened in writing.
2. Production instance installed with INS-2. Configuration accepted by the Owner, then activated by the installer.
3. Restore drill before real data.
4. First real data loaded through onboarding, with the dual-copy gate; ledger fingerprint recorded.
5. AI hosts connected by the Owner through the consent screen.
6. Operations: quarterly and pre-upgrade restore drills (IL §5), cost monitoring (9016), audit-chain verification (`audit_chain_verify.py`), revocation runbook (L-AIHR-2).

### Phase 7 — Extensions

- EXT-CRA: SIN decision plus G-CRA-1 → 9014, TAX-1…6, INT-4.
- EXT-DOC (DOC-3/4/5).
- EXT-FED (9015, after INS-2 provides two instances).
- EXT-INSTALL upgrades and decommission (INS-3/4).

## 7. Risks and known issues

| Risk | Effect | Mitigation |
|---|---|---|
| 9014/9015 gap (L-9016-8) | the runner's prefix rule blocks installing 9016+ on a persistent database | Phase 0 decision |
| Same-family reviews only | blind spots shared with the author model | Phase 1 independent G0 by another platform |
| Platform facts unverified (MCP Apps, ChatGPT Apps SDK, Workers limits, Neon) | rework after PoCs | Phase 3–4 before G2 |
| Large unmerged stack (7 draft PRs) | conflicts if `main` moves | merge in order before new work |
| Open limits (Appendix D of document 01) | functional gaps | each has a follow-up; review before G2 |
| PGDG mirror sync breaks CI apt steps at times | red CI not caused by the code | one re-run (as on PR #15, run 43246798180) |
