# G0 independent run — PWA only (prompt)

`DRAFT — AI-generated` (the author: Claude). This closes the one gap that all three independent G0 runs (R1–R3) left open: the
PWA suite was `NOT_EXECUTED` each time, because the reviewer's workspace could not download Playwright's Chromium (HTTP 403).
Open question G0-PWA-1 in `docs/s4/reviews/G0_IND_R3_DISPOSITION_2026-11-13.md`.

## For the Owner: how to use this file

1. Give the reviewer this file's URL on branch `s4/pwa-system-chromium`, or paste the section **Prompt** below:
   `https://github.com/walter-luo/balnexa/blob/s4/pwa-system-chromium/docs/s4/reviews/G0_PWA_RUN_PROMPT.md`
2. The reviewer needs a **terminal** that can install packages and run PostgreSQL, Python and Node. A browser it can only
   click in is not enough: the tests drive Chromium from Node.
3. The result comes back as R1 (a PR) or R2 (pasted to you); hand it to the author's next session as before.

## Prompt

You are an **independent G0 runner** for the open-source repository `walter-luo/balnexa` (public, Apache-2.0). Run **only the
PWA suite** (`tests/pwa/pwa.test.mjs`, Playwright, 23 tests) on PostgreSQL 16 and 17, and report. You did not write this code.
Work adversarially.

### Target

- **Code under test:** the head of branch `s4/pwa-system-chromium` (draft PR #42). State the SHA (`git rev-parse HEAD`).
- Its only code change from #41 is that the PWA suite can use an already installed Chromium: set `BNX_CHROMIUM` to the
  executable. Unset, it uses Playwright's own download, as before.

### Rules (all mandatory)

1. Do not change the code under test, or any existing branch or PR.
2. Synthetic data only; never write a Social Insurance Number or any SIN-shaped value anywhere. No secrets. No cloud resources.
3. Grade every verdict: `VERIFIED_INDEPENDENT` (you executed it and are not a Claude/Anthropic model),
   `SAME_FAMILY_VERIFICATION` (you executed it and are a Claude model), or `NOT_EXECUTED`. State your model family and platform.
4. Run one database suite at a time; name any database of your own `bnx_g0_*`.

### Environment

- **PostgreSQL 16 and 17** with clusters on these sockets and ports (or set `BNX_PG16` / `BNX_PG17` to libpq DSNs):

  ```bash
  for V in 16 17; do
    D=/var/lib/postgresql/ci$V; S=/var/lib/postgresql/bnx$V
    sudo install -d -o postgres -g postgres -m 0755 "$D" "$S"
    sudo -u postgres /usr/lib/postgresql/$V/bin/initdb -D "$D/data" -U postgres --auth=trust -E UTF8 --locale=C.UTF-8
    sudo -u postgres /usr/lib/postgresql/$V/bin/pg_ctl -D "$D/data" -o "-p 554$V -k $S -c listen_addresses=" -l "$D/server.log" -w start
  done
  ```
- **Python 3.12 or 3.13** (the suite starts the local stack through Python):

  ```bash
  pip install "psycopg[binary]==3.2.3"
  pip install --only-binary=:all: "cryptography==50.0.1"
  pip install --require-hashes --only-binary=:all: -r apps/executor/requirements.txt
  ```
- **Node 22:** `npm ci` in `apps/worker` and in `tests/pwa`.
- **A Chromium, in this order of preference:**
  1. `cd tests/pwa && npx playwright install --with-deps chromium` (Playwright 1.63.0). If that works, leave `BNX_CHROMIUM` unset.
  2. If the download is blocked, use a Chromium the system already has or can install from its own package manager. For
     example: `apt-get install -y chromium` (or `chromium-browser`), or an existing Chrome/Chromium. Find its path
     (`command -v chromium chromium-browser google-chrome`) and `export BNX_CHROMIUM=/path/to/it`. Install the browser's
     OS libraries if it does not start (`npx playwright install-deps chromium` needs no download from the Playwright CDN).

  The suite prints a line `browser: … version …` at the start. Copy it into your report. A browser other than Playwright's
  own build is supported on a best-effort basis. If a failure looks browser-specific, say so and include the error.

### Run

```bash
S=/tmp/g0pwa; mkdir -p $S
for srv in pg16 pg17; do
  (cd tests/pwa && BNX_SERVER=$srv BNX_PY="$(which python3)" node --test --test-concurrency=1 pwa.test.mjs) > $S/pwa_$srv.txt 2>&1
done
grep -E "browser:|^# (pass|fail|skipped)" $S/pwa_pg16.txt $S/pwa_pg17.txt
```

**Author's claim:** each major gives **23 pass, 0 fail**. That is the author's local runs plus CI, on Playwright's bundled
Chromium and, at this commit, also locally with `BNX_CHROMIUM` set to a separately installed Chromium 153.

### Report

Write `docs/s4/reviews/g0/<YYYYMMDD>_<runner>-pwa/REPORT.md` with:

1. **Header:** model family, version and platform; date; tested SHA; PostgreSQL 16/17, Python, Node, Playwright versions;
   the `browser:` line; whether `BNX_CHROMIUM` was set.
2. **Verdict table:** `A PWA PG16` and `A PWA PG17`, each PASS / FAIL / PARTIAL with a grade.
3. **Findings**, numbered `G0-PWA-01`, …: severity, file:line, what you saw, how to reproduce. Do not fix code.
4. **What you could not do, and why.**

Put `pwa_pg16.txt` and `pwa_pg17.txt` in `raw/` beside the report.

### Return the result

- **R1 (you can push):** branch `review/g0-<runner>-pwa-<YYYYMMDD>` from the tested commit, commit only your report folder,
  and open a **draft** PR into `s4/pwa-system-chromium` with the verdict table in the body.
- **R2 (you cannot push):** reply with the full `REPORT.md` in one fenced block, plus the `browser:` line and the
  `# pass` / `# fail` lines of both raw files.
