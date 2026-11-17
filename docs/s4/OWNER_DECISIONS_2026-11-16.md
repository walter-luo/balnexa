# Owner decisions — 2026-11-16

`DRAFT — AI-generated` (Claude) record of the project Owner's instructions; authoritative once the Owner confirms it.

On 2026-11-15 the Owner asked what the release number means and why it read `0.9.10-p2`: "如果是项目本身的版本号，就用 V1.0 R01" (if it is the project's own version number, use V1.0 R01). Claude explained that the release string names one published version of the software; compatibility between Worker and database is decided by migration numbers, so the string carries no ordering logic. Claude proposed a hyphen instead of the space, because git tags and the PWA cache name cannot contain spaces. Recorded from the Owner's message of 2026-11-16 05:55 (America/Toronto): "版本号用 V1.0-R02" (use V1.0-R02 as the version number).

| ID | Decision | Effect |
|---|---|---|
| OD-REL-1 | The release string is **`V<major>.<minor>-R<nn>`**; the first release under it is **V1.0-R02** (the fix for #52). R counts releases; V changes only when the Owner decides on a larger functional step | `apps/worker/src/release.js`, PWA shell `bnx-shell-V1.0-R02`, `release/manifest.json`, issue-form placeholders, `CHANGELOG.md`. The git tag is the release string itself, `V1.0-R02` (the process said `v<release>`; changed). Releases up to 0.9.9-p2 keep their names; earlier `min_worker_release` values in the manifest are unchanged |

## Direction: AI-first (later on 2026-11-16, America/Toronto)

The Owner's messages of 14:09, 14:15, 14:21, 17:15 and 22:04 set the direction. The design that follows from them is in `docs/s4/S4_AI_First_Workflows_Design_2026-11-16.md`.

| ID | Decision |
|---|---|
| OD-AI-1 | Balnexa is **AI-first**. AI reads documents, reconciles, writes reports and runs the workflows. The database and the data folder are the permanent stores, and the PWA is developed further |
| OD-AI-2 | The architecture is unchanged. Whatever an AI with a skill can do is not programmed. Programs are for the database, validation and the transaction flow. Reports are produced by AI |
| OD-AI-3 | The functions are delivered through AI skills: statement reconciliation, transactions of a period, and so on. Balnexa supports entering and verifying historical data |
| B1–B4 | B1: report figures come from database queries. B2: the database keeps its integrity rules. B3: C-04 stays (AI drafts, a member approves). B4: every AI report is saved with its queries |
| Q1 | A statement may be approved while its evidence hash is pending, for synthetic testing; this is decided again before real data |
| Q2 | Skills live in the household's data folder (loadable by AI hosts without native skills, such as ChatGPT), in the member's Claude account, and as a generic copy in this repository |

## 2026-11-17 06:51 (America/Toronto)

| ID | Decision |
|---|---|
| OD-AI-4 | Balnexa is a project that runs on an AI platform: system functions depend on the AI and AI skills, and the database work is done by code the AI calls. **Dual AI:** the household chooses the runtime AI platform; the other platform serves as **reviewer**, chosen by the Owner. The PWA (phone, offline or web) is only for data work: queries, data entry and viewing reports |
| OD-DRV-1 | Balnexa keeps its own Drive directory. Other projects' folders may serve as reference only and are never changed |
| OD-DRV-2 (06:59) | The household data folder is Balnexa's own Drive directory. The entry file, `50-Skills` and the skill index go there. Balnexa material that had been stored inside another project's folder was moved back into it on 2026-11-17 |
| OD-APR-1 (06:59) | The approval of AI drafts counts as data entry and is done in the PWA |
