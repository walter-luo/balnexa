# Balnexa (账知家) — S4 Design and Development Compendium, as built — 2026-11-12

**Status:** `DRAFT — AI-generated`. It becomes authoritative only once the Owner confirms it (Authority Order: human-confirmed content outranks AI drafts).

**Code basis:** repository `walter-luo/balnexa`:
- `main` = `fff6db5`;
- the open stack of draft PRs #9 → #15, top branch `s4/aih-r` @ `6571164`;
- this handoff set lives on `s4/handoff`.

**Design basis:** S4 Unified Architecture V1.2 (`Balnexa_S4_Unified_Architecture_V1.2.zip`, SHA-256 `0f4bc6b71bd2024d044708002d39d0a25fe546ed657c05db24161f1e140c6b3f`; Owner-private, not in the repository). It is read together with the Owner Requirements Book V1.2 and Amendments 02/03.

**Evidence grade of everything described as built:** `AUTHOR_RUNTIME_EVIDENCE` plus green CI. Two parts were also reviewed by an independent agent of the same model family (`SAME_FAMILY_VERIFICATION`): 9011 (review 9011R) and AIH-1/2/4 (review RV-AIH). **No component is deployed.** No gate (G0, G2, M0, AIHOST-QUAL, G-CRA-1) is claimed passed.

## Companion documents

| # | Document | Purpose |
|---|---|---|
| 01 | this compendium | What the system is and how it is built (updated overall design and development record) |
| 02 | `02_Balnexa_S4_Status_and_Plan_2026-11-12.md` | Current status per work package, gates, and the plan to completion and go-live |
| 03 | `03_Balnexa_S4_Platform_Handoff_2026-11-12.md` | Everything needed to continue on another platform: environment, conventions, sources and first steps |

---

## 1. What Balnexa is

Balnexa is a bilingual (EN/中文) household finance system with these properties:

- **Independent instances.** One codebase; every household gets its own PostgreSQL database, file storage and Gateway (UA §4).
- **Deterministic core.** Double-entry ledger, versioned reads, replayable report snapshots, and an append-only, hash-chained audit trail. Every rule that matters is enforced **inside PostgreSQL** through `SECURITY DEFINER` functions (UA §5–§6).
- **Usable without AI.** The PWA covers every function. AI hosts (Claude, ChatGPT) are optional clients through OAuth 2.1 and MCP. They may read and draft, but **never post or approve** (C-04).
- **Synthetic data only** until the Owner opens gate O-8.

## 2. Component map (as built)

```
 Browser (PWA, /app/)          AI hosts (Claude / ChatGPT)            Executor (Python 3.12, bnx_exec)
        │ session cookie              │ OAuth 2.1 bearer (resource-bound)        │ lease (Google ID token)
        ▼                             ▼                                          ▼
 ┌──────────────────────── Gateway: Cloudflare Worker (apps/worker) ─────────────────────────────┐
 │ binding checks B1/B2/B3/B8 (fail closed) · catalog dispatch + JSON-Schema validation           │
 │ REST /api/v1 · OAuth AS/RS (oauth.js) · MCP server (mcp.js) + card (card.js) · lease API      │
 │ artifact proxy · R2 presign · dispatcher tick · SIN guards C3/C4 · idempotency normalization   │
 └───────────────────────────────┬───────────────────────────────────────────────────────────────┘
                                 │ one connection role per caller class: bnx_app / bnx_authn / bnx_worker
                                 ▼
 ┌──────────────── Finance Core: PostgreSQL 16/17 (db/) ─────────────────────────────────────────┐
 │ bnx (ledger, accounts, plans, reports, OAuth, catalog comments) · bnx_audit (chain v2)         │
 │ bnx_intake · bnx_doc · bnx_backup · … · nine roles, prefix grants, privilege audit             │
 └────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- Deployment targets (`M0_PENDING`): Workers + static assets, Neon PostgreSQL, Cloud Run Jobs for the Executor, R2/GCS, Google Drive.
- Locally, everything runs through the node adapter `apps/worker/node/adapter.mjs`, with KV, R2 and assets mocks, against local PG16/PG17 clusters.

## 3. Repository layout

| Path | Content |
|---|---|
| `db/bootstrap/` | `B001_bootstrap.sql` (R1 roles and schemas), `B002_bootstrap_s4.sql` (S4 roles and schemas; asserted by 9002), `B003_audit_owner.sql` |
| `db/migrations/` | Core lane `0002–0109` (R1, frozen) and extension lane `9001–9023` (S4); see Appendix A |
| `db/tools/run_migrations.py` | Two-lane runner. Within a lane, the applied versions must be a prefix of the ordered file list, with SHA-256 checks. Re-runs `apply_grants()` and `audit_privileges()`. |
| `db/catalog/bnx-tools-1.0.overrides.json` | Overrides for the generated catalog: names, descriptions, tier helpers, `ui_cards` |
| `apps/worker/` | Gateway: `src/index.js` (routes), `oauth.js`, `mcp.js`, `card.js`, `binding.js`, `schema.js`, `dispatch.js`, `jwt.js`, `r2presign.js`, `exec_schemas.js`, `sin_detector.js`, `http.js`, `release.js`; `node/adapter.mjs` (local runtime) |
| `apps/executor/bnx_exec/` | Executor: `runner.py`, `gateway.py` (lease client), `jobs.py`, `render.py`, `restore.py`, `pgtools.py`, `agecli.py`, `store.py`, `hashing.py`, `doc_validator.py`, `sin_detector.py` |
| `apps/pwa/public/app/` | PWA: `index.html`, `app.css`, `sw.js`, `menu.json`, `i18n/{en,zh-Hans}.json`, `js/{main,api,render,i18n}.js` |
| `spec/sin-detector/` | SIN/ITN detector specification v1.1.0 (Python, JS and SQL implementations must agree) |
| `tools/s4/` | `catalog_build.py`, `sin_repo_scan.py` (guard C6), `audit_chain_verify.py`, `gen_registry_seed_sql.py`, `gen_sin_detector_spec.py` |
| `tests/py/` | `harness.py` (PG DSNs, `drop_all`), `run_g0.py` (R1 suite), `run_s4_core1…17.py`, `run_s4_core_9011r.py`, helper scripts |
| `tests/blackbox/` | `api.test.mjs` (HTTP against the Worker plus real PG), `unit.test.mjs`, `prepare_db.py` |
| `tests/pwa/` | `pwa.test.mjs` (Playwright 1.63.0 + axe-core 4.13.0), `harness.mjs` |
| `tests/sim/` | `dispatch_sim.mjs` (dispatcher simulation) |
| `docs/s4/` | One implementation-notes file per stage (decisions and limits), remediation records, reviews, Owner decisions, this handoff set |
| `.github/workflows/ci.yml` | CI: secret scan (owner_sources path check, SIN scan, gitleaks) and db-tests on PG16 and PG17 (all suites, black box, PWA, simulator) |

## 4. Finance Core (PostgreSQL)

### 4.1 Roles, schemas, privileges

- **Nine roles** (UA §6.1, CROSS-01). The R1 roles are:

  | Role | Purpose |
  |---|---|
  | `bnx_definer` | owns schemas and functions |
  | `bnx_app` | member and AI calls via the Gateway |
  | `bnx_worker` | Worker steps |
  | `bnx_authn` | unauthenticated OAuth and sign-in steps |
  | `bnx_auth` | owns schema `auth` |
  | `bnx_migrator` | runs migrations |
  | `bnx_backup` | backups |

  S4 adds `bnx_stager` (`stg_*` only) and `bnx_fed_reader` (NOLOGIN until federation). B003 adds the separate audit-chain owner `balnexa_audit_owner` (schema `bnx_audit`).
- **Schemas:**

  | Source | Schemas |
  |---|---|
  | B001 | `bnx`, `bnx_rpt`, `auth` |
  | B002 | `bnx_doc`, `bnx_intake`, `bnx_tax`, `bnx_fed` |
  | B003 | `bnx_audit` |

- **Grants by name prefix,** in `bnx.apply_grants()` (9002 MODIFY, later extended):

  | Prefix | Granted to |
  |---|---|
  | `q_`, `cmd_` | `bnx_app` |
  | `wrk_` | `bnx_worker` |
  | `authn_` | `bnx_authn` |
  | `stg_` | `bnx_stager` |
  | `fed_` | `bnx_fed_reader` |
  | `bkp_` | `bnx_backup` (SECURITY INVOKER only) |

  Every migration ends with `select bnx.apply_grants();`. `bnx.audit_privileges()` machine-checks the result: no PUBLIC execute, installer membership rules, schema USAGE.
- **Definer rules D1–D10:** schema-qualified names, `set search_path = pg_catalog, pg_temp`, no dynamic SQL from input.

### 4.2 Migration lanes

- `run_migrations.py` has two lanes: core (`0001–8999`) and extension (`9000–9999`).
- Applied versions must be a prefix of each lane's ordered file list, so a missing number blocks later files on a persistent instance. **9014 (Tax Core) and 9015 (federation) are not present while 9016+ are (L-9016-8).** No persistent instance may be installed until 9014/9015 exist or are renumbered as documented no-op reservations.
- Committed migrations are **never edited** (D-CORE9-2). Changes are `create or replace` MODIFYs in a new migration, marked line by line with the migration number.

### 4.3 Command core and actor resolution

- Every member- or AI-facing operation is one call, `bnx.cmd_<name>(cred jsonb, cmd jsonb)` or `bnx.q_<name>(cred, q)`. Worker steps are `bnx.wrk_*`.
- **Actor resolution** is `bnx.resolve_actor(cred)`, last modified in 9021:
  - **Session credentials:** 30-day idle and absolute expiry.
  - **Bearer credentials:** connection and token checks, and B7 audience (token `resource` = Gateway audience).
  - **Envelope:** values (`tool_name`, `tool_version`, `trace_id`) are validated and set as GUCs for audit provenance. On bearer calls `host_profile` comes from the connection.
- **`bnx.require(actor, tier)`:**

  | Tier | Who | Notes |
  |---|---|---|
  | 0 | read | |
  | 1 | draft | |
  | 2 | post | |
  | 3 | admin | |

  - Roles: viewer 1, member 2, owner/admin 3.
  - The mcp channel is allowed only for functions listed in `bnx.function_scope`, with the consented scope and the account-currency subset; legacy `read`/`propose` scopes are mapped per CROSS-02.
- **Idempotency:** `idem_begin`/`idem_end`, keys of 8–80 characters. The Gateway normalizes every client key to `gk-` plus 32 letters derived from SHA-256 (D-CORE10-3, RV-AIH-05).

### 4.4 Ledger, plans, approvals (CORE-4, 9008/9010)

- **Two posting paths.** Direct posting (`cmd_post_transaction`, members with `can_post`, PWA only), or draft → plan → Owner Gate.
- **Plan kinds** (9004): `import`, `onboarding_scope`, `reclassification`, `account_merge_repost`, `ai_draft`, `handoff`, `onboarding`, `member_draft`, `migration_replay`. `manual` is refused.
- **Validation and approval:** intake validations V-01…V-10, approval holds, exact-version approval (`plan_hash`, `scope_digest`).
- **Posting:** `wrk_post_plan_chunk` posts in chunks, and `wrk_activate_plan` activates the whole plan at one version.
- **Economic-type rules** (`bnx.economic_type_rule`, 26 types, B6.1 line patterns) decide which lines may be posted.

### 4.5 Accounts, registry, flags (CORE-2/3, 9006/9007)

- **Institution registry:** Amendment 02 seed (generated SQL; the seed JSON is not committed); `account_institution_event`; account fingerprints made by an HMAC in the Worker.
- **Region scope** on accounts. Module flags (`Canada`, `International`, `CRA`) are enforced per table and operation by `flag_enforcement_point` triggers; `UNKNOWN` is always refused.
- **Instance identity and configuration lifecycle** (9003): `NONE → PENDING_OWNER_ACCEPTANCE → PENDING_DEPLOY → ACTIVE`; activation is installer-only.

### 4.6 Observations, reconciliation, FX, cards, loans (CORE-5, 9012)

- Balance observations as side-table events.
- Reconciliation and matching MR-08…13.
- Imports and onboarding.
- FX with `fx_rate_at`, valuation, lots, card fee policies.
- Loans with `q_r28_loan_position`, using explicit HALF_EVEN rounding.

### 4.7 Reports and snapshots (CORE-6, 9013)

- Report families F1–F7, R09 cash flow and R28. `report_definition` is versioned.
- Snapshots: `report_snapshot` is untouched; artifacts go in the side table `report_snapshot_artifact`. `q_snapshot_status` returns CURRENT, STALE or ACCESS_REVOKED.
- The report envelope is `rpt_envelope`.
- The Executor renders the HTML artifact (CORE-8, 9018). The Gateway proxies it after a SHA-256 check.

### 4.8 Documents, evidence, SIN guards (WP-DOC partial, 9011)

- **SIN/ITN detector v1.1.0** (`spec/sin-detector/`). The same rules exist in Python, JS and SQL.
- **The guards:**

  | Guard | Where | What it does |
  |---|---|---|
  | C1 | detector | detection |
  | C2 | `bnx.audit` | refuses any audited payload or subject containing a Luhn-valid 9-digit run |
  | C3 | Worker | log scrubbing |
  | C4 | AI-host results | refusal on `/mcp` and on `/api` for bearers, audited by rule code only |
  | C6 | repository and history | scan with `tools/s4/sin_repo_scan.py` |

- Document intake states, redaction queue, renditions, and the Executor document validator (`doc_validator.py`, 9011c).
- **Never store or display a SIN or another government identifier.** Tests build such values at run time only.

### 4.9 Audit chain v2 (9005)

- Hash-chained `bnx_audit.audit_event`: v1 rows keep the R1 encoding.
- Each event stores the command, subject, payload SHA-256 (never the payload), ledger and chain version, channel, and host provenance.
- `tools/s4/audit_chain_verify.py` verifies the chain offline.
- `q_audit_trail` (9020, PWA only): the Owner and admins see the household; others see only their own events.

### 4.10 Intake, Executor lease and staging (INT-1, 9010; CORE-8, 9018)

- `bnx_intake`: unified queue, exceptions, unassigned register, notifications, shared-index and mail intake records.
- **Executor lease protocol** (`bnx.exec_lease`): pinned identity, nonce, 20-minute TTL. The work order is returned with the lease (9018). Results are staged through `stg_*` and promoted only by the Worker tick (`wrk_promote_staged`).
- **Job kinds:**

  | Kind | What it does |
  |---|---|
  | `REPORT_RENDER` | renders the report artifact |
  | `BACKUP` | UA §9.3: `pg_dump --snapshot`, `age` to the K2 recipients, signed header |
  | `RESTORE_DRILL` | restores a backup as a drill |
  | `EVIDENCE_VERIFY` | verifies evidence objects |

### 4.11 Backup, DR, cloud usage (9016)

- Registries: backup, key fingerprints (K2), drill runs, and cloud usage with admission.
- Restore-preamble generator.
- `bnx_backup` may execute only `bkp_*` SECURITY INVOKER functions.

### 4.12 Catalog bnx-tools/1.0 (CORE-7, 9017 + delta blocks)

- Every `q_`/`cmd_` function carries a JSON catalog entry in `COMMENT ON FUNCTION`: name, channels, risk class, tier, scopes, `input_schema`, idempotency, MCP hints, `ui_resource`.
- The entries are generated by `tools/s4/catalog_build.py` from `pg_proc`, `function_scope` and the overrides.
- The 9017 base block has 113 entries; later migrations carry **delta blocks** (9019, 9020, 9021, 9022), for 116 entries in total.
- `--check` compares the merged blocks with the derivation. `--write` writes only into the newest migration, which must carry markers.
- The Gateway loads the catalog through `wrk_catalog`. Uncatalogued `q_`/`cmd_` functions fail binding.

## 5. Gateway (Cloudflare Worker)

| Area | Behaviour |
|---|---|
| Binding checks | B1 identity, B2 deployable digest, B3 schema range (`release.js` `supports_schema`; currently extension 9022…9023), B8 module flags. Any mismatch → 503 on every route except health and static PWA assets (ISO-4, fail closed). |
| REST | `POST /api/v1/commands|queries/{name}`, dispatched schema-qualified from the catalog with JSON-Schema validation. Commands require the same origin (session). Key normalization. `approve_ai_connection` is refused on this route (`USE_OAUTH_AUTHORIZE`, RV-AIH-01). C4 applies for bearers. `queue_generation` is kept as a KV hint. |
| Sessions | Google ID-token sign-in (`jwt.js` with JWKS `kid` rotation). HttpOnly SameSite=Strict cookie. Logout revokes the session. |
| Lease API | `POST /exec/v1/lease` and `/exec/v1/complete`. Completion schemas per job kind (`exec_schemas.js`). The 256 KiB limit is enforced in the Executor (`check_size`). |
| Artifacts | `GET /api/v1/artifacts/{snapshot_id}`, with a SHA-256 check (502 `ARTIFACT_INTEGRITY`). |
| Uploads | `POST /api/v1/uploads` returns a presigned R2 PUT (SigV4). Needs R2, which is gate O-7. |
| Dispatcher | R1 algorithm. Unknown kinds are left queued with backoff, never lost (AT-Q-02). |
| OAuth (AIH-1) | RFC 8414 / RFC 9728 metadata. Two resources, `<instance>/mcp` and `<instance>/api`, with a per-surface B7 audience. DCR (public clients; host profile inferred by the Core; 10 per address per day; name and body rules). Allowlisted CIMD. `GET /oauth/authorize` → PWA `#/consent`; `POST` for describe, deny or approve. Token response returns the granted `scope`. RFC 7009 revoke. |
| MCP (AIH-2/4) | Stateless Streamable HTTP. Tools = mcp-channel RC-READ/RC-DRAFT catalog entries covered by the consent; names use `.`→`_`. Command tools require `idempotency_key`. Results are byte-identical to REST; errors carry the REST code. 401 with the RFC 9728 challenge. TR-01…14 instructions. One resource, the display-only card `ui://balnexa/cards/v1`; draft results also carry a sealed PWA link as text. |
| Static PWA | `/app/*` from the ASSETS binding with a strict CSP (self plus Google Identity Services on sign-in only). |

## 6. Executor (Python 3.12)

- Runs as `python -m bnx_exec run --kind KIND [--item ID …]`.
- The environment variables are listed in `runner.Config`.
- Behaviour: SIGTERM-safe job loop; exit codes 0, 2, 3 and 4; local object store only.
- Not yet built:
  - container images and the Cloud Run launch (M0-A);
  - GCS/R2 stores (M0-B/E);
  - document, import, index, mail and T1 handlers (WP-DOC, INT, TAX).

## 7. PWA

- **Code:** plain ES modules; hash router.
- **Renderers and screens:** three generic renderers (form, table, detail) drive every catalog task. The dedicated screens are:
  - Home, Quick Entry, Activity (list and calendar), Transaction, Review, Draft Confirm (sealed link `#/confirm/<plan>?h=<plan_hash>&s=<scope_digest>`), Reports, Menu, Task, Settings;
  - Handoff (status, prepare, import);
  - AI-host consent (`#/consent`) and AI connections (`#/connections`).
- **Menu:** the closed menu (items 1–8 plus Settings) comes from `menu.json`. It is filtered by the live catalog and the caller's tier. `reached_elsewhere` declares catalog entries reached by a dedicated route.
- **Platform features:** EN/中文 catalogs with identical keys; accessibility (axe clean, skip link, focus management); an offline shell that caches the shell only; idempotency keys made of letters only.

## 8. AI-host integration (AIH-1/2/4)

1. **Discovery:** the host reads `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-authorization-server`.
2. **Registration:** the host registers by DCR, or uses a CIMD client id.
3. **Authorization:** `GET /oauth/authorize` checks the client and redirect, then hands over to the PWA consent screen. There the Owner sees:
   - the verified host;
   - the scopes, with read scopes ticked and draft scopes unticked;
   - the account-currencies, none ticked;
   - the outbound disclosure.
4. **Approval:** this creates a resource-bound connection (`cmd_approve_ai_connection`). The code goes back to the host, which redeems it with PKCE S256 for an access token, plus a refresh token if `offline_access` was granted.
5. **MCP calls:** the token is checked live on every request. Tool calls go to the catalog functions. Audit provenance records host profile, tool name and version, and trace id.
6. **Drafts:** a draft shows as a display-only card with a sealed link, or as a text link. Approval happens **only in the PWA**.
7. **Revocation:** in Settings → AI connections, or by RFC 7009. It takes effect on the next request.

**Qualification status:** none of this has been run against a real host. AIH-5 (PV-AIH, PV-UI) needs the Owner's PoC authorization.

## 9. Security invariants (summary)

- The Gateway is the only holder of `bnx_app`, `bnx_authn` and `bnx_worker`. The Executor never holds `bnx_worker`.
- AI channel:
  - RC-READ and RC-DRAFT only; never post, approve, declare or administer;
  - the consented scope plus the account-currency subset, enforced in the database;
  - a token is bound to one surface and one instance.
- No SIN or government ID in storage, logs, AI results, tests or the repository (guards C1–C6). The CI secret scan blocks history with `owner_sources` paths.
- Append-only facts. Corrections are new events. The audit chain is hash-linked and checked offline.
- Every external effect (send, post to a peer, cloud action) needs a human step: handoff prompts are copied by the user; the AI never sends.

## 10. Testing architecture

| Layer | Suite | Count at `6571164` (PG16 / PG17) |
|---|---|---|
| R1 frozen | `tests/py/run_g0.py` | 40 / 38 + 2 local skips (no PG17 `pg_dump` locally; run in CI) |
| S4 database | `run_s4_core1…17.py`, `run_s4_core_9011r.py` (18 files) | 139 / 138 + 1 local skip |
| Total database | — | **179 / 176 + 3 skips** locally; **179 / 179** in CI |
| HTTP black box + unit | `tests/blackbox/api.test.mjs`, `unit.test.mjs` | 32 |
| PWA headless | `tests/pwa/pwa.test.mjs` (Playwright, axe, every AI route and other host blocked) | 19 |
| Simulator | `tests/sim/dispatch_sim.mjs` | PASS |

- The harness expects PG16 at socket `/var/lib/postgresql/bnx16`, port 55416, and PG17 at `/var/lib/postgresql/bnx17`, port 55417.
- Suites call `drop_all`, and roles are cluster-global, so **never run two suites at once**.

## 11. Development process used

- **One stage per work-package item.** Each stage delivers:
  - a migration (when the database changes);
  - a `tests/py/run_s4_coreNN.py` suite and/or black-box/PWA tests;
  - `docs/s4/S4_<stage>_Implementation_Notes.md`, with "What was built", decisions `D-<stage>-n` (`DELEGATED_DECISION` when taken under Owner delegation), tests and limits `L-<stage>-n` with follow-ups;
  - a stacked branch `s4/<stage>` and a draft PR whose body carries the regression and CI results.
- **Before each push:** a full local regression on PG16 and PG17, `gitleaks git`, and `sin_repo_scan.py --all-history`.
- **Merges:** the Owner merges, in stack order, retargeting each PR to `main`.
- **Independent reviews** (TST-6, `SAME_FAMILY_VERIFICATION`): a fresh agent with a written prompt (`docs/s4/reviews/*_PROMPT.md`), read-only. Findings are fixed forward with a remediation record.

## 12. Deviations from the V1.2 design text (all recorded as decisions)

| Topic | V1.2 text | As built | Decision |
|---|---|---|---|
| Migration register | exactly 9002–9016 | plus 9017–9023 (Gateway catalog, Executor work orders, PWA ledger query, audit trail, AI-host OAuth, card catalog, review fixes) | D-CORE7-1, D-CORE8-1, D-CORE9-1, D-CORE10-1, D-AIH-1, D-AIH4-1, D-AIHR-1 (register rows owed) |
| Catalog storage | catalog in function comments | plus per-migration delta blocks | D-CORE9-2 |
| OAuth resource | single `resource` (CORE-7 `BNX_RESOURCE`) | two resources per instance (`/mcp`, `/api`); `BNX_RESOURCE` retired | D-AIH-3 |
| MCP tool names | catalog names with dots | `.` → `_`; catalog name is the title | D-AIH-4 |
| Consentable scopes | all catalog scopes | `finance.read`, `finance.draft`, `reports.read`, `handoff.read`, `handoff.prepare`, `offline_access` (documents/tax not yet) | D-AIH-6 |
| Mode H seal | HMAC with `HANDOFF_SEAL_KEY` | version pair (`plan_hash`, `scope_digest`); approval is always of the server's version | D-CORE9-7, D-AIH4-2 |
| OD-41 in-card editing | allowed (revisions) | display-only card | D-AIH4-3 |
| Idempotency keys | R1 8–80 characters stored | normalized at the Gateway (`gk-` + letters); malformed keys refused | D-CORE10-3, RV-AIH-05 |
| AI consent path | `cmd_approve_ai_connection` | only through `POST /oauth/authorize` (the generic route refuses it) | D-AIHR-2 |

The appendices below are generated from the repository at `s4/handoff`.

---

## Appendix A — Migrations (generated)

| File | Lane | Where | SHA-256 (12) | Header (first lines) |
|---|---|---|---|---|
| `0002_reference_and_accounts.sql` | core | R1 baseline (main) | `705660726d0a` | 0002 Reference data, members, parties, accounts, current authorization, versioned account and ownership facts. |
| `0003_ledger.sql` | core | R1 baseline (main) | `0da834f92271` | 0003 Ledger: plans, batches, journals, confirmations, anchors, scope claims, snapshots, versioned reference facts. |
| `0004_evidence.sql` | core | R1 baseline (main) | `f0fe79fa984d` | 0004 Evidence objects, acquisitions, explicit access, archive protection (AUD-030, AUD-041, AUD-042). |
| `0005_matching.sql` | core | R1 baseline (main) | `b69a31fe480c` | 0005 Source transactions, links and match decisions (append-only; §C4.9, INV-19, INV-44). |
| `0006_version_aware_readers.sql` | core | R1 baseline (main) | `f4626897b7cf` | 0006 Version-aware readers (§B2a.3), ownership at (date, version) (AUD-039), live authorization (AUD-041), snapshot replay access (AUD-040). All SECURITY DEFINER, search_path pg_catalog,pg_temp, schema-qualified (rule D1/D2). |
| `0101_grants_r1.sql` | core | R1 baseline (main) | `6e215cac6626` | 0101 Grants (successor of Draft-04 0007, which needed RESET ROLE and superuser-level schema grants). Runs entirely as bnx_definer. Schema usage and backup default privileges are established by B001. |
| `0102_journal_completeness.sql` | core | R1 baseline (main) | `f9a2d524ad6f` | 0102 AUD-044 Journal completeness at COMMIT (INV-01, INV-02, INV-03, INV-04, INV-07, INV-08). A journal header without lines, a single line, same-sign lines, a currency group without both a debit and a credit, a non-zero currency… |
| `0103_currency_integrity.sql` | core | R1 baseline (main) | `623df431fc8c` | 0103 AUD-045 Currency identity and precision across linked financial objects. |
| `0104_ownership_determinism.sql` | core | R1 baseline (main) | `958d7443f7c6` | 0104 AUD-052 Deterministic bitemporal ownership/scope resolution; share totals enforced in the database. |
| `0105_source_link_events.sql` | core | R1 baseline (main) | `0c0ae8e1bcc6` | 0105 AUD-054 Source-link history with immutable event identity and an enforced state machine. The Draft-04 table keyed (source_txn_id, journal_id, event) could not record reserved→released→reserved. |
| `0106_command_core.sql` | core | R1 baseline (main) | `413621fb8e68` | 0106 AUD-053 Command Core vertical slice (milestone M0 prototype scope). Every member-facing write is ONE call bnx.cmd_<name>(cred jsonb, cmd jsonb) executed by bnx_app; worker steps are bnx.wrk_* executed by bnx_worker; identity… |
| `0107_snapshot_authz.sql` | core | R1 baseline (main) | `c60c02c0ba66` | 0107 AUD-051 Snapshot replay authorization bound to the creating audience (member + channel/connection), active membership, requested scope and current visibility. Uniform NOT_AVAILABLE for unknown snapshots and for snapshots of… |
| `0108_grants_and_privilege_audit.sql` | core | R1 baseline (main) | `4615ba8de2bf` | 0108 Worker revalidation step (AUD-053/INV-43), prefix-based EXECUTE grants, and the machine-checked privilege audit (AUD-049/AUD-050). bnx.apply_grants() and bnx.audit_privileges() are re-run by the migration runner after every… |
| `0109_archive_integrity_and_dual_copy_gate.sql` | core | R1 baseline (main) | `82ace89c511b` | 0109 AUD-047 / AUD-042: no silent dual_verified, and an optional fail-closed approval gate. * evidence_object.archive_state may become 'dual_verified' only when the object is integrity-verified (executor SHA-256 present) and an a… |
| `9001_import_draft02_logical_state.sql` | extension | R1 baseline (main) | `48ef95fc6967` | 9001 One-time conversion of a Draft-02 logical state (schema d02) into Draft-04 tables. Applied only if d02 exists. Mapping: each historical anchor revision becomes an opening_anchor_version with valid_from_version taken from the… |
| `9002_s4_bootstrap_assert_and_privileges.sql` | extension | PR #1 (merged) | `ce2edae8df2e` | 9002 S4 bootstrap assertion and privilege model for nine roles and seven schemas (V1.2 UA §6.1–§6.3; OBJ-383; CROSS-01; S4B-F01/F10/F17). MODIFY bnx.apply_grants() and bnx.audit_privileges() (same signatures, OBJ MODIFY rows); NE… |
| `9003_s4_identity_config_release.sql` | extension | PR #1 (merged) | `87d451c602c0` | 9003 Instance identity, configuration anchor and lifecycle, module flags, release/install events (V1.2 UA §4.2-§4.3, AE §5; OBJ-019, OBJ-378/379/380; CROSS-04, CROSS-05, S4B-F18). Lifecycle: NONE -> PENDING_OWNER_ACCEPTANCE -> PE… |
| `9004_s4_constraint_replacements.sql` | extension | PR #1 (merged) | `bf22de72ad93` | 9004 Constraint replacements (V1.2 UA §6.3 rule: ADD CONSTRAINT ... NOT VALID -> VALIDATE -> DROP old; OBJ-384, OBJ-367, OBJ-225; CROSS-03, S4B-F03, S4B-F14). No R1 object is dropped except the replaced CHECK constraints themselv… |
| `9005_s4_audit_chain_v2.sql` | extension | PR #2 (merged) | `c7cd02f96869` | 9005 Audit chain v2 (V1.2 UA §5.10; OBJ-020; S4B-F08). MODIFY bnx.audit(), bnx.audit_verify(), bnx.resolve_actor() (same signatures; bnx.actor composite unchanged). v1 rows (seq < first v2 seq) keep the R1 concat_ws encoding and… |
| `9006_s4_registry_policy_accounts.sql` | extension | PR #2 (merged) | `baab56222f16` | 9006 Reference data, institution registry, financial policy, account identity (V1.2 UA §5.4; OBJ-021, OBJ-372; S4B-F05, RR-02; Amendment 02). Data migration of existing free-text institutions runs inside this one transaction: nam… |
| `9007_s4_module_flag_enforcement.sql` | extension | PR #2 (merged) | `db50e24f8d8a` | 9007 Module-flag enforcement (V1.2 UA §4.4, §4.4.1; OBJ-385; S4B-F06/F07; BNX-S2-01 §5). Region -> flag: CA -> Canada; CN, HK, OTHER:* -> International; NONE never gated; UNKNOWN always refused (fail closed). Flags are read only… |
| `9008_s4_economic_type_rule.sql` | extension | PR #3 (merged) | `0f7abec7fbd3` | 9008 Economic-type rules and chunked plan posting (V1.2 UA §5.3.4, §5.5.5; OBJ-022; S4B-F12/F15; Draft-04 B6.1). * bnx.economic_type_rule: one row per R1 enum value (26) with the B6.1 line pattern, flow_class and report effects.… |
| `9009_s4_oauth.sql` | extension | PR #3 (merged) | `c4230cfa8d9a` | 9009 OAuth 2.1 for AI hosts (V1.2 UA §7.2; AIH §4; OBJ-023; S4B-F09; CROSS-02). R1 defects fixed: authn_oauth_token fails closed on missing client_id/redirect_uri (IS DISTINCT FROM), redeems a code single-use (UPDATE ... WHERE us… |
| `9010_s4_intake_drafts_validation_lease.sql` | extension | PR #4 (merged) | `eecc2e0a19db` | 9010 Intake, drafts, validations, approval holds, handoff, account proposals, index/mail intake, notifications, Executor lease and staging (V1.2 UA §5.5, §9.2, §12.2; SI contract §2-§10; OBJ-025, OBJ-066, OBJ-227, OBJ-228, OBJ-24… |
| `9011_s4_documents_evidence_renditions.sql` | extension | PR #5 (merged) | `8246b95e88bb` | 9011 (S4 V1.2, WP-DOC): documents, evidence, renditions. Increment 9011a: the SIN/ITN detector and the database guards. Addendum A1 Rev 1 (branch s4/design-addendum-a1): §3 detector (guard C1), §7 DOC-SIN-10, guard C2. Later incr… |
| `9012_s4_observations_reconciliation_loans.sql` | extension | PR #6 (merged) | `7b44e68afdd7` | 9012 Observations, reconciliation, imports, onboarding, FX, cards and loans (UA V1.2 §5.6, §5.7, §10; OBJ-026, OBJ-248, OBJ-249, OBJ-333, OBJ-373). Built in sub-stages; this file is not final until the last one (docs/s4/S4_9012_I… |
| `9013_s4_report_families_snapshot_status.sql` | extension | PR #7 (merged) | `544614b749f3` | 9013_s4_report_families_snapshot_status.sql -- S4 V1.2 report families, snapshot status and artifacts (UA V1.2 §5.8; OBJ-027, OBJ-216, OBJ-250, OBJ-251, OBJ-374). Expand-only. NEW: bnx.report_definition (versioned; R-BAL/1 is the… |
| `9016_s4_backup_registry_cloud_usage.sql` | extension | PR #8 (merged) | `6be0cc7ba72c` | 9016_s4_backup_registry_cloud_usage.sql -- S4 V1.2 backup/DR registries, cloud usage and admission, restore preamble generator (UA V1.2 §9.2-§9.5; Draft-04 Backup and DR §3-§10 and Cloud Cost and Quota Model §5-§7; OBJ-030, OBJ-2… |
| `9017_s4_gateway_catalog_binding.sql` | extension | PR #9 (draft) | `0b0424bdbe8c` | 9017_s4_gateway_catalog_binding.sql -- S4 CORE-7 Gateway support (UA V1.2 §8, §9.1; AIH V1.2 §2 DD-21; AE V1.2 §6; Amendment 03 §5.2 B1-B9; disposition OBJ-258...OBJ-271). Expand-only. Not in the V1.2 migration register (which li… |
| `9018_s4_executor_work_orders.sql` | extension | PR #10 (draft) | `24278fe7fbcd` | 9018_s4_executor_work_orders.sql -- S4 CORE-8 Executor support (UA V1.2 §9.2-§9.3, §5.8.2; WP-CORE CORE-8; closes the database side of L-9013-2). Expand-only. Not in the V1.2 migration register (which lists exactly 9002-9016): ad… |
| `9019_s4_pwa_ledger_accounts.sql` | extension | PR #11 (draft) | `6df061172d62` | 9019_s4_pwa_ledger_accounts.sql -- S4 CORE-9 PWA support (UA V1.2 §12.1; Draft-04 C1 W-M01…W-M06; WP-CORE CORE-9). Expand-only. Not in the V1.2 migration register (D-CORE9-1): Quick Entry needs the ledger accounts a member may bo… |
| `9020_s4_audit_trail_query.sql` | extension | PR #12 (draft) | `beab0880059e` | 9020_s4_audit_trail_query.sql -- S4 CORE-10 stage: PWA menu item 7 "activity, correction, approval and evidence audit trails" (Owner Requirements OR-U-02 (7); closes L-CORE9-3). Expand-only. Not in the V1.2 migration register (D-… |
| `9021_s4_ai_host_oauth.sql` | extension | PR #13 (draft) | `e9953f3a3c94` | 9021_s4_ai_host_oauth.sql -- S4 AIH-1/AIH-2 stage: database support for the OAuth 2.1 endpoints and the catalog MCP server of the Gateway (AIH V1.2 §3, §4; UA V1.2 §7.2, §8). Expand-only. Not in the V1.2 migration register (D-AIH… |
| `9022_s4_ai_host_cards.sql` | extension | PR #14 (draft) | `1f341449d913` | 9022_s4_ai_host_cards.sql -- S4 AIH-4 stage: the MCP App confirmation card (UA V1.2 §12.3; AIH V1.2 §8; WP AIH-4). Catalog only, expand-only. Not in the V1.2 migration register (D-AIH4-1): the bnx-tools/1.0 entries of the draft t… |
| `9023_s4_ai_host_review_fixes.sql` | extension | PR #15 (draft) | `c378580329b3` | 9023_s4_ai_host_review_fixes.sql -- S4 AIH review remediation (independent review RV-AIH, 2026-11-12). Expand-only. Not in the V1.2 migration register (D-AIHR-1). MODIFY: bnx.authn_oauth_client (9021 body; changed only where mark… |

Not present: **9014** (Tax Core, Owner gate G-CRA-1 / SIN custody) and **9015** (federation, needs INS-2). See L-9016-8.

## Appendix B — Stage records in `docs/s4/` (generated)

| File | Title |
|---|---|
| `G0_REMEDIATION_2026-11-11.md` | G0 remediation G0R — 2026-11-11 |
| `OWNER_DECISIONS_2026-11-06.md` | Owner decisions — 2026-11-06 |
| `OWNER_DECISIONS_2026-11-07.md` | Owner decisions — 2026-11-07 |
| `OWNER_WAIVER_S5_2026-11-05.md` | Owner waiver record — S5 independent review — 2026-11-05 |
| `S4_9011R_Remediation_2026-11-11.md` | 9011R — remediation of the 9011/G0R same-family review (2026-11-11) |
| `S4_9011a_Implementation_Notes.md` | Balnexa S4 — 9011a implementation notes: SIN/ITN detector and database guards |
| `S4_9012_Implementation_Notes.md` | S4 V1.2 — 9012 implementation notes |
| `S4_9013_Implementation_Notes.md` | S4 9013 — Report families, snapshot status, artifacts — Implementation notes |
| `S4_9016_Implementation_Notes.md` | S4 9016 — Backup/DR registries, cloud usage and admission, restore preamble generator — Implementation notes |
| `S4_AIH4_Implementation_Notes.md` | S4 AIH-4 — MCP App confirmation card — Implementation notes |
| `S4_AIH_Implementation_Notes.md` | S4 AIH-1/AIH-2 — OAuth 2.1 for AI hosts and the catalog MCP server — Implementation notes |
| `S4_AIH_Review_Remediation_2026-11-12.md` | S4 AIH review remediation (RV-AIH-01…14) — 2026-11-12 |
| `S4_CORE10_Implementation_Notes.md` | S4 CORE-10 — Inter-project handoff screens, audit trail (item 7), Gateway idempotency keys — Implementation notes |
| `S4_CORE1_Implementation_Notes.md` | Balnexa S4 — Work Package CORE-1 — Implementation Notes V1.0 |
| `S4_CORE2_Implementation_Notes.md` | Balnexa S4 — Increment 2 (9005, 9006, 9007) — Implementation Notes V1.0 |
| `S4_CORE3_Implementation_Notes.md` | Balnexa S4 — Increment 3 (9008, 9009) — Implementation Notes V1.0 |
| `S4_CORE4_Implementation_Notes.md` | Balnexa S4 — Increment 4 (9010) — Implementation Notes V1.0 |
| `S4_CORE7_Implementation_Notes.md` | S4 CORE-7 — Gateway: catalog, schema validation, binding checks, health, uploads, dispatcher — Implementation notes |
| `S4_CORE8_Implementation_Notes.md` | S4 CORE-8 — Executor: lease client, job loop, render, backup, restore drill, evidence re-hash — Implementation notes |
| `S4_CORE9_Implementation_Notes.md` | S4 CORE-9 — PWA: shell, generic renderers, daily screens, closed menu, Draft Confirm — Implementation notes |
| `S4_PR_Review_Guide.md` | Balnexa S4 — PR review guide (PR #1–#4) |
| `S4_Same_Family_Review_2026-11-07.md` | Balnexa S4 — same-family review of PR #1–#4 and its disposition (2026-11-07) |
| `reviews/9011R_REVIEW_PROMPT.md` | Re-review prompt — 9011R (remediation of the 9011/G0R review of 2026-11-11) |
| `reviews/9011_REVIEW_PROMPT.md` | Review prompt — 9011a–c and G0R (SIN/ITN detector, document intake states, Executor validator, G0 remediation) |
| `reviews/AIH_REVIEW_PROMPT.md` | Review prompt — AIH-1/AIH-2/AIH-4 (OAuth 2.1 for AI hosts, catalog MCP server, confirmation card) |
| `reviews/AIH_REVIEW_REPORT_2026-11-12.md` | AIH review report — AIH-1/AIH-2/AIH-4 (`s4/core-10..s4/aih-4`, draft PRs #13 and #14) |

## Appendix C — Decision index (146 table rows, generated)

Decisions are `DELEGATED_DECISION` unless the source says otherwise; the source file has the reason.

| ID | Decision (short) | Source |
|---|---|---|
| D-9011R-1 | No hex/UUID exemption in text. In JSON, only a whole canonical UUID or digest under an id/hash/key/nonce/token key, never under a labelled key. Multi-group windows inside a UUID-shaped substring are not sequences | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011R-2 | Separators: spaces and dashes in any grouping (at most three groups of at least two digits, any grouping near a label); dot, slash, underscore, middle dot, bullet, bare comma, tab and line break only in the printed 3-3-3 form | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011R-3 | The repository scan (guard C6 only) reports a hit inside a whole UUID or hex string of 32+ characters as a machine token and does not fail on it; reviewed history entries are listed by blob SHA in `tools/s4/sin_repo_scan_allow.tx… | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011R-4 | PDF pages are rendered with PDFium and OCRed, judged with the native rules (not R_OCR9) | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011R-5 | The scan runs in a forked child (memory limit, wall-clock kill, stderr discarded, death with the parent) | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011R-6 | Detector version 1.1.0 (spec file name unchanged) | `S4_9011R_Remediation_2026-11-11.md` |
| D-9011a-1 | A nine-digit sequence that **starts inside** a hex token of at least 32 characters, or inside a UUID, is not a candidate, even next to a label. Shorter hex tokens get no exemption | `S4_9011a_Implementation_Notes.md` |
| D-9011a-2 | Shared-index payloads are masked at `stage_write` instead of refused | `S4_9011a_Implementation_Notes.md` |
| D-9011a-3 | `bnx.audit` refuses (it does not mask) any audited payload or subject containing a candidate. This is the single generic C2 guard for every audited command | `S4_9011a_Implementation_Notes.md` |
| D-9011a-4 | The `ocr` origin exists only in the Python reference. SQL and JS refuse it | `S4_9011a_Implementation_Notes.md` |
| D-9011a-5 | Separators: one dash, or one or more spaces after normalisation; no whitespace collapsing | `S4_9011a_Implementation_Notes.md` |
| D-9011a-6 | Label word boundaries are broken only by an ASCII letter (after folding), not by a digit, so a label glued to digits (`SIN` immediately followed by the number) still counts. Chinese labels match as substrings | `S4_9011a_Implementation_Notes.md` |
| D-9011b-1 | The no-release rule of A1-OD-2 is enforced by a transition trigger, not only by the absence of a command | `S4_9011a_Implementation_Notes.md` |
| D-9011b-2 | A verdict computed under any detector version other than the current one is rejected (`DETECTOR_VERSION_STALE`). Admission also requires a scan under the current version | `S4_9011a_Implementation_Notes.md` |
| D-9011b-3 | When admission fails (identity changed, hash mismatch, scan not current, declaration missing), the document returns to `DISCOVERED` with the reason and nothing is written. Re-scan and, where needed, a new declaration follow | `S4_9011a_Implementation_Notes.md` |
| D-9011b-4 | Notification metadata uses the fixed 9010 keys: `record_key` = discovery id, `source_id` = module, `masked_subject` = file name. The file name is included only when it contains no digit at all | `S4_9011a_Implementation_Notes.md` |
| D-9011b-5 | A file name that contains a candidate never reaches the database: `stage_write` refuses the whole discovery. The Executor must send `name_withheld` instead (9011c) | `S4_9011a_Implementation_Notes.md` |
| D-9011b-6 | The SIN-bearing class list is held in the database (`doc_class_sin_bearing`). The Executor's `sin_bearing` flag can only add to it, and an uncertain class always requires a declaration | `S4_9011a_Implementation_Notes.md` |
| D-9011c-1 | The validator fails closed. Any extraction failure, refused format, limit or OCR failure adds a rule code and gives `SCAN_INCOMPLETE`. A hit takes precedence and gives `SIN_CANDIDATE` | `S4_9011a_Implementation_Notes.md` |
| D-9011c-2 | PDFs are not scanned as raw bytes. Pass 1 extracts string operands; pass 2 reads the structure revision by revision | `S4_9011a_Implementation_Notes.md` |
| D-9011c-3 | D-A1-4 resolved: `t_ocr` stays at 0.90. The lowest word confidence on clean synthetic digit lines was 0.926–0.950 at 18–44 px (AT-SIN-13 evidence). The spec file is unchanged at 1.0.0; its "provisional" note will be updated with… | `S4_9011a_Implementation_Notes.md` |
| D-9011c-4 | OCR runs the `tesseract` binary directly over stdin/stdout, with a minimal environment, one thread, and a timeout equal to the remaining time budget. `pytesseract` is not used | `S4_9011a_Implementation_Notes.md` |
| D-9011c-5 | A verdict without a document class counts as uncertain, so it needs the Owner's declaration. The validator's default is `class_uncertain = true` until a classifier exists | `S4_9011a_Implementation_Notes.md` |
| D-9011c-6 | The trusted SHA-256 writer for these documents is the lease-bound `doc_archived` staging payload, promoted by the worker. `verified_by_execution` records `executor:doc_archived:<staging id>`. `acquired_by` is the active Owner, me… | `S4_9011a_Implementation_Notes.md` |
| D-9011c-7 | Text from separate cells, XML elements, PDF strings or HTML elements is joined with " \ | `S4_9011a_Implementation_Notes.md` |
| D-9011c-8 | The tests are a new suite, `run_s4_core6.py`, picked up by the CI loop. CI installs the hash-pinned wheels plus `tesseract-ocr`, `tesseract-ocr-eng` and `strace` | `S4_9011a_Implementation_Notes.md` |
| D-9012-1 | 9012 is split into 9012a–d (table above); R28 comes first | `S4_9012_Implementation_Notes.md` |
| D-9012a-1 | One engine function holds all R28 arithmetic, and `q_r28_loan_position` only assembles its input | `S4_9012_Implementation_Notes.md` |
| D-9012a-2 | The oracle is upgraded to V1.2 (`tests/oracle/r28_reference.py`) and uses exact fractions. The S2 oracle (`r28_reference_s2_v1_0.py`, SHA-256 `ead5a9f8…22f18`) and the V1.1 fixtures (`84f68f54…98254`) are kept unchanged and hash-… | `S4_9012_Implementation_Notes.md` |
| D-9012a-3 | Validation order V0a, V0b, V1, V1a (principal scale), V1b (payment scale), then V2…V14 | `S4_9012_Implementation_Notes.md` |
| D-9012a-4 | Fixtures V1.2 were authored here (WP-TEST TST-2 issues them). Expected values are the oracle's, checked by hand below. AT-R28-20 is a database test, because it needs ledger versions | `S4_9012_Implementation_Notes.md` |
| D-9012a-5 | In the rounding-event ledger, the unrounded value is the exact accrual truncated toward zero to 12 decimals (`unrounded_trunc12`) | `S4_9012_Implementation_Notes.md` |
| D-9012a-6 | A payment's date is the journal's `transaction_date`; its amount is the journal's movement on the linked cash account | `S4_9012_Implementation_Notes.md` |
| D-9012a-7 | `household_internal` is computed at query time, never stored. It is true only when both sides are accounts in this household's books and `ownership_at(as_of, V)` names the lender on the receivable account and the borrower on the… | `S4_9012_Implementation_Notes.md` |
| D-9012a-8 | Terms are bitemporal by `recorded_at` (`terms_recorded_as_of`); payment links are versioned by ledger version | `S4_9012_Implementation_Notes.md` |
| D-9012a-9 | Accrued interest is never posted automatically. Reconciling posted interest journals against the accrual (BNX-S2-08 §1.6) is left for the F3/F5 report work | `S4_9012_Implementation_Notes.md` |
| D-9012b-1 | One function selects every rate, with the order override → settlement (same date only) → reference (on or before; stale after 7 days) → missing; quality first, then direct before inverse | `S4_9012_Implementation_Notes.md` |
| D-9012b-2 | `STALE` is both a recordable quality (a source may say so) and derived from age; `MISSING` is never replaced by 1 or 0 | `S4_9012_Implementation_Notes.md` |
| D-9012b-3 | Cost of disposed units is pro rata within the lot named by the disposal (specific identification); FX effect = translation difference of the remaining cost (as_of rate minus acquisition rate) and of the disposed cost (disposal ra… | `S4_9012_Implementation_Notes.md` |
| D-9012b-4 | A NAV older than 31 days is `STALE_NAV` (computed, flagged); a NAV in another currency is converted at the valuation date's rate, and a stale rate is used but flagged (`NAV_FX_STALE`; `FX_STALE` for the reporting rate) | `S4_9012_Implementation_Notes.md` |
| D-9012b-5 | Card spend counts `card_spend` and `consumption_expense` purchases minus `refund` journals on the card in the policy currency, by effective posting date; repayments, transfers, fees, interest, FX, clearing and openings never coun… | `S4_9012_Implementation_Notes.md` |
| D-9012b-6 | The policy in force on the `as_of` (or `period_start`) date governs the period that contains it; a later policy version affects only periods that start under it | `S4_9012_Implementation_Notes.md` |
| D-9012b-7 | The count criterion counts purchase journals; refunds reduce spend, not the count | `S4_9012_Implementation_Notes.md` |
| D-9012b-8 | A 29 February anniversary falls on 28 February in other years | `S4_9012_Implementation_Notes.md` |
| D-9012b-9 | `CALCULATED_QUALIFICATION` is computed by the server when recorded; the client cannot supply its figures | `S4_9012_Implementation_Notes.md` |
| D-9012b-10 | Test ids: AT-FX-01, AT-INVL-01 (BNX-S2-14 names it AT-INV-01, which is already the catalog inventory test of core1), AT-P0-R19, AT-9012b-CAT, in the new suite `tests/py/run_s4_core9.py` | `S4_9012_Implementation_Notes.md` |
| D-9012c-1 | Observations carry a `sign_convention` (defaulting to `owed_positive` for credit-card and loan-payable accounts, otherwise `asset_positive`) instead of being normalised to the ledger sign | `S4_9012_Implementation_Notes.md` |
| D-9012c-2 | A revision must name an earlier observation of the same account-currency and source | `S4_9012_Implementation_Notes.md` |
| D-9012c-4 | `statement_period` is a view at the current version plus a function at any version | `S4_9012_Implementation_Notes.md` |
| D-9012c-5 | Test ids AT-OBS-01, AT-STP-01, AT-RCX-01, AT-9012c-CAT in the new suite `tests/py/run_s4_core10.py` | `S4_9012_Implementation_Notes.md` |
| D-9012c2-1 | Statement rows are R1 `source_txn` rows of the account-currency with a posting date in the statement period; a row's journal is its R1 `source_link_event` link in force at the version | `S4_9012_Implementation_Notes.md` |
| D-9012c2-2 | C2's "page reference" is satisfied at document granularity (the statement's document) | `S4_9012_Implementation_Notes.md` |
| D-9012c2-3 | Draft-04 `recon_case` / `recon_finding` / `recon_case_result` map to the V1.2 `reconciliation_run` (case result, versioned) and `reconciliation_exception` (finding) | `S4_9012_Implementation_Notes.md` |
| D-9012c2-4 | The §D7 lifecycle is stored as a phase inside the S2 states (OPEN: open / investigating / findings_ready / unresolved_parked; EXPLAINED: resolved_explained; RESOLVED: resolved_matched) | `S4_9012_Implementation_Notes.md` |
| D-9012c2-5 | RC-05 recognises fee or interest rows by wording (`fee`, `interest`, `service charge`, `frais`, `intérêts`) | `S4_9012_Implementation_Notes.md` |
| D-9012c2-6 | RC-14 is emitted as a finding only when the item findings do not already close the difference; the subset search always feeds C5 | `S4_9012_Implementation_Notes.md` |
| D-9012c2-7 | Hypotheses RC-12/13/14 run on `difference_open` and `incomplete_history`; the unresolved remainder is written only for `difference_open` | `S4_9012_Implementation_Notes.md` |
| D-9012c2-8 | A run is started by the member (`cmd_run_reconciliation`); the outbox trigger of §D1 (after statement confirmation, plan activation, corrections) is not wired yet | `S4_9012_Implementation_Notes.md` |
| D-9012c2-9 | BAL01–12 are not individually defined in any available source; AT-RCN-01…03, AT-RCX-01 and AT-OBS-01 cover the summary of S2-14 OR-B-03 (observations, cut-off, missing baseline → no comparison, conflicts kept) | `S4_9012_Implementation_Notes.md` |
| D-9012d-1 | MR-08's description similarity is a trigram similarity (`bnx.text_similarity`, as pg_trgm computes it) | `S4_9012_Implementation_Notes.md` |
| D-9012d-2 | MR-04 (bank reference identity) is not applied: the R1 journal has no bank reference, and no statement profile declares `bank_ref_unique` yet | `S4_9012_Implementation_Notes.md` |
| D-9012d-3 | "Transfer-like" is recognised by wording (`transfer`, `e-transfer`, `xfer`, `tfr`, `virement`, `wire`, 转账) | `S4_9012_Implementation_Notes.md` |
| D-9012d-4 | MR-12 decides "counterpart coverage" from final statements of every other same-currency account-currency on the row's date; counterpart identification from descriptions is not attempted | `S4_9012_Implementation_Notes.md` |
| D-9012d-5 | The onboarding job state shows REVIEW ahead of PROCESSING while a member decision is pending | `S4_9012_Implementation_Notes.md` |
| D-9012d-6 | Payment methods: Apple Pay, Google Pay, Samsung Pay, WeChat Pay, Alipay, PayPal, Interac, other; networks: UnionPay, Visa, Mastercard, JCB, Amex, Interac, other | `S4_9012_Implementation_Notes.md` |
| D-9012d-7 | Test ids AT-MR-01, AT-MR-02, AT-ONB-01, AT-IMP-PAY-01, AT-9012d-CAT in `tests/py/run_s4_core11.py` | `S4_9012_Implementation_Notes.md` |
| D-9013-1 | F3 counts income and expense category lines (the accounting P&L), split by the flow class of the journal; investment results are reported apart from operating income | `S4_9013_Implementation_Notes.md` |
| D-9013-2 | R09 is a cash basis on bank, cash and e-wallet accounts; a card purchase is operating but moves no cash until the card repayment | `S4_9013_Implementation_Notes.md` |
| D-9013-3 | F2 masks lines on accounts the reader cannot see; F3/F5 totals exclude journals and balances of such accounts | `S4_9013_Implementation_Notes.md` |
| D-9013-4 | F5 is book value; market value of investments is in F4 | `S4_9013_Implementation_Notes.md` |
| D-9013-5 | The R30 query is named `q_r30_review_queue` | `S4_9013_Implementation_Notes.md` |
| D-9013-6 | Snapshot staleness is judged on the account-currencies the snapshot shows (its projection), not the whole household content | `S4_9013_Implementation_Notes.md` |
| D-9013-7 | Snapshots remain R-BAL only; family results are delivered by the queries with their envelope | `S4_9013_Implementation_Notes.md` |
| D-9013-8 | Test ids AT-F1, AT-F2-F3, AT-P0-R09, AT-F4-F5-F6, AT-F7-P0 (R11, R13, R15, R30, R31), AT-RPT-STALE, AT-ARCH-ACL (01, 02, 04 and AT-SNAP-03/04 under toggles), AT-9013-CAT in `tests/py/run_s4_core12.py` | `S4_9013_Implementation_Notes.md` |
| D-9016-1 | Ship 9016 now, before 9014 (tax, Owner-gated) and 9015 (federation, deferred), with the register numbers unchanged | `S4_9016_Implementation_Notes.md` |
| D-9016-2 | UA §6.3 names `wrk_backup_recorded` / `wrk_restore_drill_recorded`; UA §9.2 says results arrive through `stg_backup_recorded` / `stg_restore_drill_recorded` via the lease. Both hold: the `stg_*` functions (9010) stage, the `wrk_*… | `S4_9016_Implementation_Notes.md` |
| D-9016-3 | Header facts are a database function executed by `bnx_backup` itself, enabled by a narrow privilege rule (`bkp_*` + SECURITY INVOKER + not VOLATILE) | `S4_9016_Implementation_Notes.md` |
| D-9016-4 | Header facts cover every registered schema (8, including `bnx_audit`) and every table except `schema_migrations` / `schema_bootstrap` (migrations are listed separately; bootstrap rows are recreated) | `S4_9016_Implementation_Notes.md` |
| D-9016-5 | **Result contract**: staged results carry sizes in KiB (`compressed_kib`, `wire_kib`; usage `egress_kib`, `storage_kib`), never a bare byte count; the object name is derived from `run_id` (`bnx-vault-backups/<UTC yyyy/mm>/<run_id… | `S4_9016_Implementation_Notes.md` |
| D-9016-6 | K2 only (OBJ-344 design default): every VERIFIED run lists an Owner and a drill recipient; K1 (Owner key only) is not supported by this migration | `S4_9016_Implementation_Notes.md` |
| D-9016-7 | Neon branch restore points (the P-B…P-D daily tier) are not taken; `wrk_backup_due` reports `DAILY_TIER_NEON_BRANCH_UNAVAILABLE` | `S4_9016_Implementation_Notes.md` |
| D-9016-8 | Key registration, compromise handling, restore authorization and cost-policy changes are Owner-only T3 commands; admins may read the status queries; none of these functions is in the MCP catalog | `S4_9016_Implementation_Notes.md` |
| D-9016-9 | Owner alerts use the existing notification kind `EXCEPTION` with `metadata.kind` (e.g. `AUDIT_ANCHOR_MISMATCH`, `RESTORE_DRILL_FAILED`, `BACKUP_POLICY_CHANGED`) | `S4_9016_Implementation_Notes.md` |
| D-9016-10 | Billing month = UTC calendar month for all estimates | `S4_9016_Implementation_Notes.md` |
| D-9016-11 | A 100 % budget notice sets `provider_capped` but backups are still admitted within the reserve until a launch is refused; a refused launch or a killed task caps everything; after a month change (or after the 6 h back-off of a fai… | `S4_9016_Implementation_Notes.md` |
| D-9016-12 | The O-8 anchor precondition (R-11) is **reported** by `q_backup_status.real_data_anchor_precondition` (a VERIFIED backup with anchor MATCH and an external-verifier INTACT result for that anchor); gate O-8 itself is not changed or… | `S4_9016_Implementation_Notes.md` |
| D-9016-13 | Evidence that the Executor never hashed is reported `NO_REFERENCE`, not `MISMATCH` | `S4_9016_Implementation_Notes.md` |
| D-9016-14 | The `COPY` restore path (used when `pg_dump` of the server's major is missing) loads tables in FK topological order inside one transaction with restore mode on | `S4_9016_Implementation_Notes.md` |
| D-AIH4-1 | Add migration **9022**, catalog only, outside the V1.2 register. | `S4_AIH4_Implementation_Notes.md` |
| D-AIH4-2 | The seal is the version pair (`plan_hash`, `scope_digest`) of CORE-9, not an HMAC with `HANDOFF_SEAL_KEY`. | `S4_AIH4_Implementation_Notes.md` |
| D-AIH4-3 | No in-card editing. The card is display-only, and revisions go through the `fin_draft_revise` tool or the PWA. | `S4_AIH4_Implementation_Notes.md` |
| D-AIH4-4 | The draft link goes in a second content block, not in `structuredContent`. | `S4_AIH4_Implementation_Notes.md` |
| D-AIH4-5 | The card shows the instance host, not an `instance_fingerprint`. | `S4_AIH4_Implementation_Notes.md` |
| D-AIH-1 | Add migration **9021** outside the V1.2 register. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-2 | MCP transport is stateless JSON, with no SSE stream and no `Mcp-Session-Id`. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-3 | **Two resources** per instance, `<instance>/mcp` and `<instance>/api` (`BNX_PUBLIC_URL`, else `APP_ORIGIN`). The audience is the surface the token is presented to. A new consent must name one of them. `GET /oauth/authorize` witho… | `S4_AIH_Implementation_Notes.md` |
| D-AIH-4 | Tool name = catalog name with `.` replaced by `_`; the catalog name is the tool title. Uniqueness is tested. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-5 | `tools/list` shows only the tools the consent covers. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-6 | The consent screen grants `finance.read`, `finance.draft`, `reports.read`, `handoff.read`, `handoff.prepare` and `offline_access`. `documents.read` needs a document-class subset the screen does not offer yet; `tax.*` belongs to W… | `S4_AIH_Implementation_Notes.md` |
| D-AIH-7 | The **Core** infers the host profile of a DCR or CIMD client. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-8 | Audit `host_profile` comes from the connection on bearer calls. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-9 | DCR is open, limited to 10 registrations per address per day (OD-21 default). Loopback redirects remain allowed only on synthetic instances (OD-22 default, 9009). | `S4_AIH_Implementation_Notes.md` |
| D-AIH-10 | CIMD documents are fetched only for allowlisted client ids, once, with tight limits. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-11 | Consent defaults: read scopes ticked; draft and prepare scopes and every account unticked. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-12 | The client's `state` never reaches the database. The consent's idempotency key is letters only. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-13 | Tool errors use `isError: true` with `structuredContent {error, field}` carrying the REST code. An authentication failure is HTTP 401 with the challenge. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-14 | `/mcp` checks `Origin` and `MCP-Protocol-Version`. | `S4_AIH_Implementation_Notes.md` |
| D-AIH-15 | Revocation lives in Settings → AI connections. | `S4_AIH_Implementation_Notes.md` |
| D-AIHR-1 | Add migration **9023** (one MODIFY) outside the V1.2 register. | `S4_AIH_Review_Remediation_2026-11-12.md` |
| D-AIHR-2 | Close RV-AIH-01 at the Gateway, not in `cmd_approve_ai_connection`. | `S4_AIH_Review_Remediation_2026-11-12.md` |
| D-AIHR-3 | Accept RV-AIH-11 (value-wise C4). | `S4_AIH_Review_Remediation_2026-11-12.md` |
| D-CORE10-1 | Add migration **9020** (`q_audit_trail`) outside the V1.2 register. | `S4_CORE10_Implementation_Notes.md` |
| D-CORE10-2 | Restrict household-wide audit visibility to the Owner and admins; everyone else sees their own events. | `S4_CORE10_Implementation_Notes.md` |
| D-CORE10-3 | Fix L-CORE9-9 at the Gateway (normalize keys) rather than exempting `idempotency_key` from the database guard. | `S4_CORE10_Implementation_Notes.md` |
| D-CORE10-4 | Only same-currency and portable-block flows get screens. The Mode J portable proposal for AI hosts is the same `bnx-project-handoff/1.x` block, exchanged through the same two screens. | `S4_CORE10_Implementation_Notes.md` |
| D-CORE7-1 | Add migration **9017** (`s4_gateway_catalog_binding`) although the V1.2 register lists exactly 9002–9016 and CORE-7 as "code" | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-2 | Catalog entries are **generated** from the function bodies, `bnx.function_scope` and a small explicit overrides file, and stored as comments; `--check` fails on drift | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-3 | Generated input schemas are permissive: properties typed only where the body casts the value, `additionalProperties: true`, no `required`; `idempotency_key` is not in any schema | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-4 | Tool names: `function_scope.note` where it is a dotted tool name, the AIH §2.2 name for 14 entries via the overrides file, else `pwa.<rest name>`; names must be unique | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-5 | A failed binding check closes every route except health, reads included, and the dispatcher | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-6 | Release range B3 = core `0109`, extension `9016`…`9017` | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-7 | B7 is checked inside `resolve_actor` with the audience the Gateway sends; tokens issued without a resource stay accepted | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-8 | `/mcp` keeps the R1 handler; the catalog-generated MCP server is AIH-2 | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-9 | Presigned PUT signs only `host`, valid 15 minutes, and the upload route is gated on R2 settings (O-7) | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-10 | Deferred kinds back off to at most 3 h (one backstop period) | `S4_CORE7_Implementation_Notes.md` |
| D-CORE7-11 | An absent or unparsable body is `{}` (R1 behaviour); a JSON array or scalar body is `422 VALIDATION_FAILED` | `S4_CORE7_Implementation_Notes.md` |
| D-CORE8-1 | Add migration **9018** outside the V1.2 register (as 9017, D-CORE7-1) | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-2 | The work order is returned with the lease (one round trip), not by a separate input route | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-3 | The `BACKUP` order is advisory (`due` flag); the job stops (nothing staged) when not due. `RESTORE_DRILL` without `item_id` gets no order | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-4 | Artifacts are content-addressed (`bnx-artifacts/rpt/<snapshot>/<sha256>.html`) and the reference is derived by the database | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-5 | The renderer is deterministic and verifies the projection digest itself | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-6 | Archive = deterministic tar of `backup_header.json` + `data.dump`, encrypted once to both K2 recipients; `plaintext_sha256` = the tar, `header_sha256` = the header file, `dump_sha256` = the dump | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-7 | `wire_kib` = size of the plain-SQL rendering of the dump (`pg_restore -f -`) | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-8 | `pg_dump` choice = the lowest installed major ≥ the server's (with its `pg_restore`) | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-9 | A job never stages a half-done result: SIGTERM abandons the item; tool stderr and driver messages never enter a payload (step names or exception types only); restore load errors carry only the primary message | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-10 | Drill targets are provisioned by a local provisioner on a server the drill identity administers | `S4_CORE8_Implementation_Notes.md` |
| D-CORE8-11 | The Gateway's completion schemas are selected by the job kind the client names; the database still binds the lease's real kind (`LEASE_KIND_MISMATCH`) and its promoter re-validates | `S4_CORE8_Implementation_Notes.md` |
| D-CORE9-1 | Add migration **9019** (`q_ledger_accounts`) outside the V1.2 register | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-2 | Catalog blocks become **per-migration deltas**; a committed migration is never edited | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-3 | No framework, no bundler, no third-party runtime code in the PWA | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-4 | The PWA is served by the Gateway (same origin) through the Workers static-assets binding | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-5 | The menu is a fixed list of catalog core functions, and visibility is computed from the live catalog and the caller's tier | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-6 | Quick Entry covers same-currency expense, income and transfer. Other movements (card, FX, investment, loan) use the menu's generic forms | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-7 | A sealed link whose seal differs requires an explicit "reviewed the current version" before approval; approval always sends the displayed version | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-8 | Focus moves to the new heading after each navigation but not on first load, and the skip link does not touch the hash | `S4_CORE9_Implementation_Notes.md` |
| D-CORE9-9 | Headless tests run with every non-origin host and every AI route (`/mcp`, `/oauth/*`) aborted and recorded; AT-NOAI-00 asserts that both lists stay empty for the whole suite | `S4_CORE9_Implementation_Notes.md` |

## Appendix D — Limits register (96 table rows, generated)

"Closed by" is filled where a later stage records the closure; every other limit is open with the follow-up shown.

| ID | Limit (short) | Follow-up | Closed by | Source |
|---|---|---|---|---|
| L-R-1 | A correctly hashed forged append through the owner path (G0R residual R-3) |  | open | `S4_9011R_Remediation_2026-11-11.md` |
| L-R-2 | OCR quality: heavy skew beyond ±12°, handwriting, very low resolution |  | open | `S4_9011R_Remediation_2026-11-11.md` |
| L-R-3 | Image data that decodes without error to a blank image (garbage CCITT) |  | open | `S4_9011R_Remediation_2026-11-11.md` |
| L-R-4 | A value split into digits spread over three cells, or written with letters between groups |  | open | `S4_9011R_Remediation_2026-11-11.md` |
| L-R-5 | A non-standard grouping (2-4-3 with dashes) embedded across the segments of a UUID-shaped token |  | open | `S4_9011R_Remediation_2026-11-11.md` |
| L-1 | **Operational false positives.** A transaction description or reference containing a nine-digit number that happens to pass Mod 10 (about 1 in 10 random nine-digit numbers), or that begins 08/09, is now refused. This also applies… | Intended (fail closed, A1-OD-1). FP-SIN-01 measures the rate; the 5 % review trigger of A1-OD-2 applies | open | `S4_9011a_Implementation_Notes.md` |
| L-2 | Guard C4 (MCP tool responses and assembled prompts) and C3 (log scrubbing) are not wired into the Worker yet; the JS detector is ready | 9011b | open | `S4_9011a_Implementation_Notes.md` |
| L-3 | The OCR rules exist in the reference implementation only. No OCR engine is connected; `T_ocr` = 0.90 is provisional | 9011c (D-A1-4) | open | `S4_9011a_Implementation_Notes.md` |
| L-4 | NFKC is taken from each runtime's Unicode tables (Python 15.x, Node ICU, PostgreSQL). The spec pins the decimal-digit table; rare compatibility characters could normalise differently between runtimes | The corpus covers the characters that matter; AT-SIN-11 fails on any divergence it sees | open | `S4_9011a_Implementation_Notes.md` |
| L-5 | Audits now scan their payload. A cheap pre-filter skips the full scan when no nine-digit pattern exists, and suite timings did not change measurably | Watch in 9011b/c | open | `S4_9011a_Implementation_Notes.md` |
| L-6 | D-9011a-1 is a design refinement made under the delegation | Fold into Addendum A1 Rev 2 | open | `S4_9011a_Implementation_Notes.md` |
| L-7 | `ARCHIVED` is recorded as a state; the Z3 writes (evidence object, document row, Drive copy and re-hash, second copy) are not implemented yet | 9011c | open | `S4_9011a_Implementation_Notes.md` |
| L-8 | No Executor exists yet. The verdict, discovery and archive payloads are the contract the Executor must produce | 9011c | open | `S4_9011a_Implementation_Notes.md` |
| L-9 | An archived document found by a later re-scan to contain a candidate moves `ARCHIVED → SCANNING → QUARANTINED`. Removing the archived copies is an incident procedure that does not exist yet | 9011c notes; the erasure command (DL §9) is later | open | `S4_9011a_Implementation_Notes.md` |
| L-7 | Now partly closed. Z3 registration is done (evidence object, evidence file, link). Still open: the Drive Processed copy and re-hash (`wrk_record_archive_event`, 0109), the second copy (`dual_verified`), and `bnx.document` rows (s… | Drive copy: M1/M0-B-08. Segmentation: the statement work packages | open | `S4_9011a_Implementation_Notes.md` |
| L-8 | Now partly closed. The validator exists as library code. There is no Executor job runner, Drive or mail fetcher, lease client or cloud identity | M1 / M0-B | open | `S4_9011a_Implementation_Notes.md` |
| L-9 | Unchanged. A re-scan that quarantines an `ARCHIVED` document leaves its write-once Z3 rows in place. Every later use must check `doc_scan_current` and the state | Incident and erasure procedure (DL §9), later | open | `S4_9011a_Implementation_Notes.md` |
| L-10 | OCR misreadings made with high confidence are not flagged: `l`, `I` and `O` read as digits give a clean 8- or 10-digit run. A nine-digit value is always flagged (`R_OCR9`), even when misread | Inherent to OCR; documented for the Owner | open | `S4_9011a_Implementation_Notes.md` |
| L-11 | Pages are not rasterised. Text drawn as vector outlines, or set in a font without a usable Unicode mapping, can be missed when the page has no image to OCR | Needs a PDF rasteriser (poppler or pdfium) in the Executor container: M1 | open | `S4_9011a_Implementation_Notes.md` |
| L-12 | Anything outside the format allowlist (DOCX, HEIC, TIFF, and others) gives `SCAN_INCOMPLETE`. The Owner converts such a file and drops it in again. Erratum (9011 review R-45): CCITT page images inside a PDF are decoded and OCRed.… | Fail closed by design | open | `S4_9011a_Implementation_Notes.md` |
| L-13 | There is no document classifier. Every document without an Owner-supplied class needs a declaration | Safe, at the cost of more Owner work; a classifier is a later increment | open | `S4_9011a_Implementation_Notes.md` |
| L-14 | AT-SIN-07 "every view labels it": the label is in the redaction queue and `source_fidelity` is stored with the evidence. The evidence and rendition views do not exist yet | 9016 renditions and the PWA must show the label from `bnx_doc.document_evidence.source_fidelity` | open | `S4_9011a_Implementation_Notes.md` |
| L-9012-1 | Loan accounts need a registry institution (9006), and a loan between family members has none | **Resolved** by `OWNER_DECISION` 2026-11-11 (option 2): the FAMILY pseudo-institution (see "Owner decisions") | open | `S4_9012_Implementation_Notes.md` |
| L-9012-2 | No exception queue for `REJECTED` loans yet (BNX-S2-08 §1.2) | It comes with the reconciliation and exception work (9012c) | open | `S4_9012_Implementation_Notes.md` |
| L-9012-3 | F3/F5 consolidation and interest reconciliation are not implemented (AT-R28-CONS covers only the flag) | Report families (9013/9015) | open | `S4_9012_Implementation_Notes.md` |
| L-9012-4 | AT-R28-09/11 "on the plan path" (approval through posting plans) is not covered: loan commands are direct tier-2 commands | Plan kinds for loans need a design decision; recorded for the plan work | open | `S4_9012_Implementation_Notes.md` |
| L-9012-5 | AT-INV-01 still scopes the disposition register up to 9010; the 9012 objects are not yet checked against OBJ-248/249. The engine helpers and `cmd_declare_loan` are declared in its helper list, and AT-FLG-11 lists the two loan tab… | When 9012 is complete (after 9012d), 9011 and 9012 join the inventory scope | open | `S4_9012_Implementation_Notes.md` |
| L-9012-6 | Disposition register gap: OBJ-249 does not name `cmd_declare_loan`, although a loan must be declared before its terms can be. OBJ-248 does not name `loan_term_event`'s retraction rule. 9012b adds `investment_lot_disposal` and the… | Register update proposed for the next design revision; declared in AT-INV-01's helper list meanwhile | open | `S4_9012_Implementation_Notes.md` |
| L-9012-7 | No instrument registry: `instrument_id` is the caller's identifier, shared by `investment_lot` and the R1 `valuation` (which has no foreign key) | An instrument registry belongs to the F4 report work (9013) | open | `S4_9012_Implementation_Notes.md` |
| L-9012-9 | Reconciliation reads `source_txn` rows by period and cites the statement at document granularity; no running balances (S1-RUNBAL `not_available`), no page numbers, no OCR confidence for RC-09 | Narrowed when WP-DOC writes statement rows | open | `S4_9012_Implementation_Notes.md` |
| L-9012-10 | The AI investigator tools of §D6 and `NO_EVIDENCE_FOR_CORRECTION` are not built | MCP read/propose tools for reconciliation belong to the MCP work package | open | `S4_9012_Implementation_Notes.md` |
| L-9012-11 | Not built until WP-DOC exists: MR-01…MR-07 (file and document duplicates, re-extraction, statement versions, bank-reference identity, occurrence numbering, overlap alignment, running-balance guard), the onboarding scheduler tick,… | Each needs extraction runs, staged rows or executor output | open | `S4_9012_Implementation_Notes.md` |
| L-9012-8 | No automatic FX feed (`fx_selection_log`, R1, stays unused) and no automatic card-fee evaluation job | Feeds and jobs need cloud egress and scheduling, outside this stage | open | `S4_9012_Implementation_Notes.md` |
| L-9013-1 | Snapshots are R-BAL only (D-9013-7) | Family snapshot canonicalisation in a later revision | open | `S4_9013_Implementation_Notes.md` |
| L-9013-2 | The Executor `REPORT_RENDER` job, the Drive archive writer and the `GET /api/v1/artifacts/{id}` proxy route are code outside the database; only their database contracts exist here. AT-ARCH-ACL-03 (Drive permissions = instance ide… | WP-DOC / Worker | CORE-8 (9018, PR #10) | `S4_9013_Implementation_Notes.md` |
| L-9013-3 | R17 minimum payment and due dates (R21 calendar) are not modelled (`DUE_DATE_NOT_MODELLED`); R25 maturities are not modelled (`MATURITIES_NOT_MODELLED`) | Needs card statement extraction and lot maturity data | open | `S4_9013_Implementation_Notes.md` |
| L-9013-4 | R02 net-worth trend and R06 income/expense trend are obtained by calling F5/F3 per period; no stored series | A trend view can compose the queries | open | `S4_9013_Implementation_Notes.md` |
| L-9016-1 | The disposition names only `backup_run`, `backup_key_registry`, `restore_drill`, `cloud_usage` and the `wrk_`/`q_` functions of OBJ-030, OBJ-256 and OBJ-257; 35 further objects, the `bkp_` privilege rule (MODIFY of `apply_grants`… | Register update with the next disposition revision | open | `S4_9016_Implementation_Notes.md` |
| L-9016-2 | The Executor side is not built: the `bnx-backup` job (`pg_dump`, age encryption, upload with retention, re-download), the vault registry files, the `bnx-drill` job, the semi-annual Owner-key test (AT-BKP-20 is enforced only as th… | CORE-8 (Executor), M0-E | open | `S4_9016_Implementation_Notes.md` |
| L-9016-3 | `pg_dump`/`pg_restore` 17 are not available in this container: the real `pg_dump` path of AT-BAK-04 ran on PG16 only; PG17 ran the COPY path. CI installs both majors and runs both paths | NEW-052 closes when CI is green on PG17 | CI PG17 run (PR #8) | `S4_9016_Implementation_Notes.md` |
| L-9016-4 | `bkp_header_facts` aggregates each table's row text in memory | Fine within Neon Free (1 GB); a streaming digest is needed for larger instances | open | `S4_9016_Implementation_Notes.md` |
| L-9016-5 | AT-NEON-01/02/05/06 and AT-SPEND-02/07/08 are Worker, Executor or M0 behaviour; only the database parts are implemented (admission refusals, meters, capacity states). AT-SPEND-06's IAM half is M0 | CORE-7/CORE-8, M0-F | open | `S4_9016_Implementation_Notes.md` |
| L-9016-6 | Restore-as-new (new `instance_identity` with origin `restore_as_new`, fingerprints re-keyed, sessions invalidated) is only recognised as a drill kind | INS-3 | open | `S4_9016_Implementation_Notes.md` |
| L-9016-7 | AT-BKP-11 (refuse a restore into a different migration version) surfaces as `HEADER_FACTS_DIFFER` at the drill, not as an up-front refusal | The Executor's restore step R3 checks the header's migrations before loading (CORE-8) | open | `S4_9016_Implementation_Notes.md` |
| L-9016-8 | Numbering (D-9016-1): no persistent instance may be installed at 9016 before 9014 and 9015 exist; otherwise they must be renumbered after 9016 | Owner, before the first real install | open | `S4_9016_Implementation_Notes.md` |
| L-9016-9 | "Alert after 2 failed days" (Draft-04 §H11) is a Worker rule; the database alerts on each FAILED run | CORE-8 | open | `S4_9016_Implementation_Notes.md` |
| L-9016-10 | Cost figures remain Draft-04 estimates (rates, overhead, W ≈ 4 C) until M0-F measurements replace them through `cmd_set_cost_policy` | M0-F | open | `S4_9016_Implementation_Notes.md` |
| L-AIH4-1 | 9022 needs register and disposition rows. | Next register revision. | open | `S4_AIH4_Implementation_Notes.md` |
| L-AIH4-2 | Not rendered by Claude or ChatGPT. The MCP Apps message names and the ChatGPT globals follow the published descriptions but are not qualified (PV-UI-01…03). | AIH-5 PoCs. | open | `S4_AIH4_Implementation_Notes.md` |
| L-AIH4-3 | No Transaction Entry card with in-card edits (D-AIH4-3), and no in-card approval (OD-40). | Only if OD-40/OD-41 change after a host documents UI-origin attestation. | open | `S4_AIH4_Implementation_Notes.md` |
| L-AIH4-4 | No `instance_fingerprint` (D-AIH4-5). | ISO-7 follow-up to `q_whoami`. | open | `S4_AIH4_Implementation_Notes.md` |
| L-AIH4-5 | The card's accessibility was not run through axe inside the host iframe. The PWA screens it links to were. | PV-UI. | open | `S4_AIH4_Implementation_Notes.md` |
| L-AIH-1 | 9021 needs register and disposition rows. | Next register revision. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-2 | No real host has connected. PV-AIH-01…08, PV-01…13 and PV-UI-* are `NOT_EXECUTED`. Platform facts PF-A*/PF-O* are not re-verified here. | AIH-5, after the Owner's PoC authorization. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-3 | No MCP App confirmation card (`ui://balnexa/cards/v1`). Proposals reach the Owner through the PWA review queue and the instructions' link rule only. | AIH-4. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-4 | The DCR limit is best effort: KV is eventually consistent, and the client address comes from `cf-connecting-ip`. | Durable counter if abuse appears. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-5 | A CIMD client's metadata is not refreshed after its first registration; a changed document needs a new client id. | With PV-AIH-02. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-6 | RFC 7009 revocation of a refresh token does not revoke its sibling access token, which expires within 15 minutes. Revocation in the PWA revokes everything. | 9009 follow-up. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-7 | Tool input schemas are the generated, permissive ones, and output schemas are generic (`{type: object}`) (L-CORE7-2). | Curated schemas for AI-exposed tools. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-8 | No CORS on the OAuth and MCP endpoints. Browser-hosted MCP clients cannot connect; Claude and ChatGPT connect from their servers. | Only if a browser client is qualified. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-9 | `documents.read` (document-class subset) and `tax.*` cannot be consented yet. | WP-DOC consent subset; WP-TAX (G-CRA-1). | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-10 | The equivalence envelope fields of AIH §2.3 are present only where the Core's queries return them. The Gateway adds nothing, which is what makes REST and MCP byte-identical. | Report families already carry the envelope (9013). | open | `S4_AIH_Implementation_Notes.md` |
| L-AIH-11 | Not deployed: no real instance URL and no TLS. Discovery documents were verified only on the test origin. | M0. | open | `S4_AIH_Implementation_Notes.md` |
| L-AIHR-1 | C4 checks each JSON value, not the concatenated text of a result. | Revisit if a tool ever returns digit lists that a host could join. | open | `S4_AIH_Review_Remediation_2026-11-12.md` |
| L-AIHR-2 | A token issued to a loopback client before `data_class` became `real` keeps working until it expires or is revoked. New authorizations are refused. | Revoke loopback connections as part of the change to `real` (INS-2 runbook). | open | `S4_AIH_Review_Remediation_2026-11-12.md` |
| L-AIHR-3 | 9023 needs register and disposition rows. | Next register revision. | open | `S4_AIH_Review_Remediation_2026-11-12.md` |
| L-CORE10-1 | 9020 needs register and disposition rows. | Next register revision. | open | `S4_CORE10_Implementation_Notes.md` |
| L-CORE10-2 | A REPLAY_MISMATCH or refused import is returned to the importer but not stored, by the 9010 design. The status list therefore shows no row for it, and the import result is the only record. | Consider an exception log in a later migration if the Owner wants these listed. | open | `S4_CORE10_Implementation_Notes.md` |
| L-CORE10-3 | Cross-currency handoff legs (fee/FX provenance) are shown as received but not editable in the PWA. The block carries what the database generated. | With the Draft-04 FX flows. | open | `S4_CORE10_Implementation_Notes.md` |
| L-CORE10-4 | Not deployed. Nothing has been checked with a real peer project. | M0 and the Owner's first real handoff. | open | `S4_CORE10_Implementation_Notes.md` |
| L-CORE7-1 | 9017, its five objects (`catalog_entries`, `wrk_catalog`, `wrk_binding_facts`, `wrk_defer_item`, `q_evidence_upload_target`), the generator and the overrides file need register and disposition rows (DOC-LINT L1 expects 15 S4 migr… | Next register revision | open | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-2 | Generated input schemas are permissive (D-CORE7-3); `output_schema`, `module_flags`, `masked_fields` and most descriptions are generic | Curated schemas for AI-facing tools with AIH-2 (overrides file) | open | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-3 | `/mcp` is the R1 static handler | AIH-2 | AIH-2 (PR #13) | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-4 | Tokens without a resource are accepted at any audience | AIH-1: make `resource` mandatory for new consents | AIH-1 (PR #13) | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-5 | Not executed on Cloudflare: Neon serverless driver, KV binding, Google JWKS fetch, R2 acceptance of the presigned URL, CORS | M0-A, M0-B | open | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-6 | The deploy rule (`min_worker_release` per migration checked by `install_activate_config`) is not implemented; the release manifest lists `work_kinds` only | INS-1 | open | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-7 | `GET /api/v1/artifacts/{id}` (O-4 proxy) is not part of this stage (artifact streaming off, OD-20) | CORE-8 | see S4_CORE8 notes | `S4_CORE7_Implementation_Notes.md` |
| L-CORE7-8 | A binding change in the database is noticed within 10 minutes (isolate cache) | By design (AE §6) | open | `S4_CORE7_Implementation_Notes.md` |
| L-CORE8-1 | 9018 and its four objects need register and disposition rows (as L-CORE7-1) | Next register revision | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-2 | Cloud stores are not implemented: GCS vault (`bnx-<project_id>-vault`, retention lock only with O-8), R2 artifact/evidence bucket; `LocalStore` only | M0-A / M0-E with the authorized identities | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-3 | No container image (`bnx-exec`, `bnx-backup`), no Cloud Run Job definitions, no launch of jobs by the Worker tick (the hourly `wrk_backup_due` → job launch) | M0-A | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-4 | The drill target provisioner is local; the Neon drill branch and its API key are not implemented | M0-E; SECURITY_REVIEW of the Neon key (D-9016-7) | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-5 | Document, import, index, mail and T1 jobs (`DOC_*`, `IMPORT_PARSE`, `INDEX_*`, `MAIL_*`, `T1_RENDER`) have no handler in the loop yet; the 9011 validator library exists. `INDEX_RENDER` / `T1_RENDER` have no promoter | WP-DOC (DOC-1/2), TAX-5 (Owner gate) | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-6 | `EVIDENCE_VERIFY` cannot report a **missing** copy: the 9016 item contract has no such result, so the job logs it and the object comes first in the next order | Add a `MISSING` result to `wrk_evidence_state` | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-7 | Usage rows (`cloud_usage`) are not reported by the jobs; billing-export reconciliation is M0-F | M0-F | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-8 | `local_date`/`tier` come from the lease-time order; a run that crosses local midnight between lease and start is rejected by the promoter (`TIER_MISMATCH`) and retried | Acceptable (hourly C2 schedule) | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE8-9 | Drive second copy (archive writer) is not part of this stage | DOC-1 / PV-DRV-01 (Drive identity review) | open | `S4_CORE8_Implementation_Notes.md` |
| L-CORE9-1 | 9019 needs register and disposition rows (as 9017/9018). | Next register revision. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-2 | Not deployed. There is no `wrangler.toml` assets binding, no real Google client id, and nothing has run on a phone or a real browser with Google Identity Services. | M0-A/B; the Owner's device check. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-3 | Item 7 "activity, correction, approval and evidence audit trails": no catalog query returns the audit chain. The PWA shows R31 evidence trace, R30, backup/restore and cost status, but not a general audit-trail list. | Add `q_audit_trail` (read-only, tier 0) in a later migration. | CORE-10 (9020, PR #12) | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-4 | The Draft-04 onboarding screens (C5: progress counters, next decision) are served by the generic forms (`onboarding_*`, `q_onboarding_job`), not by a dedicated progress screen. | With WP-DOC / C5 work. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-5 | Quick Entry covers same-currency expense, income and transfer only (D-CORE9-6). Card, FX, investment and loan entries use the generic forms; there is no evidence upload widget yet (`register_evidence` and `evidence_upload_target`… | CORE-9 follow-up after O-7. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-6 | Offline means the shell only: no IndexedDB queue or upload resume (`apps/pwa` M2 item). | M2. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-7 | Server error texts are localized by code. Free-text database details are not shown, by design. Generic-form field labels without a catalog key fall back to the English key. | Extend `field.*` keys as screens are dedicated. | open | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-9 | The database's audit guard scans the client-chosen `idempotency_key`; a client whose keys contain digit runs (an AI host, a script) is randomly refused (F-CORE9-1). | Exempt `idempotency_key` from the C2 scan, provided it matches the key pattern and is stored only as a hash, or have the Gateway normalize… | CORE-10 (PR #12) | `S4_CORE9_Implementation_Notes.md` |
| L-CORE9-8 | AT-NOAI covers the eight items with representative tasks, not every one of the 114 tasks. AT-NOAI-09/10, the remaining TST-3 rows, and CORE-10's dedicated handoff screens are not done here. | TST-3, CORE-10. | open | `S4_CORE9_Implementation_Notes.md` |

## Appendix E — Test inventory (generated)

| Suite | Test IDs |
|---|---|
| `tests/py/run_g0.py` (40) | AT-MIG-01, AT-MIG-02, AT-MIG-03, AT-MIG-04, AT-MIG-05, AT-MIG-06, AT-MIG-07, AT-MIG-08, AT-BAL-01, AT-BAL-02, AT-BAL-03, AT-BAL-04, AT-BAL-05, AT-MUT-01, AT-CMD-01, AT-CMD-02, AT-CONC-01, AT-CONC-02, AT-CMD-03, AT-CMD-04, AT-CMD-05, AT-PLAN-01, AT-PLAN-02, AT-PLAN-03, AT-CONC-03, AT-FAULT-01, AT-CMD-06, AT-CMD-07, AT-SNAP-03, AT-SNAP-04, AT-SNAP-05, AT-OWN-05, AT-OWN-06, AT-SRC-01, AT-SRC-02, AT-EVP-11, AT-ARC-02, AT-Q-01, AT-BAK-01, AT-BAK-02 |
| `tests/py/run_s4_core1.py` (12) | AT-MIG-09, AT-MIG-11, AT-MIG-11b, AT-MIG-11c, AT-MIG-10, AT-ISO-03, AT-CFG-14, AT-CFG-15, AT-PLAN-04-DB, AT-EV-01-DB, AT-SET-01, AT-INV-01 |
| `tests/py/run_s4_core2.py` (12) | AT-CMD-06x, AT-REG-01-03,09, AT-REG-07,08, AT-REG-15, AT-REG-04-06, AT-REG-17, AT-REG-18, AT-POL-01, AT-FLG-01-09, AT-FLG-10, AT-FLG-11, AT-MUT-02 |
| `tests/py/run_s4_core3.py` (9) | AT-ECON-01-04, AT-ECON-05, AT-PLAN-06,07, AT-MUT-03, BB-OAUTH-01x,04, AT-CMD-04x, BB-OAUTH-02, BB-OAUTH-03, AT-AIH-13-15 |
| `tests/py/run_s4_core4.py` (11) | AT-PLAN-04, AT-PLAN-05, AT-PLAN-05b, AT-REV-01-07, AT-EXEC-01, AT-EXEC-02, AT-EML-01-04, AT-EML-06,COV, AT-MAIL-02-04, AT-HX-01-08, AT-ACP-01-08 |
| `tests/py/run_s4_core5.py` (8) | AT-SIN-11, AT-SIN-12-15b, AT-SIN-08a, AT-MUT-04, AT-SIN-22-27, AT-SIN-16,30, AT-SIN-C4, AT-SIN-C6 |
| `tests/py/run_s4_core6.py` (8) | AT-SIN-01-04, AT-SIN-05,07, AT-SIN-06, AT-SIN-13, AT-SIN-29, AT-SIN-30, AT-SIN-31, AT-SIN-11c |
| `tests/py/run_s4_core7.py` (5) | AT-G0R-01, AT-G0R-02, AT-G0R-03, AT-G0R-04, AT-G0R-05 |
| `tests/py/run_s4_core8.py` (8) | AT-R28-GOLD, AT-R28-NEG, AT-R28-HIST-01, AT-R28-05,20, AT-R28-09, AT-R28-11, AT-R28-CONS, AT-R28-FAM |
| `tests/py/run_s4_core9.py` (4) | AT-FX-01, AT-INVL-01, AT-P0-R19, AT-9012b-CAT |
| `tests/py/run_s4_core10.py` (7) | AT-OBS-01, AT-STP-01, AT-RCN-01, AT-RCN-02, AT-RCN-03, AT-RCX-01, AT-9012c-CAT |
| `tests/py/run_s4_core11.py` (5) | AT-MR-01, AT-MR-02, AT-ONB-01, AT-IMP-PAY-01, AT-9012d-CAT |
| `tests/py/run_s4_core12.py` (8) | AT-F1, AT-F2-F3, AT-P0-R09, AT-F4-F5-F6, AT-F7-P0, AT-RPT-STALE, AT-ARCH-ACL, AT-9013-CAT |
| `tests/py/run_s4_core13.py` (11) | AT-BAK-04, AT-BAK-03, AT-BKP-REC, AT-BKP-DRILL, AT-BKP-12-16, AT-BKP-13, AT-BKP-17-19, AT-ANCHOR-01, AT-BKP-10, AT-SPEND-ADM, AT-BKP-PRIV |
| `tests/py/run_s4_core14.py` (5) | AT-CAT-01, AT-ISO-BF, AT-B7-01, AT-Q-02-DB, AT-EV-01-DB |
| `tests/py/run_s4_core15.py` (7) | AT-EXEC-03, AT-RND-01, AT-BAK-01-EXEC, AT-BKP-DRILL-EXEC, AT-EVV-01, AT-EXEC-04, AT-EXEC-02-STG |
| `tests/py/run_s4_core16.py` (3) | AT-PWA-LA-01, AT-AUD-TRAIL-01, AT-CAT-02 |
| `tests/py/run_s4_core17.py` (5) | AT-AIH-REG-01, AT-AIH-CLI-01, AT-AIH-PROV-01, AT-AIH-CONN-01, AT-AIH-ENV-01 |
| `tests/py/run_s4_core_9011r.py` (11) | FP-SIN-01, AT-9011R-DET, AT-9011R-E2E, AT-9011R-VAL, AT-9011R-07, AT-9011R-08, AT-9011R-09, AT-SIN-17, AT-SIN-19, AT-SIN-20, AT-SIN-21 |
| `tests/blackbox/api.test.mjs` (22) | BB-AUTH-01, BB-API-01, BB-API-02, BB-OAUTH-01, BB-PLAN-01, BB-PLAN-02, BB-EXEC-01, BB-CAT-01, BB-SCHEMA-01, BB-ISO-04, BB-B7-01, BB-UP-01, BB-EXEC-02, AT-AIH-06, BB-OAUTH-03, AT-AIH-07, BB-OAUTH-02, AT-AIH-04, AT-AIH-06b, AT-CONF-04, RV-AIH-01…12, BB-AUTH-02 |
| `tests/blackbox/unit.test.mjs` (10) | UT-PRESIGN-01, UT-PRESIGN-02, UT-SCHEMA-01, UT-BIND-01, UT-JWKS-01, UT-DISPATCH-01, UT-EXEC-SCHEMA-01, UT-MCP-01, UT-OAUTH-01, UT-CARD-01 |
| `tests/pwa/pwa.test.mjs` (19) | AT-UI-00, AT-NOAI-01, AT-NOAI-02, AT-NOAI-03, AT-NOAI-04, AT-NOAI-05, AT-NOAI-06, AT-NOAI-07, AT-NOAI-08, AT-NOAI-07b, AT-IDEM-01, AT-MENU-01/02, AT-CAL-01, AT-UI-01, AT-A11Y-01/02, AT-UI-02, AT-AIH-10, AT-CONF-01/02, AT-NOAI-00 |
