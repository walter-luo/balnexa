# Balnexa S4 — pause handoff 2026-11-12 (development paused 3–7 days)

| Field | Value |
|---|---|
| Status | `DRAFT — AI-generated`; authoritative once the Owner confirms it |
| Owner instruction | 2026-11-12 18:40 Toronto: "保持当前项目状态，生成项目必要文档，项目开发工作暂停3-7天。" ("Keep the current project state, produce the necessary project documents, and pause development for 3–7 days.") |
| Reads with | `02_Balnexa_S4_Status_and_Plan_2026-11-12.md`, `03_Balnexa_S4_Platform_Handoff_2026-11-12.md`, and Project doc `04_Balnexa_S4_Progress_2026-11-12_M0A_Phase2.md`. Where they differ, this document is newer |

## 1. Repository state at the pause

All PRs are draft and stacked. Nothing was merged after #9–#16. Merge only on the Owner's request, in order.

| PR | Branch | Head at pause | Migration | Local full regression | CI at pause |
|---|---|---|---|---|---|
| #17–#29 | see doc 04 | — | 9024–9030 | recorded | green |
| #30 | `s4/tool-schemas-2` | b525eab | 9031 | 32a8ce9: 452/0/3 | green |
| #31 | `s4/next-work` | c2d599d | 9032 | 7b56433: 459/0/3 | re-running after the CI fix below |
| #32 | `s4/output-schemas-2` | f1741b7 | 9033 | fd1e2e2: 459/0/3 | re-running after the CI fix |
| — (no PR yet) | `s4/output-contract` (pushed) | ef949df | 9034 | **not complete**: the run was stopped at the pause. All PG17 suites passed on the development cluster with the output contract on | none yet |

**CI fix in flight:** on #31 and #32, `db-tests` failed because CI never installed `cryptography`, which AT-SIG-01 needs (`ModuleNotFoundError`). The failure was reproduced in a clean venv and fixed in c2d599d with a pinned binary install. The fix is merged up into #32 and `s4/output-contract`, and a comment was posted on both PRs. The re-runs had not finished at the pause; **check them first on resume.**

## 2. Deployed synthetic instance

| Item | Value |
|---|---|
| URL | `https://balnexa-test.walter-luo.workers.dev` |
| Release / schema | 0.8.9-p2 / 9033, `bindings.ok`; the Owner is bound |
| Backup | Neon branch `backup-pre-upgrade-9023-to-9032` (no compute) |
| **Credential expiry** | The Cloudflare API token expires **2026-11-19**, possibly during the pause. After that, a deploy needs a new token or the Owner's own `wrangler`. Delete the token when it is no longer needed |
| Cost | Free tiers. Neon computes suspend when idle; the Worker cron runs every minute within the free quota |

## 3. Resume checklist

1. Read this document, then doc 04.
2. Check CI on #31 and #32; fix any red result by its root cause.
3. Restart the local clusters (`scratchpad/bin/pgup.sh`). A new session must rebuild them per doc 03 §5, because the scratchpad does not survive.
4. Run the full regression on `s4/output-contract` at its head and record it (`tools/s4/record_regression.py`). Open the PR to `s4/output-schemas-2`: title "2.8 part 5: output schemas for every MCP read tool (9034) + output contract in every suite; release 0.9.0-p2".
5. Optional: deploy 0.9.0-p2. Deploy the Worker first, then migrate to 9034 (N-1 rule, no gap; runbook "Upgrade").

## 4. Waiting on the Owner

| ID | Decision or input |
|---|---|
| D-JOIN-1 | Show a non-member their own Google subject ID after sign-in (recommended: yes) |
| Register rows 9017–9034 | Accept, amend or reject (`docs/s4/S4_Migration_Register_Addendum_9017_9032.md`) |
| Release signing key | Generate it on the Owner's machine (`tools/s4/release_sign.py keygen`) before any real instance |
| L-DOC2-1 / L-INT-1 | Provider ids with digit runs vs. guard C2 (recommended: stage only digests) |
| Inputs | `verify_ai_entry.py` (ENT-1), AIH-3 rendition design, R28 V1.2 / BAL01–12 definitions |
| Owner testing | `docs/s4/Owner_Acceptance_Test_Guide.md` (parts A–G) on the deployed instance |

## 5. Standing constraints (unchanged)

- Synthetic data only; O-8 and G-CRA-1 stay closed.
- Never store or display SIN or other government IDs.
- Owner-private sources are never committed.
- Run gitleaks and the SIN scan before every push.
- No merges without the Owner's request.
- 9014 needs an Owner decision.
- Free tiers only.
- Secrets never go in the repository or the chat.
- All AI-written docs are DRAFT until the Owner confirms them.
