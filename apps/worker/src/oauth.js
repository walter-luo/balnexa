// OAuth 2.1 Authorization Server and Resource Server metadata of the Gateway for AI hosts (AIH V1.2 §4; UA V1.2 §7.2, §8;
// AIH-1). Every decision about clients, codes, tokens and consent is made in PostgreSQL (bnx.authn_* as bnx_authn,
// bnx.cmd_approve_ai_connection under the PWA session); this module only speaks the protocol:
//   GET  /.well-known/oauth-authorization-server         RFC 8414
//   GET  /.well-known/oauth-protected-resource/{mcp,api}  RFC 9728 (resource = exact URL of that surface on this instance)
//   POST /oauth/register                                  RFC 7591 DCR (public clients only; host profile inferred by the Core)
//   GET  /oauth/authorize                                 client + redirect check, then the PWA consent screen (#/consent)
//   POST /oauth/authorize                                 the PWA's describe / approve / deny (session + same origin)
//   POST /oauth/revoke                                    RFC 7009
// CIMD (Client ID Metadata Document): an unknown https client id that matches a host-profile allowlist is fetched once
// (5 s, 10 KB, no redirects) and registered as CIMD by the Core; any other URL is never fetched.
import { json, errCode, letters } from './http.js';

export const SCOPES = ['finance.read', 'finance.draft', 'documents.read', 'documents.propose', 'tax.read', 'tax.propose', 'reports.read',
  'handoff.read', 'handoff.prepare', 'alerts.summary.read', 'offline_access'];
// what the consent screen can grant in this release (D-AIH-6): documents.read needs a document-class subset and tax.* the
// taxpayer subset of WP-TAX (G-CRA-1), neither of which the consent screen offers yet; alerts.summary.read has no tool
export const CONSENTABLE = ['finance.read', 'finance.draft', 'reports.read', 'handoff.read', 'handoff.prepare', 'offline_access'];
export const HINT_SCOPE = 'finance.read reports.read offline_access';

export const instanceUrl = (env) => String(env.BNX_PUBLIC_URL || env.APP_ORIGIN || '').replace(/\/+$/, '');
export const resources = (env) => ({ mcp: `${instanceUrl(env)}/mcp`, api: `${instanceUrl(env)}/api` });
export const prmUrl = (env, which) => `${instanceUrl(env)}/.well-known/oauth-protected-resource/${which}`;

export function asMetadata(env) {
  const u = instanceUrl(env);
  return {
    issuer: u, authorization_endpoint: `${u}/oauth/authorize`, token_endpoint: `${u}/oauth/token`,
    registration_endpoint: `${u}/oauth/register`, revocation_endpoint: `${u}/oauth/revoke`,
    response_types_supported: ['code'], response_modes_supported: ['query'],
    grant_types_supported: ['authorization_code', 'refresh_token'], code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'], revocation_endpoint_auth_methods_supported: ['none'],
    scopes_supported: SCOPES, client_id_metadata_document_supported: true,
  };
}

export function prMetadata(env, which) {
  return { resource: resources(env)[which], authorization_servers: [instanceUrl(env)], scopes_supported: SCOPES,
           bearer_methods_supported: ['header'], resource_name: which === 'mcp' ? 'Balnexa MCP' : 'Balnexa Business API' };
}

// 401 challenge of the MCP surface (AIH §3; RFC 9728 §5.1)
export const challenge = (env, invalid) =>
  `Bearer resource_metadata="${prmUrl(env, 'mcp')}", scope="${HINT_SCOPE}"${invalid ? ', error="invalid_token"' : ''}`;

const PAGE_HEADERS = { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'content-security-policy': "default-src 'none'",
  'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY' };
// shown instead of a redirect when the client or its redirect URI cannot be trusted (RFC 6749 §4.1.2.1); static text only
const page = (status, msg) => new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><title>Balnexa</title><p>${msg}</p></html>`,
  { status, headers: PAGE_HEADERS });
const back = (ru, params) => {
  const u = new URL(ru);
  for (const [k, v] of Object.entries(params)) if (v) u.searchParams.set(k, v);
  return u.toString();
};
// a client's self-chosen name: at most 100 characters, no control, format or bidirectional-override characters (RV-AIH-08/09)
const BAD_NAME = /[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]/;
export const nameOk = (n) => typeof n === 'string' && n.length >= 1 && n.length <= 100 && !BAD_NAME.test(n);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const found = (location) => new Response(null, { status: 302, headers: { location, 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' } });

async function fetchCimd(env, clientId) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), 5000);
  try {
    const r = await (env.CIMD_FETCH || fetch)(clientId, { redirect: 'manual', signal: ac.signal, headers: { accept: 'application/json' } });
    if (r.status !== 200) return null;
    const text = await r.text();
    if (text.length > 10000) return null;
    const m = JSON.parse(text);
    if (!m || m.client_id !== clientId || !Array.isArray(m.redirect_uris) || !m.redirect_uris.every((x) => typeof x === 'string')) return null;
    if (m.token_endpoint_auth_method !== undefined && m.token_endpoint_auth_method !== 'none') return null;
    return m;
  } catch { return null; } finally { clearTimeout(timer); }
}

// the Core's view of a client and a redirect URI; an unknown CIMD-eligible client id is fetched and registered first
export async function client(env, clientId, redirectUri, { cimd = false } = {}) {
  const look = () => env.db.one('bnx_authn', 'select bnx.authn_oauth_client($1::jsonb) r', [JSON.stringify({ client_id: clientId, redirect_uri: redirectUri })]);
  let c = await look();
  if (cimd && !c.known && c.cimd_allowed) {
    const m = await fetchCimd(env, clientId);
    if (!m) return c;
    try {
      await env.db.one('bnx_authn', 'select bnx.authn_register_client($1::jsonb) r', [JSON.stringify({ registration_kind: 'CIMD', client_id: clientId,
        redirect_uris: m.redirect_uris, ...(nameOk(m.client_name) ? { client_name: m.client_name } : {}) })]);
    } catch (e) { if (String(e.code || '').startsWith('P0')) return c; throw e; }
    c = await look();
  }
  return c;
}

export async function authorizeGet(url, env) {
  const q = url.searchParams;
  const cid = q.get('client_id'), ru = q.get('redirect_uri'), state = q.get('state');
  if (!cid || !ru) return page(400, 'Invalid request: client_id and redirect_uri are required.');
  const c = await client(env, cid, ru, { cimd: true });
  if (!c.known || !c.redirect_ok) return page(400, 'Unknown client or unregistered redirect URI. Nothing was sent back to the application.');
  if (state && state.length > 500) return page(400, 'Invalid request: state is too long.');
  const err = (e) => found(back(ru, { error: e, state }));
  if (q.get('response_type') !== 'code') return err('unsupported_response_type');
  if (q.get('code_challenge_method') !== 'S256' || !/^[A-Za-z0-9_-]{43}$/.test(q.get('code_challenge') || '')) return err('invalid_request');
  const R = resources(env);
  const res = q.get('resource') || R.mcp;                     // D-AIH-3: an MCP client that sends no resource gets the MCP resource
  if (res !== R.mcp && res !== R.api) return err('invalid_target');
  const scopes = [...new Set((q.get('scope') || HINT_SCOPE).split(/\s+/).filter((s) => SCOPES.includes(s)))];
  const p = new URLSearchParams({ client_id: cid, redirect_uri: ru, code_challenge: q.get('code_challenge'), code_challenge_method: 'S256',
    resource: res, scope: (scopes.length ? scopes : HINT_SCOPE.split(' ')).join(' ') });
  if (state) p.set('state', state);
  return found(`/app/#/consent?${p}`);
}

// POST /oauth/authorize from the signed-in PWA (cookie + same origin checked by the caller): describe | deny | approve
export async function authorizePost(bd, cred, env) {
  const live = () => env.db.one('bnx_app', "select bnx.q_whoami($1::jsonb, '{}'::jsonb) r", [JSON.stringify(cred)]);
  if (bd.action === 'describe' || bd.action === 'deny') {
    await live();                                              // a dead session is UNAUTHENTICATED before anything is disclosed
    const c = await client(env, bd.client_id, bd.redirect_uri);
    if (!c.known || !c.redirect_ok) return json(400, { error: 'invalid_client' });
    if (bd.action === 'deny') return json(200, { redirect: back(bd.redirect_uri, { error: 'access_denied', state: bd.state }) });
    return json(200, { client_id: c.client_id, client_name: c.client_name, host_profile: c.host_profile, registration_kind: c.registration_kind,
                       consentable: CONSENTABLE, resources: resources(env) });
  }
  if (bd.code_challenge_method !== 'S256') return json(400, { error: 'invalid_request' });
  // RV-AIH-10: the subset is a list of account-currency ids, checked here so that a malformed list is a protocol error
  if (!Array.isArray(bd.account_currency_ids) || bd.account_currency_ids.length > 500 || !bd.account_currency_ids.every((x) => typeof x === 'string' && UUID.test(x))) {
    return json(400, { error: 'invalid_request' });
  }
  // RV-AIH-07: the client and its redirect URI are checked again at approval (the environment may have changed since)
  const c = await client(env, bd.client_id, bd.redirect_uri);
  if (!c.known || !c.redirect_ok) return json(400, { error: 'invalid_client' });
  const R = resources(env);
  // L-CORE7-4 closed: every new consent is bound to one surface of this instance (B7 audience on every call)
  if (bd.resource !== R.mcp && bd.resource !== R.api) return json(400, { error: 'invalid_target' });
  if (!Array.isArray(bd.scopes) || !bd.scopes.length || new Set(bd.scopes).size !== bd.scopes.length || !bd.scopes.every((s) => CONSENTABLE.includes(s))) {
    return json(400, { error: 'invalid_scope' });
  }
  // state stays at the Gateway: it is the client's opaque value and is not part of the audited consent
  const cmd = { ...bd, idempotency_key: `oauth-${letters(24)}` };
  delete cmd.action; delete cmd.state;
  const r = await env.db.one('bnx_app', 'select bnx.cmd_approve_ai_connection($1::jsonb, $2::jsonb) r', [JSON.stringify(cred), JSON.stringify(cmd)]);
  return json(200, { redirect: back(bd.redirect_uri, { code: r.code, state: bd.state }), connection_id: r.connection_id });
}

export async function register(req, env) {
  const raw = await req.text();
  if (raw.length > 16384) return json(413, { error: 'invalid_client_metadata', error_description: 'body larger than 16 KB' });   // RV-AIH-08
  let bd = null;
  try { bd = JSON.parse(raw); } catch { /* refused below */ }
  const bad = (error, d) => json(400, { error, error_description: d });
  if (!bd || typeof bd !== 'object' || Array.isArray(bd)) return bad('invalid_client_metadata', 'JSON object expected');
  if (bd.token_endpoint_auth_method !== undefined && bd.token_endpoint_auth_method !== 'none') return bad('invalid_client_metadata', 'public clients only (none)');
  if (bd.grant_types !== undefined && !(Array.isArray(bd.grant_types) && bd.grant_types.every((g) => g === 'authorization_code' || g === 'refresh_token'))) {
    return bad('invalid_client_metadata', 'grant_types');
  }
  if (bd.response_types !== undefined && !(Array.isArray(bd.response_types) && bd.response_types.every((g) => g === 'code'))) return bad('invalid_client_metadata', 'response_types');
  if (!Array.isArray(bd.redirect_uris) || !bd.redirect_uris.length || !bd.redirect_uris.every((u) => typeof u === 'string' && u.length <= 500)) {
    return bad('invalid_redirect_uri', 'redirect_uris');
  }
  if (bd.client_name !== undefined && !nameOk(bd.client_name)) return bad('invalid_client_metadata', 'client_name');
  // OD-21 default: open DCR, rate-limited per client address and UTC day (KV; best effort across isolates)
  const key = `bnx:dcr:${new Date().toISOString().slice(0, 10)}:${req.headers.get('cf-connecting-ip') || 'unknown'}`;
  const n = Number((await env.KV.get(key)) || 0);
  if (n >= Number(env.DCR_LIMIT_PER_DAY || 10)) return json(429, { error: 'too_many_requests' }, { 'retry-after': '3600' });
  await env.KV.put(key, String(n + 1), { expirationTtl: 2 * 86400 });
  let r;
  try {
    r = await env.db.one('bnx_authn', 'select bnx.authn_register_client($1::jsonb) r', [JSON.stringify({ registration_kind: 'DCR',
      redirect_uris: bd.redirect_uris, ...(bd.client_name !== undefined ? { client_name: bd.client_name } : {}) })]);
  } catch (e) {
    if (e.code !== 'P0422') throw e;
    const c = errCode(e);
    return bad(c === 'INVALID_REDIRECT_URI' ? 'invalid_redirect_uri' : 'invalid_client_metadata', c);
  }
  return json(201, { client_id: r.client_id, client_id_issued_at: Math.floor(Date.now() / 1000), client_name: bd.client_name || r.host_profile,
    redirect_uris: bd.redirect_uris, grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'], token_endpoint_auth_method: 'none' });
}

export async function revoke(req, env) {
  const f = new URLSearchParams(await req.text());
  // RV-AIH-06: a public client identifies itself with client_id (RFC 7009 §2.1); without it nothing could be revoked
  if (!f.get('token') || !f.get('client_id')) return json(400, { error: 'invalid_request' });
  await env.db.one('bnx_authn', 'select bnx.authn_oauth_revoke($1::jsonb) r', [JSON.stringify({ token: f.get('token'), client_id: f.get('client_id') })]);
  return json(200, {});                                       // RFC 7009 §2.2: unknown tokens are not an error
}
