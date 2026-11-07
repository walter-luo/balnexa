-- Synthetic Draft-02 logical state for the three tables whose shape changed (no Draft-02 database was ever deployed).
create schema d02;
create table d02.opening_anchor(account_currency_id uuid primary key, anchor_date date not null, amount numeric(20,4) not null,
  journal_id uuid, source text not null, certainty text not null, evidence jsonb, revision int not null);
create table d02.opening_anchor_history(account_currency_id uuid, revision int, anchor_date date, amount numeric(20,4),
  journal_id uuid, reversed_by_journal_id uuid, superseded_by_plan uuid, bridge_difference numeric(20,4),
  reason text not null, revised_by uuid not null, revised_at timestamptz not null, primary key (account_currency_id, revision));
create table d02.posting_date_confirmation(journal_id uuid, confirmed_posting_date date not null, confirmed_at timestamptz not null);
create table d02.match_decision(id uuid primary key, source_txn_id uuid not null, kind text not null, journal_line_id uuid,
  rule_code text not null, state text not null, evidence jsonb not null, decided_by uuid, decided_at timestamptz,
  supersedes uuid);
