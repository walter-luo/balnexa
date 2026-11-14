// Guards C4 (MCP and, since RV-AIH-02, the Business API for AI bearers) and C3 against the real Worker module with a mocked database (no network, no real data).
// stdin: {"values": [...], "clean": "..."}; the mock q_balances returns a label containing values[i]. Prints a JSON summary
// without any value. Used by tests/py/run_s4_core5.py (AT-SIN-C4).
import worker from '../../apps/worker/src/index.js';
import { scrub, MASK } from '../../apps/worker/src/sin_detector.js';

let buf = '';
process.stdin.on('data', (d) => { buf += d; });
process.stdin.on('end', async () => {
  const input = JSON.parse(buf);
  const out = { cases: [] };
  for (const label of [...input.values, input.clean]) {
    const audits = [];
    // CORE-7 re-baseline: the Gateway checks its bindings (B1/B2/B3/B8) before any route, so the mock database answers
    // the binding facts and an empty catalog consistently with the env, as a correctly deployed Worker would see them
    const env = {
      APP_ORIGIN: 'https://app.balnexa.test',
      BNX_PROJECT_ID: 'guard-household', BNX_INSTANCE_UID: '00000000-0000-4000-8000-0000000000c4', BNX_CONFIG_DIGEST: 'c'.repeat(64),
      BNX_MODULES: { Canada: 'YES', International: 'YES', CRA: 'YES' },
      db: {
        one: async (role, sql, params) => {
          if (sql.includes('wrk_binding_facts')) return { identity: { project_id: 'guard-household', instance_uid: '00000000-0000-4000-8000-0000000000c4' },
            deployable_sha256: ['c'.repeat(64)], schema_head: { core: '0109', extension: '9028' },
            active: { flags: { Canada: 'YES', International: 'YES', CRA: 'YES' } }, catalog_sha256: 'none' };
          // AIH-2 re-baseline: the MCP server is generated from the catalog, so the mock catalog carries the one tool used here
          if (sql.includes('wrk_catalog')) return { format: 'bnx-tools/1.0', catalog_sha256: 'none', uncatalogued: [], entries: [{
            name: 'fin.balances.as_of', core_function: 'bnx.q_balances', rest: '/api/v1/queries/balances', kind: 'query', version: '1.0.0',
            channels: ['pwa', 'mcp'], risk_class: 'RC-READ', scopes: ['finance.read'], legacy: { read: true, propose: false },
            mcp: { readOnlyHint: true, destructiveHint: false }, description: 'Balances', input_schema: { type: 'object', properties: {} },
            output_schema: { type: 'object' } }] };
          if (sql.includes('q_whoami')) return { member_id: 'm', channel: 'mcp', scopes: ['finance.read'] };
          if (sql.includes('wrk_audit_sin_refusal')) { audits.push({ role, payload: JSON.parse(params[0]) }); return 1; }
          if (sql.includes('q_balances')) return { balances: [{ label: `Chequing ${label}`, amount: '10.00' }] };
          throw Object.assign(new Error('UNEXPECTED'), { code: 'XX000' });
        },
      },
      KV: { get: async () => null, put: async () => {} },
    };
    const req = new Request('https://app.balnexa.test/mcp', {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer synthetic-token' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'fin_balances_as_of', arguments: {} } }),
    });
    const res = await worker.fetch(req, env, {});
    const text = await res.text();
    const leaked = [...input.values].some((v) => text.replace(/[^0-9]/g, '').includes(v));
    const j = JSON.parse(text);
    // RV-AIH-02: the same guard on the Business API for an AI bearer
    const rres = await worker.fetch(new Request('https://app.balnexa.test/api/v1/queries/balances', { method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer synthetic-token' }, body: '{}' }), env, {});
    const rtext = await rres.text();
    out.cases.push({ refused: !!(j.result && j.result.isError && j.result.content[0].text === 'SIN_CANDIDATE_REFUSED'),
                     rest_refused: rres.status === 422 && JSON.parse(rtext).error === 'SIN_CANDIDATE_REFUSED',
                     leaked: leaked || [...input.values].some((v) => rtext.replace(/[^0-9]/g, '').includes(v)), audits: audits.map((a) => ({ role: a.role, tool: a.payload.tool, rules: a.payload.rules,
                       has_value: [...input.values].some((v) => JSON.stringify(a.payload).includes(v)) })) });
  }
  const scrubbed = input.values.map((v) => scrub(`error near ${v} end`));
  out.scrub = { masked: scrubbed.every((s) => s.includes(MASK)), leaked: scrubbed.some((s, i) => s.includes(input.values[i])) };
  process.stdout.write(JSON.stringify(out));
});
