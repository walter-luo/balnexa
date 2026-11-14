// Production entry of the Gateway on Cloudflare Workers (M0-A; UA V1.2 §3, §8). The routes live in index.js, which the
// local node adapter also runs; this entry adds only what the platform provides:
//   * env.db — one Neon serverless HTTP client per database login role, from the secrets DB_URL_BNX_APP, DB_URL_BNX_AUTHN and
//     DB_URL_BNX_WORKER (UA §6.1: the Gateway holds exactly these three roles; it never holds the migrator or the installer);
//   * the same wrapped env object for every request of an isolate, so caches keyed by env (JWKS resolver, catalog) survive.
// Passwords never appear in wrangler.toml or the repository: `wrangler secret put` (docs/s4/M0A_Deployment_Runbook.md).
import { neon } from '@neondatabase/serverless';
import worker from './index.js';

const ROLES = { bnx_app: 'DB_URL_BNX_APP', bnx_authn: 'DB_URL_BNX_AUTHN', bnx_worker: 'DB_URL_BNX_WORKER' };

export function makeNeonDb(env, connect = neon) {
  const clients = {};
  const client = (role) => {
    if (!ROLES[role]) throw Object.assign(new Error(`ROLE_NOT_HELD ${role}`), { code: 'XX000' });
    if (!clients[role]) {
      const url = env[ROLES[role]];
      if (!url) throw Object.assign(new Error(`DB_URL_MISSING ${role}`), { code: 'XX000' });
      clients[role] = connect(url);
    }
    return clients[role];
  };
  return {
    async one(role, sql, params = []) {
      const rows = await client(role).query(sql, params);
      return rows[0] ? rows[0].r : null;
    },
  };
}

const WRAPPED = new WeakMap();
export function platformEnv(env, connect) {
  if (!WRAPPED.has(env)) WRAPPED.set(env, { ...env, db: makeNeonDb(env, connect) });
  return WRAPPED.get(env);
}

export default {
  fetch: (req, env, ctx) => worker.fetch(req, platformEnv(env), ctx),
  scheduled: (event, env, ctx) => worker.scheduled(event, platformEnv(env), ctx),
};
