# G0 remediation G0R — 2026-11-11

| Item | Value |
|---|---|
| Source | `Balnexa_G0_Report_2026-11-11.zip` (SHA-256 `bedee84d8f44f5ea9e5a43318d6f907f07994e06f0b5a2819632492e41a0e8f6`; internal `MANIFEST.sha256` verified). Kept by the Owner; not committed (it holds the verifier's logs and dumps) |
| Verifier | Separate Claude Code session on Claude Sonnet 5.5 (report DEV-13). Grade `SAME_FAMILY_VERIFICATION` for every verdict. Independence conditions 1 and 3 not met (report §2) |
| Baseline verified | `main` at `ee13eee` (PR #1–#4). PostgreSQL 16 complete; PostgreSQL 17 `NOT_VERIFIED` (DEV-01: PGDG blocked by the verifier's proxy) |
| Result | PG16: 66 PASS, 2 FAIL (one finding, F-01), 1 NOT_IMPLEMENTED, 1 DEFERRED_BACKUP_GAP, 2 KNOWN_RESIDUAL, 4 NOT_VERIFIED. G0 exit criteria not met (F-01 open, PG17 unverified) |
| Where the fix lives | Bootstrap `db/bootstrap/B003_audit_owner.sql`, migration 9011 block **G0R** (top of the file), runner gate, `tools/s4/audit_chain_verify.py`, tests `tests/py/run_s4_core7.py`. Branch `s4/9011a`, PR #5 |
| Evidence grade of this document | `AUTHOR_RUNTIME_EVIDENCE` (author's own runs). The fix is not verified until a G0 re-run (§6) |

## 1. Disposition of the findings

| ID | Severity (verifier) | Finding | Disposition | Where |
|---|---|---|---|---|
| F-01 | P1 (Owner decision on P0 vs P1 requested) | Owner path (`bnx_migrator` → `SET ROLE bnx_definer`) can TRUNCATE the audit table or disable its triggers and delete rows, and `audit_verify()` still returns 0 | **Fixed.** Reproduced locally first (12 rows → 0, `audit_verify()` = 0). The audit chain is now the table `bnx_audit.audit_event`; the table and its schema are owned by `balnexa_audit_owner`, which is NOLOGIN and has no member with SET or INHERIT. `bnx_definer` has SELECT and INSERT only. All 15 owner-path attacks are refused: TRUNCATE, trigger disable, DELETE, UPDATE, DROP TABLE, DROP SCHEMA, rename, owner change, SET ROLE, CREATE in the schema, self-grant then TRUNCATE, and `session_replication_role`. The privilege audit and an external verifier both detect any weakening | B003, 9011 G0R, AT-G0R-01/02/03 |
| F-02 | P3 | Plan S0 names the installer `bnx_installer`, which cannot pass S5; the reserved prefix is undocumented | **Documented and checked early.** B003 refuses an installer named `bnx_*` with `B003_INSTALLER_NAME`. B001 and B002 are already merged and are not edited. G0 plan erratum E-1 | B003 header, AT-G0R-03 |
| F-03 | P3 | With the UA §6.2 order and a non-superuser installer, the runner exits 6 at 0108, not 7 | **Documentation corrected.** Exit 6 is correct: it is the audit inside the migration transaction. Exit 7 is the runner's post-run audit. Erratum to F-C1-17 in `S4_CORE1_Implementation_Notes.md`; G0 plan erratum E-3 | notes |
| F-04 | P3 | Envelope values accept invisible Unicode format characters (U+200B) under `[[:print:]]` | **Fixed.** Envelope values may contain printable ASCII only (U+0020…U+007E), regardless of locale. The rule applies both in `resolve_actor` and at the point of use (`envelope_value`). Zero-width space, bidi override, no-break space and non-ASCII letters are refused | 9011 G0R, AT-G0R-04 |
| F-05 | P3 (observation) | After upgrade and before activation, posting gives `SCOPE_DISABLED` where AT-FLG-10 says `SCOPE_UNCONFIGURED` | **Explained, no change.** `bnx.pol_require_region` refuses an account in region `UNKNOWN` with `SCOPE_DISABLED` before the configuration is consulted. A known region without an ACTIVE configuration gives `SCOPE_UNCONFIGURED`. The verifier's R1 account was unlinked (region UNKNOWN); AT-FLG-10's account is linked. Both fail closed. Clarified in the CORE2 notes | notes |
| F-06 | Informational | The 9016 anchor must record the head hash, not only the sequence number | **Implemented as a tool; 9016 requirement recorded.** `tools/s4/audit_chain_verify.py --anchor SEQ:HASH` detects tail deletion and a full rewrite with recomputed hashes (V8.6, X2) once an anchor exists. The 9016 backup header and vault manifest must store `bnx.audit_head()`, which already returns `seq` and `hash` | tool, AT-G0R-05 |
| F-07 | Informational (accepted 2026-11-05) | The installer can re-grant itself SET on `bnx_definer` | **Unchanged; extended by one role.** The installer also holds ADMIN on `balnexa_audit_owner`, so the same re-grant is possible there. It is reported at the next audit or runner run (`INSTALLER_MEMBERSHIP`) and by the external verifier (`AUDIT_OWNER_MEMBER`) | residual R-4 |
| DEV-01 | — | PG17 not installable in the verifier's environment | **Owner action needed for the re-run** (§7) | — |
| DEV-13 | — | The session's configured model was Opus 5.5; the model served throughout the run was Sonnet 5.5 | **Owner confirmation needed** (§7) | — |

## 2. What changed

1. **`db/bootstrap/B003_audit_owner.sql`** (new; run by the installer):
   - It runs after the migrations up to 9010 and before 9011, with the same PGOPTIONS as B002 for a non-superuser installer.
   - It creates the role `balnexa_audit_owner` and the schema `bnx_audit`.
   - It moves `bnx.audit_event` into `bnx_audit`, transfers ownership, and leaves `bnx_definer` with SELECT and INSERT only.
   - It creates the compatibility view `bnx.audit_event`, owned by `bnx_definer`.
   - It registers the schema's default privileges for `bnx_backup`.
   - It removes every membership it granted to itself.
   - Its re-run guard and pre-checks read only the system catalogs, because after B002 the installer cannot read `bnx`.
   - Running it again is a no-op.
2. **Runner** (`db/tools/run_migrations.py`): before 9011 it requires B003 (the `schema_bootstrap` row, and `bnx_audit.audit_event` owned by `balnexa_audit_owner`). Without B003 it applies the pending migrations before 9011, then stops with `BOOTSTRAP_MISSING` (exit 6) and names the file to run.
3. **Migration 9011, block G0R:**
   - An assertion of B003.
   - Registration of `bnx_audit` (owner `balnexa_audit_owner`, USAGE `bnx_backup` only).
   - MODIFY of `audit_verify`, `audit_head` and `trg_audit_chain_version`, which now read the table, not the view.
   - MODIFY of `audit_privileges`:
     - ten roles;
     - the relation owner is the schema's registered owner;
     - new rules `AUDIT_TABLE_OWNER`, `AUDIT_TABLE_PRIVILEGE`, `AUDIT_TRIGGER` and `AUDIT_OWNER_LOGIN`;
     - `bnx_definer` may not create objects in `bnx_audit`, and `balnexa_audit_owner` may not create objects anywhere else.
   - MODIFY of `envelope_value` and `resolve_actor` (F-04).
   - The 9011a `audit()` writes `bnx_audit.audit_event`.
4. **`tools/s4/audit_chain_verify.py`** (new): an external verifier.
   - It runs read-only as `bnx_backup` and calls no `bnx` function.
   - It checks the catalog facts B003 established.
   - It recomputes every v1 and v2 hash with PostgreSQL built-in functions only.
   - It checks anchors and prints the current head as the next anchor.
   - Exit codes: 0 intact, 1 failed, 2 unreadable.
5. **Backup scope:** AT-BAK-01 now dumps `--schema=bnx --schema=bnx_audit --schema=auth` and compares the audit rows after restore. The production backup procedure (9016) must use the same scope.
6. **Tests:**
   - New `run_s4_core7.py`: AT-G0R-01…05.
   - AT-MIG-11b: the non-superuser installer now runs B003 itself and is left with 10 ADMIN-only memberships.
   - AT-INV-01: maps the relocated trigger.
   - The harness's `migrate()` performs the documented B003 step when the runner asks for it, and `drop_all()` also drops `balnexa_audit_owner`.

## 3. Decisions taken under the delegation — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-G0R-1 | F-01 is fixed by separating ownership (its own role and schema), not by triggers | A table owner can disable any trigger. Event triggers need a superuser, which a Neon installer is not. Moving ownership away from the path is the only control that holds against it |
| D-G0R-2 | The table moves to its own schema `bnx_audit` | A schema owner may drop any table in its schema, including one it does not own. Tested: with the table still in `bnx`, `DROP TABLE` by `bnx_definer` succeeded |
| D-G0R-3 | The role is named `balnexa_audit_owner`, outside the `bnx_` prefix | Roles are cluster-wide. The immutable audits of 9002–9010 count exactly nine `bnx_*` roles, so a second database installed in the same cluster would fail (observed: 29 suite failures with the name `bnx_audit_owner`). The 9011 audit names the role explicitly |
| D-G0R-4 | `bnx.audit_event` stays as a view owned by `bnx_definer`; the chain functions use the table | Readers and the R1 functions keep working, including between B003 and 9011. The view can be redefined by the owner path, the table cannot, so the chain functions do not rely on the view |
| D-G0R-5 | G0R lives in migration 9011, not in a new migration | Versions 9012–9016 are reserved for planned work packages (disposition register), and 9011 is neither merged nor applied anywhere. A separate later number would break the runner's prefix rule when the reserved versions arrive |
| D-G0R-6 | Install order: B001 → B002 → runner (stops before 9011, exit 6) → B003 → runner | B003 needs the audit table, which 0106 creates. The runner fails closed and says exactly what to run |
| D-G0R-7 | F-04: envelope values are printable ASCII only | This is locale-independent. Trade-off: a client that sends non-ASCII text in `host_profile`, `tool_name`, `tool_version` or `trace_id` now gets `VALIDATION_FAILED`. The Worker sets none of these fields |
| D-G0R-8 | F-02, F-03 and F-05 are documentation-only; merged bootstraps B001 and B002 are not edited | They are history; the early check sits in B003 instead |
| D-G0R-9 | The external verifier is part of the control, not a test helper | `audit_verify()` and `audit_privileges()` are functions the owner path could replace. A check that uses only built-ins and catalogs, from a read-only role, cannot be faked that way |

## 4. Residual risks after G0R

| ID | Residual | Detection or handling |
|---|---|---|
| R-1 | A superuser can still delete or rewrite audit rows (V8.6, X2) | Detected by `audit_chain_verify.py --anchor` once an anchor of (seq, head hash) has been recorded elsewhere (9016 backup header, vault manifest). Without an anchor it remains undetected |
| R-2 | The owner path can replace function bodies (`audit()`, `audit_verify()`, `audit_privileges()`, trigger functions), so later events could go unrecorded or in-database checks could report falsely | This is the migration channel's nature: it changes code. Controls are migration review, the checksummed migration ledger, and the external verifier, which checks catalog facts and the chain without calling `bnx` code. Rows already recorded cannot be removed or altered by this path |
| R-3 | The owner path can append events, including correctly hashed false ones | Equivalent to calling `bnx.audit()`, which the path can do anyway. It cannot hide or change earlier events |
| R-4 | The installer can grant itself SET on `balnexa_audit_owner` (F-07 class) | Reported by `audit_privileges()` (runner exit 7) and by the external verifier (`AUDIT_OWNER_MEMBER`) |
| R-5 | A second, different non-superuser installer in the same cluster cannot run B003, because it lacks ADMIN on the existing role | Fails closed with a permission error. One installer per cluster is the documented setup |

## 5. Test results — `AUTHOR_RUNTIME_EVIDENCE`

Local runs, PG16.15 and PG17.11, with G0R in place:

| Suite | PG16 | PG17 |
|---|---|---|
| R1 `run_g0.py` (AT-BAK-01 now dumps and restores `bnx_audit`) | 40/0/0 | 38/0/2 (no local pg_dump 17; CI runs both) |
| `run_s4_core1`…`core6` | 12, 12, 9, 11, 8, 8, all PASS | same |
| `run_s4_core7` (new, AT-G0R-01…05) | 5/0/0 | 5/0/0 |
| Black-box API | 8/8 | 8/8 |
| Dispatch simulation | exit 0 | |

Reproduction before the fix (baseline `ee13eee` plus the 9011c branch): through the owner path, `TRUNCATE bnx.audit_event` committed, the row count went from 12 to 0, and `audit_verify()` returned 0. This is the same as the G0 report's X3.

## 6. G0 re-run

The baseline is `main` after PR #5 is merged. G0R has to be verified there, by a separate session, on **both** majors.
These errata apply to `Balnexa_S4_G0_Independent_Verification_Plan_Rev1.md`:

| ID | Plan item | Erratum |
|---|---|---|
| E-1 | S0 | The installer name must not start with `bnx_` (for example `g0_installer`) |
| E-2 | S1–S5 | The order is B001 → B002 → runner (expected: exit 6, `BOOTSTRAP_MISSING` naming B003, head 9010) → B003 (same PGOPTIONS as B002) → runner (exit 0, 0 violations) |
| E-3 | V3.12a | Expected: exit **6** at 0108 (the in-migration audit), not 7 |
| E-4 | V8.4, X3 | Target `bnx_audit.audit_event`. Expected: every owner-path TRUNCATE, DISABLE TRIGGER, DELETE, UPDATE, DROP, RENAME and ownership change is refused; INSERT still works |
| E-5 | V8.6, X2 | Remain `KNOWN_RESIDUAL` without an anchor. Additional check X4: with `tools/s4/audit_chain_verify.py --anchor <seq>:<hash>` taken before the tamper, both are detected (exit 1) |
| E-6 | V4.1, V5.1 | Ten roles: `balnexa_audit_owner` is NOLOGIN with connection limit 0, has no attributes, and the installer is its only member (ADMIN only). The expected relation owner is the registered schema owner: `bnx_audit` → `balnexa_audit_owner` |
| E-7 | V8.7 | U+200B and other non-ASCII characters are now refused (F-04) |
| E-8 | V9.1–V9.5 | The backup scope is `--schema=bnx --schema=bnx_audit --schema=auth`. The restore loads `bnx_audit` data as `bnx_migrator` under `SET ROLE bnx_definer` (INSERT is enough) |
| E-9 | DEV-04 cluster resets | Drop `balnexa_audit_owner` together with the `bnx_*` roles |
| E-10 | Environment | PostgreSQL 17 must be available to the verifier (§7) |

## 7. Items for the Owner

1. **F-01 grade (requested by the verifier): P0 or P1.**
   - Recommendation: **P1**. The path needed the migrator credential, which is installer-side and is not used by any runtime role.
   - Either way it is fixed before the re-run.
2. **PostgreSQL 17 for the re-run.**
   - The verifier's environment refused `apt.postgresql.org` (HTTP 403).
   - Options:
     - (a) allow `apt.postgresql.org` and `www.postgresql.org` in that environment's network settings (preferred: PGDG packages as the plan requires);
     - (b) approve installing PostgreSQL 17 from conda-forge in that session.
   - Without one of these, PG17 stays `NOT_VERIFIED` and G0 cannot close.
3. **DEV-13:** confirm that a session created with Opus 5.5 and served by Sonnet 5.5 satisfies D1 as amended. For the re-run, select Sonnet 5.5 when the session is created.
4. **Role model:**
   - The product now has ten roles: nine `bnx_*` roles plus `balnexa_audit_owner`.
   - It also has eight registered schemas: `bnx_audit` is new.
   - This changes CROSS-01's "nine roles / seven schemas".

### 7.1 Owner decisions, 2026-11-11 06:59 America/Toronto — `OWNER_DECISION`

The Owner replied "同意" ("agreed") to the items above. Claude recorded it as follows and told the Owner so, with an
invitation to correct it:

| Item | Decision |
|---|---|
| 1 | F-01 is graded **P1** |
| 3 | DEV-13 is accepted: a session configured for Opus 5.5 and served by Sonnet 5.5 counts as a Sonnet 5.5 session under D1 as amended. The re-run selects Sonnet 5.5 when the session is created |
| 4 | The role model change is accepted: nine `bnx_*` roles plus `balnexa_audit_owner`, and eight registered schemas including `bnx_audit` |
| 2 | Open. The Owner received no request, because the agent proxy refuses with HTTP 403 and shows no prompt. Claude sent the steps to the Owner: in the re-run session's cloud environment, set **Network access** to **Custom**, allow `apt.postgresql.org` and `www.postgresql.org`, and keep the default package-manager list. Source: code.claude.com/docs/en/cloud-environments |

