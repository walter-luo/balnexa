-- 0105 AUD-054 Source-link history with immutable event identity and an enforced state machine.
-- The Draft-04 table keyed (source_txn_id, journal_id, event) could not record reserved→released→reserved.
set role bnx_definer;

create table bnx.source_link_event(
  event_id bigint generated always as identity primary key,
  source_txn_id uuid not null references bnx.source_txn,
  journal_id uuid not null references bnx.journal_entry,
  event text not null check (event in ('reserved','linked','released')),
  prior_event_id bigint references bnx.source_link_event,
  batch_id uuid references bnx.posting_batch, recorded_version bigint not null,
  recorded_at timestamptz not null default now());
create unique index sle_prior_uq on bnx.source_link_event(prior_event_id) where prior_event_id is not null;
create index sle_pair on bnx.source_link_event(source_txn_id, journal_id, event_id desc);

-- allowed transitions per (source_txn, journal): none→reserved|linked, reserved→linked|released,
-- linked→released, released→reserved|linked. Maintains source_txn_current_link (INV-19): reserved/linked hold the
-- source transaction for this journal (a different holder → SOURCE_TXN_ALREADY_LINKED); released frees it.
create function bnx.trg_source_link_transition() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare last record; holder uuid;
begin
  -- restore: rows and the derived current-link table are reloaded verbatim from the verified dump (AUD-050)
  if bnx.restore_mode() then return new; end if;
  select event_id, event into last from bnx.source_link_event
   where source_txn_id = new.source_txn_id and journal_id = new.journal_id order by event_id desc limit 1;
  if (last.event is null and new.event = 'released')
     or (last.event = 'reserved' and new.event = 'reserved')
     or (last.event = 'linked' and new.event in ('reserved','linked'))
     or (last.event = 'released' and new.event = 'released') then
    raise exception 'SOURCE_LINK_TRANSITION: % -> % for source % journal %', coalesce(last.event,'none'), new.event,
      new.source_txn_id, new.journal_id using errcode = 'P0409';
  end if;
  new.prior_event_id := last.event_id;
  if new.event in ('reserved','linked') then
    select journal_id into holder from bnx.source_txn_current_link where source_txn_id = new.source_txn_id for update;
    if holder is not null and holder <> new.journal_id then
      raise exception 'SOURCE_TXN_ALREADY_LINKED: source % held by journal %', new.source_txn_id, holder using errcode = 'P0409';
    end if;
    insert into bnx.source_txn_current_link values (new.source_txn_id, new.journal_id)
      on conflict (source_txn_id) do nothing;
  else
    delete from bnx.source_txn_current_link where source_txn_id = new.source_txn_id and journal_id = new.journal_id;
  end if;
  return new;
end $$;
create trigger t_source_link_transition before insert on bnx.source_link_event
  for each row execute function bnx.trg_source_link_transition();
create trigger t_append_only before update or delete on bnx.source_link_event
  for each row execute function bnx.trg_append_only();

-- carry any Draft-04 rows (none in a clean installation) in their recorded order, then retire the old table
insert into bnx.source_link_event(source_txn_id, journal_id, event, batch_id, recorded_version)
  select source_txn_id, journal_id, event, batch_id, recorded_version from bnx.source_txn_link_event
   order by recorded_version, case event when 'reserved' then 1 when 'linked' then 2 else 3 end;
alter table bnx.source_txn_link_event rename to source_txn_link_event_d04_retired;
create function bnx.trg_retired() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as $$
begin raise exception 'RETIRED_TABLE: % is read-only history; use bnx.source_link_event', tg_table_name using errcode = 'P0409'; end $$;
create trigger t_retired before insert on bnx.source_txn_link_event_d04_retired for each row execute function bnx.trg_retired();
update bnx.table_class set table_name = 'source_txn_link_event_d04_retired', class = 'E' where table_name = 'source_txn_link_event';
insert into bnx.table_class values ('source_link_event','F');
