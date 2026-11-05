# Balnexa — DB migrations and tests (R6.2-Draft-04)

Development and CI material only (Architecture §H12). Synthetic data only. Nothing here touches Neon, Google Cloud or real data.

| Path | Content |
|---|---|
| `migrations/0001…0007_*.sql` | Normative, executable DDL for the migrated objects (Architecture Appendix B-M): roles, schemas, extensions; reference data and accounts with bitemporal ownership; ledger, plans, batches, anchors, scope claims, snapshots; evidence with write-once integrity, archive state and explicit T3 grants; source transactions and decision events; version-aware readers and live authorization functions; grants |
| `migrations/9001_import_draft02_logical_state.sql` | One-time conversion of a Draft-02 logical state (schema `d02`); no-op otherwise |
| `tools/run_migrations.py` | Applies migrations in order, one transaction each, with checksum; refuses changed applied migrations |
| `tools/sqllint.py` | Duplicate-object and undefined-`ALTER` lint over a Markdown document's `sql` blocks |
| `tools/excerpt_check.py` | Executes every not-yet-migrated DDL excerpt on top of the migrations, in foreign-key order |
| `tests/000_support.sql` | Test-support functions (schema `t`); never a migration |
| `tests/010…060_*.sql`, `fixtures/` | Database acceptance checks and the Draft-02 conversion fixture |
| `tests/run_tests.py`, `tests/last_run.txt` | Runner and the recorded run (PostgreSQL 16.15) |
| `backup_keyring_sim/keyring_sim.py`, `last_run.txt` | AUD-038 simulation with the `age` CLI and synthetic keys |

```bash
python3 tests/run_tests.py --server "host=<socket dir> port=<port> user=postgres"   # empty, disposable cluster
python3 backup_keyring_sim/keyring_sim.py
```

Status: executed locally by the author. **Not** executed on Neon (M0-C-06) and not yet independently reproduced. Role semantics on Neon remain REQUIRES_M0_EVIDENCE (NEW-010).
