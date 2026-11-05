# Balnexa R6.2-R1 — Release Readiness

**Basis:** author-executed local synthetic runs only (`AUTHOR_RUNTIME_EVIDENCE`). No independent reproduction, no provider/account verification, no M0 execution. Decisions below are the author's proposal for reviewer adjudication.

## 1. Decisions

| Gate | Decision | Reason |
|---|---|---|
| **G0** offline remediation | **CONDITIONAL** | All four P0 (AUD-044/045/049/050) and AUD-046/051/052/053(slice)/054 are implemented and pass real-role tests on PG16 and PG17 with Draft-04 negative controls and a mutation check. Conditions: (1) independent reproduction of `tests/py/run_g0.py` on PG16 **and** PG17 and of the black-box suite; (2) backup path on PG17 is NOT_EXECUTED (no pg_dump 17 here); (3) G0-06 report projection digests exist only for the R-BAL surface; (4) G0-09 sweep covers R1 documents and the doc delta, not a rewrite of the Draft-04 documents. |
| **G1 / M0** synthetic cloud | **CONDITIONAL** (readiness to *request* authorization) · execution **NOT_EXECUTED** | The final audit requires P0 repairs to be demonstrated before an M0 authorization request; they are demonstrated by the author, not yet reproduced. Every M0-A…F test is pending and each block A-01…A-10 needs its own Owner approval. |
| **G2** (unamended Draft-04 contract: 34 reports + complete no-AI PWA) | **BLOCK** | NOT_IMPLEMENTED: PWA, executor, 33 of 34 report surfaces, statement pipeline, reconciliation, notifications delivery. |
| **G2** (proposed AI-first scope, `BNX-AI-FIRST-DESIGN-DELTA-2026-10-30-V1.0`) | **REVISE** | Proposal not yet Owner-approved as a contract; see `Balnexa_AI_First_Reconciliation_R6.2-R1_V1.0.md` §3, §4, §7. |
| **Production / real data** | **BLOCK** | Not authorized; G1 and G2 not executed; privacy, residency, key custody and real-data approvals absent. |

## 2. Residual risks (high / medium)

| # | Risk | Level | Gate | Handling |
|---|---|---|---|---|
| RR-1 | Neon role semantics (owner role, SET-only membership, default privileges) may differ from PostgreSQL 16/17 | High | G1 M0-C-06 | Bootstrap B001 + runner unchanged on Neon; any difference is a measured failure, not a reinterpretation |
| RR-2 | Single-copy exposure of evidence during onboarding: 37–74 days (1 GB) / 148–297 days (4 GB) under the 0.8 GiB egress meter; R2 loss in that window is unrecoverable for those objects | High | G1 M0-B-08, Owner DR-02 | Disclosed; gate `require_dual_copy_before_approval` available; ARC-ALT-1 to be measured |
| RR-3 | `bnx_authn` credential compromise mints sessions for any registered subject (DB cannot verify RS256) | Medium | G1 | NEW-051; candidate mitigations in CLAUDE_SELF_REVIEW §4 |
| RR-4 | Dispatcher crash after claim adds one backstop period (3 h) per crash | Medium | G1 M0-D | Bound documented; dead-letter after 5 attempts |
| RR-5 | AI hosts reading statements see full account numbers (AI-first proposal) | High | Owner privacy decision | Reconciliation §4.4 |
| RR-6 | Economic-type rule table (B6.1) not enforced in R1 slice | Medium | G2 | AUD-027 disclosed gap |
| RR-7 | Vendor-enforced US$1 maximum cannot be promised; Google cap covers Cloud Run only, R2 overages are uncapped once subscribed | High | G1 M0-F | Cost model unchanged; no paid activation authorized |

## 3. Blocked milestones and pending Owner gates

M0 blocks A-01…A-10 (each separately); CD-3 billing account, ID-01 vault identity, ODQ-19-ACT R2 subscription, CD-2 SC-V2 (only if 0.85/0.15 rejected), CD-4 (only if FT-7); DR-01 residency, ODQ-22, SEC-K, LOCK-01 before real data; R0 r0_version 3 entries individually; new DR-02 (single-copy acceptance) before real data. No routine engineering decision is escalated.

## 4. Planned production verification (not started)

Fresh production secrets and projects (no M0 promotion, AUD-043), restore drill from GCS with measured RTO/RPO, real cap configuration evidence, per-host AI qualification sign-off, independent security review.
