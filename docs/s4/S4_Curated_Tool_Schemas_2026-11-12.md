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
| Overrides `schemas.<function>.output` | Output schemas for the 8 tools AI hosts use most: the six draft tools (`create_transaction`, `create_transfer`, `revise`, `validate`, `withdraw`, `get_for_confirmation`), `fin.balances.as_of` and `sys.whoami`. They give the fields, types, formats and descriptions (for example: cite `ledger_version`; `plan_hash` binds the approval; a `null` amount means `status` is not `ok`) |
| `catalog_build.py` | An output schema must be `type: object` and use only the keywords the Gateway validator knows. Every `required` key must have a property. Otherwise the generator fails |
| Gateway | `binding.js` checks output schemas when it loads the catalog. `mcp.js` validates every successful result. A result that does not conform becomes the tool error `OUTPUT_SCHEMA_MISMATCH` with the JSON path only, and the log line has the tool, path and reason, never the value |
| Migration 9032 | The catalog delta block only (8 entries). Release 0.8.7-p2 (extension range 9031–9032) |

### Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-OUT-1 | Only these 8 tools get output schemas now. The report tools (F1–F7, R09, R28, R31 and the rest) keep `{type: object}` until each has a contract fixture | A wrong schema fails closed (D-OUT-2), so each schema needs a test that exercises its tool. The draft and balance tools have one (AT-OUT-01). The report results are larger, and their nested shapes are covered by only one or two samples in the current suites |
| D-OUT-2 | A non-conforming result is refused, not passed through or stripped | The MCP rule is a MUST. A host that validates would reject the result anyway, and a silent pass-through would hide a contract break. Error results (`isError`) are not validated, per the specification |
| D-OUT-3 | `required` lists keys the function always builds (from `jsonb_build_object` in the body). Every value that the body can make null is typed with `null`. `additionalProperties` stays true | The database is the source of the shape. New keys must not break hosts |

Supersedes D-SCH-3.

### Tests
- **AT-OUT-01** (`run_s4_core19.py`): 23 calls by the Owner in the PWA, by an AI connection over MCP and by a member. They cover all 8 tools, including an idempotent replay, `ai_draft` and `member_draft`, a transfer, a revision, a validation, a withdrawal and a withdrawn draft. Every result conforms. The catalog in the database carries the overrides' schemas. The generator refuses an unsupported keyword and a dangling `required` key.
- **UT-MCP-OUT-01:** a conforming result is returned as is. A wrong type and a missing required key each give `OUTPUT_SCHEMA_MISMATCH` with the path. The value appears neither in the reply nor in the log. A derived `{type: object}` entry still accepts everything.
- **BB-OAUTH-01**, extended: over HTTP, `tools/list` advertises the schemas, and the real results of `fin_balances_as_of`, `sys_whoami`, `fin_draft_create_transaction` and `fin_draft_withdraw` conform.

## Remaining

- The MCP-reachable commands other than the draft tools keep derived input schemas: they are RC-ADMIN or PWA-first.
- Output schemas for the report tools, one contract fixture at a time (D-OUT-1).
