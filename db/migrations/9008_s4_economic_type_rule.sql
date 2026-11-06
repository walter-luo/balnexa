-- 9008 Economic-type rules and chunked plan posting (V1.2 UA §5.3.4, §5.5.5; OBJ-022; S4B-F12/F15; Draft-04 B6.1).
-- * bnx.economic_type_rule: one row per R1 enum value (26) with the B6.1 line pattern, flow_class and report effects.
-- * t_economic_type_rule: deferred SECURITY DEFINER constraint trigger on journal_entry INSERT; restore-aware; judges only
--   journals written after this migration (historical journals are never re-judged: the trigger did not exist when they
--   were inserted, and bnx.economic_type_check() reports NOT_APPLICABLE for ledger versions <= the activation version).
--   A journal that fails R1 completeness (fewer than two lines, unbalanced) is left to the R1 completeness trigger so the
--   R1 error codes keep precedence.
-- * wrk_post_plan_chunk MODIFY (same signature): posts at most plan_chunk_size items per call (household setting, default
--   200) in seq order and returns 'executing' while items remain, 'sealed' when done; uses the economic_type (and typed
--   lines) carried in the item payload; untyped R1 two-line items are classified from the counter ledger account kind and
--   the sign, never from the sign alone; anything else fails closed (PLAN_ITEM_UNTYPED).
set role bnx_definer;

create table bnx.economic_type_rule(
  economic_type bnx.economic_type primary key,
  required_lines text not null, allowed_extra text not null,
  flow_class text not null check (flow_class in ('OPERATING','TRANSFER','INVESTING','FINANCING','CARD_REPAYMENT','LOAN_PRINCIPAL','CORRECTION')),
  budget_effect text not null, r09_effect text not null, rule_version int not null default 1,
  enforcement text not null check (enforcement in ('checked','follows_original','per_policy')),
  seeded_from text not null default 'Draft-04 B6.1');
insert into bnx.economic_type_rule(economic_type, required_lines, allowed_extra, flow_class, budget_effect, r09_effect, enforcement) values
 ('consumption_expense','X(+), A or L(-)','fee X','OPERATING','counted','operating','checked'),
 ('card_spend','X(+), L card(-)','fee X','OPERATING','counted','operating','checked'),
 ('income','A(+), I(-)','none','OPERATING','R08','operating','checked'),
 ('interest_income','A(+), I interest(-)','none','OPERATING','R08','operating','checked'),
 ('refund','A or L(+), X(-)','none','OPERATING','reduces category','operating','checked'),
 ('fee','X(+), A or L(-)','none','OPERATING','counted','operating','checked'),
 ('interest_expense','X(+), A or L(-)','none','OPERATING','counted','operating','checked'),
 ('loan_interest','X(+), A or L(-)','none','OPERATING','counted','operating','checked'),
 ('internal_transfer','A or L on >= 2 distinct household account-currencies','fee X, T','TRANSFER','excluded','excluded','checked'),
 ('card_repayment','L card(+), A(-)','fee X, T','CARD_REPAYMENT','excluded','excluded','checked'),
 ('fx_conversion','A in >= 2 currencies, T in each currency','fee X','TRANSFER','fee only','fee only','checked'),
 ('loan_disbursement','A(+), L loan(-)','fee X','FINANCING','excluded','financing','checked'),
 ('loan_principal_repayment','L loan(+), A(-)','interest X','LOAN_PRINCIPAL','excluded (interest counted)','financing','checked'),
 ('loan_lent','A receivable(+), A bank(-)','none','FINANCING','excluded','financing','checked'),
 ('loan_principal_collected','A bank(+), A receivable(-)','interest I','LOAN_PRINCIPAL','excluded (interest R08)','financing','checked'),
 ('intra_household_loan','A receivable(+), A lender bank(-), A borrower bank(+), L payable(-)','none','TRANSFER','excluded','excluded','checked'),
 ('intra_household_loan_repayment','reverse sides of intra_household_loan','interest I and X pair','TRANSFER','excluded','excluded','checked'),
 ('investment_subscription','A investment(+), A cash(-)','fee X','INVESTING','excluded','investing','checked'),
 ('investment_redemption','A cash(+), A investment(-), I investment_result (- gain / + loss)','fee X','INVESTING','excluded','investing','checked'),
 ('investment_income','A cash(+), I(-)','withholding X','INVESTING','R08','investing','checked'),
 ('transfer_to_clearing','A or L(+/-), C(-/+)','fee X','TRANSFER','excluded','excluded','checked'),
 ('clearing_resolution','C(-/+), A or L(+/-) or X/I reclassification','none','TRANSFER','per resolved type','per resolved type','checked'),
 ('opening_balance','A or L, E','none','TRANSFER','excluded','excluded','checked'),
 ('correction_reversal','exact negation of the reversed journal','none','CORRECTION','follows original','follows original','follows_original'),
 ('correction_replacement','per its own type','none','CORRECTION','follows','follows','follows_original'),
 ('interledger_transfer','A or L, counterparty A/L/E per target policy','fee X, T','TRANSFER','excluded','per policy','per_policy');
create trigger t_append_only before update or delete on bnx.economic_type_rule for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('economic_type_rule','E');
insert into bnx.migration_seeded_table values ('bnx.economic_type_rule', '9008', 'B6.1 rules for the 26 R1 economic types'),
 ('bnx.rule_activation_version', '9008+', 'activation rows; a restore keeps the original activation versions from the dump');

-- chunk progress of a plan batch (side table; R1 posting_batch_event is append-only with one row per event)
create table bnx.posting_batch_chunk(batch_id uuid not null references bnx.posting_batch, chunk_no int not null, posted int not null,
  remaining int not null, recorded_version bigint not null, recorded_at timestamptz not null default now(), primary key (batch_id, chunk_no));
create trigger t_append_only before update or delete on bnx.posting_batch_chunk for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('posting_batch_chunk','F');

insert into bnx.rule_activation_version(rule_key, activated_at_version, migration)
select 'economic_type_rule', version, '9008' from bnx.ledger_state;

-- line kind: A asset (Acash / Ainv / Arec / Aother), L liability (Lcard / Lloan / Lother), E, I, X, T fx_trading, C clearing
create function bnx.line_kind(p_ledger_account uuid) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case la.kind
           when 'asset' then 'A' || case a.kind when 'investment' then 'inv' when 'loan_receivable' then 'rec'
                                                when 'bank_deposit' then 'cash' when 'cash' then 'cash' when 'e_wallet' then 'cash' else 'other' end
           when 'liability' then 'L' || case a.kind when 'credit_card' then 'card' when 'loan_payable' then 'loan' else 'other' end
           when 'equity' then 'E' when 'income' then 'I' when 'expense' then 'X' when 'fx_trading' then 'T' when 'clearing' then 'C' end
    from bnx.ledger_account la left join bnx.account_currency ac on ac.ledger_account_id = la.id
    left join bnx.account a on a.id = ac.account_id where la.id = p_ledger_account
$$;

-- returns NULL when the journal satisfies its type's rule, else a short reason
create function bnx.economic_type_violation(p_journal uuid) returns text
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare je record; k text[]; pos text[]; neg text[]; n int; cur int; et text; acs int; tcur int; acur int;
begin
  select * into je from bnx.journal_entry where id = p_journal;
  if not found then return null; end if;
  et := je.economic_type::text;
  select array_agg(bnx.line_kind(jl.ledger_account_id)), array_agg(bnx.line_kind(jl.ledger_account_id)) filter (where jl.amount > 0),
         array_agg(bnx.line_kind(jl.ledger_account_id)) filter (where jl.amount < 0), count(*), count(distinct jl.currency),
         count(distinct ac.id), count(distinct jl.currency) filter (where la.kind = 'fx_trading'),
         count(distinct jl.currency) filter (where la.kind = 'asset')
    into k, pos, neg, n, cur, acs, tcur, acur
    from bnx.journal_line jl join bnx.ledger_account la on la.id = jl.ledger_account_id
    left join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
   where jl.journal_id = p_journal;
  -- incomplete or unbalanced journals are reported by the R1 completeness trigger (its error codes keep precedence)
  if coalesce(n, 0) < 2 or exists (select 1 from bnx.journal_line where journal_id = p_journal group by currency having sum(amount) <> 0) then
    return null;
  end if;
  if (select enforcement from bnx.economic_type_rule where economic_type = je.economic_type) <> 'checked' then return null; end if;
  pos := coalesce(pos, '{}'); neg := coalesce(neg, '{}');
  -- every line kind must belong to the type's allowed set; required signed kinds must be present
  case et
    when 'consumption_expense', 'fee', 'interest_expense', 'loan_interest' then
      if not (k <@ array['X','Acash','Ainv','Arec','Aother','Lcard','Lloan','Lother']) or not ('X' = any(pos))
         or not exists (select 1 from unnest(neg) x where x like 'A%' or x like 'L%') then return et || ': X(+), A or L(-)'; end if;
    when 'card_spend' then
      if not (k <@ array['X','Lcard']) or not ('X' = any(pos)) or not ('Lcard' = any(neg)) then return et || ': X(+), L card(-)'; end if;
    when 'income', 'interest_income' then
      if not (k <@ array['I','Acash','Ainv','Arec','Aother']) or not ('I' = any(neg)) or not exists (select 1 from unnest(pos) x where x like 'A%') then
        return et || ': A(+), I(-)'; end if;
    when 'refund' then
      if not (k <@ array['X','Acash','Ainv','Arec','Aother','Lcard','Lloan','Lother']) or not ('X' = any(neg))
         or not exists (select 1 from unnest(pos) x where x like 'A%' or x like 'L%') then return et || ': A or L(+), X(-)'; end if;
    when 'internal_transfer' then
      if not (k <@ array['X','T','Acash','Ainv','Arec','Aother','Lcard','Lloan','Lother']) or acs < 2 then
        return et || ': A or L on >= 2 account-currencies (extras X, T)'; end if;
    when 'card_repayment' then
      if not (k <@ array['X','T','Lcard','Acash','Aother']) or not ('Lcard' = any(pos)) or not exists (select 1 from unnest(neg) x where x like 'A%') then
        return et || ': L card(+), A(-)'; end if;
    when 'fx_conversion' then
      if not (k <@ array['X','T','Acash','Ainv','Aother']) or acur < 2 or tcur < acur then
        return et || ': A in >= 2 currencies, T in each currency'; end if;
    when 'loan_disbursement' then
      if not (k <@ array['X','Lloan','Acash','Aother']) or not ('Lloan' = any(neg)) or not exists (select 1 from unnest(pos) x where x like 'A%') then
        return et || ': A(+), L loan(-)'; end if;
    when 'loan_principal_repayment' then
      if not (k <@ array['X','Lloan','Acash','Aother']) or not ('Lloan' = any(pos)) or not exists (select 1 from unnest(neg) x where x like 'A%') then
        return et || ': L loan(+), A(-)'; end if;
    when 'loan_lent' then
      if not (k <@ array['Arec','Acash','Aother']) or not ('Arec' = any(pos)) or not exists (select 1 from unnest(neg) x where x in ('Acash','Aother')) then
        return et || ': A receivable(+), A bank(-)'; end if;
    when 'loan_principal_collected' then
      if not (k <@ array['I','Arec','Acash','Aother']) or not ('Arec' = any(neg)) or not exists (select 1 from unnest(pos) x where x in ('Acash','Aother')) then
        return et || ': A bank(+), A receivable(-)'; end if;
    when 'intra_household_loan', 'intra_household_loan_repayment' then
      if not (k <@ array['I','X','Arec','Acash','Aother','Lloan','Lother']) or not ('Arec' = any(k)) or not exists (select 1 from unnest(k) x where x like 'L%') then
        return et || ': receivable and payable legs between two holders'; end if;
    when 'investment_subscription' then
      if not (k <@ array['X','Ainv','Acash','Aother']) or not ('Ainv' = any(pos)) or not exists (select 1 from unnest(neg) x where x in ('Acash','Aother')) then
        return et || ': A investment(+), A cash(-)'; end if;
    when 'investment_redemption' then
      if not (k <@ array['X','I','Ainv','Acash','Aother']) or not ('Ainv' = any(neg)) or not exists (select 1 from unnest(pos) x where x in ('Acash','Aother')) then
        return et || ': A cash(+), A investment(-)'; end if;
    when 'investment_income' then
      if not (k <@ array['X','I','Acash','Ainv','Aother']) or not ('I' = any(neg)) or not exists (select 1 from unnest(pos) x where x like 'A%') then
        return et || ': A cash(+), I(-)'; end if;
    when 'transfer_to_clearing' then
      if not (k <@ array['X','C','Acash','Ainv','Arec','Aother','Lcard','Lloan','Lother']) or not ('C' = any(k))
         or not exists (select 1 from unnest(k) x where x like 'A%' or x like 'L%') then return et || ': A or L and C'; end if;
    when 'clearing_resolution' then
      if not ('C' = any(k)) or 'E' = any(k) then return et || ': C with A/L or X/I'; end if;
    when 'opening_balance' then
      if not (k <@ array['E','Acash','Ainv','Arec','Aother','Lcard','Lloan','Lother']) or not ('E' = any(k)) then return et || ': A or L, E'; end if;
    else
      return null;
  end case;
  return null;
end $$;

create function bnx.trg_economic_type_rule() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare why text;
begin
  if bnx.restore_mode() then return null; end if;
  why := bnx.economic_type_violation(new.id);
  if why is not null then
    raise exception 'ECONOMIC_TYPE_RULE_VIOLATION' using errcode = 'P0422', detail = why;
  end if;
  return null;
end $$;
create constraint trigger t_economic_type_rule after insert on bnx.journal_entry
  deferrable initially deferred for each row execute function bnx.trg_economic_type_rule();

-- re-judging tool (audits, reports): historical journals are NOT_APPLICABLE
create function bnx.economic_type_check(p_journal uuid) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case
    when je.id is null then 'NOT_FOUND'
    when coalesce(je.ledger_version, (select max(e.recorded_version) from bnx.posting_batch_event e where e.batch_id = je.posting_batch_id), 0)
         <= (select activated_at_version from bnx.rule_activation_version where rule_key = 'economic_type_rule') then 'NOT_APPLICABLE'
    else coalesce(bnx.economic_type_violation(je.id), 'OK') end
  from (select 1) d left join bnx.journal_entry je on je.id = p_journal
$$;

-- untyped R1 two-line item: type from the counter ledger account kind and the sign on the plan's account
create function bnx.plan_item_type(p_counter_kind text, p_amount numeric) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case
    when p_counter_kind = 'expense' and p_amount < 0 then 'consumption_expense'
    when p_counter_kind = 'expense' and p_amount > 0 then 'refund'
    when p_counter_kind = 'income' and p_amount > 0 then 'income'
    when p_counter_kind = 'clearing' then 'transfer_to_clearing'
    else null end
$$;

create or replace function bnx.wrk_post_plan_chunk(p_plan uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare pl record; b uuid; it record; acid uuid; ac record; j uuid; ap bnx.actor; vnow bigint; lim int; done int := 0; left_ int;
        et text; lines jsonb; ck text; chunk int;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into pl from bnx.posting_plan where id = p_plan for update;
  if not found or pl.state not in ('approved','executing') then return coalesce(pl.state, 'not_found'); end if;
  acid := (pl.scope->>'account_currency_id')::uuid;
  ap := row(pl.approved_by, null, 'pwa', null, array['post'])::bnx.actor;
  if not bnx.actor_can_post(ap, acid) then perform bnx.plan_terminate(p_plan, 'suspended', 'approver no longer authorized'); return 'suspended'; end if;
  if bnx.scope_delta_exists(p_plan, pl.last_validated_version) then
    perform bnx.plan_terminate(p_plan, 'stale', 'scope changed after approval; new approval required'); return 'stale';
  end if;
  select version into vnow from bnx.ledger_state;
  update bnx.posting_plan set last_validated_version = vnow, state = 'executing' where id = p_plan;
  select id into b from bnx.posting_batch where plan_id = p_plan;
  if b is null then
    b := gen_random_uuid();
    insert into bnx.posting_batch(id, plan_id, state) values (b, p_plan, 'open');
    insert into bnx.posting_batch_event(batch_id, event, recorded_version) values (b, 'opened', vnow);
  end if;
  select * into ac from bnx.account_currency where id = acid;
  lim := coalesce((select (value::text)::int from bnx.household_setting where key = 'plan_chunk_size'), 200);
  for it in select * from bnx.posting_plan_item where plan_id = p_plan and posted_journal_id is null order by seq limit lim loop
    if bnx.h(it.payload::text) <> it.payload_sha256 then perform bnx.fail('PLAN_ITEM_TAMPERED', 'P0409'); end if;  -- INV-26
    if it.payload ? 'lines' then
      et := it.payload->>'economic_type'; lines := it.payload->'lines';
      if et is null then perform bnx.fail('PLAN_ITEM_UNTYPED', 'P0422', 'seq ' || it.seq); end if;
    else
      select kind into ck from bnx.ledger_account where id = (it.payload->>'counter_ledger_account_id')::uuid;
      et := coalesce(it.payload->>'economic_type', bnx.plan_item_type(ck, (it.payload->>'amount')::numeric));
      if et is null then perform bnx.fail('PLAN_ITEM_UNTYPED', 'P0422', 'seq ' || it.seq); end if;
      lines := jsonb_build_array(jsonb_build_object('ledger_account_id', ac.ledger_account_id, 'currency', ac.currency, 'amount', it.payload->>'amount'),
                                 jsonb_build_object('ledger_account_id', it.payload->>'counter_ledger_account_id', 'currency', ac.currency,
                                                    'amount', (-(it.payload->>'amount')::numeric)::text));
    end if;
    j := bnx.insert_journal(ap, null, b, et, (it.payload->>'transaction_date')::date, null, it.payload->>'description', lines,
                            null, null, null, p_plan);
    update bnx.posting_plan_item set posted_journal_id = j where plan_id = p_plan and seq = it.seq;
    done := done + 1;
  end loop;
  select count(*) into left_ from bnx.posting_plan_item where plan_id = p_plan and posted_journal_id is null;
  select coalesce(max(chunk_no), 0) + 1 into chunk from bnx.posting_batch_chunk where batch_id = b;
  insert into bnx.posting_batch_chunk(batch_id, chunk_no, posted, remaining, recorded_version) values (b, chunk, done, left_, vnow);
  if left_ > 0 then return 'executing'; end if;
  update bnx.posting_batch set state = 'sealed' where id = b;
  insert into bnx.posting_batch_event(batch_id, event, recorded_version) values (b, 'sealed', vnow) on conflict do nothing;
  update bnx.posting_plan set state = 'sealed' where id = p_plan;
  return 'sealed';
end $$;

select bnx.apply_grants();
