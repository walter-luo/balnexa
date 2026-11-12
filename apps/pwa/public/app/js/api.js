// Gateway client of the PWA (UA V1.2 §8, §12). Same origin only: the session cookie is HttpOnly/SameSite=Strict and the
// Gateway checks Origin on every cookie-authenticated command. No other host is ever contacted (CSP connect-src 'self').
export class ApiError extends Error {
  constructor(status, code, field) { super(code); this.status = status; this.code = code; this.field = field; }
}

async function send(path, { method = 'POST', body, headers = {} } = {}) {
  let r;
  try {
    r = await fetch(path, { method, credentials: 'same-origin', cache: 'no-store',
      headers: body !== undefined ? { 'content-type': 'application/json', ...headers } : headers,
      body: body !== undefined ? JSON.stringify(body) : undefined });
  } catch {
    throw new ApiError(0, 'NETWORK');
  }
  let j = null;
  try { j = await r.json(); } catch { /* empty body */ }
  if (!r.ok) throw new ApiError(r.status, (j && j.error) || `HTTP_${r.status}`, j && j.field);
  return j;
}

// Idempotency keys carry no digit at all: the key is part of the audited command payload, and the database refuses any payload
// holding a Luhn-valid 9-digit run as a possible SIN (9011 guard C2). A "pwa-<uuid>" key has such a run in about 1 command in 500 (measured with the reference detector).
// 24 letters from a 32-letter alphabet = 120 random bits.
const KEY_ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEF';
export const newKey = () => `pwa-${Array.from(crypto.getRandomValues(new Uint8Array(24)), (b) => KEY_ALPHABET[b & 31]).join('')}`;
export const query = (name, body = {}) => send(`/api/v1/queries/${name}`, { body });
// one idempotency key per user intent: the caller keeps it across retries and replaces it after a success
export const command = (name, body = {}, key = newKey()) => send(`/api/v1/commands/${name}`, { body, headers: { 'idempotency-key': key } });
export const catalog = () => send('/api/v1/catalog', { method: 'GET' });
export const config = () => send('/app/config.json', { method: 'GET' });
export const signIn = (idToken) => send('/auth/google/callback', { body: { id_token: idToken } });
export const signOut = () => send('/auth/logout', { body: {} });
// AI-host consent (AIH-1): describe | deny | approve; the Gateway re-checks the client and its redirect URI every time
export const oauth = (b) => send('/oauth/authorize', { body: b });
// a catalog entry's REST name: /api/v1/commands/<name>
export const restName = (entry) => entry.rest.split('/').pop();
export const call = (entry, body, key) => (entry.kind === 'command' ? command(restName(entry), body, key) : query(restName(entry), body));
