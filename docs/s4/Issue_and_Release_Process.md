# Balnexa public issue record and release process

`DRAFT — AI-generated` (Claude). It becomes authoritative once the Owner confirms it. Owner request 2026-11-15 09:02: "该公开项目设计一个公开的记录，设计让各位使用者把问题记录进去，然后由我统一升级版本" (a public record where users file problems; the Owner then upgrades the version in one place).

## 1. Roles

| Role | Who | Does |
|---|---|---|
| Reporter | Anyone who runs or tries Balnexa (instance operators, household members, contributors) | Files an issue with a form; answers questions on it |
| Owner (maintainer) | The project Owner | Triages, decides what is fixed and in which release, publishes releases. Only the Owner changes `main` and publishes a release |
| AI developer | Claude Code sessions working for the Owner | Proposes triage, fixes issues in pull requests ("Fixes #n"), runs the full regression, drafts the release notes. Merges and releases only on the Owner's explicit request |

## 2. Where problems are recorded

**GitHub Issues of this repository** is the one public record (`https://github.com/walter-luo/balnexa/issues`). Blank issues are switched off; every issue starts from a form (`.github/ISSUE_TEMPLATE/`):

| Form | Use | Labels set |
|---|---|---|
| Problem report | Something does not work as described | `type:problem`, `status:triage` |
| Wrongly refused | A SIN or card-number guard refused ordinary data (`SIN_CANDIDATE`, `PAN_CANDIDATE`). The form asks for the *shape* of the value, never the value | `type:false-refusal`, `status:triage` |
| Idea or improvement | A need, and optionally a proposal | `type:idea`, `status:triage` |
| Question | Installing, using, upgrading | `type:question`, `status:triage` |

Each form asks for the **release** (Settings → Version in the PWA, or `release` in `/app/config.json`). The PWA's Settings screen shows the version and links to the problem form with the release prefilled. The link is plain: nothing is sent from the page.

**Security problems and privacy leaks** are never filed as public issues. They go through GitHub private vulnerability reporting (the Security tab; `SECURITY.md`).

## 3. Labels and milestones

The labels are defined in `.github/labels.json` and applied with `tools/s4/sync_labels.py --apply` (dry run by default; nothing is deleted).

| Group | Labels |
|---|---|
| Type (set by the form) | `type:problem`, `type:false-refusal`, `type:idea`, `type:question` |
| Status (set by the Owner) | `status:triage` → `status:needs-info` / `status:accepted` → `status:planned` → `status:released`; or `status:wontfix`, `status:duplicate` |
| Impact (set at triage, from the form) | `impact:blocker`, `impact:wrong-result`, `impact:workaround`, `impact:cosmetic` |
| Privacy | `privacy:redacted`: the guard or the Owner removed a sensitive value |

**One milestone per release**, named by its release string (for example `0.9.9-p2`). An issue with `status:planned` belongs to exactly one milestone. Whatever is in the milestone when the Owner publishes it is in the release.

## 4. Privacy on a public tracker

The repository is public, so whatever reporters write can be read by anyone.

- **The forms** tell reporters to use synthetic or redacted examples. Each form has a required privacy checkbox.
- **The issue guard** (`.github/workflows/issue-guard.yml`, `tools/s4/issue_guard.py`) runs on every new or edited issue and comment. It uses the same detectors as the database, the SIN detector and the card-number detector v1.1.0.
  - A SIN-like number is replaced with the mask. A card number keeps only its last 4 digits.
  - The guard adds `privacy:redacted` and posts one comment that names the kind of value removed, never the value.
  - It reads only the event file and never runs anything an issue contains.
  - Its redaction is checked by `issue_guard.py --self-test` in CI.
- **What the guard cannot undo:** GitHub keeps an issue's edit history, and e-mail notifications go out before the guard runs. When `privacy:redacted` appears, the Owner deletes the original revision from the edit history ("Edited" → the revision → Delete revision). If the value had already been sent by e-mail, the Owner asks the reporter to treat it as exposed.
- **Anything else sensitive** that the detectors do not recognise (names with amounts, account numbers, statement images): the Owner edits or deletes it by hand, deletes the revision, and adds `privacy:redacted`.

## 5. From issue to release

1. **Triage** (Owner, with an AI proposal if wanted):
   - confirm the type and add an impact label;
   - set `status:accepted`, `status:needs-info`, `status:wontfix` or `status:duplicate`, with a one-line reason;
   - a false refusal also gets the detector rule it hit.
2. **Plan:** the Owner puts accepted issues in the next release milestone (`status:planned`).
3. **Fix:** each fix is a pull request with `Fixes #n` in its description, following the project rules:
   - a full local regression recorded under `EVIDENCE/regression/`;
   - gitleaks and the SIN and card-number history scans;
   - committed migrations are never edited;
   - a new migration bumps the release.
4. **Release** (only on the Owner's explicit request):
   1. All PRs of the milestone are merged; CI is green on `main`.
   2. `CHANGELOG.md`: the release's section lists each change with its issue number, the migrations, and any action an operator must take.
   3. Tag `v<release>` on the `main` commit, and publish a GitHub Release with the CHANGELOG section. `release/manifest.json` records the migration digests. The milestone is closed, and its issues get `status:released`.
5. **Upgrade:** instance operators follow the upgrade procedure in `docs/s4/M0A_Deployment_Runbook.md`. The release notes say which migrations run and whether the Worker must be deployed with them. B3 refuses a Worker whose schema range does not cover the database.

## 6. What the Owner decides

- Whether an issue is fixed, and in which release.
- When a release is published, and its number.
- Whether a false refusal is tuned, which changes a detector and so needs a new migration and a new detector version, or is accepted as the price of failing closed.

## 7. Settings the Owner turns on once

These are repository settings, not files. Each is done on the Owner's instruction:

- **Labels:** `python3 tools/s4/sync_labels.py --apply`.
- **Private vulnerability reporting:** Settings → Code security → Private vulnerability reporting → Enable.
- **Optional:** turn off the wiki, so that issues remain the only public record.
