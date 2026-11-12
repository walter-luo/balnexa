-- 9025_s4_doc_pipeline_work_orders.sql -- S4 phase 2.2/2.3 (DOC-2, INT-2, INT-3): work orders and due lists for the Executor
-- document pipeline, shared-index consumer and exact mail retrieval. Expand-only. Not in the V1.2 register (D-DOC2-1).
--   MODIFY: bnx.exec_work_order (9018 body; branch DOC_PROCESS and declarations marked "9025"): the lease for a discovery
--           carries its source identity and the next step (VALIDATE: scan this exact revision; ARCHIVE: re-fetch, copy to
--           Processed, re-hash). A discovery with nothing to do refuses the lease (NOTHING_TO_DO), so no lease row is left.
--   NEW:    bnx.wrk_exec_due(p): the Gateway's POST /exec/v1/due (bnx_worker, after the job identity check): items a job kind
--           can lease now. DOC_PROCESS: discoveries to validate (new or re-scan due) and admissible ones to archive.
--           INDEX_CONSUME: enabled sources. MAIL_MOVE: fetched, verified messages whose route names another folder.
--   NEW:    bnx.mail_route_folder(mail_item): institution route on the received date, else the coverage-home rule.
--           INDEX_CONSUME (item = source_id): adapter, location reference and cursor. MAIL_EXACT_FETCH (item =
--           "<source_ref>|<Message-ID>"): provider and credential state. MAIL_MOVE (item = canonical key hex): the folder the
--           routes name for the sender's institution. DOC_DISCOVER for a mail attachment ("mail:<source_ref>|<id>|<part>"):
--           the provider. No new lease refusal: an unknown item gets no work order (input null, as before 9025), and a known
--           item with nothing to do says so in the input (step NONE, folder_ref absent, credential_state); the Executor then
--           stages nothing. The promoters stay the validators of record.
-- The Executor discovers Drive files itself (DOC_DISCOVER, one lease per file revision); doc_discovered dedupes repeats.
set role bnx_definer;

-- 9025: the folder a fetched message belongs in: the route of its sender's institution on the date it was received, else the
-- mailbox's coverage-home rule (when the mailbox is the coverage home). NULL = no route (the message stays where it is).
create function bnx.mail_route_folder(m bnx_intake.mail_item) returns text
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce(
    (select r.folder_ref from bnx_intake.mail_folder_route r
      where r.source_ref = m.source_ref and r.institution_id = bnx.sender_institution(m.sender_domain)
        and coalesce(m.received_at::date, current_date) >= r.effective_from
        and (r.effective_to is null or coalesce(m.received_at::date, current_date) < r.effective_to)
      order by r.effective_from desc limit 1),
    (select r.folder_ref from bnx_intake.mail_route_rule r join bnx_intake.mail_source s on s.source_ref = r.source_ref
      where r.source_ref = m.source_ref and r.rule_kind = 'coverage_home' and s.coverage_home
        and coalesce(m.received_at::date, current_date) >= r.effective_from
      order by r.effective_from desc limit 1))
$$;

create or replace function bnx.exec_work_order(p_kind text, p_item text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s bnx.report_snapshot; rows_ jsonb; rt text; due jsonb; r bnx.backup_run; sid uuid; rid uuid;
        did uuid; d bnx_doc.document_discovery; st text; sc bnx_doc.document_scan; step text; mref text; mprov text;     -- 9025
        src record; cur record; it bnx_intake.mail_item; fld text; parts text[]; k bytea;                    -- 9025
begin
  if p_kind = 'REPORT_RENDER' then
    begin sid := p_item::uuid; exception when others then sid := null; end;
    select * into s from bnx.report_snapshot where id = sid;
    if not found then perform bnx.fail('NOT_FOUND', 'P0404', 'snapshot'); end if;
    rows_ := bnx.balance_rows(s.projection_account_currency_ids, (s.filters->>'as_of')::date, s.ledger_version);
    rt := rows_::text;
    -- the renderer receives the rows exactly as they were digested; a replay that no longer matches is never rendered
    if bnx.h(rt) <> s.projection_sha256 then perform bnx.fail('SNAPSHOT_DIGEST_MISMATCH', 'P0409'); end if;
    return jsonb_build_object('kind', 'REPORT_RENDER', 'snapshot_id', s.id, 'report_code', s.report_code,
      'definition_version', s.report_definition_version, 'ledger_version', s.ledger_version, 'as_of', s.filters->>'as_of',
      'canonicalization', s.canonicalization, 'rows_text', rt, 'projection_sha256', encode(s.projection_sha256, 'hex'),
      'source_revision', s.ledger_version, 'ownership_revision', bnx.snapshot_ownership_revision(s),
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_currency_id', ac.id, 'label', a.label, 'currency', ac.currency)
                                             order by ac.id) from bnx.account_currency ac join bnx.account a on a.id = ac.account_id
                             where ac.id = any(s.projection_account_currency_ids)), '[]'),
      'object_prefix', 'bnx-artifacts/rpt/' || s.id::text || '/',
      'result_contract', 'render_done: snapshot_id, artifact_sha256, rendered_at, renderer_version, projection_sha256, source_revision, '
                         || 'ownership_revision, size_kib, coverage, warnings; object = object_prefix || artifact_sha256 || ''.html'', derived, never sent');
  elsif p_kind = 'BACKUP' then
    -- advisory (D-CORE8-3): the job runs only when due is true; the promoter (9016) stays the authority on every field
    due := bnx.wrk_backup_due('{}');
    return jsonb_build_object('kind', 'BACKUP') || due;
  elsif p_kind = 'RESTORE_DRILL' then
    if p_item is null then return null; end if;                        -- no run named: the promoter checks backup_run_id
    begin rid := p_item::uuid; exception when others then rid := null; end;
    select * into r from bnx.backup_run where run_id = rid and outcome = 'VERIFIED';
    if not found then perform bnx.fail('NOT_FOUND', 'P0404', 'backup run'); end if;
    return jsonb_build_object('kind', 'RESTORE_DRILL', 'backup_run_id', r.run_id, 'object_name', r.object_name,
      'object_generation', r.object_generation, 'dump_sha256', r.dump_sha256, 'plaintext_sha256', r.plaintext_sha256,
      'header_file_sha256', r.header_file_sha256, 'header_facts_sha256', encode(r.header_facts_sha256, 'hex'),
      'drill_key_id', r.drill_key_id, 'drill_fingerprint_sha256', (select recipient_fingerprint from bnx.backup_key_registry where key_id = r.drill_key_id),
      'pg_dump_version', r.pg_dump_version, 'migrations', r.header_facts->'migrations', 'header_facts', r.header_facts,
      'drill_kind', 'DRILL', 'target', 'ISOLATED_DRILL');
  elsif p_kind = 'EVIDENCE_VERIFY' then
    return jsonb_build_object('kind', 'EVIDENCE_VERIFY', 'items', coalesce((
      select jsonb_agg(jsonb_build_object('evidence_object_id', x.id, 'copy', 'R2', 'r2_key', x.r2_key) order by x.last_at nulls first, x.id)
        from (select o.id, o.r2_key, (select max(v.verified_at) from bnx.evidence_verification v where v.evidence_object_id = o.id and v.copy = 'R2') last_at
                from bnx.evidence_object o where o.sha256 is not null and o.r2_key is not null and o.dedup_into is null
               order by 3 nulls first, 1 limit 50) x), '[]'));
  elsif p_kind = 'DOC_PROCESS' then                                                                                    -- 9025
    begin did := p_item::uuid; exception when others then did := null; end;
    select * into d from bnx_doc.document_discovery where id = did;
    if not found then return null; end if;                    -- unknown item: no work order (9010/9011 behaviour)
    st := bnx.doc_state(did); sc := bnx.doc_latest_scan(did);
    step := case
      when st = 'DISCOVERED' then 'VALIDATE'
      when st in ('PENDING_DECLARATION','ADMISSIBLE','ARCHIVED','SCAN_INCOMPLETE')
           and sc.sin_detector_version is distinct from bnx.sin_detector_spec()->>'version' then 'VALIDATE'     -- re-scan due
      when st = 'ADMISSIBLE' and bnx.doc_scan_current(did) then 'ARCHIVE' end;
    -- step null: nothing to do now; the Executor stages nothing (the promoters stay the validators of record)
    if d.source_kind = 'MAIL_ATTACHMENT' then
      select m.source_ref, s2.provider into mref, mprov from bnx_intake.mail_item m join bnx_intake.mail_source s2 on s2.source_ref = m.source_ref
       where m.message_id = d.mail_message_id order by m.recorded_at desc limit 1;
    end if;
    return jsonb_strip_nulls(jsonb_build_object('kind', 'DOC_PROCESS', 'discovery_id', d.id, 'state', st, 'step', coalesce(step, 'NONE'),
      'source_kind', d.source_kind, 'source_file_id', d.source_file_id, 'head_revision_id', d.head_revision_id, 'md5', d.md5,
      'mail_message_id', d.mail_message_id, 'mime_part', d.mime_part, 'mail_source_ref', mref, 'mail_provider', mprov,
      'module', d.module, 'scan_sha256', case when step = 'ARCHIVE' then encode(sc.sha256, 'hex') end,
      'result_contract', case coalesce(step, 'NONE') when 'NONE' then 'nothing to stage now' when 'VALIDATE' then 'doc_validated: the verdict of a transient scan of exactly this revision'
                                   else 'doc_archived: re-fetch, Processed copy, re-hash; identity and sha256 must be unchanged' end));
  elsif p_kind = 'INDEX_CONSUME' then                                                                                  -- 9025
    select * into src from bnx_intake.external_index_source where source_id = p_item;
    if not found or not src.enabled then return null; end if;
    select * into cur from bnx_intake.index_consumer_cursor where source_id = src.source_id and tab = 'Records';
    return jsonb_strip_nulls(jsonb_build_object('kind', 'INDEX_CONSUME', 'source_id', src.source_id, 'adapter', src.adapter,
      'location_secret_ref', src.location_secret_ref, 'columns_contract_version', src.columns_contract_version,
      'max_processed_date_seen', cur.max_processed_date_seen, 'last_run_at', cur.last_run_at,
      'result_contract', 'index_consumed: source_id, header, records, open_items, coverage, availability, run_log (masked at staging)'));
  elsif p_kind = 'MAIL_EXACT_FETCH' or (p_kind = 'DOC_DISCOVER' and p_item like 'mail:%') then                         -- 9025
    parts := string_to_array(case when p_kind = 'DOC_DISCOVER' then substr(p_item, 6) else p_item end, '|');
    select * into src from bnx_intake.mail_source where source_ref = parts[1];
    if not found then return null; end if;
    if coalesce(parts[2], '') !~ '^<?[^<>@\s]+@[^<>@\s]+>?$' then return null; end if;
    return jsonb_build_object('kind', p_kind, 'source_ref', src.source_ref, 'provider', src.provider, 'message_id', parts[2],
                              'credential_state', src.credential_state, 'module', 'FINANCE');
  elsif p_kind = 'MAIL_MOVE' then                                                                                      -- 9025
    begin k := decode(p_item, 'hex'); exception when others then k := null; end;
    select * into it from bnx_intake.mail_item where canonical_key_sha256 = k;
    if not found then return null; end if;
    select * into src from bnx_intake.mail_source where source_ref = it.source_ref;
    fld := bnx.mail_route_folder(it);
    return jsonb_build_object('kind', 'MAIL_MOVE', 'canonical_key_sha256', encode(k, 'hex'), 'source_ref', it.source_ref,
                              'provider', src.provider, 'provider_message_id', it.provider_message_id,
                              'folder_ref', case when it.state = 'FETCHED' and it.sender_validation = 'verified' and fld is distinct from it.folder_ref then fld end,
                              'state', it.state, 'current_folder_ref', it.folder_ref);
  end if;
  return null;   -- the document and mail jobs carry their input in item_id (9010/9011 contracts)
end $$;

create function bnx.wrk_exec_due(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare k text := p->>'job_kind'; lim int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  if k = 'DOC_PROCESS' then
    return jsonb_build_object('job_kind', k, 'items', coalesce((
      select jsonb_agg(x.id::text order by x.ord, x.discovered_at, x.id) from (
        select d.id, d.discovered_at, case when c.state = 'ADMISSIBLE' and bnx.doc_scan_current(d.id) then 2 else 1 end ord
          from bnx_doc.document_discovery d join bnx_doc.document_current c on c.discovery_id = d.id
         where c.state = 'DISCOVERED'
            or (c.state in ('PENDING_DECLARATION','ADMISSIBLE','ARCHIVED','SCAN_INCOMPLETE')
                and c.sin_detector_version is distinct from bnx.sin_detector_spec()->>'version')
            or (c.state = 'ADMISSIBLE' and bnx.doc_scan_current(d.id))
         order by 3, d.discovered_at, d.id limit lim) x), '[]'));
  end if;
  if k = 'INDEX_CONSUME' then
    return jsonb_build_object('job_kind', k, 'items', coalesce((select jsonb_agg(s.source_id order by s.source_id)
      from bnx_intake.external_index_source s where s.enabled), '[]'));
  end if;
  if k = 'MAIL_MOVE' then
    return jsonb_build_object('job_kind', k, 'items', coalesce((
      select jsonb_agg(encode(x.canonical_key_sha256, 'hex') order by x.recorded_at) from (
        select m.canonical_key_sha256, m.recorded_at from bnx_intake.mail_item m
         where m.state = 'FETCHED' and m.sender_validation = 'verified' and bnx.mail_route_folder(m) is not null
           and bnx.mail_route_folder(m) is distinct from m.folder_ref
         order by m.recorded_at limit lim) x), '[]'));
  end if;
  perform bnx.fail('VALIDATION_FAILED', 'P0422', 'job_kind');
end $$;

select bnx.apply_grants();
