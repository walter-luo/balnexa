// Black-box suite: HTTP requests against the real Worker module (node adapter) and a real PostgreSQL database migrated
// by bnx_migrator. No test helper touches the database; identities are synthetic RSA-signed Google-style ID tokens.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeDb, makeKv, makeR2, serve, worker } from '../../apps/worker/node/adapter.mjs';
import { validate } from '../../apps/worker/src/schema.js';
import fs from 'node:fs';
import os from 'node:os';

const here = path.dirname(fileURLToPath(import.meta.url));
const SERVER = process.env.BNX_SERVER || 'pg16';
const PY = process.env.BNX_PY || '/opt/bnx-tools/venv/bin/python';
const ORIGIN = 'https://app.balnexa.test';
let env, srv, base, kp, kp2;

const b64u = (b) => Buffer.from(b).toString('base64url');
function idToken(claims, key = kp, kid = 'k1') {
  const h = b64u(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT' }));
  const now = Math.floor(Date.now() / 1000);
  const p = b64u(JSON.stringify({ iss: 'https://accounts.google.com', aud: 'test-client', iat: now, exp: now + 600, email_verified: true, ...claims }));
  const s = crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), key.privateKey);
  return `${h}.${p}.${b64u(s)}`;
}
async function call(p, { method = 'POST', body, headers = {}, cookie, bearer, form } = {}) {
  const hd = { ...headers };
  if (body !== undefined) hd['content-type'] = 'application/json';
  if (form) hd['content-type'] = 'application/x-www-form-urlencoded';
  if (cookie) hd.cookie = `bnx_session=${cookie}`;
  if (bearer) hd.authorization = `Bearer ${bearer}`;
  const r = await fetch(base + p, { method, headers: hd, body: form ? new URLSearchParams(form).toString() : (body !== undefined ? JSON.stringify(body) : undefined) });
  const text = await r.text();
  let j = null; try { j = JSON.parse(text); } catch {}
  return { status: r.status, json: j, headers: r.headers, text };
}
const cmd = (name, body, cookie, extra = {}) => call(`/api/v1/commands/${name}`, { body, cookie, headers: { origin: ORIGIN, ...extra } });

let INST = null, INFO = null;
const R2DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'bnx-bb-r2-'));
const EXEC_AUD = 'https://exec.balnexa.test';
const JOB = { sub: '108000000000000000001', email: 'bnx-executor@synthetic-project.iam.gserviceaccount.com', azp: '108000000000000000001' };
const CONTRACT = ['File ID', 'Original Name', 'Current Name', 'Document Date', 'Processed Date', 'Domain', 'Type', 'Tags', 'Source',
  'Sensitivity', 'Status', 'Summary', 'Record Path', 'Related Open Item', 'Notes'];
before(async () => {
  const info = JSON.parse(execFileSync(PY, [path.join(here, 'prepare_db.py'), SERVER]).toString());
  INST = info.institution_id ? { institution_id: info.institution_id } : { institution: 'Synthetic Bank' };   // S4 re-baseline (9006)
  kp = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  kp2 = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = kp.publicKey.export({ format: 'jwk' });
  env = { db: makeDb({ host: info.host, port: info.port, database: info.db }), KV: makeKv(), APP_ORIGIN: ORIGIN,
          GOOGLE_CLIENT_ID: 'test-client', GOOGLE_JWKS: { keys: [{ ...jwk, kid: 'k1', alg: 'RS256' }] },
          EXEC_AUDIENCE: EXEC_AUD, EXEC_JOBS: { INDEX_CONSUME: JOB, REPORT_RENDER: JOB, DOC_PROCESS: JOB, DOC_DISCOVER: JOB }, ARTIFACTS: makeR2(R2DIR), ...(info.binding || {}) };
  INFO = info;
  srv = await serve(env);
  base = `http://127.0.0.1:${srv.address().port}`;
});
after(async () => { srv && srv.close(); env && await env.db.end(); fs.rmSync(R2DIR, { recursive: true, force: true }); });

const S = {};
test('BB-AUTH-01 Google sign-in: forged, expired, wrong-audience and unknown-subject tokens are rejected', async () => {
  const cases = [
    idToken({ sub: 'g-owner' }, kp2),                                    // wrong signing key
    idToken({ sub: 'g-owner', exp: Math.floor(Date.now() / 1000) - 3600 }),
    idToken({ sub: 'g-owner', aud: 'other-client' }),
    idToken({ sub: 'g-owner', email_verified: false }),
    idToken({ sub: 'g-owner', iss: 'https://evil.example' }),
    idToken({ sub: 'g-nobody' }),
    'eyJhbGciOiJub25lIn0.eyJzdWIiOiJnLW93bmVyIn0.',                      // alg none
  ];
  for (const t of cases) {
    const r = await call('/auth/google/callback', { body: { id_token: t }, headers: { origin: ORIGIN } });
    assert.equal(r.status, 401, `token accepted: ${t.slice(0, 30)}`);
  }
  const noOrigin = await call('/auth/google/callback', { body: { id_token: idToken({ sub: 'g-owner' }) } });
  assert.equal(noOrigin.status, 403);
  const ok = await call('/auth/google/callback', { body: { id_token: idToken({ sub: 'g-owner' }) }, headers: { origin: ORIGIN } });
  assert.equal(ok.status, 200);
  const sc = ok.headers.get('set-cookie');
  assert.match(sc, /HttpOnly; Secure; SameSite=Strict/);
  S.owner = decodeURIComponent(sc.match(/bnx_session=([^;]+)/)[1]);
});

test('BB-API-01 account, category, opening and posting through /api/v1 with idempotency', async () => {
  let r = await cmd('create_account', { kind: 'bank_deposit', ...INST, label: 'Chequing', currencies: ['CAD'] }, S.owner, { 'idempotency-key': 'bb-acc-0001' });
  assert.equal(r.status, 200, r.text);
  S.ac = r.json.account_currencies[0];
  r = await cmd('create_category', { kind: 'expense', currency: 'CAD', name_en: 'Groceries' }, S.owner, { 'idempotency-key': 'bb-cat-0001' });
  S.groc = r.json.ledger_account_id;
  r = await cmd('set_opening', { account_currency_id: S.ac.account_currency_id, anchor_date: '2026-01-01', amount: '500.00' }, S.owner, { 'idempotency-key': 'bb-open-0001' });
  assert.equal(r.status, 200, r.text);
  const post = (amt) => ({ economic_type: 'consumption_expense', transaction_date: '2026-02-01', description: 'bb',
    lines: [{ ledger_account_id: S.ac.ledger_account_id, currency: 'CAD', amount: `-${amt}` }, { ledger_account_id: S.groc, currency: 'CAD', amount: amt }] });
  const a = await cmd('post_transaction', post('20.00'), S.owner, { 'idempotency-key': 'bb-post-0001' });
  const b = await cmd('post_transaction', post('20.00'), S.owner, { 'idempotency-key': 'bb-post-0001' });
  const c = await cmd('post_transaction', post('21.00'), S.owner, { 'idempotency-key': 'bb-post-0001' });
  assert.equal(a.status, 200); assert.equal(b.json.journal_id, a.json.journal_id); assert.equal(b.json.replayed, true);
  assert.deepEqual([c.status, c.json.error], [409, 'IDEMPOTENCY_CONFLICT']);
  const bad = await cmd('post_transaction', { ...post('5.00'), lines: [post('5.00').lines[0], { ...post('5.00').lines[1], amount: '4.00' }] }, S.owner, { 'idempotency-key': 'bb-post-0002' });
  assert.deepEqual([bad.status, bad.json.error], [422, 'JOURNAL_UNBALANCED']);
  const q = await call('/api/v1/queries/balances', { body: { as_of: '2026-12-31' }, cookie: S.owner });
  assert.equal(q.json.balances[0].amount, '480.0000');
});

test('BB-API-02 CSRF, unknown routes, injection-shaped names and anonymous calls', async () => {
  const noOrigin = await call('/api/v1/commands/create_category', { body: { kind: 'expense', currency: 'CAD', name_en: 'x' }, cookie: S.owner });
  assert.equal(noOrigin.status, 403);
  const evil = await call('/api/v1/commands/create_category', { body: {}, cookie: S.owner, headers: { origin: 'https://evil.example' } });
  assert.equal(evil.status, 403);
  for (const n of ['wrk_activate_plan', 'install_household', 'nonexistent_cmd']) {
    const r = await cmd(n, { idempotency_key: 'bb-x-00000001' }, S.owner);
    assert.equal(r.status, 404, `${n} -> ${r.status}`);
  }
  const inj = await call("/api/v1/commands/post_transaction('{}','{}');drop%20table%20x;--", { body: {}, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.equal(inj.status, 404);
  const anon = await call('/api/v1/queries/balances', { body: {} });
  assert.equal(anon.status, 401);
  const forged = await call('/api/v1/queries/balances', { body: {}, cookie: 'A'.repeat(44) });
  assert.equal(forged.status, 401);
});

const R_MCP = `${ORIGIN}/mcp`, R_API = `${ORIGIN}/api`;
const pkce = () => { const v = crypto.randomBytes(40).toString('base64url'); return { v, c: crypto.createHash('sha256').update(v).digest('base64url') }; };
// consent through the PWA route (session + same origin) and code redemption, as an AI host would do it after the consent screen
async function consent({ client = 'chatgpt-test', redirect = 'https://host.example/cb', scopes = ['finance.read'], resource = R_MCP,
                         acs = [S.ac.account_currency_id], cookie = S.owner } = {}) {
  const k = pkce();
  const az = await call('/oauth/authorize', { body: { client_id: client, redirect_uri: redirect, code_challenge: k.c, code_challenge_method: 'S256',
    scopes, account_currency_ids: acs, resource, state: 'st-abc' }, cookie, headers: { origin: ORIGIN } });
  assert.equal(az.status, 200, az.text);
  const u = new URL(az.json.redirect);
  assert.equal(u.searchParams.get('state'), 'st-abc');
  const tok = await call('/oauth/token', { form: { grant_type: 'authorization_code', code: u.searchParams.get('code'), client_id: client,
    redirect_uri: redirect, code_verifier: k.v, resource } });
  assert.equal(tok.status, 200, tok.text);
  return { ...tok.json, connection_id: az.json.connection_id };
}
const rpcAt = (bearer, method, params, extra = {}) => call('/mcp', { body: { jsonrpc: '2.0', id: 1, method, ...(params ? { params } : {}) }, bearer, ...extra });

test('BB-OAUTH-01 PKCE S256 authorization code flow and MCP read-only scope', async () => {
  const k = pkce();
  const plain = await call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: k.c,
    code_challenge_method: 'plain', scopes: ['finance.read'], account_currency_ids: [S.ac.account_currency_id], resource: R_MCP }, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.equal(plain.status, 400);
  // S4 re-baseline (9009): catalog scopes; a replayed code revokes the connection's tokens, so a fresh consent follows.
  // AIH-1 re-baseline: every new consent names the resource (surface) it is for
  const authorize = () => call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: k.c,
    code_challenge_method: 'S256', scopes: ['finance.read', 'finance.draft', 'reports.read'], account_currency_ids: [S.ac.account_currency_id], state: 'xyz',
    resource: R_MCP }, cookie: S.owner, headers: { origin: ORIGIN } });
  let az = await authorize();
  assert.equal(az.status, 200, az.text);
  let code = new URL(az.json.redirect).searchParams.get('code');
  const tokenReq = (v) => call('/oauth/token', { form: { grant_type: 'authorization_code', code, client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_verifier: v } });
  const wrong = await tokenReq(crypto.randomBytes(40).toString('base64url'));
  assert.deepEqual([wrong.status, wrong.json.error], [400, 'invalid_grant']);
  const tok0 = await tokenReq(k.v);
  assert.equal(tok0.status, 200, tok0.text);
  const replay = await tokenReq(k.v);
  assert.deepEqual([replay.status, replay.json.error], [400, 'invalid_grant']);
  // AIH-2 re-baseline: a revoked token is refused by the MCP transport itself (401 + RFC 9728 challenge), not as a tool error
  const revoked = await rpcAt(tok0.json.access_token, 'tools/call', { name: 'fin_balances_as_of', arguments: {} });
  assert.equal(revoked.status, 401, 'token issued before the replay must be revoked');
  assert.match(revoked.headers.get('www-authenticate'), /error="invalid_token"/);
  az = await authorize();
  code = new URL(az.json.redirect).searchParams.get('code');
  const tok = await tokenReq(k.v);
  assert.equal(tok.status, 200, tok.text);
  S.bearer = tok.json.access_token;
  const rpc = (method, params) => rpcAt(S.bearer, method, params);
  const list = await rpc('tools/list');
  const names = list.json.result.tools.map((t) => t.name);
  // AIH-2: the R1 static tools survive as catalog tools (OBJ-268); the list covers the consented scopes only
  for (const n of ['fin_balances_as_of', 'fin_reports_create_snapshot', 'fin_reports_replay_snapshot', 'fin_draft_create_transaction', 'sys_whoami']) {
    assert.ok(names.includes(n), n);
  }
  assert.ok(!names.some((n) => n.startsWith('handoff_') || n.startsWith('doc_')), `${names}`);
  // 2.8 curated schemas (9026): hosts see the required fields, the enum of economic types and plain descriptions;
  // a call missing a required field is refused by the Gateway with the database's own code and the field named
  const ct = list.json.result.tools.find((t) => t.name === 'fin_draft_create_transaction');
  if (ct.inputSchema.required) {
    assert.deepEqual(ct.inputSchema.required.filter((r) => r !== 'idempotency_key').sort(), ['account_currency_id', 'economic_type', 'transaction_date']);
    assert.ok(ct.inputSchema.properties.economic_type.enum.includes('consumption_expense') && /Owner/.test(ct.description), ct.description);
    const miss = await rpc('tools/call', { name: 'fin_draft_create_transaction', arguments: { idempotency_key: 'bb-curated-0001', transaction_date: '2026-03-01' } });
    assert.match(JSON.stringify(miss.json), /VALIDATION_FAILED/);
  }
  const bal = await rpc('tools/call', { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } });
  assert.equal(bal.json.result.structuredContent.balances.length, 1);
  // 2.8 part 3 (9032): curated output schemas are advertised and the real results conform to them over HTTP
  const bt = list.json.result.tools.find((t) => t.name === 'fin_balances_as_of');
  const wt = list.json.result.tools.find((t) => t.name === 'sys_whoami');
  if (bt.outputSchema && bt.outputSchema.required) {
    assert.deepEqual(bt.outputSchema.required, ['ledger_version', 'as_of', 'balances']);
    assert.ok(ct.outputSchema.required.includes('plan_hash') && wt.outputSchema.required.includes('scopes'));
    assert.equal(validate(bt.outputSchema, bal.json.result.structuredContent), null);
    const who = await rpc('tools/call', { name: 'sys_whoami', arguments: {} });
    assert.equal(validate(wt.outputSchema, who.json.result.structuredContent), null);
    assert.equal(who.json.result.structuredContent.channel, 'mcp');
    const dr = await rpc('tools/call', { name: 'fin_draft_create_transaction', arguments: { idempotency_key: 'bb-output-00001', account_currency_id: S.ac.account_currency_id,
      transaction_date: '2026-03-01', economic_type: 'consumption_expense', amount: '-2.00', description: 'bb output schema',
      lines: [{ ledger_account_id: S.ac.ledger_account_id, currency: 'CAD', amount: '-2.00' }, { ledger_account_id: S.groc, currency: 'CAD', amount: '2.00' }] } });
    assert.equal(dr.json.result.isError, undefined, JSON.stringify(dr.json));
    assert.equal(validate(ct.outputSchema, dr.json.result.structuredContent), null);
    assert.equal(dr.json.result.structuredContent.kind, 'ai_draft');
    const wdt = list.json.result.tools.find((t) => t.name === 'fin_draft_withdraw');
    const wd = await rpc('tools/call', { name: 'fin_draft_withdraw', arguments: { idempotency_key: 'bb-output-00002', plan_id: dr.json.result.structuredContent.plan_id } });
    assert.deepEqual(wd.json.result.structuredContent, { status: 'withdrawn' });
    assert.equal(validate(wdt.outputSchema, wd.json.result.structuredContent), null);
  }
  const w = await rpc('tools/call', { name: 'pwa_post_transaction', arguments: {} });
  assert.equal(w.json.error.code, -32602);
  // the database, not the Worker, refuses AI-channel writes even when the AI host calls REST directly (with an /api token)
  S.bearerApi = (await consent({ scopes: ['finance.read', 'finance.draft', 'reports.read'], resource: R_API })).access_token;
  const rest = await call('/api/v1/commands/post_transaction', { body: { idempotency_key: 'bb-ai-00000001', economic_type: 'fee', transaction_date: '2026-02-02',
    description: 'ai', lines: [] }, bearer: S.bearerApi });
  assert.deepEqual([rest.status, rest.json.error], [403, 'FORBIDDEN_CHANNEL']);
  const noBearer = await call('/mcp', { body: { jsonrpc: '2.0', id: 1, method: 'tools/list' }, cookie: S.owner });
  assert.equal(noBearer.status, 401);
  assert.equal(noBearer.headers.get('www-authenticate'), `Bearer resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource/mcp", scope="finance.read reports.read offline_access"`);
});

test('BB-PLAN-01 import plan approved via REST is activated by the scheduled dispatcher (KV hint path) ', async () => {
  const p = await cmd('create_import_plan', { account_currency_id: S.ac.account_currency_id, date_from: '2026-03-01', date_to: '2026-03-31',
    items: [{ transaction_date: '2026-03-05', amount: '-30.00', counter_ledger_account_id: S.groc, description: 'imp' }] }, S.owner, { 'idempotency-key': 'bb-plan-0001' });
  assert.equal(p.status, 200, p.text);
  const ap = await cmd('approve_plan', { plan_id: p.json.plan_id, plan_hash: p.json.plan_hash, scope_digest: p.json.scope_digest }, S.owner, { 'idempotency-key': 'bb-appr-0001' });
  assert.equal(ap.status, 200, ap.text);
  assert.equal(await env.KV.get('bnx:hint'), String(ap.json.queue_generation));
  const quiet = new Date('2026-10-30T13:20:00Z').getTime();             // not a backstop tick
  const r = await worker.scheduled({ scheduledTime: quiet }, env, null);
  assert.equal(r.neon, true); assert.equal(r.processed, 1);
  const r2 = await worker.scheduled({ scheduledTime: quiet + 300000 }, env, null);
  assert.equal(r2.neon, false, 'idle tick must not wake Neon');
  const q = await call('/api/v1/queries/balances', { body: { as_of: '2026-12-31' }, cookie: S.owner });
  assert.equal(q.json.balances[0].amount, '450.0000');
});

test('BB-PLAN-02 lost KV hint: work is still found by the unconditional backstop rescan', async () => {
  const p = await cmd('create_import_plan', { account_currency_id: S.ac.account_currency_id, date_from: '2026-05-01', date_to: '2026-05-31',
    items: [{ transaction_date: '2026-05-05', amount: '-10.00', counter_ledger_account_id: S.groc, description: 'imp2' }] }, S.owner, { 'idempotency-key': 'bb-plan-0002' });
  const ap = await cmd('approve_plan', { plan_id: p.json.plan_id, plan_hash: p.json.plan_hash, scope_digest: p.json.scope_digest }, S.owner, { 'idempotency-key': 'bb-appr-0002' });
  assert.equal(ap.status, 200);
  await env.KV.put('bnx:hint', await env.KV.get('bnx:drained'));          // simulate a lost / overwritten hint
  const quiet = new Date('2026-10-30T13:40:00Z').getTime();
  assert.equal((await worker.scheduled({ scheduledTime: quiet }, env, null)).neon, false);
  const backstop = new Date('2026-10-30T15:00:00Z').getTime();
  const r = await worker.scheduled({ scheduledTime: backstop }, env, null);
  assert.equal(r.neon, true); assert.equal(r.processed, 1); assert.equal(r.backstop, true);
  const q = await call('/api/v1/queries/balances', { body: { as_of: '2026-12-31' }, cookie: S.owner });
  assert.equal(q.json.balances[0].amount, '440.0000');
});

test('BB-EXEC-01 Executor lease: pinned job identity, one-time nonce, staging only, Worker promotion (AT-EXEC-01)', async () => {
  const reg = await cmd('register_index_source', { source_id: 'idx-bb-01', adapter: 'GSHEET', location_secret_ref: 'sm://synthetic/bb-index', enabled: true },
    S.owner, { 'idempotency-key': 'bb-idx-0001' });
  if (reg.status === 404) return;                                         // chain without 9010
  assert.equal(reg.status, 200, reg.text);
  const jt = (claims, key = kp) => idToken({ aud: EXEC_AUD, sub: JOB.sub, email: JOB.email, azp: JOB.azp, ...claims }, key);
  const lease = (token, kind = 'INDEX_CONSUME') => call('/exec/v1/lease', { body: { job_kind: kind }, bearer: token });
  const refused = [
    await lease(jt({ sub: '108000000000000000999', email: 'other-job@synthetic-project.iam.gserviceaccount.com' })),  // another service account
    await lease(jt({ azp: '108000000000000000777' })),                                                             // other client id
    await lease(jt({ aud: 'test-client' })),                                                                       // PWA audience
    await lease(jt({}), 'BACKUP'),                                                                                 // job kind not configured
    await lease(jt({}, kp2)),
    await call('/exec/v1/lease', { body: { job_kind: 'INDEX_CONSUME' } }),
  ];
  assert.deepEqual(refused.map(r => r.status), [401, 401, 401, 401, 401, 401]);
  const l = await lease(jt({}));
  assert.equal(l.status, 200, l.text);
  assert.ok(l.json.nonce && l.json.lease_id);
  const rec = Object.fromEntries(CONTRACT.map(k => [k, '']));
  Object.assign(rec, { 'File ID': 'f-bb-cra', 'Original Name': 'NOA 2025', 'Domain': 'Banking_Tax', 'Type': 'CRA Notice', 'Tags': 'CRA',
    'Source': 'notify@cra-arc.gc.ca', 'Document Date': '2026-03-31', 'Processed Date': '2026-04-01' });
  const payload = { source_id: 'idx-bb-01', header: CONTRACT, records: [rec] };
  const complete = (nonce, stg_kind = 'index_consumed', body = payload) =>
    call('/exec/v1/complete', { body: { job_kind: 'INDEX_CONSUME', nonce, stg_kind, payload: body }, bearer: jt({}) });
  const c1 = await complete(l.json.nonce);
  assert.deepEqual([c1.status, c1.json.state], [200, 'STAGED'], c1.text);
  const c2 = await complete(l.json.nonce);
  assert.deepEqual([c2.status, c2.json.error], [409, 'LEASE_USED']);
  const l2 = await lease(jt({}));
  const c3 = await complete(l2.json.nonce, 'doc_rows', { rows: [] });
  assert.deepEqual([c3.status, c3.json.error], [403, 'LEASE_KIND_MISMATCH']);
  const big = await call('/exec/v1/complete', { body: { job_kind: 'INDEX_CONSUME', nonce: l2.json.nonce, stg_kind: 'index_consumed',
    payload: { source_id: 'x'.repeat(320000) } }, bearer: jt({}) });
  assert.equal(big.status, 413);
  const quiet = new Date('2026-10-30T16:20:00Z').getTime();
  const r = await worker.scheduled({ scheduledTime: quiet }, env, null);
  assert.equal(r.neon, true); assert.equal(r.processed, 1);
  const n = await call('/api/v1/queries/notifications', { body: {}, cookie: S.owner });
  assert.equal(n.status, 200, n.text);
  assert.deepEqual(n.json.notifications.map(x => x.kind), ['CRA_CORRESPONDENCE']);
});

// ------------------------------------------------------------------------------------------------ CORE-7 Gateway
async function at(e, fn) {                                   // a second Gateway isolate with its own env (own binding cache)
  const s = await serve(e);
  try { return await fn(`http://127.0.0.1:${s.address().port}`); } finally { s.close(); }
}
async function callAt(b, p, opts) { const o = base; base = b; try { return await call(p, opts); } finally { base = o; } }

test('BB-CAT-01 catalog from the Core: session sees every entry, bearer only MCP entries; REST and MCP give identical results (AT-AIH-01)', async () => {
  const s = await call('/api/v1/catalog', { method: 'GET', cookie: S.owner });
  assert.equal(s.status, 200, s.text);
  assert.equal(s.json.format, 'bnx-tools/1.0');
  assert.match(s.json.catalog_sha256, /^[0-9a-f]{64}$/);
  assert.ok(s.json.entries.length > 100 && s.json.entries.every((e) => e.rest && e.core_function && e.input_schema), 'every entry routable');
  const b = await call('/api/v1/catalog', { method: 'GET', bearer: S.bearerApi });
  assert.equal(b.status, 200, b.text);
  assert.ok(b.json.entries.length > 0 && b.json.entries.every((e) => e.channels.includes('mcp') && ['RC-READ', 'RC-DRAFT'].includes(e.risk_class)));
  assert.ok(b.json.entries.length < s.json.entries.length);
  assert.equal((await call('/api/v1/catalog', { method: 'GET' })).status, 401);
  // equivalence contract: the same actor, input and version give the same structured result on REST and MCP
  const rest = await call('/api/v1/queries/balances', { body: { as_of: '2026-12-31' }, bearer: S.bearerApi });
  const mcp = await call('/mcp', { body: { jsonrpc: '2.0', id: 9, method: 'tools/call', params: { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } } }, bearer: S.bearer });
  assert.equal(rest.status, 200, rest.text);
  assert.deepEqual(mcp.json.result.structuredContent, rest.json);
});

test('BB-SCHEMA-01 body validated against the catalog input schema; error codes are the database codes (AT-AIH-05)', async () => {
  const q = await call('/api/v1/queries/f1_balances', { body: { as_of: '2026-02-30' }, cookie: S.owner });
  assert.deepEqual([q.status, q.json.error, q.json.field], [422, 'VALIDATION_FAILED', '$.as_of']);
  const c = await cmd('post_transaction', { economic_type: 'fee', transaction_date: '2026-02-02', description: 'x', lines: [], settled_rate: 'abc' }, S.owner, { 'idempotency-key': 'bb-sch-0001' });
  assert.deepEqual([c.status, c.json.error, c.json.field], [422, 'VALIDATION_FAILED', '$.settled_rate']);
  const arr = await call('/api/v1/queries/f1_balances', { body: [1, 2], cookie: S.owner });
  assert.deepEqual([arr.status, arr.json.error], [422, 'VALIDATION_FAILED']);
  // a value the schema does not type is judged by the database, which answers with the same code
  const db = await cmd('register_evidence', { size: '-1', sha256_declared: '00', name: 'x.pdf' }, S.owner, { 'idempotency-key': 'bb-sch-0002' });
  assert.deepEqual([db.status, db.json.error, db.json.field], [422, 'VALIDATION_FAILED', undefined]);
  const noKey = await cmd('create_category', { kind: 'expense', currency: 'CAD', name_en: 'x' }, S.owner);
  assert.deepEqual([noKey.status, noKey.json.error], [422, 'IDEMPOTENCY_KEY_REQUIRED']);
  const ok = await call('/api/v1/queries/f1_balances', { body: { as_of: '2026-12-31' }, cookie: S.owner });
  assert.equal(ok.status, 200, ok.text);
});

test('BB-ISO-04 binding checks B1/B2/B8 fail closed with 503; only health answers and reveals no identity (AT-ISO-04, AT-CFG-05)', async () => {
  const cases = [[{ BNX_PROJECT_ID: 'other-household' }, ['B1'], 'BNX_BINDING_MISMATCH'],
                 [{ BNX_CONFIG_DIGEST: 'f'.repeat(64) }, ['B2'], 'BNX_BINDING_MISMATCH'],
                 [{ BNX_MODULES: { ...INFO.binding.BNX_MODULES, CRA: 'NO' } }, ['B8'], 'BNX_FLAG_BINDING_MISMATCH']];
  for (const [over, failed, error] of cases) {
    const e = { ...env, KV: makeKv(), ...over };
    await at(e, async (b2) => {
      const hl = await callAt(b2, '/api/v1/health', { method: 'GET' });
      assert.deepEqual([hl.status, hl.json.bindings], [503, { ok: false, failed }]);
      assert.ok(!hl.text.includes(INFO.binding.BNX_INSTANCE_UID) && !hl.text.includes('bb-household'), 'health reveals no identity value');
      for (const r of [await callAt(b2, '/api/v1/queries/balances', { body: {}, cookie: S.owner }),
                       await callAt(b2, '/api/v1/commands/create_category', { body: {}, cookie: S.owner, headers: { origin: ORIGIN } }),
                       await callAt(b2, '/auth/google/callback', { body: { id_token: idToken({ sub: 'g-owner' }) }, headers: { origin: ORIGIN } }),
                       await callAt(b2, '/oauth/token', { form: { grant_type: 'authorization_code', code: 'x' } })]) {
        assert.deepEqual([r.status, r.json.error], [503, error]);
      }
    });
    const tick = await worker.scheduled({ scheduledTime: Date.now() }, e, null);
    assert.deepEqual([tick.neon, tick.binding], [false, error], 'the dispatcher refuses too');
  }
  const good = await call('/api/v1/health', { method: 'GET' });
  assert.deepEqual([good.status, good.json.status, good.json.bindings.ok], [200, 'ok', true]);
  assert.equal(good.json.identity_present, true);
});

test('BB-B7-01 a token is accepted only on the surface and instance it was issued for (B7; AIH-1 resource binding)', async () => {
  // AIH-1 re-baseline: the audience is the surface (<instance>/mcp or <instance>/api), derived from the instance URL
  const tm = await consent({ resource: R_MCP }), ta = await consent({ resource: R_API });
  const onMcp = (b2, t) => callAt(b2, '/mcp', { body: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'fin_balances_as_of', arguments: {} } }, bearer: t });
  const onApi = (b2, t) => callAt(b2, '/api/v1/queries/balances', { body: {}, bearer: t });
  assert.equal((await onMcp(base, tm.access_token)).status, 200);
  assert.equal((await onApi(base, ta.access_token)).status, 200);
  const x1 = await onApi(base, tm.access_token), x2 = await onMcp(base, ta.access_token);
  assert.deepEqual([x1.status, x1.json.error, x2.status], [401, 'UNAUTHENTICATED', 401]);
  assert.match(x2.headers.get('www-authenticate'), /error="invalid_token"/);
  await at({ ...env, KV: makeKv(), APP_ORIGIN: 'https://other-instance.balnexa.test' }, async (b2) => {
    assert.equal((await onMcp(b2, tm.access_token)).status, 401);
    assert.equal((await onApi(b2, ta.access_token)).status, 401);
  });
  const bad = await call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: pkce().c,
    code_challenge_method: 'S256', scopes: ['finance.read'], account_currency_ids: [S.ac.account_currency_id] }, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.deepEqual([bad.status, bad.json.error], [400, 'invalid_target'], 'a consent without a resource is refused (L-CORE7-4)');
});

test('BB-UP-01 presigned upload: O-7 gate, own upload_pending file only, URL for R2 (AT-EV-01)', async () => {
  const reg = await cmd('register_evidence', { size: 2048, sha256_declared: crypto.createHash('sha256').update('stmt').digest('hex'), name: 'stmt.pdf' },
    S.owner, { 'idempotency-key': 'bb-up-0001' });
  assert.equal(reg.status, 200, reg.text);
  const up = (b2, body, o = {}) => callAt(b2, '/api/v1/uploads', { body, cookie: S.owner, headers: { origin: ORIGIN }, ...o });
  const off = await up(base, { evidence_file_id: reg.json.evidence_file_id });
  assert.deepEqual([off.status, off.json.error], [503, 'UPLOADS_NOT_CONFIGURED']);
  const cfgOff = await call('/app/config.json', { method: 'GET' });
  assert.equal(cfgOff.json.uploads, false);                               // CORE-9 upload widget: the PWA shows "not set up"
  assert.match(cfgOff.headers.get('content-security-policy'), /connect-src 'self' https:\/\/accounts\.google\.com\/gsi\/;/);
  // synthetic R2 settings (no real account; nothing is contacted)
  await at({ ...env, KV: makeKv(), R2_ACCOUNT_ID: 'synthaccount', R2_BUCKET: 'bnx-evidence', R2_ACCESS_KEY_ID: 'synthetic-key-id', R2_SECRET_ACCESS_KEY: 'synthetic-value' }, async (b2) => {
    const r = await up(b2, { evidence_file_id: reg.json.evidence_file_id });
    assert.equal(r.status, 200, r.text);
    const u = new URL(r.json.url);
    assert.equal(u.host, 'synthaccount.r2.cloudflarestorage.com');
    assert.match(u.pathname, /^\/bnx-evidence\/orig\/[0-9a-f-]{36}$/);
    assert.deepEqual([r.json.method, r.json.size_bytes, r.json.expires_in, u.searchParams.get('X-Amz-Expires')], ['PUT', 2048, 900, '900']);
    const nf = await up(b2, { evidence_file_id: crypto.randomUUID() });
    assert.deepEqual([nf.status, nf.json.error], [404, 'NOT_AVAILABLE']);
    assert.equal((await callAt(b2, '/api/v1/uploads', { body: { evidence_file_id: reg.json.evidence_file_id }, bearer: S.bearer })).status, 401);
    assert.equal((await callAt(b2, '/api/v1/uploads', { body: { evidence_file_id: reg.json.evidence_file_id }, cookie: S.owner })).status, 403);
    // CORE-9: with uploads configured, exactly the account's R2 endpoint joins connect-src, so the browser may PUT there
    const cfgOn = await callAt(b2, '/app/config.json', { method: 'GET' });
    assert.equal(cfgOn.json.uploads, true);
    assert.match(cfgOn.headers.get('content-security-policy'), /connect-src 'self' https:\/\/synthaccount\.r2\.cloudflarestorage\.com https:\/\/accounts\.google\.com\/gsi\/;/);
  });
});

// ------------------------------------------------------------------------------------------------ CORE-8 Executor
test('BB-EXEC-02 Executor end to end over HTTP: lease with work order, render, completion schema, promotion, artifact proxy (L-9013-2)', async () => {
  const snap = await cmd('create_report_snapshot', { report_code: 'R-BAL', as_of: '2026-12-31' }, S.owner, { 'idempotency-key': 'bb-snap-core8' });
  assert.equal(snap.status, 200, snap.text);
  const sid = snap.json.snapshot_id;
  const none = await call(`/api/v1/artifacts/${sid}`, { method: 'GET', cookie: S.owner });
  assert.deepEqual([none.status, none.json.error], [404, 'ARTIFACT_NOT_RENDERED']);
  const jt = idToken({ aud: EXEC_AUD, sub: JOB.sub, email: JOB.email, azp: JOB.azp });
  // the Gateway refuses a render_done payload of the wrong shape before the database (one lease spent)
  const l = await call('/exec/v1/lease', { body: { job_kind: 'REPORT_RENDER', item_id: sid }, bearer: jt });
  assert.equal(l.status, 200, l.text);
  assert.equal(l.json.input.projection_sha256, snap.json.projection_sha256);
  const shape = await call('/exec/v1/complete', { body: { job_kind: 'REPORT_RENDER', nonce: l.json.nonce, stg_kind: 'render_done',
    payload: { snapshot_id: sid, artifact_ref: 'r2:elsewhere' } }, bearer: jt });
  assert.deepEqual([shape.status, shape.json.error], [422, 'VALIDATION_FAILED'], shape.text);
  // the real Executor process: python -m bnx_exec run --kind REPORT_RENDER --item <snapshot>
  const tok = path.join(R2DIR, '..', `bnx-bb-token-${process.pid}`);
  fs.writeFileSync(tok, jt, { mode: 0o600 });
  let run;
  try {        // asynchronous: the Gateway answering the Executor runs in this process
    run = await promisify(execFile)(PY, ['-m', 'bnx_exec', 'run', '--kind', 'REPORT_RENDER', '--item', sid], {
      cwd: path.join(here, '..', '..', 'apps', 'executor'), timeout: 60000,
      env: { PATH: process.env.PATH, BNX_GATEWAY_URL: base, BNX_ID_TOKEN_FILE: tok, BNX_ARTIFACT_STORE: R2DIR } });
  } finally { fs.rmSync(tok, { force: true }); }
  const item = JSON.parse(run.stderr.trim().split('\n').pop());
  assert.deepEqual([item.status, item.stg_kind], ['STAGED', 'render_done'], run.stderr);
  assert.ok(!run.stderr.includes(l.json.nonce));
  const r = await worker.scheduled({ scheduledTime: Date.now() }, env, null);
  assert.ok(r.processed >= 1, JSON.stringify(r));
  const a = await call(`/api/v1/artifacts/${sid}`, { method: 'GET', cookie: S.owner });
  assert.equal(a.status, 200, a.text);
  assert.equal(a.headers.get('x-bnx-snapshot-status'), 'CURRENT');
  assert.match(a.headers.get('content-type'), /^text\/html/);
  assert.equal(crypto.createHash('sha256').update(a.text).digest('hex'), a.headers.get('x-bnx-artifact-sha256'));
  assert.match(a.text, new RegExp(sid));
  // tampering with the stored object is detected by the proxy
  const meta = JSON.parse((await call('/api/v1/queries/snapshot_artifact', { body: { snapshot_id: sid }, cookie: S.owner })).text);
  const file = path.join(R2DIR, meta.artifact_ref.slice(3));
  fs.appendFileSync(file, '<!-- x -->');
  const t = await call(`/api/v1/artifacts/${sid}`, { method: 'GET', cookie: S.owner });
  assert.deepEqual([t.status, t.json.error], [502, 'ARTIFACT_INTEGRITY']);
  const anon = await call(`/api/v1/artifacts/${sid}`, { method: 'GET' });
  assert.equal(anon.status, 401);
});

// ------------------------------------------------------------------------------------------------ AIH-1 / AIH-2 (AI hosts)
let IP = 0;
const ip = () => `198.51.100.${++IP}`;                        // one client address per registration: the DCR limit is per address

test('BB-EXEC-03 Executor due list (DOC-2, 9025): pinned job identity; DOC_PROCESS items; other kinds refused', async () => {
  const jt = (claims) => idToken({ aud: EXEC_AUD, sub: JOB.sub, email: JOB.email, azp: JOB.azp, ...claims }, kp);
  const due = (kind, token) => call('/exec/v1/due', { body: { job_kind: kind }, bearer: token });
  const ok = await due('DOC_PROCESS', jt({}));
  if (ok.status === 404) return;                                          // chain without 9025
  assert.equal(ok.status, 200, ok.text);
  assert.deepEqual(ok.json, { job_kind: 'DOC_PROCESS', items: [] });
  const refused = [await due('DOC_PROCESS', jt({ sub: '108000000000000000999' })), await due('DOC_PROCESS'), await due('BACKUP', jt({}))];
  assert.deepEqual(refused.map(r => r.status), [401, 401, 401]);
  const other = await due('DOC_DISCOVER', jt({}));
  assert.deepEqual([other.status, other.json.error], [422, 'VALIDATION_FAILED']);
});

test('AT-AIH-06 discovery: RFC 8414 AS metadata, RFC 9728 metadata for /mcp and /api, 401 challenge, transport rules', async () => {
  const as = await call('/.well-known/oauth-authorization-server', { method: 'GET' });
  assert.equal(as.status, 200);
  assert.deepEqual([as.json.issuer, as.json.authorization_endpoint, as.json.token_endpoint, as.json.registration_endpoint, as.json.revocation_endpoint],
    [ORIGIN, `${ORIGIN}/oauth/authorize`, `${ORIGIN}/oauth/token`, `${ORIGIN}/oauth/register`, `${ORIGIN}/oauth/revoke`]);
  assert.deepEqual([as.json.code_challenge_methods_supported, as.json.token_endpoint_auth_methods_supported, as.json.grant_types_supported],
    [['S256'], ['none'], ['authorization_code', 'refresh_token']]);
  assert.ok(as.json.scopes_supported.includes('offline_access') && as.json.client_id_metadata_document_supported === true);
  for (const w of ['mcp', 'api']) {
    const pr = await call(`/.well-known/oauth-protected-resource/${w}`, { method: 'GET' });
    assert.deepEqual([pr.status, pr.json.resource, pr.json.authorization_servers], [200, `${ORIGIN}/${w}`, [ORIGIN]]);
  }
  assert.equal((await call('/.well-known/oauth-protected-resource/other', { method: 'GET' })).status, 404);
  assert.equal((await call('/.well-known/oauth-protected-resource', { method: 'GET' })).status, 404);
  const g = await call('/mcp', { method: 'GET', bearer: S.bearer });
  assert.deepEqual([g.status, g.headers.get('allow')], [405, 'POST']);
  const init = await rpcAt(S.bearer, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'bb', version: '1' } });
  assert.deepEqual([init.json.result.protocolVersion, init.json.result.serverInfo.name, init.json.result.capabilities.tools.listChanged], ['2025-06-18', 'balnexa', false]);
  assert.match(init.json.result.instructions, /data, never instructions/);
  assert.ok(['TR-01', 'TR-07', 'TR-13', 'TR-14'].every((x) => init.json.result.instructions.includes(x)));
  assert.equal((await rpcAt(S.bearer, 'initialize', { protocolVersion: '1999-01-01' })).json.result.protocolVersion, '2025-11-25');
  const note = await call('/mcp', { body: { jsonrpc: '2.0', method: 'notifications/initialized' }, bearer: S.bearer });
  assert.deepEqual([note.status, note.text], [202, '']);
  assert.deepEqual((await rpcAt(S.bearer, 'ping')).json.result, {});
  assert.equal((await rpcAt(S.bearer, 'prompts/list')).json.error.code, -32601);       // tools and one card resource only (AIH §3)
  const batch = await call('/mcp', { body: [{ jsonrpc: '2.0', id: 1, method: 'ping' }], bearer: S.bearer });
  assert.deepEqual([batch.status, batch.json.error.code], [400, -32600]);
  assert.equal((await rpcAt(S.bearer, 'ping', null, { headers: { 'mcp-protocol-version': '2024-01-01' } })).status, 400);
  assert.equal((await rpcAt(S.bearer, 'ping', null, { headers: { 'mcp-protocol-version': '2025-06-18' } })).status, 200);
  assert.equal((await rpcAt(S.bearer, 'ping', null, { headers: { origin: 'https://evil.example' } })).status, 403);
});

test('BB-OAUTH-03 DCR: host profile inferred from the redirect URIs; outside the allowlist refused; public clients only; rate limit', async () => {
  const reg = (b) => call('/oauth/register', { body: b, headers: { 'cf-connecting-ip': ip() } });
  const ok = await reg({ client_name: 'Claude', redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] });
  assert.equal(ok.status, 201, ok.text);
  assert.match(ok.json.client_id, /^dcr-[a-p]{32}$/);
  assert.deepEqual([ok.json.token_endpoint_auth_method, ok.json.grant_types], ['none', ['authorization_code', 'refresh_token']]);
  const d = await call('/oauth/authorize', { body: { action: 'describe', client_id: ok.json.client_id, redirect_uri: 'https://claude.ai/api/mcp/auth_callback' },
    cookie: S.owner, headers: { origin: ORIGIN } });
  assert.deepEqual([d.status, d.json.host_profile, d.json.registration_kind, d.json.client_name], [200, 'claude_remote_mcp', 'DCR', 'Claude']);
  const cg = await reg({ redirect_uris: ['https://chatgpt.com/connector_platform_oauth_redirect'] });
  assert.equal(cg.status, 201, cg.text);
  for (const [b, err] of [
    [{ redirect_uris: ['https://evil.example/cb'] }, 'invalid_redirect_uri'],
    [{ redirect_uris: ['https://claude.ai/api/mcp/auth_callback', 'https://chatgpt.com/connector_platform_oauth_redirect'] }, 'invalid_redirect_uri'],
    [{ redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], token_endpoint_auth_method: 'client_secret_basic' }, 'invalid_client_metadata'],
    [{ redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], grant_types: ['client_credentials'] }, 'invalid_client_metadata'],
    [{ redirect_uris: [] }, 'invalid_redirect_uri'],
    [[], 'invalid_client_metadata']]) {
    const r = await reg(b);
    assert.deepEqual([r.status, r.json.error], [400, err], JSON.stringify(b));
  }
  await at({ ...env, KV: makeKv(), DCR_LIMIT_PER_DAY: 2 }, async (b2) => {
    const one = (a) => callAt(b2, '/oauth/register', { body: { redirect_uris: ['https://claude.ai/api/mcp/auth_callback'] }, headers: { 'cf-connecting-ip': a } });
    assert.equal((await one('192.0.2.7')).status, 201);
    assert.equal((await one('192.0.2.7')).status, 201);
    const third = await one('192.0.2.7');
    assert.deepEqual([third.status, third.json.error], [429, 'too_many_requests']);
    assert.equal((await one('192.0.2.8')).status, 201);
  });
});

test('AT-AIH-07 a host connects end to end: DCR, authorize -> PWA consent, deny, approve, token, MCP; the audit chain carries host provenance', async () => {
  const CB = 'https://claude.ai/api/mcp/auth_callback';
  const cid = (await call('/oauth/register', { body: { client_name: 'Claude', redirect_uris: [CB] }, headers: { 'cf-connecting-ip': ip() } })).json.client_id;
  const k = pkce();
  const get = (o) => fetch(`${base}/oauth/authorize?${new URLSearchParams({ response_type: 'code', client_id: cid, redirect_uri: CB, code_challenge: k.c,
    code_challenge_method: 'S256', state: 'st-host', scope: 'finance.read reports.read offline_access openid', resource: R_MCP, ...o })}`, { redirect: 'manual' });
  const g = await get({});
  assert.equal(g.status, 302);
  const loc = g.headers.get('location');
  assert.ok(loc.startsWith('/app/#/consent?'), loc);
  const cp = new URLSearchParams(loc.split('?')[1]);
  assert.deepEqual([cp.get('client_id'), cp.get('resource'), cp.get('scope'), cp.get('state')], [cid, R_MCP, 'finance.read reports.read offline_access', 'st-host']);
  assert.equal(new URLSearchParams((await get({ resource: '' })).headers.get('location').split('?')[1]).get('resource'), R_MCP);
  // an untrusted client or redirect URI gets an error page, never a redirect (RFC 6749 §4.1.2.1)
  for (const o of [{ redirect_uri: 'https://evil.example/cb' }, { client_id: 'dcr-unknown' }, { client_id: '' }]) {
    const r = await get(o);
    assert.deepEqual([r.status, r.headers.get('location')], [400, null], JSON.stringify(o));
  }
  for (const [o, e] of [[{ code_challenge_method: 'plain' }, 'invalid_request'], [{ response_type: 'token' }, 'unsupported_response_type'],
                        [{ resource: 'https://other.example/mcp' }, 'invalid_target']]) {
    const r = await get(o);
    const u = new URL(r.headers.get('location'));
    assert.deepEqual([r.status, u.origin + u.pathname, u.searchParams.get('error'), u.searchParams.get('state')], [302, CB, e, 'st-host']);
  }
  // the consent screen's calls (session + same origin)
  const pwa = (b, o = { origin: ORIGIN }) => call('/oauth/authorize', { body: { client_id: cid, redirect_uri: CB, ...b }, cookie: S.owner, headers: o });
  const d = await pwa({ action: 'describe' });
  assert.deepEqual([d.json.client_name, d.json.host_profile, d.json.resources.mcp], ['Claude', 'claude_remote_mcp', R_MCP]);
  assert.ok(!d.json.consentable.includes('tax.read') && d.json.consentable.includes('offline_access'));
  assert.equal((await pwa({ action: 'describe' }, {})).status, 403, 'no Origin: refused (CSRF)');
  assert.equal((await pwa({ action: 'describe', redirect_uri: 'https://evil.example/cb' })).status, 400);
  const du = new URL((await pwa({ action: 'deny', state: 'st-host' })).json.redirect);
  assert.deepEqual([du.origin + du.pathname, du.searchParams.get('error'), du.searchParams.get('state'), du.searchParams.get('code')], [CB, 'access_denied', 'st-host', null]);
  const approve = (b) => pwa({ code_challenge: k.c, code_challenge_method: 'S256', resource: R_MCP, account_currency_ids: [S.ac.account_currency_id], state: 'st-host', ...b });
  const bs = await approve({ scopes: ['tax.read'] });
  assert.deepEqual([bs.status, bs.json.error], [400, 'invalid_scope']);
  const ap = await approve({ scopes: ['finance.read', 'reports.read', 'offline_access'] });
  assert.equal(ap.status, 200, ap.text);
  const au = new URL(ap.json.redirect);
  assert.deepEqual([au.origin + au.pathname, au.searchParams.get('state')], [CB, 'st-host']);
  const tok = await call('/oauth/token', { form: { grant_type: 'authorization_code', code: au.searchParams.get('code'), client_id: cid, redirect_uri: CB,
    code_verifier: k.v, resource: R_MCP } });
  assert.equal(tok.status, 200, tok.text);
  assert.ok(tok.json.refresh_token, 'offline_access consented -> refresh token');
  assert.equal(tok.json.scope, 'finance.read offline_access reports.read', 'granted scope returned (RFC 6749 §5.1)');
  const T = tok.json.access_token;
  const who = (await rpcAt(T, 'tools/call', { name: 'sys_whoami', arguments: {} })).json.result.structuredContent;
  assert.deepEqual([who.channel, [...who.scopes].sort()], ['mcp', ['finance.read', 'offline_access', 'reports.read']]);
  // a host's own key may hold a Luhn-valid 9-digit run: the Gateway normalizes it before the audited call (D-CORE10-3); built at runtime
  const luhn = (d) => { let sum = 0; [...`${d}0`].reverse().forEach((c, i) => { let x = Number(c); if (i % 2) { x *= 2; if (x > 9) x -= 9; } sum += x; }); return `${d}${(10 - (sum % 10)) % 10}`; };
  const snap = await rpcAt(T, 'tools/call', { name: 'fin_reports_create_snapshot', arguments: { report_code: 'R-BAL', as_of: '2026-12-31',
    idempotency_key: `host-key-${luhn(String(10000000 + crypto.randomInt(89999999)))}` } });
  assert.ok(!snap.json.result.isError, snap.text);
  const tr = await call('/api/v1/queries/audit_trail', { body: { command: 'create_report_snapshot', limit: 5 }, cookie: S.owner });
  const ev = tr.json.events[0];
  assert.deepEqual([ev.channel, ev.host_profile, ev.tool_name], ['mcp', 'claude_remote_mcp', 'fin.reports.create_snapshot']);
  // the connection is the Owner's to see and revoke in the PWA (OR-M-05)
  const row = (await call('/api/v1/queries/ai_connections', { body: {}, cookie: S.owner })).json.connections.find((c) => c.client_id === cid);
  assert.deepEqual([row.state, row.host_profile, row.resource, row.account_currency_ids], ['active', 'claude_remote_mcp', R_MCP, [S.ac.account_currency_id]]);
});

test('BB-OAUTH-02 refresh rotation; reuse of a rotated refresh revokes the connection; RFC 7009 and PWA revocation (PV-AIH-03)', async () => {
  const t = await consent({ scopes: ['finance.read', 'offline_access'] });
  const refresh = (rt) => call('/oauth/token', { form: { grant_type: 'refresh_token', refresh_token: rt, client_id: 'chatgpt-test' } });
  const r1 = await refresh(t.refresh_token);
  assert.equal(r1.status, 200, r1.text);
  assert.ok(r1.json.refresh_token && r1.json.refresh_token !== t.refresh_token);
  assert.equal((await rpcAt(r1.json.access_token, 'ping')).status, 200);
  const reuse = await refresh(t.refresh_token);
  assert.deepEqual([reuse.status, reuse.json.error], [400, 'invalid_grant']);
  assert.equal((await rpcAt(r1.json.access_token, 'ping')).status, 401, 'reuse of a rotated refresh token revokes the connection');
  assert.equal((await refresh(r1.json.refresh_token)).status, 400);
  const t2 = await consent({ scopes: ['finance.read'] });
  assert.equal(t2.refresh_token, undefined, 'no refresh token without offline_access');
  const rv = await call('/oauth/revoke', { form: { token: t2.access_token, client_id: 'chatgpt-test' } });
  assert.deepEqual([rv.status, rv.json], [200, {}]);
  assert.equal((await rpcAt(t2.access_token, 'ping')).status, 401);
  assert.equal((await call('/oauth/revoke', { form: { token: 'unknown-token', client_id: 'chatgpt-test' } })).status, 200);
  const t3 = await consent({ scopes: ['finance.read'] });
  const row = (await call('/api/v1/queries/ai_connections', { body: {}, cookie: S.owner })).json.connections.find((c) => c.connection_id === t3.connection_id);
  assert.deepEqual([row.state, row.client_name, row.scopes, row.resource, row.legacy], ['active', 'Synthetic AI host', ['finance.read'], R_MCP, false]);
  const rk = await cmd('revoke_ai_connection', { connection_id: t3.connection_id }, S.owner, { 'idempotency-key': 'bb-revoke-aaaaaaaa' });
  assert.equal(rk.status, 200, rk.text);
  assert.equal((await rpcAt(t3.access_token, 'ping')).status, 401, 'revocation in the PWA is effective on the next request');
  const after = (await call('/api/v1/queries/ai_connections', { body: {}, cookie: S.owner })).json.connections.find((c) => c.connection_id === t3.connection_id);
  assert.equal(after.state, 'revoked');
  const lb = await call('/api/v1/queries/ai_connections', { body: {}, bearer: S.bearerApi });
  assert.equal(lb.json.error, 'SCOPE_NOT_CONSENTED', 'the connection list is not an AI tool');
});

test('AT-AIH-04 tool classes: no RC-POST/RC-ADMIN tool is listed; read-only connections see no draft tool and are refused by the Core with the REST code (AT-AIH-01/03/05/08)', async () => {
  const ro = await consent({ scopes: ['finance.read'] }), roApi = await consent({ scopes: ['finance.read'], resource: R_API });
  const cat = (await call('/api/v1/catalog', { method: 'GET', cookie: S.owner })).json.entries;
  const byName = new Map(cat.map((e) => [e.name.replace(/\./g, '_'), e]));
  const mcpNames = cat.filter((e) => e.channels.includes('mcp')).map((e) => e.name.replace(/\./g, '_'));
  assert.equal(new Set(mcpNames).size, mcpNames.length, 'tool names stay unique after "." -> "_"');
  const list = (await rpcAt(ro.access_token, 'tools/list')).json.result.tools;
  assert.ok(list.length > 10 && list.every((t) => byName.get(t.name).risk_class === 'RC-READ'), 'read-only connection: RC-READ tools only');
  assert.ok(list.every((t) => t.annotations.destructiveHint === false && t.annotations.readOnlyHint === true && t.inputSchema.type === 'object'
    && t.title === byName.get(t.name).name && /^[A-Za-z0-9_-]{1,64}$/.test(t.name)));
  const full = (await rpcAt(S.bearer, 'tools/list')).json.result.tools;
  assert.ok(full.some((t) => byName.get(t.name).risk_class === 'RC-DRAFT'));
  assert.ok(full.every((t) => ['RC-READ', 'RC-DRAFT'].includes(byName.get(t.name).risk_class)), 'never RC-POST / RC-ADMIN');
  // equivalence (AT-AIH-01): same member, grants and version -> byte-identical structured result on MCP and REST
  const f1m = await rpcAt(S.bearer, 'tools/call', { name: 'fin_reports_f1', arguments: { as_of: '2026-12-31' } });
  const f1r = await call('/api/v1/queries/f1_balances', { body: { as_of: '2026-12-31' }, bearer: S.bearerApi });
  assert.equal(f1r.status, 200, f1r.text);
  assert.equal(f1m.json.result.content[0].text, f1r.text);
  assert.deepEqual(f1m.json.result.structuredContent, f1r.json);
  // error equivalence (AT-AIH-05): schema refusal with the same code and field
  const mv = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_reports_f1', arguments: { as_of: '2026-02-30' } })).json.result;
  const rv = await call('/api/v1/queries/f1_balances', { body: { as_of: '2026-02-30' }, bearer: S.bearerApi });
  assert.deepEqual([mv.isError, mv.structuredContent.error, mv.structuredContent.field], [true, rv.json.error, rv.json.field]);
  // a draft through a read-only connection: the Core refuses it with the same code on both surfaces (AT-AIH-03)
  const args = { account_currency_id: S.ac.account_currency_id, transaction_date: '2026-03-01', economic_type: 'consumption_expense', amount: '-1.00',
    counter_ledger_account_id: S.groc };
  const m = (await rpcAt(ro.access_token, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, idempotency_key: 'bb-ro-draft-one' } })).json.result;
  const r = await call('/api/v1/commands/draft_create_transaction', { body: args, bearer: roApi.access_token, headers: { 'idempotency-key': 'bb-ro-draft-two' } });
  assert.deepEqual([m.isError, m.structuredContent.error, r.json.error], [true, 'SCOPE_NOT_CONSENTED', 'SCOPE_NOT_CONSENTED']);
  // with finance.draft the AI host creates a draft, never a posting (AT-AIH-08): the plan waits for approval in the PWA
  const bal0 = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } })).json.result.structuredContent;
  const dr = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, idempotency_key: 'bb-full-draft-one' } })).json.result;
  assert.ok(!dr.isError, JSON.stringify(dr));
  const bal = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } })).json.result.structuredContent;
  assert.deepEqual(bal, bal0, 'nothing posted');
  const bad = await rpcAt(S.bearer, 'tools/call', { name: 'fin_balances_as_of', arguments: [1] });
  assert.deepEqual([bad.json.result.isError, bad.json.result.structuredContent.error], [true, 'VALIDATION_FAILED']);
});

test('AT-AIH-06b CIMD: an allowlisted client-id URL is fetched once and registered; any other URL is never fetched', async () => {
  const fetched = [];
  const CID = 'https://chatgpt.com/oauth/client.json', CB = 'https://chatgpt.com/connector_platform_oauth_redirect';
  const e2 = { ...env, KV: makeKv(), CIMD_FETCH: async (u) => {
    fetched.push(u);
    return new Response(JSON.stringify({ client_id: u, client_name: 'ChatGPT', redirect_uris: [CB], token_endpoint_auth_method: 'none' }), { status: 200 });
  } };
  await at(e2, async (b2) => {
    const k = pkce();
    const q = (cid, ru) => fetch(`${b2}/oauth/authorize?${new URLSearchParams({ response_type: 'code', client_id: cid, redirect_uri: ru, code_challenge: k.c,
      code_challenge_method: 'S256' })}`, { redirect: 'manual' });
    assert.equal((await q('https://evil.example/client.json', 'https://evil.example/cb')).status, 400);
    assert.equal((await q('https://chatgpt.com/oauth/../../evil/client.json', CB)).status, 400);
    assert.deepEqual(fetched, [], 'a URL outside the CIMD allowlist is never fetched');
    const ok = await q(CID, CB);
    assert.equal(ok.status, 302);
    assert.ok(ok.headers.get('location').startsWith('/app/#/consent?'));
    assert.equal((await q(CID, CB)).status, 302);
    assert.deepEqual(fetched, [CID], 'fetched once, then known');
    const d = await callAt(b2, '/oauth/authorize', { body: { action: 'describe', client_id: CID, redirect_uri: CB }, cookie: S.owner, headers: { origin: ORIGIN } });
    assert.deepEqual([d.json.host_profile, d.json.registration_kind, d.json.client_name], ['chatgpt_plugin_mcp', 'CIMD', 'ChatGPT']);
  });
});

test('AT-CONF-04 AIH-4 card: one display-only MCP App resource; draft tools name it; the draft result carries the sealed PWA link; nothing is posted', async () => {
  const init = (await rpcAt(S.bearer, 'initialize', { protocolVersion: '2025-06-18' })).json.result;
  assert.deepEqual(init.capabilities.resources, { listChanged: false });
  const ls = (await rpcAt(S.bearer, 'resources/list')).json.result.resources;
  assert.deepEqual(ls.map((r) => [r.uri, r.mimeType]), [['ui://balnexa/cards/v1', 'text/html;profile=mcp-app']]);
  assert.deepEqual(ls[0]._meta.ui.csp, { connectDomains: [], resourceDomains: [] });
  assert.deepEqual((await rpcAt(S.bearer, 'resources/templates/list')).json.result.resourceTemplates, []);
  assert.equal((await rpcAt(S.bearer, 'resources/read', { uri: 'ui://balnexa/other' })).json.error.code, -32002);
  const rd = (await rpcAt(S.bearer, 'resources/read', { uri: 'ui://balnexa/cards/v1' })).json.result.contents[0];
  assert.equal(rd.mimeType, 'text/html;profile=mcp-app');
  const html = rd.text;
  assert.ok(html.includes(JSON.stringify(ORIGIN)), 'the instance URL is the only injected value');
  assert.match(html, /connect-src 'none'/);
  // display only: no network API, no tool call, no markup from data
  for (const bad of [/fetch\(/, /XMLHttpRequest/, /WebSocket/, /EventSource/, /tools\/call/, /callTool/, /innerHTML/, /insertAdjacentHTML/, /eval\(/, /<script[^>]+src=/, /<link /]) {
    assert.doesNotMatch(html, bad);
  }
  assert.ok(!/https?:\/\/(?!app\.balnexa\.test)[a-z]/.test(html), 'no other origin is referenced');
  assert.ok(Buffer.byteLength(html) < 16384);
  // the catalog binds the card to the draft tools only
  const tools = (await rpcAt(S.bearer, 'tools/list')).json.result.tools;
  const withCard = tools.filter((t) => t._meta && t._meta.ui).map((t) => t.name).sort();
  assert.deepEqual(withCard, ['fin_draft_create_transaction', 'fin_draft_create_transfer', 'fin_draft_get_for_confirmation', 'fin_draft_revise',
    'fin_draft_validate', 'fin_draft_withdraw'].filter((n) => tools.some((t) => t.name === n)));
  const dt = tools.find((t) => t.name === 'fin_draft_create_transaction');
  assert.deepEqual(dt._meta, { ui: { resourceUri: 'ui://balnexa/cards/v1' }, 'openai/outputTemplate': 'ui://balnexa/cards/v1', 'openai/widgetAccessible': false });
  assert.equal(tools.find((t) => t.name === 'fin_balances_as_of')._meta, undefined);
  // a draft: structured result unchanged, a second text block with the sealed link of exactly this version
  const bal0 = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } })).json.result.structuredContent;
  const r = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { account_currency_id: S.ac.account_currency_id,
    transaction_date: '2026-03-04', economic_type: 'consumption_expense', amount: '-2.00', counter_ledger_account_id: S.groc, idempotency_key: 'bb-card-draft-one' } })).json.result;
  assert.ok(!r.isError, JSON.stringify(r));
  const sc = r.structuredContent;
  assert.equal(r.content[0].text, JSON.stringify(sc));
  assert.equal(r.content[1].text, `Not posted. Review and approve this exact version in Balnexa: ${ORIGIN}/app/#/confirm/${sc.plan_id}?h=${encodeURIComponent(sc.plan_hash)}&s=${encodeURIComponent(sc.scope_digest)}`);
  const g = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_get_for_confirmation', arguments: { plan_id: sc.plan_id } })).json.result;
  assert.equal(g.content[1].text, r.content[1].text, 'server-confirmed state links to the same version');
  assert.equal(g.content.length, 2);
  const nb = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_balances_as_of', arguments: { as_of: '2026-12-31' } })).json.result;
  assert.deepEqual([nb.content.length, nb.structuredContent], [1, bal0], 'not posted; read tools carry no link');
});

test('RV-AIH-01…12 review remediation: consent only through /oauth/authorize; keys required and well-formed on both surfaces; malformed input is a protocol error', async () => {
  // RV-AIH-01: the generic command route cannot create an AI-host consent
  const k = pkce();
  const direct = await cmd('approve_ai_connection', { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: k.c, scopes: ['documents.read'],
    account_currency_ids: [S.ac.account_currency_id] }, S.owner, { 'idempotency-key': 'bb-rv-direct-consent' });
  assert.deepEqual([direct.status, direct.json.error], [403, 'USE_OAUTH_AUTHORIZE']);
  // RV-AIH-10: a malformed subset and duplicate scopes are protocol errors, not 500
  const az = (b) => call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: k.c, code_challenge_method: 'S256',
    scopes: ['finance.read'], account_currency_ids: [S.ac.account_currency_id], resource: R_MCP, ...b }, cookie: S.owner, headers: { origin: ORIGIN } });
  for (const [b, st, e] of [[{ account_currency_ids: [null] }, 400, 'invalid_request'], [{ account_currency_ids: 'x' }, 400, 'invalid_request'],
                            [{ scopes: ['finance.read', 'finance.read'] }, 400, 'invalid_scope'], [{ scopes: [] }, 400, 'invalid_scope'],
                            [{ redirect_uri: 'https://evil.example/cb' }, 400, 'invalid_client']]) {
    const r = await az(b);
    assert.deepEqual([r.status, r.json.error], [st, e], JSON.stringify(b));
  }
  // RV-AIH-03: commands declare a required idempotency key; without it the Core refuses on both surfaces with the same code
  const tools = (await rpcAt(S.bearer, 'tools/list')).json.result.tools;
  const dt = tools.find((t) => t.name === 'fin_draft_create_transaction');
  assert.ok(dt.inputSchema.required.includes('idempotency_key') && dt.inputSchema.properties.idempotency_key.minLength === 8);
  assert.ok(!tools.find((t) => t.name === 'fin_balances_as_of').inputSchema.properties.idempotency_key);
  const args = { account_currency_id: S.ac.account_currency_id, transaction_date: '2026-03-06', economic_type: 'consumption_expense', amount: '-1.50', counter_ledger_account_id: S.groc };
  const m0 = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: args })).json.result;
  const r0 = await call('/api/v1/commands/draft_create_transaction', { body: args, bearer: S.bearerApi });
  assert.deepEqual([m0.isError, m0.structuredContent.error, r0.json.error], [true, 'IDEMPOTENCY_KEY_REQUIRED', 'IDEMPOTENCY_KEY_REQUIRED']);
  // a retry with the same key replays (one draft), on MCP as on REST
  const a1 = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, idempotency_key: 'bb-rv-retry-key' } })).json.result;
  const a2 = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, idempotency_key: 'bb-rv-retry-key' } })).json.result;
  assert.equal(a1.structuredContent.plan_id, a2.structuredContent.plan_id, 'a retry does not create a second draft');
  // RV-AIH-05: a key outside 8-80 printable ASCII is refused on both surfaces, never stored raw
  for (const bad of ['short', 'has a space key', 'fullwidth\uff11\uff12\uff13\uff14\uff15\uff16\uff17\uff18\uff19', 12.5]) {
    const mm = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, idempotency_key: bad } })).json.result;
    const rr = await call('/api/v1/commands/draft_create_transaction', { body: { ...args, idempotency_key: bad }, bearer: S.bearerApi });
    assert.deepEqual([mm.structuredContent.error, mm.structuredContent.field, rr.status, rr.json.error, rr.json.field],
      ['VALIDATION_FAILED', 'idempotency_key', 422, 'VALIDATION_FAILED', 'idempotency_key'], String(bad));
  }
  // RV-AIH-10/12: a non-string tool name is an unknown tool, and the host's input is never echoed
  const on = (await rpcAt(S.bearer, 'tools/call', { name: { x: 1 }, arguments: {} }));
  assert.deepEqual([on.status, on.json.error.code, on.json.error.message], [200, -32602, 'Unknown tool']);
  const echo = (await rpcAt(S.bearer, 'tools/call', { name: 'no_such_tool_abcdef', arguments: {} })).json.error.message;
  assert.equal(echo, 'Unknown tool');
  // RV-AIH-10: a data exception in the Core (a scalar where a list is expected) is VALIDATION_FAILED on both surfaces, not 500
  const sm = (await rpcAt(S.bearer, 'tools/call', { name: 'fin_draft_create_transaction', arguments: { ...args, evidence_file_ids: 'x', idempotency_key: 'bb-rv-scalar-one' } }));
  const sr = await call('/api/v1/commands/draft_create_transaction', { body: { ...args, evidence_file_ids: 'x' }, bearer: S.bearerApi, headers: { 'idempotency-key': 'bb-rv-scalar-two' } });
  assert.deepEqual([sm.status, sm.json.result.structuredContent.error, sr.status, sr.json.error], [200, 'VALIDATION_FAILED', 422, 'VALIDATION_FAILED']);
  // RV-AIH-06: RFC 7009 without client_id or token is refused instead of a silent 200
  const t = await consent({ scopes: ['finance.read'] });
  assert.deepEqual([(await call('/oauth/revoke', { form: { token: t.access_token } })).status, (await call('/oauth/revoke', { form: { client_id: 'chatgpt-test' } })).status], [400, 400]);
  assert.equal((await rpcAt(t.access_token, 'ping')).status, 200);
  // RV-AIH-08/09: body limit; a client name with control or bidirectional characters is refused; a legal name is echoed as stored
  const reg = (b) => call('/oauth/register', { body: b, headers: { 'cf-connecting-ip': ip() } });
  const big = await fetch(`${base}/oauth/register`, { method: 'POST', headers: { 'content-type': 'application/json', 'cf-connecting-ip': ip() },
    body: JSON.stringify({ redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], client_name: 'x'.repeat(20000) }) });
  assert.equal(big.status, 413);
  for (const n of ['Cl\u0000aude', 'Claude‮iaC', 'x'.repeat(101), '', 7]) {
    const r = await reg({ redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], client_name: n });
    assert.deepEqual([r.status, r.json.error], [400, 'invalid_client_metadata'], JSON.stringify(n));
  }
});

test('BB-AUTH-02 logout revokes the session server-side', async () => {
  const out = await call('/auth/logout', { body: {}, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.equal(out.status, 200);
  const q = await call('/api/v1/queries/balances', { body: {}, cookie: S.owner });
  assert.equal(q.status, 401);
});
