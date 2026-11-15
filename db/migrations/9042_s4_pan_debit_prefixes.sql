-- Copyright 2026 Walter Luo
-- SPDX-License-Identifier: Apache-2.0
-- 9042_s4_pan_debit_prefixes.sql -- OD-PAN-1: card-number detector v1.1.0.
-- The Owner confirmed D-PAN-1 on 2026-11-15 with one change: debit card prefixes differ by bank and are not to be fixed.
-- v1.0.0 accepted a 16-19 digit number only for listed prefixes (Visa, Mastercard, Discover, JCB, UnionPay, Diners and the
-- debit prefixes 50, 56-58, 63, 67). v1.1.0 accepts any 16-19 digit number that passes the Luhn check, whatever its prefix;
-- the prefix table still decides 13-15 digit numbers (Visa 13, Diners 14-15, Amex 15). Layouts, the attached-digit rule and
-- the Luhn check are unchanged.
--   MODIFY bnx.pan_scheme_ok (9041): the four debit rows become one row for any prefix, 16-19 digits.
--   MODIFY bnx.pan_json_has, pan_mask_json (9041): a scalar directly under the machine-identifier keys generation and
--          object_generation (a storage object generation: microseconds, 16 digits) is not scanned. With any 16-19 digit
--          Luhn number counting, one generation in ten would otherwise refuse a VERIFIED backup result.
-- Reference implementation: apps/executor/bnx_exec/pan_detector.py (VERSION 1.1.0); parity: AT-PAN-02. Every changed line is
-- marked "-- 9042". No catalog delta; no stored data changes. Authority: OD-PAN-1 (docs/s4/OWNER_DECISIONS_2026-11-15.md).
set role bnx_definer;

-- ---------- MODIFY bnx.pan_scheme_ok (9041) ----------
create or replace function bnx.pan_scheme_ok(d text) returns boolean
language sql immutable strict set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from (values
      (4, 4, 1, array[13, 16, 19]), (51, 55, 2, array[16]), (2221, 2720, 4, array[16]), (34, 34, 2, array[15]), (37, 37, 2, array[15]),
      (6011, 6011, 4, array[16, 17, 18, 19]), (644, 649, 3, array[16, 17, 18, 19]), (65, 65, 2, array[16, 17, 18, 19]),
      (3528, 3589, 4, array[16, 17, 18, 19]), (62, 62, 2, array[16, 17, 18, 19]), (300, 305, 3, array[14, 15, 16, 17, 18, 19]),
      (36, 36, 2, array[14, 15, 16, 17, 18, 19]), (38, 39, 2, array[14, 15, 16, 17, 18, 19]),   -- 9042
      (0, 9, 1, array[16, 17, 18, 19])) t(lo, hi, k, lens)   -- 9042 OD-PAN-1: any prefix for 16-19 digits (was debit 50, 56-58, 63, 67)
    where length(d) = any(lens) and length(d) >= k and left(d, k)::int between lo and hi)
$$;

-- ---------- MODIFY bnx.pan_json_has (9041) ----------
-- 9042: a scalar directly under a machine-identifier key (generation, object_generation: a storage object generation is its
-- creation time in microseconds, 16 digits) is not scanned; with any 16-19 digit Luhn number counting, one generation in
-- ten would otherwise be refused. The key itself is still scanned. Reference: pan_detector.EXEMPT_KEYS.
create or replace function bnx.pan_json_has(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t text;
begin
  if p is null then return false; end if;
  t := p::text;
  if octet_length(t) = length(t) and length(regexp_replace(t, '[^0-9]', '', 'g')) < 13 then return false; end if;
  return exists (
    with recursive w(v, k) as (select p, null::text union all                                                          -- 9042
      select x.value, x.key from w, lateral (select e.key, e.value from jsonb_each(case when jsonb_typeof(w.v) = 'object' then w.v end) e   -- 9042
                                      union all select null, e.value from jsonb_array_elements(case when jsonb_typeof(w.v) = 'array' then w.v end) e) x)   -- 9042
    select 1 from w where ((jsonb_typeof(v) = 'string' and bnx.pan_has(v #>> '{}')) or (jsonb_typeof(v) = 'number' and bnx.pan_has(v::text)))
                          and (k is null or k not in ('generation', 'object_generation'))                              -- 9042
                       or (jsonb_typeof(v) = 'object' and exists (select 1 from jsonb_object_keys(v) k where bnx.pan_has(k))));
end $$;

-- ---------- MODIFY bnx.pan_mask_json (9041) ----------
create or replace function bnx.pan_mask_json(p jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare out jsonb; e record;
begin
  if not bnx.pan_json_has(p) then return p; end if;
  case jsonb_typeof(p)
  when 'object' then
    out := '{}';
    for e in select key, value from jsonb_each(p) loop
      out := out || jsonb_build_object(bnx.pan_mask(e.key),
                      case when e.key in ('generation', 'object_generation') and jsonb_typeof(e.value) not in ('object', 'array')   -- 9042
                           then e.value else bnx.pan_mask_json(e.value) end);                                                   -- 9042
    end loop;
    return out;
  when 'array' then
    return coalesce((select jsonb_agg(bnx.pan_mask_json(value) order by o) from jsonb_array_elements(p) with ordinality x(value, o)), '[]');
  when 'string' then return to_jsonb(bnx.pan_mask(p #>> '{}'));
  else return to_jsonb(bnx.pan_mask(p::text));
  end case;
end $$;

select bnx.apply_grants();
