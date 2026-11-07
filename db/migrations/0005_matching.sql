-- 0005 Source transactions, links and match decisions (append-only; §C4.9, INV-19, INV-44).
set role bnx_definer;

create table bnx.source_txn(
  id uuid primary key, account_currency_id uuid not null references bnx.account_currency,
  posting_date date not null, transaction_date date, amount numeric(20,4) not null, currency char(3) not null,
  normalized_description text, bank_ref text, canonical_occurrence int not null,
  source_fingerprint bytea not null,
  constraint source_txn_fp_uq unique (account_currency_id, source_fingerprint));          -- INV-44
create table bnx.source_txn_work(source_txn_id uuid primary key references bnx.source_txn,
  match_state text not null, economic_type_proposed bnx.economic_type, category_id uuid,
  classification_source text, clearing_default_applied boolean not null default false, revision int not null default 1);
create table bnx.journal_source(journal_id uuid references bnx.journal_entry, source_txn_id uuid references bnx.source_txn,
  role text not null check (role in ('origin','counterpart','matched_confirmation')), primary key (journal_id, source_txn_id));
create table bnx.source_txn_link_event(source_txn_id uuid not null references bnx.source_txn,
  journal_id uuid not null references bnx.journal_entry,
  event text not null check (event in ('reserved','linked','released')),
  batch_id uuid references bnx.posting_batch, recorded_version bigint not null,
  primary key (source_txn_id, journal_id, event));
create table bnx.source_txn_current_link(source_txn_id uuid primary key references bnx.source_txn,
  journal_id uuid not null references bnx.journal_entry);                                -- INV-19, constraint-backed
create table bnx.match_decision_event(
  id uuid primary key, source_txn_id uuid not null references bnx.source_txn,
  kind text not null check (kind in ('overlap','ledger','transfer_pair','clearing_resolution','duplicate_document','exclude')),
  decision text not null check (decision in ('proposed','confirmed','rejected','superseded')),
  counterpart_source_txn uuid references bnx.source_txn, journal_line_id uuid references bnx.journal_line,
  clearing_item_id uuid references bnx.clearing_item, rule_code text not null, evidence jsonb not null,
  supersedes uuid references bnx.match_decision_event, decided_by uuid, recorded_version bigint not null,
  recorded_at timestamptz not null default now());
create table bnx.match_decision_current(source_txn_id uuid not null references bnx.source_txn, kind text not null,
  decision_event_id uuid not null unique references bnx.match_decision_event, journal_line_id uuid,
  primary key (source_txn_id, kind));
create unique index mdc_ledger_leg_uq on bnx.match_decision_current(journal_line_id) where kind = 'ledger';

create trigger t_append_only before update or delete on bnx.source_txn for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.journal_source for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.source_txn_link_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.match_decision_event for each row execute function bnx.trg_append_only();

insert into bnx.table_class values
 ('source_txn','E'),('source_txn_work','M'),('journal_source','F'),('source_txn_link_event','F'),
 ('source_txn_current_link','M'),('match_decision_event','F'),('match_decision_current','M');
