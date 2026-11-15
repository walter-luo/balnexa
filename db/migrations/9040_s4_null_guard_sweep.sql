-- Copyright 2026 Walter Luo
-- SPDX-License-Identifier: Apache-2.0
-- 9040_s4_null_guard_sweep.sql -- L-R2-1: systematic NULL-guard sweep (follow-up to 9039).
-- 9039 fixed six guards found by reading. L-R2-1 replaces reading with a mechanical sweep: tools/s4/null_guard_sweep.py
-- runs every suite with BNX_NULL_SWEEP set; tests/py/harness.py then repeats each cmd_*/wrk_* call in a rolled-back
-- transaction once per top-level key (and per key of the first object of a list of objects) with the key absent, JSON null
-- and empty, and records which variants still succeed. Each accepted (function, key) pair has a reviewed disposition in
-- tools/s4/null_guard_dispositions.json. The pairs reviewed as must_refuse are fixed here:
--   MODIFY bnx.plan_create (9039): a plan without date_from or date_to got an unbounded range (an unbounded scope claim)
--          and its items skipped the date check; an item without transaction_date passed; a typed line without currency
--          passed the "lac.currency <> currency" check. Now VALIDATION_FAILED (date_from and date_to / item date outside
--          plan range / line ledger account). date_from after date_to is refused too.
--   MODIFY bnx.cmd_invite_member (0106): an empty display_name or google_sub created a member (an identity with sub '').
--          Now VALIDATION_FAILED; the role check is NULL-safe.
--   MODIFY bnx.cmd_record_ownership (0106): no events (absent or []) bumped the ledger version and wrote an audit entry for
--          nothing. Now VALIDATION_FAILED events.
--   MODIFY bnx.cmd_post_transaction (0106): an empty or blank description was posted (the plan path refuses it since 9010).
--          Now VALIDATION_FAILED description.
--   MODIFY bnx.wrk_capacity_update (9016): a budget_notification without threshold_pct was recorded with no threshold.
--          Now VALIDATION_FAILED threshold_pct unless it is 50, 80 or 100.
--   MODIFY bnx.wrk_backup_recorded (9039): a VERIFIED result without retain_until skipped the retention check
--          ("null < x" is NULL) and stored the tier's retention as the object's. Now REJECTED (RETENTION).
--   MODIFY bnx.wrk_doc_discovered (9011): an empty string source identity (source_file_id, head_revision_id, md5,
--          mail_message_id, mime_part) satisfied the NOT NULL source checks. Now REJECTED (VALIDATION_FAILED).
-- Every changed line is marked "-- 9040"; the rest of each body is the latest definition unchanged.
-- No catalog delta: no catalog entry changes. No stored data changes.
-- Authority: S4 L-R2-1 (Run 2 limitation list); evidence EVIDENCE/null_guard_sweep/.
set role bnx_definer;

-- ---------- MODIFY bnx.plan_create (9039) ----------
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
  begin                                                                                                            -- 9040
    if (cmd->>'date_from')::date is null or (cmd->>'date_to')::date is null or (cmd->>'date_from')::date > (cmd->>'date_to')::date then   -- 9040
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'date_from and date_to'); end if;                             -- 9040
  exception when invalid_datetime_format or datetime_field_overflow then                                            -- 9040
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'date_from and date_to');                                       -- 9040
  end;                                                                                                             -- 9040
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
        if lac.id is null or lac.currency is distinct from l->>'currency' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'line ledger account'); end if;   -- 9040
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
    if (it->>'transaction_date')::date is null                                                                       -- 9040
       or (it->>'transaction_date')::date not between (cmd->>'date_from')::date and (cmd->>'date_to')::date then
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

-- ---------- MODIFY bnx.cmd_invite_member (0106) ----------
create or replace function bnx.cmd_invite_member(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); m uuid := gen_random_uuid(); rc jsonb;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'invite_member', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'role', '') not in ('admin','member','viewer') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'role'); end if;   -- 9040
  if coalesce(btrim(cmd->>'display_name'), '') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'display_name'); end if;   -- 9040
  if coalesce(btrim(cmd->>'google_sub'), '') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'google_sub'); end if;       -- 9040
  insert into bnx.member(id, display_name, role, state) values (m, cmd->>'display_name', cmd->>'role', 'active');
  insert into bnx.member_identity values ('https://accounts.google.com', cmd->>'google_sub', m);
  insert into bnx.party(id, kind, display_name, normalized_name, member_id, created_by)
  values (gen_random_uuid(), 'person', cmd->>'display_name', lower(cmd->>'display_name'), m, a.member_id);
  perform bnx.audit(a, 'invite_member', jsonb_build_object('member_id', m, 'role', cmd->>'role'), cmd - 'google_sub', null);
  return bnx.idem_end(a, 'invite_member', cmd, jsonb_build_object('member_id', m));
end $$;

-- ---------- MODIFY bnx.cmd_record_ownership (0106) ----------
create or replace function bnx.cmd_record_ownership(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; e jsonb;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'record_ownership', cmd); if rc is not null then return rc; end if;
  if not exists (select 1 from bnx.account where id = (cmd->>'account_id')::uuid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if jsonb_typeof(cmd->'events') is distinct from 'array' or jsonb_array_length(cmd->'events') = 0 then   -- 9040
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'events'); end if;                                     -- 9040
  v := bnx.next_version();
  for e in select * from jsonb_array_elements(cmd->'events') loop
    begin
      insert into bnx.account_ownership_event(id, account_id, party_id, kind, event, share, effective_from, evidence_kind,
        recorded_version, actor)
      values (gen_random_uuid(), (cmd->>'account_id')::uuid, (e->>'party_id')::uuid, e->>'kind', e->>'event',
              case when e->>'event' = 'set' then bnx.dec(e, 'share') end, (e->>'effective_from')::date,
              coalesce(cmd->>'evidence_kind', 'owner_confirmed'), v, a.member_id);
    exception when unique_violation then perform bnx.fail('OWNERSHIP_TIE', 'P0409');
    end;
  end loop;
  set constraints all immediate;   -- surface OWNERSHIP_OVER_100 inside the command
  perform bnx.audit(a, 'record_ownership', jsonb_build_object('account_id', cmd->>'account_id'), cmd, v);
  return bnx.idem_end(a, 'record_ownership', cmd, jsonb_build_object('ledger_version', v));
end $$;

-- ---------- MODIFY bnx.cmd_post_transaction (0106) ----------
create or replace function bnx.cmd_post_transaction(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; j uuid;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'post_transaction', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'economic_type','') in ('opening_balance','correction_reversal','correction_replacement','') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'economic_type'); end if;
  if coalesce(btrim(cmd->>'description'), '') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'description'); end if;   -- 9040
  v := bnx.next_version();
  j := bnx.insert_journal(a, v, null, cmd->>'economic_type', (cmd->>'transaction_date')::date, (cmd->>'posting_date')::date,
         cmd->>'description', cmd->'lines', case when cmd ? 'original_amount' then bnx.dec(cmd, 'original_amount') end,
         cmd->>'original_currency', case when cmd ? 'settled_rate' then (cmd->>'settled_rate')::numeric end, null);
  perform bnx.audit(a, 'post_transaction', jsonb_build_object('journal_id', j), cmd, v);
  insert into bnx.outbox(topic, payload, created_version) values ('journal.posted', jsonb_build_object('journal_id', j), v);
  return bnx.idem_end(a, 'post_transaction', cmd, jsonb_build_object('journal_id', j, 'ledger_version', v, 'status', 'committed'));
end $$;

-- ---------- MODIFY bnx.wrk_capacity_update (9016) ----------
create or replace function bnx.wrk_capacity_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare sc text := p->>'scope'; sig text := p->>'signal'; th int; cur text; nst text; nxt timestamptz; cp bnx.cost_policy; at_ timestamptz;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  begin at_ := coalesce((p->>'now')::timestamptz, now()); th := (p->>'threshold_pct')::int;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'capacity signal'); end;
  if sc not in ('bnx-exec','bnx-vault') or sig not in ('budget_notification','launch_refused','task_killed','probe_result','provider_error') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'capacity signal'); end if;
  if sig = 'budget_notification' and th is distinct from 50 and th is distinct from 80 and th is distinct from 100 then   -- 9040
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'threshold_pct'); end if;                                             -- 9040
  select * into cp from bnx.cost_policy order by version desc limit 1;
  cur := bnx.capacity_state(sc, at_)->>'state';
  nst := case sig
    when 'budget_notification' then case th when 100 then 'provider_capped' when 80 then case when cur = 'provider_capped' then cur else 'throttled_internal' end
                                             else cur end
    when 'launch_refused' then 'provider_capped' when 'task_killed' then 'provider_capped' when 'provider_error' then 'provider_error'
    when 'probe_result' then case when coalesce((p->>'ok')::boolean, false) then 'normal' else 'provider_capped' end end;
  if nst = 'probe_pending' then nst := 'normal'; end if;   -- a 50 % notice in a fresh month logs, the probe rule still applies
  if sig = 'probe_result' and not coalesce((p->>'ok')::boolean, false) then nxt := at_ + make_interval(hours => cp.probe_backoff_hours); end if;
  if sig = 'budget_notification' and th = 50 and cur = 'probe_pending' then
    return jsonb_build_object('scope', sc, 'state', cur, 'logged', true);
  end if;
  insert into bnx.capacity_event(scope, state, signal, threshold_pct, next_probe_at, billing_month, detail, at)
  values (sc, nst, sig, th, nxt, bnx.billing_month(at_), coalesce(p->'detail', '{}'), at_);
  if nst in ('provider_capped','provider_error') and cur not in ('provider_capped','provider_error') then
    perform bnx.notify('EXCEPTION', 'CAPACITY:' || sc || ':' || nst || ':' || bnx.billing_month(at_), true,
      jsonb_build_object('kind', 'CAPACITY_' || upper(nst), 'record_key', sc));
  end if;
  return jsonb_build_object('scope', sc, 'state', nst, 'previous', cur, 'next_probe_at', nxt);
end $$;

-- ---------- MODIFY bnx.wrk_backup_recorded (9039) ----------
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
      if pl->>'retain_until' is null then return bnx.doc_reject(p_staging, 'RETENTION'); end if;   -- 9040
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

-- ---------- MODIFY bnx.wrk_doc_discovered (9011) ----------
create or replace function bnx.wrk_doc_discovered(p_staging uuid) returns jsonb
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
  if exists (select 1 from unnest(array['source_file_id','head_revision_id','md5','mail_message_id','mime_part']) k   -- 9040
              where jsonb_typeof(pl->k) = 'string' and btrim(pl->>k) = '') then                                      -- 9040
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end if;                                                   -- 9040
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

select bnx.apply_grants();
