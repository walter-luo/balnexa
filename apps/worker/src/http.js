// Small HTTP helpers shared by the Gateway modules (index.js, oauth.js, mcp.js).
export const json = (status, body, headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers } });

export async function body(req) {
  try { return await req.json(); } catch { return null; }
}

// first token of one of our own database exception messages (e.g. INVALID_REDIRECT_URI); never SQL text
export const errCode = (e) => String((e && e.message) || '').split(/[\s:]/)[0];

// letters only (the audit guard refuses Luhn-valid 9-digit runs in audited values; 9011 C2)
const LETTERS = 'abcdefghijklmnopqrstuvwxyzABCDEF';
export const letters = (n) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => LETTERS[b & 31]).join('');
export async function letterDigest(raw) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw)));
  return Array.from(d, (b) => LETTERS[b & 31]).join('');
}
