-- 9011 (S4 V1.2, WP-DOC): documents, evidence, renditions. Increment 9011a: the SIN/ITN detector and the database guards.
-- Addendum A1 Rev 1 (branch s4/design-addendum-a1): §3 detector (guard C1), §7 DOC-SIN-10, guard C2. Later increments of this
-- work package (9011b intake states and declaration, 9011c Executor validators) extend this file before it is merged.
-- Synthetic data only. No function here is granted to a runtime role; they run inside SECURITY DEFINER callers.
--
-- MODIFY (bodies copied from their last version and changed only where marked "9011"):
--   bnx.audit                      (9005)  refuses SIN/ITN candidates in payload and subject (D-9011a-3)
--   bnx.stage_write                (9010)  masks index payloads, refuses other kinds (DOC-SIN-10, D-9011a-2)
--   bnx.wrk_consume_shared_index   (9010)  blocks masked records, stores no columns for them (DOC-SIN-10)
--   bnx.wrk_promote_staged         (9010)  dispatches doc_discovered / doc_validated / doc_archived to the 9011b promoters

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

-- ======================================================================================================================
-- 9011b: discovery, transient scan verdicts, Owner redaction declaration and admission (Addendum A1 Rev 1 §2, §4, §5, §7;
-- Owner decisions A1-OD-2 and A1-OD-3). Document bytes never reach the database: the Executor stages identities and verdicts
-- only (zones Z0-Z2). Registration of evidence objects in Z3 (bnx.evidence_object / bnx.document) follows in 9011c.
-- ======================================================================================================================

create table bnx_doc.document_discovery(
  id uuid primary key default gen_random_uuid(),
  source_kind text not null check (source_kind in ('DRIVE_INBOX','MAIL_ATTACHMENT')),
  source_file_id text, head_revision_id text, md5 text, size_bytes bigint, source_mtime timestamptz,
  mail_message_id text, mime_part text,
  module text not null check (module in ('FINANCE','TAX','SYSTEM')), period_key text,
  original_name text, name_withheld boolean not null,
  staging_id uuid, discovered_at timestamptz not null default now(),
  check (source_kind <> 'DRIVE_INBOX' or (source_file_id is not null and head_revision_id is not null and md5 is not null)),
  check (source_kind <> 'MAIL_ATTACHMENT' or (mail_message_id is not null and mime_part is not null)),
  check (name_withheld = (original_name is null)),
  unique nulls not distinct (source_kind, source_file_id, head_revision_id, md5, mail_message_id, mime_part));

create table bnx_doc.document_scan(
  id uuid primary key default gen_random_uuid(),
  discovery_id uuid not null references bnx_doc.document_discovery,
  sha256 bytea not null check (octet_length(sha256) = 32),
  sin_detector_version text not null,
  scan_result text not null check (scan_result in ('PASSED','SIN_CANDIDATE','SCAN_INCOMPLETE')),
  rule_codes text[] not null default '{}', locators jsonb not null default '[]',
  doc_class text check (doc_class ~ '^[A-Z0-9_]{1,40}$'), class_uncertain boolean not null, sin_bearing boolean not null,
  staging_id uuid, scanned_at timestamptz not null default now());

create table bnx_doc.document_declaration(
  id uuid primary key default gen_random_uuid(),
  discovery_id uuid not null references bnx_doc.document_discovery,
  sha256 bytea not null check (octet_length(sha256) = 32),
  source_kind text not null, source_file_id text, head_revision_id text, md5 text, mail_message_id text, mime_part text,
  declared_by uuid not null, declared_at timestamptz not null default now(),
  unique (discovery_id, sha256));

create table bnx_doc.document_state_event(
  seq bigint generated always as identity primary key,
  discovery_id uuid not null references bnx_doc.document_discovery,
  state text not null check (state in ('DISCOVERED','SCANNING','QUARANTINED','SCAN_INCOMPLETE','PENDING_DECLARATION','ADMISSIBLE',
                                       'ARCHIVED','INVALIDATED')),
  reason text, staging_id uuid, at timestamptz not null default now());
create index on bnx_doc.document_state_event(discovery_id, seq desc);

create trigger t_append_only before update or delete on bnx_doc.document_discovery for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_scan for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_declaration for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_state_event for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('document_discovery','E'),('document_scan','E'),('document_declaration','E'),('document_state_event','E');

-- SIN-bearing classes (Addendum A1 Rev 1 §2); an uncertain class or an Owner tag also requires a declaration
create function bnx.doc_class_sin_bearing(p_class text) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select coalesce(p_class = any(array['T4','T4A','T4A_P','T4A_OAS','T4E','T4RSP','T4RIF','T4FHSA','T5','T3','T5008','T5007','RC62',
                                      'RRSP_RECEIPT','NOA','NOR','CRA_CORRESPONDENCE','T1_SCHEDULE']), false)
$$;

create function bnx.doc_state(p_disc uuid) returns text
language sql stable set search_path = pg_catalog, pg_temp as $$
  select state from bnx_doc.document_state_event where discovery_id = p_disc order by seq desc limit 1
$$;

create function bnx.doc_latest_scan(p_disc uuid) returns bnx_doc.document_scan
language sql stable set search_path = pg_catalog, pg_temp as $$
  select * from bnx_doc.document_scan where discovery_id = p_disc order by scanned_at desc, id desc limit 1
$$;

create function bnx.doc_needs_declaration(p_disc uuid) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce((select s.sin_bearing or s.class_uncertain or bnx.doc_class_sin_bearing(s.doc_class) from bnx.doc_latest_scan(p_disc) s), true)
      or exists (select 1 from bnx_doc.document_state_event e where e.discovery_id = p_disc and e.reason = 'OWNER_TAGGED')
$$;

-- the scan is usable only under the current detector version (DOC-SIN-14)
create function bnx.doc_scan_current(p_disc uuid) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce((select s.scan_result = 'PASSED' and s.sin_detector_version = bnx.sin_detector_spec()->>'version'
                   from bnx.doc_latest_scan(p_disc) s), false)
$$;

-- state machine (Addendum A1 Rev 1 §5.3). QUARANTINED and INVALIDATED are terminal: there is no release path (A1-OD-2,
-- DOC-SIN-13). SCAN_INCOMPLETE may be scanned again only after a detector version change.
create function bnx.trg_doc_state_transition() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev text := bnx.doc_state(new.discovery_id); ok boolean;
begin
  ok := case
    when prev is null then new.state = 'DISCOVERED'
    when prev = 'DISCOVERED' then new.state in ('SCANNING','INVALIDATED')
    when prev = 'SCANNING' then new.state in ('QUARANTINED','SCAN_INCOMPLETE','PENDING_DECLARATION','ADMISSIBLE')
    when prev = 'PENDING_DECLARATION' then new.state in ('ADMISSIBLE','SCANNING','INVALIDATED')
    when prev = 'ADMISSIBLE' then new.state in ('ARCHIVED','PENDING_DECLARATION','SCANNING','DISCOVERED','INVALIDATED')
    when prev = 'ARCHIVED' then new.state = 'SCANNING'
    when prev = 'SCAN_INCOMPLETE' then new.state = 'SCANNING' and coalesce(
           (select s.sin_detector_version from bnx.doc_latest_scan(new.discovery_id) s) <> bnx.sin_detector_spec()->>'version', false)
    else false end;
  if not ok then
    raise exception 'DOC_STATE_TRANSITION' using errcode = 'P0409', detail = coalesce(prev, 'none') || ' -> ' || new.state;
  end if;
  return new;
end $$;
create trigger t_doc_state_transition before insert on bnx_doc.document_state_event for each row execute function bnx.trg_doc_state_transition();

create function bnx.doc_event(p_disc uuid, p_state text, p_reason text, p_staging uuid) returns void
language sql set search_path = pg_catalog, pg_temp as $$
  insert into bnx_doc.document_state_event(discovery_id, state, reason, staging_id) values (p_disc, p_state, p_reason, p_staging)
$$;

-- current view: state, scan, declaration status and source fidelity, without any content
create view bnx_doc.document_current as
  select d.id as discovery_id, d.source_kind, d.module, d.period_key, d.original_name, d.name_withheld,
         bnx.doc_state(d.id) as state, s.sha256, s.scan_result, s.sin_detector_version, s.doc_class, s.class_uncertain,
         case when bnx.doc_state(d.id) = 'INVALIDATED' then 'INVALIDATED'
              when not bnx.doc_needs_declaration(d.id) then 'NOT_REQUIRED'
              when exists (select 1 from bnx_doc.document_declaration x where x.discovery_id = d.id and x.sha256 = s.sha256) then 'DECLARED'
              else 'PENDING' end as declaration_status,
         case when bnx.doc_needs_declaration(d.id) then 'OWNER_REDACTED_SOURCE' else 'AS_RECEIVED_FROM_OWNER' end as source_fidelity
    from bnx_doc.document_discovery d left join lateral (select * from bnx.doc_latest_scan(d.id)) s on true;

-- payload helpers
create function bnx.doc_payload_keys_ok(p jsonb, p_allowed text[]) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'object' and not exists (select 1 from jsonb_object_keys(p) k where not k = any(p_allowed))
$$;

-- a locator carries positions only: integers, short lower-case tokens, or a bounding box of at most four integers
create function bnx.doc_locators_ok(p jsonb) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 200 and not exists (
    select 1 from jsonb_array_elements(p) l
     where jsonb_typeof(l) <> 'object'
        or exists (select 1 from jsonb_each(l) e
                    where not e.key = any(array['part','kind','page','offset','length','bbox','revision','path_depth'])
                       or not (jsonb_typeof(e.value) = 'number'
                               or (jsonb_typeof(e.value) = 'string' and e.value #>> '{}' ~ '^[a-z_]{1,32}$')
                               or (jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) <= 4
                                   and not exists (select 1 from jsonb_array_elements(e.value) b where jsonb_typeof(b) <> 'number')))))
$$;

create function bnx.doc_reject(p_staging uuid, p_reason text) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare res jsonb := jsonb_build_object('status', 'REJECTED', 'reason', p_reason);
begin
  update bnx_intake.staging_payload set state = 'REJECTED', promoted_at = now(), result = res where id = p_staging;
  return res;
end $$;

create function bnx.doc_done(p_staging uuid, p_res jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = p_res where id = p_staging;
  return p_res;
end $$;

-- step 1, Z0 -> Z2: a discovered file identity (no bytes, no content). A new revision of the same source invalidates the
-- earlier discoveries that were not archived (a declaration never carries over to changed content: A1-OD-3).
create function bnx.wrk_doc_discovered(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; old uuid;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_discovered' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['source_kind','source_file_id','head_revision_id','md5','size_bytes','source_mtime',
                                         'mail_message_id','mime_part','module','period_key','original_name']) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  select id into did from bnx_doc.document_discovery
   where source_kind = pl->>'source_kind' and source_file_id is not distinct from pl->>'source_file_id'
     and head_revision_id is not distinct from pl->>'head_revision_id' and md5 is not distinct from pl->>'md5'
     and mail_message_id is not distinct from pl->>'mail_message_id' and mime_part is not distinct from pl->>'mime_part';
  if did is not null then
    return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'new', false));
  end if;
  begin
    insert into bnx_doc.document_discovery(source_kind, source_file_id, head_revision_id, md5, size_bytes, source_mtime, mail_message_id,
                                           mime_part, module, period_key, original_name, name_withheld, staging_id)
    values (pl->>'source_kind', pl->>'source_file_id', pl->>'head_revision_id', pl->>'md5', (pl->>'size_bytes')::bigint,
            (pl->>'source_mtime')::timestamptz, pl->>'mail_message_id', pl->>'mime_part', pl->>'module', pl->>'period_key',
            nullif(pl->>'original_name', ''), nullif(pl->>'original_name', '') is null, p_staging)
    returning id into did;
  exception when check_violation or not_null_violation or invalid_text_representation or invalid_datetime_format
            or datetime_field_overflow then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  perform bnx.doc_event(did, 'DISCOVERED', null, p_staging);
  if pl->>'source_kind' = 'DRIVE_INBOX' then
    for old in select d.id from bnx_doc.document_discovery d
                where d.source_kind = 'DRIVE_INBOX' and d.source_file_id = pl->>'source_file_id' and d.id <> did
                  and bnx.doc_state(d.id) in ('DISCOVERED','PENDING_DECLARATION','ADMISSIBLE') loop
      perform bnx.doc_event(old, 'INVALIDATED', 'NEW_REVISION', p_staging);
    end loop;
  end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'new', true));
end $$;

-- step 2, Z1 verdict -> Z2: the Executor stages the verdict of the transient scan, never content (DOC-SIN-01/04/07/08)
create function bnx.wrk_doc_validated(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; st text; sha bytea; res text; nxt text; d record; nm text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_validated' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['discovery_id','sha256','sin_detector_version','scan_result','rule_codes','locators','doc_class',
                                         'class_uncertain','sin_bearing']) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  if coalesce(pl->>'sha256', '') !~ '^[0-9a-f]{64}$' or not bnx.doc_locators_ok(coalesce(pl->'locators', '[]'))
     or jsonb_typeof(coalesce(pl->'rule_codes', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(coalesce(pl->'rule_codes', '[]')) r where r !~ '^R_[A-Z0-9_]{1,30}$') then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end if;
  if pl->>'sin_detector_version' is distinct from bnx.sin_detector_spec()->>'version' then
    return bnx.doc_reject(p_staging, 'DETECTOR_VERSION_STALE'); end if;
  begin did := (pl->>'discovery_id')::uuid; exception when others then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then return bnx.doc_reject(p_staging, 'DISCOVERY_UNKNOWN'); end if;
  st := bnx.doc_state(did);
  if st in ('QUARANTINED','INVALIDATED') then return bnx.doc_reject(p_staging, 'TERMINAL_STATE'); end if;
  if st = 'SCANNING' then return bnx.doc_reject(p_staging, 'SCAN_IN_PROGRESS'); end if;
  sha := decode(pl->>'sha256', 'hex'); res := pl->>'scan_result';
  -- the SCANNING transition is checked against the previous scan before the new verdict is stored; both or neither
  begin
    perform bnx.doc_event(did, 'SCANNING', null, p_staging);
    insert into bnx_doc.document_scan(discovery_id, sha256, sin_detector_version, scan_result, rule_codes, locators, doc_class,
                                      class_uncertain, sin_bearing, staging_id)
    values (did, sha, pl->>'sin_detector_version', res, array(select jsonb_array_elements_text(coalesce(pl->'rule_codes', '[]'))),
            coalesce(pl->'locators', '[]'), nullif(pl->>'doc_class', ''), coalesce((pl->>'class_uncertain')::boolean, true),
            coalesce((pl->>'sin_bearing')::boolean, false), p_staging);
  exception
    when sqlstate 'P0409' then return bnx.doc_reject(p_staging, 'RESCAN_NOT_ALLOWED');
    when check_violation or not_null_violation or invalid_text_representation then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  -- notification metadata keys are fixed (9010); a file name is included only when it contains no digit at all (DOC-SIN-08)
  nm := case when d.original_name is null or d.original_name ~ '[0-9]' then null else left(d.original_name, 80) end;
  if res = 'SIN_CANDIDATE' then
    nxt := 'QUARANTINED';
    perform bnx.notify('EXCEPTION', 'SIN_QUARANTINE:' || encode(sha, 'hex'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'SIN_CANDIDATE_QUARANTINED', 'source_id', d.module, 'record_key', did, 'masked_subject', nm,
                                          'caveat', 'replace the Inbox file with a newly redacted copy')));
  elsif res = 'SCAN_INCOMPLETE' then
    nxt := 'SCAN_INCOMPLETE';
    perform bnx.notify('EXCEPTION', 'SCAN_INCOMPLETE:' || encode(sha, 'hex') || ':' || (pl->>'sin_detector_version'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'SCAN_INCOMPLETE', 'source_id', d.module, 'record_key', did, 'masked_subject', nm)));
  elsif not bnx.doc_needs_declaration(did) then
    nxt := 'ADMISSIBLE';
  elsif exists (select 1 from bnx_doc.document_declaration x where x.discovery_id = did and x.sha256 = sha) then
    nxt := 'ADMISSIBLE';
  else
    nxt := 'PENDING_DECLARATION';
    perform bnx.notify('EXCEPTION', 'DECLARE:' || did || ':' || encode(sha, 'hex'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'REDACTION_DECLARATION_PENDING', 'source_id', d.module, 'record_key', did, 'masked_subject', nm)));
  end if;
  perform bnx.doc_event(did, nxt, res, p_staging);
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', nxt));
end $$;

-- the Owner's redaction declaration (A1-OD-3): Owner only, PWA only, bound to identity, revision and SHA-256 (DOC-SIN-11)
create function bnx.cmd_doc_declare_redacted(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; role text; did uuid; d record; sc bnx_doc.document_scan; sha bytea;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if a.channel is distinct from 'pwa' then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'doc_declare_redacted', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'sha256', '') !~ '^[0-9a-f]{64}$' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'sha256'); end if;
  sha := decode(cmd->>'sha256', 'hex');
  begin did := (cmd->>'discovery_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'discovery_id'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  sc := bnx.doc_latest_scan(did);
  if bnx.doc_state(did) <> 'PENDING_DECLARATION' or sc.sha256 is distinct from sha or not bnx.doc_scan_current(did) then
    perform bnx.fail('DECLARATION_NOT_APPLICABLE', 'P0409'); end if;
  insert into bnx_doc.document_declaration(discovery_id, sha256, source_kind, source_file_id, head_revision_id, md5, mail_message_id,
                                           mime_part, declared_by)
  values (did, sha, d.source_kind, d.source_file_id, d.head_revision_id, d.md5, d.mail_message_id, d.mime_part, a.member_id);
  perform bnx.doc_event(did, 'ADMISSIBLE', 'OWNER_DECLARED_REDACTED', null);
  perform bnx.audit(a, 'doc_declare_redacted', jsonb_build_object('discovery_id', did),
                    jsonb_build_object('sha256', cmd->>'sha256', 'source_kind', d.source_kind), null);
  return bnx.idem_end(a, 'doc_declare_redacted', cmd, jsonb_build_object('discovery_id', did, 'state', 'ADMISSIBLE',
                      'declaration_status', 'DECLARED', 'source_fidelity', 'OWNER_REDACTED_SOURCE'));
end $$;

-- the Owner tags a document as SIN-bearing before it is archived: it then needs a declaration (Addendum A1 Rev 1 §2)
create function bnx.cmd_doc_tag_sin_bearing(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; role text; did uuid;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if a.channel is distinct from 'pwa' then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'doc_tag_sin_bearing', cmd); if rc is not null then return rc; end if;
  begin did := (cmd->>'discovery_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'discovery_id'); end;
  if bnx.doc_state(did) is distinct from 'ADMISSIBLE' then perform bnx.fail('DECLARATION_NOT_APPLICABLE', 'P0409'); end if;
  perform bnx.doc_event(did, 'PENDING_DECLARATION', 'OWNER_TAGGED', null);
  perform bnx.audit(a, 'doc_tag_sin_bearing', jsonb_build_object('discovery_id', did), '{}', null);
  return bnx.idem_end(a, 'doc_tag_sin_bearing', cmd, jsonb_build_object('discovery_id', did, 'state', 'PENDING_DECLARATION'));
end $$;

-- step 5 gate (Addendum A1 Rev 1 §5.4, DOC-SIN-12): the Executor re-fetched the bytes for archiving and reports their SHA-256
-- and identity. Admission only if identity and hash are unchanged, the scan passed under the current detector and the
-- declaration (when required) is bound to that hash. Any mismatch writes nothing and returns the document to DISCOVERED.
create function bnx.wrk_doc_archived(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; d record; sc bnx_doc.document_scan; why text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_archived' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['discovery_id','sha256','source_file_id','head_revision_id','md5','mail_message_id','mime_part',
                                         'archived_file_id']) or coalesce(pl->>'sha256', '') !~ '^[0-9a-f]{64}$' then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end if;
  begin did := (pl->>'discovery_id')::uuid; exception when others then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then return bnx.doc_reject(p_staging, 'DISCOVERY_UNKNOWN'); end if;
  if bnx.doc_state(did) is distinct from 'ADMISSIBLE' then return bnx.doc_reject(p_staging, 'NOT_ADMISSIBLE'); end if;
  sc := bnx.doc_latest_scan(did);
  why := case
    when d.source_file_id is distinct from pl->>'source_file_id' or d.head_revision_id is distinct from pl->>'head_revision_id'
         or d.md5 is distinct from pl->>'md5' or d.mail_message_id is distinct from pl->>'mail_message_id'
         or d.mime_part is distinct from pl->>'mime_part' then 'IDENTITY_CHANGED'
    when sc.sha256 is distinct from decode(pl->>'sha256', 'hex') then 'HASH_MISMATCH'
    when not bnx.doc_scan_current(did) then 'SCAN_NOT_CURRENT'
    when bnx.doc_needs_declaration(did) and not exists (select 1 from bnx_doc.document_declaration x
                                                         where x.discovery_id = did and x.sha256 = sc.sha256) then 'DECLARATION_MISSING'
    end;
  if why is not null then
    perform bnx.doc_event(did, 'DISCOVERED', why, p_staging);
    return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', 'DISCOVERED', 'reason', why));
  end if;
  perform bnx.doc_event(did, 'ARCHIVED', 'ADMITTED', p_staging);
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', 'ARCHIVED'));
end $$;

-- DOC-SIN-14: documents whose last scan predates the current detector version and that are not terminal
create function bnx.wrk_doc_rescan_due() returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  return coalesce((select jsonb_agg(c.discovery_id order by c.discovery_id) from bnx_doc.document_current c
                    where c.state in ('PENDING_DECLARATION','ADMISSIBLE','ARCHIVED','SCAN_INCOMPLETE')
                      and c.sin_detector_version is distinct from bnx.sin_detector_spec()->>'version'), '[]');
end $$;

-- the Owner's view of pending and quarantined documents (DOC-SIN-06 label); no content, no locators
create function bnx.q_doc_redaction_queue(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  return jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object(
           'discovery_id', c.discovery_id, 'module', c.module, 'period_key', c.period_key, 'state', c.state,
           'file', case when c.name_withheld then null else c.original_name end, 'sha256', encode(c.sha256, 'hex'),
           'doc_class', c.doc_class, 'declaration_status', c.declaration_status, 'source_fidelity', c.source_fidelity,
           'label', case when c.source_fidelity = 'OWNER_REDACTED_SOURCE' then 'Owner-redacted copy — not the issuer''s original' end)
           order by c.discovery_id)
         from bnx_doc.document_current c where c.state in ('PENDING_DECLARATION','QUARANTINED','SCAN_INCOMPLETE','ADMISSIBLE')), '[]'));
end $$;

-- C4 (Worker): an MCP tool response that carried a candidate was refused; record the refusal without any value
create function bnx.wrk_audit_sin_refusal(p jsonb) returns bigint
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  if coalesce(p->>'tool', '') !~ '^[a-z_]{1,64}$' or jsonb_typeof(coalesce(p->'rules', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(coalesce(p->'rules', '[]')) r where r !~ '^R_[A-Z0-9_]{1,30}$') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'refusal record'); end if;
  return bnx.audit(row(null, null, 'mcp', null, null)::bnx.actor, 'mcp_response_refused',
                   jsonb_build_object('tool', p->>'tool'), jsonb_build_object('rules', p->'rules'), null);
end $$;

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

-- ---------- MODIFY bnx.wrk_promote_staged (9010): document promoters (9011b) ----------
create or replace function bnx.wrk_promote_staged(p_staging uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; r jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging;
  if not found then return 'not_found'; end if;
  if s.state in ('PROMOTED','REJECTED') then return lower(s.state); end if;
  if s.stg_kind = 'index_consumed' then r := bnx.wrk_consume_shared_index(p_staging);
  elsif s.stg_kind = 'mail_fetched' and s.payload->>'op' = 'move' then r := bnx.wrk_mail_move_result(p_staging);
  elsif s.stg_kind = 'mail_fetched' then r := bnx.wrk_mail_evidence_registered(p_staging);
  elsif s.stg_kind = 'doc_discovered' then r := bnx.wrk_doc_discovered(p_staging);       -- 9011b
  elsif s.stg_kind = 'doc_validated' then r := bnx.wrk_doc_validated(p_staging);         -- 9011b
  elsif s.stg_kind = 'doc_archived' then r := bnx.wrk_doc_archived(p_staging);           -- 9011b (admission gate)
  else
    update bnx_intake.staging_payload set state = 'AWAITING_PROMOTER' where id = p_staging;   -- 9011c / 9014 / 9016 promoters
    return 'awaiting_promoter';
  end if;
  return lower(coalesce(r->>'status', 'promoted'));
end $$;

select bnx.apply_grants();
