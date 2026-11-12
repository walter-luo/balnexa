# Test records policy (Owner instruction 2026-11-12 16:08)

> "自我测试不要减少，测试记录要保留，保留在GitHub？以便上线后不再做重复测试。"
>
> ("Do not reduce self-testing; keep the test records, in GitHub, so that the tests are not repeated after go-live.")

| Rule | How |
|---|---|
| Every PR gets the full local regression before it is pushed | PG16 and PG17 Python suites (R1 G0 and every `run_s4_core*`), the black-box and unit suites, the Playwright PWA suite on both majors, and the dispatcher simulation (scratchpad `regrun.sh`) |
| Each run is kept in the repository | `tools/s4/record_regression.py --from <run dir> --sha <commit> --branch <name>` writes `EVIDENCE/regression/<date>_<sha7>/` with the raw outputs, the per-suite result JSON files and `INDEX.md`, and adds a row to `EVIDENCE/regression/README.md` |
| Records pass guard C6 | The repository SIN scan and gitleaks run on the records before they are committed |
| CI is a second, independent run on GitHub | Every push; its logs stay with the PR |
| Grade | The records are `AUTHOR_RUNTIME_EVIDENCE`. Acceptance after go-live can cite a record for the exact commit that is deployed. Phase 1 still requires an independent G0 runner |

## Coverage on 2026-11-12

- PRs #22–#27 had targeted runs plus CI.
- The full record of `9b959c7` (stack head #28) covers their code.
