# Balnexa S4 — PR review guide (PR #1–#4)

| Field | Value |
|---|---|
| Purpose | Help the Owner review the four stacked S4 pull requests. It names the changes that matter most and the order to merge in. |
| Scope | PR #1 `s4/core-1` → `main`, PR #2 `s4/core-2` → `s4/core-1`, PR #3 `s4/core-3` → `s4/core-2`, PR #4 `s4/core-4` → `s4/core-3` |
| Evidence | All test results are `AUTHOR_RUNTIME_EVIDENCE`. CI (`.github/workflows/ci.yml`) re-runs every suite on PostgreSQL 16 and 17 (PGDG) for each PR. A same-family (Fable) review of the high-risk areas is reported on the PRs. Nothing is `VERIFIED_INDEPENDENT`. |
| Not in scope | Cloud, credentials, real data, deployment: none of the four PRs touches them |

## 1. How to read each PR quickly

1. Open the PR's implementation notes (`docs/s4/S4_COREn_Implementation_Notes.md`) and read §1 (what was built) and §3 (findings). Every Owner-severity finding (**O**) has been decided and recorded in `docs/s4/OWNER_DECISIONS_*.md`.
2. Check that CI is green on the PR's head commit. CI runs all suites, not only the PR's own.
3. Review the files in the table below. In SQL, most lines are new functions. The lines that change existing R1 behaviour are the `MODIFY` blocks (`create or replace function` on an R1 name) and the `alter table` statements.

## 2. What matters most, per PR

### PR #1 — CORE-1 (B002, 9002–9004, runner) — **highest risk**

| File | Why it matters | What to check |
|---|---|---|
| `db/migrations/0108_grants_and_privilege_audit.sql` | **The only changed R1 file**, an 8-line amendment you authorized (F-C1-01 option a). The original is in `db/history/r1/` | `git diff d0d1365 -- db/migrations/0108_grants_and_privilege_audit.sql`. The audit now accepts the installer's membership in `bnx_definer` only as ADMIN without SET or INHERIT, held by the B001 `applied_by_session` role. A database built with the original 0108 is refused (AT-MIG-11c) |
| `db/bootstrap/B002_bootstrap_s4.sql` | Creates the 7 schemas and 2 new NOLOGIN roles. Ends by revoking the installer's own SET/INHERIT self-grants | Run under `createrole_self_grant=set,inherit` as documented. Nothing is left that lets the installer act as `bnx_definer` |
| `db/migrations/9002_…` | `apply_grants` / `audit_privileges` MODIFY: prefix → role (`cmd_`/`q_` app, `wrk_` worker, `authn_` authn, `stg_` stager, `fed_` fed_reader; `install_*`, `pol_*` never granted) | Rules ROLE_INVENTORY, INSTALLER_MEMBERSHIP, NEW_SCHEMA_UNREGISTERED, RUNTIME_SCHEMA_USAGE, STAGER_NO_POSTING |
| `db/migrations/9003_…` | Config lifecycle; `install_activate_config` | Activation is installer-only; T3 freshness ≤ 15 min |
| `db/tools/run_migrations.py` | Two lanes (core 0001–8999, extension 9000–9999) | Exit 6 `BOOTSTRAP_MISSING` is all-or-nothing |

### PR #2 — 9005 audit v2, 9006 registry, 9007 module flags

| File | What to check |
|---|---|
| `9005_s4_audit_chain_v2.sql` | v1 events still verify byte for byte; the v2 hash is TimeZone-independent (F-C2-01) |
| `9006_s4_registry_policy_accounts.sql` | The seed and your F-C2-05 jurisdictions; data migration of free-text institutions. **Upgrade consequence F-C2-04 (accepted):** R1 accounts get region UNKNOWN and stay hidden until you verify the institution |
| `9007_s4_module_flag_enforcement.sql` | Fail closed without an ACTIVE configuration; grants on a disabled region can be reduced but not widened (F-C2-13) |

### PR #3 — 9008 economic types and chunked posting, 9009 OAuth

| File | What to check |
|---|---|
| `9008_s4_economic_type_rule.sql`, `apps/worker/src/dispatch.js` | B6.1 deferred check at COMMIT; plans post in chunks, at most 4 chunks per dispatcher item |
| `9009_s4_oauth.sql`, `apps/worker/src/index.js` | Code replay or refresh reuse revokes the tokens; the revocation commits because the call returns an error object instead of raising (F-C3-06). The MCP scope catalog is fail-closed |

### PR #4 — 9010 intake, drafts, holds, lease

| File | What to check |
|---|---|
| `9010_…` Part 1 | `cmd_approve_plan` keeps the 0109 body and adds `PLAN_HELD`. AI connections can create drafts but never approve them. Your F-C4-09 commands `cmd_withdraw_plan` / `cmd_validate_plan` |
| `9010_…` Part 2, `apps/worker/src/jwt.js` | The lease nonce is stored only as a hash and used once; the job identity (sub/email/azp) is pinned; staging never posts (AT-EXEC-01/02, BB-EXEC-01) |
| `9010_…` Part 3 | Index location is a secret reference only; a mail address is Owner-only; no subject/body is stored; handoff import treats only the fenced JSON block as data |

## 3. Merge procedure (stacked PRs)

- Use **"Create a merge commit"** for all four. Do **not** squash or rebase: the upper branches contain the lower commits, and a squash leaves #2–#4 with conflicting histories.
- Order: **#1 → main**, then change the base of #2 to `main` (GitHub offers this; it does it automatically only if `s4/core-1` is deleted), merge #2, and the same for #3 and #4.
- Alternative with the same final result: merge top-down (#4 into `s4/core-3`, #3 into `s4/core-2`, #2 into `s4/core-1`), then #1 into `main`. You then approve once, on #1, with the whole change visible.
- After merging, keep the `s4/core-n` branches until the next increment has started from `main`.

## 4. Things a reviewer should not need to check

- Test re-baselines: each is listed in §4 of the notes with the reason, and every re-baselined test still asserts the behaviour it was written for.
- Generated seed SQL: `tools/s4/gen_registry_seed_sql.py` builds it from the Amendment 02 seed JSON (SHA-256 recorded in the CORE-2 notes; the JSON is not committed).
- `EVIDENCE/`: raw runner output, kept for traceability. CI produces its own copy as a downloadable artifact.
