#!/usr/bin/env python3
# Copyright 2026 Walter Luo
# SPDX-License-Identifier: Apache-2.0
"""Builds AUD001_054_Master_Tracker.csv: 54 canonical AUD IDs (+ NEW-* author namespace rows). AUD-001…043 Draft-04
author dispositions are taken verbatim from tools/aud001_043_draft04_extract.json (parsed from
Balnexa_Draft04_Consolidated_Review_and_Traceability.md sha256 111f86ee…); R1 columns are this package's assessment.
Nothing is marked CLOSED: 'proposed_closure' is a proposal for the independent reviewer."""
import csv, hashlib, json, os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
D04 = json.load(open(os.path.join(ROOT, "tools/aud001_043_draft04_extract.json")))
EV16, EV17, BB = "EVIDENCE/pg16/g0_results.json", "EVIDENCE/pg17/g0_results.json", "EVIDENCE/blackbox/blackbox_pg16.tap;EVIDENCE/blackbox/blackbox_pg17.tap"
SIM = "EVIDENCE/sim/dispatch_sim.json.log"


def sha(p):
    return hashlib.sha256(open(os.path.join(ROOT, p), "rb").read()).hexdigest()[:16] if p and os.path.exists(os.path.join(ROOT, p)) else ""


A = "AUTHOR_TESTED_AWAITING_INDEPENDENT_REPRODUCTION"
P = "PARTIALLY_IMPLEMENTED_AUTHOR_TESTED"
U = "UNCHANGED_IN_R1"
N = "NOT_IMPLEMENTED"
# id: (r1_status, grade, predicates, change, files_objects, before, after, tests, evidence, g0, g1, g2, owner, proposal, primary_file)
R1 = {
 "AUD-001": (P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Balances read through bnx.q_balances -> balance_at at a ledger version; journals created only by commands",
             "0106 q_balances, insert_journal; 0103 balance_at", "contract + t.post tests", "real command path; versioned reads", "AT-BAL-03, AT-CMD-05, AT-CMD-07, AT-PLAN-01, BB-API-01", f"{EV16};{EV17};{BB}",
             "PASS (author)", "M0-C pending", "R01-R34 NOT_IMPLEMENTED", "", "G0 component for the balance surface only; keep open for R01-R34", "db/migrations/0106_command_core.sql"),
 "AUD-005": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Privileged bootstrap B001 separated; restricted migrator; prefix grants; machine privilege audit",
             "B001; 0101; 0108 apply_grants/audit_privileges", "roles created by 0001 under superuser", "0 privilege violations; runtime roles have no table rights", "AT-MIG-01..06, AT-CMD-03", f"{EV16};{EV17};EVIDENCE/pg16/privilege_matrix.json",
             "PASS (author)", "M0-C-06 Neon role semantics", "", "", "propose G0 closure; G1 open", "db/bootstrap/B001_bootstrap.sql"),
 "AUD-006": (P, "AUTHOR_RUNTIME_EVIDENCE", "NOT_IMPLEMENTED (delivery)", "Outbox rows written in the command transaction (journal.posted, plan.*, archive.failed)",
             "0106 bnx.outbox", "design", "outbox row per posting; delivery worker absent", "AT-CMD-06, AT-ARC-02", EV16, "PASS (author, write side)", "M0-D", "notification delivery NOT_IMPLEMENTED", "", "keep open (delivery)", "db/migrations/0106_command_core.sql"),
 "AUD-011": (P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING;OWNER_DECISION_REQUIRED (Draft-04 residual unchanged)", "Google ID-token verification (RS256/WebCrypto) in Worker; DB sessions (SHA-256 only); OAuth code + PKCE S256 in SQL",
             "apps/worker/src/jwt.js, index.js; 0106 authn_*", "spec", "sessions, PKCE, revocation work against synthetic JWKS", "AT-CMD-01, AT-CMD-04, BB-AUTH-01/02, BB-OAUTH-01", f"{EV16};{BB}",
             "PASS (author)", "M0-A-05/06 real Google + real hosts", "refresh tokens NOT_IMPLEMENTED", "Draft-04 residual decision unchanged", "G0 component; G1 open", "apps/worker/src/jwt.js"),
 "AUD-016": (A, "AUTHOR_RUNTIME_EVIDENCE", "", "cmd_set_opening: install/revise at one version; exclusion guard; T3 for revision",
             "0106 cmd_set_opening", "spec + t.set_anchor", "real command", "AT-CMD-07", EV16, "PASS (author)", "M0-C", "UI", "", "propose G0 closure", "db/migrations/0106_command_core.sql"),
 "AUD-019": (P, "AUTHOR_RUNTIME_EVIDENCE", "NOT_IMPLEMENTED (matching engine)", "Fingerprint uniqueness and source-link state machine executed; matching rules absent",
             "0005 source_txn_fp_uq; 0105", "PK blocked relink", "state machine + fingerprints", "AT-SRC-01", EV16, "PASS (author, storage layer)", "M0-C", "matching NOT_IMPLEMENTED", "", "keep open", "db/migrations/0105_source_link_events.sql"),
 "AUD-020": (P, "AUTHOR_RUNTIME_EVIDENCE", "OWNER_DECISION_REQUIRED (Draft-04 residual unchanged)", "Runtime roles have no table/sequence privileges; only cmd_/q_/wrk_/authn_ functions",
             "0101, 0108", "grants by convention", "audited by bnx.audit_privileges on every migration", "AT-MIG-05, AT-MIG-06, AT-CMD-03, BB-API-02", f"{EV16};{BB}", "PASS (author)", "M0-C", "", "Draft-04 residual decision unchanged", "G0 component", "db/migrations/0108_grants_and_privilege_audit.sql"),
 "AUD-025": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "pg_dump --snapshot (exported, REPEATABLE READ READ ONLY) as bnx_backup, custom format, both schemas",
             "B001 default privileges; tests AT-BAK-01", "untested", "dump + isolated restore verified (PG16)", "AT-BAK-01", "EVIDENCE/pg16/AT-BAK-01_*", "PASS (author, PG16); PG17 NOT_EXECUTED", "M0-E", "", "", "propose G0 closure for PG16 path", "db/bootstrap/B001_bootstrap.sql"),
 "AUD-027": (U, "DOCUMENTED_DESIGN", "NOT_IMPLEMENTED (rule table)", "R1 cmd_post_transaction stores economic_type but does NOT enforce the B6.1 economic_type_rule table",
             "—", "design", "unchanged; label only in R1 slice", "AT-ECON-* (Draft-04, not executed)", "—", "no new G0 evidence", "per Draft-04", "rule table + AT-ECON", "", "none (carry; disclosed gap)", ""),
 "AUD-028": (A, "AUTHOR_RUNTIME_EVIDENCE", "", "Versioned reads through commands (ledger_version parameter), snapshot replay at V",
             "0106 q_balances; 0107", "t.* tests", "real queries", "AT-CMD-05, AT-CMD-07, AT-PLAN-01, AT-SNAP-03", EV16, "PASS (author)", "M0-C", "R01-R34", "", "G0 component", "db/migrations/0106_command_core.sql"),
 "AUD-029": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Fail-closed activation vs concurrent direct postings; stale/suspend; scope claims",
             "0106 wrk_*; 0108 wrk_revalidate_plan", "design", "activation waits on ledger lock then refuses", "AT-CONC-02, AT-CONC-03, AT-PLAN-02, AT-PLAN-03", EV16, "PASS (author)", "M0-C workloads", "onboarding UI", "", "propose G0 closure", "db/migrations/0106_command_core.sql"),
 "AUD-030": (P, "AUTHOR_RUNTIME_EVIDENCE", "NOT_IMPLEMENTED (dedup by trusted SHA)", "Uniform registration/access responses (no existence oracle)",
             "0106 cmd_register_evidence, q_evidence_access", "design", "identical denied responses", "AT-EVP-11, AT-CMD-04", EV16, "PASS (author)", "M0-B", "dedup", "", "keep open", "db/migrations/0106_command_core.sql"),
 "AUD-031": (P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Isolated restore verified: per-table counts, audit chain, journal completeness, migration ledger, identical q_balances",
             "tests AT-BAK-01", "design", "restore path executed (PG16)", "AT-BAK-01", "EVIDENCE/pg16/AT-BAK-01_restore_verification.json", "PASS (author, PG16)", "M0-E RTO/RPO", "R01-R34 surface hashes NOT_IMPLEMENTED", "", "keep open (report hashes)", "tests/py/run_g0.py"),
 "AUD-035": (A, "AUTHOR_RUNTIME_EVIDENCE", "", "Verifier + 15 negative fixtures re-run offline from the pinned wheelhouse",
             "Draft-04 AI-ENTRY zip (unchanged)", "author run", "re-run PASS", "AI-ENTRY verify + N01..N15", "EVIDENCE/g0_08/ai_entry_verify.log", "PASS (author re-run)", "", "", "", "propose closure after reviewer reproduction", ""),
 "AUD-037": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Clean chain B001 + 0002-0006 (byte-identical) + 0101-0109 + 9001 under bnx_migrator on PG16 and PG17; Draft-04 0001/0007 retained as history only",
             "db/migrations; db/history/draft04", "superuser runner", "restricted runner; lint 0 findings", "AT-MIG-01, AT-MIG-07, chain lint", f"{EV16};{EV17};EVIDENCE/g0_08/chain_lint.json", "PASS (author)", "M0-C-06", "", "", "propose G0 closure", "db/tools/run_migrations.py"),
 "AUD-038": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Keyring simulation re-run unchanged (age 1.1.1)", "db/history/draft04/backup_keyring_sim", "author run", "re-run PASS", "AT-BKP-* (sim)",
             "EVIDENCE/g0_08/AUD-038_keyring_sim_rerun.log", "PASS (author re-run)", "M0-E-06/07", "owner key custody", "SEC-K (later)", "G0 component", ""),
 "AUD-039": (A, "AUTHOR_RUNTIME_EVIDENCE", "", "Ownership through cmd_record_ownership; deterministic resolution (see AUD-052)", "0104; 0106", "t.own", "real commands", "AT-OWN-05", EV16,
             "PASS (author)", "M0-C", "holders_at NOT_IMPLEMENTED; UI", "", "G0 component", "db/migrations/0104_ownership_determinism.sql"),
 "AUD-040": (A, "AUTHOR_RUNTIME_EVIDENCE", "", "AT-SNAP-03 executed (audit replay T3, revocation)", "0107", "AT-SNAP-03 specified only", "executed", "AT-SNAP-03, AT-SNAP-04", EV16,
             "PASS (author)", "M0-C", "", "", "propose G0 closure with AUD-051", "db/migrations/0107_snapshot_authz.sql"),
 "AUD-041": (A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Live decision per request; 60 s URL TTL recorded; revocation effective on next request", "0106 q_evidence_access", "decision path only", "through commands",
             "AT-EVP-11", EV16, "PASS (author)", "M0-D-07 presigned URL window", "", "", "G0 component", "db/migrations/0106_command_core.sql"),
 "AUD-042": (P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "No silent dual_verified (trigger); worker archive events; mismatch -> archive_failed + alert", "0109", "state column only", "guarded transitions",
             "AT-ARC-02", EV16, "PASS (author)", "M0-B-08 real copy", "", "DR-02 (new)", "keep open", "db/migrations/0109_archive_integrity_and_dual_copy_gate.sql"),
}
NEWER = {
 "AUD-044": ("P0", "Deferred journal completeness — a header without lines can commit", "Handoff §2 AUD-044; Draft-04 0003_ledger.sql t_je_balanced on journal_line only",
   A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Deferred COMMIT-time assertion fired by the HEADER insert and every line insert (SECURITY DEFINER); >=2 lines; debit+credit per currency; zero sum; currency = ledger account; scale; same-transaction lines (LATE_LINE)",
   "0102 bnx.assert_journal_complete, t_journal_complete_header/_line, t_line_same_txn", "header-only journal committed (AT-BAL-05 reproduces on Draft-04)", "all malformed journals rejected at COMMIT, state unchanged",
   "AT-BAL-01, AT-BAL-02, AT-BAL-03, AT-BAL-05 (control), AT-MUT-01, AT-FAULT-01, AT-CONC-02", f"{EV16};{EV17}", "PASS (author, PG16+PG17)", "M0-C pending", "", "", "propose G0 closure", "db/migrations/0102_journal_completeness.sql"),
 "AUD-045": ("P0", "Currency identity and precision not enforced across linked financial objects", "Handoff §2 AUD-045; Draft-04 0002-0006",
   A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Composite FKs (id,currency) across ledger_account/account_currency/journal_line/statement/source_txn/clearing_item; ISO check; per-currency scale triggers; original vs posting currency separated; balance_at filters currency",
   "0103", "USD line on CAD ledger account committed (AT-BAL-05)", "rejected by FK and by the deferred LINE_CURRENCY_MISMATCH layer",
   "AT-BAL-01..05, AT-MUT-01", f"{EV16};{EV17}", "PASS (author, PG16+PG17)", "M0-C pending", "investment trades NOT_IMPLEMENTED", "", "propose G0 closure", "db/migrations/0103_currency_integrity.sql"),
 "AUD-046": ("P1", "KV wakeup can be lost despite durable queued Neon work", "Handoff §3 AUD-046; Cost §6.4; M0 §2.1/2.2",
   A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "Neon queue authority with generation/drained_generation under row lock; KV hint never cleared; unconditional backstop every 3 h; bound and CU estimate simulated",
   "0106 work_item/queue_state/wrk_claim; apps/worker/src/dispatch.js; tests/sim/dispatch_sim.mjs", "boolean flag cleared by consumer: lost wakeups (57 in control)", "0 lost; delay <= 316 min + 180 min per dispatcher crash; ~5 CU-h/month idle",
   "AT-Q-01, BB-PLAN-01, BB-PLAN-02, dispatch_sim", f"{EV16};{BB};{SIM}", "PASS (author)", "M0-D real Cron/KV/Neon metrics", "", "", "propose G0 closure", "apps/worker/src/dispatch.js"),
 "AUD-047": ("P1", "Independent second-copy objective conflicts with archive egress throttling", "Handoff §3 AUD-047; Arch §C2.8; Backup §9/§11; Cost §6.3/§11",
   P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING;OWNER_DECISION_REQUIRED (DR-02 before real data)", "Capacity model (1 GB / 4 GB): 24 h target not met for onboarding; optional fail-closed require_dual_copy_before_approval implemented; recoverability disclosed",
   "0109; tests/sim/archive_capacity.py", "24 h stated as design exposure", "37-74 days (1 GB) / 148-297 days (4 GB) single-copy exposure disclosed; gate tested",
   "AT-ARC-02, archive_capacity", f"{EV16};EVIDENCE/sim/archive_capacity.json", "PASS (author, model + gate)", "M0-B-08, M0-F", "", "DR-02", "keep open: capacity trade-off requires M0 measurement and Owner risk acceptance", "db/migrations/0109_archive_integrity_and_dual_copy_gate.sql"),
 "AUD-048": ("P1", "Separate independent-PWA acceptance from optional AI-host qualification", "Handoff §3 AUD-048; Arch §0.5 OWN-01",
   "DOCUMENTED_MATRIX", "DOCUMENTED_DESIGN", "NOT_IMPLEMENTED (PWA)", "Three-axis acceptance matrix; host statuses NOT_TESTED; OWN-01 unchanged",
   "docs/AUD-048_Acceptance_Matrix.md", "axes conflated", "separated; per-host status", "matrix (G0)", "docs/AUD-048_Acceptance_Matrix.md", "matrix delivered", "M0-A-06", "full no-AI PWA", "OWN-01 unchanged", "propose G0 closure of the matrix only", "docs/AUD-048_Acceptance_Matrix.md"),
 "AUD-049": ("P0", "Restricted migrator cannot be proven to execute/record ordered migrations", "Handoff §2 AUD-049; Draft-04 0001, tools/run_migrations.py",
   A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "B001 privileged bootstrap; bnx_migrator NOINHERIT + SET-only membership; runner: identity check, prefix/checksum verification, one transaction per migration, injected-failure rollback, privilege audit",
   "db/bootstrap/B001_bootstrap.sql; db/tools/run_migrations.py; 0101; 0108", "Draft-04 chain fails under bnx_migrator (AT-MIG-08)", "full chain under bnx_migrator on PG16+PG17",
   "AT-MIG-01..08", f"{EV16};{EV17}", "PASS (author, PG16+PG17)", "M0-C-06 Neon owner/migrator", "", "", "propose G0 closure", "db/tools/run_migrations.py"),
 "AUD-050": ("P0", "Backups will not automatically read newly created tables and sequences", "Handoff §2 AUD-050; Draft-04 0001/0007",
   A, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING", "ALTER DEFAULT PRIVILEGES for bnx_definer (bnx, bnx_rpt) and bnx_auth (auth), tables AND sequences; audit rule DEFAULT_PRIVILEGE_MISSING/BACKUP_CANNOT_READ",
   "B001; 0108 audit_privileges", "pg_dump as bnx_backup fails after a new table (AT-BAK-02)", "dump before/after new bnx table+identity and auth table+serial; isolated restore verified",
   "AT-BAK-01, AT-BAK-02 (control), AT-MIG-06", "EVIDENCE/pg16/AT-BAK-01_*;EVIDENCE/pg16/AT-BAK-02_draft04_dump.log", "PASS (author, PG16); PG17 dump NOT_EXECUTED", "M0-E Neon permissions + GCS restore", "", "", "propose G0 closure (PG16)", "db/bootstrap/B001_bootstrap.sql"),
 "AUD-051": ("P1", "Snapshot replay authorization omits actor/role/active-member checks", "Handoff §3 AUD-051; Draft-04 0006 snapshot_replay_access",
   A, "AUTHOR_RUNTIME_EVIDENCE", "", "Audience-bound decision (member + connection/channel), active member, requested scope, uniform NOT_AVAILABLE, ACCESS_REVOKED, Owner T3 audit replay",
   "0107", "suspended non-audience member gets 'ok' on zero-scope snapshot (AT-SNAP-05)", "rejected", "AT-SNAP-03, AT-SNAP-04, AT-SNAP-05 (control)", EV16, "PASS (author)", "API/MCP on M0", "historic reports R01-R34", "", "propose G0 closure", "db/migrations/0107_snapshot_authz.sql"),
 "AUD-052": ("P1", "Bitemporal ownership and scope can have nondeterministic ties", "Handoff §3 AUD-052; Draft-04 0002/0006",
   A, "AUTHOR_RUNTIME_EVIDENCE", "", "event_seq tie-breaker; unique same-version ties rejected; deferred share total <= 100 per date and version; commands",
   "0104; 0106 cmd_record_ownership/cmd_set_account_scope", "same-version tie accepted (AT-OWN-06)", "OWNERSHIP_TIE / OWNERSHIP_OVER_100", "AT-OWN-05, AT-OWN-06 (control)", EV16, "PASS (author)", "M0-C", "ownership UI", "", "propose G0 closure", "db/migrations/0104_ownership_determinism.sql"),
 "AUD-053": ("P1", "No black-box proof of the production Command Core / approval lifecycle", "Handoff §3 AUD-053; Draft-04 tests/000_support.sql",
   P, "AUTHOR_RUNTIME_EVIDENCE", "M0_PENDING;NOT_IMPLEMENTED (rest of G2)", "Command Core vertical slice (sessions, OAuth/PKCE, idempotency, journals, corrections, openings, ownership, plans, queue, audit chain, outbox) + REST/MCP Worker + black-box suite",
   "0106-0109; apps/worker", "t.* helpers under superuser", "real roles; 26 G0 tests + 7 black-box tests", "AT-CMD-*, AT-CONC-*, AT-PLAN-*, AT-FAULT-01, BB-*", f"{EV16};{EV17};{BB}", "PASS (author, M0 prototype scope)", "M0-C integration", "full product", "", "propose G0 closure for the M0 prototype scope only", "db/migrations/0106_command_core.sql"),
 "AUD-054": ("P2", "Source-link event PK cannot record repeated same-event transitions", "Handoff §3 AUD-054; Draft-04 0005",
   A, "AUTHOR_RUNTIME_EVIDENCE", "", "Immutable event identity + enforced state machine + chained prior_event_id; old table retired read-only",
   "0105", "reserved->released->reserved fails (AT-SRC-02)", "recorded", "AT-SRC-01, AT-SRC-02 (control)", EV16, "PASS (author)", "", "matching/reconciliation acceptance", "", "propose G0 closure", "db/migrations/0105_source_link_events.sql"),
}
NEW_IDS = [
 ("NEW-048", "P0", "Deferred constraint triggers run as the session role at COMMIT, not as the definer: completeness checks failed with 'permission denied' for bnx_app",
  "Found while executing AUD-044 through real roles; fixed by SECURITY DEFINER trigger functions (0102, 0104); rule D3 added", "AT-BAL-03, AT-CONC-02, AT-OWN-05"),
 ("NEW-049", "P1", "Owner/admin could grant themselves access to another member's private account via cmd_set_grant",
  "Found in adversarial review; private-account grants restricted to the creator, uniform NOT_AVAILABLE (0106)", "AT-CMD-03"),
 ("NEW-050", "P2", "Worker mapped calls of unknown command names to HTTP 500", "42883 mapped to 404 NOT_FOUND", "BB-API-02"),
 ("NEW-051", "P1", "A compromised bnx_authn credential can mint sessions for any registered Google subject (the database cannot verify the RS256 signature)",
  "Residual risk disclosed; mitigation candidates in CLAUDE_SELF_REVIEW §4 (M0)", "—"),
 ("NEW-052", "P2", "pg_dump 17 not available locally: backup path not executed on PostgreSQL 17", "NOT_EXECUTED; production must pin pg_dump major = server major", "AT-BAK-01 (SKIP on pg17)"),
]

# AI-first proposal impact (BNX-AI-FIRST-DESIGN-DELTA-2026-10-30-V1.0); "after approval" = only after a recorded Owner scope decision
AI = {
 "AUD-002": ("Traditional workflows primary vs AI-dependent minimal PWA: direct conflict", "G2 axis-1 scope (AUD-048) and Arch §A/§I PWA journeys"),
 "AUD-003": ("Extraction responsibility moves to user-invoked AI; text/scan/OCR accuracy obligation unchanged", "M0-B OCR tests may be replaced only by equivalent synthetic-oracle AI-extraction tests"),
 "AUD-004": ("ChatGPT primary retained; host features NOT_VERIFIED", "none (OWN-01 unchanged)"),
 "AUD-009": ("F7 consumes reconciliation; R13/R15 become backend controls", "R13/R15 acceptance tests restated as F7 control tests"),
 "AUD-013": ("34 report contracts -> F1-F7 + standalone R28 + 7 controls + 3 deferred (proposal)", "Arch §I2 acceptance, AT-RPT-*, R2 §5 P0 conditions"),
 "AUD-015": ("Historical onboarding via AI drafts; plan/claim/activation machinery unchanged", "intake envelope -> posting_plan freeze contract"),
 "AUD-017": ("Identity tuple unchanged; AI must not see full numbers (conflict with AI reading statements)", "fingerprint capture path; Owner privacy decision"),
 "AUD-018": ("Drive intake location is not the evidence vault; R2 + trusted SHA unchanged", "none"),
 "AUD-019": ("AI batch duplicates/relinks increase reliance on fingerprints and AUD-054 machine", "none"),
 "AUD-024": ("Statement balance-chain check becomes the primary guard on AI extraction", "AT-REC criteria extended to AI drafts"),
 "AUD-027": ("AI proposes economic types; B6.1 rule table enforcement (not in R1) becomes mandatory", "none (already Draft-04 contract)"),
 "AUD-028": ("Drive archives need ledger/source/ownership/FX revision metadata and STALE", "report_snapshot metadata extension"),
 "AUD-030": ("AI hosts see source documents; existence oracle and dedup unchanged", "Owner privacy decision on AI-host data handling"),
 "AUD-032": ("Unattended CLI agent spec superseded in practice by user-invoked AI (proposal)", "Arch §C5 agent text, after approval"),
 "AUD-036": ("No scheduled paid LLM; Cron/queue/STALE marking remain cloud-only", "none"),
 "AUD-039": ("R28 lender/borrower identities rely on bitemporal holders/ownership", "none"),
 "AUD-040": ("Drive archive increases historical disclosure surface", "archive ACL contract"),
 "AUD-041": ("Old Drive links must not bypass current grants", "authenticated proxy or Drive permission revocation"),
 "AUD-042": ("Drive report archive is NOT the evidence second copy", "none"),
 "AUD-044": ("Unchanged: AI-proposed entries still pass the DB completeness assertion", "none"),
 "AUD-045": ("Higher reliance: AI-extracted currency/amount must pass composite FK + scale", "none"),
 "AUD-046": ("STALE marking/outbox use the same queue liveness", "none"),
 "AUD-047": ("Drive intake/archive does not create a verified second copy", "none"),
 "AUD-048": ("Material conflict: minimal PWA requires Owner scope decision", "G2 axis-1 contract"),
 "AUD-049": ("Unchanged", "none"),
 "AUD-050": ("New R28/intake/report-archive tables must be covered (default privileges already do)", "none"),
 "AUD-051": ("Drive archives: zero-scope/old actor/current-grant checks apply to links and metadata", "archive access contract"),
 "AUD-052": ("R28 lender/borrower, Joint and backdated ownership need stable resolution", "none"),
 "AUD-053": ("AI host, PWA and MCP must share the same cmd_/q_ path; propose (T1) tools NOT_IMPLEMENTED", "MCP tool list after approval"),
 "AUD-054": ("AI batch void/rebuild/relink paths covered by the state machine", "none"),
}

hdr = ["aud_id", "severity", "origin", "title", "source_reference", "draft04_author_disposition", "draft04_evidence_status", "r1_status", "evidence_grade",
       "predicates", "r1_change", "files_objects", "before_behavior", "after_behavior", "tests", "evidence_paths", "g0", "g1_m0", "g2", "owner_decision",
       "proposed_closure_for_reviewer", "primary_file_sha256_16", "ai_first_impact", "changes_only_after_owner_scope_approval"]
rows = []
for i in range(1, 44):
    a = f"AUD-{i:03d}"
    d = D04[a]
    src = f"Draft-04 Traceability §3 {a}; refs: {d['References']}"
    if a in R1:
        st, gr, pr, ch, fo, be, af, te, evp, g0, g1, g2, ow, prop, pf = R1[a]
    else:
        st, gr, pr, ch, fo, be, af = U, "DOCUMENTED_DESIGN" if d["Disposition"] != "TEST_PENDING" else "UNTESTED_PROPOSAL", \
            ("OWNER_DECISION_REQUIRED" if d["Disposition"] == "OWNER_DECISION_PENDING" else ("M0_PENDING" if d["Disposition"] == "TEST_PENDING" else "")), \
            "no R1 change", "—", "—", "—"
        te, evp, g0, g1, g2, ow, prop, pf = d["Tests"], "—", "no new G0 evidence", "per Draft-04", "per Draft-04", d["Residual / dependency"], "none (carry)", ""
    rows.append([a, d["sev"], d["round"], d["title"], src, d["Disposition"], d["Evidence status"], st, gr, pr, ch, fo, be, af, te, evp, g0, g1, g2, ow, prop, sha(pf), *AI.get(a, ("no material impact", "none"))])
for a, v in NEWER.items():
    sev, title, src, st, gr, pr, ch, fo, be, af, te, evp, g0, g1, g2, ow, prop, pf = v
    rows.append([a, sev, "Final consolidated audit (Draft-04)", title, src, "NOT_PRESENT_IN_DRAFT04", "—", st, gr, pr, ch, fo, be, af, te, evp, g0, g1, g2, ow, prop, sha(pf), *AI.get(a, ("no material impact", "none"))])
for nid, sev, title, ch, te in NEW_IDS:
    rows.append([nid, sev, "R1 author (Claude)", title, "R1 implementation", "—", "—", A if nid not in ("NEW-051", "NEW-052") else "OPEN_RISK" if nid == "NEW-051" else "NOT_EXECUTED",
                 "AUTHOR_RUNTIME_EVIDENCE" if te != "—" else "ASSUMPTION", "", ch, "", "", "", te, EV16 if te != "—" else "", "", "", "", "", "reviewer adjudication", "", "", ""])
assert len({r[0] for r in rows if r[0].startswith("AUD-")}) == 54
with open(os.path.join(ROOT, "AUD001_054_Master_Tracker.csv"), "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(hdr)
    w.writerows(rows)
print(f"rows={len(rows)} aud={sum(r[0].startswith('AUD-') for r in rows)} new={sum(r[0].startswith('NEW-') for r in rows)}")
