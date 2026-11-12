-- 9018_s4_executor_work_orders.sql -- S4 CORE-8 Executor support (UA V1.2 §9.2-§9.3, §5.8.2; WP-CORE CORE-8; closes the database
-- side of L-9013-2). Expand-only. Not in the V1.2 migration register (which lists exactly 9002-9016): added under
-- DELEGATED_DECISION D-CORE8-1 because the Executor holds no database credential for the render jobs (UA §9.2) and so
-- must receive its input with the lease, and because REPORT_RENDER completions had no promoter.
--   NEW: bnx.exec_work_order (the input of one job, built when the lease is issued: REPORT_RENDER = the snapshot's projection
--        rows exactly as digested, verified against projection_sha256; BACKUP = wrk_backup_due (advisory: the job runs
--        only when due); RESTORE_DRILL = the facts of the VERIFIED run named by item_id; EVIDENCE_VERIFY = up to 50 hashed evidence objects, least recently
--        verified first), bnx.artifact_object_name (content-addressed R2 name of a rendered artifact; derived, never sent),
--        bnx.snapshot_ownership_revision, bnx.wrk_render_done (the REPORT_RENDER promoter: payload bound to the leased
--        snapshot, projection digest and revisions recomputed, then bnx.wrk_snapshot_artifact).
--   MODIFY: bnx.wrk_issue_exec_lease (9010 body; changed only where marked "9018": the work order is built before the lease
--        row, so a refused order leaves no lease, and it is returned as "input"), bnx.wrk_promote_staged (9016 body;
--        "9018": render_done of a REPORT_RENDER lease is promoted; INDEX_RENDER / T1_RENDER stay AWAITING_PROMOTER).
set role bnx_definer;

-- ---------- artifact object name (content addressed; the staged result never carries a path, D-9016-5 / D-CORE8-4) ----------
create function bnx.artifact_object_name(p_snapshot uuid, p_sha256 text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select 'bnx-artifacts/rpt/' || p_snapshot::text || '/' || p_sha256 || '.html'
$$;

-- the ownership revision a snapshot was taken at: the latest ownership event of its projected accounts recorded at or before
-- the snapshot's ledger version (0 when none)
create function bnx.snapshot_ownership_revision(s bnx.report_snapshot) returns bigint
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce(max(e.recorded_version), 0) from bnx.account_ownership_event e
    join bnx.account_currency ac on ac.account_id = e.account_id
   where ac.id = any(s.projection_account_currency_ids) and e.recorded_version <= s.ledger_version
$$;

-- ---------- work orders (UA §9.2: the render jobs hold no database credential; §9.3: the backup job reads only as bnx_backup) ----------
create function bnx.exec_work_order(p_kind text, p_item text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s bnx.report_snapshot; rows_ jsonb; rt text; due jsonb; r bnx.backup_run; sid uuid; rid uuid;
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
  end if;
  return null;   -- the document and mail jobs carry their input in item_id (9010/9011 contracts)
end $$;

-- ---------- lease issue (MODIFY, 9010 body) ----------
create or replace function bnx.wrk_issue_exec_lease(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare n text := bnx.new_secret(); lid uuid; exp timestamptz := now() + interval '20 minutes'; inp jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  inp := bnx.exec_work_order(p->>'job_kind', p->>'item_id');           -- 9018: refused orders leave no lease row
  insert into bnx.exec_lease(job_kind, item_id, job_identity_sub, job_identity_email, job_identity_azp, nonce, expires_at)
  values (p->>'job_kind', p->>'item_id', p->>'sub', p->>'email', p->>'azp', bnx.h(n), exp) returning lease_id into lid;
  return jsonb_build_object('lease_id', lid, 'nonce', n, 'expires_at', exp, 'job_kind', p->>'job_kind', 'input', inp);   -- 9018: input
exception when check_violation or not_null_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'lease');
end $$;

-- ---------- REPORT_RENDER promoter ----------
create function bnx.wrk_render_done(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; snap bnx.report_snapshot; sha text; r jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind, l.item_id into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id
   where p.id = p_staging for update of p;
  if not found or s.stg_kind <> 'render_done' or s.job_kind <> 'REPORT_RENDER' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;                        -- idempotent replay
  pl := s.payload;
  if exists (select 1 from jsonb_object_keys(pl) k where k not in ('snapshot_id','artifact_sha256','rendered_at','renderer_version',
       'projection_sha256','source_revision','ownership_revision','size_kib','coverage','warnings','usage')) then
    return bnx.doc_reject(p_staging, 'FIELD'); end if;
  if pl->>'snapshot_id' is distinct from s.item_id then return bnx.doc_reject(p_staging, 'ITEM_MISMATCH'); end if;  -- bound to the lease
  select * into snap from bnx.report_snapshot where id = s.item_id::uuid;
  if not found then return bnx.doc_reject(p_staging, 'SNAPSHOT_UNKNOWN'); end if;
  if pl->>'projection_sha256' is distinct from encode(snap.projection_sha256, 'hex') then return bnx.doc_reject(p_staging, 'PROJECTION_DIGEST'); end if;
  if pl->>'source_revision' is distinct from snap.ledger_version::text
     or pl->>'ownership_revision' is distinct from bnx.snapshot_ownership_revision(snap)::text then
    return bnx.doc_reject(p_staging, 'REVISION'); end if;
  sha := bnx.backup_hex(pl->>'artifact_sha256');
  if sha is null or jsonb_typeof(coalesce(pl->'size_kib', 'null')) <> 'number' or (pl->>'size_kib')::numeric < 0
     or (pl ? 'warnings' and jsonb_typeof(pl->'warnings') <> 'array') then
    return bnx.doc_reject(p_staging, 'ARTIFACT_FACTS'); end if;
  begin
    r := bnx.wrk_snapshot_artifact(snap.id, (pl - 'usage' - 'size_kib' - 'projection_sha256' - 'snapshot_id')
                                            || jsonb_build_object('artifact_ref', 'r2:' || bnx.artifact_object_name(snap.id, sha), 'artifact_sha256', sha));
  exception when sqlstate 'P0422' then return bnx.doc_reject(p_staging, 'ARTIFACT_FACTS');
  end;
  if pl ? 'usage' then perform bnx.usage_insert(pl->'usage' || jsonb_build_object('job', 'REPORT_RENDER')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'snapshot_id', snap.id, 'seq', r->'seq',
                                                    'artifact_ref', 'r2:' || bnx.artifact_object_name(snap.id, sha)));
end $$;

-- ---------- staging dispatch (MODIFY, 9016 body) ----------
create or replace function bnx.wrk_promote_staged(p_staging uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; r jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id   -- 9018: job kind
   where p.id = p_staging;
  if not found then return 'not_found'; end if;
  if s.state in ('PROMOTED','REJECTED') then return lower(s.state); end if;
  if s.stg_kind = 'index_consumed' then r := bnx.wrk_consume_shared_index(p_staging);
  elsif s.stg_kind = 'mail_fetched' and s.payload->>'op' = 'move' then r := bnx.wrk_mail_move_result(p_staging);
  elsif s.stg_kind = 'mail_fetched' then r := bnx.wrk_mail_evidence_registered(p_staging);
  elsif s.stg_kind = 'doc_discovered' then r := bnx.wrk_doc_discovered(p_staging);       -- 9011b
  elsif s.stg_kind = 'doc_validated' then r := bnx.wrk_doc_validated(p_staging);         -- 9011b
  elsif s.stg_kind = 'doc_archived' then r := bnx.wrk_doc_archived(p_staging);           -- 9011b (admission gate)
  elsif s.stg_kind = 'backup_recorded' then r := bnx.wrk_backup_recorded(p_staging);     -- 9016 (BACKUP, EVIDENCE_VERIFY)
  elsif s.stg_kind = 'restore_drill_recorded' then r := bnx.wrk_restore_drill_recorded(p_staging);   -- 9016
  elsif s.stg_kind = 'render_done' and s.job_kind = 'REPORT_RENDER' then r := bnx.wrk_render_done(p_staging);   -- 9018
  else
    update bnx_intake.staging_payload set state = 'AWAITING_PROMOTER' where id = p_staging;   -- 9011c / 9014 / INDEX_RENDER / T1_RENDER
    return 'awaiting_promoter';
  end if;
  return lower(coalesce(r->>'status', 'promoted'));
end $$;

select bnx.apply_grants();
