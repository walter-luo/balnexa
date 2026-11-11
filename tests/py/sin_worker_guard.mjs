// Guards C4 and C3 against the real Worker module with a mocked database (no network, no real data).
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
    const env = {
      APP_ORIGIN: 'https://app.balnexa.test',
      db: {
        one: async (role, sql, params) => {
          if (sql.includes('wrk_audit_sin_refusal')) { audits.push({ role, payload: JSON.parse(params[0]) }); return 1; }
          if (sql.includes('q_balances')) return { balances: [{ label: `Chequing ${label}`, amount: '10.00' }] };
          throw Object.assign(new Error('UNEXPECTED'), { code: 'XX000' });
        },
      },
      KV: { get: async () => null, put: async () => {} },
    };
    const req = new Request('https://app.balnexa.test/mcp', {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer synthetic-token' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_balances', arguments: {} } }),
    });
    const res = await worker.fetch(req, env, {});
    const text = await res.text();
    const leaked = [...input.values].some((v) => text.replace(/[^0-9]/g, '').includes(v));
    const j = JSON.parse(text);
    out.cases.push({ refused: !!(j.result && j.result.isError && j.result.content[0].text === 'SIN_CANDIDATE_REFUSED'),
                     leaked, audits: audits.map((a) => ({ role: a.role, tool: a.payload.tool, rules: a.payload.rules,
                       has_value: [...input.values].some((v) => JSON.stringify(a.payload).includes(v)) })) });
  }
  const scrubbed = input.values.map((v) => scrub(`error near ${v} end`));
  out.scrub = { masked: scrubbed.every((s) => s.includes(MASK)), leaked: scrubbed.some((s, i) => s.includes(input.values[i])) };
  process.stdout.write(JSON.stringify(out));
});
