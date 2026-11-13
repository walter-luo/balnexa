-- 9039_s4_null_safe_guards.sql -- G0 remediation, round 2 (independent G0 re-run 2026-11-13, finding G0-IND-01 of R2).
-- The re-run's PG17 drill failure was an Executor environment problem (the drill provisioner started the migration runner
-- as a bare "python3" from PATH; see apps/executor/bnx_exec/restore.py). Its recorded reasons exposed a database defect:
-- a guard written "jsonb_typeof(x) <> 'object'" is NULL, not true, when x is absent, so PL/pgSQL skips the branch. The
-- same pattern was audited across the latest definitions; six functions let an absent field through:
--   MODIFY bnx.wrk_restore_drill_recorded (9016): a drill result without restored_header was recorded as
--          HEADER_FACTS_DIFFER (with a meaningless mismatch list) instead of NO_RESTORED_HEADER. Outcome was FAIL either way.
--   MODIFY bnx.wrk_backup_recorded (9016): a header without "format" (or without tables/migrations/audit_head) was accepted
--          and the run recorded VERIFIED. Now rejected (HEADER).
--   MODIFY bnx.wrk_evidence_state (9016): an EVIDENCE_VERIFY result without items was promoted as "verified 0". Now ITEMS.
--   MODIFY bnx.install_activate_config (9029): worker_supports_extension [] (or with missing/non-version elements) let the
--          configuration activate without the B3 range check. Now B3 unless it is exactly two 4-digit versions around head.
--   MODIFY bnx.plan_create (9010): a plan command without items created an empty plan. Now VALIDATION_FAILED items.
--   MODIFY bnx.cmd_create_account (9006): an account without currencies (or without kind) passed validation. Now
--          VALIDATION_FAILED account.
-- Every changed line is marked "-- 9039"; the rest of each body is the latest definition unchanged.
-- No catalog delta: no catalog entry changes. No stored data changes.
-- Authority: S4 G0 remediation; docs/s4/reviews/g0/20261113_chatgpt-codex-r2/.
set role bnx_definer;

-- ---------- MODIFY bnx.wrk_restore_drill_recorded (9016) ----------
create or replace function bnx.wrk_restore_drill_recorded(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; b bnx.backup_run; st timestamptz; en timestamptz; why text[] := '{}'; mm jsonb := '[]'; k bnx.backup_key_registry;
        ks text; kh text; auth bnx.restore_authorization; outc text; tgt text; knd text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'restore_drill_recorded' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.backup_payload_ok(pl) then return bnx.doc_reject(p_staging, 'KEY_MATERIAL_REFUSED'); end if;
  if exists (select 1 from jsonb_object_keys(pl) jk where jk not in ('drill_id','backup_run_id','kind','target','decrypt_key_id','started_at',
       'ended_at','outcome','restored_header','cleanup_verified','tools','failure_reason','authorization_id','usage')) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  begin
    st := (pl->>'started_at')::timestamptz; en := (pl->>'ended_at')::timestamptz;
    select * into b from bnx.backup_run where run_id = (pl->>'backup_run_id')::uuid;
  exception when others then return bnx.doc_reject(p_staging, 'FIELDS');
  end;
  if b.run_id is null then return bnx.doc_reject(p_staging, 'UNKNOWN_BACKUP'); end if;
  if b.outcome <> 'VERIFIED' then return bnx.doc_reject(p_staging, 'BACKUP_NOT_VERIFIED'); end if;
  if st is null or en is null or en < st or coalesce(pl->>'drill_id', '') !~ '^[0-9a-f-]{36}$' then return bnx.doc_reject(p_staging, 'TIMES_OR_ID'); end if;
  knd := coalesce(pl->>'kind', 'DRILL'); tgt := coalesce(pl->>'target', 'ISOLATED_DRILL');
  if knd not in ('DRILL','RESTORE_SAME_IDENTITY','RESTORE_AS_NEW') or tgt not in ('ISOLATED_DRILL','NEW_PROJECT','PRODUCTION')
     or (knd = 'DRILL') <> (tgt = 'ISOLATED_DRILL') then return bnx.doc_reject(p_staging, 'KIND_TARGET'); end if;
  if coalesce(pl->>'outcome', '') not in ('PASS','FAIL') then return bnx.doc_reject(p_staging, 'OUTCOME'); end if;
  select * into k from bnx.backup_key_registry where key_id = pl->>'decrypt_key_id';
  if k.key_id is null then return bnx.doc_reject(p_staging, 'UNKNOWN_KEY'); end if;
  if pl->>'outcome' = 'FAIL' then why := why || coalesce(left(pl->>'failure_reason', 120), 'REPORTED_FAIL'); end if;
  -- key rules (S4B-F24; Backup §10.4)
  if knd = 'DRILL' and k.role <> 'DRILL' then why := why || 'DRILL_WITH_OWNER_KEY'::text; end if;
  if k.key_id is distinct from b.drill_key_id and k.key_id is distinct from b.owner_key_id then why := why || 'KEY_NOT_RECIPIENT'::text; end if;
  ks := bnx.backup_key_state(k.key_id, st);
  if ks = 'PRUNED' then why := why || 'KEY_PRUNED'::text; end if;
  select handling into kh from bnx.backup_key_event where key_id = k.key_id and event = 'COMPROMISED' and at <= st order by seq desc limit 1;
  if kh = 'OWNER_KEY_TEST_ONLY' and k.role = 'DRILL' then why := why || 'KEY_COMPROMISED_OWNER_TEST_ONLY'::text; end if;
  -- header facts of the restored database
  if jsonb_typeof(pl->'restored_header') is distinct from 'object' then why := why || 'NO_RESTORED_HEADER'::text;   -- 9039
  else
    mm := bnx.bkp_header_compare(b.header_facts, pl->'restored_header');
    if mm <> '[]' then why := why || 'HEADER_FACTS_DIFFER'::text; end if;
  end if;
  if coalesce((pl->>'cleanup_verified')::boolean, false) is not true and knd = 'DRILL' then why := why || 'CLEANUP_NOT_VERIFIED'::text; end if;
  -- production / new project: Owner authorization (INV-45)
  if tgt <> 'ISOLATED_DRILL' then
    begin
      select * into auth from bnx.restore_authorization where id = (pl->>'authorization_id')::uuid;
    exception when others then auth := null;
    end;
    if auth.id is null or auth.backup_run_id <> b.run_id or auth.target <> tgt or auth.expires_at < st or auth.authorized_at > st
       or exists (select 1 from bnx.restore_drill d where d.authorization_id = auth.id) then
      perform bnx.notify('EXCEPTION', 'RESTORE_UNAUTHORIZED:' || p_staging, true, jsonb_build_object('kind', 'RESTORE_WITHOUT_AUTHORIZATION', 'record_key', b.run_id::text));
      return bnx.doc_reject(p_staging, 'RESTORE_NOT_AUTHORIZED');
    end if;
  end if;
  outc := case when cardinality(why) = 0 then 'PASS' else 'FAIL' end;
  begin
    insert into bnx.restore_drill(drill_id, staging_id, backup_run_id, kind, target, decrypt_key_id, started_at, ended_at, duration_seconds,
      reported_outcome, outcome, reasons, header_mismatches, cleanup_verified, pg_restore_version, server_version, authorization_id)
    values ((pl->>'drill_id')::uuid, p_staging, b.run_id, knd, tgt, k.key_id, st, en, extract(epoch from en - st), pl->>'outcome', outc,
      case when outc = 'FAIL' then why else '{}' end, case when outc = 'FAIL' then mm else '[]' end,
      coalesce((pl->>'cleanup_verified')::boolean, false), pl#>>'{tools,pg_restore}', pl#>>'{tools,server}', auth.id);
  exception when unique_violation then return bnx.doc_reject(p_staging, 'DUPLICATE_DRILL');
            when check_violation or not_null_violation or invalid_text_representation then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  if outc = 'FAIL' then
    perform bnx.notify('EXCEPTION', 'RESTORE_DRILL_FAILED:' || (pl->>'drill_id'), true, jsonb_build_object('kind', 'RESTORE_DRILL_FAILED', 'record_key', b.run_id::text));
  end if;
  if tgt <> 'ISOLATED_DRILL' and outc = 'PASS' then
    insert into bnx.release_install_event(release_version, kind, detail)
    values (coalesce(pl#>>'{tools,release}', 'unknown'), 'RESTORE', jsonb_build_object('drill_id', pl->>'drill_id', 'backup_run_id', b.run_id, 'restore_kind', knd, 'target', tgt));
  end if;
  if pl ? 'usage' then perform bnx.usage_insert(pl->'usage' || jsonb_build_object('job', 'RESTORE_DRILL')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'drill_id', pl->>'drill_id', 'outcome', outc, 'reasons', to_jsonb(why),
    'restorable', bnx.backup_restorable(b.run_id)));
end $$;

-- ---------- MODIFY bnx.wrk_backup_recorded (9016) ----------
create or replace function bnx.wrk_backup_recorded(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; job text; t jsonb; why text; st timestamptz; en timestamptz; hf jsonb; ac text; aseq bigint; ahash text;
        live bytea; outc text; pol jsonb; ok_keys text[] := array['run_id','started_at','ended_at','local_date','tier','retain_until',
        'destination','outcome','failure_reason','object','sizes','dump_sha256','plaintext_sha256','header_sha256','tools','verify',
        'recipients','header','usage'];
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id where p.id = p_staging for update of p;
  if not found or s.stg_kind <> 'backup_recorded' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  if s.job_kind = 'EVIDENCE_VERIFY' then return bnx.wrk_evidence_state(p_staging); end if;
  pl := s.payload;
  if not bnx.backup_payload_ok(pl) then
    perform bnx.notify('EXCEPTION', 'BACKUP_KEY_MATERIAL:' || p_staging, true, jsonb_build_object('kind', 'BACKUP_KEY_MATERIAL_IN_PAYLOAD', 'record_key', p_staging::text));
    return bnx.doc_reject(p_staging, 'KEY_MATERIAL_REFUSED');
  end if;
  if exists (select 1 from jsonb_object_keys(pl) k where k <> all(ok_keys))
     or (pl ? 'object' and (jsonb_typeof(pl->'object') <> 'object' or exists (select 1 from jsonb_object_keys(pl->'object') k where k <> 'generation')))
     or (pl ? 'sizes' and (jsonb_typeof(pl->'sizes') <> 'object' or exists (select 1 from jsonb_object_keys(pl->'sizes') k where k not in ('compressed_kib','wire_kib')))) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  begin
    st := (pl->>'started_at')::timestamptz; en := (pl->>'ended_at')::timestamptz;
  exception when others then return bnx.doc_reject(p_staging, 'TIMES');
  end;
  if st is null or en is null or en < st or pl->>'run_id' !~ '^[0-9a-f-]{36}$' then return bnx.doc_reject(p_staging, 'TIMES_OR_RUN_ID'); end if;
  if exists (select 1 from bnx.backup_run where run_id = (pl->>'run_id')::uuid) then return bnx.doc_reject(p_staging, 'DUPLICATE_RUN'); end if;
  t := bnx.backup_tier(st); pol := bnx.backup_policy(); outc := pl->>'outcome';
  if outc not in ('VERIFIED','FAILED') then return bnx.doc_reject(p_staging, 'OUTCOME'); end if;
  if coalesce(pl->>'local_date', '') <> t->>'local_date' or coalesce(pl->>'tier', '') <> t->>'tier' then return bnx.doc_reject(p_staging, 'TIER_MISMATCH'); end if;
  if outc = 'VERIFIED' then
    -- retention set on the object at creation must not be shorter than the tier's (1 h clock tolerance)
    begin
      if (pl->>'retain_until')::timestamptz < (t->>'retain_until')::timestamptz - interval '1 hour' then return bnx.doc_reject(p_staging, 'RETENTION_SHORT'); end if;
    exception when others then return bnx.doc_reject(p_staging, 'RETENTION');
    end;
    if coalesce(pl->>'destination', '') <> 'OFF_PROVIDER' then return bnx.doc_reject(p_staging, 'DESTINATION'); end if;
    if exists (select 1 from bnx.backup_run where local_date = (t->>'local_date')::date and outcome = 'VERIFIED') then
      perform bnx.notify('EXCEPTION', 'BACKUP_DUPLICATE_DATE:' || (t->>'local_date'), true, jsonb_build_object('kind', 'BACKUP_DUPLICATE_LOCAL_DATE', 'record_key', t->>'local_date'));
      return bnx.doc_reject(p_staging, 'DUPLICATE_LOCAL_DATE');
    end if;
    if bnx.backup_hex(pl->>'dump_sha256') is null or bnx.backup_hex(pl->>'plaintext_sha256') is null or bnx.backup_hex(pl->>'header_sha256') is null then
      return bnx.doc_reject(p_staging, 'DIGESTS'); end if;
    -- UA §9.3 step 7: pg_dump major >= server major; pg_restore of the same major as pg_dump
    if bnx.backup_major(pl#>>'{tools,pg_dump}') is null or bnx.backup_major(pl#>>'{tools,server}') is null
       or bnx.backup_major(pl#>>'{tools,pg_dump}') < bnx.backup_major(pl#>>'{tools,server}')
       or bnx.backup_major(pl#>>'{tools,pg_restore}') is distinct from bnx.backup_major(pl#>>'{tools,pg_dump}') then
      return bnx.doc_reject(p_staging, 'TOOL_MAJOR'); end if;
    -- K2 recipients: the Owner key and the drill key that were ACTIVE at the start, fingerprints equal to the registry
    -- (an archive without a drill recipient is refused: S4B-F24)
    if pl#>>'{recipients,owner_key_id}' is distinct from bnx.backup_key_active('OWNER', st)
       or pl#>>'{recipients,drill_key_id}' is distinct from bnx.backup_key_active('DRILL', st)
       or pl#>>'{recipients,owner_fingerprint_sha256}' is distinct from (select recipient_fingerprint from bnx.backup_key_registry where key_id = pl#>>'{recipients,owner_key_id}')
       or pl#>>'{recipients,drill_fingerprint_sha256}' is distinct from (select recipient_fingerprint from bnx.backup_key_registry where key_id = pl#>>'{recipients,drill_key_id}') then
      return bnx.doc_reject(p_staging, 'RECIPIENTS'); end if;
    -- step 8: re-downloaded, decrypted with the drill identity, pg_restore --list, hash compare
    if coalesce((pl#>>'{verify,redownload_sha256_equal}')::boolean, false) is not true or coalesce((pl#>>'{verify,pg_restore_list_ok}')::boolean, false) is not true
       or pl#>>'{verify,decrypted_with}' is distinct from pl#>>'{recipients,drill_key_id}' then
      return bnx.doc_reject(p_staging, 'NOT_VERIFIED'); end if;
    hf := pl->'header';
    if jsonb_typeof(hf) is distinct from 'object' or hf->>'format' is distinct from 'bnx-backup-header-facts/1'                -- 9039
       or jsonb_typeof(hf->'tables') is distinct from 'object' or jsonb_typeof(hf->'migrations') is distinct from 'array'          -- 9039
       or jsonb_typeof(hf->'audit_head') is distinct from 'object' then                                                          -- 9039
      return bnx.doc_reject(p_staging, 'HEADER'); end if;
    -- anchor (R-11): the live chain must hold the recorded head hash at the recorded seq
    aseq := (hf#>>'{audit_head,seq}')::bigint; ahash := hf#>>'{audit_head,hash}';
    if aseq = 0 then ac := 'EMPTY_CHAIN';
    else
      select hash into live from bnx_audit.audit_event where seq = aseq;
      ac := case when live is not null and encode(live, 'hex') = ahash then 'MATCH' else 'MISMATCH' end;
    end if;
    if ac = 'MISMATCH' then
      perform bnx.notify('EXCEPTION', 'AUDIT_ANCHOR_MISMATCH:' || (pl->>'run_id'), true, jsonb_build_object('kind', 'AUDIT_ANCHOR_MISMATCH', 'record_key', pl->>'run_id'));
    end if;
  else
    if coalesce(pl->>'failure_reason', '') = '' then return bnx.doc_reject(p_staging, 'FAILURE_REASON'); end if;
  end if;
  begin
    insert into bnx.backup_run(run_id, staging_id, started_at, ended_at, local_date, tier, retain_until, policy, destination, outcome, failure_reason,
      object_name, object_generation, dump_sha256, plaintext_sha256, header_file_sha256, compressed_bytes, wire_bytes, pg_dump_version,
      pg_restore_version, server_version, owner_key_id, drill_key_id, header_facts, header_facts_sha256, migrations_sha256, ledger_version,
      anchor_seq, anchor_hash, anchor_check)
    values ((pl->>'run_id')::uuid, p_staging, st, en, (t->>'local_date')::date, t->>'tier',
      greatest((t->>'retain_until')::timestamptz, coalesce((pl->>'retain_until')::timestamptz, (t->>'retain_until')::timestamptz)),
      pol->>'policy', 'OFF_PROVIDER', outc, case when outc = 'FAILED' then left(pl->>'failure_reason', 200) end,
      case when outc = 'VERIFIED' then bnx.backup_object_name(st, (pl->>'run_id')::uuid) end, pl#>>'{object,generation}', pl->>'dump_sha256',
      pl->>'plaintext_sha256', pl->>'header_sha256',
      (pl#>>'{sizes,compressed_kib}')::bigint * 1024, (pl#>>'{sizes,wire_kib}')::bigint * 1024, pl#>>'{tools,pg_dump}', pl#>>'{tools,pg_restore}',
      pl#>>'{tools,server}', pl#>>'{recipients,owner_key_id}', pl#>>'{recipients,drill_key_id}', hf, case when hf is not null then bnx.h(hf::text) end,
      case when hf is not null then bnx.h((hf->'migrations')::text) end, (hf->>'ledger_version')::bigint, aseq, ahash, ac);
  exception when check_violation or not_null_violation or foreign_key_violation or invalid_text_representation or numeric_value_out_of_range then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  if outc = 'FAILED' then
    perform bnx.notify('EXCEPTION', 'BACKUP_FAILED:' || (t->>'local_date'), true, jsonb_build_object('kind', 'BACKUP_FAILED', 'record_key', t->>'local_date'));
  end if;
  -- a policy switch is an alert (AT-BKP-13); P-D is raised to the Owner
  if outc = 'VERIFIED' and (bnx.backup_policy()->>'policy') <> (pol->>'policy') then
    perform bnx.notify('EXCEPTION', 'BACKUP_POLICY:' || (bnx.backup_policy()->>'policy') || ':' || (t->>'local_date'), true,
      jsonb_build_object('kind', 'BACKUP_POLICY_CHANGED', 'record_key', bnx.backup_policy()->>'policy'));
  end if;
  if pl ? 'usage' then perform bnx.usage_insert(pl->'usage' || jsonb_build_object('job', 'BACKUP')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'run_id', pl->>'run_id', 'outcome', outc, 'tier', t->>'tier',
    'policy', pol->>'policy', 'anchor_check', ac));
end $$;

-- ---------- MODIFY bnx.wrk_evidence_state (9016) ----------
create or replace function bnx.wrk_evidence_state(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; it jsonb; o bnx.evidence_object; res text; n int := 0; bad int := 0;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id where p.id = p_staging for update of p;
  if not found or s.stg_kind <> 'backup_recorded' or s.job_kind <> 'EVIDENCE_VERIFY' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  if exists (select 1 from jsonb_object_keys(s.payload) k where k not in ('items','started_at','ended_at','usage'))
     or jsonb_typeof(s.payload->'items') is distinct from 'array' or jsonb_array_length(s.payload->'items') = 0                  -- 9039
     or jsonb_array_length(s.payload->'items') > 500 then
    return bnx.doc_reject(p_staging, 'ITEMS'); end if;
  -- validate every item before writing any row (a rejected result leaves nothing behind)
  for it in select * from jsonb_array_elements(s.payload->'items') loop
    if jsonb_typeof(it) <> 'object' or exists (select 1 from jsonb_object_keys(it) k where k not in ('evidence_object_id','copy','observed_sha256'))
       or bnx.backup_hex(it->>'observed_sha256') is null or coalesce(it->>'copy', '') not in ('R2','DRIVE')
       or coalesce(it->>'evidence_object_id', '') !~ '^[0-9a-fA-F-]{36}$' then
      return bnx.doc_reject(p_staging, 'ITEM'); end if;
    if not exists (select 1 from bnx.evidence_object where id = (it->>'evidence_object_id')::uuid) then return bnx.doc_reject(p_staging, 'UNKNOWN_EVIDENCE'); end if;
  end loop;
  if (select count(*) from jsonb_array_elements(s.payload->'items') x) <>
     (select count(distinct (x->>'evidence_object_id', x->>'copy')) from jsonb_array_elements(s.payload->'items') x) then
    return bnx.doc_reject(p_staging, 'DUPLICATE_ITEM'); end if;
  for it in select * from jsonb_array_elements(s.payload->'items') loop
    select * into o from bnx.evidence_object where id = (it->>'evidence_object_id')::uuid;
    -- an object whose SHA-256 was never set by the executor has no reference to compare with (never reported as a mismatch)
    res := case when o.sha256 is null then 'NO_REFERENCE' when encode(o.sha256, 'hex') = it->>'observed_sha256' then 'MATCH' else 'MISMATCH' end;
    insert into bnx.evidence_verification(staging_id, evidence_object_id, copy, observed_sha256, result, evidence_status)
    values (p_staging, o.id, it->>'copy', it->>'observed_sha256', res, bnx.evidence_status(o.id));
    n := n + 1;
    if res = 'MISMATCH' then
      bad := bad + 1;
      perform bnx.notify('EXCEPTION', 'EVIDENCE_HASH_MISMATCH:' || o.id || ':' || (it->>'copy'), true,
        jsonb_build_object('kind', 'EVIDENCE_HASH_MISMATCH', 'record_key', o.id::text));
    end if;
  end loop;
  if s.payload ? 'usage' then perform bnx.usage_insert(s.payload->'usage' || jsonb_build_object('job', 'EVIDENCE_VERIFY')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'verified', n, 'mismatches', bad));
end $$;

-- ---------- MODIFY bnx.install_activate_config (9029) ----------
create or replace function bnx.install_activate_config(p_config_version int, p_deployed_digest text, p_deployed_env jsonb) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare an record; idt record; prev int; k text; hd text;                                       -- 9029: hd
begin
  if session_user <> 'bnx_migrator' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into an from bnx.config_version_anchor where config_version = p_config_version for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if an.state <> 'PENDING_DEPLOY' then perform bnx.fail('CONFIG_STATE', 'P0409', an.state || ' -> ACTIVE'); end if;
  if p_deployed_digest is null or p_deployed_digest !~ '^[0-9a-f]{64}$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'deployed_digest'); end if;
  if an.config_sha256 is not null and an.config_sha256 <> p_deployed_digest then
    perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B2 config digest'); end if;
  select * into idt from bnx.instance_identity;
  if not found or p_deployed_env->>'project_id' is distinct from idt.project_id
     or p_deployed_env->>'instance_uid' is distinct from idt.instance_uid::text then
    perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B1 instance identity'); end if;
  -- 9029 deploy rule (UA V1.2 §9.1; INS-1 R3): when the installer states the deployed Worker's schema range, the applied
  -- extension head must lie inside it, so a Worker that does not understand this schema is never activated against it
  if p_deployed_env ? 'worker_supports_extension' then                                                                  -- 9029
    hd := (select max(version) from bnx.schema_migrations where version >= '9000');
    if jsonb_typeof(p_deployed_env->'worker_supports_extension') is distinct from 'array'                                      -- 9039
       or jsonb_array_length(p_deployed_env->'worker_supports_extension') <> 2                                                    -- 9039
       or coalesce(p_deployed_env->'worker_supports_extension'->>0, '') !~ '^[0-9]{4}$'                                         -- 9039
       or coalesce(p_deployed_env->'worker_supports_extension'->>1, '') !~ '^[0-9]{4}$'                                         -- 9039
       or hd is null                                                                                                               -- 9039
       or hd < p_deployed_env->'worker_supports_extension'->>0 or hd > p_deployed_env->'worker_supports_extension'->>1 then
      perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B3 deployed worker range excludes schema head ' || coalesce(hd, 'none')); end if;
  end if;
  if not bnx.config_modules_valid(p_deployed_env->'modules') then perform bnx.fail('BNX_FLAG_BINDING_MISMATCH', 'P0409', 'B8'); end if;
  for k in select flag_key from bnx.instance_module_flag where config_version = p_config_version loop
    if (select value from bnx.instance_module_flag where config_version = p_config_version and flag_key = k)
       is distinct from p_deployed_env->'modules'->>k then
      perform bnx.fail('BNX_FLAG_BINDING_MISMATCH', 'P0409', 'B8 ' || k); end if;
  end loop;
  select config_version into prev from bnx.config_version_anchor where state = 'ACTIVE' for update;
  if prev is not null then perform bnx.config_transition(prev, 'SUPERSEDED', null, jsonb_build_object('by_version', p_config_version)); end if;
  if an.config_sha256 is null then
    update bnx.config_version_anchor set config_sha256 = p_deployed_digest where config_version = p_config_version;
  end if;
  perform bnx.config_transition(p_config_version, 'ACTIVE', null,
            jsonb_build_object('deployed_digest', p_deployed_digest, 'digest_bound_at_activation', an.config_sha256 is null));
  update bnx.config_version_anchor set activated_at = now(), deployed_digest = p_deployed_digest where config_version = p_config_version;
  perform bnx.audit(row(null, null, 'installer', null, null)::bnx.actor, 'install_activate_config',
                    jsonb_build_object('config_version', p_config_version, 'superseded', prev), p_deployed_env, null);
  return 'ACTIVE';
end $$;

-- ---------- MODIFY bnx.plan_create (9010) ----------
create or replace function bnx.plan_create(a bnx.actor, p_kind text, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare p uuid := gen_random_uuid(); acid uuid := (cmd->>'account_currency_id')::uuid; ac record; it jsonb; i int := 0; vnow bigint; rng daterange;
        ph bytea; sd bytea; cla record; ev jsonb := coalesce(cmd->'evidence_file_ids', '[]'); f text; et text; draft boolean := p_kind in ('ai_draft','member_draft','handoff');
        scope jsonb; v jsonb; items jsonb := '[]'; l jsonb; lac record; amt numeric; k text;
begin
  if p_kind not in ('import','ai_draft','handoff','onboarding','member_draft') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'kind'); end if;
  if jsonb_typeof(cmd->'items') is distinct from 'array' or jsonb_array_length(cmd->'items') = 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'items'); end if;  -- 9039
  if p_kind = 'member_draft' and jsonb_array_length(cmd->'items') <> 1 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'member_draft has one item'); end if;
  if not (acid in (select bnx.actor_visible_acs(a))) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  for f in select jsonb_array_elements_text(ev) loop
    if bnx.can_read_evidence(a.member_id, f::uuid) = 'denied' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  end loop;
  select * into ac from bnx.account_currency where id = acid;
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
  select version into vnow from bnx.ledger_state;
  rng := case when draft then daterange((cmd->>'date_from')::date, (cmd->>'date_to')::date + 1, '[)')
              else daterange((cmd->>'date_from')::date - 10, (cmd->>'date_to')::date + 11, '[)') end;
  -- every item is rebuilt from an allowlist of keys (same-family review findings 1, 2, 5): the stored payload is exactly
  -- what validation saw; types the direct path refuses are refused here too; typed items take their amount from the plan
  -- account line; every household account line must be visible to the caller; clearing_open only on handoff legs
  for it in select * from jsonb_array_elements(cmd->'items') loop
    if jsonb_typeof(it) <> 'object' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item'); end if;
    for k in select jsonb_object_keys(it) loop
      if not k = any(array['transaction_date','description','amount','counter_ledger_account_id','economic_type','lines','source_fingerprint',
                            'evidence_sha256','needs_review','currency','clearing_open']) or (k = 'clearing_open' and p_kind <> 'handoff') then
        perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item field ' || k); end if;
    end loop;
    if coalesce(btrim(it->>'description'), '') = '' or length(it->>'description') > 500 then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item description'); end if;
    if it->>'economic_type' in ('opening_balance','correction_reversal','correction_replacement','interledger_transfer','clearing_resolution') then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'economic_type ' || (it->>'economic_type') || ' is not available on the plan path'); end if;
    if it ? 'economic_type' and not exists (select 1 from bnx.economic_type_rule where economic_type::text = it->>'economic_type') then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'economic_type'); end if;
    if it ? 'lines' then
      et := it->>'economic_type';
      if et is null or jsonb_typeof(it->'lines') <> 'array' or jsonb_array_length(it->'lines') < 2 or it ? 'counter_ledger_account_id' then
        perform bnx.fail('VALIDATION_FAILED', 'P0422', 'typed item needs economic_type and two or more lines'); end if;
      amt := 0;
      for l in select * from jsonb_array_elements(it->'lines') loop
        select la.*, x.id acid into lac from bnx.ledger_account la left join bnx.account_currency x on x.ledger_account_id = la.id
         where la.id = (l->>'ledger_account_id')::uuid;
        if lac.id is null or lac.currency <> l->>'currency' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'line ledger account'); end if;
        if lac.acid is not null and not (lac.acid in (select bnx.actor_visible_acs(a))) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
        perform bnx.assert_scale(bnx.dec(l, 'amount'), lac.currency, 'plan line');
        if lac.id = ac.ledger_account_id then amt := amt + (l->>'amount')::numeric; end if;
      end loop;
      if not exists (select 1 from jsonb_array_elements(it->'lines') x where (x->>'ledger_account_id')::uuid = ac.ledger_account_id) then
        perform bnx.fail('VALIDATION_FAILED', 'P0422', 'typed item must touch the plan account'); end if;
      it := jsonb_set(it, '{amount}', to_jsonb(amt::text));       -- never the caller's figure
    else
      select * into cla from bnx.ledger_account where id = (it->>'counter_ledger_account_id')::uuid;
      if not found or cla.kind not in ('income','expense','clearing') or cla.currency <> ac.currency then
        perform bnx.fail('VALIDATION_FAILED', 'P0422', 'counter ledger account'); end if;
      perform bnx.assert_scale(bnx.dec(it, 'amount'), ac.currency, 'plan item');
    end if;
    if (it->>'transaction_date')::date not between (cmd->>'date_from')::date and (cmd->>'date_to')::date then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item date outside plan range'); end if;
    items := items || jsonb_build_array(it);
  end loop;
  ph := bnx.h(acid::text || '|' || rng::text || '|' || items::text || '|' || ev::text
              || case when p_kind = 'import' then '' else '|' || p_kind end);   -- R1 import hash unchanged
  sd := bnx.scope_digest(ac.ledger_account_id, acid, rng, vnow);
  scope := jsonb_build_object('account_currency_id', acid, 'range', rng::text, 'evidence_file_ids', ev)
           || case when cmd ? 'statement' then jsonb_build_object('statement', cmd->'statement') else '{}' end
           || case when cmd ? 'require_fingerprints' then jsonb_build_object('require_fingerprints', cmd->'require_fingerprints') else '{}' end;
  insert into bnx.posting_plan(id, kind, scope, item_count, control_totals, plan_hash, state, frozen_at_version, last_validated_version, scope_digest,
                               origin_channel, origin_ai_connection_id, created_by, supersedes_plan_id)
  values (p, p_kind, scope, jsonb_array_length(items),
          jsonb_build_object('sum', (select sum(coalesce((x->>'amount')::numeric, 0)) from jsonb_array_elements(items) x)::text),
          ph, 'frozen', vnow, vnow, sd, a.channel, a.connection_id, a.member_id, (cmd->>'supersedes_plan_id')::uuid);
  for it in select * from jsonb_array_elements(items) loop
    i := i + 1;
    insert into bnx.posting_plan_item values (p, i, 'new_journal', '{}', it, bnx.h(it::text), 1, null);
  end loop;
  if not draft then                                -- drafts and handoff legs claim no range (single new journals)
    begin
      insert into bnx.posting_scope_claim values (p, acid, rng, 'held', vnow, null);
    exception when exclusion_violation then perform bnx.fail('SCOPE_CLAIM_CONFLICT', 'P0409');
    end;
  end if;
  insert into bnx.plan_event values (p, 1, 'frozen', vnow, vnow, null, null, a.member_id, now());
  v := bnx.intake_validate(p);                                      -- at freeze (UA §5.5.3)
  return jsonb_build_object('plan_id', p, 'plan_hash', encode(ph,'hex'), 'scope_digest', encode(sd,'hex'), 'frozen_at_version', vnow,
                            'kind', p_kind, 'hold_reasons', v->'hold_reasons', 'validation_result', v->'validation_result');
end $$;

-- ---------- MODIFY bnx.cmd_create_account (9006) ----------
create or replace function bnx.cmd_create_account(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; acc uuid := gen_random_uuid(); inst uuid; cur text; ins record;
        la uuid; acid uuid; res jsonb := '[]'; v bigint; kind text := cmd->>'kind'; lkind text; vis text := coalesce(cmd->>'visibility','household');
        region text; tz text;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'create_account', cmd); if rc is not null then return rc; end if;
  if coalesce(kind, '') not in ('bank_deposit','cash','e_wallet','credit_card','investment','loan_payable','loan_receivable','other_asset')  -- 9039
     or vis not in ('household','private') or coalesce(cmd->>'label','') = ''
     or jsonb_typeof(cmd->'currencies') is distinct from 'array' or jsonb_array_length(cmd->'currencies') = 0 then           -- 9039
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account');
  end if;
  if cmd ? 'institution' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'institution_id or institution_code required (free-text institutions are not accepted)'); end if;
  if cmd ? 'institution_id' then
    inst := (cmd->>'institution_id')::uuid;
  elsif cmd ? 'institution_code' then
    select id into inst from bnx.institution where code = cmd->>'institution_code';
    if inst is null then perform bnx.fail('INSTITUTION_NOT_ELIGIBLE', 'P0422', 'unknown code'); end if;
  end if;
  if kind in ('cash','other_asset') then
    region := coalesce(cmd->>'region_scope', 'NONE');
    if inst is not null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'cash/other_asset take no institution'); end if;
  else
    if inst is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'institution required'); end if;
    select * into ins from bnx.institution where id = inst;
    if not found or ins.status not in ('ACTIVE_SEED','VERIFIED_ACTIVE') then perform bnx.fail('INSTITUTION_NOT_ELIGIBLE', 'P0422'); end if;
    region := bnx.region_of_jurisdiction(ins.jurisdiction);
    if region is null then
      -- providers without a jurisdiction (wallets, networks): the account's region is declared (F-C2-05)
      region := cmd->>'region_scope';
    end if;
  end if;
  if region is null or region = 'UNKNOWN' or region !~ '^(CA|CN|HK|NONE|OTHER:[A-Z]{2})$' then
    perform bnx.fail('JURISDICTION_REQUIRED', 'P0422'); end if;
  if region = 'NONE' and kind not in ('cash','other_asset') then perform bnx.fail('JURISDICTION_REQUIRED', 'P0422', 'NONE is for cash/other assets'); end if;
  tz := coalesce((bnx.financial_policy_current()).household_timezone, 'America/Toronto');
  v := bnx.next_version();
  insert into bnx.account(id, kind, institution_id, label, reference_kind, reference_display, visibility, timezone, origin, state, created_by,
                          number_fingerprint, managed_reference, masked_display, region_scope)
  values (acc, kind, inst, cmd->>'label', case when cmd ? 'masked_display' then 'masked_number' else 'managed' end, cmd->>'masked_display',
          vis, tz, 'manual', 'active', a.member_id, decode(cmd->>'number_fingerprint', 'hex'), cmd->>'managed_reference',
          cmd->>'masked_display', region);
  if inst is not null then
    insert into bnx.account_institution_event(account_id, institution_id, reason, effective_from, recorded_version, actor_member_id)
    values (acc, inst, 'INITIAL', current_date, v, a.member_id);
  end if;
  lkind := case when kind in ('credit_card','loan_payable') then 'liability' else 'asset' end;
  for cur in select jsonb_array_elements_text(cmd->'currencies') loop
    if not exists (select 1 from bnx.currency where code = cur) then perform bnx.fail('UNKNOWN_CURRENCY', 'P0422', cur); end if;
    la := gen_random_uuid(); acid := gen_random_uuid();
    insert into bnx.ledger_account values (la, lkind, cur, (cmd->>'label') || ' ' || cur);
    insert into bnx.account_currency values (acid, acc, cur, la);
    res := res || jsonb_build_object('account_currency_id', acid, 'currency', cur, 'ledger_account_id', la);
  end loop;
  insert into bnx.account_grant(member_id, account_id, can_view, can_post, granted_by) values (a.member_id, acc, true, true, a.member_id);
  if vis = 'household' then
    insert into bnx.account_grant(member_id, account_id, can_view, can_post, granted_by)
    select m.id, acc, true, false, a.member_id from bnx.member m where m.state = 'active' and m.id <> a.member_id;
  end if;
  insert into bnx.account_event values (acc, 1, 'created', jsonb_build_object('label', cmd->>'label', 'visibility', vis), v, a.member_id, now());
  perform bnx.audit(a, 'create_account', jsonb_build_object('account_id', acc, 'institution_id', inst, 'region_scope', region), cmd, v);
  return bnx.idem_end(a, 'create_account', cmd, jsonb_build_object('account_id', acc, 'account_currencies', res, 'ledger_version', v,
                      'region_scope', region));
end $$;

select bnx.apply_grants();
