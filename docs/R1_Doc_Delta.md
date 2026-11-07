# R6.2-R1 — Minimal exact documentation delta (proposed)

The Draft-04 documents are **not edited** (immutable baseline). Each row states the exact superseded statement (file and line in the Draft-04 file with the SHA-256 listed) and the replacement text, justified by executed R1 work. `docs/contradiction_sweep.py` checks that every Draft-04 occurrence of a superseded token is listed here.

| Draft-04 document | SHA-256 (prefix) |
|---|---|
| A = `Balnexa_Unified_Architecture_V1.0_R6.2_Draft04.md` | `4ad49225` |
| M = `Balnexa_HA_Platform_Qualification_M0_R6.2_Draft04.md` | `d31b0d35` |
| C = `Balnexa_Cloud_Cost_and_Quota_Model_R6.2_Draft04.md` | `ec6aed0d` |
| B = `Balnexa_Backup_and_Disaster_Recovery_R6.2_Draft04.md` | `20a3d996` |
| R = `Balnexa_Owner_Decision_Register_R6.2_Draft04.md` | `2c06f032` |
| K = `Balnexa_M0_Owner_Setup_Checklist_R6.2_Draft04.md` | `6449761d` |
| T = `Balnexa_Draft04_Consolidated_Review_and_Traceability.md` | `111f86ee` |

| Δ | Location(s) | Superseded statement | Replacement (R1) | Evidence |
|---|---|---|---|---|
| D-01 | A:794, A:815 | INV-01…04: completeness on line insert only; `jl_same_txn` deferred to M2 | INV-01…04/07/08 enforced by `bnx.assert_journal_complete` (deferred, fired by header and lines, SECURITY DEFINER) and composite `(id, currency)` FKs (`0102`, `0103`) | AT-BAL-01…05, AT-MUT-01 |
| D-02 | A:13, A:381, A:2323, A:2361, A:2389, A:2413, A:2445, A:2513; M:187 | Migration truth "0001–0007 + 9001", applied by a privileged runner | B001 privileged bootstrap + clean chain 0002–0006, 0101–0109, 9001 applied by `bnx_migrator` (`db/tools/run_migrations.py`); Draft-04 0001/0007 retained as history only | AT-MIG-01…08 |
| D-03 | A:385, A:500, A:534, A:1114, A:3178, A:3200, A:3204 | `source_txn_link_event` keyed `(source_txn, journal, event)` | `bnx.source_link_event` (event id, state machine, `prior_event_id`); old table retired read-only (`0105`) | AT-SRC-01/02 |
| D-04 | A:402, A:417, A:849, A:3305 | Replay if projection set ⊆ visible set | Audience-bound decision: same member; same AI connection when created through one; active member; requested scope and projection ⊆ current visible set; uniform `NOT_AVAILABLE`; Owner T3 audit replay (`0107`) | AT-SNAP-03…05 |
| D-05 | A:695 (B5.8), INV-47 | Ties broken by `recorded_version` | `event_seq` final tie-breaker; same-version same-date ties rejected; share total ≤ 100 per date and version, deferred (`0104`) | AT-OWN-05/06 |
| D-06 | A:936, A:1154, A:1838, A:1847; M:43, M:51, M:68; C:189 | KV boolean `work_pending`, set only when absent, cleared after drain | Neon `queue_state(generation, drained_generation)`; KV `bnx:hint`/`bnx:drained` never cleared; unconditional backstop rescan every 3 h; bound = 3 h + 5 min tick + outage + 10 min lease + 60 s KV lag (+3 h per dispatcher crash); dispatcher-only ≈ 5 CU-h/month idle, ≈ 7 normal, ≈ 23.5 onboarding | AT-Q-01, BB-PLAN-01/02, dispatch_sim |
| D-07 | A:965, A:2350, A:2394, A:2450; M:176 (M0-B-08); B:153 | Designed single-copy exposure ≤ 24 h | 24 h is a target that is **not met** for onboarding volumes under the 0.8 GiB meter (37–74 days for 1 GB, 148–297 days for 4 GB, factor 1–2); `dual_verified` only with a matching executor-trusted re-hash (`0109` trigger); optional `require_dual_copy_before_approval` | AT-ARC-02, archive_capacity |
| D-08 | B:112, B:125 (R4) | Restore mode "disables only the named non-immutability triggers" | No trigger is disabled. `bnx.restore_mode()` is true only when `session_user = 'bnx_migrator'` and `bnx.restore_mode = on`; it relaxes only INV-07 same-transaction and the source-link state machine; completeness, FKs, scale and ownership checks run on the restored data. pg_dump major must equal server major. | AT-BAK-01 |
| D-09 | A (rules D1/D2) | — (new rule) | **D3:** a deferred constraint trigger function must be SECURITY DEFINER with `search_path = pg_catalog, pg_temp` | NEW-048 |
| D-10 | R (new entry) | — | **DR-02 (Owner, before real data):** accept the disclosed onboarding single-copy window, or enable `require_dual_copy_before_approval`, or authorize evaluation of ARC-ALT-1 in M0-B-08 | RR-2 |
| D-11 | K | — | No change. (M0-C-06 already covers Neon role semantics; B001 runs as the Neon project owner, migrations as `bnx_migrator`.) | — |
| D-12 | T (whole document) | AUD-001…043 dispositions | Superseded for tracking by `AUD001_054_Master_Tracker.csv` (54 IDs + NEW-048…052); T is retained unchanged as history | tracker |
