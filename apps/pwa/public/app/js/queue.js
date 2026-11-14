// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Offline draft queue (CORE-9 phase 2.5; Owner decision 2026-11-12: "同意你的建议" — only drafts are queued offline).
// When the network is gone at the moment a Quick Entry draft (draft_create_transaction / draft_create_transfer) is sent, the
// request is kept in IndexedDB with its idempotency key and sent again when the browser is back online. Nothing is posted
// offline: a queued item becomes a draft that the Owner still approves. Postings and every other command are never queued.
// The queue holds the draft's fields on this device only; it is emptied on sign-out, and the app shows only a count, never a
// figure from it (AT-UI-02). A replay that the server refuses is dropped and reported; the same key makes a replay safe.
const DB = 'bnx-queue', STORE = 'drafts';
export const QUEUEABLE = new Set(['draft_create_transaction', 'draft_create_transfer']);

function open() {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'key' });
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

async function tx(mode, fn) {
  const db = await open();
  try {
    return await new Promise((resolve, reject) => {
      const t = db.transaction(STORE, mode);
      const out = fn(t.objectStore(STORE));
      t.oncomplete = () => resolve(out && 'result' in out ? out.result : undefined);
      t.onerror = () => reject(t.error);
    });
  } finally { db.close(); }
}

export async function enqueue(name, body, key) {
  if (!QUEUEABLE.has(name)) throw new Error('not queueable');
  await tx('readwrite', (s) => s.put({ key, name, body, queued_at: new Date().toISOString() }));
}

export async function list() {
  try { return (await tx('readonly', (s) => s.getAll())) || []; } catch { return []; }
}

export async function count() { return (await list()).length; }

export async function clear() {
  try { await tx('readwrite', (s) => s.clear()); } catch { /* storage may be unavailable */ }
}

async function remove(key) { await tx('readwrite', (s) => s.delete(key)); }

// send every queued draft once; -> { sent: [plan ids], refused: [codes], left: n }
export async function replay(command) {
  const out = { sent: [], refused: [], left: 0 };
  for (const it of await list()) {
    try {
      const r = await command(it.name, it.body, it.key);
      out.sent.push(r && r.plan_id);
      await remove(it.key);
    } catch (e) {
      if (e && e.code === 'NETWORK') { out.left += 1; continue; }     // still offline: keep it
      out.refused.push((e && e.code) || 'ERROR');
      await remove(it.key);                                           // the server decided; a retry cannot change that
    }
  }
  return out;
}
