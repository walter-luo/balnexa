-- 9007 Module-flag enforcement (V1.2 UA §4.4, §4.4.1; OBJ-385; S4B-F06/F07; BNX-S2-01 §5).
-- Region -> flag: CA -> Canada; CN, HK, OTHER:* -> International; NONE never gated; UNKNOWN always refused (fail closed).
-- Flags are read only from the ACTIVE configuration version; with no ACTIVE version every gated write and read fails with
-- SCOPE_UNCONFIGURED (P0403) until bnx.install_activate_config runs (upgrade semantics, AT-FLG-10).
-- Writes: restore-aware BEFORE triggers t_scope_flag_<table> on every account-scoped table that exists at this point.
-- Reads: R1 helpers visible_account_currency_ids() and actor_visible_acs() (same signatures) return only enabled scopes,
-- so every R1 reader (q_balances, snapshots, evidence decisions, AI consent checks) is filtered; balance_rows is unchanged
-- (snapshot digests stay verifiable; a snapshot whose scope is now disabled replays as ACCESS_REVOKED). q_balances MODIFY adds
-- scope_warnings. Tables created by later migrations (balance_observation_event, loan, card_fee_event, bnx_tax.*, …) get
-- their trigger in the migration that creates them (F-C2-07).
set role bnx_definer;

create function bnx.pol_active_config() returns int
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare cv int;
begin
  select config_version into cv from bnx.config_version_anchor where state = 'ACTIVE';
  if cv is null then raise exception 'SCOPE_UNCONFIGURED' using errcode = 'P0403', detail = 'no ACTIVE configuration version'; end if;
  return cv;
end $$;

create function bnx.pol_region_flag(p_region text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when p_region is null or p_region = 'NONE' then null when p_region = 'CA' then 'Canada'
              when p_region in ('CN','HK') or p_region like 'OTHER:%' then 'International' else 'UNKNOWN' end
$$;

create function bnx.pol_flag(p_flag text) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select value from bnx.instance_module_flag where config_version = bnx.pol_active_config() and flag_key = p_flag
$$;

create function bnx.pol_require_module(p_flag text) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if p_flag not in ('Canada','International','CRA') then
    raise exception 'SCOPE_DISABLED' using errcode = 'P0403', detail = coalesce(p_flag, 'NULL'); end if;
  if bnx.pol_flag(p_flag) is distinct from 'YES' then
    raise exception 'SCOPE_DISABLED' using errcode = 'P0403', detail = p_flag; end if;
end $$;

create function bnx.pol_require_region(p_region text) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare f text := bnx.pol_region_flag(p_region);
begin
  if f is null then return; end if;                                  -- NONE: never gated
  if f = 'UNKNOWN' then raise exception 'SCOPE_DISABLED' using errcode = 'P0403', detail = 'UNKNOWN region'; end if;
  perform bnx.pol_require_module(f);
end $$;

create function bnx.pol_require_module_for_account(p_account uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare r text;
begin
  select region_scope into r from bnx.account where id = p_account;
  if found then perform bnx.pol_require_region(r); end if;
end $$;

create function bnx.pol_require_module_for_ac(p_ac uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare r text;
begin
  select a.region_scope into r from bnx.account_currency ac join bnx.account a on a.id = ac.account_id where ac.id = p_ac;
  if found then perform bnx.pol_require_region(r); end if;
end $$;

-- account-currencies whose region is enabled (NONE always). With no ACTIVE version any gated account raises.
create function bnx.pol_enabled_acs() returns setof uuid
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare cv int; flags jsonb;
begin
  select config_version into cv from bnx.config_version_anchor where state = 'ACTIVE';
  if cv is null then
    if exists (select 1 from bnx.account where region_scope <> 'NONE') then
      raise exception 'SCOPE_UNCONFIGURED' using errcode = 'P0403', detail = 'no ACTIVE configuration version';
    end if;
    return query select ac.id from bnx.account_currency ac;
    return;
  end if;
  select jsonb_object_agg(flag_key, value) into flags from bnx.instance_module_flag where config_version = cv;
  return query select ac.id from bnx.account_currency ac join bnx.account a on a.id = ac.account_id
                where bnx.pol_region_flag(a.region_scope) is null
                   or flags->>bnx.pol_region_flag(a.region_scope) = 'YES';
end $$;

-- flags that currently exclude accounts the member holds a grant on (for scope_warnings)
create function bnx.pol_excluded_scopes(p_member uuid) returns text[]
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce(array_agg(distinct 'EXCLUDED_SCOPE:' || bnx.pol_region_flag(a.region_scope) order by 'EXCLUDED_SCOPE:' || bnx.pol_region_flag(a.region_scope)), '{}')
    from bnx.account a join bnx.account_grant g on g.account_id = a.id and g.member_id = p_member and g.can_view
    join bnx.account_currency ac on ac.account_id = a.id
   where ac.id not in (select bnx.pol_enabled_acs())
$$;

-- R1 helper MODIFY (same signature): live visibility now also requires an enabled scope
create or replace function bnx.visible_account_currency_ids(p_member uuid)
returns setof uuid language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select ac.id from bnx.account_currency ac
    join bnx.account_grant g on g.account_id = ac.account_id and g.member_id = p_member and g.can_view
    join bnx.member m on m.id = p_member and m.state = 'active'
   where ac.id in (select bnx.pol_enabled_acs())
$$;

create function bnx.pol_scope_filter(a bnx.actor) returns setof uuid
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select bnx.actor_visible_acs(a)
$$;

-- ---------- write enforcement: BEFORE triggers (restore-aware) ----------
create function bnx.trg_scope_flag() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare x uuid;
begin
  if bnx.restore_mode() then return new; end if;
  case tg_argv[0]
    when 'account' then
      if tg_op = 'INSERT' or new.region_scope is distinct from old.region_scope then perform bnx.pol_require_region(new.region_scope); end if;
    when 'account_id' then perform bnx.pol_require_module_for_account(new.account_id);
    when 'card_account_id' then perform bnx.pol_require_module_for_account(new.card_account_id);
                                perform bnx.pol_require_module_for_account(new.linked_account_id);
    when 'account_currency_id' then perform bnx.pol_require_module_for_ac(new.account_currency_id);
    when 'evidence_file' then
      if new.assigned_account_currency_id is not null and (tg_op = 'INSERT' or new.assigned_account_currency_id is distinct from old.assigned_account_currency_id) then
        perform bnx.pol_require_module_for_ac(new.assigned_account_currency_id); end if;
    when 'journal_line' then
      select ac.id into x from bnx.account_currency ac where ac.ledger_account_id = new.ledger_account_id;
      if x is not null then perform bnx.pol_require_module_for_ac(x); end if;   -- category/equity/system lines are not scoped
    when 'posting_date_confirmation' then
      for x in select ac.id from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                where jl.journal_id = new.journal_id loop
        perform bnx.pol_require_module_for_ac(x);
      end loop;
    when 'ai_connection' then
      foreach x in array coalesce(new.account_currency_ids, '{}') loop perform bnx.pol_require_module_for_ac(x); end loop;
    when 'posting_plan' then
      if tg_op = 'INSERT' or (new.state = 'approved' and old.state is distinct from 'approved') then
        if new.scope ? 'account_currency_id' then perform bnx.pol_require_module_for_ac((new.scope->>'account_currency_id')::uuid); end if;
      end if;
    else raise exception 'trg_scope_flag: unknown mode %', tg_argv[0];
  end case;
  return new;
end $$;

create table bnx.flag_enforcement_point(table_name text primary key, mode text not null, ops text not null, migration text not null);
insert into bnx.flag_enforcement_point values
 ('account','account','INSERT, UPDATE OF region_scope','9007'),
 ('account_currency','account_id','INSERT','9007'),
 ('journal_line','journal_line','INSERT','9007'),
 ('posting_date_confirmation','posting_date_confirmation','INSERT','9007'),
 ('account_ownership_event','account_id','INSERT','9007'),
 ('account_scope_event','account_id','INSERT','9007'),
 ('account_grant','account_id','INSERT, UPDATE','9007'),
 ('account_holder_event','account_id','INSERT','9007'),
 ('card_link_event','card_account_id','INSERT','9007'),
 ('evidence_file','evidence_file','INSERT, UPDATE OF assigned_account_currency_id','9007'),
 ('statement','account_currency_id','INSERT','9007'),
 ('source_txn','account_currency_id','INSERT','9007'),
 ('clearing_item','account_currency_id','INSERT','9007'),
 ('posting_scope_claim','account_currency_id','INSERT','9007'),
 ('ai_connection','ai_connection','INSERT, UPDATE OF account_currency_ids','9007'),
 ('posting_plan','posting_plan','INSERT, UPDATE OF state','9007');
insert into bnx.table_class values ('flag_enforcement_point','M');
insert into bnx.migration_seeded_table values ('bnx.flag_enforcement_point', '9007', 'enforcement matrix register');

do $$
declare r record; ev text;
begin
  for r in select * from bnx.flag_enforcement_point loop
    ev := case r.ops when 'INSERT' then 'insert' when 'INSERT, UPDATE' then 'insert or update'
                     else 'insert or update of ' || split_part(r.ops, 'UPDATE OF ', 2) end;
    execute format('create trigger %I before %s on bnx.%I for each row execute function bnx.trg_scope_flag(%L)',
                   't_scope_flag_' || r.table_name, ev, r.table_name, r.mode);
  end loop;
end $$;

-- generated enforcement matrix (AT-FLG-11): what the catalog actually enforces
create function bnx.flag_enforcement_matrix() returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'trigger', t.tgname,
           'mode', (select p.mode from bnx.flag_enforcement_point p where p.table_name = c.relname)) order by c.relname), '[]')
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'bnx' and t.tgname like 't\_scope\_flag\_%' and not t.tgisinternal
$$;

-- ---------- read enforcement: q_balances MODIFY (same signature) adds scope_warnings ----------
create or replace function bnx.q_balances(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); vnow bigint; v bigint; d date := coalesce((q->>'as_of')::date, current_date); res jsonb;
begin
  perform bnx.require(a, 0);
  select version into vnow from bnx.ledger_state;
  v := coalesce((q->>'ledger_version')::bigint, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('account_currency_id', x.id, 'currency', ac.currency, 'status', (b).status,
           'amount', (b).amount::text) order by x.id), '[]') into res
    from (select id from bnx.actor_visible_acs(a) id
           where not (q ? 'account_currency_ids') or id::text in (select jsonb_array_elements_text(q->'account_currency_ids'))) x
    join bnx.account_currency ac on ac.id = x.id
    cross join lateral (select bnx.balance_at(x.id, d, v) b) bb;
  return jsonb_build_object('ledger_version', v, 'as_of', d, 'balances', res,
                            'scope_warnings', to_jsonb(bnx.pol_excluded_scopes(a.member_id)));
end $$;

select bnx.apply_grants();
