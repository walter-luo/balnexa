# Regression record 2026-11-21 12:05 UTC — commit `59d1e1894574b4ba4d4009c84fb9c5154ae4e66a`

- Branch: `s4/dry-run-sin`
- Commit: `59d1e1894574b4ba4d4009c84fb9c5154ae4e66a`
- Finished: 2026-11-21T12:05:31.220963+00:00
- Label: `pg16-only`
- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 only (see the note), Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: Local PostgreSQL 16 only: PGDG PostgreSQL 17 packages are not reachable from this workspace (403); PG17 and ICU run in CI. Earlier run on 1f36ceb failed AT-OUT-01 only (new curated output schema not yet exercised); fixed in 59d1e18.

**Totals:** 276 pass, 0 fail, 0 skip

| Suite | Pass | Fail | Skip |
|---|---|---|---|
| blackbox | 37 | 0 | 0 |
| pg16.run_g0 | 40 | 0 | 0 |
| pg16.run_s4_core1 | 12 | 0 | 0 |
| pg16.run_s4_core10 | 7 | 0 | 0 |
| pg16.run_s4_core11 | 5 | 0 | 0 |
| pg16.run_s4_core12 | 8 | 0 | 0 |
| pg16.run_s4_core13 | 11 | 0 | 0 |
| pg16.run_s4_core14 | 5 | 0 | 0 |
| pg16.run_s4_core15 | 7 | 0 | 0 |
| pg16.run_s4_core16 | 3 | 0 | 0 |
| pg16.run_s4_core17 | 6 | 0 | 0 |
| pg16.run_s4_core18 | 12 | 0 | 0 |
| pg16.run_s4_core19 | 7 | 0 | 0 |
| pg16.run_s4_core2 | 12 | 0 | 0 |
| pg16.run_s4_core20 | 3 | 0 | 0 |
| pg16.run_s4_core21 | 4 | 0 | 0 |
| pg16.run_s4_core22 | 4 | 0 | 0 |
| pg16.run_s4_core23 | 3 | 0 | 0 |
| pg16.run_s4_core3 | 9 | 0 | 0 |
| pg16.run_s4_core4 | 11 | 0 | 0 |
| pg16.run_s4_core5 | 8 | 0 | 0 |
| pg16.run_s4_core6 | 8 | 0 | 0 |
| pg16.run_s4_core7 | 5 | 0 | 0 |
| pg16.run_s4_core8 | 8 | 0 | 0 |
| pg16.run_s4_core9 | 4 | 0 | 0 |
| pg16.run_s4_core_9011r | 11 | 0 | 0 |
| pwa_pg16 | 25 | 0 | 0 |
| sim | 1 | 0 | 0 |

Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`.
