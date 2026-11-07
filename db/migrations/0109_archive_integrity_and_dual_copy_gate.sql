-- 0109 AUD-047 / AUD-042: no silent dual_verified, and an optional fail-closed approval gate.
--  * evidence_object.archive_state may become 'dual_verified' only when the object is integrity-verified (executor
--    SHA-256 present) and an archive 'verified' event recorded a re-hash of the Drive copy equal to that SHA-256.
--  * archive transitions are recorded through bnx.wrk_record_archive_event (worker/executor path only).
--  * household setting require_dual_copy_before_approval (Owner T3): when on, cmd_approve_plan refuses plans whose
--    evidence objects are not dual_verified (PLAN_WAITING_DUAL_COPY) and enqueues a notification instead.
set role bnx_definer;

create function bnx.trg_archive_state_guard() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if new.archive_state = 'dual_verified' and old.archive_state is distinct from 'dual_verified' then
    if new.integrity_state <> 'verified' or new.sha256 is null or not exists (
         select 1 from bnx.evidence_archive_event e where e.evidence_object_id = new.id and e.event = 'verified'
            and e.sha256_observed = new.sha256) then
      raise exception 'ARCHIVE_NOT_VERIFIED: object % has no verified independent copy matching its SHA-256', new.id
        using errcode = 'P0409';
    end if;
  end if;
  if old.archive_state = 'dual_verified' and new.archive_state not in ('dual_verified', 'archive_failed') then
    raise exception 'ARCHIVE_STATE_REGRESSION: % -> %', old.archive_state, new.archive_state using errcode = 'P0409';
  end if;
  return new;
end $$;
create trigger t_archive_state_guard before update of archive_state on bnx.evidence_object
  for each row execute function bnx.trg_archive_state_guard();

create function bnx.wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare o record; s int; obs bytea := case when p_sha_hex is null then null else decode(p_sha_hex, 'hex') end;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into o from bnx.evidence_object where id = p_object for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  select coalesce(max(seq), 0) + 1 into s from bnx.evidence_archive_event where evidence_object_id = p_object;
  if p_event = 'verified' and (o.sha256 is null or obs is distinct from o.sha256) then
    insert into bnx.evidence_archive_event values (p_object, s, 'failed', p_drive_file, obs, jsonb_build_object('reason', 'hash_mismatch'), now());
    update bnx.evidence_object set archive_state = 'archive_failed' where id = p_object and archive_state <> 'dual_verified';
    insert into bnx.outbox(topic, payload) values ('archive.failed', jsonb_build_object('evidence_object_id', p_object, 'reason', 'hash_mismatch'));
    return 'archive_failed';
  end if;
  insert into bnx.evidence_archive_event values (p_object, s, p_event, p_drive_file, obs, null, now());
  update bnx.evidence_object set archive_state = case p_event when 'queued' then 'archive_pending' when 'copied' then 'archive_pending'
      when 'verified' then 'dual_verified' when 'failed' then 'archive_failed' else archive_state end
   where id = p_object;
  if p_event = 'failed' then
    insert into bnx.outbox(topic, payload) values ('archive.failed', jsonb_build_object('evidence_object_id', p_object));
  end if;
  return (select archive_state from bnx.evidence_object where id = p_object);
end $$;

create table bnx.household_setting(key text primary key check (key in ('require_dual_copy_before_approval')),
  value jsonb not null, set_by uuid not null, set_at timestamptz not null default now());
insert into bnx.table_class values ('household_setting','M');

create function bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; rc jsonb;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'set_household_setting', cmd); if rc is not null then return rc; end if;
  if cmd->>'setting' is distinct from 'require_dual_copy_before_approval' or jsonb_typeof(cmd->'value') <> 'boolean' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'setting'); end if;
  insert into bnx.household_setting values (cmd->>'setting', cmd->'value', a.member_id, now())
    on conflict (key) do update set value = excluded.value, set_by = excluded.set_by, set_at = now();
  perform bnx.audit(a, 'set_household_setting', jsonb_build_object('setting', cmd->>'setting', 'value', cmd->'value'), cmd, null);
  return bnx.idem_end(a, 'set_household_setting', cmd, jsonb_build_object('setting', cmd->>'setting', 'value', cmd->'value'));
end $$;

-- plans may declare the evidence they were built from (the statement pipeline fills this in M1)
create function bnx.plan_evidence_pending(p_plan uuid) returns int
language sql stable set search_path = pg_catalog, pg_temp as $$
  select count(*)::int from bnx.posting_plan pl
    cross join lateral jsonb_array_elements_text(coalesce(pl.scope->'evidence_file_ids', '[]')) f(id)
    join bnx.evidence_file ef on ef.id = f.id::uuid join bnx.evidence_object eo on eo.id = ef.evidence_object_id
   where pl.id = p_plan and eo.archive_state <> 'dual_verified'
$$;

create or replace function bnx.cmd_approve_plan(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; pl record; s int; pend int;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'approve_plan', cmd); if rc is not null then return rc; end if;
  select * into pl from bnx.posting_plan where id = (cmd->>'plan_id')::uuid for update;
  if not found or pl.state <> 'frozen' then perform bnx.fail('PLAN_NOT_APPROVABLE', 'P0409'); end if;
  if not bnx.actor_can_post(a, (pl.scope->>'account_currency_id')::uuid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if encode(pl.plan_hash,'hex') <> cmd->>'plan_hash' or encode(pl.scope_digest,'hex') <> cmd->>'scope_digest' then
    perform bnx.fail('PLAN_DIGEST_MISMATCH', 'P0409'); end if;
  if bnx.scope_delta_exists(pl.id, pl.last_validated_version) then perform bnx.fail('PLAN_REQUIRES_REVALIDATION', 'P0409'); end if;
  if coalesce((select (value)::text::boolean from bnx.household_setting where key = 'require_dual_copy_before_approval'), false) then
    pend := bnx.plan_evidence_pending(pl.id);
    if pend > 0 then
      perform bnx.fail('PLAN_WAITING_DUAL_COPY', 'P0409', pend || ' evidence object(s) not dual_verified');
    end if;
  end if;
  update bnx.posting_plan set state = 'approved', approved_by = a.member_id, approved_at = now(), approval_tier = 'T2' where id = pl.id;
  select coalesce(max(seq),0)+1 into s from bnx.plan_event where plan_id = pl.id;
  insert into bnx.plan_event values (pl.id, s, 'approved', null, null, null, null, a.member_id, now());
  perform bnx.enqueue('plan.execute', jsonb_build_object('plan_id', pl.id));
  perform bnx.audit(a, 'approve_plan', jsonb_build_object('plan_id', pl.id, 'plan_hash', cmd->>'plan_hash'), cmd, null);
  return bnx.idem_end(a, 'approve_plan', cmd, jsonb_build_object('status', 'approved_pending_activation',
         'queue_generation', (select generation from bnx.queue_state)));
end $$;

-- create_import_plan: accept an optional evidence_file_ids list (each must be readable by the actor; no oracle)
create or replace function bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; p uuid := gen_random_uuid(); acid uuid := (cmd->>'account_currency_id')::uuid;
        ac record; it jsonb; i int := 0; vnow bigint; rng daterange; ph bytea; sd bytea; cla record; ev jsonb := coalesce(cmd->'evidence_file_ids', '[]');
        f text;
begin
  perform bnx.require(a, 2);
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'create_import_plan', cmd); if rc is not null then return rc; end if;
  for f in select jsonb_array_elements_text(ev) loop
    if bnx.can_read_evidence(a.member_id, f::uuid) = 'denied' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  end loop;
  select * into ac from bnx.account_currency where id = acid;
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
  select version into vnow from bnx.ledger_state;
  rng := daterange((cmd->>'date_from')::date - 10, (cmd->>'date_to')::date + 11, '[)');
  for it in select * from jsonb_array_elements(cmd->'items') loop
    select * into cla from bnx.ledger_account where id = (it->>'counter_ledger_account_id')::uuid;
    if not found or cla.kind not in ('income','expense','clearing') or cla.currency <> ac.currency then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'counter ledger account');
    end if;
    perform bnx.assert_scale(bnx.dec(it, 'amount'), ac.currency, 'plan item');
    if (it->>'transaction_date')::date not between (cmd->>'date_from')::date and (cmd->>'date_to')::date then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item date outside plan range'); end if;
  end loop;
  ph := bnx.h(acid::text || '|' || rng::text || '|' || (cmd->'items')::text || '|' || ev::text);
  sd := bnx.scope_digest(ac.ledger_account_id, acid, rng, vnow);
  insert into bnx.posting_plan(id, kind, scope, item_count, control_totals, plan_hash, state, frozen_at_version, last_validated_version, scope_digest)
  values (p, 'import', jsonb_build_object('account_currency_id', acid, 'range', rng::text, 'evidence_file_ids', ev), jsonb_array_length(cmd->'items'),
          jsonb_build_object('sum', (select sum((x->>'amount')::numeric) from jsonb_array_elements(cmd->'items') x)::text),
          ph, 'frozen', vnow, vnow, sd);
  for it in select * from jsonb_array_elements(cmd->'items') loop
    i := i + 1;
    insert into bnx.posting_plan_item values (p, i, 'new_journal', '{}', it, bnx.h(it::text), 1, null);
  end loop;
  begin
    insert into bnx.posting_scope_claim values (p, acid, rng, 'held', vnow, null);
  exception when exclusion_violation then perform bnx.fail('SCOPE_CLAIM_CONFLICT', 'P0409');
  end;
  insert into bnx.plan_event values (p, 1, 'frozen', vnow, vnow, null, null, a.member_id, now());
  perform bnx.audit(a, 'create_import_plan', jsonb_build_object('plan_id', p), cmd, null);
  return bnx.idem_end(a, 'create_import_plan', cmd, jsonb_build_object('plan_id', p, 'plan_hash', encode(ph,'hex'),
         'scope_digest', encode(sd,'hex'), 'frozen_at_version', vnow));
end $$;
