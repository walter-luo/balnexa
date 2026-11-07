// Black-box suite: HTTP requests against the real Worker module (node adapter) and a real PostgreSQL database migrated
// by bnx_migrator. No test helper touches the database; identities are synthetic RSA-signed Google-style ID tokens.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeDb, makeKv, serve, worker } from '../../apps/worker/node/adapter.mjs';

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

let INST = null;
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
          EXEC_AUDIENCE: EXEC_AUD, EXEC_JOBS: { INDEX_CONSUME: JOB } };
  srv = await serve(env);
  base = `http://127.0.0.1:${srv.address().port}`;
});
after(async () => { srv && srv.close(); env && await env.db.end(); });

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

test('BB-OAUTH-01 PKCE S256 authorization code flow and MCP read-only scope', async () => {
  const verifier = crypto.randomBytes(40).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  const plain = await call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: challenge,
    code_challenge_method: 'plain', scopes: ['finance.read'], account_currency_ids: [S.ac.account_currency_id] }, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.equal(plain.status, 400);
  // S4 re-baseline (9009): catalog scopes; a replayed code revokes the connection's tokens, so a fresh consent follows
  const authorize = () => call('/oauth/authorize', { body: { client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_challenge: challenge,
    code_challenge_method: 'S256', scopes: ['finance.read', 'finance.draft', 'reports.read'], account_currency_ids: [S.ac.account_currency_id], state: 'xyz' }, cookie: S.owner, headers: { origin: ORIGIN } });
  let az = await authorize();
  assert.equal(az.status, 200, az.text);
  let code = new URL(az.json.redirect).searchParams.get('code');
  const tokenReq = (v) => call('/oauth/token', { form: { grant_type: 'authorization_code', code, client_id: 'chatgpt-test', redirect_uri: 'https://host.example/cb', code_verifier: v } });
  const wrong = await tokenReq(crypto.randomBytes(40).toString('base64url'));
  assert.deepEqual([wrong.status, wrong.json.error], [400, 'invalid_grant']);
  const tok0 = await tokenReq(verifier);
  assert.equal(tok0.status, 200, tok0.text);
  const replay = await tokenReq(verifier);
  assert.deepEqual([replay.status, replay.json.error], [400, 'invalid_grant']);
  const revoked = await call('/mcp', { body: { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_balances', arguments: {} } }, bearer: tok0.json.access_token });
  assert.ok(revoked.json.result.isError, 'token issued before the replay must be revoked');
  az = await authorize();
  code = new URL(az.json.redirect).searchParams.get('code');
  const tok = await tokenReq(verifier);
  assert.equal(tok.status, 200, tok.text);
  S.bearer = tok.json.access_token;
  const rpc = (method, params) => call('/mcp', { body: { jsonrpc: '2.0', id: 1, method, params }, bearer: S.bearer });
  const list = await rpc('tools/list');
  assert.deepEqual(list.json.result.tools.map(t => t.name).sort(), ['create_report_snapshot', 'get_balances', 'replay_snapshot']);
  const bal = await rpc('tools/call', { name: 'get_balances', arguments: { as_of: '2026-12-31' } });
  assert.equal(bal.json.result.structuredContent.balances.length, 1);
  const w = await rpc('tools/call', { name: 'post_transaction', arguments: {} });
  assert.equal(w.json.error.code, -32602);
  // the database, not the Worker, refuses AI-channel writes even when the AI host calls REST directly
  const rest = await call('/api/v1/commands/post_transaction', { body: { idempotency_key: 'bb-ai-00000001', economic_type: 'fee', transaction_date: '2026-02-02',
    description: 'ai', lines: [] }, bearer: S.bearer });
  assert.deepEqual([rest.status, rest.json.error], [403, 'FORBIDDEN_CHANNEL']);
  const noBearer = await call('/mcp', { body: { jsonrpc: '2.0', id: 1, method: 'tools/list' }, cookie: S.owner });
  assert.equal(noBearer.status, 401);
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

test('BB-AUTH-02 logout revokes the session server-side', async () => {
  const out = await call('/auth/logout', { body: {}, cookie: S.owner, headers: { origin: ORIGIN } });
  assert.equal(out.status, 200);
  const q = await call('/api/v1/queries/balances', { body: {}, cookie: S.owner });
  assert.equal(q.status, 401);
});
