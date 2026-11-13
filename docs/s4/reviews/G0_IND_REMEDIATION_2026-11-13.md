# G0 independent run 2026-11-13 — disposition and remediation

`DRAFT — AI-generated` (the author: Claude). Report: `docs/s4/reviews/g0/20261113_chatgpt-codex/REPORT.md`. Runner: GPT-5/Codex, graded `VERIFIED_INDEPENDENT`; the PWA run is `NOT_EXECUTED`. Code under test: `6913869` (top of #37). Remediation: branch `s4/g0-remediation` (PR #39), migration **9038**, release **0.9.4-p2**.

## Summary

| Finding / observation | Reviewer | Author's verdict | Action |
|---|---|---|---|
| G0-IND-01 `config_modules_valid` | blocker | **Confirmed**. Reproduced independently on PG16 under ICU en-US: core1 gives 7 pass / 5 fail with the same five test ids. Root cause refined below | Fixed in 9038 |
| Collation, general (author's own audit after G0-IND-01) | — | One more collation-dependent result: the institution-candidate de-duplication key | Hardened in 9038 |
| Collation, test side: AT-9013-CAT | (noted in Part A) | **Confirmed**: the test sorted with the database collation | Fixed in the test |
| Collation, lasting guard | — | The suites ran only on `C.UTF-8` clusters, which hid the defect | New CI job `db-tests (17, icu-en-US)`; local ICU lane |
| G0-IND-02 migration history | major | **Not a defect**, but the rule's wording in the prompt was ambiguous | Rule clarified; evidence below |
| G0-IND-03 validator parity | minor | **Confirmed**. Also a second parity gap: string checks ran in a different order | Fixed; new AT-OUT-06 |
| AT-SIN-C6, empty stdout | (noted in Part A) | **Confirmed test defect**: a scanner crash and real hits gave the same exit code. Probable cause on the runner: git's "dubious ownership" refusal; reproduced locally | Scanner exit code 2 plus stderr; the test reports it |
| PWA not executed | limitation | Environment: the Playwright CDN was blocked | none; the author's local run and CI cover it |

## G0-IND-01 — confirmed; root cause is the database collation

`bnx.config_modules_valid` (9003) sorts the module keys with `array_agg(k order by k)` and compares the result with `array['CRA','Canada','International']`. That literal is in **byte order** (C collation: `R` = 0x52 < `a` = 0x61).

The reviewer's clusters used a linguistic default collation. There, `Canada` sorts before `CRA`, so every valid configuration was refused (`VALIDATION_FAILED`, `modules`). The author's clusters, the CI clusters (`initdb --locale=C.UTF-8`) and the synthetic Neon instance all use byte order, which hid the defect. Balnexa is a public, general-purpose project, and many PostgreSQL installs default to a linguistic collation, so this blocks any such install. The reviewer's severity is right.

Reproduction on the author's side:
- An ICU en-US cluster (`initdb --locale-provider=icu --icu-locale=en-US`) gives `{Canada,CRA,International}` for `order by k` and `{CRA,Canada,International}` for `order by k collate "C"`.
- `run_s4_core1.py` on that cluster before the fix gives 7 pass / 5 fail: AT-MIG-10, AT-ISO-03, AT-CFG-14, AT-CFG-15, AT-SET-01. This is exactly the reviewer's core1 line.

**Fix (9038, MODIFY):** `order by k collate "C"`. On byte-order databases nothing changes.

**Audit of the other 46 ordered aggregates.** The author ran it after this finding. Only results that are compared or hashed matter:

| Site | Use | Verdict |
|---|---|---|
| 9006 `cmd_propose_institution_candidate` | candidate de-duplication key built from the sorted identifiers | Collation-dependent: a restore into a database with another collation would give the same identifiers another key. **Hardened in 9038** (`collate "C"`) |
| 9013 `rpt_envelope` `grants_digest` | digest over sorted account-currency UUID text | UUID text is hexadecimal digits and hyphens at fixed positions, which order the same under every collation. Not affected |
| 9002, 9011, 9016 `nspname`; 9017 `proname` | system `name` type | The `name` type always uses C collation. Not affected |
| 9016 backup digests | hashes | Already `collate "C"` |
| 9021/9024 host-profile candidates | only the count (= 1) is used | Not affected |
| the rest | output order only | Not affected |

## G0-IND-02 — not a defect; the rule is now stated precisely

The rule is: a committed migration is never edited; a change is a MODIFY in a new migration. Its purpose is that an installed database never meets a migration file different from the one it applied. A migration counts as committed once it has landed on `main` or been applied to a persistent database.

The author checked every file the reviewer listed:

| File | Commits touching it | Landed on `main` in | Touches after landing |
|---|---|---|---|
| 9002 | 3 | PR #1 merge `c140615` | none |
| 9005, 9006, 9007 | 2 each | PR #2 merge `b9d13c1` | none |
| 9008, 9009 | 2 each | PR #3 merge `f592d58` | none |
| 9010 | 3 | PR #4 merge `ee13eee` | none |
| 9011 | 6 | PR #5 merge `c3401c3` | none |
| 9012 | 6 | PR #6 merge `544389d` | none |
| 9017–9037 (still in draft PRs; 9017–9033 applied to the synthetic instance) | exactly 1 each | — | none |

Every later commit the reviewer found sits inside the PR that introduced the file, before the merge. That is ordinary development of an unmerged migration, and no persistent database had applied any of these files before they landed. The prompt's wording ("touched after the PR that introduced it") was ambiguous: it could be read as "after the introducing commit". The prompt now states the rule as above.

## G0-IND-03 — confirmed; fixed with a lasting parity test

`tests/py/jsonschema_lite.py` lacked `minimum`, `maximum`, `minItems` and `maxItems`. The author also found a second gap: the port checked string `format` before `minLength`/`maxLength`, while the Gateway checks lengths first. A value with two violations could therefore get a different first reason. No current curated schema uses the four keywords, so no earlier result was affected.

Fix:
- The four keywords were added, with booleans excluded from the numeric checks as in JavaScript.
- The string checks now run in the Gateway's order.
- **AT-OUT-06** (core19) feeds 43 cases through both validators, Node `apps/worker/src/schema.js` and the Python port. They cover a valid and an invalid value of every keyword in the Gateway's `KNOWN` set, plus cases with several violations and key-order cases. The test requires identical results, paths and reasons, and that every `KNOWN` keyword is covered. Without the fix it fails and lists the differences.

## AT-SIN-C6 — test defect; fixed

`tools/s4/sin_repo_scan.py` exited 1 both for hits and for an uncaught `git` failure. The test kept only stdout. The reviewer therefore saw "found candidates" with empty output, while its own host scan was clean.

The author reproduced the probable cause: running the scanner as one user on a checkout owned by another makes git refuse with "detected dubious ownership". Before the fix this gave exit 1 with empty stdout.

Fix:
- The scanner exits **2** with the git error on stderr when the scan cannot run.
- AT-SIN-C6 reports exit 2 as "the scan did not run" with stderr, keeps stderr in its evidence, and still fails on hits.
- CI's step fails on any non-zero exit, as before.

## Lasting guard against the defect class

- **CI:** a new matrix entry, `db-tests (17, icu-en-US)`, creates the test cluster with `initdb --locale-provider=icu --icu-locale=en-US` and runs every suite. The existing jobs are now named `db-tests (16, c)` and `db-tests (17, c)`; evidence artifacts are named per job.
- **Local:** the author's regression for this PR runs every suite on both a byte-order pair and an ICU en-US pair (PG16 and PG17). Both records are committed under `EVIDENCE/regression/`.

## What the re-run should show

After 9038, the same environment as the reviewer's should give the author's numbers: 194 per major with 0 fail, 35 Node and the simulation. The PWA needs a browser the reviewer's platform could not download. The Owner may give the same prompt (updated target) to the reviewer again.
