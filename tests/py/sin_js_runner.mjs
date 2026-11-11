// Runs the Worker detector over cases read from stdin (JSON array of {id, kind, origin, input}); prints {id: hits}.
// Used by tests/py/run_s4_core5.py (AT-SIN-11 parity). Values come from the generated corpus and are never printed.
import { scan, scanJson } from '../../apps/worker/src/sin_detector.js';

let buf = '';
process.stdin.on('data', (d) => { buf += d; });
process.stdin.on('end', () => {
  const out = {};
  for (const c of JSON.parse(buf)) {
    try {
      out[c.id] = c.kind === 'json' ? scanJson(c.input, c.origin) : scan(c.input, c.origin);
    } catch (e) {
      out[c.id] = { error: e.message };
    }
  }
  process.stdout.write(JSON.stringify(out));
});
