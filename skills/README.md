# Balnexa skills

`DRAFT — AI-generated` (Claude). It becomes authoritative once the project Owner confirms it.

Balnexa runs on an AI platform (OD-AI-1, OD-AI-4). The household's AI does the workflows (reading statements, reconciling, reporting, filing), and the database does the checks, the drafts, the approval path and the posting. A **skill** is the written procedure for one workflow: the tools it calls, the checks it expects from the database, and what it must never do. Skills replace the main code development (OD-AI-3). The design is in `docs/s4/S4_AI_First_Workflows_Design_2026-11-16.md` §5.

## What is here

| Path | What it is |
|---|---|
| `<name>/SKILL.md` | One skill: front matter (`name`, `description`) and the procedure |
| `INDEX.csv` | One row per skill: `name, version, status, path, size_bytes, sha256`. Kept in step by `tools/s4/skill_index.py`; CI runs `--check` |
| `BALNEXA-AI-ENTRY.template.md` | Template of the entry file a household puts in its data folder (`00-Governance/BALNEXA-AI-ENTRY.md`) |

| Skill | Workflow | Version | Status |
|---|---|---|---|
| `balnexa-statement-intake` | W1: one bank, card or investment statement as a statement draft; a new account is proposed first (two-step approval) | 0.2.0 | candidate |
| `balnexa-history` | W6: past statements per account, oldest first, and the history report | 0.2.0 | candidate |
| `balnexa-reports` | W4, OD-IO-4/5: fixed and real-time reports from read tools | — | planned |
| `balnexa-entry` | W2: single transactions and receipts as drafts | — | planned |
| `balnexa-reconcile` | W3: explaining reconciliation exceptions | — | planned |
| `balnexa-filing` | W5: `30-Processed` copies and the document index | — | planned |

## Generic copies only

The skills here serve every Balnexa household, so they hold **no instance details**: no instance URL, no folder ids, no member names, no account numbers. A skill tells the AI to read the household's entry file first; the entry file holds the instance values. `skill_index.py --check` refuses a skill that contains a `workers.dev` host, a Drive link or a Drive-style file id.

The rules every skill follows are stated in the skill itself and repeated in the entry file: B1 (figures from read tools only), B2 (the database refuses a wrong entry), B3/C-04 (the AI drafts, a member approves in the app), B4 (saved reports carry their queries), no SIN, last 4 digits only, and `20-Inbox` is read only.

## Three copies (Owner decision Q2, 2026-11-16)

| Copy | Where | Who uses it | Checked by |
|---|---|---|---|
| Generic | this folder | every Balnexa user; the source for the other two | `skills/INDEX.csv` |
| Household | the data folder: `50-Skills/Validation/<name>/SKILL.md` (candidate) or `50-Skills/Active/<name>/SKILL.md` (published), listed in `10-Index` | any AI host, including one without native skills (for example ChatGPT), which loads it from the folder | the household's skill index: same SHA-256 as this repository's index for the same version |
| Native | the member's AI account (for example a Claude skill) | an AI host with native skills | same text; the host may rewrite the front matter, so the SHA-256 is not compared |

The household copy is byte-identical to the file here: UTF-8, no byte-order mark, LF line endings, a final newline. Upload it as a plain file, not converted to a document, so that its bytes and SHA-256 are kept.

## Life cycle

1. **Write or change** the skill here. Run `python3 tools/s4/skill_index.py --write`, set the new version in `INDEX.csv` (`N.N.N`), and commit. A changed file with an unchanged row fails CI.
2. **Candidate.** The AI uploads the file to the data folder under `50-Skills/Validation/<name>/` as a new file and adds an index row with status `candidate`, its file id, size and SHA-256. It is used only for tests on synthetic data.
3. **Publish.** The member (the household's Owner) publishes it. The AI then uploads the same bytes under `50-Skills/Active/<name>/`, adds an `active` row with who published it and when, and sets `INDEX.csv` to `active` in the next pull request. The member may also save it as a native skill.
4. **New version.** Always a new file; the old row becomes `retired` and the old file is kept, so every report and draft can be traced to the skill version that produced it.

AI output stays `DRAFT` until a person confirms it: a skill is never published by an AI.

## How an AI host loads a skill from the data folder

1. Read `00-Governance/BALNEXA-AI-ENTRY.md`.
2. Read the skill index in `10-Index` and find the `active` row of the skill.
3. Load the file by its id, compute the SHA-256 of its bytes and compare it with the row. On a mismatch, stop and tell the member. If the host cannot compute a SHA-256, tell the member that the skill is unverified before using it.
4. Follow the skill.
