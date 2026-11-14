// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Balnexa M0-A synthetic test instance: one-command deploy to the Owner's Cloudflare account.
// Run from this folder:  node deploy.mjs
// Steps: npm ci -> wrangler login -> deploy -> set APP_ORIGIN to the real workers.dev URL and deploy again
//        -> upload the three database secrets -> delete secrets.json -> print the URL.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = fs.existsSync(path.join(HERE, 'apps', 'worker')) ? HERE : path.dirname(HERE); // bundle root or repo deploy/
const WORKER = path.join(ROOT, 'apps', 'worker');
const TOML = path.join(WORKER, 'wrangler.toml');
const SECRETS = path.join(ROOT, 'secrets.json');
const WRANGLER = 'npx --yes wrangler@4.161.0';

function run(cmd, { capture = false } = {}) {
  return new Promise((resolve, reject) => {
    console.log(`\n> ${cmd}`);
    const p = spawn(cmd, { cwd: WORKER, shell: true, stdio: capture ? ['inherit', 'pipe', 'pipe'] : 'inherit' });
    let out = '';
    if (capture) {
      p.stdout.on('data', (d) => { out += d; process.stdout.write(d); });
      p.stderr.on('data', (d) => { out += d; process.stderr.write(d); });
    }
    p.on('close', (code) => (code === 0 ? resolve(out) : reject(new Error(`failed (exit ${code}): ${cmd}`))));
  });
}

async function main() {
  const major = Number(process.versions.node.split('.')[0]);
  if (major < 20) throw new Error(`Node.js 20 or newer is required (found ${process.versions.node}). Install the LTS from https://nodejs.org`);

  await run('npm ci --no-audit --no-fund');
  await run(`${WRANGLER} login`);

  const first = await run(`${WRANGLER} deploy`, { capture: true });
  const m = first.match(/https:\/\/[a-z0-9.-]+\.workers\.dev/i);
  if (!m) throw new Error('could not find the workers.dev URL in the deploy output; send the output above to the installer');
  const url = m[0].toLowerCase();

  const toml = fs.readFileSync(TOML, 'utf8');
  if (!toml.includes(`APP_ORIGIN = "${url}"`)) {
    fs.writeFileSync(TOML, toml.replace(/APP_ORIGIN = "[^"]*"/, `APP_ORIGIN = "${url}"`));
    await run(`${WRANGLER} deploy`);
  }

  if (fs.existsSync(SECRETS)) {
    await run(`${WRANGLER} secret bulk "${SECRETS}"`);
    fs.rmSync(SECRETS);
    console.log('\nsecrets uploaded; secrets.json deleted');
  } else {
    console.log('\nsecrets.json not found: assuming the secrets were uploaded on an earlier run');
  }

  console.log('\n==================================================================');
  console.log(` Deployed: ${url}`);
  console.log(` 1. Google Cloud Console -> Credentials -> your OAuth client ->`);
  console.log(`    Authorized JavaScript origins: add  ${url}`);
  console.log(` 2. Open  ${url}/app/  and sign in with Google.`);
  console.log(`    The page shows an "Installer setup" subject: send it to the installer.`);
  console.log(` 健康检查 / health: ${url}/api/v1/health`);
  console.log('==================================================================\n');
}

main().catch((e) => { console.error(`\nERROR: ${e.message}`); process.exit(1); });
