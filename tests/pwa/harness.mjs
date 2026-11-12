// Shared set-up of the headless PWA suite: a fresh database (tests/blackbox/prepare_db.py), the real Worker module on a
// local HTTP server (node adapter) serving apps/pwa/public as its ASSETS binding, synthetic Google-style ID tokens, and
// sessions for the Owner, a member without can_post and a viewer. No helper touches the database directly.
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeDb, makeKv, makeAssets, serve, worker } from '../../apps/worker/node/adapter.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.join(here, '..', '..');
const b64u = (b) => Buffer.from(b).toString('base64url');

export async function start({ server = process.env.BNX_SERVER || 'pg16', py = process.env.BNX_PY || 'python3' } = {}) {
  const info = JSON.parse(execFileSync(py, [path.join(ROOT, 'tests', 'blackbox', 'prepare_db.py'), server]).toString());
  const kp = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = kp.publicKey.export({ format: 'jwk' });
  const env = { db: makeDb({ host: info.host, port: info.port, database: info.db }), KV: makeKv(), APP_ORIGIN: 'pending',
    GOOGLE_CLIENT_ID: 'test-client', GOOGLE_JWKS: { keys: [{ ...jwk, kid: 'k1', alg: 'RS256' }] },
    ASSETS: makeAssets(path.join(ROOT, 'apps', 'pwa', 'public')), ...(info.binding || {}) };
  const srv = await serve(env);
  const base = `http://localhost:${srv.address().port}`;
  env.APP_ORIGIN = base;                                   // the page's own origin: commands are same-origin (CSRF check)
  const idToken = (sub) => {
    const h = b64u(JSON.stringify({ alg: 'RS256', kid: 'k1', typ: 'JWT' }));
    const now = Math.floor(Date.now() / 1000);
    const p = b64u(JSON.stringify({ iss: 'https://accounts.google.com', aud: 'test-client', sub, iat: now, exp: now + 600, email_verified: true }));
    return `${h}.${p}.${b64u(crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), kp.privateKey))}`;
  };
  async function call(p, { body, cookie, method = 'POST', key } = {}) {
    const headers = { origin: base };
    if (body !== undefined) headers['content-type'] = 'application/json';
    if (cookie) headers.cookie = `bnx_session=${cookie}`;
    if (key) headers['idempotency-key'] = key;
    const r = await fetch(base + p, { method, headers, redirect: 'manual', body: body !== undefined ? JSON.stringify(body) : undefined });
    const text = await r.text();
    let json = null; try { json = JSON.parse(text); } catch { /* not JSON */ }
    return { status: r.status, json, text, headers: r.headers };
  }
  async function login(sub) {
    const r = await call('/auth/google/callback', { body: { id_token: idToken(sub) } });
    if (r.status !== 200) throw new Error(`login ${sub}: ${r.status} ${r.text}`);
    return decodeURIComponent(/bnx_session=([^;]+)/.exec(r.headers.get('set-cookie'))[1]);
  }
  const letters = () => Array.from(crypto.randomBytes(24), (b) => 'abcdefghijklmnopqrstuvwxyzABCDEF'[b & 31]).join('');
  const cmd = async (cookie, name, body) => {
    const r = await call(`/api/v1/commands/${name}`, { body, cookie, key: `pwa-test-${letters()}` });   // no digits: see api.js newKey
    if (r.status !== 200) throw new Error(`${name}: ${r.status} ${r.text}`);
    return r.json;
  };
  const q = async (cookie, name, body = {}) => {
    const r = await call(`/api/v1/queries/${name}`, { body, cookie });
    if (r.status !== 200) throw new Error(`${name}: ${r.status} ${r.text}`);
    return r.json;
  };
  const tick = () => worker.scheduled({ scheduledTime: Date.now() }, env, null);
  const stop = async () => { srv.close(); await env.db.end(); };
  return { info, env, base, call, login, cmd, q, tick, stop };
}

// a browser context whose every request is recorded; anything that is not this origin is aborted and recorded as a
// violation, and so is any AI route of this origin (/mcp, /oauth/*) - AT-NOAI-00 "no hidden LLM call".
// policy (AIH-1 consent tests only, never counted in AT-NOAI-00): aiPaths = AI routes of this origin let through (the consent
// screen's /oauth/authorize); capture = origins whose requests are still aborted but recorded in log.captured (the AI host's
// redirect URI the browser is sent back to)
export async function context(browser, base, cookie, opts = {}, policy = {}) {
  const ctx = await browser.newContext({ locale: 'en-CA', timezoneId: 'America/Toronto', serviceWorkers: 'block', ...opts });
  const log = { requests: [], external: [], ai: [], captured: [] };
  const aiPaths = policy.aiPaths || [], capture = policy.capture || [];
  await ctx.route('**/*', (route) => {
    const u = new URL(route.request().url());
    log.requests.push(`${route.request().method()} ${u.pathname}`);
    if (u.origin !== base && capture.includes(u.origin)) { log.captured.push(u.href); return route.abort('blockedbyclient'); }
    if (u.origin !== base) { log.external.push(u.href); return route.abort('blockedbyclient'); }
    if (aiPaths.includes(u.pathname)) return route.continue();
    if (u.pathname === '/mcp' || u.pathname.startsWith('/oauth')) { log.ai.push(u.pathname); return route.abort('blockedbyclient'); }
    return route.continue();
  });
  if (cookie) {
    const { hostname, port } = new URL(base);
    await ctx.addCookies([{ name: 'bnx_session', value: cookie, domain: hostname, path: '/', httpOnly: true, secure: true, sameSite: 'Strict' }]);
    void port;
  }
  ctx.log = log;
  return ctx;
}
