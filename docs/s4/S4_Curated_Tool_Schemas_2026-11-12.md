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

## Remaining

- The other 90 MCP-reachable entries keep derived schemas.
- No output schemas are curated yet.
