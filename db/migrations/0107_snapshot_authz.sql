-- 0107 AUD-051 Snapshot replay authorization bound to the creating audience (member + channel/connection),
-- active membership, requested scope and current visibility. Uniform NOT_AVAILABLE for unknown snapshots and for
-- snapshots of another audience (no existence oracle). ACCESS_REVOKED when the audience lost the rights it used.
-- Owner T3 audit replay of the canonical content digest is a separate, audited command.
set role bnx_definer;

alter table bnx.report_snapshot add column projection_channel text;
alter table bnx.report_snapshot add column projection_connection_id uuid references bnx.ai_connection;
alter table bnx.report_snapshot add column projection_requested_acs uuid[];
alter table bnx.report_snapshot add column filters jsonb;

create function bnx.snapshot_decision(a bnx.actor, p_snapshot uuid) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare s bnx.report_snapshot; vis uuid[];
begin
  select * into s from bnx.report_snapshot where id = p_snapshot;
  if s.id is null or s.projection_actor is distinct from a.member_id then return 'NOT_AVAILABLE'; end if;
  -- a snapshot created through an AI connection is replayable by that connection or by the member's own PWA session;
  -- a snapshot created in the PWA is replayable through a connection only within the connection's current scope
  if a.channel = 'mcp' and s.projection_connection_id is not null and s.projection_connection_id <> a.connection_id then
    return 'NOT_AVAILABLE';
  end if;
  if not exists (select 1 from bnx.member m where m.id = a.member_id and m.state = 'active') then return 'ACCESS_REVOKED'; end if;
  if a.channel = 'mcp' and (a.connection_id is null or not exists (select 1 from bnx.ai_connection c
        where c.id = a.connection_id and c.revoked_at is null and 'read' = any(c.scopes))) then
    return 'ACCESS_REVOKED';
  end if;
  vis := array(select bnx.actor_visible_acs(a));
  -- requested scope covers zero-content snapshots (an empty projection is never vacuously authorized)
  if s.projection_requested_acs is null or not (s.projection_requested_acs <@ vis)
     or not (s.projection_account_currency_ids <@ vis) then
    return 'ACCESS_REVOKED';
  end if;
  return 'ok';
end $$;

-- compatibility entry point of Draft-04 (member-only; PWA channel)
create or replace function bnx.snapshot_replay_access(p_member uuid, p_snapshot uuid)
returns text language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case d when 'NOT_AVAILABLE' then 'NOT_FOUND' else d end
    from bnx.snapshot_decision(row(p_member, null, 'pwa', null, array['read'])::bnx.actor, p_snapshot) d
$$;

create function bnx.balance_rows(p_acs uuid[], p_date date, p_v bigint) returns jsonb
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('account_currency_id', x, 'currency', ac.currency,
           'status', (bnx.balance_at(x, p_date, p_v)).status, 'amount', (bnx.balance_at(x, p_date, p_v)).amount::text)
           order by x), '[]'::jsonb)
    from unnest(p_acs) x join bnx.account_currency ac on ac.id = x
$$;

create function bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); snap uuid := gen_random_uuid(); vnow bigint; v bigint; d date;
        vis uuid[]; req uuid[]; content_acs uuid[]; proj uuid[];
begin
  perform bnx.require(a, 0);
  if cmd->>'report_code' is distinct from 'R-BAL' then perform bnx.fail('REPORT_NOT_IMPLEMENTED', 'P0422', cmd->>'report_code'); end if;
  select version into vnow from bnx.ledger_state;
  v := coalesce((cmd->>'ledger_version')::bigint, vnow);
  if v < 0 or v > vnow then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  d := coalesce((cmd->>'as_of')::date, current_date);
  vis := array(select bnx.actor_visible_acs(a));
  if cmd ? 'account_currency_ids' then
    select coalesce(array_agg(x::uuid order by x::uuid), '{}') into req from jsonb_array_elements_text(cmd->'account_currency_ids') x;
    if not (req <@ vis) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;   -- no oracle on unseen accounts
  else
    req := array(select unnest(vis) order by 1);
  end if;
  -- household report: accounting content covers all account-currencies; the projection is what this audience sees
  content_acs := array(select ac.id from bnx.account_currency ac order by ac.id);
  proj := array(select x from unnest(req) x order by x);
  insert into bnx.report_snapshot(id, report_code, filters_digest, ledger_version, report_definition_version, fx_policy,
    valuation_cutoff, content_account_currency_ids, content_sha256, projection_actor, projection_account_currency_ids,
    projection_sha256, canonicalization, projection_channel, projection_connection_id, projection_requested_acs, filters)
  values (snap, 'R-BAL', bnx.h(jsonb_build_object('as_of', d, 'acs', req)::text), v, 'R-BAL/1', '{"mode":"native"}', null,
    content_acs, bnx.h(bnx.balance_rows(content_acs, d, v)::text), a.member_id, proj,
    bnx.h(bnx.balance_rows(proj, d, v)::text), 'jsonb-text/rows-sorted-by-account_currency_id',
    a.channel, a.connection_id, req, jsonb_build_object('as_of', d));
  perform bnx.audit(a, 'create_report_snapshot', jsonb_build_object('snapshot_id', snap), cmd, v);
  return jsonb_build_object('snapshot_id', snap, 'ledger_version', v, 'rows', bnx.balance_rows(proj, d, v),
                            'projection_sha256', encode(bnx.h(bnx.balance_rows(proj, d, v)::text), 'hex'));
end $$;

create function bnx.q_replay_snapshot(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); sid uuid; decision text; s bnx.report_snapshot; r_rows jsonb;
begin
  perform bnx.require(a, 0);
  begin sid := (q->>'snapshot_id')::uuid; exception when others then sid := null; end;
  decision := bnx.snapshot_decision(a, sid);
  if decision = 'NOT_AVAILABLE' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if decision = 'ACCESS_REVOKED' then perform bnx.fail('ACCESS_REVOKED', 'P0403'); end if;
  select * into s from bnx.report_snapshot where id = sid;
  r_rows := bnx.balance_rows(s.projection_account_currency_ids, (s.filters->>'as_of')::date, s.ledger_version);
  return jsonb_build_object('snapshot_id', sid, 'ledger_version', s.ledger_version, 'rows', r_rows,
    'projection_digest_verified', bnx.h(r_rows::text) = s.projection_sha256);
end $$;

-- Owner-only T3 audit replay of the canonical (unprojected) content digest; always audited
create function bnx.cmd_audit_replay_snapshot(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; s bnx.report_snapshot; ok boolean;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  select * into s from bnx.report_snapshot where id = (cmd->>'snapshot_id')::uuid;
  if s.id is null then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  ok := bnx.h(bnx.balance_rows(s.content_account_currency_ids, (s.filters->>'as_of')::date, s.ledger_version)::text) = s.content_sha256;
  perform bnx.audit(a, 'audit_replay_snapshot', jsonb_build_object('snapshot_id', s.id, 'content_digest_verified', ok),
                    coalesce(cmd, '{}'), s.ledger_version);
  return jsonb_build_object('snapshot_id', s.id, 'content_digest_verified', ok, 'ledger_version', s.ledger_version);
end $$;
