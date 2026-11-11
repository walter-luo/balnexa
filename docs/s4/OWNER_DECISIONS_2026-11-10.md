# Owner decisions and delegation — 2026-11-10

Grade: `OWNER_DECISION` for §1 and §2; `DELEGATED_DECISION` for §4. Merged baseline `ee13eee451a4969eef58ae8cac24ca0c905d5059` is unchanged by this record.

## 1. Decisions on the SIN Addendum A1 and the Independent G0 packages (Owner, 2026-11-10 18:31 America/Toronto)

| ID | Decision |
|---|---|
| A1-OD-1 | Option C, conditionally approved. OCR: every nine-digit sequence is a candidate, including Luhn failures. Normalise Unicode digits and spacing. Recognise complete CRA program-account formats from current CRA specifications. No automatic exemption for standalone BNs. No reliance on an unverified BN check digit. Precise label-proximity rules, including form fields and supported languages. An explicit SIN label overrides the BN exception. Fail closed when uncertain. Verify the rules against Canadian government publications and document what cannot be verified |
| A1-OD-2 | Option A. A quarantined document is replaced by a newly redacted copy and scanned again. No Owner override that releases a quarantined document into the permanent archive; any future exception needs a separate Owner decision. A provisional 5 % false-positive rate triggers a policy review; it never relaxes the policy automatically |
| A1-OD-3 | Option A. Both an explicit Owner redaction declaration and a passed scan. Owner only, through the PWA, for the first release; AI connections, Workers and other members may not declare. Bound to the exact file identity, version and SHA-256; any content change invalidates it. Separate `declaration_status`, `scan_result`, `sin_detector_version`. A post-discovery PWA declaration with `PENDING_DECLARATION`. No unverified bytes in permanent evidence storage, indexes, AI processing, logs or exports |
| Baseline | Option (b) preserved: SIN-bearing originals remain outside Balnexa; only Owner-redacted copies may be accepted |
| D1 | Independent verifier: OpenAI Codex or a qualified human reviewer who did not take part in the Claude implementation. Environment, expected results, execution and evidence review are independent of the author. Vendor separation alone is not sufficient |
| D2 | The `bnx_intake` backup gap is deferred to 9016 as `DEFERRED_BACKUP_GAP`. It is never marked PASS. No real-data ingestion or production deployment until complete backup and restore coverage is implemented and verified, covering all schemas, tables, sequences, dependencies, audit records and operational state |
| D3 | Preserve the CI evidence of run 42426384390 (approved in principle) |
| D4 | The verifier may write test-only helper code in an isolated workspace; never in the production repository, protected branches, original migrations or production environments |
| G0-01…04 | Corrections required in the G0 plan: installer sequence, V3.12, V9.2 split, AT-BAK-03 inventory |

## 2. Delegation (Owner, 2026-11-10 19:04 America/Toronto)

Instruction, translated from Chinese: "Decide according to your AI experience. Design each later development stage to be completed in one step, unless a ChatGPT review is needed, to reduce my involvement."

Effect:

1. Claude decides open design and process items itself and records each one as `DELEGATED_DECISION`, with its reason, in the stage record.
2. Each development stage is planned and completed in one pass: design check, implementation, tests, CI, notes, and a branch with a PR. There is no intermediate stop. An independent review (ChatGPT or Codex) is requested where §3 requires it.
3. This record supersedes, for later stages, the earlier working rule of stopping for the Owner's review after each work package.

## 3. Boundaries Claude keeps under the delegation

These stay with the Owner. Claude prepares them but does not decide or execute them:

| Boundary | Reason |
|---|---|
| Real or tax data of any kind; gate O-8; CPA gate G-CRA-1 | Privacy and legal risk; Owner rule |
| Cloud provisioning, deployment, paid services, M0 measurements | Cost and external exposure |
| Changing any Owner decision (SIN Option (b), A1-OD-1…3, D1–D4, earlier ODR rows) | Only the Owner can change his own decisions |
| Merging into `main` | `main` stays under the Owner's control. Claude opens PRs with green CI and a merge recommendation; the merge is one click for the Owner |
| Signing off independent verification (G0, external reviews) | The author cannot verify his own work |
| Irreversible actions (deleting branches, history rewrites, force-push, deleting artifacts) | Not undoable |

Required independent reviews: G0 (Codex or a human, D1) before real data. A ChatGPT or Codex review of each stage that adds a security control (9011 SIN detector and document pipeline; 9014 tax output; 9016 backup and restore) before its PR is recommended for merge.

## 4. Decisions Claude made under the delegation (2026-11-10) — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-A1-1 | The ITN is protected like a SIN: nine digits beginning `08` or `09` are candidates in every origin, with no check digit assumed. EN labels "Individual Tax Number" and "ITN" are added; FR and ZH labels only once verified from the CRA. TTN and other identifiers are out of scope until their format is verified (Addendum A1 Rev 1 §3.6) | Owner rule: never store or display sensitive government ID numbers. Fact F-5 is verified. Fail closed at a measured cost (about 2 % more candidates) |
| D-A1-2 | Assumption A-1 (CRA Mod 10 = Luhn) accepted | The label, OCR and ITN rules do not depend on it |
| D-A1-3 | Proximity windows (64 characters after, 32 before) and the label set kept | No evidence for other values before the corpus exists; the values become versioned parameters |
| D-A1-4 | `T_ocr` and the scan budgets are set in 9011 from the synthetic corpus | They need measurement; they can only add candidates, never remove them |
| D-A1-5 | Addendum A1 Revision 1, the Owner Decision Register V1.2-A1r1, the SIN decision package Rev 1, the G0 plan Rev 1 and the change log are accepted and committed to branch `s4/design-addendum-a1`. They are merged into `main` together with the 9011 PR, not separately | Design records belong next to the code they bind; no `main` change without the Owner |
| D-G0-1 | CI evidence (D3): Claude archived the three job logs with a SHA-256 manifest and delivered them to the Owner. The two artifact zips could not be downloaded from Claude's environment (the storage host refused the request); the Owner downloads them from the run page before 2026-12-07 23:42 UTC. The proposed long-term location is the Owner's Google Drive. No repository copy is made | The repository is public and the evidence stays outside it; the archive is complete except for what the environment cannot reach |
| D-G0-2 | The G0 plan Rev 1 is accepted for execution. A self-contained verifier brief (`docs/s4/g0/G0_VERIFIER_BRIEF.md`) is prepared; the Owner hands it to Codex or a human verifier. That hand-off and the sign-off of the result are the Owner's only G0 tasks | D1 requires a verifier independent of Claude |
| D-ST-1 | Next stage: 9011 starts now on its own branch from `main`, in parallel with G0 and with synthetic data only. Any G0 finding is fixed in a separate PR and 9011 is rebased on it | 9011 is additive and G0 verifies a frozen baseline; waiting would serialise two independent pieces of work |
| D-ST-2 | 9011 is split into sub-stages, each completed in one step: 9011a shared detector, corpus and database guards (including the DOC-SIN-10 MODIFY of the 9010 objects); 9011b document intake states, the declaration command and the admission check; 9011c Executor validators (PDF, images and OCR, XLSX, EML, CSV, OFX). A Codex review follows 9011c, before the merge recommendation | Each sub-stage stays reviewable and testable on its own; the security review covers the whole control at once |
