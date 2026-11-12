# Balnexa S4 phase 2.6 (part) — INS-1 release manifest

`DRAFT — AI-generated`.

`tools/s4/release_manifest.py` builds `release/manifest.json` (format `bnx-release-manifest/1.0`). The manifest records:
- the Worker release, its schema range and its work kinds;
- every migration with the SHA-256 the runner stores, and the minimum Worker release for that migration;
- the Executor version and the PWA shell version;
- an SBOM: npm lockfiles (`apps/worker`, `deploy`) and the hash-pinned Python requirements.

Nothing in the manifest is secret.

| Rule | Check |
|---|---|
| R1 | The Worker's extension range ends at the newest migration and starts at most one migration earlier (N-1) |
| R2 | Migration file names are `NNNN_name.sql` and versions strictly increase |
| R3 | `min_worker_release` is the first release that listed the migration (the UA §9.1 deploy rule: the Worker that understands a migration is deployed before it). The baseline manifest of 2026-11-12 assigns 0.8.1-p2 to every migration that existed then |
| R4 | A released migration never changes (same SHA-256), and the committed manifest matches the repository |

CI runs `--check` in the `secret-scan` job. After adding a migration or changing a release, run `--write` and commit `release/manifest.json`.

## Remaining in INS-1 and INS-2

- `install_activate_config` reading `min_worker_release` (database side).
- Signed releases.
- INS-2, part done: `deploy/install_instance.py --plan` validates every input before anything is touched, and prints the steps (AT-INS-01). Its rules:
  - the installer role is not `bnx_*`;
  - the modules are exactly Canada, International and CRA, and CRA=YES is refused while G-CRA-1 is closed;
  - the app origin is https;
  - the KV id, Google client id and Owner subject have the right shape.
- INS-2 remaining: the setup wizard (a PWA setup mode).
