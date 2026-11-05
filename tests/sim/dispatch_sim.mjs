// AUD-046 deterministic adversarial simulation of the Cron/KV/Neon wake-up protocol.
// Uses the production decision functions from apps/worker/src/dispatch.js (shouldReadNeon/isBackstopTick) with a
// simulated eventually-consistent KV (per-POP stale reads up to 60 s, lost writes, last-writer-wins overwrites) and a
// simulated Neon queue with generation counters (wrk_claim / wrk_queue_status semantics of migration 0106).
// Negative control: the Draft-04 boolean work_pending flag protocol (producer skips the write when it reads "true",
// consumer clears it after draining) under the same adversary.
// Output: max observed enqueue->completion delay vs the analytic bound, and Neon CU-hour estimates per workload.
import { isBackstopTick, BACKSTOP_HOURS, TICK_MINUTES } from '../../apps/worker/src/dispatch.js';

let seed = Number(process.env.SEED || 20261030);
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const MIN = 60_000, H = 60 * MIN, DAY = 24 * H;
const KV_LAG = 60_000;                 // documented KV propagation upper bound used by the model (Cloudflare: "up to 60 s or more")
const LEASE = 10 * MIN;

class KV {                              // last-writer-wins value with per-reader staleness
  constructor() { this.hist = []; }
  put(k, v, t) { this.hist.push({ k, v, t }); }
  get(k, t) {                          // a reader sees the latest write older than (t - random lag)
    const lag = rnd() * KV_LAG;
    let v = null;
    for (const e of this.hist) if (e.k === k && e.t <= t - lag) v = e.v;
    return v;
  }
}

function run({ protocol, days = 30, enqueueTimes, outage = [], pLostWrite = 0.2, pCrashMidDrain = 0.1 }) {
  const kv = new KV();
  const q = { gen: 0, drained: 0, items: [] };             // items: {t, done, leaseUntil}
  const delays = [];
  let neonWakes = [];
  const pending = [...enqueueTimes].sort((a, b) => a - b);
  const end = days * DAY;
  for (let t = 0; t <= end; t += TICK_MINUTES * MIN) {
    // producers that committed during the previous tick
    while (pending.length && pending[0] <= t) {
      const et = pending.shift();
      q.items.push({ t: et, done: null, leaseUntil: 0, crashes: 0 });
      q.gen++;
      if (protocol === 'r1') {
        if (rnd() >= pLostWrite) kv.put('hint', q.gen - (rnd() < 0.2 ? 1 : 0), et);   // lost or stale-lower overwrite
      } else {
        const seen = kv.get('work_pending', et);
        if (seen !== 'true' && rnd() >= pLostWrite) kv.put('work_pending', 'true', et);
      }
    }
    if (outage.some(([a, b]) => t >= a && t < b)) continue;          // Cron did not fire
    let run;
    if (protocol === 'r1') {
      const hint = Number(kv.get('hint', t) ?? 0), drained = Number(kv.get('drained', t) ?? 0);
      run = hint > drained || isBackstopTick(t);
    } else {
      run = kv.get('work_pending', t) === 'true';
    }
    if (!run) continue;
    neonWakes.push(t);
    const g = q.gen;
    const claim = q.items.filter(i => !i.done && i.leaseUntil <= t);
    const crash = rnd() < pCrashMidDrain;
    for (const it of claim) it.leaseUntil = t + LEASE;
    if (crash) { for (const it of claim) it.crashes++; continue; }    // dispatcher died after claim, before complete
    for (const it of claim) { it.done = t; delays.push({ d: t - it.t, crashes: it.crashes }); }
    const remaining = q.items.some(i => !i.done && i.leaseUntil <= t);
    if (!remaining) q.drained = g;
    if (protocol === 'r1') kv.put('drained', q.drained, t);
    else kv.put('work_pending', 'false', t);                          // Draft-04: clear after drain (the race)
  }
  const lost = q.items.filter(i => !i.done).length;
  return { delays, lost, neonWakes, items: q.items.length };
}

function cuHours(wakes, days, activeMin = 5, cu = 0.25) {          // Neon Free: suspend after 5 min idle (F-18)
  let total = 0, until = -1;
  for (const t of wakes) {
    const start = Math.max(t, until);
    const stop = t + activeMin * MIN;
    if (stop > start) total += stop - start;
    until = Math.max(until, stop);
  }
  return (total / H) * cu * (30 / days);
}

const outage = [[5 * DAY + 2 * H, 5 * DAY + 4 * H]];                 // a 2-hour Cron outage
const bound = BACKSTOP_HOURS * H + TICK_MINUTES * MIN + 2 * H + LEASE + KV_LAG;
const out = { seed, model: { KV_LAG_s: KV_LAG / 1000, TICK_MINUTES, BACKSTOP_HOURS, LEASE_min: LEASE / MIN, outage_h: 2 } };
const bursts = (n, days) => Array.from({ length: n }, () => Math.floor(rnd() * days * DAY));

// per item: delay <= bound + crashes x BACKSTOP (each dispatcher crash that claimed the item can cost one more period)
let worstNoCrash = 0, worstAny = 0, maxCrashes = 0, lostR1 = 0, lostD04 = 0, violations = 0, runs = 0, n = 0;
for (let r = 0; r < 200; r++) {
  const times = bursts(60, 30);
  const a = run({ protocol: 'r1', enqueueTimes: times, outage });
  const b = run({ protocol: 'draft04', enqueueTimes: times, outage });
  for (const x of a.delays) {
    n++;
    if (x.d > bound + x.crashes * BACKSTOP_HOURS * H) violations++;
    if (x.crashes === 0) worstNoCrash = Math.max(worstNoCrash, x.d);
    worstAny = Math.max(worstAny, x.d); maxCrashes = Math.max(maxCrashes, x.crashes);
  }
  lostR1 += a.lost; lostD04 += b.lost; runs++;
}
out.adversarial = { runs, items: n, p_lost_or_stale_hint: 0.2 + 0.8 * 0.2, p_dispatcher_crash_after_claim: 0.1,
  r1_lost_items: lostR1, r1_bound_violations: violations, r1_worst_delay_min_no_crash: +(worstNoCrash / MIN).toFixed(1),
  analytic_bound_min: bound / MIN, r1_worst_delay_min_any: +(worstAny / MIN).toFixed(1), r1_max_consecutive_crashes: maxCrashes,
  bound_formula: 'delay <= BACKSTOP + TICK + outage + LEASE + KV_LAG + crashes*BACKSTOP', draft04_lost_items: lostD04 };

const work = {
  idle: [],
  normal: bursts(4 * 30, 30),                                       // ~4 enqueues/day (plans, outbox, maintenance)
  onboarding: bursts(40 * 30, 30),                                  // onboarding month
};
out.cu_hours_per_month = {};
for (const [k, times] of Object.entries(work)) {
  const a = run({ protocol: 'r1', enqueueTimes: times, pLostWrite: 0, pCrashMidDrain: 0 });
  out.cu_hours_per_month[k] = { dispatcher_wakes: a.neonWakes.length, cu_hours: +cuHours(a.neonWakes, 30).toFixed(2) };
}
out.cu_hours_per_month.note = 'dispatcher-only (backstop + hinted ticks); member traffic is additional and modelled in the Cost Model §6.4';
const pass = lostR1 === 0 && violations === 0 && worstNoCrash <= bound && lostD04 > 0;
out.result = pass ? 'PASS' : 'FAIL';
console.log(JSON.stringify(out, null, 1));
process.exit(pass ? 0 : 1);
