# Owner decisions — 2026-11-16

`DRAFT — AI-generated` (Claude) record of the project Owner's instructions; authoritative once the Owner confirms it.

On 2026-11-15 the Owner asked what the release number means and why it read `0.9.10-p2`: "如果是项目本身的版本号，就用 V1.0 R01" (if it is the project's own version number, use V1.0 R01). Claude explained that the release string names one published version of the software; compatibility between Worker and database is decided by migration numbers, so the string carries no ordering logic. Claude proposed a hyphen instead of the space, because git tags and the PWA cache name cannot contain spaces. Recorded from the Owner's message of 2026-11-16 05:55 (America/Toronto): "版本号用 V1.0-R02" (use V1.0-R02 as the version number).

| ID | Decision | Effect |
|---|---|---|
| OD-REL-1 | The release string is **`V<major>.<minor>-R<nn>`**; the first release under it is **V1.0-R02** (the fix for #52). R counts releases; V changes only when the Owner decides on a larger functional step | `apps/worker/src/release.js`, PWA shell `bnx-shell-V1.0-R02`, `release/manifest.json`, issue-form placeholders, `CHANGELOG.md`. The git tag is the release string itself, `V1.0-R02` (the process said `v<release>`; changed). Releases up to 0.9.9-p2 keep their names; earlier `min_worker_release` values in the manifest are unchanged |
