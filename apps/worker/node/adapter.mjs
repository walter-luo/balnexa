// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Node adapter for local G0 black-box tests: runs the Workers module (fetch/scheduled) behind node:http with one pg Pool
// per database login role and an in-memory KV. In Cloudflare the same module receives a Neon serverless driver and a
// KV namespace binding (M0-A/M0-C pending; not executed here).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import pg from 'pg';
import worker from '../src/index.js';

export function makeDb({ host, port, database }) {
  const pools = {};
  const pool = (role) => (pools[role] ||= new pg.Pool({ host, port, database, user: role, max: 4 }));
  return {
    async one(role, sql, params) {
      const r = await pool(role).query(sql, params);
      return r.rows[0] ? r.rows[0].r : null;
    },
    async end() { await Promise.all(Object.values(pools).map(p => p.end())); },
  };
}

export function makeKv() {
  const m = new Map();
  return { async get(k) { return m.has(k) ? m.get(k) : null; }, async put(k, v) { m.set(k, String(v)); }, _m: m };
}

// R2 bucket binding over a directory tree written by the Executor's LocalStore (bnx_exec/store.py): get(key) -> body | null
export function makeR2(root) {
  const base = path.resolve(root);
  return {
    async get(key) {
      const p = path.resolve(base, key);
      if (!p.startsWith(base + path.sep) || !fs.existsSync(p)) return null;
      const b = fs.readFileSync(p);
      return { size: b.length, async arrayBuffer() { return b.buffer.slice(b.byteOffset, b.byteOffset + b.length); } };
    },
  };
}

// Workers static-assets binding over a directory (the deployed Worker binds apps/pwa/public as ASSETS)
const TYPES = { html: 'text/html; charset=utf-8', js: 'text/javascript; charset=utf-8', css: 'text/css; charset=utf-8',
  json: 'application/json; charset=utf-8', webmanifest: 'application/manifest+json', svg: 'image/svg+xml', png: 'image/png', txt: 'text/plain' };
export function makeAssets(root) {
  const base = path.resolve(root);
  return {
    async fetch(req) {
      const u = new URL(req.url);
      const p = path.resolve(base, '.' + decodeURIComponent(u.pathname));
      if (!p.startsWith(base + path.sep) || !fs.existsSync(p) || !fs.statSync(p).isFile()) return new Response('not found', { status: 404 });
      const ext = p.split('.').pop();
      return new Response(fs.readFileSync(p), { status: 200, headers: { 'content-type': TYPES[ext] || 'application/octet-stream' } });
    },
  };
}

export function serve(env, port = 0) {
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const request = new Request(`http://localhost${req.url}`, {
      method: req.method, headers: req.headers, body: ['GET', 'HEAD'].includes(req.method) ? undefined : Buffer.concat(chunks) });
    const r = await worker.fetch(request, env);
    res.writeHead(r.status, Object.fromEntries(r.headers));
    res.end(Buffer.from(await r.arrayBuffer()));
  });
  return new Promise(ok => server.listen(port, '127.0.0.1', () => ok(server)));
}

export { worker };
