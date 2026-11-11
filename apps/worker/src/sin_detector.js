// SIN/ITN candidate detector — Worker implementation (Addendum A1 Rev 1 §3; spec/sin-detector/sin_detector_v1.json).
// Same algorithm as apps/executor/bnx_exec/sin_detector.py and bnx.sin_scan (migration 9011) for origins 'native' and
// 'typed'. 'ocr' is refused here (only the Executor performs OCR). Hits are {rule, start, end} in code-point positions of
// the original text; values are never returned or logged.
import SPEC from '../../../spec/sin-detector/sin_detector_v1.json' with { type: 'json' };

export const VERSION = SPEC.version;
export const MASK = SPEC.mask;

const ZW = new Set(SPEC.zero_width.map((c) => String.fromCodePoint(c)));
const WS = new Set(SPEC.whitespace.map((c) => String.fromCodePoint(c)));
const APOS = new Set(SPEC.apostrophes.map((c) => String.fromCodePoint(c)));
const DIGIT = new Map();
for (const z of SPEC.nd_zeros) for (let d = 0; d < 10; d++) DIGIT.set(String.fromCodePoint(z + d), String(d));
const SEQ = new RegExp(SPEC.sequence_regex, 'uy');
const BN15 = new RegExp(SPEC.bn15_suffix_regex, 'uy');
const UUID = new RegExp(SPEC.uuid_regex, 'gu');
const HEX = new RegExp(`[0-9A-Fa-f]{${SPEC.hex_token_min},}`, 'gu');
const LABELS = SPEC.labels.map((l) => [new RegExp(l.pattern, 'gu'), l.word_start, l.word_end]);
const KEY_TOKENS = SPEC.key_tokens;
const isDigit = (c) => c !== undefined && c >= '0' && c <= '9';
const isAsciiLetter = (c) => c !== undefined && /^[A-Za-z]$/.test(c);

export function normalize(s) {
  const out = [], idx = [];
  Array.from(s).forEach((ch, i) => {
    if (ZW.has(ch)) return;
    for (let c of Array.from(ch.normalize('NFKC'))) {
      if (ZW.has(c)) continue;
      c = DIGIT.get(c) ?? c;
      if (WS.has(c)) c = ' ';
      out.push(c); idx.push(i);
    }
  });
  return [out, idx];
}

function foldChar(c) {
  if (APOS.has(c)) return "'";
  const d = Array.from(c.normalize('NFD'));
  const b = Array.from((d.length ? d[0] : c).toLowerCase());
  return b[0];
}

export function luhn(d) {
  let t = 0;
  for (let k = 0; k < d.length; k++) {
    let v = d.charCodeAt(d.length - 1 - k) - 48;
    if (k % 2) { v *= 2; if (v > 9) v -= 9; }
    t += v;
  }
  return t % 10 === 0;
}

// regex helpers over a code-point array: run on the joined string, translate UTF-16 offsets to code-point offsets
function cpIndex(arr) {
  const m = new Array(arr.join('').length + 1);
  let u = 0;
  arr.forEach((c, k) => { m[u] = k; u += c.length; });
  m[u] = arr.length;
  const off = new Array(arr.length + 1);
  let o = 0;
  arr.forEach((c, k) => { off[k] = o; o += c.length; });
  off[arr.length] = o;
  return { str: arr.join(''), cp: m, u16: (k) => off[k] };
}

function allMatches(rx, S) {
  const res = [];
  rx.lastIndex = 0;
  let m;
  while ((m = rx.exec(S.str)) !== null) {
    res.push([S.cp[m.index], S.cp[m.index + m[0].length]]);
    if (m[0].length === 0) rx.lastIndex++;
  }
  return res;
}

function labelSpans(f) {
  const S = cpIndex(f), spans = [];
  for (const [rx, ws, we] of LABELS) {
    for (const [a, b] of allMatches(rx, S)) {
      if (ws && a > 0 && isAsciiLetter(foldAt(f, a - 1))) continue;
      if (we && b < f.length && isAsciiLetter(foldAt(f, b))) continue;
      spans.push([a, b]);
    }
  }
  return spans;
}
const foldAt = (f, k) => f[k];

function near(i, j, spans) {
  const wa = SPEC.label_window_after, wb = SPEC.label_window_before;
  return spans.some(([a, b]) => (b <= i && i - b <= wa) || (j <= a && a - j <= wb) || (a < j && i < b));
}

export function scan(text, origin = 'native', forceLabel = false) {
  if (!SPEC.origins_sql_js.includes(origin)) throw new Error('SIN_DETECTOR_ORIGIN');
  if (text === null || text === undefined) return [];
  const [n, idx] = normalize(String(text));
  const S = cpIndex(n);
  const spans = labelSpans(n.map(foldChar));
  const hexes = [...allMatches(HEX, S), ...allMatches(UUID, S)];
  const hits = [];
  for (let i = 0; i < n.length; i++) {
    if (!isDigit(n[i]) || (i > 0 && isDigit(n[i - 1]))) continue;
    SEQ.lastIndex = S.u16(i);
    const m = SEQ.exec(S.str);
    if (!m) continue;
    const j = S.cp[m.index + m[0].length];
    const d = m[0].replace(/[^0-9]/g, '');
    const isNear = forceLabel || near(i, j, spans);
    let rule;
    if (hexes.some(([a, b]) => a <= i && i < b)) continue; // starts inside a hash or UUID token: labels do not apply (D-9011a-1)
    if (isNear) rule = 'R_LABEL';
    else if (j - i === 9 && !(i > 0 && isAsciiLetter(n[i - 1])) && (BN15.lastIndex = S.u16(j), BN15.exec(S.str))) continue;
    else if (luhn(d)) rule = 'R_MOD10';
    else if (SPEC.itn_prefixes.includes(d.slice(0, 2))) rule = 'R_ITN';
    else continue;
    hits.push({ rule, start: idx[i], end: idx[j - 1] + 1 });
  }
  hits.sort((x, y) => x.start - y.start || x.end - y.end || (x.rule < y.rule ? -1 : x.rule > y.rule ? 1 : 0));
  return hits;
}

export const candidate = (text, origin = 'native') => scan(text, origin).length > 0;

export function keyIsLabel(key) {
  const k = String(key ?? '').replace(/([a-z0-9])([A-Z])/g, '$1 $2');
  const toks = normalize(k)[0].map(foldChar).join('').split(/[\s_\-.]+/u).filter(Boolean);
  return KEY_TOKENS.some((pat) => {
    for (let s = 0; s + pat.length <= toks.length; s++) if (pat.every((t, q) => toks[s + q] === t)) return true;
    return false;
  });
}

const numText = (v) => JSON.stringify(v);

export function scanJson(v, origin = 'native', path = '$', labelled = false) {
  const out = [];
  if (Array.isArray(v)) v.forEach((x, i) => out.push(...scanJson(x, origin, `${path}[${i}]`, labelled)));
  else if (v !== null && typeof v === 'object') {
    for (const [k, x] of Object.entries(v)) {
      const p = `${path}.${k}`;
      for (const h of scan(k, origin)) out.push({ ...h, path: p, part: 'key' });
      out.push(...scanJson(x, origin, p, labelled || keyIsLabel(k)));
    }
  } else if (typeof v === 'string' || typeof v === 'number') {
    for (const h of scan(typeof v === 'string' ? v : numText(v), origin, labelled)) out.push({ ...h, path, part: 'value' });
  }
  return out;
}

export function maskJson(v, origin = 'native', labelled = false) {
  if (Array.isArray(v)) return v.map((x) => maskJson(x, origin, labelled));
  if (v !== null && typeof v === 'object') {
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      let nk = scan(k, origin).length ? MASK : k;
      if (nk in out) nk = `${nk}#${Object.keys(out).length}`;
      out[nk] = maskJson(x, origin, labelled || keyIsLabel(k));
    }
    return out;
  }
  if (typeof v === 'string' || typeof v === 'number') {
    return scan(typeof v === 'string' ? v : numText(v), origin, labelled).length ? MASK : v;
  }
  return v;
}
