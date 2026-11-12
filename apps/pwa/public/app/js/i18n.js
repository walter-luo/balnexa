// Bilingual catalogs (OR-U-06, OR-U-08): internal keys are English; the language changes display text only, never an
// identity, a balance or a calculation. The choice is a per-viewer convenience kept in localStorage when it is available.
const LANGS = { en: 'en', zh: 'zh-Hans' };
let lang = 'en', dict = {}, fallback = {};

function stored() {
  try { return localStorage.getItem('bnx.lang'); } catch { return null; }
}

export async function load(want) {
  const pick = want || stored() || ((navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en');
  lang = LANGS[pick] ? pick : 'en';
  const get = async (l) => (await fetch(`/app/i18n/${LANGS[l]}.json`, { cache: 'no-cache' })).json();
  fallback = await get('en');
  dict = lang === 'en' ? fallback : await get(lang);
  document.documentElement.lang = LANGS[lang];
  try { localStorage.setItem('bnx.lang', lang); } catch { /* private mode: per page only */ }
}

export const current = () => lang;
export const other = () => (lang === 'en' ? 'zh' : 'en');
export function t(key, vars = {}) {
  const s = dict[key] ?? fallback[key] ?? key;
  return s.replace(/\{(\w+)\}/g, (_, k) => (vars[k] ?? `{${k}}`));
}
export const has = (key) => key in dict || key in fallback;
export function errorText(e) {
  const code = e && e.code ? e.code : 'INTERNAL';
  return has(`error.${code}`) ? t(`error.${code}`, { field: e.field || '?' }) : t('error.generic', { code });
}
// field labels: an explicit catalog key, else the English key made readable
export const label = (name) => (has(`field.${name}`) ? t(`field.${name}`) : name.replace(/_/g, ' '));
export const fmtDate = (d) => d;               // ISO dates are shown as stored: the day never shifts with the viewer's zone (C-02)
