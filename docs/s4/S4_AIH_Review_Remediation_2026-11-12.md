# S4 AIH review remediation (RV-AIH-01…14) — 2026-11-12

**Status:** implemented on branch `s4/aih-r`, stacked on `s4/aih-4` (PR #14).

**Evidence grade of the fixes:** `AUTHOR_RUNTIME_EVIDENCE`. The review itself is graded `SAME_FAMILY_VERIFICATION`: an independent agent without authoring context, of the same model family.

**Review:** `docs/s4/reviews/AIH_REVIEW_REPORT_2026-11-12.md`, produced from the prompt `docs/s4/reviews/AIH_REVIEW_PROMPT.md` against `s4/aih-4` at `5612c6b`. It found 0 Critical, 0 High, 3 Medium, 6 Low and 4 Info findings, and records its covered cases with no findings. The reviewer's regression was green.

## Disposition

| ID | Sev. | Finding (short) | Disposition | Where | Test |
|---|---|---|---|---|---|
| RV-AIH-01 | Medium | `cmd_approve_ai_connection` was reachable through REST and the PWA task, bypassing every AIH-1 consent rule (resource, consentable scopes, subset). | **Fixed.** The Gateway refuses that command on the generic route (`403 USE_OAUTH_AUTHORIZE`); consent is created only by `POST /oauth/authorize`. The PWA Settings task "Approve AI connection" is removed from `menu.json`. The Gateway is the only holder of `bnx_app` (UA §8), so no other path reaches the Core. | `index.js`, `menu.json` | RV-AIH test: a direct REST consent naming `documents.read` → 403 |
| RV-AIH-02 | Medium | Guard C4 ran only on `/mcp`; an AI bearer on `/api` received unscanned results. | **Fixed.** C4 runs on every Business-API result for a bearer credential: `422 SIN_CANDIDATE_REFUSED`, audited through `wrk_audit_sin_refusal` with rule codes only. One function (`refuseSin`) serves both surfaces. | `index.js`, `mcp.js` | AT-SIN-C4 extended: MCP and REST refused, two audits per value, clean result passes |
| RV-AIH-03 | Medium | MCP invented a random idempotency key, so every retry made a new draft; REST required a key. | **Fixed.** Command tools declare `idempotency_key` (8–80 characters, required) in their `inputSchema`. An absent key reaches the Core, which answers `IDEMPOTENCY_KEY_REQUIRED` exactly as on REST. A retry with the same key replays. | `mcp.js` | RV-AIH test: same code on both surfaces; same key → same `plan_id` |
| RV-AIH-04 | Low | The card accepted messages from any frame. | **Fixed.** The card ignores every message whose source is not the frame that embeds it. | `card.js` | PWA AT-CONF-01/02 via the card: a sibling frame's forged draft is ignored |
| RV-AIH-05 | Low | Keys outside the normalized form reached the database raw. | **Fixed.** A key that is not a string of 8–80 printable ASCII characters is refused on both surfaces (`VALIDATION_FAILED`, field `idempotency_key`). Every accepted key is normalized, so no client key is stored raw (D-CORE10-3 now holds without exception). | `http.js` (`KEY_RE`), `index.js`, `mcp.js` | RV-AIH test: short, space, fullwidth digits, number |
| RV-AIH-06 | Low | RFC 7009 revocation without `client_id` answered 200 and revoked nothing. | **Fixed.** A missing `token` or `client_id` gets `400 invalid_request`. | `oauth.js` | RV-AIH test |
| RV-AIH-07 | Low | A loopback DCR client stayed usable after `data_class` became `real`. | **Fixed (migration 9023).** `authn_oauth_client.redirect_ok` re-applies the host-profile rule on the current environment. The Gateway checks at `GET /oauth/authorize`, at describe/deny and again at approval. Tokens already issued are not withdrawn (L-AIHR-2). | `9023`, `oauth.js` | AT-AIH-ENV-01 (both majors) |
| RV-AIH-08 | Low | No body limit on `/oauth/register`; NUL gave 500; the full name was echoed back. | **Fixed.** Bodies over 16 KB get 413. `client_name` must be 1–100 characters with no control, format or bidirectional characters, else `invalid_client_metadata`. Local refusals do not use up the rate budget. Refusals by the Core still do, by design (no probing for free). | `oauth.js` | RV-AIH test |
| RV-AIH-09 | Low | A DCR `client_name` could impersonate another host or carry bidi overrides. | **Fixed.** Names with bidi or format characters are refused, and a CIMD name of that kind is dropped. The consent screen now leads with the verified host, derived from the redirect allowlist, and marks the client's own name as unverified. | `oauth.js`, i18n `consent.who` | PWA AT-AIH-10; RV-AIH test |
| RV-AIH-10 | Low | An object tool name, a scalar list field and a malformed consent subset gave 500. | **Fixed.** A non-string tool name gets `-32602`. Data exceptions (SQLSTATE class 22) map to `VALIDATION_FAILED` on REST and MCP. The consent subset must be a list of UUIDs, scopes non-empty and unique. | `mcp.js`, `index.js`, `oauth.js` | RV-AIH test |
| RV-AIH-11 | Info | C4 scans values, not the serialized text. | **Accepted as a limit (L-AIHR-1).** No reachable result was found. Scanning the serialized text would refuse ordinary integer arrays. | — | — |
| RV-AIH-12 | Info | "Unknown tool" echoed the host's input. | **Fixed.** The message is now a fixed `Unknown tool`. | `mcp.js` | RV-AIH test |
| RV-AIH-13 | Info | L-AIH-6 and L-AIH-4 behave as documented. | Unchanged; still documented. | — | — |
| RV-AIH-14 | Info | Malformed shapes leave the card blank (fails closed). | Accepted; the behaviour is fail-closed. | — | — |

## Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-AIHR-1 | Add migration **9023** (one MODIFY) outside the V1.2 register. | RV-AIH-07 needs the environment rule at use time, and 9021 is committed (D-CORE9-2). |
| D-AIHR-2 | Close RV-AIH-01 at the Gateway, not in `cmd_approve_ai_connection`. | Only the Gateway connects as `bnx_app`, and the database-level test helpers (AT-OAUTH-*, BB-OAUTH-03 in Python) consent directly with document and legacy scopes. A database-side policy would re-baseline those helpers without closing any extra path. |
| D-AIHR-3 | Accept RV-AIH-11 (value-wise C4). | See L-AIHR-1. |

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-AIHR-1 | C4 checks each JSON value, not the concatenated text of a result. | Revisit if a tool ever returns digit lists that a host could join. |
| L-AIHR-2 | A token issued to a loopback client before `data_class` became `real` keeps working until it expires or is revoked. New authorizations are refused. | Revoke loopback connections as part of the change to `real` (INS-2 runbook). |
| L-AIHR-3 | 9023 needs register and disposition rows. | Next register revision. |

## Regression

- Local full run: see the PR.
- Release `0.7.1-aihr`, extension range 9022…9023; service-worker cache `bnx-shell-0.7.1-aihr`.
