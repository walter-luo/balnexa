# AUD-048 — Three orthogonal acceptance axes (R6.2-R1)

OWN-01 is **unchanged**: ChatGPT remains the Owner's primary AI host preference and the PWA must be complete without AI.
This matrix separates *what is proven* from *preference*; it does not change any Owner decision.

## Axis 1 — Full PWA business workflows with **both** AI hosts disabled (gate G2)

| ID | Workflow | Server surface today | Status |
|---|---|---|---|
| A1-01 | Google sign-in, session, logout | `/auth/google/callback`, `authn_begin_session`, `cmd_revoke_session` | Server: AUTHOR_RUNTIME_EVIDENCE (BB-AUTH-01/02); UI: NOT_IMPLEMENTED |
| A1-02 | Household members, roles, suspension | `cmd_invite_member`, `cmd_set_member_state` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-PLAN-03, AT-SNAP-03); UI: NOT_IMPLEMENTED |
| A1-03 | Account creation (institution, label, multi-currency) | `cmd_create_account` | Server: AUTHOR_RUNTIME_EVIDENCE (BB-API-01); UI: NOT_IMPLEMENTED |
| A1-04 | Opening date and amount per account-currency, revision | `cmd_set_opening` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-CMD-07); UI: NOT_IMPLEMENTED |
| A1-05 | Manual journal, split, FX conversion | `cmd_post_transaction` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-BAL-03, BB-API-01); UI: NOT_IMPLEMENTED |
| A1-06 | Correction (reversal + replacement) | `cmd_correct_transaction` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-CMD-05); UI: NOT_IMPLEMENTED |
| A1-07 | Statement upload, OCR review | `cmd_register_evidence`, `cmd_assign_evidence` (registration only) | Pipeline NOT_IMPLEMENTED (M1/M0-B) |
| A1-08 | Import plan review, approval, activation | `cmd_create_import_plan`, `cmd_approve_plan`, `wrk_*` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-PLAN-01…03, BB-PLAN-01/02); UI: NOT_IMPLEMENTED |
| A1-09 | Reconciliation | — | NOT_IMPLEMENTED (M2) |
| A1-10 | Reports R01–R34 | `q_balances`, R-BAL snapshot only | 33 of 34 report surfaces NOT_IMPLEMENTED (G2) |
| A1-11 | Settings, export (PDF/Excel/CSV) | `cmd_set_household_setting` (one setting) | NOT_IMPLEMENTED except one setting |
| A1-12 | Family access (grants, private accounts) | `cmd_set_grant`, `cmd_create_account visibility` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-CMD-03); UI: NOT_IMPLEMENTED |
| A1-13 | Backup/recovery controls | backup job NOT_IMPLEMENTED; dump/restore path AT-BAK-01 | Partial (G0 only) |
| A1-14 | Evidence viewing with live revocation | `q_evidence_access` | Server: AUTHOR_RUNTIME_EVIDENCE (AT-EVP-11); URL presign NOT_IMPLEMENTED |

## Axis 2 — Optional AI-host qualification, per host, signed separately (gate G1 M0-A-06, then G2)

| Host | OAuth (PKCE S256) | MCP read tools | Propose tools | File parameters | Status |
|---|---|---|---|---|---|
| ChatGPT | Implemented server-side; synthetic client `chatgpt-test` in tests | `get_balances`, `create_report_snapshot`, `replay_snapshot` | NOT_IMPLEMENTED (M1) | NOT_IMPLEMENTED | **NOT_TESTED** on the real host |
| Claude | same server path | same | NOT_IMPLEMENTED (M1) | NOT_IMPLEMENTED | **NOT_TESTED** on the real host |

The database refuses every AI-channel write (T2/T3) independently of the Worker (AT-CMD-04, BB-OAUTH-01). A synthetic
host passing BB-OAUTH-01 is **not** evidence that ChatGPT or Claude accept this server; only M0-A-06 runs on the real hosts.

## Axis 3 — Everyday interface/branding priority (Owner-controlled)

OWN-01 as recorded in the Draft-04 Register. No change is inferred. If the Owner wants to change interface-priority
wording it is a Register entry before UI baseline freeze, not an engineering decision.
