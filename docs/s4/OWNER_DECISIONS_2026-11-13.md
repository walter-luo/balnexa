# Owner decisions — 2026-11-13

Recorded from the Owner's messages of 2026-11-13 (America/Toronto):
- **06:32:** "2. 独立 G0 复核，你推入GitHub仓库，写prompt。我发给ChatGPT读仓库来测试，测完从仓库返回。或者，我在claude开new clean chat，用不同AI mode来测试。" (Independent G0 run: push a prompt to the repository; the Owner gives it to ChatGPT, which reads the repository, tests, and returns the result through the repository; or a new clean Claude chat in another mode.)
- **06:51:** "版本管理，代码保存，测试数据保存，版本设计文档，全面使用GitHub。特别是双AI审核，测试交换文件和prompt通过GitHub，但owner中间启动替代GitHub action，数据文件存放Drive。Drive数据目录还没建，hostinger邮件和网站，从需求中拿掉。"

Grade: `OWNER_DECISION`. Recorded by the author (Claude) as `DRAFT` until the Owner confirms this record.

| ID | Decision | Effect |
|---|---|---|
| OD-GH-1 | **GitHub is the system of record for the project**: version management, code, test data and test records, and the versioned design documents | Continues the current practice: code, migrations, synthetic fixtures and regression records (`EVIDENCE/regression/`) are already in `walter-luo/balnexa`. Design and handoff documents produced in development go under `docs/`. **Open point P-1** below concerns the Owner-private design package |
| OD-GH-2 | **Dual-AI review runs through GitHub, with the Owner as the dispatcher.** Prompts and exchange files (test outputs, reports) live in the repository. The Owner starts the other AI by hand; there is no GitHub Actions automation for it | Review prompts live in `docs/s4/reviews/`. Results return as a draft PR (R1) or through the Owner, who hands them to the next author session to commit unchanged (R2). See `G0_INDEPENDENT_RUN_PROMPT.md`. CI (GitHub Actions) stays as it is for the author's own checks (OWNER_DECISIONS_2026-11-07) |
| OD-GH-3 | **Data files are stored in Google Drive, not in GitHub.** The Drive data directory does not exist yet | Until the Owner creates it and names its location, nothing is moved to Drive. The repository keeps only synthetic test data and test records; no real data is committed (gate O-8 unchanged). The installer's dedicated Drive identity (OD-50) is a separate runtime concern, not this directory |
| OD-REQ-1 | **Hostinger mail and the Hostinger website are removed from Balnexa's requirements** | No code change: the repository has no Hostinger reference; the mail-source providers are `gmail` and `outlook` only (9010 `bnx_intake.mail_source.provider`), and the instance is served by Cloudflare Workers. Any Hostinger item in the Owner-private Requirements Book is superseded by this decision |
| OD-G0-1 | **Independent G0 by ChatGPT** (another model family) through `docs/s4/reviews/G0_INDEPENDENT_RUN_PROMPT.md`; optionally also a new Claude chat | The ChatGPT run can give `VERIFIED_INDEPENDENT` evidence. A Claude run is `SAME_FAMILY_VERIFICATION` and does not close G0 (doc 03 §6). This changes the 2026-11-10 arrangement under which G0 verification was planned in another Claude session only |

## Open point

**P-1 — the Owner-private design package and GitHub.**

- The repository is public.
- The V1.2 design package (Unified Architecture, contracts, WP matrix, test and migration registers), the S3 package and Design Inputs B have so far been kept out of the repository. Constraint 3 of doc 03 §2 requires this, and CI rejects any `owner_sources` path.
- OD-GH-1 can be read in two ways:
  - (a) Only the documents produced in development are versioned in GitHub; the Owner-private packages stay out. This is the current practice.
  - (b) The design package is also committed, so that a reviewer can read it.

  Reading (b) publishes it, and the Requirements Book contains Owner sources. Until the Owner chooses, the author applies (a).

## Later the same day

Recorded from the Owner's message of 2026-11-13 20:59 (America/Toronto): "1，https://drive.google.com/…（link withheld here）, 20-Inbox/还要分人名，年份，银行，种类，怎么放更合适？AI对20-Inbox只读，其他目录对Owner是只读。" ("1" answers G0-PWA-1, option 1.)

| ID | Decision | Effect |
|---|---|---|
| OD-G0-2 | **G0-PWA-1, option 1:** the PWA suite stands on `AUTHOR_RUNTIME_EVIDENCE` plus CI. The independent G0 verification is complete with that one gate not independently executed | All other G0 gates are `VERIFIED_INDEPENDENT` (runs R1–R3; dispositions in `docs/s4/reviews/`). The PWA-only run on native Windows was `NOT_EXECUTED` (`G0_PWA_R1_DISPOSITION_2026-11-13.md`). An independent PWA run on Linux, for example WSL2, remains possible later and is advised before production use |
| OD-GH-4 | **The Drive data directory exists** (OD-GH-3). Its location is held in the Owner's private project documents, **not in this public repository**. Access rule: **the AI reads `20-Inbox` only; the other folders are read-only for the Owner** | A convention, not a technical control. The AI works through the Owner's own Google account, so Drive cannot enforce it. Integrity is checked through the sha256 of each Inbox original, recorded in the index. The folder layout under `20-Inbox` and `30-Processed` is the author's **proposal, awaiting the Owner's confirmation** |
