-- 9011 (S4 V1.2, WP-DOC): documents, evidence, renditions. Increment 9011a: the SIN/ITN detector and the database guards.
-- Addendum A1 Rev 1 (branch s4/design-addendum-a1): §3 detector (guard C1), §7 DOC-SIN-10, guard C2. Later increments of this
-- work package (9011b intake states and declaration, 9011c Executor validators) extend this file before it is merged.
-- Synthetic data only. No function here is granted to a runtime role; they run inside SECURITY DEFINER callers.
--
-- MODIFY (bodies copied from their last version and changed only where marked "9011"):
--   bnx.audit                      (9005)  refuses SIN/ITN candidates in payload and subject (D-9011a-3)
--   bnx.stage_write                (9010)  masks index payloads, refuses other kinds (DOC-SIN-10, D-9011a-2)
--   bnx.wrk_consume_shared_index   (9010)  blocks masked records, stores no columns for them (DOC-SIN-10)

-- ---------- SIN/ITN detector (Addendum A1 Rev 1 §3; guard C1; spec/sin-detector/sin_detector_v1.json) ----------
-- Same algorithm as apps/executor/bnx_exec/sin_detector.py and apps/worker/src/sin_detector.js for origins 'native' and
-- 'typed' ('ocr' exists only in the Executor). Values are never returned, logged or stored: a hit is {rule, start, end}
-- in 0-based code-point positions of the original text. Internal functions: no runtime role holds EXECUTE on them.

create function bnx.sin_detector_spec() returns jsonb
language sql immutable set search_path = pg_catalog, pg_temp as $f$ select $spec${"spec":"bnx-sin-detector","version":"1.0.0","source":"Addendum A1 Rev 1 §3 (S4 V1.2); Owner decisions A1-OD-1 (2026-11-10) and DELEGATED_DECISION D-A1-1..4","unicode_version":"15.1.0","origins":["native","typed","ocr"],"origins_sql_js":["native","typed"],"zero_width":[8203,8204,8205,8288,65279,173],"whitespace":[9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8232,8233,8239,8287,12288],"dash_separators":[45,8208,8209,8210,8211,8212,8213],"apostrophes":[8217,8216,700],"nd_zeros":[48,1632,1776,1984,2406,2534,2662,2790,2918,3046,3174,3302,3430,3558,3664,3792,3872,4160,4240,6112,6160,6470,6608,6784,6800,6992,7088,7232,7248,42528,43216,43264,43472,43504,43600,44016,65296,66720,68912,69734,69872,69942,70096,70384,70736,70864,71248,71360,71472,71904,72016,72784,73040,73120,73552,92768,92864,93008,120782,120792,120802,120812,120822,123200,123632,124144,125264,130032],"sequence_regex":"[0-9]{3}(?: +|[-‐-―])?[0-9]{3}(?: +|[-‐-―])?[0-9]{3}(?![0-9])","label_window_after":64,"label_window_before":32,"labels":[{"lang":"en","label":"SIN","kind":"sin","folded":"sin","pattern":"sin","word_start":true,"word_end":true},{"lang":"en","label":"S.I.N.","kind":"sin","folded":"s.i.n.","pattern":"s\\.i\\.n\\.","word_start":true,"word_end":false},{"lang":"en","label":"Social Insurance Number","kind":"sin","folded":"social insurance number","pattern":"social +insurance +number","word_start":true,"word_end":true},{"lang":"en","label":"Social Insurance No","kind":"sin","folded":"social insurance no","pattern":"social +insurance +no","word_start":true,"word_end":true},{"lang":"en","label":"Social Insurance #","kind":"sin","folded":"social insurance #","pattern":"social +insurance +#","word_start":true,"word_end":false},{"lang":"en","label":"Soc. Ins. No","kind":"sin","folded":"soc. ins. no","pattern":"soc\\. +ins\\. +no","word_start":true,"word_end":true},{"lang":"en","label":"Individual Tax Number","kind":"itn","folded":"individual tax number","pattern":"individual +tax +number","word_start":true,"word_end":true},{"lang":"en","label":"ITN","kind":"itn","folded":"itn","pattern":"itn","word_start":true,"word_end":true},{"lang":"fr","label":"NAS","kind":"sin","folded":"nas","pattern":"nas","word_start":true,"word_end":true},{"lang":"fr","label":"N.A.S.","kind":"sin","folded":"n.a.s.","pattern":"n\\.a\\.s\\.","word_start":true,"word_end":false},{"lang":"fr","label":"numéro d'assurance sociale","kind":"sin","folded":"numero d'assurance sociale","pattern":"numero +d'assurance +sociale","word_start":true,"word_end":true},{"lang":"fr","label":"no d'assurance sociale","kind":"sin","folded":"no d'assurance sociale","pattern":"no +d'assurance +sociale","word_start":true,"word_end":true},{"lang":"fr","label":"n° d'assurance sociale","kind":"sin","folded":"n° d'assurance sociale","pattern":"n° +d'assurance +sociale","word_start":true,"word_end":true},{"lang":"zh-Hans","label":"社会保险号","kind":"sin","folded":"社会保险号","pattern":"社会保险号","word_start":false,"word_end":false},{"lang":"zh-Hans","label":"社会保险号码","kind":"sin","folded":"社会保险号码","pattern":"社会保险号码","word_start":false,"word_end":false},{"lang":"zh-Hans","label":"社会保障号","kind":"sin","folded":"社会保障号","pattern":"社会保障号","word_start":false,"word_end":false},{"lang":"zh-Hant","label":"社會保險號","kind":"sin","folded":"社會保險號","pattern":"社會保險號","word_start":false,"word_end":false},{"lang":"zh-Hant","label":"社會保險號碼","kind":"sin","folded":"社會保險號碼","pattern":"社會保險號碼","word_start":false,"word_end":false}],"key_tokens":[["sin"],["nas"],["itn"],["social","insurance"],["assurance","sociale"],["individual","tax"]],"program_identifiers":["RT","RP","RC","RZ","RR","RG","RD","RE","RM","RN","LT","RU","PT"],"bn15_suffix_regex":"[ -]?(?:RT|RP|RC|RZ|RR|RG|RD|RE|RM|RN|LT|RU|PT)[ -]?[0-9]{4}(?![0-9A-Za-z])","itn_prefixes":["08","09"],"hex_token_min":32,"uuid_regex":"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}","ocr":{"confusables":{"O":"0","o":"0","I":"1","l":"1","|":"1","S":"5","B":"8","Z":"2","G":"6"},"t_ocr":0.9,"run_digits":[8,10],"t_ocr_note":"provisional; D-A1-4 sets the final value in 9011c from the corpus"},"mask":"[MASKED:SIN]","rules":{"R_LABEL":"nine-digit sequence near a SIN/ITN label or under a labelled key","R_MOD10":"nine-digit sequence passing Mod 10 (Luhn; assumption A-1 accepted as D-A1-2)","R_ITN":"nine-digit sequence beginning 08 or 09 (D-A1-1)","R_OCR9":"any nine-digit sequence in OCR text","R_OCR_RUN":"8- or 10-digit OCR run with a low-confidence or confusable glyph"}}$spec$::jsonb $f$;

create function bnx.sin_luhn(d text) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t int := 0; v int; k int;
begin
  for k in 0 .. length(d) - 1 loop
    v := ascii(substr(d, length(d) - k, 1)) - 48;
    if k % 2 = 1 then v := v * 2; if v > 9 then v := v - 9; end if; end if;
    t := t + v;
  end loop;
  return t % 10 = 0;
end $$;

-- normalized text and, per character, the 0-based code-point index of the original character it came from
-- (idx is null when the text is ASCII: then normalization only maps ASCII whitespace to spaces and indexes are unchanged)
create function bnx.sin_normalize(p text, out n text, out idx int[])
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare sp jsonb := bnx.sin_detector_spec(); zw int[]; ws int[]; zeros int[]; i int; k int; ch text; t text; c text; cp int; z int;
        buf text[] := '{}'; ix int[] := '{}';
begin
  if p is null then return; end if;
  if octet_length(p) = length(p) then
    n := translate(p, E'\t\n\x0b\x0c\r', '     '); idx := null; return;
  end if;
  zw := array(select jsonb_array_elements_text(sp->'zero_width')::int);
  ws := array(select jsonb_array_elements_text(sp->'whitespace')::int);
  zeros := array(select jsonb_array_elements_text(sp->'nd_zeros')::int);
  for i in 1 .. length(p) loop
    ch := substr(p, i, 1);
    continue when ascii(ch) = any(zw);
    t := normalize(ch, NFKC);
    for k in 1 .. length(t) loop
      c := substr(t, k, 1); cp := ascii(c);
      continue when cp = any(zw);
      if cp >= 128 then
        select x into z from unnest(zeros) x where cp - x between 0 and 9;
        if found then c := chr(48 + cp - z); cp := ascii(c); end if;
      end if;
      if cp = any(ws) then c := ' '; end if;
      buf := buf || c; ix := ix || (i - 1);
    end loop;
  end loop;
  n := array_to_string(buf, ''); idx := ix;
end $$;

create function bnx.sin_fold(n text) returns text
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare ap int[] := array(select jsonb_array_elements_text(bnx.sin_detector_spec()->'apostrophes')::int); buf text[] := '{}'; c text; i int;
begin
  if n is null then return null; end if;
  if octet_length(n) = length(n) then return lower(n); end if;
  for i in 1 .. length(n) loop
    c := substr(n, i, 1);
    if ascii(c) = any(ap) then buf := buf || ''''::text;
    else buf := buf || left(lower(left(normalize(c, NFD), 1)), 1); end if;
  end loop;
  return array_to_string(buf, '');
end $$;

create function bnx.sin_scan(p text, p_origin text default 'native', p_force_label boolean default false) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare sp jsonb := bnx.sin_detector_spec(); r record; n text; idx int[]; f text; seq text := sp->>'sequence_regex';
        la int[] := '{}'; lb int[] := '{}'; ha int[] := '{}'; hb int[] := '{}'; lab jsonb; pat text; st int; a int; b int;
        i int; j int; ii int; jj int; d text; near boolean; rule text; k int; hits jsonb := '[]';
        wa int := (sp->>'label_window_after')::int; wb int := (sp->>'label_window_before')::int;
begin
  if p_origin is null or not (p_origin = any(array(select jsonb_array_elements_text(sp->'origins_sql_js')))) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'sin detector origin'); end if;
  if p is null then return hits; end if;
  select * into r from bnx.sin_normalize(p); n := r.n; idx := r.idx;
  if n !~ seq then return hits; end if;                                     -- no nine-digit sequence anywhere
  f := bnx.sin_fold(n);
  for lab in select x from jsonb_array_elements(sp->'labels') x loop
    pat := lab->>'pattern'; st := 1;
    loop
      a := regexp_instr(f, pat, st, 1, 0); exit when a = 0;
      b := regexp_instr(f, pat, st, 1, 1);
      st := greatest(b, a + 1);
      continue when (lab->>'word_start')::boolean and a > 1 and substr(f, a - 1, 1) ~ '^[A-Za-z]$';
      continue when (lab->>'word_end')::boolean and b <= length(f) and substr(f, b, 1) ~ '^[A-Za-z]$';
      la := la || (a - 1); lb := lb || (b - 1);
    end loop;
  end loop;
  foreach pat in array array['[0-9A-Fa-f]{' || (sp->>'hex_token_min') || ',}', sp->>'uuid_regex'] loop
    st := 1;
    loop
      a := regexp_instr(n, pat, st, 1, 0); exit when a = 0;
      b := regexp_instr(n, pat, st, 1, 1);
      ha := ha || (a - 1); hb := hb || (b - 1); st := b;
    end loop;
  end loop;
  st := 1;
  loop
    i := regexp_instr(n, seq, st, 1, 0); exit when i = 0;
    j := regexp_instr(n, seq, st, 1, 1);
    st := i + 1;
    continue when i > 1 and substr(n, i - 1, 1) between '0' and '9';     -- a sequence starts after a non-digit (§3.1)
    ii := i - 1; jj := j - 1;                                               -- 0-based [ii, jj)
    d := regexp_replace(substr(n, i, j - i), '[^0-9]', '', 'g');
    rule := null;
    near := p_force_label;
    if not near then
      for k in 1 .. coalesce(array_length(la, 1), 0) loop
        if (lb[k] <= ii and ii - lb[k] <= wa) or (jj <= la[k] and la[k] - jj <= wb) or (la[k] < jj and ii < lb[k]) then near := true; exit; end if;
      end loop;
    end if;
    for k in 1 .. coalesce(array_length(ha, 1), 0) loop
      if ha[k] <= ii and ii < hb[k] then rule := 'SKIP'; exit; end if;     -- starts inside a hash or UUID token: labels do not apply (D-9011a-1)
    end loop;
    continue when rule = 'SKIP';
    rule := null;
    if near then rule := 'R_LABEL';
    elsif jj - ii = 9 and not (i > 1 and substr(n, i - 1, 1) ~ '^[A-Za-z]$') and regexp_instr(n, sp->>'bn15_suffix_regex', j) = j then
      continue;                                                              -- complete CRA program account (§3.5)
    elsif bnx.sin_luhn(d) then rule := 'R_MOD10';
    elsif left(d, 2) = any(array(select jsonb_array_elements_text(sp->'itn_prefixes'))) then rule := 'R_ITN';
    else continue;
    end if;
    hits := hits || jsonb_build_object('rule', rule,
              'start', case when idx is null then ii else idx[i] end,
              'end', case when idx is null then jj else idx[j - 1] + 1 end);
  end loop;
  return coalesce((select jsonb_agg(x order by (x->>'start')::int, (x->>'end')::int, x->>'rule') from jsonb_array_elements(hits) x), '[]');
end $$;

create function bnx.sin_candidate(p text, p_origin text default 'native') returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$ select jsonb_array_length(bnx.sin_scan(p, p_origin)) > 0 $$;

create function bnx.sin_key_is_label(p_key text) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare toks text[]; pat jsonb; s int; m int; ok boolean;
begin
  toks := array(select t from unnest(regexp_split_to_array(
            bnx.sin_fold((bnx.sin_normalize(regexp_replace(coalesce(p_key, ''), '([a-z0-9])([A-Z])', '\1 \2', 'g'))).n), '[ _.-]+')) t
          where t <> '');
  for pat in select x from jsonb_array_elements(bnx.sin_detector_spec()->'key_tokens') x loop
    for s in 1 .. coalesce(array_length(toks, 1), 0) - jsonb_array_length(pat) + 1 loop
      ok := true;
      for m in 0 .. jsonb_array_length(pat) - 1 loop
        if toks[s + m] is distinct from pat->>m then ok := false; exit; end if;
      end loop;
      if ok then return true; end if;
    end loop;
  end loop;
  return false;
end $$;

-- hits in a JSON value: keys, strings and numbers; values under a labelled key are judged with force_label
create function bnx.sin_scan_json(p jsonb, p_origin text default 'native', p_path text default '$', p_labelled boolean default false)
returns jsonb language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare out jsonb := '[]'; e record; h jsonb;
begin
  case jsonb_typeof(p)
  when 'object' then
    for e in select key, value from jsonb_each(p) loop
      for h in select x from jsonb_array_elements(bnx.sin_scan(e.key, p_origin)) x loop
        out := out || (h || jsonb_build_object('path', p_path || '.' || e.key, 'part', 'key'));
      end loop;
      out := out || bnx.sin_scan_json(e.value, p_origin, p_path || '.' || e.key, p_labelled or bnx.sin_key_is_label(e.key));
    end loop;
  when 'array' then
    for e in select value, ordinality from jsonb_array_elements(p) with ordinality loop
      out := out || bnx.sin_scan_json(e.value, p_origin, p_path || '[' || (e.ordinality - 1) || ']', p_labelled);
    end loop;
  when 'string', 'number' then
    for h in select x from jsonb_array_elements(bnx.sin_scan(p #>> '{}', p_origin, p_labelled)) x loop
      out := out || (h || jsonb_build_object('path', p_path, 'part', 'value'));
    end loop;
  else null;
  end case;
  return out;
end $$;

-- cheap pre-filter on the JSON text (escapes of control characters count as separators), then the full scan
create function bnx.sin_json_has(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t text;
begin
  if p is null then return false; end if;
  t := p::text;
  if octet_length(t) = length(t)
     and regexp_replace(t, '\\(?:[tnrfb]|u00[0-9a-fA-F]{2})', ' ', 'g') !~ (bnx.sin_detector_spec()->>'sequence_regex') then
    return false;
  end if;
  return jsonb_array_length(bnx.sin_scan_json(p)) > 0;
end $$;

-- copy of p with every key, string or number that holds a candidate replaced by the mask
create function bnx.sin_mask_json(p jsonb, p_origin text default 'native', p_labelled boolean default false) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare mask text := bnx.sin_detector_spec()->>'mask'; out jsonb; e record; nk text;
begin
  case jsonb_typeof(p)
  when 'object' then
    out := '{}';
    for e in select key, value from jsonb_each(p) loop
      nk := case when bnx.sin_candidate(e.key, p_origin) then mask else e.key end;
      if out ? nk then nk := nk || '#' || (select count(*) from jsonb_object_keys(out)); end if;
      out := out || jsonb_build_object(nk, bnx.sin_mask_json(e.value, p_origin, p_labelled or bnx.sin_key_is_label(e.key)));
    end loop;
    return out;
  when 'array' then
    return coalesce((select jsonb_agg(bnx.sin_mask_json(x, p_origin, p_labelled) order by o) from jsonb_array_elements(p) with ordinality a(x, o)), '[]');
  when 'string', 'number' then
    return case when jsonb_array_length(bnx.sin_scan(p #>> '{}', p_origin, p_labelled)) > 0 then to_jsonb(mask) else p end;
  else return p;
  end case;
end $$;

-- ---------- intake exception class for blocked shared-index records (DOC-SIN-10) ----------
alter table bnx_intake.intake_exception drop constraint intake_exception_class_check,
  add constraint intake_exception_class_check check (class in ('UNCLASSIFIED','SCOPE_DISABLED','ACCESS_UNVERIFIED','BLOCKED',
    'INSTITUTION_UNVERIFIED','OWNER_TYPE_AMBIGUOUS','COUNTRY_UNKNOWN','HASH_MISMATCH','INCOMPLETE_ATTACHMENTS','UPSTREAM_OPEN_ITEM',
    'STALE_NON_TERMINAL','SIN_CANDIDATE'));

-- ---------- MODIFY bnx.audit (9005) ----------
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
  perform pg_advisory_xact_lock(hashtext('bnx.audit'));
  select seq, hash into s, prev from bnx.audit_event order by seq desc limit 1;
  s := coalesce(s, 0) + 1;
  insert into bnx.audit_event(seq, at, member_id, connection_id, channel, command, subject, payload_sha256, ledger_version, prev_hash,
                              hash, chain_version, at_hashed, host_profile, tool_name, tool_version, trace_id)
  values (s, t, a.member_id, a.connection_id, coalesce(a.channel,'system'), p_command, p_subject, ph, p_version, prev,
          sha256(coalesce(prev, '\x'::bytea) || bnx.audit_canonical_v2(s, a.member_id, a.connection_id, coalesce(a.channel,'system'),
                 p_command, p_subject, encode(ph,'hex'), p_version, t, 2::smallint, hp, tn, tv, tr)),
          2, t, hp, tn, tv, tr);
  return s;
end $$;

-- ---------- MODIFY bnx.stage_write (9010) ----------
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

-- ---------- MODIFY bnx.wrk_consume_shared_index (9010) ----------
create or replace function bnx.wrk_consume_shared_index(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; src record; hdr text[]; rec jsonb; rk text; weak boolean; vh bytea; st text; reason text; region text; flag text;
        owner_type text; avail text; item uuid; inst uuid; j text; is_cra boolean; cra jsonb := '[]'; cnt jsonb := '{}'; res jsonb; c text;
        maxd date; n int := 0; oi jsonb; sinb boolean; mask text := bnx.sin_detector_spec()->>'mask';
        contract text[] := array['File ID','Original Name','Current Name','Document Date','Processed Date','Domain','Type','Tags','Source',
                                 'Sensitivity','Status','Summary','Record Path','Related Open Item','Notes'];
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'index_consumed' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;                        -- idempotent replay
  pl := s.payload;
  select * into src from bnx_intake.external_index_source where source_id = pl->>'source_id';
  if not found or not src.enabled then
    res := jsonb_build_object('status', 'REJECTED', 'reason', 'SOURCE_UNKNOWN_OR_DISABLED');
    update bnx_intake.staging_payload set state = 'REJECTED', promoted_at = now(), result = res where id = p_staging;
    return res;
  end if;
  hdr := array(select jsonb_array_elements_text(coalesce(pl->'header', '[]')));
  if not (cardinality(hdr) = 15 and hdr @> contract and contract @> hdr) then              -- order-insensitive, case-sensitive
    item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':run', 'EXCEPTION');
    perform bnx.intake_exception_new(item, 'BLOCKED', true, jsonb_build_object('reason', 'CONTRACT_MISMATCH', 'source_id', src.source_id));
    update bnx_intake.index_consumer_cursor set failed_runs = failed_runs + 1 where source_id = src.source_id and tab = 'Records';
    res := jsonb_build_object('status', 'BLOCKED', 'reason', 'CONTRACT_MISMATCH', 'consumed', 0);
    update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = res where id = p_staging;
    return res;
  end if;
  for rec in select x from jsonb_array_elements(coalesce(pl->'records', '[]')) x loop
    n := n + 1;
    rk := coalesce(nullif(rec->>'File ID', ''), nullif(rec->>'Record Path', ''));
    weak := rk is null;
    -- 9011 DOC-SIN-10: a record that stage_write masked is blocked; its columns are not stored, only key and version hash
    sinb := position(mask in rec::text) > 0;
    if sinb and coalesce(rk, '') like '%' || mask || '%' then rk := null; weak := true; end if;
    if weak and sinb then rk := 'sin:' || encode(bnx.h(rec::text), 'hex');
    elsif weak then rk := 'weak:' || encode(bnx.h(coalesce(rec->>'Original Name','') || '|' || coalesce(rec->>'Document Date','') || '|'
                                                || coalesce(rec->>'Source','')), 'hex'); end if;
    -- version hash over the 15 columns in contract order (F-C4-05: deterministic canonical form, not RFC 8785 JCS)
    vh := bnx.h((select jsonb_agg(coalesce(rec->k, 'null'::jsonb) order by o) from unnest(contract) with ordinality u(k, o))::text);
    if exists (select 1 from bnx_intake.index_record_ack where source_id = src.source_id and record_key = rk and record_version_hash = vh
                and status in ('CONSUMED','SKIPPED_SCOPE','SKIPPED_DOMAIN','DEAD_LETTER')) then
      cnt := jsonb_set(cnt, '{REPLAYED}', to_jsonb(coalesce((cnt->>'REPLAYED')::int, 0) + 1)); continue;
    end if;
    insert into bnx_intake.external_index_record(source_id, record_key, record_version_hash, weak_key, columns)
    values (src.source_id, rk, vh, weak, case when sinb then '{}'::jsonb else (select jsonb_object_agg(k, rec->k) from unnest(contract) k where rec ? k) end)
    on conflict (source_id, record_key, record_version_hash) do update set last_seen_at = now();
    begin maxd := greatest(maxd, (rec->>'Processed Date')::date); exception when others then null; end;
    item := null; reason := null; region := null;
    if sinb then
      st := 'BLOCKED'; reason := 'SIN_CANDIDATE';
      item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk, 'BLOCKED');
      perform bnx.intake_exception_new(item, reason, true, jsonb_build_object('source_id', src.source_id, 'record_key', rk),
                                       'idx:' || src.source_id || ':' || rk || ':' || reason);
    elsif rec->>'Domain' is distinct from 'Banking_Tax' then
      st := 'SKIPPED_DOMAIN';
    else
      is_cra := coalesce(rec->>'Type', '') ~* '\mCRA\M' or coalesce(rec->>'Tags', '') ~* '\mCRA\M';
      owner_type := case when coalesce(rec->>'Tags', '') ~* '\m(corporate|business)\M' then 'CORPORATE'
                         when coalesce(rec->>'Tags', '') ~* 'owner[:_ ]?unknown' then 'UNKNOWN' else 'PERSONAL' end;
      if is_cra then region := 'CA'; flag := 'CRA';
      else
        inst := bnx.sender_institution(coalesce(nullif(split_part(rec->>'Source', '@', 2), ''), rec->>'Source'));
        select jurisdiction into j from bnx.institution where id = inst;
        region := coalesce(bnx.region_of_jurisdiction(j), 'UNKNOWN');
        flag := bnx.pol_region_flag(region);
      end if;
      avail := case when not weak and coalesce(rec->>'File ID', '') <> '' and pl->'availability'->>rk = 'FILED_VERIFIED'
                    then 'FILED_VERIFIED' else 'INDEXED_SOURCE_ONLY' end;
      update bnx_intake.external_index_record set derived_category = case when is_cra then 'CRA' else 'Banking' end,
             derived_banking_region = region, derived_country_code = case when region like 'OTHER:%' then substr(region, 7) else region end,
             derived_account_owner_type = owner_type, availability = avail
       where source_id = src.source_id and record_key = rk and record_version_hash = vh;
      if owner_type <> 'PERSONAL' then st := 'BLOCKED'; reason := 'OWNER_TYPE_AMBIGUOUS';
      elsif region = 'UNKNOWN' then st := 'BLOCKED'; reason := 'COUNTRY_UNKNOWN';
      elsif bnx.pol_flag(flag) is distinct from 'YES' then st := 'SKIPPED_SCOPE'; reason := flag;
      else
        st := 'CONSUMED';
        item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk,
                                    case when avail = 'FILED_VERIFIED' then 'RECEIVED' else 'EVIDENCE_PENDING' end);
        if is_cra then cra := cra || jsonb_build_object('record_key', rk, 'document_date', rec->>'Document Date',
                                                          'masked_subject', coalesce(nullif(rec->>'Current Name', ''), rec->>'Original Name')); end if;
      end if;
      if st = 'BLOCKED' then
        item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk, 'BLOCKED');
        perform bnx.intake_exception_new(item, reason, true, jsonb_build_object('source_id', src.source_id, 'record_key', rk),
                                         'idx:' || src.source_id || ':' || rk || ':' || reason);
      end if;
    end if;
    st := bnx.index_ack(src.source_id, rk, vh, st, item, reason);                             -- same transaction as the item
    cnt := jsonb_set(cnt, array[st], to_jsonb(coalesce((cnt->>st)::int, 0) + 1));
  end loop;
  -- upstream open items -> Owner-only exceptions (deduplicated by upstream key)
  for oi in select x from jsonb_array_elements(coalesce(pl->'open_items', '[]')) x loop
    perform bnx.intake_exception_new(null, 'UPSTREAM_OPEN_ITEM', true, jsonb_build_object('source_id', src.source_id, 'key', left(oi->>'key', 120)),
                                     'open:' || src.source_id || ':' || left(oi->>'key', 120));
  end loop;
  -- CRA correspondence: never an assessment; unresolved taxpayer -> Owner-only; > 20 in one run -> one NOTICE_BURST exception
  if jsonb_array_length(cra) > 20 then
    perform bnx.notify('EXCEPTION', 'NOTICE_BURST:' || src.source_id || ':' || p_staging, true,
                       jsonb_build_object('kind', 'NOTICE_BURST', 'source_id', src.source_id, 'count', jsonb_array_length(cra)));
  else
    for rec in select x from jsonb_array_elements(cra) x loop
      perform bnx.notify('CRA_CORRESPONDENCE', 'CRA_CORRESPONDENCE:' || (rec->>'record_key'), true,
                         jsonb_build_object('kind', 'UNASSIGNED_TAX_NOTICE', 'record_key', rec->>'record_key', 'document_date', rec->>'document_date',
                                            'masked_subject', rec->>'masked_subject', 'caveat', 'an email may not contain the full CRA document'));
    end loop;
  end if;
  insert into bnx_intake.index_consumer_cursor(source_id, tab, last_run_at, rows_seen, max_processed_date_seen, coverage_declaration, failed_runs)
  values (src.source_id, 'Records', now(), n, maxd, coalesce(pl->'coverage', '{}'), 0)
  on conflict (source_id, tab) do update set last_run_at = now(), rows_seen = n,
    max_processed_date_seen = greatest(bnx_intake.index_consumer_cursor.max_processed_date_seen, maxd),
    coverage_declaration = coalesce(pl->'coverage', bnx_intake.index_consumer_cursor.coverage_declaration), failed_runs = 0;
  res := jsonb_build_object('status', 'PROMOTED', 'rows_seen', n, 'acks', cnt, 'cra_notices', jsonb_array_length(cra));
  update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = res where id = p_staging;
  return res;
end $$;
