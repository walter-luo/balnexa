# Regression record 2026-11-20 13:12 UTC — commit `60a4f61a24d573fa6b8cedeed02378ff227903ac`

- Branch: `s4/categories-accounts`
- Commit: `60a4f61a24d573fa6b8cedeed02378ff227903ac`
- Finished: 2026-11-20T13:12:04.005384+00:00
- Label: `pg16-only`
- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 only (see the note), Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: Local PostgreSQL 16 only: PGDG PostgreSQL 17 packages are not reachable from this workspace (403); PG17 and ICU run in CI. Earlier run on a1e7753 failed AT-OUT-01 only (new curated output schema not yet exercised); fixed in 60a4f61.

**Totals:** 268 pass, 0 fail, 0 skip

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
| pg16.run_s4_core3 | 9 | 0 | 0 |
| pg16.run_s4_core4 | 11 | 0 | 0 |
| pg16.run_s4_core5 | 8 | 0 | 0 |
| pg16.run_s4_core6 | 8 | 0 | 0 |
| pg16.run_s4_core7 | 5 | 0 | 0 |
| pg16.run_s4_core8 | 8 | 0 | 0 |
| pg16.run_s4_core9 | 4 | 0 | 0 |
| pg16.run_s4_core_9011r | 11 | 0 | 0 |
| pwa_pg16 | 24 | 0 | 0 |
| sim | 1 | 0 | 0 |

Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`.
