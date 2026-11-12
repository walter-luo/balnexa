# Balnexa S4 phase 2.8 — curated tool schemas (migration 9026)

`DRAFT — AI-generated`. Closes the first part of L-CORE7-2 / L-AIH-7.

## What changed

| Part | Content |
|---|---|
| `db/catalog/bnx-tools-1.0.overrides.json` → `schemas` | Hand-written input schemas and descriptions for the seven tools AI hosts use most: `fin.draft.create_transaction`, `create_transfer`, `revise`, `validate`, `withdraw`, `get_for_confirmation`, and `fin.balances.as_of`. They carry types, formats, the economic-type enum, required fields and plain-language descriptions |
| `tools/s4/catalog_build.py` | A curated schema must name exactly the keys the function body reads. Otherwise the generator fails, so the curated and derived schemas cannot drift. The entry's `provenance` becomes `curated` and its description comes from the curated entry |
| Migration 9026 | The catalog delta block only (7 entries); no function changes |
| Gateway `schema.js` | `description` is accepted as an annotation keyword |

## Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-SCH-1 | 9026 is outside the V1.2 register | As for 9017–9025 |
| D-SCH-2 | `additionalProperties` stays true, and the required lists mirror only the body's own `VALIDATION_FAILED` checks | The database stays the validator of record, and error codes are identical on every surface (AT-AIH-05) |
| D-SCH-3 | The output schemas stay `{type: object}` | The results are versioned by the database. Curating outputs needs a contract test per tool, which comes next |

## Tests

- `catalog_build --check`: OK, 116 entries.
- BB-OAUTH-01 extended: `tools/list` shows the required fields, the enum and the description, and a call missing a required field gets `VALIDATION_FAILED`.
- Full regression: see the PR.

## Second part (migration 9031)

Every MCP-reachable read tool (28 queries) now has a plain-language description of the tool and of each input. Types are unchanged and no `required` lists were added, so the database still reports missing inputs with its own codes.

## Third part (migration 9032): output schemas

The MCP specification says that when a tool declares an `outputSchema`, every successful `structuredContent` must conform to it.

| Part | Content |
|---|---|
| Overrides `schemas.<function>.output` | Output schemas for 18 tools:
- the six draft tools (`create_transaction`, `create_transfer`, `revise`, `validate`, `withdraw`, `get_for_confirmation`), `fin.balances.as_of` and `sys.whoami`, in full;
- the report families F1–F7, R09 (cash flow), R30 (review queue) and R31 (evidence trace). For these, the common envelope built by `bnx.rpt_envelope` is required: `report`, `ledger_version`, `as_of`, `reporting_currency`, `fx_policy`, `fx_snapshot_ref`, `grants_digest`, `scope_warnings`, `rounding`. Each family's own keys are typed and nullable.

The schemas give the fields, types, formats and descriptions. For example: cite `ledger_version`; `plan_hash` binds the approval; a `null` amount means `status` is not `ok`; non-empty `scope_warnings` means a partial view |
| `catalog_build.py` | An output schema must be `type: object` and use only the keywords the Gateway validator knows. Every `required` key must have a property. Otherwise the generator fails |
| Gateway | `binding.js` checks output schemas when it loads the catalog. `mcp.js` validates every successful result. A result that does not conform becomes the tool error `OUTPUT_SCHEMA_MISMATCH` with the JSON path only, and the log line has the tool, path and reason, never the value |
| Migration 9032 | The catalog delta block only (18 entries). Release 0.8.7-p2 (extension range 9031–9032) |

### Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-OUT-1 | Report rows and other nested report structures are typed only as array or object, never field by field. The remaining read tools (R28 loan position, FX rate, investment position, snapshots, onboarding, evidence access and others) keep `{type: object}` until each has a contract fixture | A wrong schema fails closed (D-OUT-2), so every schema needs a test that exercises its tool (AT-OUT-01). The nested report shapes appear only once or twice in the current suites. Before committing, the schemas were also checked offline against every result of these tools captured during a full PG17 suite run (74 results, 0 violations after two type fixes) |
| D-OUT-2 | A non-conforming result is refused, not passed through or stripped | The MCP rule is a MUST. A host that validates would reject the result anyway, and a silent pass-through would hide a contract break. Error results (`isError`) are not validated, per the specification |
| D-OUT-3 | `required` lists keys the function always builds (from `jsonb_build_object` in the body). Every value that the body can make null is typed with `null`. `additionalProperties` stays true | The database is the source of the shape. New keys must not break hosts |

Supersedes D-SCH-3.

### Tests
- **AT-OUT-01** (`run_s4_core19.py`): 45 calls by the Owner in the PWA, by an AI connection over MCP and by a member. They cover all 18 tools, including an idempotent replay, `ai_draft` and `member_draft`, a transfer, a revision, a validation, a withdrawal, a withdrawn draft, and F1 with a reporting currency that has no rate. Every result conforms. The catalog in the database carries the overrides' schemas. The generator refuses an unsupported keyword and a dangling `required` key.
- **Host-side check (one-off, not in CI):** the official MCP TypeScript SDK 1.32.2 validates `structuredContent` against `outputSchema` in its client (`AjvJsonSchemaValidator`: Ajv, non-strict, with ajv-formats). Its validator accepted all 119 captured results: the 45 from AT-OUT-01 and the 74 from the full-suite capture. So a host built on that SDK will not reject Balnexa's results.
- **UT-MCP-OUT-01:** a conforming result is returned as is. A wrong type and a missing required key each give `OUTPUT_SCHEMA_MISMATCH` with the path. The value appears neither in the reply nor in the log. A derived `{type: object}` entry still accepts everything.
- **BB-OAUTH-01**, extended: over HTTP, `tools/list` advertises the schemas, and the real results of `fin_balances_as_of`, `sys_whoami`, `fin_draft_create_transaction` and `fin_draft_withdraw` conform.

## Fourth part (migration 9033)

Output schemas for 5 more read tools: `fin.fx.rate`, `reports.snapshot.list`, `reports.snapshot.status`, `reg.institutions.search` and `handoff.status`. The FX rate schema states that `rate` is a decimal string to quote, never to compute; that it is null only when `quality` is `MISSING`; and it gives the `quality` enum.

- AT-OUT-01 now also calls them, as the Owner and as an AI connection with `reports.read` and `handoff.read`. The calls cover a missing rate, an identity rate, a fresh snapshot and a registry search.
- The MCP SDK validator accepted 140 captured results, 0 invalid.
- Release 0.8.9-p2 (extension range 9032–9033). In total, 23 tools have curated output schemas.

## Fifth part (migration 9034) and the output contract in every suite

**Remaining read tools.** Output schemas for the 12 remaining MCP read tools: account proposals, balance observations, card fee progress, evidence access, investment position, onboarding job, R28 loan position, reconciliation coverage and exceptions, snapshot replay and artifact, and transfer matching.
- They list each tool's top-level keys, typed and nullable, with no required keys and plain descriptions where a field needs care (for example a `refusal` or `partial_view` to report).
- Every curated tool now has an output schema. Release 0.9.0-p2 (extension range 9033–9034).

**Output contract (AT-OUT-02).** `tests/py/jsonschema_lite.py` holds the validator port and `check_output`. The harness calls it on every `bnx_app` call of a tool with an output schema, in **every** Python suite, so the whole regression is the contract test: every fixture of every suite exercises the schemas, including the loan, card, investment, onboarding and snapshot scenarios. A mismatch fails the calling test with the path and no value. AT-OUT-01 keeps calling the field-level tools explicitly.

## Remaining

- The MCP-reachable commands other than the draft tools keep derived input schemas: they are RC-ADMIN or PWA-first.
- Field-level schemas for report rows and for the 9034 tools, one at a time; the harness contract already covers them (D-OUT-1).
