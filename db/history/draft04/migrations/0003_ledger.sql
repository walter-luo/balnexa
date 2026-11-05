-- 0003 Ledger: plans, batches, journals, confirmations, anchors, scope claims, snapshots, versioned reference facts.
set role bnx_definer;

create type bnx.economic_type as enum (
  'consumption_expense','card_spend','income','interest_income','refund','fee','interest_expense','loan_interest',
  'internal_transfer','card_repayment','fx_conversion','loan_disbursement','loan_principal_repayment','loan_lent',
  'loan_principal_collected','intra_household_loan','intra_household_loan_repayment','investment_subscription',
  'investment_redemption','investment_income','transfer_to_clearing','clearing_resolution','opening_balance',
  'correction_reversal','correction_replacement','interledger_transfer');
create type bnx.posting_date_status as enum ('estimated','user_confirmed','statement_confirmed');

create table bnx.posting_plan(
  id uuid primary key,
  kind text not null check (kind in ('import','onboarding_scope','reclassification','account_merge_repost')),
  job_id uuid,                                              -- FK to bnx.onboarding_job added in the onboarding migration
  scope jsonb not null, item_count int not null, control_totals jsonb not null,
  anchor_changes jsonb not null default '[]', bridge_results jsonb not null default '{}',
  clearing_defaults jsonb not null default '{}', plan_hash bytea not null,
  state text not null check (state in ('draft','frozen','approved','executing','sealed','activated','superseded',
                                       'stale','suspended','void')),          -- class M; plan_event is the record
  frozen_at_version bigint, last_validated_version bigint, scope_digest bytea,
  supersedes_plan_id uuid references bnx.posting_plan,
  approved_by uuid references bnx.member, approved_at timestamptz, approval_tier text,
  accepted_bridge_differences jsonb, auto_activate boolean not null default true,
  created_at timestamptz not null default now());
create table bnx.plan_event(plan_id uuid not null references bnx.posting_plan, seq int not null,
  event text not null check (event in ('frozen','approved','rebased','stale','suspended','superseded','activated','voided')),
  from_version bigint, to_version bigint, delta_digest bytea, diff jsonb, actor uuid,
  recorded_at timestamptz not null default now(), primary key (plan_id, seq));
create table bnx.posting_plan_item(
  plan_id uuid references bnx.posting_plan, seq int not null,
  kind text not null check (kind in ('new_journal','ledger_match','transfer_pair','clearing_post',
        'clearing_resolution','correction_reversal','correction_replacement')),
  source_txn_ids uuid[] not null default '{}', payload jsonb not null, payload_sha256 bytea not null,
  chunk_no int not null, posted_journal_id uuid, primary key (plan_id, seq));
create table bnx.posting_batch(
  id uuid primary key, plan_id uuid not null unique references bnx.posting_plan,
  state text not null check (state in ('open','sealed','active','void')),       -- class M cache of batch events
  activated_version bigint unique, activated_at timestamptz, activated_by uuid, void_reason text);
create table bnx.posting_batch_event(batch_id uuid not null references bnx.posting_batch,
  event text not null check (event in ('opened','sealed','activated','voided')), recorded_version bigint not null,
  actor uuid, reason text, recorded_at timestamptz not null default now(), primary key (batch_id, event),
  check (not (event = 'activated' and recorded_version is null)));
create unique index pbe_one_terminal on bnx.posting_batch_event(batch_id) where event in ('activated','voided');

create table bnx.clearing_item(id uuid primary key, account_currency_id uuid not null references bnx.account_currency,
  currency char(3) not null, kind text not null check (kind in ('transfer_in_transit','unclassified_movement')),
  amount numeric(20,4) not null, origin_source_txn uuid, counterpart_hint jsonb, opened_journal uuid not null);
create table bnx.clearing_item_event(clearing_item_id uuid not null references bnx.clearing_item, seq int not null,
  event text not null check (event in ('opened','resolved')), resolved_by_journal uuid,
  recorded_version bigint not null, primary key (clearing_item_id, seq));

create table bnx.journal_entry(
  id uuid primary key, entry_no bigserial unique,
  economic_type bnx.economic_type not null,
  transaction_date date not null, posting_date date not null,
  posting_date_status bnx.posting_date_status not null,
  description text not null,
  original_amount numeric(20,4), original_currency char(3), settled_rate numeric(28,10),
  ledger_version bigint,                                  -- direct postings
  posting_batch_id uuid references bnx.posting_batch,     -- plan postings
  approval_plan_id uuid references bnx.posting_plan,
  source_proposal_id uuid,                                -- FK to bnx.proposal added with the proposal migration (M1)
  origin_channel text not null check (origin_channel in ('pwa','plan','system_opening')),
  created_by_member uuid not null, confirmed_by_member uuid not null, created_via_connection uuid,
  created_xid xid8 not null default pg_current_xact_id(),
  check ((ledger_version is null) <> (posting_batch_id is null)));                  -- INV-28
create table bnx.journal_line(
  id uuid primary key, journal_id uuid not null references bnx.journal_entry,
  ledger_account_id uuid not null references bnx.ledger_account,
  currency char(3) not null references bnx.currency, amount numeric(20,4) not null check (amount <> 0),
  clearing_item_id uuid references bnx.clearing_item);
create index jl_account on bnx.journal_line(ledger_account_id, journal_id);
create index je_posting_date on bnx.journal_entry(posting_date);

-- INV-02 (per journal, per currency zero-sum), checked once per journal at commit
create function bnx.trg_je_balanced() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare bad record;
begin
  select jl.currency, sum(jl.amount) s, count(*) n into bad
    from bnx.journal_line jl where jl.journal_id = new.journal_id
   group by jl.currency having sum(jl.amount) <> 0 or count(*) < 2 limit 1;
  if found then raise exception 'JOURNAL_UNBALANCED % %', new.journal_id, bad.currency using errcode = 'P0422'; end if;
  return null;
end $$;
create constraint trigger t_je_balanced after insert on bnx.journal_line
  deferrable initially deferred for each row execute function bnx.trg_je_balanced();

create table bnx.posting_date_confirmation(
  journal_id uuid not null references bnx.journal_entry, seq int not null,
  confirmed_posting_date date not null, source text not null check (source in ('statement','member')),
  evidence jsonb, recorded_version bigint not null, actor uuid, recorded_at timestamptz not null default now(),
  primary key (journal_id, seq));
create index pdc_version on bnx.posting_date_confirmation(journal_id, recorded_version desc);

create table bnx.opening_anchor_version(
  id uuid primary key, account_currency_id uuid not null references bnx.account_currency,
  anchor_date date not null, amount numeric(20,4) not null,
  journal_id uuid unique references bnx.journal_entry, reversed_journal_id uuid references bnx.journal_entry,
  source text not null check (source in ('statement_opening','statement_derived','zero_new_account',
                                         'manual_declaration','history_reconstruction')),
  certainty text not null check (certainty in ('evidenced','declared','estimated')),
  evidence jsonb, revision int not null, installed_by_plan uuid references bnx.posting_plan,
  bridge_difference numeric(20,4), reason text not null,
  valid_from_version bigint not null, recorded_by uuid not null, recorded_at timestamptz not null default now(),
  unique (account_currency_id, valid_from_version), unique (account_currency_id, revision),
  check ((amount = 0) = (journal_id is null)));
create view bnx.opening_anchor as                      -- current anchor (compatibility view; no table of this name exists)
  select distinct on (account_currency_id) * from bnx.opening_anchor_version
  order by account_currency_id, valid_from_version desc;
create type bnx.balance_result as (status text, amount numeric(20,4), anchor bnx.opening_anchor_version, ledger_version bigint);

create table bnx.balance_checkpoint(
  id uuid primary key, account_currency_id uuid not null references bnx.account_currency,
  as_of date not null, amount numeric(20,4) not null,
  kind text not null check (kind in ('member_spot_check','cash_count','superseded_anchor')),
  evidence jsonb, recorded_by uuid not null, recorded_at timestamptz not null default now());

create table bnx.posting_scope_claim(
  plan_id uuid not null references bnx.posting_plan,
  account_currency_id uuid not null references bnx.account_currency,
  during daterange not null,
  claim_state text not null check (claim_state in ('held','released')),
  created_version bigint not null, released_version bigint,
  primary key (plan_id, account_currency_id),
  constraint posting_scope_claim_no_overlap
    exclude using gist (account_currency_id with =, during with &&) where (claim_state = 'held'));   -- INV-40
create table bnx.bridge_acceptance(plan_id uuid not null references bnx.posting_plan,
  account_currency_id uuid not null references bnx.account_currency, amount numeric(20,4) not null,
  accepted_by uuid not null, recorded_version bigint not null, primary key (plan_id, account_currency_id));

-- Versioned reference facts used by reports
create table bnx.category_version(category_id uuid not null, valid_from_version bigint not null, parent_id uuid,
  name_en text not null, name_zh text not null, state text not null check (state in ('active','retired')),
  primary key (category_id, valid_from_version));
create table bnx.fx_override_event(id uuid primary key, base char(3) not null references bnx.currency,
  quote char(3) not null references bnx.currency, rate_date date not null, rate numeric(28,10) not null check (rate > 0),
  reason text not null, actor uuid not null, recorded_version bigint not null);
create table bnx.fx_selection_log(id uuid primary key, base char(3) not null references bnx.currency,
  quote char(3) not null references bnx.currency, rate_date date not null, rate numeric(28,10) not null check (rate > 0),
  provider text not null, fetched_at timestamptz not null, recorded_version bigint not null);
create table bnx.valuation(id uuid primary key, instrument_id uuid not null, valuation_date date not null,
  price numeric(28,10) not null, currency char(3) not null references bnx.currency, source text not null,
  recorded_version bigint not null);

-- AUD-040: report snapshots carry two digests (§B2a.4)
create table bnx.report_snapshot(id uuid primary key, report_code text not null, filters_digest bytea not null,
  ledger_version bigint not null, report_definition_version text not null, fx_policy jsonb not null,
  valuation_cutoff date,
  content_account_currency_ids uuid[] not null,          -- the full accounting scope of the result
  content_sha256 bytea not null,                          -- canonical unprojected accounting result (audit replay)
  projection_actor uuid not null, projection_account_currency_ids uuid[] not null,
  projection_sha256 bytea not null,                       -- what the creating actor saw
  canonicalization text not null default 'RFC8785-JCS/rows-sorted-by-key',
  created_at timestamptz not null default now());

do $$
declare t text;
begin
  foreach t in array array['plan_event','posting_batch_event','clearing_item_event','journal_entry','journal_line',
      'posting_date_confirmation','opening_anchor_version','bridge_acceptance','category_version','fx_override_event',
      'fx_selection_log','valuation','balance_checkpoint','report_snapshot','clearing_item']
  loop
    execute format('create trigger t_append_only before update or delete on bnx.%I for each row execute function bnx.trg_append_only()', t);
  end loop;
end $$;

insert into bnx.table_class values
 ('posting_plan','M'),('plan_event','F'),('posting_plan_item','M'),('posting_batch','M'),('posting_batch_event','F'),
 ('clearing_item','E'),('clearing_item_event','F'),('journal_entry','F'),('journal_line','F'),
 ('posting_date_confirmation','F'),('opening_anchor_version','F'),('balance_checkpoint','E'),
 ('posting_scope_claim','M'),('bridge_acceptance','F'),('category_version','F'),('fx_override_event','F'),
 ('fx_selection_log','F'),('valuation','F'),('report_snapshot','E');
