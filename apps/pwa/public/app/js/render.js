// The three generic renderers of the PWA (CORE-9): a form from a catalog entry's input_schema, a table for any list of
// records (filter, sort, CSV export), and a detail view for any record. Every task in the closed menu that has no daily
// screen of its own is served by these three, so no menu entry is a dead end (OR-U-01, "smallest reusable UI").
import { t, label } from './i18n.js';

export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat()) if (c !== null && c !== undefined && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}

let seq = 0;
const uid = (p) => `${p}-${++seq}`;
const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
const scalar = (v) => v === null || ['string', 'number', 'boolean'].includes(typeof v);

// ---------------------------------------------------------------------------------------------------------------- form
// options: { ledger } = q_ledger_accounts result, used to offer account and category pickers for the matching fields
const AC_FIELDS = /(^|_)account_currency_id$/;
const LA_FIELDS = /ledger_account_id$/;

function fieldFor(name, sch, opts) {
  const id = uid('f'), types = [].concat(sch.type || []);
  let input;
  if (AC_FIELDS.test(name) && opts.ledger) {
    input = h('select', { id, name }, h('option', { value: '' }, '—'),
      opts.ledger.accounts.map((a) => h('option', { value: a.account_currency_id }, `${a.label} · ${a.currency}`)));
  } else if (LA_FIELDS.test(name) && opts.ledger) {
    input = h('select', { id, name }, h('option', { value: '' }, '—'),
      opts.ledger.accounts.map((a) => h('option', { value: a.ledger_account_id }, `${a.label} · ${a.currency}`)),
      opts.ledger.categories.map((c) => h('option', { value: c.ledger_account_id }, `${c.name_en} / ${c.name_zh} · ${c.currency}`)));
  } else if (Array.isArray(sch.enum) && sch.enum.every((x) => typeof x === 'boolean' || x === 'true' || x === 'false')) {
    input = h('select', { id, name }, h('option', { value: '' }, '—'), h('option', { value: 'true' }, 'true'), h('option', { value: 'false' }, 'false'));
  } else if (Array.isArray(sch.enum)) {
    input = h('select', { id, name }, h('option', { value: '' }, '—'), sch.enum.map((x) => h('option', { value: String(x) }, String(x))));
  } else if (types.includes('array') || types.includes('object')) {
    input = h('textarea', { id, name, rows: 3, 'data-json': '1', spellcheck: 'false' });
  } else {
    const type = sch.format === 'date' ? 'date' : sch.format === 'date-time' ? 'datetime-local' : 'text';
    input = h('input', { id, name, type, inputmode: sch.pattern && /\[0-9\]/.test(sch.pattern) ? 'decimal' : null, autocomplete: 'off' });
  }
  return h('div', { class: 'field' }, h('label', { for: id }, label(name)), input);
}

function readValue(el, sch) {
  const raw = el.value.trim();
  if (raw === '') return undefined;
  if (el.type === 'datetime-local') return new Date(raw).toISOString();
  if (el.dataset.json || ((raw.startsWith('[') || raw.startsWith('{')) && !sch.format)) {
    try { return JSON.parse(raw); } catch { if (el.dataset.json) return raw.split(',').map((s) => s.trim()).filter(Boolean); }
  }
  if (raw === 'true' || raw === 'false') return [].concat(sch.type || []).includes('boolean') || Array.isArray(sch.enum) ? raw === 'true' : raw;
  return raw;
}

export function renderForm(entry, opts = {}) {
  const props = (entry.input_schema && entry.input_schema.properties) || {};
  const names = Object.keys(props).sort();
  const rawId = uid('raw');
  const form = h('form', { class: 'task-form', novalidate: true },
    names.map((n) => fieldFor(n, props[n], opts)),
    h('details', {}, h('summary', {}, t('task.raw')),
      h('div', { class: 'field' }, h('label', { for: rawId }, t('task.raw')),
        h('textarea', { id: rawId, name: '__raw', rows: 4, spellcheck: 'false', 'aria-describedby': `${rawId}-hint` }),
        h('p', { id: `${rawId}-hint`, class: 'hint' }, t('task.raw_hint')))),
    h('button', { type: 'submit', class: 'primary' }, opts.submitLabel || t('task.run')));
  form.values = () => {
    const raw = form.elements.__raw.value.trim();
    if (raw) return JSON.parse(raw);
    const out = {};
    for (const n of names) { const v = readValue(form.elements[n], props[n]); if (v !== undefined) out[n] = v; }
    return out;
  };
  return form;
}

// --------------------------------------------------------------------------------------------------------------- table
const show = (v) => (v === null || v === undefined ? '' : scalar(v) ? String(v)
  : Array.isArray(v) ? `[${v.length}]` : JSON.stringify(v));
const STATUS_COLS = /(^|_)(status|state)$/;

export function csv(rows, cols) {
  // RFC 4180 quoting; a cell starting with = + - @ tab or CR is prefixed with ' so that a spreadsheet never runs it as a formula,
  // except plain signed numbers (amounts) which stay numeric
  const cell = (v) => {
    let s = show(v);
    if (/^[=+\-@\t\r]/.test(s) && !/^[+-]?\d+(\.\d+)?$/.test(s)) s = `'${s}`;
    return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [cols.join(','), ...rows.map((r) => cols.map((c) => cell(r[c])).join(','))].join('\r\n') + '\r\n';
}

export function renderTable(rows, { caption, name = 'export', onRow } = {}) {
  const cols = [];
  for (const r of rows.slice(0, 200)) for (const [k, v] of Object.entries(r)) if (!cols.includes(k) && (scalar(v) || v === undefined)) cols.push(k);
  for (const r of rows.slice(0, 50)) for (const [k, v] of Object.entries(r)) if (!cols.includes(k) && !scalar(v)) cols.push(k);
  let view = rows, sortCol = null, dir = 1;
  const tbody = h('tbody'), count = h('p', { class: 'hint', 'aria-live': 'polite' });
  const fid = uid('filter');
  const filter = h('input', { id: fid, type: 'search', oninput: () => draw() });
  const thead = h('thead', {}, h('tr', {}, cols.map((c) => {
    const btn = h('button', { type: 'button', class: 'sort', onclick: () => { dir = sortCol === c ? -dir : 1; sortCol = c; draw(); } }, label(c));
    return h('th', { scope: 'col', 'aria-sort': 'none', 'data-col': c }, btn);
  })));
  function draw() {
    const q = filter.value.trim().toLowerCase();
    view = rows.filter((r) => !q || cols.some((c) => show(r[c]).toLowerCase().includes(q)));
    if (sortCol) view = [...view].sort((a, b) => show(a[sortCol]).localeCompare(show(b[sortCol]), undefined, { numeric: true }) * dir);
    for (const th of thead.querySelectorAll('th')) th.setAttribute('aria-sort', th.dataset.col === sortCol ? (dir > 0 ? 'ascending' : 'descending') : 'none');
    tbody.replaceChildren(...view.map((r) => h('tr', onRow ? { tabindex: '0', class: 'clickable', onclick: () => onRow(r), onkeydown: (e) => { if (e.key === 'Enter') onRow(r); } } : {},
      cols.map((c) => {
        const v = r[c], s = show(v);
        const cls = (typeof v === 'number' || /^-?\d+(\.\d+)?$/.test(s)) ? 'n' : STATUS_COLS.test(c) ? `st st-${s}` : null;
        return h('td', { class: cls, 'data-label': label(c) }, s);
      }))));
    count.textContent = t('table.rows', { n: view.length });
  }
  const exportCsv = () => {
    const blob = new Blob(['﻿', csv(view, cols)], { type: 'text/csv;charset=utf-8' });
    const a = h('a', { href: URL.createObjectURL(blob), download: `${name}.csv` });
    document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };
  draw();
  if (!rows.length) return h('p', { class: 'empty' }, t('table.empty'));
  return h('div', { class: 'table' },
    h('div', { class: 'table-tools' }, h('label', { for: fid }, t('table.filter')), filter,
      h('button', { type: 'button', onclick: exportCsv }, t('table.csv'))),
    count,
    h('div', { class: 'scroll', tabindex: '0', role: 'region', 'aria-label': caption || name },
      h('table', {}, caption ? h('caption', {}, caption) : null, thead, tbody)));
}

// -------------------------------------------------------------------------------------------------------------- detail
export function renderDetail(obj, { name = 'result', depth = 0 } = {}) {
  if (scalar(obj)) return h('p', {}, show(obj));
  if (Array.isArray(obj)) {
    return obj.length && obj.every(isObj) ? renderTable(obj, { caption: label(name), name })
      : h('p', {}, obj.map(show).join(', ') || t('table.empty'));
  }
  const dl = h('dl', { class: depth ? 'detail nested' : 'detail' });
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === 'string' && (v.length > 160 || v.includes('\n'))) {      // a prompt or a document text: verbatim, copyable
      const pre = h('pre', { class: 'mono block', tabindex: '0' }, v);
      dl.append(h('dt', {}, label(k)), h('dd', {}, pre, h('button', { type: 'button', onclick: async (e) => {
        try { await navigator.clipboard.writeText(v); e.target.textContent = t('task.copied'); } catch { window.getSelection().selectAllChildren(pre); }
      } }, t('task.copy'))));
      continue;
    }
    dl.append(h('dt', {}, label(k)), h('dd', {}, scalar(v) ? h('span', { class: STATUS_COLS.test(k) ? `st st-${v}` : null }, show(v))
      : depth > 3 ? JSON.stringify(v) : renderDetail(v, { name: k, depth: depth + 1 })));
  }
  return dl;
}

// a command or query result: the first list of records becomes the table, the rest stays a detail view
export function renderResult(r, name) {
  return renderDetail(r, { name });
}
