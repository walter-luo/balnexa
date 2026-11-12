# S4 CORE-10 — Inter-project handoff screens, audit trail (item 7), Gateway idempotency keys — Implementation notes

**Status:** implemented on branch `s4/core-10`, stacked on `s4/core-9` (PR #11).

**Evidence grade:** `AUTHOR_RUNTIME_EVIDENCE` — the author's local runs, headless and in the database, on PG16.15 and PG17.11, plus CI on the PR. Not independently reviewed and not deployed.

**Authority:**
- WP matrix V1.2, row CORE-10: "Prompt-based handoff (prepare/import/status; Mode J portable proposal)", depends on CORE-4 and CORE-9. Acceptance: AT-HX-01…08 and AT-NOAI-08.
- Owner Requirements Book V1.2, §6A (OR-X-01…05) and OR-U-02, item (7).
- UA V1.2, §12.2.
- CORE-9 limits L-CORE9-3 (audit trail) and L-CORE9-9 (idempotency keys).

The database side of the handoff was already in place from 9010: `cmd_handoff_prepare`, `cmd_handoff_import`, `cmd_handoff_mark_sent` and `q_handoff_status`, covered by AT-HX-01-08 in `run_s4_core4.py`. This stage adds the screens that make it usable without AI. It also adds the audit-trail query that item 7 lacked, and a Gateway fix for the CORE-9 finding.

## What was built

| Part | Content |
|---|---|
| Handoff status `#/handoff` | Every message the caller may see: direction, type, state, sender, message and transfer ids. A row with a draft opens Draft Confirm. Links to import, and to prepare from a transaction. |
| Prepare `#/handoff/prepare?journal_id=` | Reached from the transaction view, or from the menu with the journal id typed in. Fields: receiving project label, project code (2–10 capital letters or digits; lower case is upper-cased) and an optional note. The note's hint says a full account number is refused, and the database refuses it (AT-HX-06). The generated prompt is shown verbatim, with **Copy** and **Mark as sent** buttons. Balnexa never sends it. |
| Import `#/handoff/import` | Paste the whole received message. The screen states that only the one JSON block is read and that every other line is ignored, instructions included. Optional local account and direction (needed for a PROPOSAL or REVERSAL). The result shows the status, message type and a localized reason. A duplicate shows its existing state. A PROPOSAL links to its draft, which then goes through the normal exact-version approval. |
| Menu | The three handoff tasks open their dedicated screens. Item 7 gains **Audit trail**. |
| `q_audit_trail` (migration 9020) | Tier 0. PWA only: it is not in `function_scope`, so it is never an MCP tool. The Owner and admins see the household chain; any other member sees only the events they caused. Filters: command prefix, member, date range, `before_seq` paging, limit ≤ 500. Returns the time, member, channel, command, subject, ledger version, chain version and host provenance of each event. The chain stores only the payload's SHA-256, so no payload is ever returned. |
| Gateway idempotency keys (closes L-CORE9-9) | A client key of 8–80 printable characters is replaced before the database call by `gk-` followed by 32 letters derived from its SHA-256. The digest is spelled in letters only. As a result, no client is randomly refused by the audit guard for a digit run, and no raw client key is stored. The mapping is deterministic: a retry with the same key replays, and another body under the same key still conflicts (409). Keys outside 8–80 characters pass through unchanged, so the database reports its own error code. |
| Release | `0.5.0-core10`, extension range 9019…9020; service-worker cache `bnx-shell-0.5.0-core10`. |

## Decisions — `DELEGATED_DECISION`

Taken under the Owner's instruction "你做出判断和决定，继续推进开发直至完成" (2026-11-12 05:50).

| ID | Decision | Reason |
|---|---|---|
| D-CORE10-1 | Add migration **9020** (`q_audit_trail`) outside the V1.2 register. | Item 7 requires audit trails, and no catalog query returned the chain. |
| D-CORE10-2 | Restrict household-wide audit visibility to the Owner and admins; everyone else sees their own events. | Audit subjects name accounts and members. A member's grants cover accounts, not the history of other members' commands. |
| D-CORE10-3 | Fix L-CORE9-9 at the Gateway (normalize keys) rather than exempting `idempotency_key` from the database guard. | An exemption would let a SIN-shaped key be stored raw in the idempotency records. The Gateway is the only holder of `bnx_app`, so every client is covered. |
| D-CORE10-4 | Only same-currency and portable-block flows get screens. The Mode J portable proposal for AI hosts is the same `bnx-project-handoff/1.x` block, exchanged through the same two screens. | OR-X-05: prepare, import and status work in the PWA without AI, and AI hosts use the same deterministic format. |

## Tests — `AUTHOR_RUNTIME_EVIDENCE`

**`tests/pwa/pwa.test.mjs`** — now 17 tests. Throughout, every non-origin host and AI route is blocked, so all of these also count toward AT-NOAI-00.

- **AT-NOAI-08 + AT-HX-01…08:**
  - prepare from the transaction view;
  - a note containing a full account number is refused;
  - the prompt has a JSON block and no long digit run;
  - Mark as sent works;
  - the peer's ACKNOWLEDGMENT for the same amount gives MATCHED;
  - a peer PROPOSAL wrapped in instructions becomes a `handoff` draft that stays `frozen` until the Owner approves it, and then posts `transfer_to_clearing`, so it is never classified automatically;
  - the same message again is shown as already imported;
  - the same message id with another amount is an exception, shown as possible tampering, and nothing is posted;
  - a peer STATUS leaves our prompt `AWAITING_PEER`;
  - two blocks are refused;
  - the menu links open the dedicated screens.
- **AT-NOAI-07b:** the Owner sees the household chain; a member sees only their own events.
- **AT-IDEM-01:** a key containing a Luhn-valid 9-digit run (built at runtime) is accepted; it replays; another body under it conflicts.

**`tests/py/run_s4_core16.py`** — now 3 tests:
- AT-AUD-TRAIL-01: scope, ordering, exact paging, prefix filter, malformed filter refused, no payload returned, AI bearer refused.
- AT-CAT-02: now generic over all delta blocks.

## Limits

| ID | Limit | Follow-up |
|---|---|---|
| L-CORE10-1 | 9020 needs register and disposition rows. | Next register revision. |
| L-CORE10-2 | A REPLAY_MISMATCH or refused import is returned to the importer but not stored, by the 9010 design. The status list therefore shows no row for it, and the import result is the only record. | Consider an exception log in a later migration if the Owner wants these listed. |
| L-CORE10-3 | Cross-currency handoff legs (fee/FX provenance) are shown as received but not editable in the PWA. The block carries what the database generated. | With the Draft-04 FX flows. |
| L-CORE10-4 | Not deployed. Nothing has been checked with a real peer project. | M0 and the Owner's first real handoff. |
