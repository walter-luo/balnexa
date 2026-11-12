// Unit tests for the Gateway modules that need no database (CORE-7, AIH): SigV4 presigning (AWS published vector), the JSON
// Schema subset, binding evaluation B1/B2/B3/B8, JWKS rotation, the dispatcher's unknown-kind path (AT-Q-02), the MCP tool set and OAuth metadata.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { presign, presignR2Put } from '../../apps/worker/src/r2presign.js';
import { validate, checkSchema, SchemaError } from '../../apps/worker/src/schema.js';
import { evaluate } from '../../apps/worker/src/binding.js';
import { jwksResolver, verifyGoogleIdToken, AuthError } from '../../apps/worker/src/jwt.js';
import { dispatch, handleItem, KINDS, DEFER, isBackstopTick } from '../../apps/worker/src/dispatch.js';
import { RELEASE } from '../../apps/worker/src/release.js';
import * as mcp from '../../apps/worker/src/mcp.js';
import * as oauth from '../../apps/worker/src/oauth.js';
import * as card from '../../apps/worker/src/card.js';
import * as cf from '../../apps/worker/src/cloudflare.js';

test('UT-PRESIGN-01 SigV4 query-string presigning equals the AWS documented example', async () => {
  // AWS S3 API Reference, "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)", worked example 1.
  // AWS publishes these example credentials for testing implementations; they are not secrets.
  const r = await presign({ method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt', region: 'us-east-1',
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE', secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', expires: 86400,
    date: new Date('2013-05-24T00:00:00Z') });
  assert.equal(r.signature, 'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
  assert.equal(r.url, 'https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
});

test('UT-PRESIGN-02 R2 PUT: account host, bucket path, region auto, 15 minutes, key encoding', async () => {
  const env = { R2_ACCOUNT_ID: 'synthaccount', R2_BUCKET: 'bnx-evidence', R2_ACCESS_KEY_ID: 'synthetic-key-id', R2_SECRET_ACCESS_KEY: 'synthetic-secret' };
  const r = await presignR2Put(env, 'orig/00000000-0000-4000-8000-000000000001', new Date('2026-11-12T03:00:00Z'));
  const u = new URL(r.url);
  assert.equal(u.host, 'synthaccount.r2.cloudflarestorage.com');
  assert.equal(u.pathname, '/bnx-evidence/orig/00000000-0000-4000-8000-000000000001');
  assert.equal(u.searchParams.get('X-Amz-Credential'), 'synthetic-key-id/20261112/auto/s3/aws4_request');
  assert.equal(u.searchParams.get('X-Amz-Expires'), '900');
  assert.match(u.searchParams.get('X-Amz-Signature'), /^[0-9a-f]{64}$/);
  const odd = await presignR2Put(env, 'orig/a b+c', new Date('2026-11-12T03:00:00Z'));
  assert.ok(odd.url.includes('/bnx-evidence/orig/a%20b%2Bc?'), odd.url);
});

test('UT-SCHEMA-01 JSON Schema subset: types, formats, patterns, required, additionalProperties, items', () => {
  const s = { type: 'object', properties: {
    as_of: { type: 'string', format: 'date' }, at: { type: 'string', format: 'date-time' }, id: { type: 'string', format: 'uuid' },
    n: { type: ['integer', 'string'], pattern: '^-?[0-9]{1,18}$' }, amt: { type: ['number', 'string'], pattern: '^-?[0-9]{1,24}(\\.[0-9]{1,12})?$' },
    b: { type: ['boolean', 'string'], enum: [true, false, 'true', 'false'] }, xs: { type: 'array', items: { type: 'string' }, maxItems: 2 } },
    required: ['as_of'], additionalProperties: true };
  const ok = { as_of: '2026-02-28', at: '2026-03-31T23:30:00-04:00', id: '00000000-0000-4000-8000-000000000001', n: 5, amt: '-20.00', b: 'true', xs: ['a'], extra: 1 };
  assert.equal(validate(s, ok), null);
  const bad = [[{ as_of: '2026-02-30' }, '$.as_of'], [{ as_of: '2026-02-28', n: 1.5 }, '$.n'], [{ as_of: '2026-02-28', n: '1e3' }, '$.n'],
               [{ as_of: '2026-02-28', amt: '1,000' }, '$.amt'], [{ as_of: '2026-02-28', b: 'yes' }, '$.b'], [{ as_of: '2026-02-28', id: 'x' }, '$.id'],
               [{ as_of: '2026-02-28', xs: ['a', 'b', 'c'] }, '$.xs'], [{ as_of: '2026-02-28', xs: [1] }, '$.xs[0]'], [{}, '$.as_of'],
               [{ as_of: '2026-02-28', at: '31/03/2026' }, '$.at']];
  for (const [v, path] of bad) assert.equal((validate(s, v) || {}).path, path, JSON.stringify(v));
  assert.equal(validate({ ...s, additionalProperties: false }, ok).reason, 'additional property');
  assert.throws(() => checkSchema({ type: 'object', oneOf: [] }), SchemaError);
  assert.throws(() => checkSchema({ type: 'string', pattern: '(' }));
});

test('UT-BIND-01 binding evaluation: B1 identity, B2 digest, B3 schema range, B8 flags; codes', () => {
  const env = { BNX_PROJECT_ID: 'p1', BNX_INSTANCE_UID: 'u1', BNX_CONFIG_DIGEST: 'd'.repeat(64), BNX_MODULES: '{"Canada":"YES","International":"NO","CRA":"YES"}' };
  const facts = { identity: { project_id: 'p1', instance_uid: 'u1' }, deployable_sha256: ['d'.repeat(64)],
                  schema_head: { core: '0109', extension: '9031' }, active: { flags: { CRA: 'YES', Canada: 'YES', International: 'NO' } } };
  assert.deepEqual(evaluate(env, facts), { ok: true, failed: [], error: null });
  const cases = [
    [{ ...env, BNX_PROJECT_ID: 'p2' }, facts, ['B1'], 'BNX_BINDING_MISMATCH'],
    [{ ...env, BNX_INSTANCE_UID: undefined }, facts, ['B1'], 'BNX_BINDING_MISMATCH'],
    [{ ...env, BNX_CONFIG_DIGEST: 'e'.repeat(64) }, facts, ['B2'], 'BNX_BINDING_MISMATCH'],
    [env, { ...facts, schema_head: { core: '0109', extension: '9032' } }, ['B3'], 'BNX_BINDING_MISMATCH'],       // newer database than this release
    [env, { ...facts, schema_head: { core: '0109', extension: '9016' } }, ['B3'], 'BNX_BINDING_MISMATCH'],       // older than N-1
    [{ ...env, BNX_MODULES: '{"Canada":"YES","International":"YES","CRA":"YES"}' }, facts, ['B8'], 'BNX_FLAG_BINDING_MISMATCH'],
    [{ ...env, BNX_MODULES: 'not json' }, facts, ['B8'], 'BNX_FLAG_BINDING_MISMATCH'],
    [{}, null, ['B1', 'B2', 'B3', 'B8'], 'BNX_BINDING_MISMATCH'],
  ];
  for (const [e, f, failed, error] of cases) assert.deepEqual(evaluate(e, f), { ok: false, failed, error }, JSON.stringify(e));
});

const b64u = (b) => Buffer.from(b).toString('base64url');
function idToken(key, kid, claims = {}) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64u(JSON.stringify({ alg: 'RS256', kid, typ: 'JWT' }));
  const p = b64u(JSON.stringify({ iss: 'https://accounts.google.com', aud: 'test-client', sub: 'g-x', email_verified: true, iat: now, exp: now + 600, ...claims }));
  return `${h}.${p}.${b64u(crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), key.privateKey))}`;
}

test('UT-JWKS-01 kid rotation without redeploy; unknown-kid refetch at most once per 60 s; max-age cache (BB-AUTH-01 rotated kid)', async () => {
  const k1 = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }), k2 = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = (k, kid) => ({ ...k.publicKey.export({ format: 'jwk' }), kid, alg: 'RS256' });
  let served = { keys: [jwk(k1, 'old')] }, fetches = 0;
  const fetchFn = async () => { fetches++; return new Response(JSON.stringify(served), { headers: { 'cache-control': 'public, max-age=3600' } }); };
  const keys = jwksResolver({ fetchFn });
  const t0 = Date.now();
  assert.equal((await verifyGoogleIdToken(idToken(k1, 'old'), { jwks: keys, audience: 'test-client', now: t0 })).sub, 'g-x');
  assert.equal(fetches, 1);
  served = { keys: [jwk(k1, 'old'), jwk(k2, 'new')] };                       // Google rotates
  assert.equal((await verifyGoogleIdToken(idToken(k2, 'new'), { jwks: keys, audience: 'test-client', now: t0 + 61_000 })).sub, 'g-x');
  assert.equal(fetches, 2, 'unknown kid triggers one refetch');
  await assert.rejects(verifyGoogleIdToken(idToken(k2, 'forged-1'), { jwks: keys, audience: 'test-client', now: t0 + 62_000 }), AuthError);
  await assert.rejects(verifyGoogleIdToken(idToken(k2, 'forged-2'), { jwks: keys, audience: 'test-client', now: t0 + 63_000 }), AuthError);
  assert.equal(fetches, 2, 'a flood of unknown kids within 60 s does not refetch');
  await verifyGoogleIdToken(idToken(k1, 'old', { exp: Math.floor(t0 / 1000) + 7200 }), { jwks: keys, audience: 'test-client', now: t0 + 3_700_000 });
  assert.equal(fetches, 3, 'max-age expiry refetches');
});

function mockDb(items) {
  const calls = [];
  let claimed = false;
  return { calls, async one(role, sql, params) {
    calls.push([role, sql.replace(/^select bnx\.([a-z_]+).*$/s, '$1'), params]);
    if (sql.includes('wrk_claim')) { const r = { items: claimed ? [] : items }; claimed = true; return r; }
    if (sql.includes('wrk_queue_status')) return { generation: 1, drained_generation: 1, queued: 0 };
    if (sql.includes('wrk_promote_staged')) return 'promoted';
    if (sql.includes('wrk_defer_item')) return { status: 'deferred' };
    return null;
  } };
}

test('UT-DISPATCH-01 unknown work-item kind is deferred, never completed; known kinds by table (UA §9.1; AT-Q-02)', async () => {
  assert.deepEqual(Object.keys(KINDS).sort(), [...RELEASE.work_kinds].sort(), 'release manifest lists exactly the dispatched kinds');
  assert.equal(await handleItem(mockDb([]), { kind: 'doc.future_kind', payload: {} }), DEFER);
  const db = mockDb([{ id: 7, kind: 'doc.future_kind', payload: {} }, { id: 8, kind: 'staging.promote', payload: { staging_id: 'x' } }]);
  const kv = new Map([['bnx:hint', '1'], ['bnx:drained', '0']]);
  const env = { db, KV: { get: async (k) => kv.get(k) ?? null, put: async (k, v) => kv.set(k, String(v)) } };
  const quiet = new Date('2026-10-30T13:20:00Z').getTime();
  assert.equal(isBackstopTick(quiet), false);
  const r = await dispatch(env, quiet);
  assert.deepEqual([r.processed, r.deferred], [1, 1]);
  const fns = db.calls.map((c) => [c[1], c[2] && c[2][0]]);
  assert.deepEqual(fns.filter(([f]) => f === 'wrk_defer_item'), [['wrk_defer_item', 7]]);
  assert.deepEqual(fns.filter(([f]) => f === 'wrk_complete'), [['wrk_complete', 8]], 'the unknown item is never completed');
});

test('UT-EXEC-SCHEMA-01 completion schemas per (job kind, staging kind) load and reject wrong shapes (UA §9.2; CORE-8)', async () => {
  const { EXEC_SCHEMAS, schemaFor } = await import('../../apps/worker/src/exec_schemas.js');
  for (const s of Object.values(EXEC_SCHEMAS)) checkSchema(s);
  const h = 'a'.repeat(64), id = '7f0c2a52-9b1e-4c56-8a51-3b2d9c0e1f10';
  const ok = { snapshot_id: id, artifact_sha256: h, rendered_at: '2026-11-12T04:00:00+00:00', renderer_version: 'bnx-render-1.0',
               projection_sha256: h, source_revision: 25, ownership_revision: 24, size_kib: 2, coverage: { rows: 7 }, warnings: [] };
  const s = schemaFor('REPORT_RENDER', 'render_done');
  assert.equal(validate(s, ok), null);
  assert.equal(validate(s, { ...ok, artifact_ref: 'r2:x' }).path, '$.artifact_ref');
  assert.equal(validate(s, { ...ok, size_kib: '2' }).path, '$.size_kib');
  assert.equal(validate(schemaFor('EVIDENCE_VERIFY', 'backup_recorded'), { items: [] }).path, '$.items');
  assert.equal(validate(schemaFor('BACKUP', 'backup_recorded'), { run_id: id, started_at: ok.rendered_at, ended_at: ok.rendered_at, outcome: 'FAILED',
                                                                    failure_reason: 'TOOL_MAJOR' }), null);
  assert.equal(schemaFor('INDEX_CONSUME', 'index_consumed'), null);           // 9010 contract: the database validates
});

test('UT-MCP-01 MCP tool set from the catalog: mcp channel and RC-READ/RC-DRAFT only, host-valid names, consent coverage incl. legacy scopes (AIH-2)', () => {
  const e = (name, risk, scopes, legacy = { read: false, propose: false }, channels = ['pwa', 'mcp']) => ({ name, risk_class: risk, scopes, legacy, channels,
    kind: 'query', version: '1.0.0', description: name, input_schema: { type: 'object', properties: {} }, output_schema: { type: 'object' }, mcp: { readOnlyHint: risk === 'RC-READ' } });
  const cat = { entries: [e('fin.balances.as_of', 'RC-READ', ['finance.read'], { read: true, propose: false }), e('fin.draft.create_transaction', 'RC-DRAFT', ['finance.draft'], { read: false, propose: true }),
    e('pwa.post_transaction', 'RC-POST', [], undefined, ['pwa']), e('adm.leak', 'RC-ADMIN', [], undefined, ['pwa', 'mcp']), e('sys.whoami', 'RC-READ', [], { read: true, propose: true }),
    e('handoff.status', 'RC-READ', ['handoff.read'])] };
  const tools = mcp.mcpTools(cat);
  assert.deepEqual([...tools.keys()].sort(), ['fin_balances_as_of', 'fin_draft_create_transaction', 'handoff_status', 'sys_whoami']);
  const names = (scopes) => [...tools.values()].filter((x) => mcp.covered(x, scopes)).map(mcp.toolName).sort();
  assert.deepEqual(names(['finance.read']), ['fin_balances_as_of', 'sys_whoami']);
  assert.deepEqual(names(['finance.read', 'finance.draft', 'handoff.read']), ['fin_balances_as_of', 'fin_draft_create_transaction', 'handoff_status', 'sys_whoami']);
  assert.deepEqual(names(['read']), ['fin_balances_as_of', 'sys_whoami']);                  // legacy R1 read (CROSS-02)
  assert.deepEqual(names(['propose']), ['fin_draft_create_transaction', 'sys_whoami']);      // legacy R1 propose
  assert.deepEqual(names([]), ['sys_whoami']);
  const d = mcp.describe(tools.get('fin_balances_as_of'));
  assert.deepEqual([d.title, d.annotations.destructiveHint, d.annotations.readOnlyHint, d.annotations.idempotentHint], ['fin.balances.as_of', false, true, true]);
  assert.ok(['TR-01', 'TR-02', 'TR-03', 'TR-04', 'TR-05', 'TR-06', 'TR-07', 'TR-08', 'TR-09', 'TR-10', 'TR-11', 'TR-12', 'TR-13', 'TR-14'].every((x) => mcp.INSTRUCTIONS.includes(x)));
});

test('UT-OAUTH-01 metadata documents derive every URL from the instance URL (RFC 8414, RFC 9728; AIH-1)', () => {
  const env = { APP_ORIGIN: 'https://h.example/' };
  assert.equal(oauth.instanceUrl(env), 'https://h.example');
  assert.equal(oauth.instanceUrl({ ...env, BNX_PUBLIC_URL: 'https://pub.example' }), 'https://pub.example');
  const as = oauth.asMetadata(env);
  assert.deepEqual([as.issuer, as.registration_endpoint, as.code_challenge_methods_supported, as.token_endpoint_auth_methods_supported],
    ['https://h.example', 'https://h.example/oauth/register', ['S256'], ['none']]);
  assert.deepEqual(oauth.prMetadata(env, 'api'), { resource: 'https://h.example/api', authorization_servers: ['https://h.example'], scopes_supported: oauth.SCOPES,
    bearer_methods_supported: ['header'], resource_name: 'Balnexa Business API' });
  assert.ok(oauth.CONSENTABLE.every((s) => oauth.SCOPES.includes(s)) && !oauth.CONSENTABLE.some((s) => s.startsWith('tax.')));
  assert.equal(oauth.challenge(env, true), 'Bearer resource_metadata="https://h.example/.well-known/oauth-protected-resource/mcp", scope="finance.read reports.read offline_access", error="invalid_token"');
});

test('UT-CARD-01 confirmation card (AIH-4): the instance URL cannot break out of its JSON element; the card has no network or tool API; sealed link format', () => {
  const html = card.cardHtml('https://x.example/</script><script>alert(1)</script>');
  assert.equal((html.match(/<\/script>/g) || []).length, 2, 'only the two closing tags of the card itself');
  assert.ok(html.includes('\\u003c/script>'));
  for (const bad of [/fetch\(/, /XMLHttpRequest/, /WebSocket/, /tools\/call/, /innerHTML/, /eval\(/]) assert.doesNotMatch(html, bad);
  assert.deepEqual(card.CARD_META.ui.csp, { connectDomains: [], resourceDomains: [] });
  assert.equal(mcp.sealedLink({ APP_ORIGIN: 'https://h.example' }, { plan_id: 'p-1', plan_hash: 'a+b/c=', scope_digest: 's d' }),
    'https://h.example/app/#/confirm/p-1?h=a%2Bb%2Fc%3D&s=s%20d');
  const d = mcp.describe({ name: 'fin.draft.revise', risk_class: 'RC-DRAFT', version: '1.0.0', description: 'x', kind: 'command', input_schema: { type: 'object' },
    output_schema: { type: 'object' }, mcp: { readOnlyHint: false, ui_resource: card.CARD_URI } });
  assert.deepEqual(d._meta.ui, { resourceUri: 'ui://balnexa/cards/v1' });
});

test('UT-CF-01 production entry (M0-A): one Neon client per held role from its secret; other roles refused; env wrapped once per isolate', async () => {
  const seen = [];
  const connect = (url) => ({ query: async (sql, params) => { seen.push([url, sql, params]); return [{ r: { ok: url } }]; } });
  const env = { DB_URL_BNX_APP: 'u-app', DB_URL_BNX_AUTHN: 'u-authn', DB_URL_BNX_WORKER: 'u-worker' };
  const db = cf.makeNeonDb(env, connect);
  assert.deepEqual(await db.one('bnx_app', 'select 1 r', [1]), { ok: 'u-app' });
  assert.deepEqual(await db.one('bnx_worker', 'select 2 r'), { ok: 'u-worker' });
  await assert.rejects(db.one('bnx_migrator', 'select 3 r'), /ROLE_NOT_HELD/);
  await assert.rejects(cf.makeNeonDb({}, connect).one('bnx_app', 'select 4 r'), /DB_URL_MISSING/);
  assert.deepEqual(seen.map((s) => s[0]), ['u-app', 'u-worker']);
  assert.equal(cf.platformEnv(env, connect), cf.platformEnv(env, connect), 'same wrapped env for the same binding object');
});
