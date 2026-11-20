# Regression record 2026-11-20 21:22 UTC — commit `7d49750f0e2005aafbc8d05044ec20bf54666711`

- Branch: `s4/live-findings`
- Commit: `7d49750f0e2005aafbc8d05044ec20bf54666711`
- Finished: 2026-11-20T21:22:10.137078+00:00
- Label: `pg16-only`
- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 only (see the note), Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: Local PostgreSQL 16 only: PGDG PostgreSQL 17 packages are not reachable from this workspace (403); PG17 and ICU run in CI.

**Totals:** 273 pass, 0 fail, 0 skip

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
