# Owner decisions — 2026-11-14

`DRAFT — AI-generated` (Claude) record of the project Owner's instructions; authoritative once the Owner confirms it.

Recorded from the Owner's message of 2026-11-14 05:10 (America/Toronto): "README写DATA OWNER是我，符合公开版要求吗？再准备一份版权文件，版权属于我公司 Tambition Technologies Group Inc." (Does naming me as data owner in the README fit the public-version rule? Also prepare a copyright file; the copyright belongs to my company, Tambition Technologies Group Inc.)

| ID | Decision | Effect |
|---|---|---|
| OD-LIC-1 | The Owner intends the copyright to belong to **Tambition Technologies Group Inc.** Revised at 05:35, "先按这条：作品的第一版权人是作者本人" (for now, follow the rule that the author is the first owner): **the notice names the author, Walter Luo, until a signed written assignment to the company exists**. The license stays Apache-2.0 | `NOTICE` and `README.md`: `Copyright 2026 Walter Luo`. `docs/s4/Copyright_and_Contributions.md` holds the open points CR-1 (when to sign the assignment) to CR-3 |

The Owner's question about the data-owner name was answered in the conversation. The name appears only in the Owner's **private** instance README, which is outside this repository. The public convention (`docs/s4/Data_Folder_Convention.md`) names roles only, so it is consistent with the public-project rule.

Recorded from the Owner's message of 2026-11-14 06:20: "CR-1以后再说，CR-2默认的“贡献即同许可证授权“，CR-3加。" (CR-1 later; CR-2 the default, a contribution is licensed under the same license; CR-3 add.)

| ID | Decision | Effect |
|---|---|---|
| OD-LIC-2 | **CR-1 deferred:** the notice keeps naming the author | — |
| OD-LIC-3 | **CR-2: inbound = outbound** (Apache-2.0 §5); no CLA | `Copyright_and_Contributions.md` §3 |
| OD-LIC-4 | **CR-3: license headers in source files** | `tools/s4/license_headers.py`, the CI step `license headers`, and headers in 105 files; committed migrations, bootstrap files and the frozen reference oracles excluded |

Recorded from the Owner's message of 2026-11-14 09:38: "确认" (confirmed), in reply to the plan for the first processing run of his own data folder instance. The instance and its files are private and are not described here. The plan proposed two rules that apply to any instance:

| ID | Decision | Effect |
|---|---|---|
| OD-DATA-1 | A statement that covers several months is named with the period `YYYY-MM~YYYY-MM`; the date prefix and the year folder use the statement's own date | `Data_Folder_Convention.md` §3 |
| OD-DATA-2 | When the toolchain cannot compute sha256 without passing each file through the AI conversation, sha256 may be **deferred** for a run: server-side copy, file ID and size checks, `sha256` blank with a note, computed later | `Data_Folder_Convention.md` §5 |

Recorded from the Owner's message of 2026-11-14 09:57: "要，继续" (yes, continue), in reply to the question whether the public convention should record OD-DATA-2.

| ID | Decision | Effect |
|---|---|---|
| OD-DATA-3 | The public convention records OD-DATA-1 and OD-DATA-2 | This change. It also carries two additions proposed by the AI: a note in §1 that some connectors can edit only files the AI created (accepted as OD-DATA-6), and the import rule accepted as OD-DATA-5 |

Recorded from the Owner's message of 2026-11-14 11:18: "同意" (agreed), in reply to the consequence of the import rule: a row whose sha256 is deferred cannot be imported until a tool has computed and checked it.

| ID | Decision | Effect |
|---|---|---|
| OD-DATA-5 | **No import with deferred sha256.** A row whose sha256 was deferred under OD-DATA-2 is not imported into Balnexa (`IMPORTED`) until sha256 has been computed for the original and the copy and the two match | `Data_Folder_Convention.md` §5 |

Recorded from the Owner's message of 2026-11-14 12:03, which quoted "同意" (agreed) in reply to the question about the §1 connector note.

| ID | Decision | Effect |
|---|---|---|
| OD-DATA-6 | The §1 note stays: some AI connectors can edit only files the AI itself created, which enforces the `20-Inbox` rule in practice; what the connector reports is checked, not assumed | `Data_Folder_Convention.md` §1 |
