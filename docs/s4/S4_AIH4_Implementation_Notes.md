# S4 AIH-4 — MCP App confirmation card — Implementation notes

**Status:** implemented on branch `s4/aih-4`, stacked on `s4/aih` (PR #13).

**Evidence grade:** `AUTHOR_RUNTIME_EVIDENCE` — local runs on PG16.15 and PG17.11, plus CI on the PR.

**No host has rendered the card.** PV-UI-01…03 are `NOT_EXECUTED`, which needs the AIH-5 account PoCs. The card has been exercised only in Chromium, inside a sandboxed iframe driven by a host stub that speaks the MCP Apps messages.

**Authority:**
- WP matrix V1.2, row AIH-4: "MCP App confirmation card (CARD-LINKED-CONFIRM = sealed Mode H link); in-card approval off (ODQ-03/OD-40)". Depends on AIH-2 and CORE-9. Acceptance: AT-CONF-01…04 and PV-UI-01…03.
- UA V1.2 §12.3, AIH V1.2 §8, OR-I-06 (C-01) and OR-U-05 (C-04).
- Owner decision defaults: OD-40 (in-card confirmation disabled) and OD-41 (see D-AIH4-3).

## What was built

| Part | Content |
|---|---|
| Resource `ui://balnexa/cards/v1` (`apps/worker/src/card.js`) | One HTML document, `text/html;profile=mcp-app`, served by `resources/read`. Its own CSP is `default-src 'none'`, inline script and style only, `connect-src 'none'`. The resource `_meta.ui.csp` declares no connect or resource domain. The only injected value is the instance URL, as JSON in a non-executable element. Every data value is written as text, never as markup. It is about 7 KB. |
| Card behaviour | Speaks MCP Apps: `ui/initialize`, then `ui/notifications/initialized`; it receives `ui/notifications/tool-result` and asks the host for `ui/open-link`. Where present it uses the ChatGPT Apps SDK globals (`window.openai.toolOutput`, `openExternal`). The **Draft Confirm** card shows: "Draft — not posted"; kind and state; the items (date, description, economic type, line amounts); any hold reasons; the rule that nothing is posted until the exact version is approved in the app; the instance. **Confirm** opens the sealed PWA link `#/confirm/<plan>?h=<plan_hash>&s=<scope_digest>` (CORE-9 Mode H); an anchor with the same link is the fallback. Errors and other results get a small status card. Labels in EN/中文, chosen by the host locale. |
| Catalog binding (migration 9022) | `mcp.ui_resource = ui://balnexa/cards/v1` and `ui_profile` (`draft_confirm`, or `status` for withdraw) on the six draft tools. This is a catalog-only delta block generated from the new `ui_cards` override; no function changes. |
| MCP server | `initialize` advertises `resources`. `resources/list` returns the card, `resources/templates/list` is empty, and `resources/read` returns the card (or `-32002` for any other URI). Tools bound to the card carry `_meta.ui.resourceUri`, plus `openai/outputTemplate` and `openai/widgetAccessible: false` for the same resource. A draft result gets a second text block — "Not posted. Review and approve this exact version in Balnexa: <sealed link>" — so a host without cards still has the path. `structuredContent` and the first text block stay byte-identical to REST (AT-AIH-01). |
| Release | `0.7.0-aih4`, extension range 9021…9022. |

## Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-AIH4-1 | Add migration **9022**, catalog only, outside the V1.2 register. | The binding belongs in the catalog (`mcp.ui_resource` exists there) so that no surface drifts. A committed migration is never edited (D-CORE9-2). |
| D-AIH4-2 | The seal is the version pair (`plan_hash`, `scope_digest`) of CORE-9, not an HMAC with `HANDOFF_SEAL_KEY`. | The PWA shows the server's current version and approval sends exactly that version, so a forged link discloses nothing and approves nothing (D-CORE9-7). An HMAC would add a deployment secret and no protection on this path. |
| D-AIH4-3 | No in-card editing. The card is display-only, and revisions go through the `fin_draft_revise` tool or the PWA. | OD-41's default allows revisions in the card. But an editable card needs a tool call from inside the card, which the C-04 "display never posts" boundary and `widgetAccessible: false` exclude in V1. The model can still revise. |
| D-AIH4-4 | The draft link goes in a second content block, not in `structuredContent`. | Keeps REST and MCP equivalence byte-exact while giving every host the confirmation path (AIH §8 fallback ladder: card, then text and link, then review queue). |
| D-AIH4-5 | The card shows the instance host, not an `instance_fingerprint`. | `q_whoami` returns no fingerprint yet (AIH §2.2 lists it for ISO-7). |

## Tests — `AUTHOR_RUNTIME_EVIDENCE`

- **Black box, AT-CONF-04 (AIH-4 card):**
  - the resource is the only one, with no domains in its CSP; templates list empty; unknown URI refused;
  - the card HTML contains only the instance URL, `connect-src 'none'`, no network or tool API (fetch, XHR, WebSocket, EventSource, tools/call), no `innerHTML`/`eval`, no other origin, and is under 16 KB;
  - exactly the draft tools carry the card `_meta`, and read tools do not;
  - a draft's second block is the sealed link of exactly that version; `fin_draft_get_for_confirmation` links to the same version;
  - balances are unchanged (nothing posted).
- **Unit, UT-CARD-01:** a `</script>` in the instance URL cannot break out; no network or tool API; sealed-link encoding; tool `_meta`.
- **PWA, AT-CONF-01/02 via the card (AT-PRIV-05 pattern):**
  - a real draft is created over MCP with a description containing markup, then the card is rendered in a sandboxed iframe by a host stub;
  - it shows "Draft — not posted" and the amount, renders the markup as text with no `<b>` or `<img>` element and no script effect, and made **no request at all**;
  - the only messages it sent are `ui/initialize`, `ui/notifications/initialized`, `ui/open-link` and size changes — never a tool call;
  - Confirm asked the host to open exactly the sealed link from the tool result;
  - opening it in the PWA shows the seal-match notice; the Owner approves, and the draft's state changes in the PWA, not in the card.
- **Re-baselined:** AT-AIH-06 probes `prompts/list` for "method not found", since `resources/list` now exists.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-AIH4-1 | 9022 needs register and disposition rows. | Next register revision. |
| L-AIH4-2 | Not rendered by Claude or ChatGPT. The MCP Apps message names and the ChatGPT globals follow the published descriptions but are not qualified (PV-UI-01…03). | AIH-5 PoCs. |
| L-AIH4-3 | No Transaction Entry card with in-card edits (D-AIH4-3), and no in-card approval (OD-40). | Only if OD-40/OD-41 change after a host documents UI-origin attestation. |
| L-AIH4-4 | No `instance_fingerprint` (D-AIH4-5). | ISO-7 follow-up to `q_whoami`. |
| L-AIH4-5 | The card's accessibility was not run through axe inside the host iframe. The PWA screens it links to were. | PV-UI. |
