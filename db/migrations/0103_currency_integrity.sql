-- 0103 AUD-045 Currency identity and precision across linked financial objects.
set role bnx_definer;

alter table bnx.currency add constraint currency_iso check (code ~ '^[A-Z]{3}$');

alter table bnx.ledger_account add constraint ledger_account_id_currency_uq unique (id, currency);
alter table bnx.account_currency add constraint account_currency_ledger_currency_fk
  foreign key (ledger_account_id, currency) references bnx.ledger_account(id, currency);
alter table bnx.account_currency add constraint account_currency_id_currency_uq unique (id, currency);

alter table bnx.journal_line add constraint journal_line_ledger_currency_fk
  foreign key (ledger_account_id, currency) references bnx.ledger_account(id, currency);

alter table bnx.statement add constraint statement_account_currency_fk
  foreign key (account_currency_id, currency) references bnx.account_currency(id, currency);
alter table bnx.source_txn add constraint source_txn_account_currency_fk
  foreign key (account_currency_id, currency) references bnx.account_currency(id, currency);
alter table bnx.clearing_item add constraint clearing_item_account_currency_fk
  foreign key (account_currency_id, currency) references bnx.account_currency(id, currency);

-- original transaction currency/amount kept separate from posting currency
alter table bnx.journal_entry add constraint journal_original_currency_fk
  foreign key (original_currency) references bnx.currency(code);
alter table bnx.journal_entry add constraint journal_original_pair
  check ((original_amount is null) = (original_currency is null)
         and (settled_rate is null or (original_amount is not null and settled_rate > 0)));

create function bnx.assert_scale(p_amount numeric, p_currency char(3), p_what text) returns void
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare mu smallint;
begin
  if p_amount is null then return; end if;
  select minor_units into mu from bnx.currency where code = p_currency;
  if mu is null then raise exception 'UNKNOWN_CURRENCY % (%)', p_currency, p_what using errcode = 'P0422'; end if;
  if p_amount <> round(p_amount, mu) or abs(p_amount) >= 1e15 then
    raise exception 'AMOUNT_SCALE: % % exceeds % minor units of % (INV-08)', p_what, p_amount, mu, p_currency using errcode = 'P0422';
  end if;
end $$;

create function bnx.trg_scale() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare cur char(3);
begin
  if tg_table_name = 'source_txn' then perform bnx.assert_scale(new.amount, new.currency, 'source_txn.amount');
  elsif tg_table_name = 'statement' then
    perform bnx.assert_scale(new.opening_balance, new.currency, 'statement.opening_balance');
    perform bnx.assert_scale(new.closing_balance, new.currency, 'statement.closing_balance');
  elsif tg_table_name = 'clearing_item' then perform bnx.assert_scale(new.amount, new.currency, 'clearing_item.amount');
  elsif tg_table_name = 'opening_anchor_version' then
    select currency into cur from bnx.account_currency where id = new.account_currency_id;
    perform bnx.assert_scale(new.amount, cur, 'opening_anchor.amount');
  elsif tg_table_name = 'journal_entry' then
    perform bnx.assert_scale(new.original_amount, new.original_currency, 'journal.original_amount');
  end if;
  return new;
end $$;
create trigger t_scale before insert on bnx.source_txn for each row execute function bnx.trg_scale();
create trigger t_scale before insert on bnx.statement for each row execute function bnx.trg_scale();
create trigger t_scale before insert on bnx.clearing_item for each row execute function bnx.trg_scale();
create trigger t_scale before insert on bnx.opening_anchor_version for each row execute function bnx.trg_scale();
create trigger t_scale before insert on bnx.journal_entry for each row execute function bnx.trg_scale();

-- defensive: balance readers also require currency equality (redundant with the composite FKs)
create or replace function bnx.balance_at(p_ac uuid, p_date date, p_v bigint)
returns bnx.balance_result language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.opening_anchor_version; r bnx.balance_result;
begin
  a := bnx.anchor_at(p_ac, p_v);
  r.ledger_version := p_v;
  if a.id is null then r.status := 'NO_OPENING'; return r; end if;
  r.anchor := a;
  if p_date < a.anchor_date then r.status := 'BEFORE_OPENING'; return r; end if;
  select coalesce(sum(jl.amount), 0) into r.amount
    from bnx.visible_at(p_v) v
    join bnx.journal_line jl on jl.journal_id = v.journal_id
    join bnx.account_currency ac on ac.id = p_ac and jl.ledger_account_id = ac.ledger_account_id and jl.currency = ac.currency
   where bnx.effective_posting_date(v.journal_id, p_v) <= p_date;
  r.status := 'ok';
  return r;
end $$;
