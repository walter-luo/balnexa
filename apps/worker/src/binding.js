// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Binding checks B1/B2/B3/B8 (Amendment 03 §5.2; AE V1.2 §6) and the bnx-tools/1.0 catalog cache (CORE-7).
// Run on the first request of an isolate and again at most every 10 minutes (isolate memory, never KV). A failure answers
// every route except GET /api/v1/health with 503 (fail closed, ISO-4) and is re-checked after 60 s so a corrected deploy
// recovers quickly. B7 (audience) is enforced per call by bnx.resolve_actor (9017) with the audience the Gateway sends.
import { RELEASE } from './release.js';
import { checkSchema } from './schema.js';

const OK_TTL = 10 * 60 * 1000, FAIL_TTL = 60 * 1000;
const STATE = new WeakMap();                         // env -> {at, ttl, result, catalog}

function modulesOf(env) {
  const m = env.BNX_MODULES;
  if (!m) return null;
  try { return typeof m === 'string' ? JSON.parse(m) : m; } catch { return null; }
}

function sameFlags(a, b) {
  if (!a || !b) return false;
  const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
  return ka.length === kb.length && ka.every((k, i) => k === kb[i] && String(a[k]) === String(b[k]));
}

const within = (v, [lo, hi]) => typeof v === 'string' && v >= lo && v <= hi;

// pure evaluation (exported for unit tests)
export function evaluate(env, facts, release = RELEASE) {
  const failed = [];
  const id = facts && facts.identity;
  if (!env.BNX_PROJECT_ID || !env.BNX_INSTANCE_UID || !id || id.project_id !== env.BNX_PROJECT_ID || id.instance_uid !== env.BNX_INSTANCE_UID) failed.push('B1');
  if (!env.BNX_CONFIG_DIGEST || !(facts && (facts.deployable_sha256 || []).includes(env.BNX_CONFIG_DIGEST))) failed.push('B2');
  const sh = (facts && facts.schema_head) || {};
  if (!within(sh.core, release.supports_schema.core) || !within(sh.extension, release.supports_schema.extension)) failed.push('B3');
  if (!sameFlags(modulesOf(env), facts && facts.active && facts.active.flags)) failed.push('B8');
  const error = failed.some((f) => f !== 'B8') ? 'BNX_BINDING_MISMATCH' : failed.length ? 'BNX_FLAG_BINDING_MISMATCH' : null;
  return { ok: failed.length === 0, failed, error };
}

function loadCatalog(c) {
  const byRest = new Map();
  for (const e of c.entries || []) {
    if (!/^[a-z_]+\.(cmd|q)_[a-z_0-9]+$/.test(e.core_function || '')) continue;    // never trust a malformed comment
    checkSchema(e.input_schema);
    if (e.output_schema !== undefined) checkSchema(e.output_schema);                  // 2.8 part 3: enforced on every MCP result
    byRest.set(e.rest, e);
  }
  return { sha256: c.catalog_sha256, format: c.format, entries: c.entries || [], byRest, uncatalogued: c.uncatalogued || [] };
}

// returns {ok, failed, error, catalog}; never throws for a database error (fails closed with B1)
export async function bindings(env, now = Date.now()) {
  const s = STATE.get(env);
  if (s && now - s.at < s.ttl) return s.result;
  let result;
  try {
    const facts = await env.db.one('bnx_worker', 'select bnx.wrk_binding_facts() r', []);
    result = evaluate(env, facts);
    let catalog = s && s.catalog;
    if (!catalog || catalog.sha256 !== facts.catalog_sha256) catalog = loadCatalog(await env.db.one('bnx_worker', 'select bnx.wrk_catalog() r', []));
    result.catalog = catalog;
    result.schema_head = facts.schema_head;
  } catch (e) {
    result = { ok: false, failed: ['B1'], error: 'BNX_BINDING_MISMATCH', unreachable: String((e && e.code) || 'ERROR') };
  }
  STATE.set(env, { at: now, ttl: result.ok ? OK_TTL : FAIL_TTL, result, catalog: result.catalog });
  return result;
}

export function resetBindings(env) { STATE.delete(env); }
