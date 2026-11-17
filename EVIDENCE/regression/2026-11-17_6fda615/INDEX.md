# Regression record 2026-11-17 12:46 UTC — commit `6fda615427a9f812abea3e3d10389ad99f42b7b9`

- Branch: `s4/statement-draft`
- Commit: `6fda615427a9f812abea3e3d10389ad99f42b7b9`
- Finished: 2026-11-17T12:46:51.596144+00:00

- Runner: author (`AUTHOR_RUNTIME_EVIDENCE`); local PostgreSQL 16 and 17, Node black-box and Playwright PWA suites, dispatcher simulation (scratchpad `regrun.sh`)
- Note: 10 failures from 3 causes, all in this commit, fixed in the next: (1) release/manifest.json held a 9043 hash from before the last edit (AT-INS-01, AT-SIG-01 on pg16 and pg17); (2) AT-PWA-LA-01 still expected q_ledger_accounts to be PWA-only, but 9043 makes it the MCP read tool fin.ledger.accounts - test updated to assert the consented account subset and the refusal without finance.read; (3) node: UT-BIND-01 'newer database' case still used 9043 (now the head; uses 9044), AT-CONF-04 card-bound tool list lacked fin_draft_create_statement, AT-MENU-01/02 (pg16, pg17) the three new PWA catalog entries were not in the closed menu (added to item 4 Review with labels in both languages).

**Totals:** 474 pass, 10 fail, 3 skip

| Suite | Pass | Fail | Skip |
|---|---|---|---|
| blackbox | 34 | 2 | 0 |
| pg16.run_g0 | 40 | 0 | 0 |
| pg16.run_s4_core1 | 12 | 0 | 0 |
| pg16.run_s4_core10 | 7 | 0 | 0 |
| pg16.run_s4_core11 | 5 | 0 | 0 |
| pg16.run_s4_core12 | 8 | 0 | 0 |
| pg16.run_s4_core13 | 11 | 0 | 0 |
| pg16.run_s4_core14 | 5 | 0 | 0 |
| pg16.run_s4_core15 | 7 | 0 | 0 |
| pg16.run_s4_core16 | 2 | 1 | 0 |
| pg16.run_s4_core17 | 6 | 0 | 0 |
| pg16.run_s4_core18 | 11 | 1 | 0 |
| pg16.run_s4_core19 | 6 | 1 | 0 |
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
| pg17.run_g0 | 38 | 0 | 2 |
| pg17.run_s4_core1 | 12 | 0 | 0 |
| pg17.run_s4_core10 | 7 | 0 | 0 |
| pg17.run_s4_core11 | 5 | 0 | 0 |
| pg17.run_s4_core12 | 8 | 0 | 0 |
| pg17.run_s4_core13 | 11 | 0 | 0 |
| pg17.run_s4_core14 | 5 | 0 | 0 |
| pg17.run_s4_core15 | 6 | 0 | 1 |
| pg17.run_s4_core16 | 2 | 1 | 0 |
| pg17.run_s4_core17 | 6 | 0 | 0 |
| pg17.run_s4_core18 | 11 | 1 | 0 |
| pg17.run_s4_core19 | 6 | 1 | 0 |
| pg17.run_s4_core2 | 12 | 0 | 0 |
| pg17.run_s4_core20 | 3 | 0 | 0 |
| pg17.run_s4_core3 | 9 | 0 | 0 |
| pg17.run_s4_core4 | 11 | 0 | 0 |
| pg17.run_s4_core5 | 8 | 0 | 0 |
| pg17.run_s4_core6 | 8 | 0 | 0 |
| pg17.run_s4_core7 | 5 | 0 | 0 |
| pg17.run_s4_core8 | 8 | 0 | 0 |
| pg17.run_s4_core9 | 4 | 0 | 0 |
| pg17.run_s4_core_9011r | 11 | 0 | 0 |
| pwa_pg16 | 22 | 1 | 0 |
| pwa_pg17 | 22 | 1 | 0 |
| sim | 1 | 0 | 0 |

Raw outputs are the `*.txt` files beside this index; per-suite result JSON files are under `results/`.
