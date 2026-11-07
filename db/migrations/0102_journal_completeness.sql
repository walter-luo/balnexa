-- 0102 AUD-044 Journal completeness at COMMIT (INV-01, INV-02, INV-03, INV-04, INV-07, INV-08).
-- A journal header without lines, a single line, same-sign lines, a currency group without both a debit and a
-- credit, a non-zero currency sum, a line in a currency other than its ledger account's, an over-scale amount,
-- or a line added in a later transaction are all rejected. Checked by a deferred constraint trigger fired by the
-- HEADER insert (so header-only journals are caught) and by every line insert.
set role bnx_definer;

alter table bnx.journal_line add column created_xid xid8 not null default pg_current_xact_id();

create function bnx.restore_mode() returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  -- Only the migrator's own session (never a runtime role calling a definer function) can enable restore mode.
  select session_user = 'bnx_migrator' and coalesce(current_setting('bnx.restore_mode', true), '') = 'on'
$$;

create function bnx.assert_journal_complete(p_journal uuid) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare je record; n int; bad record;
begin
  select * into je from bnx.journal_entry where id = p_journal;
  if not found then return; end if;
  select count(*) into n from bnx.journal_line where journal_id = p_journal;
  if n < 2 then
    raise exception 'JOURNAL_INCOMPLETE: journal % has % line(s) (INV-01)', p_journal, n using errcode = 'P0422';
  end if;
  select jl.currency, sum(jl.amount) s, bool_or(jl.amount > 0) d, bool_or(jl.amount < 0) c into bad
    from bnx.journal_line jl where jl.journal_id = p_journal
   group by jl.currency
  having sum(jl.amount) <> 0 or not bool_or(jl.amount > 0) or not bool_or(jl.amount < 0)
   limit 1;
  if found then
    raise exception 'JOURNAL_UNBALANCED: journal % currency % sum % debit % credit % (INV-02/03)',
      p_journal, bad.currency, bad.s, bad.d, bad.c using errcode = 'P0422';
  end if;
  select jl.id, jl.currency, la.currency la_currency into bad
    from bnx.journal_line jl join bnx.ledger_account la on la.id = jl.ledger_account_id
   where jl.journal_id = p_journal and jl.currency <> la.currency limit 1;
  if found then
    raise exception 'LINE_CURRENCY_MISMATCH: line % % vs ledger account % (INV-04)', bad.id, bad.currency, bad.la_currency
      using errcode = 'P0422';
  end if;
  select jl.id, jl.amount, c.minor_units into bad
    from bnx.journal_line jl join bnx.currency c on c.code = jl.currency
   where jl.journal_id = p_journal
     and (jl.amount <> round(jl.amount, c.minor_units) or abs(jl.amount) >= 1e15) limit 1;
  if found then
    raise exception 'AMOUNT_SCALE: line % amount % exceeds % minor units (INV-08)', bad.id, bad.amount, bad.minor_units
      using errcode = 'P0422';
  end if;
  if not bnx.restore_mode() and exists (select 1 from bnx.journal_line
       where journal_id = p_journal and created_xid <> je.created_xid) then
    raise exception 'LATE_LINE: journal % has lines from another transaction (INV-07)', p_journal using errcode = 'P0422';
  end if;
end $$;

-- Deferred constraint triggers fire at COMMIT, outside any SECURITY DEFINER frame (current_user is then the session
-- role, e.g. bnx_app). The trigger function is therefore SECURITY DEFINER itself.
create function bnx.trg_journal_complete() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if tg_table_name = 'journal_entry' then perform bnx.assert_journal_complete(new.id);
  else perform bnx.assert_journal_complete(new.journal_id); end if;
  return null;
end $$;

-- immediate guard: a line may only be inserted in the transaction that created its journal
create function bnx.trg_line_same_txn() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare x xid8;
begin
  select created_xid into x from bnx.journal_entry where id = new.journal_id;
  if not bnx.restore_mode() and (x is null or x <> pg_current_xact_id()) then
    raise exception 'LATE_LINE: journal % was created in another transaction (INV-07)', new.journal_id using errcode = 'P0422';
  end if;
  if not bnx.restore_mode() then new.created_xid := pg_current_xact_id(); end if;
  return new;
end $$;

drop trigger t_je_balanced on bnx.journal_line;
drop function bnx.trg_je_balanced();
create trigger t_line_same_txn before insert on bnx.journal_line for each row execute function bnx.trg_line_same_txn();
create constraint trigger t_journal_complete_header after insert on bnx.journal_entry
  deferrable initially deferred for each row execute function bnx.trg_journal_complete();
create constraint trigger t_journal_complete_line after insert on bnx.journal_line
  deferrable initially deferred for each row execute function bnx.trg_journal_complete();
