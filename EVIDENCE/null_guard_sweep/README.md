# NULL-guard sweep evidence (L-R2-1)

Method and dispositions: `docs/s4/S4_L-R2-1_NULL_Guard_Sweep_2026-11-14.md`, `tools/s4/null_guard_dispositions.json`. Synthetic data only. The reports keep function names, key paths, modes and counts, with no values. The raw `sweep.jsonl` is not committed.

| Folder | Migration head | Server | Suites (exit 0) | Pairs tried | Accepted | must_refuse still accepted | Note |
|---|---|---|---|---|---|---|---|
| [9039_before](9039_before/report.md) | 9039 | PG 16 | 20 of 21 | 455 | 169 | 14 | Before the fix. `run_s4_core7` exited 1 only in sweep mode: the first harness version kept a cached connection that blocked a database copy. The sweep tool was fixed (one short connection per call) before the 9040 run |
| [9040](9040/report.md) | 9040 | PG 16 | 21 of 21 | 455 | 155 | 0 | After 9040; the check passes (exit 0) |

Re-check either run: `python3 tools/s4/null_guard_sweep.py --aggregate <run dir> [--head 9039]` (the run directory holds the raw file).
