# Claude Self-Review — R6.2-R1 (adversarial pass after development)

Method: re-read every new SQL function and Worker route against the attack list of the final audit §8.1(9); each item ends in a test, a fix, or a disclosed residual. This review is by the author and is **not** independent.

## 1. Defects found and fixed during this pass

| ID | Finding | How found | Fix | Test |
|---|---|---|---|---|
| NEW-048 (P0) | Deferred constraint triggers fire at COMMIT **outside** the SECURITY DEFINER frame (`current_user` = session role). The completeness check failed for `bnx_app` with `permission denied for function assert_journal_complete`; a superuser-only test suite would never have shown this. | First command run as `bnx_app` | Deferred trigger functions are SECURITY DEFINER (`0102`, `0104`); design rule D3 proposed in `docs/R1_Doc_Delta.md` | AT-BAL-03, AT-CONC-02, AT-OWN-05 |
| — | `trg_journal_complete` referenced `new.journal_id` inside a CASE that PL/pgSQL plans for both tables | first run | if/else per table | AT-BAL-01 |
| NEW-049 (P1) | Owner/admin could `cmd_set_grant` themselves onto another member's **private** account (silent privacy bypass) | review of grant paths | private-account grants only by the creator; uniform `NOT_AVAILABLE` (no existence oracle) | AT-CMD-03 |
| NEW-050 (P2) | Unknown command names (`/api/v1/commands/wrk_activate_plan`) returned HTTP 500 | black-box | `42883` → 404 | BB-API-02 |
| — | `wrk_claim` first version returned items leased by other dispatchers | review | `UPDATE … RETURNING` in the claim CTE | AT-Q-01 |
| — | Evidence registration accepted negative sizes / malformed hashes | review | validation in `cmd_register_evidence` | AT-CMD-03 |
| — | Simulation first reported a "bound violation" that was actually repeated dispatcher crashes | sim | bound restated per crash count (`+3 h per crash`) | dispatch_sim |

## 2. Attack list walk-through

| Area | Probe | Result |
|---|---|---|
| Spoofed identity | forged/truncated session tokens, wrong-key/expired/wrong-aud/unverified/foreign-issuer/`alg:none` ID tokens, app role minting sessions | rejected (AT-CMD-01, BB-AUTH-01) |
| Forged AI identity | wrong PKCE verifier, code replay, `plain` method, revoked connection, MCP write via MCP and via REST | rejected; the **database** refuses AI-channel writes (AT-CMD-04, BB-OAUTH-01) |
| Skipped routes | direct table access by every runtime role, cross-role function calls, installer and helper functions | 10 + 24 denials (AT-CMD-03, AT-MIG-05) |
| Numeric edges | over-scale, exponent notation, JPY fraction, cross-currency zero sum, |amount| ≥ 1e15 | rejected (AT-BAL-01/02/04) |
| Idempotency | same key/payload, changed payload, cross-member keys, 8-way race, crash before commit then retry | AT-CMD-02, AT-CONC-01, AT-FAULT-01 |
| Approval transitions | digest mismatch, stale scope, revoked approver, suspended approver after seal, activation vs in-flight posting, tampered item | AT-PLAN-01…03, AT-CONC-03, AT-FAULT-01 |
| Snapshot revocation | guessed/other-audience/malformed IDs identical; revoked grant; suspended zero-scope member; other AI connection; narrower AI consent | AT-SNAP-03/04 |
| Evidence URL after revocation | next request denied, identical to unknown file | AT-EVP-11 (URL presign itself NOT_IMPLEMENTED → M0-D-07) |
| Job crashes | killed backend, failed queue item re-queued, lease expiry, dispatcher crash after claim (sim) | AT-FAULT-01, AT-Q-01, dispatch_sim |
| R2 loss | only `dual_verified` objects counted recoverable; silent `dual_verified` refused; hash mismatch → `archive_failed` + alert | AT-ARC-02 (real R2 = M0-B-08) |
| Key rotation | AUD-038 keyring simulation re-run | PASS (unchanged Draft-04 tool) |
| Unbounded billing | no code path calls a paid API; dispatcher wakes Neon ≈ 241×/month idle (≈ 5 CU-h); KV writes bounded by enqueues + dispatches | dispatch_sim; real metering = M0-F |
| Backup role | write/DDL/nextval/`SET default_transaction_read_only=off` attempts | 9 denials (AT-BAK-01) |

## 3. False positives / tests that could pass for the wrong reason (checked)

- Draft-04 negative controls run on a separate database migrated by the Draft-04 tools under `postgres` (that is how Draft-04 ran); they prove the defect, not R1 behaviour.
- AT-MUT-01 proves the AT-BAL probes fail when the header trigger or both currency layers are removed (the composite FK alone is backed by a second deferred layer).
- Definer-level probes (migrator under `SET ROLE bnx_definer`) model a buggy future definer function; they are not presented as runtime-role evidence. Runtime-role claims use `bnx_app`/`bnx_worker`/`bnx_authn`/`bnx_backup` connections.
- AT-ARC-02 sets `sha256`/`integrity_state` through the owner role because the executor does not exist (labelled in the test).
- The KV used by the black-box suite is an in-memory map; Cloudflare KV semantics are only modelled (60 s staleness) in the simulation.

## 4. Residuals not fixed (disclosed)

| ID | Residual | Proposal |
|---|---|---|
| NEW-051 | `bnx.authn_begin_session` trusts claims verified by the Worker; a stolen `bnx_authn` credential can mint sessions for registered subjects | M0: bind the authn credential to the Worker only (Neon IP allow / separate role password rotation); optionally store Google `jti`+`exp` to block replay; alert on session creation outside the Worker |
| NEW-052 | PG17 backup path NOT_EXECUTED | run AT-BAK-01 with pg_dump 17 before M0-E; production pins pg_dump major = server major |
| — | Refresh tokens not implemented (AI host must re-authorize after 15 min) | M0-A-06 decides |
| — | Plan chunking: one transaction posts all items (worker statement_timeout 30 s) | M1 chunking with resumable batches |
| — | Economic-type rule table (B6.1) not enforced; `economic_type` is a label in R1 | M1/G2, AUD-027 |
| — | Account identity fingerprint/holder events not in the command slice | M1, AUD-017 |
| — | Restore splits `bnx` (migrator/definer) and `auth` (bnx_auth) loads into two transactions | acceptable for G0; M0-E drill documents the ordering |
| — | `q_*` functions update `member_session.last_seen_at` (read path writes one row) | acceptable; noted for read-replica designs |
