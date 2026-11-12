// Cron dispatcher (AUD-046). Neon is the queue authority; KV carries hints only and is never "cleared".
//   KV bnx:hint     = latest queue generation reported by a producer after its COMMIT (last-writer-wins, may be stale)
//   KV bnx:drained  = drained_generation last reported by Neon to a dispatcher
// A tick reads Neon iff hint > drained, or the tick is a backstop tick (unconditional rescan every BACKSTOP_HOURS).
// A lost, stale or overwritten hint therefore delays work by at most one backstop period plus one tick plus the Cron
// outage, and never forever. The bound is checked by tests/sim/dispatch_sim.mjs and the live counter by M0-D.
export const TICK_MINUTES = 5;
export const BACKSTOP_HOURS = 3;
export const MAX_CHUNKS_PER_ITEM = 4;              // bounded per item and tick (Workers CPU budget; M0-A)

export function isBackstopTick(nowMs) {
  const d = new Date(nowMs);
  return d.getUTCHours() % BACKSTOP_HOURS === 0 && d.getUTCMinutes() < TICK_MINUTES;
}

export async function shouldReadNeon(kv, nowMs) {
  const hint = Number((await kv.get('bnx:hint')) ?? 0);
  const drained = Number((await kv.get('bnx:drained')) ?? 0);
  return { run: hint > drained || isBackstopTick(nowMs), hint, drained, backstop: isBackstopTick(nowMs) };
}

// CORE-7 (UA §9.1, S4B-F13; OBJ-259 MODIFY): known kinds are dispatched by this table; an unknown kind is never completed
// (R1 completed it as a no-op, so a Worker rollback lost work): it is deferred by bnx.wrk_defer_item (back-off; Owner
// alert after 3 attempts) and processed once a release that knows it is deployed (AT-Q-02).
export const DEFER = Symbol('defer');
export const KINDS = {
  'staging.promote': promoteStaged,
  'plan.execute': executePlan,
};
export const isKnownKind = (kind) => Object.prototype.hasOwnProperty.call(KINDS, kind);

export async function handleItem(db, it) {
  if (!isKnownKind(it.kind)) return DEFER;
  return KINDS[it.kind](db, it);
}

async function promoteStaged(db, it) {                   // S4 9010: Executor results staged through the lease API
  const st = await db.one('bnx_worker', 'select bnx.wrk_promote_staged($1::uuid) r', [it.payload.staging_id]);
  return ['promoted', 'rejected', 'blocked', 'awaiting_promoter', 'not_found'].includes(st);
}

async function executePlan(db, it) {
  const plan = it.payload.plan_id;
  let st = await db.one('bnx_worker', 'select bnx.wrk_post_plan_chunk($1::uuid) r', [plan]);
  // S4 9008: a plan larger than one chunk returns 'executing'; continue within this tick up to MAX_CHUNKS_PER_ITEM, then the
  // item is re-queued (not completed) and the next tick continues; activation stays all-or-nothing.
  for (let n = 1; st === 'executing' && n < MAX_CHUNKS_PER_ITEM; n++) {
    st = await db.one('bnx_worker', 'select bnx.wrk_post_plan_chunk($1::uuid) r', [plan]);
  }
  if (st === 'sealed') st = await db.one('bnx_worker', 'select bnx.wrk_activate_plan($1::uuid) r', [plan]);
  if (st === 'revalidation_required') st = await db.one('bnx_worker', 'select bnx.wrk_revalidate_plan($1::uuid) r', [plan]);
  return ['activated', 'stale', 'suspended', 'void', 'not_found'].includes(st);
}

export async function dispatch(env, nowMs = Date.now()) {
  const decision = await shouldReadNeon(env.KV, nowMs);
  if (!decision.run) return { ...decision, neon: false, processed: 0 };
  let processed = 0, deferred = 0;
  for (let round = 0; round < 4; round++) {               // bounded per tick (Workers CPU budget; M0-A)
    const claim = await env.db.one('bnx_worker', 'select bnx.wrk_claim(10) r', []);
    if (!claim.items.length) break;
    for (const it of claim.items) {
      let ok = false;
      try { ok = await handleItem(env.db, it); } catch { ok = false; }
      if (ok === DEFER) {
        await env.db.one('bnx_worker', 'select bnx.wrk_defer_item($1::bigint) r', [it.id]);
        deferred++;
        continue;
      }
      await env.db.one('bnx_worker', 'select bnx.wrk_complete($1::bigint, $2::boolean) r', [it.id, ok]);
      processed++;
    }
  }
  const st = await env.db.one('bnx_worker', 'select bnx.wrk_queue_status() r', []);
  await env.KV.put('bnx:drained', String(st.drained_generation));
  return { ...decision, neon: true, processed, deferred, status: st };
}
