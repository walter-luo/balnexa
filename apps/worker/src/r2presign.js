// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// AWS Signature Version 4 query-string presigning (UA V1.2 §8.1, OBJ-271; AT-EV-01): a presigned R2 PUT so evidence bytes
// never pass through the Worker (1 MB body limit; DIF-080). Cloudflare R2 speaks the S3 API with region "auto".
// Gated by O-7: the Gateway serves /api/v1/uploads only when R2_* settings are configured.
// Verified against the AWS documented example (tests/blackbox/unit.test.mjs, "Authenticating Requests: Using Query Parameters").
const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

async function sha256Hex(s) { return hex(await crypto.subtle.digest('SHA-256', enc.encode(s))); }
async function hmac(key, s) {
  const k = await crypto.subtle.importKey('raw', typeof key === 'string' ? enc.encode(key) : key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(s)));
}
// RFC 3986 unreserved characters only (S3 canonical URI and query encoding)
export const uriEncode = (s, slash = true) => [...enc.encode(s)].map((b) => {
  const c = String.fromCharCode(b);
  if (/[A-Za-z0-9\-._~]/.test(c) || (!slash && c === '/')) return c;
  return '%' + b.toString(16).toUpperCase().padStart(2, '0');
}).join('');

export async function presign({ method, host, path, region, service = 's3', accessKeyId, secretAccessKey, expires, date }) {
  const amzDate = date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');   // YYYYMMDDTHHMMSSZ
  const day = amzDate.slice(0, 8);
  const scope = `${day}/${region}/${service}/aws4_request`;
  const q = { 'X-Amz-Algorithm': 'AWS4-HMAC-SHA256', 'X-Amz-Credential': `${accessKeyId}/${scope}`, 'X-Amz-Date': amzDate,
              'X-Amz-Expires': String(expires), 'X-Amz-SignedHeaders': 'host' };
  const cq = Object.keys(q).sort().map((k) => `${uriEncode(k)}=${uriEncode(q[k])}`).join('&');
  const curi = uriEncode(path, false);
  const creq = [method, curi, cq, `host:${host}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n');
  const sts = ['AWS4-HMAC-SHA256', amzDate, scope, await sha256Hex(creq)].join('\n');
  let k = await hmac(`AWS4${secretAccessKey}`, day);
  for (const part of [region, service, 'aws4_request']) k = await hmac(k, part);
  const sig = hex(await hmac(k, sts));
  return { url: `https://${host}${curi}?${cq}&X-Amz-Signature=${sig}`, signature: sig, amzDate };
}

// R2 PUT for one object key of the configured bucket; 15-minute validity
export function presignR2Put(env, key, date = new Date(), expires = 900) {
  return presign({ method: 'PUT', host: `${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`, path: `/${env.R2_BUCKET}/${key}`, region: 'auto',
                   accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY, expires, date });
}
