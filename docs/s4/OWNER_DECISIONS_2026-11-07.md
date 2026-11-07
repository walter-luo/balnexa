# Owner decisions — 2026-11-07

Recorded from the Owner's message of 2026-11-07 09:13 America/Toronto ("SIN 根本不进系统，只在填表那一刻由你手工输入，其他同意"), answering the plan presented on 2026-11-07 06:36. Grade: `OWNER_DECISION`.

| Item | Decision | Effect |
|---|---|---|
| ODR "SIN" (Unresolved Owner Decision Register V1.2, row SIN; CRA contract §2) | **SIN never enters Balnexa.** This is stricter than the design default `per_generation`, under which the Owner types the SIN at PDF generation and the Executor writes it into the form field without persisting it. Under this decision the SIN reaches no Balnexa component: database, Worker, Executor, Gateway, logs, prompts, AI hosts, renditions, exports, or generated PDFs. The Owner types it by hand into the official form or filing software, outside Balnexa, when filling. | 9014 / WP-TAX: no `sin_fingerprint`; no `sin_entry_mode` other than `none`. Generated official forms leave the SIN field blank and come with a checklist line "enter SIN by hand". PV-CRA-01 verification must accept the blank SIN field. Structured inputs (taxpayer, slip and handoff fields) refuse SIN-shaped values. Masked renditions keep `[MASKED:SIN]`. Open point: SIN printed on original evidence documents (see below) |
| CI (plan step 1a) | **Accepted**: GitHub Actions on the public repository. It runs a secret scan and the full suites on PostgreSQL 16 and 17 (PGDG builds with `pg_dump`/`pg_restore` of the same major). No secrets, no cloud resources, no deployment. | `.github/workflows/ci.yml` on `s4/core-1`, merged up the stack |
| PR review guide (plan step 1) | **Accepted** | `docs/s4/S4_PR_Review_Guide.md` |
| Same-family review (Fable) of the high-risk areas | **Accepted** as recommended (optional, before merge). Grade of its findings: same-vendor review, **not** `VERIFIED_INDEPENDENT` | Findings handled in the PR where they arise |
| Independent checks | **Accepted** as recommended: an independent G0 reproduction (ChatGPT/Codex) before any real data; an independent G-CRA-1 tax-rule validation (CPA) before any tax output is used. Neither is scheduled now | No change to the S5 waiver |
| Order | **Accepted**: merge PR #1–#4 before 9011 | 9011 waits for the merge or a new instruction |

## Open point raised by the SIN decision

Original slips and notices (T4, T5, NOA) carry the SIN in print. Balnexa keeps the original bytes as evidence (Drive archive copy, R2/GCS object, SHA-256 verified). Two readings of "never enters the system":

- (a) Originals are stored as opaque evidence and are never parsed into any field. Every read goes through the masked rendition. Extraction refuses SIN-shaped values. This needs no redaction work by the Owner, and the evidence stays bit-identical.
- (b) The Owner redacts the SIN before any document reaches Balnexa. The stored "original" is then the redacted copy, so it differs from the bytes the CRA or the employer issued.

The Owner should choose before 9011 (evidence pipeline) and 9014 (tax).
