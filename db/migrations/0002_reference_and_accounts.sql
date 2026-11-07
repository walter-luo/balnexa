-- 0002 Reference data, members, parties, accounts, current authorization, versioned account and ownership facts.
set role bnx_definer;

create table bnx.table_class(table_name text primary key, class char(1) not null check (class in ('F','E','M')));

-- Version clock (§B2a.1). One row. Incremented only by bnx.next_version() under the ledger lock.
create table bnx.ledger_state(singleton boolean primary key default true check (singleton), version bigint not null);
insert into bnx.ledger_state values (true, 0);

create function bnx.next_version() returns bigint
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare v bigint;
begin
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
  update bnx.ledger_state set version = version + 1 returning version into v;
  return v;
end $$;

-- Append-only guard for class F facts (INV-37)
create function bnx.trg_append_only() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  raise exception 'APPEND_ONLY: % on %', tg_op, tg_table_name using errcode = 'P0409';
end $$;

create table bnx.currency(code char(3) primary key, minor_units smallint not null check (minor_units between 0 and 4));
create table bnx.member(
  id uuid primary key, display_name text not null,
  role text not null check (role in ('owner','admin','member','viewer')),
  state text not null check (state in ('active','suspended','removed')),
  created_at timestamptz not null default now());
create table bnx.party(id uuid primary key, kind text not null check (kind in ('person','organization')),
  display_name text not null, normalized_name text not null, aliases text[] not null default '{}',
  member_id uuid references bnx.member, created_by uuid not null);
create table bnx.institution(id uuid primary key, name_en text, name_zh text, country char(2), bic text, created_by uuid);
create table bnx.ledger_account(id uuid primary key,
  kind text not null check (kind in ('asset','liability','equity','income','expense','fx_trading','clearing')),
  currency char(3) not null references bnx.currency, name text not null);
create table bnx.account(
  id uuid primary key,
  kind text not null check (kind in ('bank_deposit','cash','e_wallet','credit_card','investment',
                                     'loan_payable','loan_receivable','other_asset')),
  institution_id uuid references bnx.institution,
  label text not null,                                   -- class M cache; authoritative: account_event
  reference_kind text not null check (reference_kind in ('masked_number','managed','none')),
  reference_display text,
  visibility text not null check (visibility in ('household','private')),   -- class M cache
  timezone text not null, origin text not null check (origin in ('manual','discovered')),
  state text not null check (state in ('active','closed','merged_into')),  -- class M cache
  merged_into uuid references bnx.account,
  created_by uuid not null, created_at timestamptz not null default now(),
  check (kind in ('cash','other_asset') or institution_id is not null));
create table bnx.account_currency(id uuid primary key, account_id uuid not null references bnx.account,
  currency char(3) not null references bnx.currency, ledger_account_id uuid not null unique references bnx.ledger_account,
  unique (account_id, currency));

-- Current authorization (class M, live; every change audited). Never historical, never ownership (§B5, AUD-039).
create table bnx.account_grant(member_id uuid not null references bnx.member, account_id uuid not null references bnx.account,
  can_view boolean not null, can_post boolean not null, granted_by uuid not null, granted_at timestamptz not null default now(),
  primary key (member_id, account_id), check (can_view or not can_post));

-- Versioned business facts about accounts (class F)
create table bnx.account_event(account_id uuid not null references bnx.account, seq int not null,
  event text not null check (event in ('created','label_changed','visibility_changed','state_changed')),
  payload jsonb not null, recorded_version bigint not null, actor uuid not null,
  recorded_at timestamptz not null default now(), primary key (account_id, seq));

-- AUD-039: ownership is bitemporal and append-only. Business effect from effective_from (date) until the next
-- event for the same (account, party, kind); record time = recorded_version. 'ended' closes a holding.
create table bnx.account_ownership_event(
  id uuid primary key, account_id uuid not null references bnx.account, party_id uuid not null references bnx.party,
  kind text not null check (kind in ('legal_owner','beneficial_owner')),
  event text not null check (event in ('set','ended')),
  share numeric(7,4) check (share is null or (share > 0 and share <= 100)),
  effective_from date not null,
  evidence_kind text not null check (evidence_kind in ('statement_header','member_declared','owner_confirmed','document')),
  evidence_ref jsonb, recorded_version bigint not null, actor uuid not null, recorded_at timestamptz not null default now(),
  check ((event = 'ended') = (share is null)));
create index aoe_lookup on bnx.account_ownership_event(account_id, kind, party_id, recorded_version, effective_from);
create table bnx.account_scope_event(
  id uuid primary key, account_id uuid not null references bnx.account,
  ownership_scope text not null check (ownership_scope in ('individual','joint','corporate')),
  effective_from date not null, recorded_version bigint not null, actor uuid not null,
  recorded_at timestamptz not null default now());
create index ase_lookup on bnx.account_scope_event(account_id, recorded_version, effective_from);

create trigger t_append_only before update or delete on bnx.account_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.account_ownership_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.account_scope_event for each row execute function bnx.trg_append_only();

insert into bnx.table_class values
 ('schema_migrations','M'),('table_class','M'),('ledger_state','M'),('currency','E'),('member','M'),('party','E'),
 ('institution','E'),('ledger_account','E'),('account','M'),('account_currency','E'),('account_grant','M'),
 ('account_event','F'),('account_ownership_event','F'),('account_scope_event','F');
