-- 9004 Constraint replacements (V1.2 UA §6.3 rule: ADD CONSTRAINT ... NOT VALID -> VALIDATE -> DROP old; OBJ-384, OBJ-367,
-- OBJ-225; CROSS-03, S4B-F03, S4B-F14). No R1 object is dropped except the replaced CHECK constraints themselves.
-- Not done here (CORE-1 implementation notes, see docs/S4_CORE1_Implementation_Notes.md):
--   * balance_checkpoint.kind is NOT widened: V1.2 keeps balance_checkpoint untouched (S4B-F04, OBJ-077 REUSE) and no
--     value list is specified anywhere; observations live in balance_observation_event (9012).
set role bnx_definer;

-- helper: name of the single CHECK constraint on a column (R1 used inline unnamed checks)
create function bnx.check_constraint_of(p_table regclass, p_column text) returns text
language sql stable set search_path = pg_catalog, pg_temp as $$
  select c.conname::text from pg_constraint c
   where c.conrelid = p_table and c.contype = 'c'
     and c.conkey = array[(select attnum from pg_attribute where attrelid = p_table and attname = p_column)]
$$;

do $$
declare r record; old text;
begin
  for r in select * from (values
    ('bnx.posting_plan'::regclass, 'kind', 'posting_plan_kind_v2',
     $c$kind in ('import','onboarding_scope','reclassification','account_merge_repost','ai_draft','handoff','onboarding',
                 'member_draft','migration_replay')$c$),
    ('bnx.household_setting'::regclass, 'key', 'household_setting_key_v2',
     $c$key in ('require_dual_copy_before_approval','coverage_alert_hours','data_class','authorization_ref','plan_chunk_size',
                'retention_daily','retention_weekly','retention_monthly')$c$),
    ('bnx.evidence_file'::regclass, 'acquired_via', 'evidence_file_acquired_via_v2',
     $c$acquired_via in ('pwa_upload','drive_selection','chat_file','drive_inbox','shared_index','mail_exact_fetch','executor_staging')$c$),
    ('bnx.document'::regclass, 'doc_type', 'document_doc_type_v2',
     $c$doc_type in ('bank_statement','card_statement','investment_statement','not_statement','unknown',
                     'transaction_export','tax_slip','structured_receipt','prior_t1','noa','nor','filed_schedule',
                     'transaction_notice_email','fee_or_waiver_notice','promotion_or_offer','terms_or_service_notice',
                     'procedure','historical_context','security_sensitive','ai_composed_report')$c$)
  ) as t(tbl, col, newname, expr) loop
    old := bnx.check_constraint_of(r.tbl, r.col);
    if old is null then raise exception 'CONSTRAINT_REPLACEMENT: no CHECK on %.%', r.tbl, r.col; end if;
    execute format('alter table %s add constraint %I check (%s) not valid', r.tbl, r.newname, r.expr);
    execute format('alter table %s validate constraint %I', r.tbl, r.newname);
    execute format('alter table %s drop constraint %I', r.tbl, old);
  end loop;
end $$;

-- evidence_object: storage location kind; r2_key NOT NULL relaxed by a replacing CHECK (S4B-F14). Pre-O-7 objects live only
-- in the Drive Processed folder (storage_kind = drive_processed, r2_key NULL).
alter table bnx.evidence_object add column storage_kind text not null default 'r2';
alter table bnx.evidence_object add constraint evidence_object_storage_kind_ck
  check (storage_kind in ('r2','drive_processed','gcs','pending')) not valid;
alter table bnx.evidence_object validate constraint evidence_object_storage_kind_ck;
alter table bnx.evidence_object add constraint evidence_object_r2_key_ck
  check ((storage_kind = 'r2') = (r2_key is not null)) not valid;
alter table bnx.evidence_object validate constraint evidence_object_r2_key_ck;
alter table bnx.evidence_object alter column r2_key drop not null;

-- Write-once guard (MODIFY of 0004, same signature): R1 rules unchanged, plus NULL-safe comparison now that r2_key is
-- nullable: r2_key and storage_kind may move only forward (pending/drive_processed -> r2|gcs), never back or away.
create or replace function bnx.trg_evidence_object_write_once() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if tg_op = 'DELETE' then raise exception 'APPEND_ONLY: delete evidence_object' using errcode = 'P0409'; end if;
  if (old.r2_key is not null and new.r2_key is distinct from old.r2_key) or new.size_bytes <> old.size_bytes
     or (old.sha256 is not null and new.sha256 is distinct from old.sha256)
     or (old.dedup_into is not null and new.dedup_into is distinct from old.dedup_into)
     or (old.integrity_state <> 'unverified' and new.integrity_state <> old.integrity_state)
     or (new.storage_kind is distinct from old.storage_kind
         and not (old.storage_kind in ('pending','drive_processed') and new.storage_kind in ('r2','gcs','drive_processed')
                  and new.storage_kind <> old.storage_kind)) then
    raise exception 'WRITE_ONCE: evidence_object %', old.id using errcode = 'P0409';
  end if;
  return new;
end $$;

-- cmd_set_household_setting MODIFY (same signature): the widened key list with per-key validation (OBJ-225).
create or replace function bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; rc jsonb; k text := cmd->>'setting'; v jsonb := cmd->'value'; ok boolean;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'set_household_setting', cmd); if rc is not null then return rc; end if;
  ok := case k
    when 'require_dual_copy_before_approval' then jsonb_typeof(v) = 'boolean'
    when 'coverage_alert_hours' then jsonb_typeof(v) = 'number' and (v::text)::numeric between 1 and 720 and (v::text)::numeric = trunc((v::text)::numeric)
    when 'plan_chunk_size' then jsonb_typeof(v) = 'number' and (v::text)::numeric between 1 and 2000 and (v::text)::numeric = trunc((v::text)::numeric)
    when 'retention_daily' then jsonb_typeof(v) = 'number' and (v::text)::numeric between 1 and 31 and (v::text)::numeric = trunc((v::text)::numeric)
    when 'retention_weekly' then jsonb_typeof(v) = 'number' and (v::text)::numeric between 0 and 52 and (v::text)::numeric = trunc((v::text)::numeric)
    when 'retention_monthly' then jsonb_typeof(v) = 'number' and (v::text)::numeric between 0 and 120 and (v::text)::numeric = trunc((v::text)::numeric)
    when 'data_class' then jsonb_typeof(v) = 'string' and v #>> '{}' in ('synthetic','owner_test','real')
    when 'authorization_ref' then jsonb_typeof(v) = 'string' and length(v #>> '{}') between 1 and 200
    else false end;
  if not coalesce(ok, false) then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'setting'); end if;
  insert into bnx.household_setting values (k, v, a.member_id, now())
    on conflict (key) do update set value = excluded.value, set_by = excluded.set_by, set_at = now();
  perform bnx.audit(a, 'set_household_setting', jsonb_build_object('setting', k, 'value', v), cmd, null);
  return bnx.idem_end(a, 'set_household_setting', cmd, jsonb_build_object('setting', k, 'value', v));
end $$;

select bnx.apply_grants();
