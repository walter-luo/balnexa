// Balnexa PWA (S4 CORE-9; UA V1.2 §12; Owner Requirements OR-U-01…08, OR-X-05). Plain ES modules, no build step and no
// third-party code. Every screen works with every AI host and every LLM service unreachable: the page talks only to this
// origin (and to Google Identity Services on the sign-in screen); there is no AI route anywhere in it (AT-NOAI-00).
import * as api from './api.js';
import * as i18n from './i18n.js';
import { h, renderForm, renderTable, renderDetail, renderResult } from './render.js';

const { t } = i18n;
const TIER = { owner: 3, admin: 3, member: 2, viewer: 1 };
const S = { navigated: false, me: null, tier: 0, cat: new Map(), menu: null, ledger: null, rows: new Map(), cfg: null };
const main = () => document.getElementById('view');
const today = () => new Date().toLocaleDateString('en-CA');           // the viewer's calendar day, ISO

// ------------------------------------------------------------------------------------------------------------- shell
function status(msg, kind = 'info') {
  const el = document.getElementById('status');
  el.className = `status ${kind}`;
  el.textContent = msg || '';
}
const fail = (e) => { status(i18n.errorText(e), 'error'); if (e && e.code === 'UNAUTHENTICATED') setTimeout(() => boot(), 50); };

function screen(titleKey, ...kids) {
  const h1 = h('h1', { tabindex: '-1' }, t(titleKey));
  main().replaceChildren(h1, ...kids);
  document.title = `${t(titleKey)} · ${t('app.title')}`;
  if (S.navigated) h1.focus();          // after a navigation the new heading takes focus; the first load leaves the skip link first
  document.body.dataset.route = location.hash;
}

// tasks with a dedicated screen; every other task uses the generic renderers
const DEDICATED = { 'bnx.q_handoff_status': 'handoff', 'bnx.cmd_handoff_prepare': 'handoff/prepare', 'bnx.cmd_handoff_import': 'handoff/import',
  'bnx.q_ai_connections': 'connections', 'bnx.q_doc_redaction_queue': 'documents' };
const visible = (e) => !!e && e.channels.includes('pwa') && (e.tier === null || e.tier <= S.tier);
const entry = (fn) => { const e = S.cat.get(fn); return visible(e) ? e : null; };

function nav() {
  const items = [['home', 'nav.home'], ['add', 'nav.add'], ['activity', 'nav.activity'], ['review', 'nav.review'], ['reports', 'nav.reports'], ['menu', 'nav.menu']];
  const cur = (location.hash.split('/')[1] || 'home').split('?')[0];
  document.getElementById('nav').replaceChildren(h('ul', {}, items.map(([r, k]) =>
    h('li', {}, h('a', { href: `#/${r}`, 'aria-current': cur === r ? 'page' : null }, t(k))))));
  const user = document.getElementById('user');
  user.replaceChildren(S.me ? h('span', {}, S.me.display_name) : '',
    h('button', { type: 'button', class: 'link', lang: i18n.other() === 'zh' ? 'zh-Hans' : 'en', onclick: async () => { await i18n.load(i18n.other()); render(); } }, t('app.lang')),
    S.me ? h('a', { href: '#/settings' }, t('nav.settings')) : '');
  document.querySelector('.skip').textContent = t('app.skip');
  document.querySelector('.offline-banner').textContent = t('app.offline');
  document.getElementById('nav').setAttribute('aria-label', t('app.title'));
}

async function ledger(force) {
  if (!S.ledger || force) S.ledger = await api.query('ledger_accounts');
  return S.ledger;
}

// ------------------------------------------------------------------------------------------------------------- home
async function home() {
  screen('home.title', h('p', {}, t('home.hello', { name: S.me.display_name, role: t(`role.${S.me.role}`) })), h('p', { class: 'hint' }, t('app.loading')));
  const parts = [h('p', {}, t('home.hello', { name: S.me.display_name, role: t(`role.${S.me.role}`) }))];
  const tasks = [];
  if (entry('bnx.q_review_queue')) tasks.push(api.query('review_queue').then((r) => {
    const n = r.plans.filter((p) => p.approvable_by_me).length;
    if (n) parts.push(h('p', {}, h('a', { href: '#/review' }, t('home.review', { n }))));
  }));
  if (entry('bnx.q_notifications')) tasks.push(api.query('notifications').then((r) => {
    if (r.notifications.length) parts.push(h('p', {}, h('a', { href: '#/task/bnx.q_notifications' }, t('home.notifications', { n: r.notifications.length }))));
  }));
  if (entry('bnx.q_backup_status') && S.tier >= 3) tasks.push(api.query('backup_status', { limit: 5 }).then((r) => {
    const v = (r.runs || []).find((x) => x.outcome === 'VERIFIED');
    parts.push(h('p', {}, v ? t('home.backup', { when: v.started_at }) : t('home.backup.none')));
  }));
  let bal = null;
  if (entry('bnx.q_f1_balances')) tasks.push(api.query('f1_balances', { as_of: today() }).then((r) => { bal = r.rows; }));
  try { await Promise.all(tasks); } catch (e) { fail(e); }
  const cols = (r) => ({ account: r.account_label, institution: r.institution, currency: r.currency, balance: r.balance, status: r.status });
  screen('home.title', ...parts, h('h2', {}, t('home.balances')),
    bal ? renderTable(bal.map(cols), { name: `balances-${today()}` }) : '');
}

// ------------------------------------------------------------------------------------------------------------- add
// Quick Entry (Draft-04 C1 W-M01/W-M02/W-M03; UA §12.1): a member who can post to the account posts directly
// (cmd_post_transaction); otherwise a member_draft plan is created for approval (cmd_draft_create_transaction, CROSS-03).
async function add() {
  let L;
  try { L = await ledger(true); } catch (e) { return fail(e); }
  const accs = L.accounts.filter((a) => a.state === 'active');
  if (!accs.length) return screen('add.title', h('p', {}, t('add.no_accounts')));
  let key = api.newKey();
  const opt = (a) => h('option', { value: a.account_currency_id }, `${a.label} · ${a.currency}${a.can_post ? '' : ' *'}`);
  const f = h('form', { class: 'task-form', novalidate: true },
    h('fieldset', {}, h('legend', {}, t('add.type')),
      ['expense', 'income', 'transfer'].map((k, i) => h('label', { class: 'radio' },
        h('input', { type: 'radio', name: 'type', value: k, checked: i === 0, onchange: () => sync() }), t(`add.${k}`)))),
    h('div', { class: 'field' }, h('label', { for: 'q-acc' }, t('add.account')), h('select', { id: 'q-acc', name: 'acc', onchange: () => sync() }, accs.map(opt))),
    h('div', { class: 'field', id: 'q-cat-f' }, h('label', { for: 'q-cat' }, t('add.category')), h('select', { id: 'q-cat', name: 'cat' })),
    h('div', { class: 'field', id: 'q-to-f', hidden: true }, h('label', { for: 'q-to' }, t('add.to')), h('select', { id: 'q-to', name: 'to' }, accs.map(opt))),
    h('div', { class: 'field' }, h('label', { for: 'q-amt' }, t('add.amount')),
      h('input', { id: 'q-amt', name: 'amount', inputmode: 'decimal', autocomplete: 'off', required: true, pattern: '^[0-9]+(\\.[0-9]{1,4})?$' })),
    h('div', { class: 'field' }, h('label', { for: 'q-date' }, t('add.date')), h('input', { id: 'q-date', name: 'date', type: 'date', value: today(), required: true })),
    h('div', { class: 'field' }, h('label', { for: 'q-desc' }, t('add.description')), h('input', { id: 'q-desc', name: 'desc', autocomplete: 'off' })),
    h('p', { id: 'q-note', class: 'hint', 'aria-live': 'polite' }),
    h('button', { type: 'submit', class: 'primary' }, t('add.submit')));
  const el = f.elements;
  const ac = (id) => accs.find((a) => a.account_currency_id === id);
  function sync() {
    const type = el.type.value, a = ac(el.acc.value);
    f.querySelector('#q-cat-f').hidden = type === 'transfer';
    f.querySelector('#q-to-f').hidden = type !== 'transfer';
    const kind = type === 'income' ? 'income' : 'expense';
    el.cat.replaceChildren(...L.categories.filter((c) => c.kind === kind && c.currency === a.currency)
      .map((c) => h('option', { value: c.ledger_account_id }, i18n.current() === 'zh' ? c.name_zh : c.name_en)));
    f.querySelector('#q-note').textContent = a.can_post ? '' : t('add.via_draft');
  }
  sync();
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    if (!f.checkValidity()) { f.reportValidity(); return; }
    const type = el.type.value, a = ac(el.acc.value), amt = el.amount.value.trim();
    const d = el.date.value, desc = el.desc.value.trim() || t(`add.${type}`);
    let counter, other = null;
    if (type === 'transfer') {
      other = ac(el.to.value);
      if (!other || other.currency !== a.currency || other.account_currency_id === a.account_currency_id) return status(t('add.currency_mismatch'), 'error');
      counter = other.ledger_account_id;
    } else {
      counter = el.cat.value;
      if (!counter) return status(t('error.VALIDATION_FAILED', { field: t('add.category') }), 'error');
    }
    const et = type === 'expense' ? 'consumption_expense' : type === 'income' ? 'income' : 'internal_transfer';
    const signed = type === 'income' ? amt : `-${amt}`;                                // movement of the selected account
    const neg = (s) => (s.startsWith('-') ? s.slice(1) : `-${s}`);
    try {
      let r;
      if (a.can_post && (!other || other.can_post)) {
        r = await api.command('post_transaction', { economic_type: et, transaction_date: d, description: desc,
          lines: [{ ledger_account_id: a.ledger_account_id, currency: a.currency, amount: signed },
                  { ledger_account_id: counter, currency: a.currency, amount: neg(signed) }] }, key);
        status(t('add.posted', { id: r.journal_id }), 'ok');
      } else {
        r = await api.command('draft_create_transaction', { account_currency_id: a.account_currency_id, transaction_date: d, economic_type: et,
          amount: signed, counter_ledger_account_id: counter, description: desc }, key);
        status(t('add.drafted', { id: r.plan_id }), 'ok');
        main().append(h('p', {}, h('a', { href: `#/confirm/${r.plan_id}` }, t('add.open_draft'))));
      }
      key = api.newKey();                                                              // the next entry is a new intent
      el.amount.value = ''; el.desc.value = '';
    } catch (e) { fail(e); }
  });
  screen('add.title', f);
}

// --------------------------------------------------------------------------------------------------------- activity
// List and calendar of one month (OR-U-03 / C-02): daily counts and per-currency totals of account movements; the day is the
// stored transaction date, so it never shifts with the viewer's time zone; a day drills down to its transactions.
function monthRange(m) {
  const [y, mo] = m.split('-').map(Number);
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  return { from: `${m}-01`, to: `${m}-${String(last).padStart(2, '0')}`, y, mo, last };
}
const moves = (r) => r.lines.filter((l) => l.account_currency_id);
function totals(rows) {
  const out = {};
  for (const r of rows) for (const l of moves(r)) out[l.currency] = (out[l.currency] || 0) + Number(l.amount);
  return Object.entries(out).map(([c, v]) => `${c} ${v.toFixed(2)}`).join(' · ');
}

async function activity(params) {
  const m = params.get('m') || today().slice(0, 7), mode = params.get('mode') || 'list', day = params.get('day');
  const R = monthRange(m);
  let rows;
  try { rows = (await api.query('f2_transactions', { date_from: R.from, date_to: R.to, limit: 500 })).rows; } catch (e) { return fail(e); }
  for (const r of rows) S.rows.set(r.journal_id, r);
  const mid = 'act-month';
  const picker = h('div', { class: 'toolbar' }, h('label', { for: mid }, t('activity.month')),
    h('input', { id: mid, type: 'month', value: m, onchange: (e) => go(`activity?m=${e.target.value}&mode=${mode}`) }),
    h('div', { role: 'group', 'aria-label': t('activity.title') },
      ['list', 'calendar'].map((k) => h('a', { class: 'tab', href: `#/activity?m=${m}&mode=${k}`, 'aria-current': mode === k ? 'page' : null }, t(`activity.${k}`)))));
  const list = (rs) => (rs.length ? renderTable(rs.map((r) => ({ date: r.transaction_date, description: r.description, type: r.economic_type,
    amount: totals([r]), corrected: r.corrected, journal_id: r.journal_id })), { caption: t('activity.title'), name: `activity-${m}`, onRow: (r) => go(`tx/${r.journal_id}`) })
    : h('p', { class: 'empty' }, t('activity.none')));
  if (mode !== 'calendar') return screen('activity.title', picker, list(rows));
  const byDay = new Map();
  for (const r of rows) { const k = r.transaction_date; byDay.set(k, [...(byDay.get(k) || []), r]); }
  const first = new Date(Date.UTC(R.y, R.mo - 1, 1)).getUTCDay();                       // 0 = Sunday
  const cells = [];
  for (let i = 0; i < first; i++) cells.push(h('li', { class: 'pad', 'aria-hidden': 'true' }));
  for (let dd = 1; dd <= R.last; dd++) {
    const date = `${m}-${String(dd).padStart(2, '0')}`, rs = byDay.get(date) || [];
    cells.push(h('li', { class: rs.length ? 'has' : null, 'data-date': date },
      rs.length ? h('a', { href: `#/activity?m=${m}&mode=calendar&day=${date}`, 'aria-label': t('activity.day', { date, n: rs.length }) },
        h('span', { class: 'd' }, dd), h('span', { class: 'c' }, `${rs.length}×`), h('span', { class: 'tt' }, totals(rs)))
        : h('span', { class: 'd' }, dd)));
  }
  const wd = new Intl.DateTimeFormat(i18n.current() === 'zh' ? 'zh-Hans' : 'en', { weekday: 'short', timeZone: 'UTC' });
  const head = h('div', { class: 'calendar weekdays', 'aria-hidden': 'true' },
    [0, 1, 2, 3, 4, 5, 6].map((i) => h('span', {}, wd.format(new Date(Date.UTC(2023, 0, 1 + i))))));   // 2023-01-01 was a Sunday
  screen('activity.title', picker, head, h('ol', { class: 'calendar', 'aria-label': m }, cells),
    day ? h('section', { 'aria-labelledby': 'dayh' }, h('h2', { id: 'dayh' }, t('activity.day', { date: day, n: (byDay.get(day) || []).length })), list(byDay.get(day) || [])) : '');
}

async function tx(id) {
  const r = S.rows.get(id);
  if (!r) return go('activity');
  const kids = [renderDetail(r, { name: 'transaction' })];
  if (entry('bnx.cmd_correct_transaction') && !r.corrected && r.economic_type !== 'opening_balance') {
    let key = api.newKey();
    const f = h('form', { class: 'task-form' }, h('div', { class: 'field' }, h('label', { for: 'rv-reason' }, t('activity.reason')),
      h('input', { id: 'rv-reason', name: 'reason', required: true })), h('button', { type: 'submit' }, t('activity.reverse')));
    f.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      try {
        const x = await api.command('correct_transaction', { journal_id: id, reason: f.elements.reason.value || t('activity.reverse') }, key);
        key = api.newKey();
        status(t('activity.reversed', { id: x.reversal_journal_id }), 'ok');
      } catch (e) { fail(e); }
    });
    kids.push(f);
  }
  if (entry('bnx.cmd_handoff_prepare')) kids.push(h('p', {}, h('a', { href: `#/handoff/prepare?journal_id=${id}` }, t('activity.handoff'))));
  screen('activity.detail', ...kids);
}

// ------------------------------------------------------------------------------------------------------------ review
async function review() {
  let r;
  try { r = await api.query('review_queue'); } catch (e) { return fail(e); }
  const plans = r.plans.map((p) => ({ kind: p.kind, items: p.item_count, origin: p.origin_channel, approvable_by_me: p.approvable_by_me,
    held: (p.hold_reasons || []).join(' '), plan_id: p.plan_id }));
  screen('review.title', plans.length ? renderTable(plans, { caption: t('review.title'), name: 'review', onRow: (p) => go(`confirm/${p.plan_id}`) })
    : h('p', { class: 'empty' }, t('review.none')),
    entry('bnx.q_r30_review_queue') ? h('p', {}, h('a', { href: '#/task/bnx.q_r30_review_queue' }, t('task.bnx.q_r30_review_queue'))) : '');
}

// Draft Confirm (C-01/C-04; UA §12.3 Mode H): the PWA review screen is the guaranteed confirmation path. A sealed link from an
// AI host carries the plan hash and scope digest it was made for (h, s); approval always sends the version the screen shows,
// and a link whose seal no longer matches cannot approve until the member has reviewed the current version.
async function confirm(planId, params) {
  let d;
  try { d = await api.query('draft_get_for_confirmation', { plan_id: planId }); } catch (e) { return fail(e); }
  const sealH = params.get('h'), sealS = params.get('s');
  const sealed = sealH || sealS ? sealH === d.plan_hash && sealS === d.scope_digest : null;
  const items = d.items.map((it) => ({ seq: it.seq, date: it.payload.transaction_date, type: it.economic_type, description: it.payload.description,
    lines: it.lines.map((l) => `${l.amount} ${l.currency}`).join(' / ') }));
  const kids = [h('dl', { class: 'detail' }, h('dt', {}, 'kind'), h('dd', {}, d.kind), h('dt', {}, 'state'), h('dd', {}, h('span', { class: `st st-${d.state}` }, d.state)),
    h('dt', {}, 'plan_hash'), h('dd', { class: 'mono' }, d.plan_hash)),
  h('h2', {}, t('confirm.items')), renderTable(items, { caption: t('confirm.items'), name: `draft-${planId}` })];
  if ((d.hold_reasons || []).length) kids.push(h('p', { class: 'status error' }, t('confirm.held', { reasons: d.hold_reasons.join(', ') })));
  if (sealed === true) kids.push(h('p', { class: 'status ok' }, t('confirm.sealed_ok')));
  let ack = sealed !== false;
  if (sealed === false) {
    const cb = h('input', { type: 'checkbox', id: 'ack', onchange: (e) => { ack = e.target.checked; btn.disabled = !ack || !d.approvable_by_me; } });
    kids.push(h('p', { class: 'status error', role: 'alert' }, t('confirm.sealed_changed')), h('p', {}, cb, ' ', h('label', { for: 'ack' }, t('confirm.review_current'))));
  }
  let key = api.newKey();
  const btn = h('button', { type: 'button', class: 'primary', disabled: !d.approvable_by_me || !ack, onclick: async () => {
    try {
      await api.command('approve_plan', { plan_id: d.plan_id, plan_hash: d.plan_hash, scope_digest: d.scope_digest }, key);
      key = api.newKey(); btn.disabled = true; status(t('confirm.approved'), 'ok');
    } catch (e) { fail(e); }
  } }, t('confirm.approve'));
  if (entry('bnx.cmd_approve_plan')) kids.push(btn);
  if (!d.approvable_by_me) kids.push(h('p', { class: 'hint' }, t('confirm.not_yours')));
  if (entry('bnx.cmd_draft_withdraw') && d.created_by === S.me.member_id) {
    kids.push(h('button', { type: 'button', onclick: async () => {
      try { await api.command('draft_withdraw', { plan_id: d.plan_id }); status(t('task.done'), 'ok'); } catch (e) { fail(e); }
    } }, t('confirm.withdraw')));
  }
  screen('confirm.title', ...kids);
}

// ----------------------------------------------------------------------------------------------------------- reports
async function reports() {
  const kids = [];
  const fam = ['q_f1_balances', 'q_f2_transactions', 'q_f3_income_expense', 'q_f4_investments', 'q_f5_networth', 'q_f6_cards', 'q_f7_reconciliation',
    'q_cashflow_statement', 'q_r28_loan_position', 'q_evidence_trace'].map((n) => `bnx.${n}`).filter((n) => entry(n));
  kids.push(h('ul', { class: 'links' }, fam.map((n) => h('li', {}, h('a', { href: `#/task/${n}` }, t(`task.${n}`))))));
  if (entry('bnx.cmd_create_report_snapshot')) {
    let key = api.newKey();
    const f = h('form', { class: 'task-form inline' }, h('div', { class: 'field' }, h('label', { for: 'snap-asof' }, t('reports.as_of')),
      h('input', { id: 'snap-asof', name: 'as_of', type: 'date', value: today(), required: true })), h('button', { type: 'submit' }, t('reports.create')));
    f.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      try {
        const r = await api.command('create_report_snapshot', { report_code: 'R-BAL', as_of: f.elements.as_of.value }, key);
        key = api.newKey(); status(t('reports.created', { id: r.snapshot_id }), 'ok'); reports();
      } catch (e) { fail(e); }
    });
    kids.push(h('h2', {}, t('reports.snapshot')), f);
  }
  if (entry('bnx.q_snapshot_list')) {
    try {
      const r = await api.query('snapshot_list', {});
      const list = (r.snapshots || r.rows || []).map((s) => ({ report: s.report_code, as_of: s.as_of || (s.filters && s.filters.as_of), status: s.status,
        ledger_version: s.ledger_version, snapshot_id: s.snapshot_id || s.id }));
      kids.push(h('h2', {}, t('reports.snapshots')), renderTable(list, { caption: t('reports.snapshots'), name: 'snapshots',
        onRow: (s) => window.open(`/api/v1/artifacts/${s.snapshot_id}`, '_blank', 'noopener') }));
    } catch (e) { fail(e); }
  }
  screen('reports.title', ...kids);
}

// --------------------------------------------------------------------------------------------------------- menu / task
function menu() {
  const kids = S.menu.items.map((it) => {
    const tasks = it.tasks.filter((fn) => entry(fn));
    if (!tasks.length) return null;                                 // an item with nothing the caller may do is not shown
    return h('section', { 'aria-labelledby': `m-${it.id}`, 'data-item': it.id }, h('h2', { id: `m-${it.id}` }, t(`menu.${it.id}`)),
      h('ul', { class: 'links' }, tasks.map((fn) => h('li', {}, h('a', { href: `#/${DEDICATED[fn] || `task/${fn}`}`, 'data-task': fn }, t(`task.${fn}`))))));
  });
  screen('menu.title', ...kids);
}

async function task(fn, params) {
  const e = entry(fn);
  if (!e) return screen('task.not_found');
  let L = null;
  try { L = await ledger(); } catch { /* the pickers fall back to text fields */ }
  const f = renderForm(e, { ledger: L });
  for (const [k, v] of params) if (f.elements[k]) f.elements[k].value = v;
  const out = h('section', { 'aria-live': 'polite', 'aria-labelledby': 'res-h' });
  let key = api.newKey();
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    let body;
    try { body = f.values(); } catch { return status(t('error.VALIDATION_FAILED', { field: '__raw' }), 'error'); }
    try {
      const r = await api.call(e, body, key);
      if (e.kind === 'command') key = api.newKey();
      status(t('task.done'), 'ok');
      out.replaceChildren(h('h2', { id: 'res-h' }, t('task.result')), renderResult(r, api.restName(e)));
    } catch (err) { fail(err); }
  });
  screen(`task.${fn}`, h('p', { class: 'hint' }, e.description), f, out);
  if (e.kind === 'query' && !Object.keys((e.input_schema || {}).properties || {}).length) f.requestSubmit();
}

// ------------------------------------------------------------------------------------------------------------- handoff
// Inter-project handoff by generated prompt (CORE-10; OR-X-01…05, C-05; UA §12.2). Deterministic on both sides: the prompt is
// generated by the database and the import reads only the one fenced JSON block - every other line of the pasted text is
// ignored, so instructions inside a received prompt can never act. An import creates at most a draft for the normal review.
async function handoff() {
  let r;
  try { r = await api.query('handoff_status'); } catch (e) { return fail(e); }
  const rows = r.messages.map((m) => ({ created_at: m.created_at, direction: m.direction, message_type: m.message_type, state: m.state,
    sender_project: m.sender_project, message_id: m.message_id, transfer_id: m.transfer_id, plan_id: m.plan_id }));
  const acts = h('p', { class: 'toolbar' },
    entry('bnx.cmd_handoff_import') ? h('a', { class: 'tab', href: '#/handoff/import' }, t('handoff.import')) : '',
    entry('bnx.cmd_handoff_prepare') ? h('a', { class: 'tab', href: `#/activity?m=${today().slice(0, 7)}` }, t('handoff.prepare_from')) : '');
  screen('handoff.title', h('p', { class: 'hint' }, t('handoff.explain')), acts,
    rows.length ? renderTable(rows, { caption: t('handoff.title'), name: 'handoff', onRow: (m) => (m.plan_id ? go(`confirm/${m.plan_id}`) : null) })
      : h('p', { class: 'empty' }, t('handoff.none')));
}

async function handoffPrepare(params) {
  const jid = params.get('journal_id') || '';
  const tx0 = S.rows.get(jid);
  let key = api.newKey();
  const f = h('form', { class: 'task-form', novalidate: true },
    h('div', { class: 'field' }, h('label', { for: 'hp-j' }, t('field.journal_id')), h('input', { id: 'hp-j', name: 'journal_id', value: jid, required: true, autocomplete: 'off' })),
    tx0 ? h('p', { class: 'hint' }, `${tx0.transaction_date} · ${tx0.description} · ${totals([tx0])}`) : '',
    h('div', { class: 'field' }, h('label', { for: 'hp-l' }, t('handoff.recipient')), h('input', { id: 'hp-l', name: 'label', required: true, autocomplete: 'off' })),
    h('div', { class: 'field' }, h('label', { for: 'hp-c' }, t('handoff.code')),
      h('input', { id: 'hp-c', name: 'code', required: true, pattern: '^[A-Z0-9]{2,10}$', autocomplete: 'off', 'aria-describedby': 'hp-c-h' }),
      h('p', { id: 'hp-c-h', class: 'hint' }, t('handoff.code_hint'))),
    h('div', { class: 'field' }, h('label', { for: 'hp-n' }, t('field.note')), h('input', { id: 'hp-n', name: 'note', autocomplete: 'off', 'aria-describedby': 'hp-n-h' }),
      h('p', { id: 'hp-n-h', class: 'hint' }, t('handoff.note_hint'))),
    h('button', { type: 'submit', class: 'primary' }, t('handoff.generate')));
  const out = h('section', { 'aria-live': 'polite' });
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const el = f.elements;
    el.code.value = el.code.value.trim().toUpperCase();
    if (!f.checkValidity()) { f.reportValidity(); return; }
    try {
      const r = await api.command('handoff_prepare', { journal_id: el.journal_id.value.trim(), note: el.note.value.trim() || undefined,
        recipient: { label: el.label.value.trim(), system_code: el.code.value } }, key);
      key = api.newKey();
      status(t('handoff.prepared', { id: r.message_id }), 'ok');
      const pre = h('pre', { class: 'mono block', tabindex: '0', id: 'handoff-text' }, r.text);
      let sentKey = api.newKey();
      out.replaceChildren(h('h2', {}, t('handoff.prompt')), h('p', { class: 'hint' }, t('handoff.prompt_hint')), pre,
        h('p', { class: 'toolbar' },
          h('button', { type: 'button', onclick: async (e) => {
            try { await navigator.clipboard.writeText(r.text); e.target.textContent = t('task.copied'); } catch { window.getSelection().selectAllChildren(pre); }
          } }, t('task.copy')),
          entry('bnx.cmd_handoff_mark_sent') ? h('button', { type: 'button', id: 'mark-sent', onclick: async (e) => {
            try { await api.command('handoff_mark_sent', { message_id: r.message_id }, sentKey); sentKey = api.newKey(); e.target.disabled = true; status(t('handoff.sent'), 'ok'); }
            catch (err) { fail(err); }
          } }, t('handoff.mark_sent')) : ''));
    } catch (e) { fail(e); }
  });
  screen('handoff.prepare', f, out);
}

async function handoffImport() {
  let L;
  try { L = await ledger(true); } catch (e) { return fail(e); }
  let key = api.newKey();
  const f = h('form', { class: 'task-form', novalidate: true },
    h('p', { class: 'hint', id: 'hi-h' }, t('handoff.import_hint')),
    h('div', { class: 'field' }, h('label', { for: 'hi-t' }, t('handoff.paste')),
      h('textarea', { id: 'hi-t', name: 'text', rows: 10, required: true, spellcheck: 'false', 'aria-describedby': 'hi-h' })),
    h('div', { class: 'field' }, h('label', { for: 'hi-a' }, t('handoff.account')),
      h('select', { id: 'hi-a', name: 'acc', 'aria-describedby': 'hi-a-h' }, h('option', { value: '' }, '—'),
        L.accounts.filter((a) => a.state === 'active').map((a) => h('option', { value: a.account_currency_id }, `${a.label} · ${a.currency}`))),
      h('p', { id: 'hi-a-h', class: 'hint' }, t('handoff.account_hint'))),
    h('fieldset', {}, h('legend', {}, t('handoff.direction')),
      ['incoming', 'outgoing'].map((k, i) => h('label', { class: 'radio' }, h('input', { type: 'radio', name: 'dir', value: k, checked: i === 0 }), t(`handoff.${k}`)))),
    h('button', { type: 'submit', class: 'primary' }, t('handoff.import')));
  const out = h('section', { 'aria-live': 'polite' });
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const el = f.elements;
    if (!el.text.value.trim()) return status(t('error.VALIDATION_FAILED', { field: t('handoff.paste') }), 'error');
    try {
      const r = await api.command('handoff_import', { text: el.text.value, direction: el.dir.value,
        ...(el.acc.value ? { account_currency_id: el.acc.value } : {}) }, key);
      key = api.newKey();
      const kids = [h('dl', { class: 'detail' }, h('dt', {}, t('field.status')), h('dd', {}, h('span', { class: `st st-${r.status}` }, r.status)),
        r.message_type ? [h('dt', {}, t('field.type')), h('dd', {}, r.message_type)] : '',
        r.reason ? [h('dt', {}, t('field.reason')), h('dd', {}, t(`handoff.reason.${r.reason}`))] : '')];
      if (r.duplicate) kids.push(h('p', {}, t('handoff.duplicate')));
      if (r.plan_id) kids.push(h('p', {}, h('a', { href: `#/confirm/${r.plan_id}` }, t('handoff.review_draft'))));
      status(r.status === 'EXCEPTION' ? t('handoff.exception') : t('handoff.imported'), r.status === 'EXCEPTION' ? 'error' : 'ok');
      out.replaceChildren(h('h2', {}, t('task.result')), ...kids);
    } catch (e) { fail(e); }
  });
  screen('handoff.import', f, out);
}

// ------------------------------------------------------------------------------------------------------------ settings
async function settings() {
  const kids = [h('button', { type: 'button', onclick: async () => {
    try { await api.signOut(); } catch { /* the cookie may already be gone */ }
    S.me = null; status(t('settings.signed_out'), 'ok'); boot();
  } }, t('settings.signout'))];
  if (entry('bnx.q_config_status')) {
    try { kids.push(h('h2', {}, t('settings.config')), renderDetail(await api.query('config_status'), { name: 'config' })); } catch (e) { fail(e); }
  }
  const it = S.menu.items.find((x) => x.id === 'settings');
  const tasks = it.tasks.filter((fn) => entry(fn) && fn !== 'bnx.q_config_status');
  if (tasks.length) kids.push(h('ul', { class: 'links' }, tasks.map((fn) => h('li', {}, h('a', { href: `#/${DEDICATED[fn] || `task/${fn}`}` }, t(`task.${fn}`))))));
  screen('settings.title', ...kids);
}

// ------------------------------------------------------------------------------------------------- AI-host consent (AIH-1)
// Reached from GET /oauth/authorize after the Gateway checked the client and its redirect URI (AIH V1.2 §4.2-§4.3; OR-AIH-06;
// OR-P-07: sign-in happens here, never in an AI conversation). Nothing is pre-selected that the Owner did not choose: draft
// scopes and account-currencies start unticked (data minimization); the AI host can never post or approve (C-04).
const READ_SCOPES = ['finance.read', 'reports.read', 'handoff.read', 'offline_access'];
async function consentScreen(params) {
  const p = Object.fromEntries(params);
  const base = { client_id: p.client_id || '', redirect_uri: p.redirect_uri || '' };
  let d, L;
  try { d = await api.oauth({ action: 'describe', ...base }); L = await ledger(true); } catch (e) { return fail(e); }
  const requested = (p.scope || '').split(' ').filter(Boolean);
  const grantable = requested.filter((x) => d.consentable.includes(x));
  const absent = requested.filter((x) => !d.consentable.includes(x));
  const surface = p.resource === d.resources.api ? 'api' : 'mcp';
  const f = h('form', { class: 'task-form', novalidate: true },
    h('p', { id: 'cs-who' }, t('consent.who', { client: d.client_name, host: t(`host.${d.host_profile || 'unknown'}`) })),
    h('p', { class: 'hint' }, t(`consent.surface_${surface}`)),
    h('fieldset', {}, h('legend', {}, t('consent.scopes')),
      grantable.map((x) => h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'scope', value: x, checked: READ_SCOPES.includes(x) }),
        h('span', {}, t(`scope.${x}`)))),
      absent.length ? h('p', { class: 'hint', id: 'cs-absent' }, t('consent.not_offered', { list: absent.map((x) => t(`scope.${x}`)).join('; ') })) : ''),
    h('fieldset', {}, h('legend', {}, t('consent.accounts')), h('p', { class: 'hint' }, t('consent.accounts_hint')),
      L.accounts.filter((a) => a.state === 'active').map((a) => h('label', { class: 'check' },
        h('input', { type: 'checkbox', name: 'ac', value: a.account_currency_id }), h('span', {}, `${a.label} · ${a.currency}`)))),
    h('p', { class: 'note', id: 'cs-out' }, t('consent.disclosure')),
    h('p', { class: 'note' }, t('consent.never_posts')),
    h('p', { class: 'toolbar' },
      h('button', { type: 'submit', class: 'primary', id: 'cs-allow' }, t('consent.allow')),
      h('button', { type: 'button', id: 'cs-deny', onclick: async () => {
        try { const r = await api.oauth({ action: 'deny', ...base, state: p.state }); status(t('consent.leaving'), 'ok'); location.assign(r.redirect); } catch (e) { fail(e); }
      } }, t('consent.deny'))));
  f.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const scopes = [...f.querySelectorAll('input[name=scope]:checked')].map((x) => x.value);
    const acs = [...f.querySelectorAll('input[name=ac]:checked')].map((x) => x.value);
    if (!scopes.some((x) => x !== 'offline_access')) return status(t('consent.need_scope'), 'error');
    if (scopes.some((x) => ['finance.read', 'finance.draft', 'reports.read'].includes(x)) && !acs.length) return status(t('consent.need_account'), 'error');
    try {
      const r = await api.oauth({ ...base, code_challenge: p.code_challenge, code_challenge_method: p.code_challenge_method, resource: p.resource,
        state: p.state, scopes, account_currency_ids: acs });
      status(t('consent.leaving'), 'ok');
      location.assign(r.redirect);
    } catch (e) { fail(e); }
  });
  screen('consent.title', f);
}

// ------------------------------------------------------------------------------------------- documents (DOC-2; A1 Rev 1 §5)
// The Owner's redaction queue: documents waiting for a declaration, quarantined, incompletely scanned or admissible. The
// declaration binds to the exact bytes (sha256) the scan saw; the screen shows a short fingerprint so the Owner can compare
// it with the file in the Inbox. No content, value or locator is ever shown (the query returns none).
async function documents() {
  let r;
  try { r = await api.query('doc_redaction_queue'); } catch (e) { return fail(e); }
  const act = (label, cmd, body, ok) => h('button', { type: 'button', onclick: async () => {
    try { await api.command(cmd, body); status(t(ok), 'ok'); documents(); } catch (e) { fail(e); } } }, t(label));
  const rows = r.items.map((d) => h('tr', {},
    h('td', { 'data-label': t('field.file') }, d.file || t('documents.name_withheld')),
    h('td', { 'data-label': t('field.state') }, h('span', { class: `st st-${d.state}` }, t(`documents.${d.state}`))),
    h('td', { 'data-label': t('documents.fingerprint') }, d.sha256 ? h('code', {}, d.sha256.slice(0, 12)) : ''),
    h('td', { 'data-label': t('documents.fidelity') }, d.label || ''),
    h('td', {}, d.state === 'PENDING_DECLARATION' && d.sha256 && entry('bnx.cmd_doc_declare_redacted')
      ? act('documents.declare', 'doc_declare_redacted', { discovery_id: d.discovery_id, sha256: d.sha256 }, 'documents.declared_ok')
      : d.state === 'ADMISSIBLE' && d.declaration_status !== 'DECLARED' && entry('bnx.cmd_doc_tag_sin_bearing')
        ? act('documents.tag', 'doc_tag_sin_bearing', { discovery_id: d.discovery_id }, 'documents.tagged_ok') : '')));
  screen('documents.title', h('p', { class: 'hint' }, t('documents.explain')),
    rows.length ? h('div', { class: 'table' }, h('div', { class: 'scroll', tabindex: '0', role: 'region', 'aria-label': t('documents.title') },
      h('table', { class: 'cards' }, h('caption', {}, t('documents.title')), h('thead', {}, h('tr', {},
        ['field.file', 'field.state', 'documents.fingerprint', 'documents.fidelity', 'connections.action']
          .map((k) => h('th', { scope: 'col' }, t(k))))), h('tbody', {}, rows))))
      : h('p', { class: 'empty' }, t('documents.none')));
}

// ------------------------------------------------------------------------------------------------- AI connections (OR-M-05)
async function connections() {
  let r, L;
  try { r = await api.query('ai_connections'); L = await ledger(); } catch (e) { return fail(e); }
  const names = new Map(L.accounts.map((a) => [a.account_currency_id, `${a.label} · ${a.currency}`]));
  const rows = r.connections.map((c) => h('tr', {},
    h('td', { 'data-label': t('field.client') }, c.client_name, h('br'), h('span', { class: 'hint' }, t(`host.${c.host_profile || 'unknown'}`))),
    h('td', { 'data-label': t('field.scopes') }, c.scopes.join(', ')),
    h('td', { 'data-label': t('consent.accounts') }, c.account_currency_ids.map((x) => names.get(x) || t('connections.hidden_account')).join('; ')),
    h('td', { 'data-label': t('field.approved_at') }, String(c.approved_at || '').slice(0, 16).replace('T', ' ')),
    h('td', { 'data-label': t('field.last_token_at') }, String(c.last_token_at || '').slice(0, 16).replace('T', ' ')),
    h('td', { 'data-label': t('field.state') }, h('span', { class: `st st-${c.state}` }, t(`connections.${c.state}`))),
    h('td', {}, c.state === 'active' && entry('bnx.cmd_revoke_ai_connection') ? h('button', { type: 'button', 'data-connection': c.connection_id, onclick: async (e) => {
      try { await api.command('revoke_ai_connection', { connection_id: c.connection_id }); status(t('connections.revoked_ok', { client: c.client_name }), 'ok'); connections(); }
      catch (err) { fail(err); }
    } }, t('connections.revoke')) : '')));
  screen('connections.title', h('p', { class: 'hint' }, t('connections.explain')),
    rows.length ? h('div', { class: 'table' }, h('div', { class: 'scroll', tabindex: '0', role: 'region', 'aria-label': t('connections.title') },
      h('table', { class: 'cards' }, h('caption', {}, t('connections.title')), h('thead', {}, h('tr', {},
        ['field.client', 'field.scopes', 'consent.accounts', 'field.approved_at', 'field.last_token_at', 'field.state', 'connections.action']
          .map((k) => h('th', { scope: 'col' }, t(k))))), h('tbody', {}, rows))))
      : h('p', { class: 'empty' }, t('connections.none')));
}

// --------------------------------------------------------------------------------------------------------------- login
// Google Identity Services is loaded only on this screen (CSP allows exactly its client script and frame)
function login() {
  const box = h('div', { id: 'gsi' });
  screen('login.title', h('p', {}, t('login.text')), box);
  if (!S.cfg || !S.cfg.google_client_id) return;
  const go2 = () => {
    window.google.accounts.id.initialize({ client_id: S.cfg.google_client_id, callback: async (r) => {
      try { await api.signIn(r.credential); boot(); } catch (e) {
        // installer probe (M0-A runbook): an unknown but verified Google account sees its own subject, to send to the installer.
        // Not through fail(): its UNAUTHENTICATED path re-boots to a fresh login screen and would remove the note (F-M0A-03).
        const sub = e.body && e.body.install_probe_subject;
        if (sub) { status(t('login.failed'), 'error'); box.after(h('p', { class: 'note', id: 'probe' }, t('login.probe', { sub }))); return; }
        status(t('login.failed'), 'error'); fail(e);
      }
    } });
    window.google.accounts.id.renderButton(box, { type: 'standard', locale: i18n.current() === 'zh' ? 'zh_CN' : 'en' });
  };
  if (window.google && window.google.accounts) return go2();
  const s = document.createElement('script');
  s.src = 'https://accounts.google.com/gsi/client'; s.async = true; s.onload = go2;
  document.head.append(s);
}

// -------------------------------------------------------------------------------------------------------------- router
function go(path) { location.hash = `#/${path}`; }

async function render() {
  nav();
  status('');
  if (!S.me) return login();
  const [path, qs] = (location.hash.slice(2) || 'home').split('?');
  const params = new URLSearchParams(qs || '');
  const [r, arg] = path.split('/');
  try {
    if (r === 'add') return await add();
    if (r === 'activity') return await activity(params);
    if (r === 'tx') return await tx(arg);
    if (r === 'review') return await review();
    if (r === 'confirm') return await confirm(arg, params);
    if (r === 'reports') return await reports();
    if (r === 'menu') return menu();
    if (r === 'task') return await task(decodeURIComponent(arg), params);
    if (r === 'settings') return await settings();
    if (r === 'documents') return await documents();
    if (r === 'handoff' && arg === 'prepare') return await handoffPrepare(params);
    if (r === 'handoff' && arg === 'import') return await handoffImport();
    if (r === 'handoff') return await handoff();
    if (r === 'consent') return await consentScreen(params);
    if (r === 'connections') return await connections();
    return await home();
  } catch (e) { fail(e); }
}

async function boot() {
  S.me = null; S.ledger = null;
  try { S.cfg = await api.config(); } catch { S.cfg = null; }
  try {
    S.me = await api.query('whoami');
    S.tier = TIER[S.me.role] || 0;
    const c = await api.catalog();
    S.cat = new Map(c.entries.map((e) => [e.core_function, e]));
    S.menu = S.menu || await (await fetch('/app/menu.json', { cache: 'no-cache' })).json();
  } catch (e) {
    S.me = null;
    if (e.code !== 'UNAUTHENTICATED') status(e.code === 'NETWORK' ? t('app.offline') : i18n.errorText(e), 'error');
  }
  render();
}

window.addEventListener('hashchange', () => { S.navigated = true; render(); });
// the skip link moves focus to the content without touching the hash (the hash is the router)
document.querySelector('.skip').addEventListener('click', (e) => { e.preventDefault(); main().focus(); });
window.addEventListener('online', () => document.body.classList.remove('offline'));
window.addEventListener('offline', () => document.body.classList.add('offline'));
await i18n.load();
if (!navigator.onLine) document.body.classList.add('offline');
if ('serviceWorker' in navigator) navigator.serviceWorker.register('/app/sw.js', { scope: '/app/' }).catch(() => {});
boot();
