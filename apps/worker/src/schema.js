// Copyright 2026 Walter Luo
// SPDX-License-Identifier: Apache-2.0
// Minimal JSON Schema validator for the bnx-tools/1.0 input schemas (CORE-7; UA V1.2 §8: "JSON-Schema validation of the
// body"). Supports exactly the keywords the catalog generator emits or an override may use: type (string or list),
// properties, required, additionalProperties (boolean or schema), enum, pattern, minLength, maxLength, minimum, maximum,
// items, minItems, maxItems, format (uuid, date, date-time). Unknown keywords are an error at load time, never ignored.
// The database stays the validator of record; this check rejects wrong shapes before a database round trip.
const KNOWN = new Set(['type', 'properties', 'required', 'additionalProperties', 'enum', 'pattern', 'minLength', 'maxLength',
  'minimum', 'maximum', 'items', 'minItems', 'maxItems', 'format', 'description']);     // description: annotation only (2.8)
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const DATETIME = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}(:?\d{2})?)?$/;

export class SchemaError extends Error {}

function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v;                                     // string, boolean, object
}

function typeMatches(v, t) {
  const actual = typeOf(v);
  return actual === t || (t === 'number' && actual === 'integer');
}

function validDate(s) {
  const m = DATE.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
}

export function checkSchema(schema, path = '$') {
  if (schema === true || schema === false) return;
  if (typeof schema !== 'object' || schema === null || Array.isArray(schema)) throw new SchemaError(`${path}: schema must be an object`);
  for (const k of Object.keys(schema)) if (!KNOWN.has(k)) throw new SchemaError(`${path}: unsupported keyword ${k}`);
  if (schema.pattern !== undefined) new RegExp(schema.pattern);           // throws on an invalid pattern
  for (const [k, s] of Object.entries(schema.properties || {})) checkSchema(s, `${path}.${k}`);
  if (typeof schema.additionalProperties === 'object') checkSchema(schema.additionalProperties, `${path}.*`);
  if (schema.items !== undefined) checkSchema(schema.items, `${path}[]`);
}

// returns null when valid, otherwise {path, reason} for the first violation found (deterministic order)
export function validate(schema, v, path = '$') {
  if (schema === true || schema === undefined) return null;
  if (schema === false) return { path, reason: 'not allowed' };
  if (schema.type !== undefined) {
    const ts = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!ts.some((t) => typeMatches(v, t))) return { path, reason: `type ${typeOf(v)}` };
  }
  if (schema.enum && !schema.enum.some((e) => e === v)) return { path, reason: 'enum' };
  if (typeof v === 'string') {
    if (schema.pattern !== undefined && !new RegExp(schema.pattern).test(v)) return { path, reason: 'pattern' };
    if (schema.minLength !== undefined && v.length < schema.minLength) return { path, reason: 'minLength' };
    if (schema.maxLength !== undefined && v.length > schema.maxLength) return { path, reason: 'maxLength' };
    if (schema.format === 'uuid' && !UUID.test(v)) return { path, reason: 'format uuid' };
    if (schema.format === 'date' && !validDate(v)) return { path, reason: 'format date' };
    if (schema.format === 'date-time' && !(DATETIME.test(v) && validDate(v.slice(0, 10)))) return { path, reason: 'format date-time' };
  }
  if (typeof v === 'number') {
    if (schema.minimum !== undefined && v < schema.minimum) return { path, reason: 'minimum' };
    if (schema.maximum !== undefined && v > schema.maximum) return { path, reason: 'maximum' };
  }
  if (Array.isArray(v)) {
    if (schema.minItems !== undefined && v.length < schema.minItems) return { path, reason: 'minItems' };
    if (schema.maxItems !== undefined && v.length > schema.maxItems) return { path, reason: 'maxItems' };
    if (schema.items !== undefined) {
      for (let i = 0; i < v.length; i++) { const e = validate(schema.items, v[i], `${path}[${i}]`); if (e) return e; }
    }
  }
  if (typeOf(v) === 'object') {
    for (const r of schema.required || []) if (!(r in v)) return { path: `${path}.${r}`, reason: 'required' };
    const props = schema.properties || {};
    for (const k of Object.keys(v).sort()) {
      if (k in props) { const e = validate(props[k], v[k], `${path}.${k}`); if (e) return e; }
      else if (schema.additionalProperties === false) return { path: `${path}.${k}`, reason: 'additional property' };
      else if (typeof schema.additionalProperties === 'object') { const e = validate(schema.additionalProperties, v[k], `${path}.${k}`); if (e) return e; }
    }
  }
  return null;
}
