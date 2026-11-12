// The one MCP App resource of the MCP server (AIH-4; UA V1.2 §12.3; AIH V1.2 §8): ui://balnexa/cards/v1. A display-only card
// that renders a draft (Draft Confirm) or a status from the tool result the host hands to it. Confirm opens the sealed PWA
// link (#/confirm/<plan>?h=<plan_hash>&s=<scope_digest>, CORE-9 Mode H); the card never calls a tool, never fetches anything
// (CSP connect-src 'none'; connectDomains []) and writes data only as text, so document or description text cannot become
// markup (AT-PRIV-05). In-card approval is off (OD-40); in-card editing is not offered (D-AIH4-3).
// Host protocols: MCP Apps (postMessage JSON-RPC: ui/initialize, ui/notifications/tool-result, ui/open-link) and, where the
// host provides it, the ChatGPT Apps SDK globals (window.openai.toolOutput, openExternal). Neither has been qualified on a
// real host yet (PV-UI-01…03 NOT_EXECUTED).
export const CARD_URI = 'ui://balnexa/cards/v1';
export const CARD_MIME = 'text/html;profile=mcp-app';

const SCRIPT = String.raw`
(() => {
  const INSTANCE = JSON.parse(document.getElementById('bnx-instance').textContent);
  const L = {
    en: { draft: 'Draft — not posted', status: 'Balnexa', kind: 'Kind', state: 'State', items: 'Items', held: 'On hold', confirm: 'Review and approve in Balnexa',
      open: 'Open in Balnexa', rule: 'Nothing is posted until you approve this exact version in the Balnexa app.', none: 'No result to show.', error: 'Refused',
      instance: 'Instance' },
    zh: { draft: '草稿——尚未记账', status: 'Balnexa', kind: '类型', state: '状态', items: '明细', held: '暂缓', confirm: '在 Balnexa 中审核并批准',
      open: '在 Balnexa 中打开', rule: '在你于 Balnexa 应用中批准这一确切版本之前，不会记账。', none: '没有可显示的结果。', error: '已拒绝',
      instance: '实例' },
  };
  let lang = (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh' : 'en';
  const t = (k) => L[lang][k] || L.en[k];
  const root = document.getElementById('card');
  const el = (tag, attrs, ...kids) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) { if (v === null || v === undefined) continue; if (k === 'class') e.className = v; else e.setAttribute(k, String(v)); }
    for (const c of kids.flat()) if (c !== null && c !== undefined && c !== false) e.append(c instanceof Node ? c : document.createTextNode(String(c)));
    return e;
  };
  let seq = 0; const pending = new Map();
  const post = (m) => { if (window.parent && window.parent !== window) window.parent.postMessage(m, '*'); };
  const request = (method, params) => new Promise((ok, no) => {
    const id = ++seq; pending.set(id, { ok, no }); post({ jsonrpc: '2.0', id, method, params });
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); no(new Error('timeout')); } }, 5000);
  });
  const sealed = (sc) => INSTANCE + '/app/#/confirm/' + encodeURIComponent(sc.plan_id) + '?h=' + encodeURIComponent(sc.plan_hash) + '&s=' + encodeURIComponent(sc.scope_digest);
  async function open(url) {
    try { if (window.openai && typeof window.openai.openExternal === 'function') { window.openai.openExternal({ href: url }); return; } } catch (e) { /* next */ }
    try { await request('ui/open-link', { url }); } catch (e) { const a = document.getElementById('bnx-link'); if (a) a.focus(); }
  }
  function lines(it) { return (it.lines || []).map((l) => (l.amount || '') + ' ' + (l.currency || '')).join(' / '); }
  function render(sc) {
    root.replaceChildren();
    if (!sc || typeof sc !== 'object') { root.append(el('p', {}, t('none'))); return; }
    if (sc.error) { root.append(el('h1', {}, t('error')), el('p', { class: 'code' }, String(sc.error))); return; }
    if (sc.plan_id && sc.plan_hash && sc.scope_digest) {
      const url = sealed(sc);
      const dl = el('dl', {}, el('dt', {}, t('kind')), el('dd', {}, sc.kind || ''), el('dt', {}, t('state')), el('dd', {}, sc.state || ''));
      const items = (sc.items || []).map((it) => el('li', {}, [(it.payload && it.payload.transaction_date) || '', (it.payload && it.payload.description) || '',
        it.economic_type || '', lines(it)].filter(Boolean).join(' · ')));
      root.append(el('h1', {}, t('draft')), dl,
        ...(items.length ? [el('h2', {}, t('items')), el('ul', {}, items)] : []),
        (sc.hold_reasons || []).length ? el('p', { class: 'held' }, t('held') + ': ' + sc.hold_reasons.join(', ')) : '',
        el('p', {}, t('rule')));
      const btn = el('button', { type: 'button', id: 'bnx-confirm' }, t('confirm'));
      btn.addEventListener('click', () => open(url));
      root.append(btn, el('p', {}, el('a', { id: 'bnx-link', href: url, target: '_blank', rel: 'noopener noreferrer' }, t('open'))),
        el('p', { class: 'meta' }, t('instance') + ': ' + INSTANCE.replace(/^https?:\/\//, '')));
      post({ jsonrpc: '2.0', method: 'ui/notifications/size-changed', params: { height: document.documentElement.scrollHeight } });
      return;
    }
    root.append(el('h1', {}, t('status')), el('p', {}, String(sc.state || sc.status || '')));
  }
  window.addEventListener('message', (ev) => {
    // only the host frame that embeds the card speaks to it (RV-AIH-04): a sibling frame cannot replace the draft shown
    if (ev.source !== window.parent || window.parent === window) return;
    const m = ev.data;
    if (!m || m.jsonrpc !== '2.0') return;
    if (m.id !== undefined && !m.method && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); if (m.error) p.no(m.error); else p.ok(m.result); return; }
    if (m.method === 'ui/notifications/tool-result') { const r = m.params || {}; render(r.structuredContent !== undefined ? r.structuredContent : (r.result || {}).structuredContent); }
    if (m.method === 'ui/notifications/host-context-changed' && m.params && m.params.locale) lang = String(m.params.locale).toLowerCase().startsWith('zh') ? 'zh' : 'en';
  });
  request('ui/initialize', { protocolVersion: '2025-11-21', appInfo: { name: 'balnexa-card', version: '1' }, appCapabilities: {} })
    .then((r) => {
      const loc = r && r.hostContext && r.hostContext.locale;
      if (loc) lang = String(loc).toLowerCase().startsWith('zh') ? 'zh' : 'en';
      post({ jsonrpc: '2.0', method: 'ui/notifications/initialized' });
    }).catch(() => {});
  if (window.openai && window.openai.toolOutput) render(window.openai.toolOutput);
  window.addEventListener('openai:set_globals', () => { if (window.openai && window.openai.toolOutput) render(window.openai.toolOutput); });
})();
`;

const STYLE = `
:root { color-scheme: light dark; --fg: #14181f; --muted: #555d6b; --line: #d5d9e0; --accent: #1f4e79; --bg: #ffffff; }
@media (prefers-color-scheme: dark) { :root { --fg: #e8ebf0; --muted: #aab2bf; --line: #333b47; --accent: #8cbcf0; --bg: #11151b; } }
body { margin: 0; font: 15px/1.45 system-ui, sans-serif; color: var(--fg); background: var(--bg); }
main { padding: 12px 14px; border: 1px solid var(--line); border-radius: 10px; }
h1 { font-size: 16px; margin: 0 0 8px; } h2 { font-size: 14px; margin: 10px 0 4px; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 10px; margin: 0; } dt { color: var(--muted); }
ul { margin: 0; padding-left: 18px; } .held { color: #a33; } .meta { color: var(--muted); font-size: 13px; } .code { font-family: ui-monospace, monospace; }
button { margin-top: 8px; min-height: 40px; padding: 6px 14px; border-radius: 8px; border: 0; background: var(--accent); color: var(--bg); font: inherit; cursor: pointer; }
a { color: var(--accent); }
`;

// the instance URL is the only value injected; it is JSON in a non-executable script element (no </script> possible)
export function cardHtml(instance) {
  const inst = JSON.stringify(String(instance)).replace(/</g, '\\u003c');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'">
<title>Balnexa</title><style>${STYLE}</style></head><body><main id="card" aria-live="polite"></main>
<script type="application/json" id="bnx-instance">${inst}</script><script>${SCRIPT}</script></body></html>`;
}

// resource _meta (MCP Apps): no network origin at all; the host draws a border
export const CARD_META = { ui: { csp: { connectDomains: [], resourceDomains: [] }, prefersBorder: true } };
