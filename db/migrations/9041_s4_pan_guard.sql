-- Copyright 2026 Walter Luo
-- SPDX-License-Identifier: Apache-2.0
-- 9041_s4_pan_guard.sql -- payment-card numbers are never stored; only the last 4 digits are kept (D-PAN-1).
-- Real card statements print the full card number (in the payment slip). The database, the single authority on what is
-- stored, now refuses a full card number (PAN) wherever the SIN guard sits, and in every command:
--   NEW bnx.pan_luhn, pan_scheme_ok, pan_is, pan_letter, pan_spans, pan_has, pan_mask, pan_json_has, pan_mask_json: detector
--          v1.0.0. Reference implementation and the algorithm: apps/executor/bnx_exec/pan_detector.py; the two are compared on
--          a generated corpus (AT-PAN-02). A candidate is a 13-19 digit number (one run, or the printed layouts 4-4-4-4,
--          4-4-4-4-3, 4-6-5, 4-6-4 with single spaces or hyphens) that passes the Luhn check and matches a card scheme's prefix
--          and length. A digit run touching an ASCII letter (hex digests, identifiers) or a decimal point is never one.
--   MODIFY bnx.idem_begin (0106): every command that stores data is refused (PAN_CANDIDATE) when any key, string or number of
--          its body holds a candidate, including fields its audit entry leaves out (register_evidence name, handoff_import text).
--   MODIFY bnx.audit (9011): the audited payload and subject are checked the same way (commands without idempotency, workers).
--   MODIFY bnx.stage_write (9011): index_consumed payloads are masked to the last 4 digits; every other staging kind is refused.
-- Refusals never echo the value. Every changed line of a MODIFY is marked "-- 9041"; the rest of each body is the latest
-- definition unchanged. No catalog delta: no catalog entry changes. No stored data changes (nothing stored is rescanned).
-- Authority: D-PAN-1 (DELEGATED_DECISION 2026-11-14, extends the SIN principle to card numbers; DRAFT until the Owner confirms);
-- docs/s4/S4_PAN_Guard_2026-11-14.md.
set role bnx_definer;


-- ---------- NEW payment-card number (PAN) detector, v1.0.0 (reference: apps/executor/bnx_exec/pan_detector.py) ----------
-- Luhn check over a string of ASCII digits
create function bnx.pan_luhn(d text) returns boolean
language sql immutable strict set search_path = pg_catalog, pg_temp as $$
  select coalesce(sum(case when i % 2 = 1 then case when x * 2 > 9 then x * 2 - 9 else x * 2 end else x end), 1) % 10 = 0
    from (select (ascii(substr(reverse(d), i + 1, 1)) - 48) x, i from generate_series(0, length(d) - 1) i) s
$$;

-- prefix and length match a card scheme (pan_detector.SCHEMES; the ranges are inclusive)
create function bnx.pan_scheme_ok(d text) returns boolean
language sql immutable strict set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from (values
      (4, 4, 1, array[13, 16, 19]), (51, 55, 2, array[16]), (2221, 2720, 4, array[16]), (34, 34, 2, array[15]), (37, 37, 2, array[15]),
      (6011, 6011, 4, array[16, 17, 18, 19]), (644, 649, 3, array[16, 17, 18, 19]), (65, 65, 2, array[16, 17, 18, 19]),
      (3528, 3589, 4, array[16, 17, 18, 19]), (62, 62, 2, array[16, 17, 18, 19]), (300, 305, 3, array[14, 15, 16, 17, 18, 19]),
      (36, 36, 2, array[14, 15, 16, 17, 18, 19]), (38, 39, 2, array[14, 15, 16, 17, 18, 19]), (50, 50, 2, array[16, 17, 18, 19]),
      (56, 58, 2, array[16, 17, 18, 19]), (63, 63, 2, array[16, 17, 18, 19]), (67, 67, 2, array[16, 17, 18, 19])) t(lo, hi, k, lens)
    where length(d) = any(lens) and length(d) >= k and left(d, k)::int between lo and hi)
$$;

create function bnx.pan_is(d text) returns boolean
language sql immutable strict set search_path = pg_catalog, pg_temp as $$
  select length(d) between 13 and 19 and bnx.pan_scheme_ok(d) and bnx.pan_luhn(d)
$$;

-- an ASCII letter (by code point: the result never depends on the database collation)
create function bnx.pan_letter(c text) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select c is not null and c <> '' and (ascii(c) between 65 and 90 or ascii(c) between 97 and 122)
$$;

-- candidate spans in normalize(p, NFKC): (a, b) 1-based, inclusive, in code points
create function bnx.pan_spans(p text) returns table(a int, b int)
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare n text; s text[]; g text[]; k int; att boolean[] := '{}'; pos int[] := '{}'; i int; j int; x int; lay int[]; ok boolean; d text;
        lays int[][] := array[array[4,4,4,4,0], array[4,4,4,4,3], array[4,6,5,0,0], array[4,6,4,0,0]]; L int;
begin
  if p is null or (octet_length(p) = length(p) and length(regexp_replace(p, '[^0-9]', '', 'g')) < 13) then return; end if;   -- ASCII fast path
  n := normalize(p, NFKC);
  if length(regexp_replace(n, '[^0-9]', '', 'g')) < 13 then return; end if;
  s := regexp_split_to_array(n, '[0-9]+');                 -- s[i] is the text before group i; s[k + 1] the text after the last
  g := array(select m[1] from regexp_matches(n, '([0-9]+)', 'g') m);
  k := coalesce(array_length(g, 1), 0);
  x := 1;
  for i in 1 .. k loop
    x := x + length(s[i]);
    pos := pos || x;                                        -- start of group i
    att := att || (bnx.pan_letter(right(s[i], 1)) or bnx.pan_letter(left(s[i + 1], 1))
                   or (i > 1 and s[i] in ('.', ',')) or (i < k and s[i + 1] in ('.', ',')));
    x := x + length(g[i]);
  end loop;
  for i in 1 .. k loop
    continue when att[i];
    if length(g[i]) between 13 and 19 and bnx.pan_is(g[i]) then
      a := pos[i]; b := pos[i] + length(g[i]) - 1; return next;
    end if;
    foreach lay slice 1 in array lays loop
      L := (select count(*) from unnest(lay) v where v > 0);
      continue when i + L - 1 > k;
      ok := true; d := '';
      for j in 0 .. L - 1 loop
        if att[i + j] or length(g[i + j]) <> lay[j + 1] or (j < L - 1 and s[i + j + 1] not in (' ', '-')) then ok := false; exit; end if;
        d := d || g[i + j];
      end loop;
      if ok and bnx.pan_is(d) then
        a := pos[i]; b := pos[i + L - 1] + length(g[i + L - 1]) - 1; return next;
      end if;
    end loop;
  end loop;
end $$;

create function bnx.pan_has(p text) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from bnx.pan_spans(p))
$$;

-- normalize(p, NFKC) with every digit of each candidate except its last 4 replaced by '*'; p unchanged when it has none
create function bnx.pan_mask(p text) returns text
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare n text; c text[]; r record; i int; dig int[];
begin
  if not bnx.pan_has(p) then return p; end if;
  n := normalize(p, NFKC);
  c := regexp_split_to_array(n, '');
  for r in select * from bnx.pan_spans(p) loop
    dig := array(select q from generate_series(r.a, r.b) q where c[q] ~ '^[0-9]$' order by q);
    for i in 1 .. coalesce(array_length(dig, 1), 0) - 4 loop c[dig[i]] := '*'; end loop;
  end loop;
  return array_to_string(c, '');
end $$;

-- any key, string or number of p holds a candidate (one whole-document fast path, then every key and scalar)
create function bnx.pan_json_has(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t text;
begin
  if p is null then return false; end if;
  t := p::text;
  if octet_length(t) = length(t) and length(regexp_replace(t, '[^0-9]', '', 'g')) < 13 then return false; end if;
  return exists (
    with recursive w(v) as (select p union all
      select x.value from w, lateral (select e.value from jsonb_each(case when jsonb_typeof(w.v) = 'object' then w.v end) e
                                      union all select e.value from jsonb_array_elements(case when jsonb_typeof(w.v) = 'array' then w.v end) e) x)
    select 1 from w where (jsonb_typeof(v) = 'string' and bnx.pan_has(v #>> '{}')) or (jsonb_typeof(v) = 'number' and bnx.pan_has(v::text))
                       or (jsonb_typeof(v) = 'object' and exists (select 1 from jsonb_object_keys(v) k where bnx.pan_has(k))));
end $$;

-- copy of p with each candidate masked to its last 4 digits (keys and strings; a number holding one becomes a string)
create function bnx.pan_mask_json(p jsonb) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare out jsonb; e record;
begin
  if not bnx.pan_json_has(p) then return p; end if;
  case jsonb_typeof(p)
  when 'object' then
    out := '{}';
    for e in select key, value from jsonb_each(p) loop out := out || jsonb_build_object(bnx.pan_mask(e.key), bnx.pan_mask_json(e.value)); end loop;
    return out;
  when 'array' then
    return coalesce((select jsonb_agg(bnx.pan_mask_json(value) order by o) from jsonb_array_elements(p) with ordinality x(value, o)), '[]');
  when 'string' then return to_jsonb(bnx.pan_mask(p #>> '{}'));
  else return to_jsonb(bnx.pan_mask(p::text));
  end case;
end $$;

-- ---------- MODIFY bnx.idem_begin (0106) ----------
create or replace function bnx.idem_begin(a bnx.actor, p_command text, p_cmd jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare k text := p_cmd->>'idempotency_key'; req bytea; r record;
begin
  if k is null or length(k) < 8 or length(k) > 80 then perform bnx.fail('IDEMPOTENCY_KEY_REQUIRED', 'P0422'); end if;
  -- 9041: a payment-card number anywhere in a command refuses it before anything is stored; the value is never echoed. This is
  -- every command that stores data, including the fields its audit entry leaves out (register_evidence name, handoff text)
  if bnx.pan_json_has(p_cmd) then perform bnx.fail('PAN_CANDIDATE', 'P0422', p_command); end if;   -- 9041
  perform pg_advisory_xact_lock(hashtext('idem:' || a.member_id || ':' || k));
  req := bnx.h(p_command || '|' || (p_cmd - 'idempotency_key')::text);
  select * into r from bnx.idempotency where member_id = a.member_id and idem_key = k;
  if found then
    if r.request_sha256 = req and r.command = p_command then return r.receipt || '{"replayed": true}'::jsonb; end if;
    perform bnx.fail('IDEMPOTENCY_CONFLICT', 'P0409');
  end if;
  return null;
end $$;

-- ---------- MODIFY bnx.audit (9011) ----------
create or replace function bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev bytea; s bigint; ph bytea := bnx.h(coalesce(p_payload,'{}'::jsonb)::text); t timestamptz := now();
        hp text := bnx.envelope_value('host_profile'); tn text := bnx.envelope_value('tool_name');
        tv text := bnx.envelope_value('tool_version'); tr text := bnx.envelope_value('trace_id');
begin
  -- 9011 (Addendum A1 Rev 1 guard C2, DELEGATED_DECISION D-9011a-3): a SIN or ITN candidate anywhere in an audited payload or
  -- subject refuses the command; nothing is stored or hashed, and the value is never echoed
  if bnx.sin_json_has(p_payload) or bnx.sin_json_has(p_subject) then
    perform bnx.fail('SIN_CANDIDATE', 'P0422', p_command);
  end if;
  if bnx.pan_json_has(p_payload) or bnx.pan_json_has(p_subject) then perform bnx.fail('PAN_CANDIDATE', 'P0422', p_command); end if;   -- 9041
  perform pg_advisory_xact_lock(hashtext('bnx.audit'));
  select seq, hash into s, prev from bnx_audit.audit_event order by seq desc limit 1;
  s := coalesce(s, 0) + 1;
  insert into bnx_audit.audit_event(seq, at, member_id, connection_id, channel, command, subject, payload_sha256, ledger_version, prev_hash,
                              hash, chain_version, at_hashed, host_profile, tool_name, tool_version, trace_id)
  values (s, t, a.member_id, a.connection_id, coalesce(a.channel,'system'), p_command, p_subject, ph, p_version, prev,
          sha256(coalesce(prev, '\x'::bytea) || bnx.audit_canonical_v2(s, a.member_id, a.connection_id, coalesce(a.channel,'system'),
                 p_command, p_subject, encode(ph,'hex'), p_version, t, 2::smallint, hp, tn, tv, tr)),
          2, t, hp, tn, tv, tr);
  return s;
end $$;

-- ---------- MODIFY bnx.stage_write (9011) ----------
create or replace function bnx.stage_write(p_nonce text, p_kind text, p_payload jsonb, p_via text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare l record; sid uuid; ph bytea;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 262144 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'staging payload (object, <= 256 KiB)'); end if;
  if bnx.stage_jobs(p_kind) is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'staging kind'); end if;
  -- 9011 DOC-SIN-10 (DELEGATED_DECISION D-9011a-2): index records are masked here so that the consumer can block the affected
  -- records without the value ever being staged; every other kind is refused (the Executor quarantines before staging)
  if p_kind = 'index_consumed' then
    p_payload := bnx.sin_mask_json(p_payload);
  elsif bnx.sin_json_has(p_payload) then
    perform bnx.fail('SIN_CANDIDATE', 'P0422', 'staging payload ' || p_kind);
  end if;
  -- 9041: payment-card numbers. Index records keep the last 4 digits only (the Owner's index rule); every other kind is refused
  if p_kind = 'index_consumed' then                                                                    -- 9041
    p_payload := bnx.pan_mask_json(p_payload);                                                         -- 9041
  elsif bnx.pan_json_has(p_payload) then                                                               -- 9041
    perform bnx.fail('PAN_CANDIDATE', 'P0422', 'staging payload ' || p_kind);                          -- 9041
  end if;                                                                                              -- 9041
  select * into l from bnx.exec_lease where nonce = bnx.h(coalesce(p_nonce, '')) for update;
  if not found then perform bnx.fail('LEASE_INVALID', 'P0401'); end if;
  if l.completed_at is not null then perform bnx.fail('LEASE_USED', 'P0409'); end if;
  if l.expires_at <= now() then perform bnx.fail('LEASE_EXPIRED', 'P0401'); end if;
  if not (l.job_kind = any(bnx.stage_jobs(p_kind))) then perform bnx.fail('LEASE_KIND_MISMATCH', 'P0403', l.job_kind || ' -> ' || p_kind); end if;
  -- field allowlist for the kinds promoted here (the Gateway validates the full JSON Schema; mail subject/body never staged)
  if p_kind in ('index_consumed','mail_fetched') and exists (select 1 from jsonb_object_keys(p_payload) k where not k = any(case p_kind
       when 'index_consumed' then array['source_id','header','records','open_items','coverage','availability','run_log']
       else array['op','source_ref','canonical_key_sha256','message_id','provider_message_id','folder_ref','received_at','sender_domain',
                  'content_class','attachments_expected','attachments_fetched','evidence_sha256','ok'] end)) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'unknown staging field for ' || p_kind); end if;
  ph := bnx.h(p_payload::text);
  insert into bnx_intake.staging_payload(lease_id, stg_kind, payload, payload_sha256, staged_by)
  values (l.lease_id, p_kind, p_payload, ph, p_via) returning id into sid;
  update bnx.exec_lease set completed_at = now(), completion_sha256 = ph where lease_id = l.lease_id;
  perform bnx.enqueue('staging.promote', jsonb_build_object('staging_id', sid));
  return jsonb_build_object('staging_id', sid, 'state', 'STAGED', 'queue_generation', (select generation from bnx.queue_state));
end $$;

select bnx.apply_grants();
