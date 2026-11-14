// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// SIN/ITN candidate detector — Worker implementation (Addendum A1 Rev 1 §3; spec/sin-detector/sin_detector_v1.json).
// Same algorithm as apps/executor/bnx_exec/sin_detector.py and bnx.sin_scan (migration 9011) for origins 'native' and
// 'typed'. 'ocr' is refused here (only the Executor performs OCR). Hits are {rule, start, end} in code-point positions of
// the original text; values are never returned or logged.
import SPEC from '../../../spec/sin-detector/sin_detector_v1.json' with { type: 'json' };

export const VERSION = SPEC.version;
export const MASK = SPEC.mask;

const IGN_LO = SPEC.ignorable_ranges.map((r) => r[0]);
const IGN_HI = SPEC.ignorable_ranges.map((r) => r[1]);
const WS = new Set(SPEC.whitespace.map((c) => String.fromCodePoint(c)));
const LB = new Set(SPEC.line_breaks.map((c) => String.fromCodePoint(c)));
const HARD = new Set(SPEC.hard_separators.map((c) => String.fromCodePoint(c)));
const APOS = new Set(SPEC.apostrophes.map((c) => String.fromCodePoint(c)));
const DIGIT = new Map();
for (const z of SPEC.nd_zeros) for (let d = 0; d < 10; d++) DIGIT.set(String.fromCodePoint(z + d), String(d));
for (const [cp, d] of SPEC.digit_map) DIGIT.set(String.fromCodePoint(cp), String(d));
const SQ = SPEC.sequence;
const LINK_STRICT = new RegExp(SQ.link_strict_regex, 'u');
const LINK_LOOSE = new RegExp(SQ.link_loose_regex, 'u');
const BN15 = new RegExp(SPEC.bn15_suffix_regex, 'uy');
const HEX_VALUE = new RegExp(SPEC.hex_exempt.value_regex, 'u');
const HEX_KEYS = new Set(SPEC.hex_exempt.key_tokens);
const UUID = new RegExp(SPEC.uuid_regex, 'gu');
const LABELS = SPEC.labels.map((l) => [new RegExp(l.pattern, 'gu'), l.word_start, l.word_end]);
const KEY_TOKENS = SPEC.key_tokens;
const KEY_SPLIT = new Set(SPEC.key_split_chars.map((c) => String.fromCodePoint(c)));
const isDigit = (c) => c !== undefined && c >= '0' && c <= '9';
const isAsciiLetter = (c) => c !== undefined && /^[A-Za-z]$/.test(c);

export function ignorable(ch) {
  const cp = ch.codePointAt(0);
  if (cp < 0xad) return false;
  let lo = 0, hi = IGN_LO.length - 1, k = -1;
  while (lo <= hi) { const m = (lo + hi) >> 1; if (IGN_LO[m] <= cp) { k = m; lo = m + 1; } else hi = m - 1; }
  return k >= 0 && cp <= IGN_HI[k];
}

// normalized text as a code-point array, the original code-point index of each character, and whether it was a line break
export function normalize(s, lines = false) {
  const out = [], idx = [], brk = [];
  Array.from(s).forEach((ch, i) => {
    if (ignorable(ch)) return;
    for (let c of Array.from(ch.normalize('NFKC'))) {
      if (ignorable(c)) continue;
      c = DIGIT.get(c) ?? c;
      const b = LB.has(c);
      if (WS.has(c)) c = ' ';
      out.push(c); idx.push(i); brk.push(b);
    }
  });
  return lines ? [out, idx, brk] : [out, idx];
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

function near(i, j, spans, n, brk) {
  const wa = SPEC.label_window_after, wb = SPEC.label_window_before, lm = SPEC.label_line_max;
  for (const [a, b] of spans) {
    if ((b <= i && i - b <= wa) || (j <= a && a - j <= wb) || (a < j && i < b)) return true;
    if (b <= i && i - b <= lm) {
      const br = [];
      for (let k = b; k < i; k++) if (brk[k]) br.push(k);
      if (!br.length || n.slice(br[0], br[br.length - 1] + 1).every((c) => c === ' ')) return true;
    }
    if (j <= a && a - j <= lm) {
      let any = false;
      for (let k = j; k < a; k++) if (brk[k]) { any = true; break; }
      if (!any) return true;
    }
  }
  return false;
}

// windows of linked digit groups holding exactly nine digits (v1.1): [i, j, digits, okFree, okNear, ngroups]
export function windows(n, orig = null, idx = null) {
  const g = [];
  for (let k = 0; k < n.length;) {
    if (isDigit(n[k])) { const a = k; while (k < n.length && isDigit(n[k])) k++; g.push([a, k]); } else k++;
  }
  const link = [];
  for (let k = 0; k + 1 < g.length; k++) {
    const sep = n.slice(g[k][1], g[k + 1][0]).join('');
    if (LINK_STRICT.test(sep)) {
      let hard = false;
      if (orig) for (let q = g[k][1]; q < g[k + 1][0]; q++) if (HARD.has(orig[idx[q]])) { hard = true; break; }
      link.push(hard ? 'L' : 'S');
    } else link.push(LINK_LOOSE.test(sep) ? 'L' : null);
  }
  const res = [];
  for (let a = 0; a < g.length; a++) {
    let tot = 0, allS = true, mn = 99, mx = 0;
    for (let b = a; b < g.length; b++) {
      if (b > a) { if (link[b - 1] === null) break; allS = allS && link[b - 1] === 'S'; }
      const ln = g[b][1] - g[b][0];
      tot += ln; mn = Math.min(mn, ln); mx = Math.max(mx, ln);
      if (tot > SQ.digits) break;
      if (tot === SQ.digits) {
        const ng = b - a + 1;
        const d = g.slice(a, b + 1).map(([x, y]) => n.slice(x, y).join('')).join('');
        const f333 = ng === 3 && mn === 3 && mx === 3;
        const okFree = (allS && ng <= SQ.strict_max_groups && mn >= SQ.strict_min_group) || f333;
        res.push([g[a][0], g[b][1], d, okFree, allS || f333, ng]);
      }
    }
  }
  return res;
}

export function scan(text, origin = 'native', forceLabel = false) {
  if (!SPEC.origins_sql_js.includes(origin)) throw new Error('SIN_DETECTOR_ORIGIN');
  if (text === null || text === undefined) return [];
  const orig = Array.from(String(text));
  const [n, idx, brk] = normalize(String(text), true);
  if (n.filter(isDigit).length < SQ.digits) return [];
  const S = cpIndex(n);
  const spans = labelSpans(n.map(foldChar));
  const uu = allMatches(UUID, S);
  const hits = [];
  for (const [i, j, d, ok, okNear, ng] of windows(n, orig, idx)) {
    if (!okNear) continue;
    if (ng > 1 && uu.some(([a, b]) => a <= i && j <= b)) continue;
    const isNear = forceLabel || near(i, j, spans, n, brk);
    if (!(ok || isNear)) continue;
    let rule;
    if (isNear) rule = 'R_LABEL';
    else if (ng === 1 && !(i > 0 && isAsciiLetter(n[i - 1])) && (BN15.lastIndex = S.u16(j), BN15.exec(S.str))) continue;
    else if (luhn(d)) rule = 'R_MOD10';
    else if (SPEC.itn_prefixes.includes(d.slice(0, 2))) rule = 'R_ITN';
    else continue;
    hits.push({ rule, start: idx[i], end: idx[j - 1] + 1 });
  }
  hits.sort((x, y) => x.start - y.start || x.end - y.end || (x.rule < y.rule ? -1 : x.rule > y.rule ? 1 : 0));
  return hits.filter((h, k) => k === 0 || h.start !== hits[k - 1].start || h.end !== hits[k - 1].end || h.rule !== hits[k - 1].rule);
}

export const candidate = (text, origin = 'native') => scan(text, origin).length > 0;

export function keySplit(key, digits = true) {
  let k = String(key ?? '');
  k = k.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2');
  if (digits) k = k.replace(/([A-Za-z])([0-9])/g, '$1 $2').replace(/([0-9])([A-Za-z])/g, '$1 $2');
  const f = normalize(k)[0].map(foldChar).map((c) => (KEY_SPLIT.has(c) ? ' ' : c)).join('');
  return f.split(' ').filter(Boolean);
}

export function keyIsLabel(key) {
  const toks = keySplit(key);
  const hit = KEY_TOKENS.some((pat) => {
    for (let s = 0; s + pat.length <= toks.length; s++) if (pat.every((t, q) => toks[s + q] === t)) return true;
    return false;
  });
  return hit || labelSpans(Array.from(toks.join(' '))).length > 0;
}

export function keyIsHex(key) {
  const toks = keySplit(key, false);
  return toks.length > 0 && HEX_KEYS.has(toks[toks.length - 1]);
}

const hexExempt = (s, hexkey, labelled) => hexkey && !labelled && HEX_VALUE.test(s);

const numText = (v) => JSON.stringify(v);

export function scanJson(v, origin = 'native', path = '$', labelled = false, hexkey = false) {
  const out = [];
  if (Array.isArray(v)) v.forEach((x, i) => out.push(...scanJson(x, origin, `${path}[${i}]`, labelled, hexkey)));
  else if (v !== null && typeof v === 'object') {
    for (const [k, x] of Object.entries(v)) {
      const p = `${path}.${k}`;
      for (const h of scan(k, origin)) out.push({ ...h, path: p, part: 'key' });
      out.push(...scanJson(x, origin, p, labelled || keyIsLabel(k), keyIsHex(k)));
    }
  } else if (typeof v === 'string' || typeof v === 'number') {
    if (typeof v === 'string' && hexExempt(v, hexkey, labelled)) return out;
    for (const h of scan(typeof v === 'string' ? v : numText(v), origin, labelled)) out.push({ ...h, path, part: 'value' });
  }
  return out;
}

export function maskJson(v, origin = 'native', labelled = false, hexkey = false) {
  if (Array.isArray(v)) return v.map((x) => maskJson(x, origin, labelled, hexkey));
  if (v !== null && typeof v === 'object') {
    const out = {};
    for (const [k, x] of Object.entries(v)) {
      let nk = scan(k, origin).length ? MASK : k;
      if (nk in out) nk = `${nk}#${Object.keys(out).length}`;
      out[nk] = maskJson(x, origin, labelled || keyIsLabel(k), keyIsHex(k));
    }
    return out;
  }
  if (typeof v === 'string' || typeof v === 'number') {
    if (typeof v === 'string' && hexExempt(v, hexkey, labelled)) return v;
    return scan(typeof v === 'string' ? v : numText(v), origin, labelled).length ? MASK : v;
  }
  return v;
}

// guard C3: a log line with every candidate replaced by the mask (positions are code points of the original text)
export function scrub(text) {
  const s = String(text ?? '');
  const hits = scan(s);
  if (!hits.length) return s;
  const cps = Array.from(s), out = [];
  let k = 0;
  for (const h of hits) {
    if (h.start < k) continue;
    out.push(cps.slice(k, h.start).join(''), MASK);
    k = h.end;
  }
  out.push(cps.slice(k).join(''));
  return out.join('');
}
