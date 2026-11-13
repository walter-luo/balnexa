# Regression record 2026-11-13 11:13 UTC — commit `82c425e443819c1d96916c68eacbc5f550279088`

- Branch: `s4/report-rows-2`
- Commit: `82c425e443819c1d96916c68eacbc5f550279088`
- Finished: 2026-11-13T11:13:14.103493+00:00
- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 and 17, Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: 2.8 part 8 (9037) + validator parity. Local PG17 = @embedded-postgres 17.11 without pg_dump 17 (3 skips; CI runs them).

**Totals:** 467 pass, 0 fail, 3 skip

| Suite | Pass | Fail | Skip |
|---|---|---|---|
| blackbox | 35 | 0 | 0 |
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
| pg16.run_s4_core18 | 8 | 0 | 0 |
| pg16.run_s4_core19 | 6 | 0 | 0 |
| pg16.run_s4_core2 | 12 | 0 | 0 |
| pg16.run_s4_core3 | 9 | 0 | 0 |
| pg16.run_s4_core4 | 11 | 0 | 0 |
| pg16.run_s4_core5 | 8 | 0 | 0 |
| pg16.run_s4_core6 | 8 | 0 | 0 |
| pg16.run_s4_core7 | 5 | 0 | 0 |
| pg16.run_s4_core8 | 8 | 0 | 0 |
| pg16.run_s4_core9 | 4 | 0 | 0 |
| pg16.run_s4_core_9011r | 11 | 0 | 0 |
| pg17.run_g0 | 38 | 0 | 2 |
| pg17.run_s4_core1 | 12 | 0 | 0 |
| pg17.run_s4_core10 | 7 | 0 | 0 |
| pg17.run_s4_core11 | 5 | 0 | 0 |
| pg17.run_s4_core12 | 8 | 0 | 0 |
| pg17.run_s4_core13 | 11 | 0 | 0 |
| pg17.run_s4_core14 | 5 | 0 | 0 |
| pg17.run_s4_core15 | 6 | 0 | 1 |
| pg17.run_s4_core16 | 3 | 0 | 0 |
| pg17.run_s4_core17 | 6 | 0 | 0 |
| pg17.run_s4_core18 | 8 | 0 | 0 |
| pg17.run_s4_core19 | 6 | 0 | 0 |
| pg17.run_s4_core2 | 12 | 0 | 0 |
| pg17.run_s4_core3 | 9 | 0 | 0 |
| pg17.run_s4_core4 | 11 | 0 | 0 |
| pg17.run_s4_core5 | 8 | 0 | 0 |
| pg17.run_s4_core6 | 8 | 0 | 0 |
| pg17.run_s4_core7 | 5 | 0 | 0 |
| pg17.run_s4_core8 | 8 | 0 | 0 |
| pg17.run_s4_core9 | 4 | 0 | 0 |
| pg17.run_s4_core_9011r | 11 | 0 | 0 |
| pwa_pg16 | 23 | 0 | 0 |
| pwa_pg17 | 23 | 0 | 0 |
| sim | 1 | 0 | 0 |

Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`.
