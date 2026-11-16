# Regression record 2026-11-15 21:33 UTC — commit `736c79035d2bb81972d735d7489118f06cf23dbd`

- Branch: `s4/idle-tick`
- Commit: `736c79035d2bb81972d735d7489118f06cf23dbd`
- Finished: 2026-11-15T21:33:29.198706+00:00

- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 and 17, Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: BB-ISO-04 failed: after #52 an idle tick no longer runs the binding check, and the test ticked at Date.now() with an empty KV, so it passed only on a backstop tick (the pre-commit run happened at 21:0x UTC). Fixed in the next commit by hinting work and ticking at a fixed time.

**Totals:** 477 pass, 1 fail, 3 skip

| Suite | Pass | Fail | Skip |
|---|---|---|---|
| blackbox | 35 | 1 | 0 |
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
| pg17.run_s4_core18 | 12 | 0 | 0 |
| pg17.run_s4_core19 | 7 | 0 | 0 |
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
