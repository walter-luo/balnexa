# G0 independent PWA-only run (PWA-R1) 2026-11-13 — disposition

`DRAFT — AI-generated` (the author: Claude). Report: `docs/s4/reviews/g0/20261113_chatgpt-codex-pwa/REPORT.md` with `raw/`, returned by the reviewer as draft PR #43 (R1). The Owner also uploaded the same report; that copy differs only in dash characters and line endings, so it is not committed twice. Runner: GPT-5 family, ChatGPT Work Mode, on native Windows 11. Code under test: `15e5eb0` (#42). Grade: `NOT_EXECUTED` for both lanes. The suite's set-up failed before Chromium launched, so no PWA test ran.

## Findings

| ID | Reviewer | Author's verdict | Action |
|---|---|---|---|
| G0-PWA-01: B001 had no effect on native Windows, then the migrator failed with `role "bnx_migrator" does not exist`; a direct `run_bootstrap()` probe hung for more than 5 minutes | blocker (for the environment) | **Platform, plus a real harness weakness.** Native Windows is not a supported platform for the harness: CI, the recipe in the prompt and the Executor image are Linux. The raw output (PR #43) shows only the later failure, the missing role; psql's own output for B001 was not captured, so the exact Windows cause cannot be determined. Candidates: psql waiting on an interactive prompt (stdin was not redirected), or a path or quoting difference. **The harness weakness is real.** `run_bootstrap` trusted psql's exit status. A psql that exits 0 without applying the file went undetected, and the failure only surfaced later as a missing role. It also had no time limit | `run_bootstrap` now runs psql with stdin closed and a 300-second limit, then checks that the file's version is recorded in `bnx.schema_bootstrap`. Tested with a stand-in psql that exits 0 and does nothing: the error is now raised at the bootstrap step, naming the file. Both prompts now state that the supported platform is Linux x86-64 (native, WSL2 or a Linux guest) |
| G0-PWA-02: the hash-pinned Pillow wheel is rejected on Windows | medium | **By design.** `apps/executor/requirements.txt` pins manylinux x86-64 wheels only, as its header says. The Executor runs as a Linux container | Stated in the prompts (Linux only). No change to the pins |

## Status of G0-PWA-1

Still open. No independent run has executed the PWA suite yet. The options are the same as in `G0_IND_R3_DISPOSITION_2026-11-13.md`, plus one:

1. Accept `AUTHOR_RUNTIME_EVIDENCE` plus CI.
2. An independent run on Linux. The new option is **WSL2 (Ubuntu) on a Windows machine**, with the same ChatGPT Work Mode following the Linux recipe inside WSL2. This needs administrator rights and a restart, so it is the Owner's decision.
3. A clean Claude session (for example Claude Code with Sonnet), graded `SAME_FAMILY_VERIFICATION`.

## Note for reviewers who run on their own machine

A Work Mode run installs software and starts local PostgreSQL clusters on the machine it runs on (here: ports 55416 and 55417). Stop the clusters, and remove the software if it is not wanted, after the run.
