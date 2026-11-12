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

- **Done (9029):** `install_activate_config` refuses activation (B3) when the deployed Worker's stated schema range (`worker_supports_extension`) excludes the applied head. `install_instance.py` sends the range from `release.js`. Test AT-DPL-01.
- **Done (signed releases, mechanism):** see "Signed releases" below. The Owner's key does not exist yet.
- INS-2, part done: `deploy/install_instance.py --plan` validates every input before anything is touched, and prints the steps (AT-INS-01). Its rules:
  - the installer role is not `bnx_*`;
  - the modules are exactly Canada, International and CRA, and CRA=YES is refused while G-CRA-1 is closed;
  - the app origin is https;
  - the KV id, Google client id and Owner subject have the right shape.
- INS-2 remaining: the setup wizard (a PWA setup mode).

## Signed releases (INS-1)

`tools/s4/release_sign.py` signs `release/manifest.json` with Ed25519. The manifest pins every migration by SHA-256, the Worker release and its schema range, and the SBOM, so one detached signature over the manifest bytes covers the whole release.

| File | Content |
|---|---|
| `release/manifest.json.sig` | format `bnx-release-signature/1.0`; the manifest's SHA-256; key id (first 16 hex of SHA-256 of the raw public key); base64 signature |
| `release/release-signing.pub` | the Owner's public key: 32 raw bytes, base64, one line. Not committed yet |

| Command | Use |
|---|---|
| `keygen --private PATH --public release/release-signing.pub` | Owner's machine, once. The private key file is created 0600 and is refused inside the repository |
| `sign --private PATH` | Owner, at release time. Writes `release/manifest.json.sig` |
| `verify` | `VALID`, or `UNSIGNED`, `MANIFEST_CHANGED`, `SIGNATURE_INVALID`, `KEY_MISMATCH`, `SIGNATURE_MALFORMED`, `NO_PUBLIC_KEY` |
| `check-files` | every migration file has the SHA-256 the manifest lists; reports `CHANGED`, `UNLISTED`, `MISSING` |

**Installer:**
- `deploy/install_instance.py` always runs `check-files` in its validator. Migration files that differ from the manifest are an input problem, so nothing is touched.
- `--require-signed` also refuses any signature verdict other than `VALID`. `--release-pub` names another public key file.
- `--plan` prints the release state as step 0.

**CI:** the `secret-scan` job runs `check-files` (blocking) and `verify` (reported only). Every development commit changes the manifest, so the signature gate belongs at install, not on every push.

### Decisions — `DELEGATED_DECISION`

| ID | Decision | Reason |
|---|---|---|
| D-SIG-1 | The private key is the Owner's. It is never in the repository, CI or this workspace. The tool refuses to write it inside the repository | A signature made by the AI or by CI would prove nothing about the Owner's approval |
| D-SIG-2 | Ed25519 detached signature over the exact manifest bytes. Python `cryptography` is needed only when a public key exists (keygen, sign, verify) | Small, deterministic, no PKI. Key rotation is a new public key file plus a re-sign |
| D-SIG-3 | Unsigned releases stay installable without `--require-signed` | Synthetic instances only (O-8 closed). Owner action before any real instance: generate the key, commit the public key, sign, and install with `--require-signed` |

Test: AT-SIG-01 (`tests/py/run_s4_core19.py`).
