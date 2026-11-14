# M0-A — Synthetic test instance deployment runbook (Cloudflare Workers + Neon)

**Status:** first execution 2026-11-12. Owner authorization for that execution:
> "授权你合并 #9–#16，云账户已经开通和授权connector，授权 AI 主机测试"

("I authorize you to merge #9–#16; the cloud accounts are open and the connectors authorized; I authorize AI host testing.")

**Data class:** synthetic only. Gate O-8 stays closed: no real data and no production use.

**Cost target:** Cloudflare Workers Free and Neon Free. Stop and ask the Owner before anything leaves a free tier.

## What gets deployed

| Piece | Where | How |
|---|---|---|
| Database | Neon project `balnexa-synthetic-test`, PG 17, `aws-us-east-2`, database `balnexa`, owner role `balnexa_owner` (non-superuser CREATEROLE) | `deploy/install_instance.py` through `deploy/neon_ws_bridge.mjs` |
| Gateway + PWA | Cloudflare Worker `balnexa-test` (`apps/worker/src/cloudflare.js`), static assets `apps/pwa/public`, KV `balnexa-test-kv`, cron every minute | `wrangler deploy` |
| Executor | not deployed (Cloud Run: later M0-A step) | — |

**Note:** the installer role must **not** be named `bnx_*`. The privilege audit (9002) treats every `bnx_` role as a system role. The first Neon project used `bnx_installer`, failed the audit, and was deleted and re-created with `balnexa_owner`.

## Steps

1. **Neon project.** Create it with the owner role `balnexa_owner` (connector `create_project`, `branch.role_name`). Get the owner connection string. Use the **direct** endpoint host (without `-pooler`) for the installer and the runtime.
2. **KV namespace.** Create `balnexa-test-kv` (connector `kv_namespace_create`) and note its id.
3. **Bridge.** Needed only when the build host reaches the internet through an HTTPS proxy only:

   ```bash
   cd deploy && npm ci && node neon_ws_bridge.mjs <ep-…>.neon.tech 15432
   ```

4. **Install.** First run the same command with `--plan` (INS-2): it validates every input and prints the steps without touching anything. Re-running the install is safe: it skips completed steps.

   ```bash
   python3 deploy/install_instance.py --pg "host=127.0.0.1 port=15432 dbname=balnexa user=balnexa_owner password=… sslmode=disable" \
     --runtime-host <ep-…>.neon.tech --project-id synthetic-test-01 --app-origin https://balnexa-test.<sub>.workers.dev \
     --kv-id <kv id> --google-client-id <client id> --secrets-dir ~/.balnexa
   ```

   The command:
   - runs B001/B002 (and B003 when the runner asks for it);
   - sets random passwords for `bnx_migrator`, `bnx_app`, `bnx_authn` and `bnx_worker`;
   - applies the 35 migrations (expected: `privilege_violations=0`);
   - runs `install_household_v2`, with the Owner identity as a placeholder until step 6, and `data_class = synthetic`;
   - runs `install_activate_config`;
   - renders `apps/worker/wrangler.toml`;
   - writes the runtime connection strings to `~/.balnexa/<project>.secrets.json` (mode 0600).
5. **Deploy** (Owner's machine, Node 22):

   ```bash
   cd apps/worker
   npm ci
   npx wrangler@4.161.0 login
   npx wrangler@4.161.0 deploy
   npx wrangler@4.161.0 secret bulk ../../secrets.json
   ```

   The secrets file holds `DB_URL_BNX_APP`, `DB_URL_BNX_AUTHN` and `DB_URL_BNX_WORKER`. Delete it after the upload.
6. **Bind the Owner.**
   1. In Google Cloud, add the Worker URL to the OAuth client's Authorized JavaScript origins.
   2. Open `<url>/app/` and sign in. With `BNX_INSTALL_PROBE=1` the page shows "Installer setup … subject". This appears only for a verified Google account that is not yet a member.
   3. Run the binding command with that subject:

      ```bash
      install_instance.py … --bind-owner-sub <subject>
      ```

      It adds the Owner's identity and removes the placeholder.
   4. Sign in again.
7. **Close the probe.** Render with `--install-probe 0` and redeploy. This can wait for a test instance; the probe only ever shows a signer their own subject.
8. **Checks:**
   - `GET /api/v1/health`: `bindings.ok = true`, `schema_head = 9023`;
   - the PWA signs in;
   - Quick Entry and Draft Confirm work;
   - `/.well-known/oauth-protected-resource/mcp` answers.
9. **AI hosts** (POC-AUTH, granted 2026-11-12). Add a Claude custom connector with the URL `<url>/mcp`; it registers by DCR. Consent happens in the PWA. Then run PV-AIH-01…08 and PV-UI-01…03 with synthetic data.

## Upgrade to a newer release (re-run)

Re-running the step 4 command with the same arguments is the upgrade:
- it applies the new migrations;
- it skips the install and the activation that are already done;
- it re-renders `wrangler.toml` with the activated digest.

Then deploy the Worker (step 5). No secret upload is needed when the passwords are unchanged.

| Order | Step | Why |
|---|---|---|
| 0 | Check the target: `release_sign.py check-files`, and `--plan`, which shows the release state | The migration files must match the manifest |
| 1 | **Neon backup branch** of the current state (connector `create_branch`; non-destructive) | Rollback point. Recoverable without touching the main branch |
| 2 | Re-run the installer: migrations to the new head | The old Worker fails closed (B3: the database head is outside its range) from here until step 3. API and MCP answer 503 `BNX_BINDING_MISMATCH`, so nothing can be written in between |
| 3 | Deploy the new Worker (`wrangler deploy`) | Its range (N-1..N) includes the new head; `GET /api/v1/health` shows `bindings.ok` |
| 4 | Checks as in step 8 | — |

A one-migration step could keep serving through the N-1 range: deploy the Worker first, then migrate (UA §9.1). A jump of several migrations cannot, so it takes a short maintenance gap, made safe by B3 failing closed.

**Rollback:**
- Point the runtime secrets at the backup branch, or restore the main branch from it.
- Redeploy the old Worker from its commit.
- On a synthetic instance, a fresh install is also acceptable.

## Rollback and teardown

| What | How |
|---|---|
| Worker | `wrangler delete` (Owner's machine) |
| KV | delete the namespace |
| Neon | delete the project (recoverable for 7 days) |

No real data exists, so a teardown loses nothing. Every deletion needs the Owner's confirmation.

## Execution log (2026-11-12, synthetic-test-01)

| Step | Result |
|---|---|
| Neon install | 35 migrations, head 9023, `privilege_violations=0`; config v1 ACTIVE |
| Worker deploy | by the installer with a 7-day Owner-scoped Cloudflare API token (Owner chose this over running wrangler himself); `https://balnexa-test.<owner subdomain>.workers.dev`; health `bindings.ok` |
| F-M0A-02 | PWA `Referrer-Policy: no-referrer` left the Google button unrendered; now `strict-origin-when-cross-origin` (GIS setup guide) |
| F-M0A-03 | the probe note was removed by `fail()` re-booting to a fresh login screen; the subject was read from `wrangler tail` (digits logged as letters) and the PWA fixed. No automated test covers the probe note yet |
| Owner binding | `--bind-owner-sub` done; Owner signed in; `BNX_INSTALL_PROBE=0` redeployed (0.7.4-m0a) |
| F-M0A-01 | handoff SIN guard false positive on UUIDs (about 0.1% per UUID in free text); next DB batch |
| Upgrade 2026-11-12 23:07–23:10 UTC | Upgrade procedure above, run from commit 64b59b1 (code = 7b56433, regression 459/0/3). Neon backup branch `backup-pre-upgrade-9023-to-9032` (no compute); installer re-run: 9024–9032 applied, `privilege_violations=0`, install and activation skipped; Worker deployed with the 7-day token; health `release 0.8.8-p2`, `schema_head 9032`, `bindings.ok` |
