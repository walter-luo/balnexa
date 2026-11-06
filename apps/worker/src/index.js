// Balnexa Worker — M0 vertical slice. Thin transport: every financial and authorization decision is made inside
// PostgreSQL by bnx.cmd_* / bnx.q_* / bnx.authn_* / bnx.wrk_* (SECURITY DEFINER) under the matching login role.
// Routes: POST /auth/google/callback, POST /auth/logout, POST /api/v1/commands/:name, POST /api/v1/queries/:name,
//         POST /oauth/authorize (PWA consent), POST /oauth/token, POST /mcp (JSON-RPC 2.0, read tools only).
import { verifyGoogleIdToken, AuthError } from './jwt.js';
import { dispatch } from './dispatch.js';

const NAME = /^[a-z][a-z_]{2,40}$/;
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

function credential(req) {
  const auth = req.headers.get('authorization') || '';
  if (auth.startsWith('Bearer ')) return { kind: 'bearer', secret: auth.slice(7) };
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

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname;
    try {
      if (req.method === 'POST' && p === '/auth/google/callback') {
        if (!sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const b = await body(req);
        let claims;
        try {
          claims = await verifyGoogleIdToken(b && b.id_token, { jwks: env.GOOGLE_JWKS, audience: env.GOOGLE_CLIENT_ID });
        } catch (e) { if (e instanceof AuthError) return json(401, { error: 'UNAUTHENTICATED' }); throw e; }
        const r = await env.db.one('bnx_authn', 'select bnx.authn_begin_session($1::jsonb) r',
          [JSON.stringify({ iss: claims.iss, sub: claims.sub, email_verified: claims.email_verified, aud: claims.aud })]);
        return json(200, { member_id: r.member_id }, {
          'set-cookie': `bnx_session=${encodeURIComponent(r.session_token)}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=7776000` });
      }
      if (req.method === 'POST' && p === '/auth/logout') {
        const cred = credential(req);
        if (!cred || !sameOrigin(req, env)) return json(401, { error: 'UNAUTHENTICATED' });
        await env.db.one('bnx_app', 'select bnx.cmd_revoke_session($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), '{}']);
        return json(200, { status: 'revoked' }, { 'set-cookie': 'bnx_session=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0' });
      }
      let m = p.match(/^\/api\/v1\/(commands|queries)\/([^/]+)$/);
      if (req.method === 'POST' && m) {
        const [, kind, name] = m;
        if (!NAME.test(name)) return json(404, { error: 'NOT_FOUND' });
        const cred = credential(req);
        if (!cred) return json(401, { error: 'UNAUTHENTICATED' });
        if (kind === 'commands' && !sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const b = (await body(req)) || {};
        if (kind === 'commands' && req.headers.get('idempotency-key')) b.idempotency_key = req.headers.get('idempotency-key');
        const fn = (kind === 'commands' ? 'cmd_' : 'q_') + name;
        const r = await env.db.one('bnx_app', `select bnx.${fn}($1::jsonb, $2::jsonb) r`, [JSON.stringify(cred), JSON.stringify(b)]);
        if (r && r.queue_generation !== undefined) await env.KV.put('bnx:hint', String(r.queue_generation));  // after COMMIT
        return json(200, r);
      }
      if (req.method === 'POST' && p === '/oauth/authorize') {      // consent submitted by the signed-in PWA
        const cred = credential(req);
        if (!cred || cred.kind !== 'session') return json(401, { error: 'UNAUTHENTICATED' });
        if (!sameOrigin(req, env)) return json(403, { error: 'ORIGIN' });
        const b = (await body(req)) || {};
        if (b.code_challenge_method !== 'S256') return json(400, { error: 'invalid_request' });
        b.idempotency_key = b.idempotency_key || crypto.randomUUID();
        const r = await env.db.one('bnx_app', 'select bnx.cmd_approve_ai_connection($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), JSON.stringify(b)]);
        const to = new URL(b.redirect_uri);
        to.searchParams.set('code', r.code);
        if (b.state) to.searchParams.set('state', b.state);
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
      if (req.method === 'POST' && p === '/mcp') {
        const cred = credential(req);
        if (!cred || cred.kind !== 'bearer') return json(401, { error: 'UNAUTHENTICATED' }, { 'www-authenticate': 'Bearer' });
        const rpc = await body(req);
        if (!rpc || rpc.jsonrpc !== '2.0') return json(400, { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid Request' } });
        const reply = (result) => json(200, { jsonrpc: '2.0', id: rpc.id, result });
        const fail = (code, message) => json(200, { jsonrpc: '2.0', id: rpc.id, error: { code, message } });
        if (rpc.method === 'initialize') return reply({ protocolVersion: '2025-06-18', serverInfo: { name: 'balnexa', version: '0.1.0-r1' }, capabilities: { tools: {} } });
        if (rpc.method === 'tools/list') return reply({ tools: Object.entries(MCP_TOOLS).map(([name, t]) => ({ name, description: t.description, inputSchema: t.inputSchema })) });
        if (rpc.method === 'tools/call') {
          const t = MCP_TOOLS[rpc.params && rpc.params.name];
          if (!t) return fail(-32602, 'unknown tool');
          const args = { ...(rpc.params.arguments || {}) };
          if (t.cmd) args.idempotency_key = args.idempotency_key || crypto.randomUUID();
          try {
            const r = await env.db.one('bnx_app', `select bnx.${t.cmd ? 'cmd_' + t.cmd : 'q_' + t.q}($1::jsonb, $2::jsonb) r`, [JSON.stringify(cred), JSON.stringify(args)]);
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
      return json(500, { error: 'INTERNAL' });
    }
  },
  async scheduled(event, env, ctx) {
    const work = dispatch(env, event.scheduledTime || Date.now());
    if (ctx && ctx.waitUntil) ctx.waitUntil(work);
    return work;
  },
};
