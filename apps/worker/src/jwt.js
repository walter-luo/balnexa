// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Google ID-token verification with WebCrypto (available in Cloudflare Workers and Node >= 20).
// Production: the key set comes from jwksResolver() (Google's JWKS endpoint, cached in isolate memory, refetched on an
// unknown kid); tests inject a synthetic JWKS or a resolver with a fake fetch. Only RS256 is accepted; alg "none" and HS*
// are rejected.
const enc = new TextEncoder();

function b64urlToBytes(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export class AuthError extends Error {}

// CORE-7 (OBJ-258 MODIFY): JWKS fetched and cached with kid rotation. A key set is either a static object (tests; the
// R1 env.GOOGLE_JWKS) or a resolver made by jwksResolver(). The resolver keeps the last set in isolate memory for the
// Cache-Control max-age (default 1 h, at most 24 h) and, on an unknown kid, refetches at most once per 60 s, so a rotated
// Google key is accepted without a redeploy and a flood of forged kids cannot hammer the endpoint.
export const GOOGLE_JWKS_URL = 'https://www.googleapis.com/oauth2/v3/certs';
export function jwksResolver({ url = GOOGLE_JWKS_URL, fetchFn = (u) => fetch(u), minRefetchMs = 60_000 } = {}) {
  let set = null, expires = 0, lastFetch = -Infinity;
  async function load(now) {
    lastFetch = now;
    const r = await fetchFn(url);
    if (!r.ok) throw new AuthError('jwks');
    const m = /max-age=(\d+)/.exec((r.headers && r.headers.get && r.headers.get('cache-control')) || '');
    set = await r.json();
    expires = now + Math.min(m ? Number(m[1]) : 3600, 86400) * 1000;
  }
  return async function keyFor(kid, now = Date.now()) {
    if (!set || now >= expires) await load(now);
    let k = (set.keys || []).find((x) => x.kid === kid && x.kty === 'RSA');
    if (!k && now - lastFetch >= minRefetchMs) { await load(now); k = (set.keys || []).find((x) => x.kid === kid && x.kty === 'RSA'); }
    return k || null;
  };
}

async function keyFor(jwks, kid, now) {
  if (typeof jwks === 'function') return jwks(kid, now);
  return ((jwks && jwks.keys) || []).find((k) => k.kid === kid && k.kty === 'RSA') || null;
}

export async function verifyGoogleIdToken(token, { jwks, audience, now = Date.now() }) {
  if (typeof token !== 'string' || token.split('.').length !== 3) throw new AuthError('malformed');
  const [h64, p64, s64] = token.split('.');
  let header, payload;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlToBytes(h64)));
    payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(p64)));
  } catch { throw new AuthError('malformed'); }
  if (header.alg !== 'RS256' || !header.kid) throw new AuthError('alg');
  const jwk = await keyFor(jwks, header.kid, now);
  if (!jwk) throw new AuthError('kid');
  const key = await crypto.subtle.importKey('jwk', { kty: 'RSA', n: jwk.n, e: jwk.e, alg: 'RS256', ext: true },
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, b64urlToBytes(s64), enc.encode(`${h64}.${p64}`));
  if (!ok) throw new AuthError('signature');
  const t = Math.floor(now / 1000);
  if (!['https://accounts.google.com', 'accounts.google.com'].includes(payload.iss)) throw new AuthError('iss');
  if (payload.aud !== audience) throw new AuthError('aud');
  if (typeof payload.exp !== 'number' || payload.exp < t - 60) throw new AuthError('exp');
  if (typeof payload.iat === 'number' && payload.iat > t + 300) throw new AuthError('iat');
  if (payload.email_verified !== true || !payload.sub) throw new AuthError('email');
  return payload;
}

// Executor lease authentication (UA §9.2; S4B-F12): a Google ID token of the job's service account, pinned to the
// configured identity: sub and email of the job service account, azp of the job's client id (AT-EXEC-01).
export async function verifyJobToken(token, { jwks, audience, pin, now = Date.now() }) {
  if (!pin || !pin.sub || !pin.email || !pin.azp) throw new AuthError('pin');
  const c = await verifyGoogleIdToken(token, { jwks, audience, now });
  if (c.sub !== pin.sub || c.email !== pin.email || c.azp !== pin.azp) throw new AuthError('pin');
  return c;
}
