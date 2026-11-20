# Regression record 2026-11-20 01:47 UTC — commit `b8fd7d237c958058692beb0bc67f5a03fc8f5441`

- Branch: `s4/skills-and-io`
- Commit: `b8fd7d237c958058692beb0bc67f5a03fc8f5441`
- Finished: 2026-11-20T01:47:15.075958+00:00
- Label: `pg16-only`
- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 only (see the note), Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: PG16 only: the PGDG repository is blocked by this session's network policy and no other PG17 source was used, so the PG17 suites, the PG17 PWA suite and the ICU en-US run are covered by CI on this commit's PR, not by this record.

**Totals:** 262 pass, 0 fail, 0 skip

| Suite | Pass | Fail | Skip |
|---|---|---|---|
| blackbox | 36 | 0 | 0 |
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
| pg16.run_s4_core3 | 9 | 0 | 0 |
| pg16.run_s4_core4 | 11 | 0 | 0 |
| pg16.run_s4_core5 | 8 | 0 | 0 |
| pg16.run_s4_core6 | 8 | 0 | 0 |
| pg16.run_s4_core7 | 5 | 0 | 0 |
| pg16.run_s4_core8 | 8 | 0 | 0 |
| pg16.run_s4_core9 | 4 | 0 | 0 |
| pg16.run_s4_core_9011r | 11 | 0 | 0 |
| pwa_pg16 | 23 | 0 | 0 |
| sim | 1 | 0 | 0 |

Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`.
