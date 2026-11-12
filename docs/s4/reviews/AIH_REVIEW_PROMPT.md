# Review prompt — AIH-1/AIH-2/AIH-4 (OAuth 2.1 for AI hosts, catalog MCP server, confirmation card)

You are reviewing the Balnexa repository `walter-luo/balnexa`. Your scope is the change set `s4/core-10..s4/aih-4`: draft PRs #13 (AIH-1/AIH-2, migration 9021) and #14 (AIH-4, migration 9022).

You did not write this code. Review it adversarially.

**Rules:**
- Read-only: commit nothing, push nothing, comment on nothing, approve nothing. Write your cases and evidence under the scratch directory you are given.
- Synthetic data only. Build any SIN-shaped value at run time (see `tests/py/sin_corpus.py`) and never write one into a file, a log or your report.
- `requirements/owner_sources/` and every Owner-private package are out of scope.
- Grade every verdict `SAME_FAMILY_VERIFICATION`.

## Inputs

- `docs/s4/S4_AIH_Implementation_Notes.md`: decisions D-AIH-1…15 and limits L-AIH-1…11.
- `docs/s4/S4_AIH4_Implementation_Notes.md`: decisions D-AIH4-1…5.
- Code: `apps/worker/src/oauth.js`, `mcp.js`, `card.js`, `http.js`, `index.js`; `db/migrations/9021_s4_ai_host_oauth.sql`, `9022_s4_ai_host_cards.sql`; 9009 (the OAuth core); 9017 (`resolve_actor`, the catalog).
- Tests: `tests/blackbox/api.test.mjs` (the `AT-AIH-*`, `BB-OAUTH-*`, `BB-B7-01` and `AT-CONF-04` tests), `tests/blackbox/unit.test.mjs`, `tests/py/run_s4_core17.py`, `tests/pwa/pwa.test.mjs` (`AT-AIH-10`, `AT-CONF-01/02` via the card).

## Environment

PG16 and PG17 are already running locally:
- PG16: socket `/var/lib/postgresql/bnx16`, port 55416.
- PG17: socket `/var/lib/postgresql/bnx17`, port 55417.

`tests/py/harness.py` knows the DSNs. Node, Playwright (`PLAYWRIGHT_BROWSERS_PATH` preset) and `npm ci`'d `tests/pwa` and `apps/worker` are in place.

Suites call `drop_all`, and roles are cluster-global, so **never run two database suites at the same time**. Name any database you create with the prefix `bnx_rv` so that it is recognisable.

## Tasks

1. **Regression of the stage:**
   - `python3 tests/py/run_s4_core17.py --server pg16` and `--server pg17`;
   - `BNX_PY=$(which python3) node --test tests/blackbox/api.test.mjs tests/blackbox/unit.test.mjs`;
   - `cd tests/pwa && BNX_SERVER=pg16 node --test --test-concurrency=1 pwa.test.mjs`.

   Report PASS/FAIL per suite.
2. **OAuth attacks.** Write your own cases with the node adapter in `apps/worker/node/adapter.mjs` (see how `tests/blackbox/api.test.mjs` starts it) or directly against the database functions. Cover at least:
   - **Redirect safety:** open redirect and redirect-URI confusion (prefix, path, query, fragment, case, user-info, IDN and percent-encoding tricks); any way to get a 302 to a URI that is not registered for the client.
   - **The consent `POST`:** CSRF (Origin and cookie rules), a session of a viewer or another household, a `client_id`/`redirect_uri` swap between describe and approve, scope escalation (scopes outside `CONSENTABLE`, legacy `read`/`propose`, duplicates), and account-currency subsets the caller cannot see.
   - **Codes and tokens:** PKCE downgrade or omission, code reuse, code from another client, resource/audience confusion between `/mcp` and `/api` and between instances, refresh rotation races, and revocation (RFC 7009 and PWA) followed by use.
   - **DCR:** profile inference tricks (patterns matched by a crafted URI that is not really the host), loopback on a production-class instance, metadata injection into `client_name`, oversized bodies, and getting around the rate limit.
   - **CIMD:** SSRF (any way to make the Gateway fetch a URL outside the allowlist: encodings, redirects, userinfo, ports, `..`), a document whose `client_id` differs from the URL, and a document listing foreign redirect URIs.
3. **MCP attacks:**
   - calling any tool that is not listed (RC-POST/RC-ADMIN, PWA-only queries such as `q_audit_trail` and `q_ai_connections`, internal functions) by any name form;
   - JSON-Schema bypass to reach the database with a field the schema should refuse;
   - an idempotency key that makes an audited value fail or leak;
   - a SIN-shaped value reaching an AI result (guard C4);
   - provenance spoofing in the audit chain (`host_profile`, `tool_name`, `trace_id`);
   - the `Origin` and protocol-version checks;
   - a notification or batch smuggling;
   - result size limits;
   - REST/MCP equivalence counter-examples.
4. **Card (AIH-4):**
   - can any tool-result value become markup or script in `card.js`;
   - can the card reach the network or call a tool;
   - can the instance URL injection break out;
   - can a crafted result make Confirm open a URL other than this instance's sealed link.
5. **Database (9021/9022):**
   - grants of `authn_oauth_client`;
   - the `resolve_actor` rewrite compared with the 9017 body: is any check lost or weakened (session expiry, B7, envelope validation)?
   - `q_ai_connections` disclosure across members and households;
   - catalog block integrity: run `tools/s4/catalog_build.py --check` against a fresh database.

## Report

Write `AIH_REVIEW_REPORT.md` in the scratch directory.

1. One table row per finding: ID `RV-AIH-nn`, severity (Critical/High/Medium/Low/Info), component, a short statement, a reproduction (case file and command), the expected and the observed behaviour, and a suggested fix.
2. A second table listing every case you ran that found nothing, so that coverage is visible.
3. The regression results.
4. An explicit statement of what you could not verify.

Do not soften findings, and do not report a theoretical issue as confirmed: mark it `PLAUSIBLE` unless you reproduced it.
