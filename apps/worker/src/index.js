// Balnexa Worker (Gateway). Thin transport: every financial and authorization decision is made inside PostgreSQL by
// bnx.cmd_* / bnx.q_* / bnx.authn_* / bnx.wrk_* (SECURITY DEFINER) under the matching login role.
// Routes: POST /auth/google/callback, POST /auth/logout, POST /api/v1/commands/:name, POST /api/v1/queries/:name,
//         GET /api/v1/catalog, GET /api/v1/health, POST /api/v1/uploads, GET /api/v1/artifacts/:snapshot_id (CORE-8), POST /oauth/authorize (PWA consent),
//         POST /oauth/token, POST /mcp (JSON-RPC 2.0, read tools only; replaced by the catalog MCP server in AIH-2),
//         POST /exec/v1/lease, POST /exec/v1/complete (Executor lease model, S4 9010; the Executor holds no DB credential).
// CORE-7 (UA V1.2 §8; OBJ-260, OBJ-263, OBJ-264, OBJ-269, OBJ-270, OBJ-271): binding checks B1/B2/B3/B8 gate every route except /api/v1/health
// (503, fail closed); B7 audience is passed to bnx.resolve_actor; commands and queries resolve through the bnx-tools/1.0
// catalog read from the Core (unknown -> 404; schema-qualified dispatch) and the body is validated against its
// input_schema before the database call (VALIDATION_FAILED, the database's own code).
import { verifyGoogleIdToken, verifyJobToken, jwksResolver, AuthError } from './jwt.js';
import { dispatch } from './dispatch.js';
import { scanJson, scrub } from './sin_detector.js';
import { bindings } from './binding.js';
import { validate } from './schema.js';
import { presignR2Put } from './r2presign.js';
import { RELEASE } from './release.js';
import { schemaFor } from './exec_schemas.js';

// guard C3 (Addendum A1 Rev 1): every log line passes the SIN/ITN scrubber
const log = (...parts) => console.log(parts.map((x) => scrub(typeof x === 'string' ? x : JSON.stringify(x))).join(' '));

const NAME = /^[a-z][a-z_0-9]{2,40}$/;
const STATUS = { P0401: 401, P0403: 403, P0404: 404, P0409: 409, P0422: 422, '42501': 404, '42883': 404, '22P02': 422, '23503': 422, '23505': 409, '23514': 422 };
const MCP_TOOLS = {
  get_balances: { q: 'balances', description: 'Balances per account-currency at an optional ledger_version and date',
    inputSchema: { type: 'object', properties: { as_of: { type: 'string' }, ledger_version: { type: 'integer' } } } },
  create_report_snapshot: { cmd: 'create_report_snapshot', description: 'Create a replayable balance report snapshot (R-BAL)',
    inputSchema: { type: 'object', properties: { as_of: { type: 'string' } } } },
  replay_snapshot: { q: 'replay_snapshot', description: 'Replay a snapshot this connection created',
    inputSchema: { type: 'object', properties: { snapshot_id: { type: 'string' } }, required: ['snapshot_id'] } },
};

const json = (status, body, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers } });

function dbError(e) {
  const code = e.code || '';
  const status = STATUS[code] || (code.startsWith('P0') ? 422 : 500);
  // only the first token of our own exception messages is exposed (e.g. JOURNAL_UNBALANCED); never SQL text
  const err = status === 500 ? 'INTERNAL' : (code === '42501' || code === '42883' ? 'NOT_FOUND' : String(e.message || '').split(/[\s:]/)[0]);
  return json(status, { error: err });
}

function cookie(req, name) {
  const m = (req.headers.get('cookie') || '').match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? decodeURIComponent(m[1]) : null;
}

// B7: a bearer credential carries this Gateway's audience; bnx.resolve_actor refuses a token bound to another resource
function credential(req, env) {
  const auth = req.headers.get('authorization') || '';
  if (auth.startsWith('Bearer ')) return { kind: 'bearer', secret: auth.slice(7), ...(env.BNX_RESOURCE ? { audience: env.BNX_RESOURCE } : {}) };
  const s = cookie(req, 'bnx_session');
  return s ? { kind: 'session', secret: s } : null;
}

function sameOrigin(req, env) {
  // cookie-authenticated writes require the PWA origin (CSRF); bearer requests carry no ambient credential
  if ((req.headers.get('authorization') || '').startsWith('Bearer ')) return true;
  return req.headers.get('origin') === env.APP_ORIGIN;
}

async function body(req) {
  try { return await req.json(); } catch { return null; }
}

const RESOLVERS = new WeakMap();
function jwks(env) {
  if (env.GOOGLE_JWKS) return env.GOOGLE_JWKS;                     // static set (tests) or a resolver function
  if (!RESOLVERS.has(env)) RESOLVERS.set(env, jwksResolver({ fetchFn: env.JWKS_FETCH }));
  return RESOLVERS.get(env);
}

// PWA documents (CORE-9; UA V1.2 §12; OR-U-01/06): the page may talk only to this origin and to Google Identity Services for
// sign-in (no other host, so no hidden LLM call is possible from the shell); camera, microphone and location are never asked.
const PWA_HEADERS = {
  'content-security-policy': "default-src 'self'; script-src 'self' https://accounts.google.com/gsi/client; "
    + "style-src 'self' https://accounts.google.com/gsi/style; frame-src https://accounts.google.com/gsi/; "
    + "connect-src 'self' https://accounts.google.com/gsi/; img-src 'self' data:; font-src 'self'; manifest-src 'self'; "
    + "worker-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY',
  'permissions-policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
  'cross-origin-opener-policy': 'same-origin-allow-popups',
};
const PWA_FILE = /^\/app\/(?:[a-z0-9_-]+\/)*[A-Za-z0-9_.-]*$/;

async function pwaAsset(req, env, p) {
  if (!env.ASSETS || !PWA_FILE.test(p) || p.includes('..')) return json(404, { error: 'NOT_FOUND' });
  const file = p.endsWith('/') ? `${p}index.html` : p;
  const r = await env.ASSETS.fetch(new Request(new URL(file, req.url), { method: req.method }));
  if (r.status !== 200) return json(404, { error: 'NOT_FOUND' });
  const h = new Headers(r.headers);
  for (const [k, v] of Object.entries(PWA_HEADERS)) h.set(k, v);
  // the shell, the service worker and the catalogs revalidate; versioned assets may be cached by the service worker
  h.set('cache-control', /\.(html|json|webmanifest)$|\/sw\.js$/.test(file) ? 'no-cache' : 'public, max-age=300');
  if (file.endsWith('/sw.js')) h.set('service-worker-allowed', '/app/');
  return new Response(req.method === 'HEAD' ? null : r.body, { status: 200, headers: h });
}

// Idempotency keys (D-CORE10-3; closes L-CORE9-9): the client's key reaches the database as a digest spelled in letters only,
// so a client whose keys contain digits (an AI host, a script) is never refused by the audit guard for a Luhn-valid 9-digit run
// (9011 guard C2), and no raw client key is stored. Deterministic: a retry with the same key replays; another body under the
// same key is still IDEMPOTENCY_KEY_REUSED. A key outside 8..80 printable characters is passed through so that the database
// reports its own error code.
const KEY_LETTERS = 'abcdefghijklmnopqrstuvwxyzABCDEF';
async function gatewayKey(raw) {
  if (!/^[\x21-\x7e]{8,80}$/.test(raw)) return raw;
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw)));
  return `gk-${Array.from(d, (b) => KEY_LETTERS[b & 31]).join('')}`;
}

const uploadsConfigured = (env) => !!(env.R2_ACCOUNT_ID && env.R2_BUCKET && env.R2_ACCESS_KEY_ID && env.R2_SECRET_ACCESS_KEY);

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;
    try {
      // CORE-9: the PWA shell is static and reveals nothing, so it is served before the binding checks (its API calls are not)
      if ((req.method === 'GET' || req.method === 'HEAD') && (p === '/' || p === '/app')) {
        return new Response(null, { status: 302, headers: { location: '/app/', ...PWA_HEADERS } });
      }
      if (req.method === 'GET' && p === '/app/config.json') {
        return json(200, { google_client_id: env.GOOGLE_CLIENT_ID || null, release: RELEASE.version }, { ...PWA_HEADERS, 'cache-control': 'no-store' });
      }
      if ((req.method === 'GET' || req.method === 'HEAD') && p.startsWith('/app/')) return pwaAsset(req, env, p);
      // health answers even when a binding check fails; it reveals no identity value (q_health, 9003)
      if (req.method === 'GET' && p === '/api/v1/health') {
        const b = await bindings(env);
        let h = null;
        try { h = await env.db.one('bnx_app', "select bnx.q_health(null::jsonb, '{}'::jsonb) r", []); } catch { h = { status: 'unreachable' }; }
        return json(b.ok ? 200 : 503, { ...h, release: RELEASE.version, bindings: { ok: b.ok, failed: b.failed } });
      }
      const b = await bindings(env);
      if (!b.ok) return json(503, { error: b.error });                // ISO-4: fail closed
      if (req.method === 'POST' && p === '/auth/google/callback') {
        if (!sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const bd = await body(req);
        let claims;
        try {
          claims = await verifyGoogleIdToken(bd && bd.id_token, { jwks: jwks(env), audience: env.GOOGLE_CLIENT_ID });
        } catch (e) { if (e instanceof AuthError) return json(401, { error: 'UNAUTHENTICATED' }); throw e; }
        const r = await env.db.one('bnx_authn', 'select bnx.authn_begin_session($1::jsonb) r',
          [JSON.stringify({ iss: claims.iss, sub: claims.sub, email_verified: claims.email_verified, aud: claims.aud })]);
        return json(200, { member_id: r.member_id }, {
          'set-cookie': `bnx_session=${encodeURIComponent(r.session_token)}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=7776000` });
      }
      if (req.method === 'POST' && p === '/auth/logout') {
        const cred = credential(req, env);
        if (!cred || !sameOrigin(req, env)) return json(401, { error: 'UNAUTHENTICATED' });
        await env.db.one('bnx_app', 'select bnx.cmd_revoke_session($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), '{}']);
        return json(200, { status: 'revoked' }, { 'set-cookie': 'bnx_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0' });
      }
      let m = p.match(/^\/api\/v1\/(commands|queries)\/([^/]+)$/);
      if (req.method === 'POST' && m) {
        const [, kind, name] = m;
        const entry = NAME.test(name) ? b.catalog.byRest.get(`/api/v1/${kind}/${name}`) : null;
        if (!entry) return json(404, { error: 'NOT_FOUND' });         // not in the catalog read from the Core
        const cred = credential(req, env);
        if (!cred && entry.risk_class !== 'RC-PUBLIC') return json(401, { error: 'UNAUTHENTICATED' });
        if (kind === 'commands' && !sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const bd = (await body(req)) ?? {};                             // R1: an absent or unparsable body is {}
        if (typeof bd !== 'object' || Array.isArray(bd)) return json(422, { error: 'VALIDATION_FAILED', field: '$' });
        if (kind === 'commands' && req.headers.get('idempotency-key')) bd.idempotency_key = req.headers.get('idempotency-key');
        if (kind === 'commands' && typeof bd.idempotency_key === 'string') bd.idempotency_key = await gatewayKey(bd.idempotency_key);
        const bad = validate(entry.input_schema, bd);
        if (bad) return json(422, { error: 'VALIDATION_FAILED', field: bad.path });
        const r = await env.db.one('bnx_app', `select ${entry.core_function}($1::jsonb, $2::jsonb) r`, [JSON.stringify(cred), JSON.stringify(bd)]);
        if (r && r.queue_generation !== undefined) await env.KV.put('bnx:hint', String(r.queue_generation));  // after COMMIT
        return json(200, r);
      }
      if (req.method === 'GET' && p === '/api/v1/catalog') {           // sys.catalog (RC-READ)
        const cred = credential(req, env);
        if (!cred) return json(401, { error: 'UNAUTHENTICATED' });
        await env.db.one('bnx_app', "select bnx.q_whoami($1::jsonb, '{}'::jsonb) r", [JSON.stringify(cred)]);   // credential is live
        const entries = cred.kind === 'bearer' ? b.catalog.entries.filter((e) => e.channels.includes('mcp')) : b.catalog.entries;
        return json(200, { format: b.catalog.format, catalog_sha256: b.catalog.sha256, release: RELEASE.version, entries });
      }
      m = p.match(/^\/api\/v1\/artifacts\/([0-9a-fA-F-]{36})$/);
      if (req.method === 'GET' && m) {                                // artifact proxy (UA V1.2 §5.8.2; L-9013-2; CORE-8)
        const cred = credential(req, env);
        if (!cred) return json(401, { error: 'UNAUTHENTICATED' });
        let a;
        try {
          a = await env.db.one('bnx_app', 'select bnx.q_snapshot_artifact($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), JSON.stringify({ snapshot_id: m[1] })]);
        } catch (e) {
          // the current grant decides; a revoked snapshot discloses nothing but its status
          if (e.code === 'P0403' && String(e.message).startsWith('ACCESS_REVOKED')) return json(403, { error: 'ACCESS_REVOKED' }, { 'x-bnx-snapshot-status': 'ACCESS_REVOKED' });
          throw e;
        }
        if (!a || !a.artifact_ref) return json(404, { error: 'NOT_AVAILABLE' });
        if (!a.artifact_ref.startsWith('r2:') || !env.ARTIFACTS) return json(503, { error: 'ARTIFACT_STORE_NOT_CONFIGURED' });
        const obj = await env.ARTIFACTS.get(a.artifact_ref.slice(3));
        if (!obj) return json(502, { error: 'ARTIFACT_MISSING' });
        const bytes = new Uint8Array(await obj.arrayBuffer());
        const got = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map((x) => x.toString(16).padStart(2, '0')).join('');
        if (got !== a.artifact_sha256) { log('artifact_integrity', m[1]); return json(502, { error: 'ARTIFACT_INTEGRITY' }); }
        return new Response(bytes, { status: 200, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'private, no-store',
          'x-bnx-snapshot-status': a.status, 'x-bnx-artifact-sha256': a.artifact_sha256, 'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'",
          'x-content-type-options': 'nosniff' } });
      }
      if (req.method === 'POST' && p === '/api/v1/uploads') {          // presigned direct-to-R2 PUT (UA §8.1; O-7)
        const cred = credential(req, env);
        if (!cred || cred.kind !== 'session') return json(401, { error: 'UNAUTHENTICATED' });
        if (!sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        if (!uploadsConfigured(env)) return json(503, { error: 'UPLOADS_NOT_CONFIGURED' });
        const bd = (await body(req)) || {};
        const t = await env.db.one('bnx_app', 'select bnx.q_evidence_upload_target($1::jsonb, $2::jsonb) r',
          [JSON.stringify(cred), JSON.stringify({ evidence_file_id: bd.evidence_file_id })]);
        const s = await presignR2Put(env, t.r2_key);
        return json(200, { evidence_file_id: t.evidence_file_id, method: 'PUT', url: s.url, expires_in: 900,
                           headers: { 'content-type': t.mime }, size_bytes: t.size_bytes, sha256_declared: t.sha256_declared });
      }
      if (req.method === 'POST' && p === '/oauth/authorize') {      // consent submitted by the signed-in PWA
        const cred = credential(req, env);
        if (!cred || cred.kind !== 'session') return json(401, { error: 'UNAUTHENTICATED' });
        if (!sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const bd = (await body(req)) || {};
        if (bd.code_challenge_method !== 'S256') return json(400, { error: 'invalid_request' });
        bd.idempotency_key = bd.idempotency_key || crypto.randomUUID();
        const r = await env.db.one('bnx_app', 'select bnx.cmd_approve_ai_connection($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), JSON.stringify(bd)]);
        const to = new URL(bd.redirect_uri);
        to.searchParams.set('code', r.code);
        if (bd.state) to.searchParams.set('state', bd.state);
        return json(200, { redirect: to.toString() });
      }
      if (req.method === 'POST' && p === '/oauth/token') {
        const f = new URLSearchParams(await req.text());
        const gt = f.get('grant_type');
        if (gt !== 'authorization_code' && gt !== 'refresh_token') return json(400, { error: 'unsupported_grant_type' });
        try {
          // S4 9009: replay / refresh-reuse detection revokes tokens and is RETURNED as {error} so the revocation commits
          const r = gt === 'authorization_code'
            ? await env.db.one('bnx_authn', 'select bnx.authn_oauth_token($1::jsonb) r', [JSON.stringify({
                code: f.get('code'), client_id: f.get('client_id'), redirect_uri: f.get('redirect_uri'), code_verifier: f.get('code_verifier'),
                ...(f.get('resource') ? { resource: f.get('resource') } : {}) })])
            : await env.db.one('bnx_authn', 'select bnx.authn_oauth_refresh($1::jsonb) r', [JSON.stringify({
                refresh_token: f.get('refresh_token'), client_id: f.get('client_id') })]);
          if (r && r.error) return json(400, { error: r.error });
          return json(200, r);
        } catch (e) { if (e.code === 'P0401') return json(400, { error: e.message === 'INVALID_TARGET' ? 'invalid_target' : 'invalid_grant' }); throw e; }
      }
      if (req.method === 'POST' && (p === '/exec/v1/lease' || p === '/exec/v1/complete')) {
        const raw = await req.text();
        if (raw.length > 300000) return json(413, { error: 'PAYLOAD_TOO_LARGE' });
        let bd = null; try { bd = JSON.parse(raw); } catch { bd = null; }
        if (!bd || typeof bd.job_kind !== 'string') return json(400, { error: 'VALIDATION_FAILED' });
        const pin = (env.EXEC_JOBS || {})[bd.job_kind];                    // configured job identity per job kind
        const auth = req.headers.get('authorization') || '';
        let claims;
        try {
          claims = await verifyJobToken(auth.startsWith('Bearer ') ? auth.slice(7) : null, { jwks: jwks(env), audience: env.EXEC_AUDIENCE, pin });
        } catch (e) { if (e instanceof AuthError) return json(401, { error: 'UNAUTHENTICATED' }); throw e; }
        if (p === '/exec/v1/lease') {
          const r = await env.db.one('bnx_worker', 'select bnx.wrk_issue_exec_lease($1::jsonb) r', [JSON.stringify({
            job_kind: bd.job_kind, item_id: bd.item_id ?? null, sub: claims.sub, email: claims.email, azp: claims.azp })]);
          return json(200, r);
        }
        // completion: the Gateway writes the staging row as bnx_worker (lease_completions = gateway); never a posting call.
        // CORE-8: the payload shape is checked against the schema of its (job kind, staging kind) first (UA §9.2)
        const sch = schemaFor(bd.job_kind, String(bd.stg_kind || ''));
        if (sch) {
          const bad = validate(sch, bd.payload);
          if (bad) return json(422, { error: 'VALIDATION_FAILED', field: bad.path });
        }
        const r = await env.db.one('bnx_worker', 'select bnx.wrk_stage_completion($1::text, $2::text, $3::jsonb) r',
          [String(bd.nonce || ''), String(bd.stg_kind || ''), JSON.stringify(bd.payload ?? null)]);
        if (r && r.queue_generation !== undefined) await env.KV.put('bnx:hint', String(r.queue_generation));
        return json(200, { staging_id: r.staging_id, state: r.state });
      }
      if (req.method === 'POST' && p === '/mcp') {
        const cred = credential(req, env);
        if (!cred || cred.kind !== 'bearer') return json(401, { error: 'UNAUTHENTICATED' }, { 'www-authenticate': 'Bearer' });
        const rpc = await body(req);
        if (!rpc || rpc.jsonrpc !== '2.0') return json(400, { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request' } });
        const reply = (result) => json(200, { jsonrpc: '2.0', id: rpc.id, result });
        const fail = (code, message) => json(200, { jsonrpc: '2.0', id: rpc.id, error: { code, message } });
        if (rpc.method === 'initialize') return reply({ protocolVersion: '2025-06-18', serverInfo: { name: 'balnexa', version: RELEASE.version }, capabilities: { tools: {} } });
        if (rpc.method === 'tools/list') return reply({ tools: Object.entries(MCP_TOOLS).map(([name, t]) => ({ name, description: t.description, inputSchema: t.inputSchema })) });
        if (rpc.method === 'tools/call') {
          const t = MCP_TOOLS[rpc.params && rpc.params.name];
          if (!t) return fail(-32602, 'unknown tool');
          const args = { ...(rpc.params.arguments || {}) };
          if (t.cmd) args.idempotency_key = await gatewayKey(typeof args.idempotency_key === 'string' ? args.idempotency_key : crypto.randomUUID());   // D-CORE10-3
          try {
            const r = await env.db.one('bnx_app', `select bnx.${t.cmd ? 'cmd_' + t.cmd : 'q_' + t.q}($1::jsonb, $2::jsonb) r`, [JSON.stringify(cred), JSON.stringify(args)]);
            // guard C4 (Addendum A1 Rev 1, 9011b): an AI host never receives a SIN/ITN candidate; refused, audited without the value
            const hits = scanJson(r);
            if (hits.length) {
              await env.db.one('bnx_worker', 'select bnx.wrk_audit_sin_refusal($1::jsonb) r',
                [JSON.stringify({ tool: rpc.params.name, rules: [...new Set(hits.map((h) => h.rule))].sort() })]);
              return reply({ isError: true, content: [{ type: 'text', text: 'SIN_CANDIDATE_REFUSED' }] });
            }
            return reply({ content: [{ type: 'text', text: JSON.stringify(r) }], structuredContent: r });
          } catch (e) {
            if (String(e.code || '').startsWith('P0')) return reply({ isError: true, content: [{ type: 'text', text: String(e.message).split(/[\s:]/)[0] }] });
            throw e;
          }
        }
        return fail(-32601, 'Method not found');
      }
      return json(404, { error: 'NOT_FOUND' });
    } catch (e) {
      if (e && e.code) return dbError(e);
      log('worker_error', String((e && e.message) || e));
      return json(500, { error: 'INTERNAL' });
    }
  },
  async scheduled(event, env, ctx) {
    // ISO-4: a Worker whose bindings fail never dispatches against the database it is connected to
    const b = await bindings(env, event.scheduledTime || Date.now());
    if (!b.ok) { log('dispatch_refused', b.error, b.failed); return { neon: false, processed: 0, binding: b.error }; }
    const work = dispatch(env, event.scheduledTime || Date.now());
    if (ctx && ctx.waitUntil) ctx.waitUntil(work);
    return work;
  },
};
