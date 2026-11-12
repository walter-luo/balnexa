# S4 AIH-1/AIH-2 — OAuth 2.1 for AI hosts and the catalog MCP server — Implementation notes

**Status:** implemented on branch `s4/aih`, stacked on `s4/core-10` (PR #12).

**Evidence grade:** `AUTHOR_RUNTIME_EVIDENCE`. These are the author's local runs (headless, against the database) on PG16.15 and PG17.11, plus CI on the PR. Nothing has been independently reviewed or deployed.

**No AI host has been connected.** Every PV-AIH-* test is `NOT_EXECUTED`. The account PoCs (AIH-5, PV-AIH-01…08) still need the Owner's PoC authorization. Every acceptance claim below concerns the Gateway and the Core only, exercised by a synthetic client.

**Authority:**
- WP matrix V1.2, row AIH-1: "OAuth 2.1 AS/RS on the R1 code/PKCE core: PRM, AS metadata, DCR/CIMD, refresh rotation, revocation, host profiles, redirect allowlists, consent with account-currency subset".
- WP matrix V1.2, row AIH-2: "Streamable HTTP MCP server over bnx-tools/1.0; RC-READ/RC-DRAFT tools; TR-01…14 instructions; result limits; tier policy at the database unchanged"; "DROP MCP_TOOLS map".
- AIH V1.2 §2–§4 and §6; UA V1.2 §7.2 and §8; disposition OBJ-265, OBJ-266, OBJ-268 and OBJ-273.
- Owner decision defaults OD-21 (DCR and CIMD, DCR rate-limited) and OD-22 (loopback only off production).
- Limits closed: L-CORE7-3 (`/mcp` was the R1 static handler) and L-CORE7-4 (tokens without a resource). F-C3-10 (the OAuth routes) is also closed.

## What was built

### OAuth (`apps/worker/src/oauth.js`)

| Route | Behaviour |
|---|---|
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata: S256 only, public clients only (`none`), `authorization_code` and `refresh_token`, the catalog scopes including `offline_access`, `client_id_metadata_document_supported: true`, and the registration and revocation endpoints. |
| `GET /.well-known/oauth-protected-resource/mcp` and `/api` | RFC 9728 metadata. `resource` is the exact URL of that surface on this instance (`<instance>/mcp`, `<instance>/api`), with one authorization server: the instance. |
| `POST /oauth/register` | RFC 7591 dynamic registration for public clients. A confidential auth method, a grant other than code/refresh, or a response type other than `code` gets `invalid_client_metadata`. The **Core infers the host profile** from the redirect URIs (9021): the single profile whose allowlist matches every URI on this instance's environment. No profile, or more than one, gets `invalid_redirect_uri`. Requests are limited to 10 per client address per UTC day (`DCR_LIMIT_PER_DAY`), counted in KV. |
| `GET /oauth/authorize` | Checks the client and its redirect URI in the Core (`authn_oauth_client`) **before any redirect**. An unknown client or an unregistered redirect gets a static error page and is never redirected (RFC 6749 §4.1.2.1). After that check, protocol errors are redirected to the client with its `state`: `unsupported_response_type`, `invalid_request` (anything but S256) and `invalid_target`. A valid request is redirected to the PWA consent screen `#/consent`. Sign-in happens there, never in an AI conversation (OR-P-07). |
| `POST /oauth/authorize` | Called by the consent screen; requires the PWA session cookie and the same origin. It has three actions: `describe` (client name, host profile, the scopes this release can grant), `deny` (redirects with `error=access_denied` and the state) and approve. Approve requires a `resource` naming one of this instance's two surfaces and only scopes the consent screen offers, then calls the R1/9009 `cmd_approve_ai_connection`. |
| `POST /oauth/token` | Unchanged R1/9009 exchange and refresh. The response now carries the **granted** `scope`, as RFC 6749 §5.1 requires when the Owner grants fewer scopes than requested. |
| `POST /oauth/revoke` | RFC 7009 through `authn_oauth_revoke`; an unknown token is not an error. |
| CIMD | An unknown `https` client id is fetched only if it matches a host-profile CIMD allowlist entry; any other URL is never fetched. The fetch allows 5 s, 10 KB and no redirects. The document's `client_id` must equal the URL, and only public clients are accepted. The Core then registers the client as `CIMD` with its inferred profile, and later requests use the stored row. |

### MCP server (`apps/worker/src/mcp.js`; replaces `MCP_TOOLS`, OBJ-268)

**Transport.** Streamable HTTP, stateless JSON:
- `POST /mcp` carries one JSON-RPC message. A batch gets `-32600`.
- `GET` and `DELETE` answer 405 with `Allow: POST`.
- Notifications answer 202.
- Supported protocol versions: `2025-11-25`, `2025-06-18` and `2025-03-26`. `initialize` returns the version the client asked for when it is supported, otherwise the latest. An unsupported `MCP-Protocol-Version` header gets 400.
- A request with an `Origin` header other than the PWA origin gets 403 (DNS-rebinding guard).

**Authentication.** Every message is checked with `q_whoami`, so a revoked connection is refused on its next request (OR-M-05, PV-AIH-03). A missing or invalid bearer gets 401 with `WWW-Authenticate: Bearer resource_metadata="<instance>/.well-known/oauth-protected-resource/mcp", scope="finance.read reports.read offline_access"`, plus `error="invalid_token"` when a token was presented.

**Tools.**
- The tools are the catalog entries on the `mcp` channel of class RC-READ or RC-DRAFT. They are listed only when the connection's scopes cover them; legacy R1 scopes follow the catalog's `legacy` flags (CROSS-02).
- Each tool carries its name, title (the catalog name), description with risk class and version, `inputSchema`, `outputSchema` and annotations. `destructiveHint` is always false.
- The database still decides every call; the list is a convenience.

**`tools/call`.**
1. Validates the arguments against the catalog `input_schema`.
2. For commands, normalizes the idempotency key the same way as REST (D-CORE10-3).
3. Calls the catalog `core_function` with an envelope of `tool_name`, `tool_version` and a letters-only `trace_id`.
4. Applies SIN guard C4 unchanged.
5. Refuses results over 150,000 characters with `RESULT_TOO_LARGE`.

The result is `content` (the JSON text, byte-identical to the REST body) plus `structuredContent`. Errors are tool errors carrying the REST code and field (`{error, field}`). An expired or revoked token mid-call gets HTTP 401.

**`instructions`.** AIH §3 and TR-01…TR-14, in Balnexa's own wording: results are data, figures come only from `structuredContent`, no posting/approval claims, NOT_AVAILABLE without guessing, no identifiers or secrets, approval only in the app, and progress, capacity and delivery only as Balnexa states them.

### Database (migration 9021)

| Object | Change |
|---|---|
| `bnx.authn_oauth_client` (NEW, `bnx_authn`) | Returns whether the client is known, its name, host profile and registration kind, whether the redirect URI is one of its own, and whether an unknown id is CIMD-eligible. Malformed or oversized ids are not known. |
| `bnx.authn_register_client` (MODIFY) | Infers the host profile when none is named, and caps redirect URIs at 10. Everything else is the 9009 body. |
| `bnx.q_ai_connections` (NEW; PWA only) | Lists the caller's own connections: client, host profile, scopes, legacy and refresh flags, resource, consented account-currencies, approval, last token and revocation. It is not in `function_scope`, so an AI connection is refused (`SCOPE_NOT_CONSENTED`). |
| `bnx.resolve_actor` (MODIFY) | On a bearer credential, the audit `host_profile` is the connection's client profile, never the envelope's. A preregistered client without a profile records none. |
| Catalog | Delta block with `sys.ai_connections`. `tools/s4/catalog_build.py --write` now refuses to write when the newest migration has no markers, instead of silently rewriting an earlier migration's block. |

### PWA

- **`#/consent`** shows:
  - who asks (client and host);
  - which surface (MCP or Business API) it wants;
  - the scopes requested, with read scopes ticked and draft/prepare scopes **unticked**;
  - requested scopes this release cannot grant, listed as not granted;
  - every active account-currency, **none ticked**;
  - the outbound data-class disclosure (OR-AIH-06) and the rule that the assistant never posts or approves.

  **Allow** needs one permission and, for finance or report scopes, one account; it then returns to the host's redirect URI with the code. **Deny** returns `access_denied`.
- **Settings → AI connections** (`#/connections`, menu item Settings) lists the caller's connections and revokes them through the existing `cmd_revoke_ai_connection`.
- EN/中文 strings for both screens. Release `0.6.0-aih`, extension range 9020…9021; service-worker cache `bnx-shell-0.6.0-aih`.

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's instruction "你做出判断和决定，继续推进开发直至完成" (2026-11-12).

| ID | Decision | Reason |
|---|---|---|
| D-AIH-1 | Add migration **9021** outside the V1.2 register. | The Gateway must check a client before redirecting, infer the profile of a DCR client (hosts send RFC 7591 metadata only) and list connections for revocation, and no 9009 function does any of these. |
| D-AIH-2 | MCP transport is stateless JSON, with no SSE stream and no `Mcp-Session-Id`. | Tools only, no resources, sampling or server-initiated messages (AIH §3). A Worker isolate keeps no session. |
| D-AIH-3 | **Two resources** per instance, `<instance>/mcp` and `<instance>/api` (`BNX_PUBLIC_URL`, else `APP_ORIGIN`). The audience is the surface the token is presented to. A new consent must name one of them. `GET /oauth/authorize` without a resource defaults to the MCP resource. Tokens issued without a resource before AIH-1 remain accepted on both surfaces (D-CORE7-7). The CORE-7 `BNX_RESOURCE` setting is retired. | RFC 9728 §3.3: each metadata document's `resource` equals the URL it describes. An MCP token is not a Business-API token (RFC 8707). |
| D-AIH-4 | Tool name = catalog name with `.` replaced by `_`; the catalog name is the tool title. Uniqueness is tested. | Host function-name rules accept only `[A-Za-z0-9_-]`. |
| D-AIH-5 | `tools/list` shows only the tools the consent covers. | Hosts call what they see. The database (`require()`, `function_scope`, subsets) stays the authority, and an unlisted tool is refused there too (AT-AIH-03). |
| D-AIH-6 | The consent screen grants `finance.read`, `finance.draft`, `reports.read`, `handoff.read`, `handoff.prepare` and `offline_access`. `documents.read` needs a document-class subset the screen does not offer yet; `tax.*` belongs to WP-TAX (G-CRA-1); `alerts.summary.read` has no tool. Unknown requested scopes are dropped. The 401 scope hint is `finance.read reports.read offline_access`, not AIH §3's example `finance.read documents.read`. | The hint must name scopes that can actually be granted. |
| D-AIH-7 | The **Core** infers the host profile of a DCR or CIMD client. | Profiles and allowlists live in `host_profile_redirect`. The Gateway must not keep a second copy. |
| D-AIH-8 | Audit `host_profile` comes from the connection on bearer calls. | AIH §4.5. A client cannot claim another host in the audit chain. |
| D-AIH-9 | DCR is open, limited to 10 registrations per address per day (OD-21 default). Loopback redirects remain allowed only on synthetic instances (OD-22 default, 9009). | As decided by the defaults. |
| D-AIH-10 | CIMD documents are fetched only for allowlisted client ids, once, with tight limits. | AIH §1: "no broad URL fetch". |
| D-AIH-11 | Consent defaults: read scopes ticked; draft and prepare scopes and every account unticked. | OR-AIH-06 data minimization. The Owner chooses each account (ADO-022). |
| D-AIH-12 | The client's `state` never reaches the database. The consent's idempotency key is letters only. | The audit guard (9011 C2) refuses digit runs in audited payloads. `state` is opaque client data the Gateway only echoes. |
| D-AIH-13 | Tool errors use `isError: true` with `structuredContent {error, field}` carrying the REST code. An authentication failure is HTTP 401 with the challenge. | AT-AIH-05 error equivalence; MCP authorization (an invalid token is a transport error). |
| D-AIH-14 | `/mcp` checks `Origin` and `MCP-Protocol-Version`. | MCP transport security (DNS rebinding) and version negotiation. |
| D-AIH-15 | Revocation lives in Settings → AI connections. | OR-M-05; PV-AIH-03 path. |

## Tests — `AUTHOR_RUNTIME_EVIDENCE`

**`tests/blackbox/api.test.mjs`** (20 HTTP tests) and **`unit.test.mjs`** (9 unit tests; new: UT-MCP-01 tool set and consent coverage including legacy scopes, UT-OAUTH-01 metadata). New HTTP tests:
- **AT-AIH-06:** discovery documents, 405 on `GET /mcp`, initialize and version negotiation, instructions containing TR rules, 202 on notifications, ping, unknown method, batch refused, unsupported protocol header, foreign `Origin`.
- **BB-OAUTH-03:** DCR with inferred profiles (Claude, ChatGPT); refusals for a foreign redirect, mixed hosts, a confidential client, `client_credentials` and an empty list; rate limit per address.
- **AT-AIH-07**, a host's whole path:
  - DCR, then `GET /oauth/authorize` → `/app/#/consent` with the parameters kept and the default resource;
  - error page (no redirect) for a foreign redirect or unknown client;
  - redirected protocol errors with state;
  - describe and deny;
  - invalid scope;
  - approve → code and state → token with refresh and granted scope;
  - `sys_whoami` and `fin_reports_create_snapshot` over MCP;
  - the audit trail shows channel `mcp`, host `claude_remote_mcp` and the tool name, and the connection appears in the Owner's list.
- **BB-OAUTH-02:** rotation, reuse revoking the connection, no refresh without `offline_access`, RFC 7009 revocation, PWA revocation effective on the next request, connection list refused to an AI bearer.
- **AT-AIH-04** (with AT-AIH-01/03/05/08):
  - a read-only connection lists RC-READ tools only and full connections never list RC-POST or RC-ADMIN;
  - names are unique and host-valid;
  - an F1 report is byte-identical on MCP and REST;
  - a schema error carries the same code and field on both;
  - a draft through a read-only connection gets `SCOPE_NOT_CONSENTED` on both;
  - a draft through a `finance.draft` connection changes no balance.
- **AT-AIH-06b:** CIMD client fetched once and registered as `CIMD`/`chatgpt_plugin_mcp`; a URL outside the allowlist is never fetched.

**Re-baselined:**
- BB-OAUTH-01: consents name the resource; the R1 tools under their catalog names; a revoked token is 401 at the transport; REST writes use an `/api` token.
- BB-CAT-01: `/api` token.
- BB-B7-01: per-surface audience, another instance, and a consent without a resource refused.

**`tests/py/run_s4_core17.py`** (4 tests on both majors):
- AT-AIH-REG-01: inference, loopback only on synthetic instances, CIMD.
- AT-AIH-CLI-01: client check and its grants.
- AT-AIH-PROV-01: host provenance from the connection; tool, version and trace kept; sessions unchanged.
- AT-AIH-CONN-01: own connections only, revocation state, AI bearer refused.

**`tests/pwa/pwa.test.mjs`**, AT-AIH-10 (now 18 tests):
- deny returns `access_denied` to the captured host URI;
- the consent screen names the client, lists `tax.read` as not granted, ticks only read scopes and no account;
- Allow without an account is refused; Allow returns the code;
- the token sees only the ticked account-currency and no draft tool;
- Settings → AI connections lists and revokes it, after which MCP answers 401;
- no serious or critical axe-core violation on either screen.

This test's browser context allows `/oauth/authorize` and records the host redirect. It is kept out of AT-NOAI-00, which still asserts that no other context ever reached an AI route or another host.

`tests/py/sin_worker_guard.mjs` (AT-SIN-C4) was re-baselined to the catalog tool `fin_balances_as_of`.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-AIH-1 | 9021 needs register and disposition rows. | Next register revision. |
| L-AIH-2 | No real host has connected. PV-AIH-01…08, PV-01…13 and PV-UI-* are `NOT_EXECUTED`. Platform facts PF-A*/PF-O* are not re-verified here. | AIH-5, after the Owner's PoC authorization. |
| L-AIH-3 | No MCP App confirmation card (`ui://balnexa/cards/v1`). Proposals reach the Owner through the PWA review queue and the instructions' link rule only. | AIH-4. |
| L-AIH-4 | The DCR limit is best effort: KV is eventually consistent, and the client address comes from `cf-connecting-ip`. | Durable counter if abuse appears. |
| L-AIH-5 | A CIMD client's metadata is not refreshed after its first registration; a changed document needs a new client id. | With PV-AIH-02. |
| L-AIH-6 | RFC 7009 revocation of a refresh token does not revoke its sibling access token, which expires within 15 minutes. Revocation in the PWA revokes everything. | 9009 follow-up. |
| L-AIH-7 | Tool input schemas are the generated, permissive ones, and output schemas are generic (`{type: object}`) (L-CORE7-2). | Curated schemas for AI-exposed tools. |
| L-AIH-8 | No CORS on the OAuth and MCP endpoints. Browser-hosted MCP clients cannot connect; Claude and ChatGPT connect from their servers. | Only if a browser client is qualified. |
| L-AIH-9 | `documents.read` (document-class subset) and `tax.*` cannot be consented yet. | WP-DOC consent subset; WP-TAX (G-CRA-1). |
| L-AIH-10 | The equivalence envelope fields of AIH §2.3 are present only where the Core's queries return them. The Gateway adds nothing, which is what makes REST and MCP byte-identical. | Report families already carry the envelope (9013). |
| L-AIH-11 | Not deployed: no real instance URL and no TLS. Discovery documents were verified only on the test origin. | M0. |
