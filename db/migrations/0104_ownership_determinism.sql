-- 0104 AUD-052 Deterministic bitemporal ownership/scope resolution; share totals enforced in the database.
set role bnx_definer;

alter table bnx.account_ownership_event add column event_seq bigint generated always as identity;
alter table bnx.account_ownership_event add constraint aoe_event_seq_uq unique (event_seq);
-- explicit tie rejection: one event per (account, party, kind, effective date) per ledger version
alter table bnx.account_ownership_event add constraint aoe_no_same_version_tie
  unique (account_id, party_id, kind, effective_from, recorded_version);
alter table bnx.account_scope_event add column event_seq bigint generated always as identity;
alter table bnx.account_scope_event add constraint ase_event_seq_uq unique (event_seq);
alter table bnx.account_scope_event add constraint ase_no_same_version_tie
  unique (account_id, effective_from, recorded_version);

create or replace function bnx.ownership_at(p_account uuid, p_date date, p_v bigint)
returns table(party_id uuid, kind text, share numeric) language sql stable security definer
set search_path = pg_catalog, pg_temp as $$
  select x.party_id, x.kind, x.share from (
    select distinct on (e.party_id, e.kind) e.party_id, e.kind, e.event, e.share
      from bnx.account_ownership_event e
     where e.account_id = p_account and e.recorded_version <= p_v and e.effective_from <= p_date
     order by e.party_id, e.kind, e.effective_from desc, e.recorded_version desc, e.event_seq desc) x
  where x.event = 'set'
$$;

create or replace function bnx.account_scope_at(p_account uuid, p_date date, p_v bigint)
returns text language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select s.ownership_scope from bnx.account_scope_event s
     where s.account_id = p_account and s.recorded_version <= p_v and s.effective_from <= p_date
     order by s.effective_from desc, s.recorded_version desc, s.event_seq desc limit 1), 'individual')
$$;

-- INV-47: on every business date where the ownership of (account, kind) changes, the total share ≤ 100 %,
-- evaluated at the inserting version. Deferred, so a transfer (ended + set) in one command is checked as a whole.
create function bnx.trg_ownership_share_total() returns trigger   -- deferred: SECURITY DEFINER (see 0102)
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare d date; total numeric;
begin
  for d in select distinct effective_from from bnx.account_ownership_event
            where account_id = new.account_id and kind = new.kind and recorded_version <= new.recorded_version loop
    select coalesce(sum(share), 0) into total from bnx.ownership_at(new.account_id, d, new.recorded_version) where kind = new.kind;
    if total > 100 then
      raise exception 'OWNERSHIP_OVER_100: account % kind % on % totals % at version %', new.account_id, new.kind, d, total,
        new.recorded_version using errcode = 'P0422';
    end if;
  end loop;
  return null;
end $$;
create constraint trigger t_ownership_share_total after insert on bnx.account_ownership_event
  deferrable initially deferred for each row execute function bnx.trg_ownership_share_total();
