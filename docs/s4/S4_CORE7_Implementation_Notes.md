# S4 CORE-7 — Gateway: catalog, schema validation, binding checks, health, uploads, dispatcher — Implementation notes

Status: implemented on branch `s4/core-7` (from `main` at `fff6db5`): Worker code in `apps/worker/src/`, database support in
`db/migrations/9017_s4_gateway_catalog_binding.sql`, catalog generator `tools/s4/catalog_build.py`.
Evidence grade: `AUTHOR_RUNTIME_EVIDENCE` (author's local runs on PG16.15 and PG17.11 with the Node adapter; CI on the PR); not
independently reviewed. Cloudflare runtime behaviour (Neon serverless driver, KV binding, Google JWKS endpoint, R2) is not
executed here (M0-A/M0-B).

Authority: WP matrix V1.2 row CORE-7 ("R1 routes retained; catalog generation from pg_proc comments; JSON-Schema validation;
B1/B2/B3/B7/B8 checks; health; presigned uploads; Cron/KV dispatcher"); UA V1.2 §8 (schema-qualified dispatch from the catalog,
`queue_generation`, JWKS with kid rotation) and §9.1 (unknown kinds never `done`; deploy rule); AIH V1.2 §2 (bnx-tools/1.0 from
`COMMENT ON FUNCTION`, DD-21; risk classes; equivalence contract OR-AIH-04); AE V1.2 §6 and Amendment 03 §5.2 (B1–B9); disposition
OBJ-258…OBJ-271 (`jwt.js`, `dispatch.js`, `index.js`, routes); acceptance BB-AUTH-01/02, BB-API-01/02, BB-PLAN-01/02, AT-AIH-01/05,
AT-ISO-04, AT-EV-01, AT-Q-02.

## What was built

| Part | Content |
|---|---|
| Catalog `bnx-tools/1.0` | One entry per REST-callable function (every `cmd_*`/`q_*` that `bnx_app` may execute: 113), stored as `COMMENT ON FUNCTION` in 9017 and read by the Gateway through `bnx.wrk_catalog()` (entries, SHA-256 digest, list of uncatalogued functions). Entry fields per AIH §2: `name, version, kind, rest, core_function` (schema-qualified), `risk_class, tier, scopes, legacy, needs_ac_subset, channels, module_flags, input_schema, output_schema, errors, idempotency, masked_fields, evidence_citation, mcp{…}, ui_profile, description` |
| Generator `tools/s4/catalog_build.py` | Derives every entry from the function itself: tier = highest N in `bnx.require(a, N)` (incl. `case … then N`) or a helper tier listed in `db/catalog/bnx-tools-1.0.overrides.json`; an underivable tier is an error, never a default. Scopes, tool name, legacy flags and subset from `bnx.function_scope`. Input properties = every key the body reads from its jsonb argument, typed from a direct cast (`uuid`, `date`, `timestamptz`, integers, `numeric`, `boolean`, arrays). `--write` emits the block between the `@@CATALOG` markers; `--check` re-derives and fails on drift (run by AT-CAT-01 on every CI run) |
| Router (`index.js` MODIFY) | Binding gate before every route except `GET /api/v1/health`; `POST /api/v1/commands|queries/{name}` resolves through the catalog (unknown → 404), checks the credential (public entries excepted), CSRF for commands, injects `Idempotency-Key`, validates the body against `input_schema` (422 `VALIDATION_FAILED` with the failing path), then calls the entry's schema-qualified `core_function`; `queue_generation` KV hint unchanged. R1 OAuth, `/exec/v1/*` and `/mcp` handlers unchanged |
| `GET /api/v1/catalog` | `sys.catalog`: live credential required; a session sees every entry, a bearer only MCP entries (RC-READ/RC-DRAFT) |
| `GET /api/v1/health` | `q_health` + release + binding result (`ok`, failed check IDs); answers while a binding check fails; reveals no identity value |
| `POST /api/v1/uploads` | Presigned direct-to-R2 PUT (15 min) for an `upload_pending` evidence file the caller registered (`bnx.q_evidence_upload_target`, 9017); `503 UPLOADS_NOT_CONFIGURED` until R2 settings exist (gate O-7); session and same origin only |
| Binding checks (`binding.js`) | B1 `BNX_PROJECT_ID`/`BNX_INSTANCE_UID` = `instance_identity`; B2 `BNX_CONFIG_DIGEST` ∈ ACTIVE/PENDING_DEPLOY digests; B3 database heads inside the release range (`release.js`: core 0109, extension 9016…9017 = N-1…N); B8 `BNX_MODULES` = ACTIVE flags. Facts from `bnx.wrk_binding_facts()` (9017, `bnx_worker` only). Cached per isolate 10 min when OK, 60 s after a failure. B1/B2/B3 → `503 BNX_BINDING_MISMATCH`, B8 alone → `503 BNX_FLAG_BINDING_MISMATCH`; the scheduled dispatcher refuses too |
| B7 (9017 `resolve_actor` MODIFY) | A bearer credential carries the Gateway's audience (`BNX_RESOURCE`); a token issued for another resource is `UNAUTHENTICATED` |
| JWKS (`jwt.js` MODIFY) | `jwksResolver()`: Google's key set cached in isolate memory for its `max-age` (≤ 24 h); an unknown `kid` refetches at most once per 60 s, so a rotated key works without a redeploy and forged kids cannot hammer the endpoint. A static set (tests) still works |
| Presigning (`r2presign.js`) | AWS SigV4 query-string presigning (`UNSIGNED-PAYLOAD`, signed header `host`), R2 region `auto`; equal to the AWS documented example |
| Dispatcher (`dispatch.js` MODIFY) | Known kinds from a table (`plan.execute`, `staging.promote`; the release manifest lists the same); an unknown kind is deferred by `bnx.wrk_defer_item` (9017) — back-off 5 min × 2^(attempts−1), at most 3 h; Owner alert after 3 attempts, once per kind and day; never `done`, never `dead`. `shouldReadNeon`/`isBackstopTick` byte-identical |
| Schema validator (`schema.js`) | JSON Schema subset used by the catalog (`type`, `properties`, `required`, `additionalProperties`, `enum`, `pattern`, lengths, bounds, `items`, item counts, formats `uuid`/`date`/`date-time`); unknown keywords are rejected when the catalog loads, never ignored |

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's delegation of 2026-11-11. Each is reversible: nothing is deployed and no persistent instance exists.

| ID | Decision | Reason |
|---|---|---|
| D-CORE7-1 | Add migration **9017** (`s4_gateway_catalog_binding`) although the V1.2 register lists exactly 9002–9016 and CORE-7 as "code" | The binding checks cannot fail closed without database support: no runtime role can read the instance identity or the ACTIVE config without a member credential, and `q_health` deliberately reveals nothing. The catalog is specified as `COMMENT ON FUNCTION` metadata, which only a migration can write. 9017 follows 9016, so the runner's prefix rule holds; L-9016-8 for 9014/9015 is unchanged |
| D-CORE7-2 | Catalog entries are **generated** from the function bodies, `bnx.function_scope` and a small explicit overrides file, and stored as comments; `--check` fails on drift | DD-21's purpose (PWA, REST and MCP cannot drift) is enforced mechanically, and a new or changed function without a matching entry fails CI (AT-CAT-01) |
| D-CORE7-3 | Generated input schemas are permissive: properties typed only where the body casts the value, `additionalProperties: true`, no `required`; `idempotency_key` is not in any schema | The database stays the validator of record. Stricter schemas would reject inputs the database accepts today; `idempotency_key` errors must keep the database's own code `IDEMPOTENCY_KEY_REQUIRED` (AT-AIH-05) |
| D-CORE7-4 | Tool names: `function_scope.note` where it is a dotted tool name, the AIH §2.2 name for 14 entries via the overrides file, else `pwa.<rest name>`; names must be unique | Keeps the 9009 catalog rows authoritative and follows AIH §2.2 where it names a tool |
| D-CORE7-5 | A failed binding check closes every route except health, reads included, and the dispatcher | AE §6: "only `q_health` answers"; stricter than Amendment 03's "writes refused" |
| D-CORE7-6 | Release range B3 = core `0109`, extension `9016`…`9017` | IL V1.2 §4 `supports_schema_from = N-1` |
| D-CORE7-7 | B7 is checked inside `resolve_actor` with the audience the Gateway sends; tokens issued without a resource stay accepted | Only the database knows a token's resource. 9009 made `resource` optional, and R1 flows issue tokens without it; making it mandatory belongs to AIH-1 (L-CORE7-4) |
| D-CORE7-8 | `/mcp` keeps the R1 handler; the catalog-generated MCP server is AIH-2 | AIH-2 depends on AIH-1 and CORE-7; BB-OAUTH-01 still asserts the R1 tool set |
| D-CORE7-9 | Presigned PUT signs only `host`, valid 15 minutes, and the upload route is gated on R2 settings (O-7) | R2 enforcement of checksum headers on presigned PUTs is unverified (Cost F-17 note); integrity is proven by the Executor's re-hash, as today |
| D-CORE7-10 | Deferred kinds back off to at most 3 h (one backstop period) | A deferred item never wakes Neon (the queue counts as drained), so a longer cap only delays recovery; the simulation measures ≤ 2.75 h after a redeploy (bound 6.1 h) |
| D-CORE7-11 | An absent or unparsable body is `{}` (R1 behaviour); a JSON array or scalar body is `422 VALIDATION_FAILED` | Compatibility with existing clients; non-object input can never be valid |

## Test results — `AUTHOR_RUNTIME_EVIDENCE`

| Suite | Tests | What they prove |
|---|---|---|
| `tests/py/run_s4_core14.py` (new, 5) | AT-CAT-01, AT-ISO-BF, AT-B7-01, AT-Q-02-DB, AT-EV-01-DB | 113 entries = every REST-callable function, 0 uncatalogued, generator `--check` clean, unique names, MCP only for RC-READ/RC-DRAFT entries of `function_scope`, digest equal to the binding facts; binding facts correct and worker-only; B7 audience; deferral back-off 5…160 min, one alert, never done/dead, queue drained; upload target only for the registering member's `upload_pending` file, no oracle, refused on an AI connection |
| `tests/blackbox/api.test.mjs` (+5) | BB-CAT-01, BB-SCHEMA-01, BB-ISO-04, BB-B7-01, BB-UP-01 | catalog route per credential kind; REST and MCP `structuredContent` identical (AT-AIH-01); schema errors `422 VALIDATION_FAILED` with path, database-detected errors with the same code, `IDEMPOTENCY_KEY_REQUIRED` from the database (AT-AIH-05); B1/B2/B8 mismatches → 503 on every route and in the dispatcher, health 503 without identity values; B7 at two Gateways; presigned upload gate, URL, ownership, credential and origin rules (AT-EV-01) |
| `tests/blackbox/unit.test.mjs` (new, 6) | UT-PRESIGN-01/02, UT-SCHEMA-01, UT-BIND-01, UT-JWKS-01, UT-DISPATCH-01 | SigV4 equal to the AWS documented example; R2 URL shape; validator cases; B1/B2/B3/B8 matrix incl. a database newer than the release and older than N-1; kid rotation and refetch limits; an unknown kind is deferred and never completed |
| `tests/sim/dispatch_sim.mjs` (+1 scenario) | AT-Q-02 rollback | Worker rollback hides a kind for 2 days: the R1 policy loses every item of that kind (negative control, 13/13); the CORE-7 policy loses none and processes them ≤ 2.75 h after the redeploy |
| Existing suites | all | unchanged and green behind the new Gateway (8 R1 black-box tests, R1 suite, S4 suites 1…13) |

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-CORE7-1 | 9017, its five objects (`catalog_entries`, `wrk_catalog`, `wrk_binding_facts`, `wrk_defer_item`, `q_evidence_upload_target`), the generator and the overrides file need register and disposition rows (DOC-LINT L1 expects 15 S4 migrations) | Next register revision |
| L-CORE7-2 | Generated input schemas are permissive (D-CORE7-3); `output_schema`, `module_flags`, `masked_fields` and most descriptions are generic | Curated schemas for AI-facing tools with AIH-2 (overrides file) |
| L-CORE7-3 | `/mcp` is the R1 static handler | AIH-2 |
| L-CORE7-4 | Tokens without a resource are accepted at any audience | AIH-1: make `resource` mandatory for new consents |
| L-CORE7-5 | Not executed on Cloudflare: Neon serverless driver, KV binding, Google JWKS fetch, R2 acceptance of the presigned URL, CORS | M0-A, M0-B |
| L-CORE7-6 | The deploy rule (`min_worker_release` per migration checked by `install_activate_config`) is not implemented; the release manifest lists `work_kinds` only | INS-1 |
| L-CORE7-7 | `GET /api/v1/artifacts/{id}` (O-4 proxy) is not part of this stage (artifact streaming off, OD-20) | CORE-8 |
| L-CORE7-8 | A binding change in the database is noticed within 10 minutes (isolate cache) | By design (AE §6) |
