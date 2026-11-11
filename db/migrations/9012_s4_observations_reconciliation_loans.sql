-- 9012 Observations, reconciliation, imports, onboarding, FX, cards and loans (UA V1.2 §5.6, §5.7, §10; OBJ-026, OBJ-248,
-- OBJ-249, OBJ-333, OBJ-373). Built in sub-stages; this file is not final until the last one (docs/s4/S4_9012_Implementation_Notes.md).
--   9012a (this block): R28 intra-household loans: bnx.loan_convention (registry), bnx.loan, bnx.loan_term_event (bitemporal
--          terms), bnx.loan_payment_link (payments are posted journals), the engine bnx.r28_evaluate (exact numeric; the CI
--          oracle is tests/oracle/r28_reference.py), bnx.r28_contract, q_r28_loan_position, cmd_declare_loan,
--          cmd_declare_loan_terms, cmd_link_loan_payment; module-flag enforcement on the three account-scoped tables.
--   NOT_IMPLEMENTED in this file yet: balance_observation_event, reconciliation_exception(+event), statement_period,
--          import_mapping, cross_source_match, payment_attribute, onboarding tables, posting_plan.job_id FK, fx_quote,
--          investment_lot, card_fee_policy, card_fee_event (9012b...).
-- MODIFY: bnx.trg_scope_flag (9007) adds the modes 'loan', 'loan_id' and 'loan_payment_link'.
-- Requires B003 (G0R) because 9011 does.

-- ---------- 9012a: R28 loans (UA V1.2 §5.7, §10; BNX-S2-08 §1; OR-L-01...06) ----------
create table bnx.loan_convention(
  kind text not null check (kind in ('DAY_COUNT','PERIOD_RULE','INTEREST_MODEL','ROUNDING_MODE','ROUNDING_EVENT','WATERFALL')),
  code text not null, note text not null, primary key (kind, code));
insert into bnx.loan_convention values
 ('DAY_COUNT','ACT/365F','actual days / 365'), ('DAY_COUNT','ACT/360','actual days / 360'),
 ('DAY_COUNT','30/360-BB','ISDA 2006 30/360 bond basis'), ('DAY_COUNT','30E/360','Eurobond basis'),
 ('PERIOD_RULE','start_inclusive_end_exclusive','interest for [a, b): the end day is not accrued'),
 ('INTEREST_MODEL','simple','balance x rate x day-count fraction, unrounded across rate segments'),
 ('INTEREST_MODEL','compound','nominal rate / periods_per_year per contracted period end; simple stub; one rate segment'),
 ('ROUNDING_MODE','HALF_UP','half away from zero'), ('ROUNDING_MODE','HALF_EVEN','half to even (explicit; S4B-F19)'),
 ('ROUNDING_EVENT','payment_and_as_of','one rounding per payment event and at the as-of date'),
 ('WATERFALL','interest_then_principal','a payment settles accrued interest first');
insert into bnx.table_class values ('loan_convention','M');
insert into bnx.migration_seeded_table values ('bnx.loan_convention', '9012', 'R28 convention registry (9012a)');

create table bnx.loan(
  id uuid primary key, currency char(3) not null references bnx.currency,
  principal numeric(20,4) not null check (principal > 0),
  start_date date not null, maturity_date date, due_date date,                 -- both optional (OR-L-02: open-ended)
  lender_party_id uuid not null references bnx.party, borrower_party_id uuid not null references bnx.party,
  receivable_account_currency_id uuid references bnx.account_currency,       -- lender side in this household's books
  payable_account_currency_id uuid references bnx.account_currency,          -- borrower side in this household's books
  evidence_ref jsonb not null, created_by uuid not null references bnx.member, created_at timestamptz not null default now(),
  check (lender_party_id <> borrower_party_id),
  check (receivable_account_currency_id is not null or payable_account_currency_id is not null),
  check (maturity_date is null or maturity_date >= start_date), check (due_date is null or due_date >= start_date));
create table bnx.loan_term_event(                                           -- bitemporal terms; nothing is ever updated
  loan_id uuid not null references bnx.loan, event_seq int not null,
  term_kind text not null check (term_kind in ('RATE','DAY_COUNT','PERIOD_RULE','INTEREST_MODEL','COMPOUNDING','ROUNDING','WATERFALL')),
  value jsonb, effective_from date, retracts_event_seq int,
  declared_by uuid not null references bnx.member, evidence_ref jsonb not null,
  recorded_at timestamptz not null default clock_timestamp(),
  primary key (loan_id, event_seq), foreign key (loan_id, retracts_event_seq) references bnx.loan_term_event(loan_id, event_seq),
  check ((value is null) = (retracts_event_seq is not null)),
  check (term_kind <> 'RATE' or retracts_event_seq is not null or effective_from is not null));
create table bnx.loan_payment_link(                                         -- payments are posted journals (OR-L-04)
  loan_id uuid not null references bnx.loan, seq int not null, journal_id uuid not null references bnx.journal_entry,
  cash_account_currency_id uuid not null references bnx.account_currency,
  event text not null check (event in ('linked','unlinked')), actor uuid not null references bnx.member,
  recorded_version bigint not null, recorded_at timestamptz not null default now(), primary key (loan_id, seq));
create index loan_payment_link_journal on bnx.loan_payment_link(journal_id);
create trigger t_append_only before update or delete on bnx.loan for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.loan_term_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.loan_payment_link for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('loan','E'),('loan_term_event','F'),('loan_payment_link','F');

-- ---------- the engine: exact numeric, one division per accrual, rounding only at events ----------
create function bnx.r28_dec(t text) returns numeric
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when t ~ '^-?[0-9]+(\.[0-9]+)?$' then t::numeric end $$;
create function bnx.r28_scale(t text) returns int
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when position('.' in t) > 0 then length(split_part(t, '.', 2)) else 0 end $$;
-- day-count numerator (days); the fraction is days / bnx.r28_basis(conv)
create function bnx.r28_days(conv text, a date, b date) returns int
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare d1 int := extract(day from a); d2 int := extract(day from b);
begin
  if conv in ('ACT/365F','ACT/360') then return b - a; end if;
  if conv = '30/360-BB' then
    if d1 = 31 then d1 := 30; end if;
    if d2 = 31 and d1 >= 30 then d2 := 30; end if;
  elsif conv = '30E/360' then d1 := least(d1, 30); d2 := least(d2, 30);
  else raise exception 'r28_days: unsupported %', conv; end if;
  return 360 * (extract(year from b) - extract(year from a))::int + 30 * (extract(month from b) - extract(month from a))::int + (d2 - d1);
end $$;
create function bnx.r28_basis(conv text) returns int
language sql immutable set search_path = pg_catalog, pg_temp as $$ select case when conv = 'ACT/365F' then 365 else 360 end $$;
-- exact numerator / denominator with 40 decimals (a non-terminating quotient is never near a rounding tie at that depth)
create function bnx.r28_div(n numeric, d numeric) returns numeric
language sql immutable set search_path = pg_catalog, pg_temp as $$ select n::numeric(1000,40) / d $$;
-- explicit rounding (S4B-F19): PostgreSQL round(numeric) is half away from zero, so HALF_EVEN is implemented here
create function bnx.r28_round(x numeric, mu int, mode text) returns numeric
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare q numeric := abs(x) * 10::numeric ^ mu; n numeric := trunc(q); f numeric := q - trunc(q);
begin
  if f > 0.5 or (f = 0.5 and (mode = 'HALF_UP' or mod(n, 2) = 1)) then n := n + 1; end if;
  return round(sign(x) * n / 10::numeric ^ mu, mu);
end $$;

-- r28_evaluate: contract (the oracle's JSON shape) -> {refusal} or the position with its rounding-event ledger. Validation
-- order V0a, V0b, V1, V1a, V1b, V2...V14 (UA V1.2 §10.4; tests/oracle/r28_reference.py documents the same order).
create function bnx.r28_evaluate(c jsonb) returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare principal numeric; pscale int; start date := (c->>'start')::date; as_of date; mu int; cur text := c->>'currency';
        conv text; model text; mode text; basis int; p jsonb; amt numeric; rates jsonb; ppy numeric; ends date[];
        pay_dates date[] := '{}'; pay_amts numeric[] := '{}'; pay_curs text[] := '{}'; pay_scales int[] := '{}';
        seg_from date[]; seg_rate numeric[]; i int; k int;
        pout numeric; carry numeric := 0; ipaid numeric := 0; ppaid numeric := 0; total numeric := 0;
        last date; ex numeric; acc numeric; pi numeric; events jsonb := '[]'; res jsonb; due date; overdue boolean; np int;
begin
  -- V0a
  principal := bnx.r28_dec(c->>'principal');
  if principal is null or principal <= 0 then return jsonb_build_object('refusal', 'REJECT:INVALID_PRINCIPAL'); end if;
  pscale := bnx.r28_scale(c->>'principal');
  -- V0b
  for p in select * from jsonb_array_elements(coalesce(c->'payments', '[]')) loop
    amt := bnx.r28_dec(p->>'amount');
    if amt is null or amt <= 0 then return jsonb_build_object('refusal', 'REJECT:INVALID_PAYMENT'); end if;
    if (p->>'date')::date < start then return jsonb_build_object('refusal', 'REJECT:PAYMENT_BEFORE_START'); end if;
    pay_dates := pay_dates || (p->>'date')::date; pay_amts := pay_amts || amt;
    pay_curs := pay_curs || coalesce(p->>'currency', cur); pay_scales := pay_scales || bnx.r28_scale(p->>'amount');
  end loop;
  -- V1, V1a, V1b
  select minor_units into mu from bnx.currency where code = cur;
  if mu is null then return jsonb_build_object('refusal', 'REJECT:UNKNOWN_CURRENCY'); end if;
  if pscale > mu then return jsonb_build_object('refusal', 'REJECT:INVALID_PRINCIPAL'); end if;
  for i in 1 .. coalesce(array_length(pay_dates, 1), 0) loop
    if pay_curs[i] = cur and pay_scales[i] > mu then return jsonb_build_object('refusal', 'REJECT:INVALID_PAYMENT'); end if;
  end loop;
  -- V2 ... V12
  as_of := (c->>'as_of')::date;
  if as_of < start then return jsonb_build_object('refusal', 'REJECT:AS_OF_BEFORE_START'); end if;
  conv := c->>'day_count';
  if conv is null then return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:day_count'); end if;
  if not exists (select 1 from bnx.loan_convention where kind = 'DAY_COUNT' and code = conv) then
    return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:day_count_unknown'); end if;
  if not exists (select 1 from bnx.loan_convention where kind = 'PERIOD_RULE' and code = c->>'period_rule') then
    return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:period_rule'); end if;
  rates := coalesce(c->'rates', '[]');
  if jsonb_typeof(rates) <> 'array' or jsonb_array_length(rates) = 0 then return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:rates'); end if;
  mode := c->'rounding'->>'mode';
  if not exists (select 1 from bnx.loan_convention where kind = 'ROUNDING_MODE' and code = mode)
     or not exists (select 1 from bnx.loan_convention where kind = 'ROUNDING_EVENT' and code = c->'rounding'->>'event') then
    return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:rounding'); end if;
  if c->>'waterfall' is null then return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:waterfall'); end if;
  if not exists (select 1 from bnx.loan_convention where kind = 'WATERFALL' and code = c->>'waterfall') then
    return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:waterfall_unknown'); end if;
  model := c->>'interest_model';
  if not exists (select 1 from bnx.loan_convention where kind = 'INTEREST_MODEL' and code = model) then
    return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:interest_model'); end if;
  select array_agg((r->>'from')::date order by (r->>'from')::date), array_agg((r->>'annual_rate')::numeric order by (r->>'from')::date)
    into seg_from, seg_rate from jsonb_array_elements(rates) r;
  if exists (select 1 from unnest(seg_rate) x where x < 0) then return jsonb_build_object('refusal', 'REJECT:NEGATIVE_RATE'); end if;
  if (select count(distinct x) from unnest(seg_from) x) <> array_length(seg_from, 1) then
    return jsonb_build_object('refusal', 'REJECT:OVERLAPPING_RATE_SEGMENTS'); end if;
  if seg_from[1] > start then return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:no_rate_at_start'); end if;
  if model = 'compound' then
    if c->'compounding' is null or jsonb_array_length(coalesce(c->'compounding'->'period_ends', '[]')) = 0
       or coalesce((c->'compounding'->>'periods_per_year')::numeric, 0) = 0 then
      return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:compounding'); end if;
    if array_length(seg_from, 1) > 1 then return jsonb_build_object('refusal', 'TERMS_UNVERIFIED:compound_with_rate_changes'); end if;
    ppy := (c->'compounding'->>'periods_per_year')::numeric;
    select array_agg(x::date order by x::date) into ends from jsonb_array_elements_text(c->'compounding'->'period_ends') x;
  end if;
  -- V13
  for i in 1 .. coalesce(array_length(pay_dates, 1), 0) loop
    if pay_curs[i] <> cur then return jsonb_build_object('refusal', 'REJECT:PAYMENT_CURRENCY_MISMATCH'); end if;
  end loop;
  select array_agg(d order by d, o), array_agg(a order by d, o) into pay_dates, pay_amts
    from unnest(pay_dates, pay_amts) with ordinality u(d, a, o);
  basis := bnx.r28_basis(conv);
  pout := principal; last := start;
  np := (select count(*) from unnest(pay_dates) x where x <= as_of);       -- payments after as_of are ignored
  for i in 1 .. np + 1 loop
    declare b date := case when i <= np then pay_dates[i] else as_of end;
            num numeric := 0; cd date := last; nb date; rate numeric; n int := 0; f numeric := 1; g numeric := 1; sd int;
    begin
      if model = 'simple' then
        for k in 1 .. array_length(seg_from, 1) + 1 loop
          nb := case when k <= array_length(seg_from, 1) then seg_from[k] else b end;
          continue when k <= array_length(seg_from, 1) and not (last < nb and nb < b);
          if nb > cd then
            select r into rate from unnest(seg_from, seg_rate) s(fr, r) where fr <= cd order by fr desc limit 1;
            num := num + pout * rate * bnx.r28_days(conv, cd, nb);
          end if;
          cd := nb;
        end loop;
        ex := bnx.r28_div(num, basis);
      else
        rate := seg_rate[1];
        for k in 1 .. array_length(ends, 1) loop
          continue when ends[k] <= last;
          exit when ends[k] > b;
          n := n + 1; cd := ends[k];
        end loop;
        sd := case when b > cd then bnx.r28_days(conv, cd, b) else 0 end;
        for k in 1 .. n loop f := f * (ppy + rate); g := g * ppy; end loop;
        ex := bnx.r28_div(pout * f * (basis + rate * sd), g * basis) - pout;
      end if;
      acc := bnx.r28_round(ex, mu, mode);
      events := events || jsonb_build_object('event_date', b::text, 'kind', case when i <= np then 'payment' else 'as_of' end,
                                             'unrounded_trunc12', trunc(ex, 12)::text, 'rounded', round(acc, mu)::text, 'mode', mode);
      total := total + acc; carry := carry + acc;
      if i <= np then
        amt := pay_amts[i];
        if amt > carry + pout then return jsonb_build_object('refusal', 'REJECT:OVERPAYMENT'); end if;   -- V14
        pi := least(amt, carry);
        carry := carry - pi; ipaid := ipaid + pi; pout := pout - (amt - pi); ppaid := ppaid + (amt - pi);
        last := b;
      end if;
    end;
  end loop;
  res := jsonb_build_object('status', 'OK', 'accrued_interest_total', round(total, mu)::text, 'accrued_interest', round(total, mu)::text,
           'principal_outstanding', round(pout, mu)::text, 'interest_outstanding', round(carry, mu)::text,
           'outstanding_total', round(pout + carry, mu)::text, 'interest_paid', round(ipaid, mu)::text,
           'principal_paid', round(ppaid, mu)::text);
  due := (c->>'due_date')::date;
  if due is null then
    res := res || jsonb_build_object('overdue', null, 'days_past_due', null);
  else
    overdue := as_of > due and pout + carry > 0;
    res := res || jsonb_build_object('overdue', overdue, 'days_past_due', case when overdue then as_of - due else 0 end);
  end if;
  return res || jsonb_build_object('rounding_events', events);
end $$;

-- trg_scope_flag MODIFY (9007 body; adds the 9012a modes 'loan', 'loan_id' and 'loan_payment_link')
create or replace function bnx.trg_scope_flag() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare x uuid;
begin
  if bnx.restore_mode() then return new; end if;
  case tg_argv[0]
    when 'account' then
      if tg_op = 'INSERT' or new.region_scope is distinct from old.region_scope then perform bnx.pol_require_region(new.region_scope); end if;
    when 'account_id' then perform bnx.pol_require_module_for_account(new.account_id);
    when 'account_grant' then
      -- Owner decision 2026-11-06 (F-C2-13): while a region is disabled a grant on it may be reduced (revoked), never added
      -- or widened. cmd_set_grant upserts, so a BEFORE INSERT compares against the existing grant.
      if tg_op = 'UPDATE' then
        if (new.can_view and not old.can_view) or (new.can_post and not old.can_post) then
          perform bnx.pol_require_module_for_account(new.account_id); end if;
      elsif not exists (select 1 from bnx.account_grant g where g.member_id = new.member_id and g.account_id = new.account_id
                         and (g.can_view or not new.can_view) and (g.can_post or not new.can_post)) then
        perform bnx.pol_require_module_for_account(new.account_id);
      end if;
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
    when 'loan' then                                                           -- 9012a
      if new.receivable_account_currency_id is not null then perform bnx.pol_require_module_for_ac(new.receivable_account_currency_id); end if;
      if new.payable_account_currency_id is not null then perform bnx.pol_require_module_for_ac(new.payable_account_currency_id); end if;
    when 'loan_id' then                                                        -- 9012a
      for x in select unnest(array[l.receivable_account_currency_id, l.payable_account_currency_id]) from bnx.loan l where l.id = new.loan_id loop
        if x is not null then perform bnx.pol_require_module_for_ac(x); end if;
      end loop;
    when 'loan_payment_link' then perform bnx.pol_require_module_for_ac(new.cash_account_currency_id);   -- 9012a
    else raise exception 'trg_scope_flag: unknown mode %', tg_argv[0];
  end case;
  return new;
end $$;

-- contract for the engine from the stored facts: terms as recorded at p_t (bitemporal; a retracted event no longer counts),
-- payments as linked at ledger version p_v, from journals visible at p_v and not corrected at or before p_v
create function bnx.r28_contract(p_loan uuid, p_as_of date, p_v bigint, p_t timestamptz) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with ev as (
    select e.* from bnx.loan_term_event e
     where e.loan_id = p_loan and e.recorded_at <= p_t and e.retracts_event_seq is null
       and not exists (select 1 from bnx.loan_term_event x where x.loan_id = e.loan_id and x.retracts_event_seq = e.event_seq
                         and x.recorded_at <= p_t)),
  lastof as (select distinct on (term_kind) term_kind, value from ev where term_kind <> 'RATE' order by term_kind, event_seq desc),
  links as (
    select distinct on (k.journal_id) k.journal_id, k.cash_account_currency_id, k.event from bnx.loan_payment_link k
     where k.loan_id = p_loan and k.recorded_version <= p_v order by k.journal_id, k.seq desc),
  pay as (
    select je.transaction_date, ac.currency, sum(jl.amount) amount
      from links k
      join bnx.visible_at(p_v) v on v.journal_id = k.journal_id
      join bnx.journal_entry je on je.id = k.journal_id
      join bnx.account_currency ac on ac.id = k.cash_account_currency_id
      join bnx.journal_line jl on jl.journal_id = k.journal_id and jl.ledger_account_id = ac.ledger_account_id
     where k.event = 'linked'
       and not exists (select 1 from bnx.journal_correction jc where jc.original_journal_id = k.journal_id and jc.recorded_version <= p_v)
     group by k.journal_id, je.transaction_date, ac.currency)
  select jsonb_strip_nulls(jsonb_build_object(
           'currency', l.currency, 'principal', trim_scale(l.principal)::text, 'start', l.start_date::text, 'as_of', p_as_of::text,
           'due_date', l.due_date::text,
           'day_count', (select value->>'code' from lastof where term_kind = 'DAY_COUNT'),
           'period_rule', (select value->>'code' from lastof where term_kind = 'PERIOD_RULE'),
           'interest_model', (select value->>'code' from lastof where term_kind = 'INTEREST_MODEL'),
           'waterfall', (select value->>'code' from lastof where term_kind = 'WATERFALL'),
           'rounding', (select value from lastof where term_kind = 'ROUNDING'),
           'compounding', (select value from lastof where term_kind = 'COMPOUNDING')))
         || jsonb_build_object(
           'rates', coalesce((select jsonb_agg(jsonb_build_object('from', ev.effective_from::text, 'annual_rate', ev.value->>'annual_rate')
                                               order by ev.effective_from, ev.event_seq) from ev where ev.term_kind = 'RATE'), '[]'),
           'payments', coalesce((select jsonb_agg(jsonb_build_object('date', p.transaction_date::text, 'amount', trim_scale(p.amount)::text,
                                                                     'currency', p.currency) order by p.transaction_date) from pay p), '[]'))
    from bnx.loan l where l.id = p_loan
$$;

-- household_internal (OR-L-06, INV-23b): both sides are in this household's books and the verified ownership facts at
-- (as_of, version) name the lender on the receivable account and the borrower on the payable account; never from names
create function bnx.r28_household_internal(p_loan uuid, p_as_of date, p_v bigint) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select l.receivable_account_currency_id is not null and l.payable_account_currency_id is not null
     and exists (select 1 from bnx.account_currency ac, bnx.ownership_at(ac.account_id, p_as_of, p_v) o
                  where ac.id = l.receivable_account_currency_id and o.party_id = l.lender_party_id)
     and exists (select 1 from bnx.account_currency ac, bnx.ownership_at(ac.account_id, p_as_of, p_v) o
                  where ac.id = l.payable_account_currency_id and o.party_id = l.borrower_party_id)
     from bnx.loan l where l.id = p_loan), false)
$$;

create function bnx.q_r28_loan_position(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); l bnx.loan; lid uuid; as_of date; v bigint; vnow bigint; t timestamptz;
        vis uuid[]; sides uuid[]; seen int; c jsonb; r jsonb; st text;
begin
  perform bnx.require(a, 0);
  begin
    lid := (q->>'loan_id')::uuid; as_of := coalesce((q->>'as_of')::date, current_date);
    t := coalesce((q->>'terms_recorded_as_of')::timestamptz, clock_timestamp());
    v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'loan_id, as_of, ledger_version or terms_recorded_as_of');
  end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  select * into l from bnx.loan where id = lid;
  vis := array(select bnx.actor_visible_acs(a));
  sides := array_remove(array[l.receivable_account_currency_id, l.payable_account_currency_id], null);
  seen := (select count(*) from unnest(sides) x where x = any(vis));
  if l.id is null or seen = 0 then perform bnx.fail('NOT_FOUND', 'P0404'); end if;     -- no existence leak
  for lid in select x from unnest(sides) x where x = any(vis) loop perform bnx.pol_require_module_for_ac(lid); end loop;
  c := bnx.r28_contract(l.id, as_of, v, t);
  r := bnx.r28_evaluate(c);
  st := case when r ? 'refusal' then split_part(r->>'refusal', ':', 1) else 'OK' end;
  return jsonb_build_object('loan_id', l.id, 'as_of', as_of, 'ledger_version', v, 'terms_recorded_as_of', t, 'currency', l.currency,
           'status', case st when 'REJECT' then 'REJECTED' else st end, 'refusal', r->>'refusal',
           'position', case when st = 'OK' then r - 'rounding_events' - 'status' end,   -- null, never zero, when not computed (OR-L-03)
           'rounding_events', coalesce(r->'rounding_events', '[]'),
           'payments_counted', jsonb_array_length(c->'payments'),
           'partial_view', cardinality(sides) = 2 and seen = 1,
           'household_internal', bnx.r28_household_internal(l.id, as_of, v),
           'engine', 'bnx.r28_evaluate/9012a', 'oracle', 'tests/oracle/r28_reference.py V1.2');
end $$;

-- the actor must be allowed to post on every side of the loan that is in this household's books
create function bnx.r28_require_post(a bnx.actor, l bnx.loan) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if (l.receivable_account_currency_id is not null and not bnx.actor_can_post(a, l.receivable_account_currency_id))
     or (l.payable_account_currency_id is not null and not bnx.actor_can_post(a, l.payable_account_currency_id)) then
    perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
end $$;

create function bnx.cmd_declare_loan(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; l bnx.loan; mu int; side text;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'declare_loan', cmd); if rc is not null then return rc; end if;
  select minor_units into mu from bnx.currency where code = cmd->>'currency';
  if mu is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'currency'); end if;
  if bnx.r28_dec(cmd->>'principal') is null or bnx.r28_dec(cmd->>'principal') <= 0 or bnx.r28_scale(cmd->>'principal') > mu then
    perform bnx.fail('INVALID_PRINCIPAL', 'P0422'); end if;
  if jsonb_typeof(cmd->'evidence_ref') is distinct from 'object' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'evidence_ref'); end if;
  begin
    l := row(gen_random_uuid(), cmd->>'currency', (cmd->>'principal')::numeric, (cmd->>'start')::date, (cmd->>'maturity_date')::date,
             (cmd->>'due_date')::date, (cmd->>'lender_party_id')::uuid, (cmd->>'borrower_party_id')::uuid,
             (cmd->>'receivable_account_currency_id')::uuid, (cmd->>'payable_account_currency_id')::uuid, cmd->'evidence_ref',
             a.member_id, now())::bnx.loan;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'loan fields');
  end;
  if l.start_date is null or l.lender_party_id is null or l.borrower_party_id is null or l.lender_party_id = l.borrower_party_id
     or (l.receivable_account_currency_id is null and l.payable_account_currency_id is null)
     or not exists (select 1 from bnx.party where id = l.lender_party_id) or not exists (select 1 from bnx.party where id = l.borrower_party_id) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'parties, start or accounts'); end if;
  for side in select x from unnest(array['receivable','payable']) x loop
    declare acid uuid := case side when 'receivable' then l.receivable_account_currency_id else l.payable_account_currency_id end;
            ok boolean;
    begin
      continue when acid is null;
      select ac.currency = l.currency and acc.kind = 'loan_' || side into ok
        from bnx.account_currency ac join bnx.account acc on acc.id = ac.account_id where ac.id = acid;
      if not coalesce(ok, false) then perform bnx.fail('VALIDATION_FAILED', 'P0422', side || ' account'); end if;
    end;
  end loop;
  perform bnx.r28_require_post(a, l);
  insert into bnx.loan select (l).*;
  perform bnx.audit(a, 'declare_loan', jsonb_build_object('loan_id', l.id), cmd, null);
  return bnx.idem_end(a, 'declare_loan', cmd, jsonb_build_object('loan_id', l.id));
end $$;

-- append term events (bitemporal): RATE needs effective_from; a correction retracts an earlier event and adds the new one
create function bnx.cmd_declare_loan_terms(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; l bnx.loan; e jsonb; s int; out int[] := '{}'; k text; v jsonb;
        ok boolean;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'declare_loan_terms', cmd); if rc is not null then return rc; end if;
  begin select * into l from bnx.loan where id = (cmd->>'loan_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'loan_id'); end;
  if l.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform bnx.r28_require_post(a, l);
  if jsonb_typeof(cmd->'evidence_ref') is distinct from 'object' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'evidence_ref'); end if;
  if jsonb_typeof(cmd->'events') is distinct from 'array' or jsonb_array_length(cmd->'events') not between 1 and 50 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'events'); end if;
  perform 1 from bnx.loan where id = l.id for update;                         -- serialises event_seq per loan
  s := coalesce((select max(event_seq) from bnx.loan_term_event where loan_id = l.id), 0);
  for e in select * from jsonb_array_elements(cmd->'events') loop
    k := e->>'term_kind'; v := e->'value'; s := s + 1;
    if e ? 'retracts_event_seq' then
      if v is not null or not exists (select 1 from bnx.loan_term_event x where x.loan_id = l.id and x.event_seq = (e->>'retracts_event_seq')::int
                                       and x.term_kind = k and x.retracts_event_seq is null) then
        perform bnx.fail('VALIDATION_FAILED', 'P0422', 'retracts_event_seq'); end if;
    else
      ok := case k
        when 'RATE' then jsonb_typeof(v) = 'object' and bnx.r28_dec(v->>'annual_rate') is not null and e->>'effective_from' ~ '^\d{4}-\d{2}-\d{2}$'
        when 'ROUNDING' then jsonb_typeof(v) = 'object' and v->>'mode' ~ '^[A-Z_]{1,20}$' and v->>'event' ~ '^[a-z_]{1,40}$'
        when 'COMPOUNDING' then jsonb_typeof(v) = 'object' and (v->>'periods_per_year') ~ '^[1-9][0-9]{0,2}$'
                                and jsonb_typeof(v->'period_ends') = 'array' and jsonb_array_length(v->'period_ends') between 1 and 1200
                                and not exists (select 1 from jsonb_array_elements_text(v->'period_ends') x where x !~ '^\d{4}-\d{2}-\d{2}$')
        when 'DAY_COUNT' then jsonb_typeof(v) = 'object' and v->>'code' ~ '^[A-Za-z0-9/ _-]{1,30}$'
        when 'PERIOD_RULE' then jsonb_typeof(v) = 'object' and v->>'code' ~ '^[A-Za-z0-9/ _-]{1,40}$'
        when 'INTEREST_MODEL' then jsonb_typeof(v) = 'object' and v->>'code' ~ '^[A-Za-z0-9/ _-]{1,30}$'
        when 'WATERFALL' then jsonb_typeof(v) = 'object' and v->>'code' ~ '^[A-Za-z0-9/ _-]{1,40}$'
        else false end;
      if not coalesce(ok, false) then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'term ' || coalesce(k, 'null')); end if;
    end if;
    begin
      insert into bnx.loan_term_event(loan_id, event_seq, term_kind, value, effective_from, retracts_event_seq, declared_by, evidence_ref)
      values (l.id, s, k, v, (e->>'effective_from')::date, (e->>'retracts_event_seq')::int, a.member_id, cmd->'evidence_ref');
    exception when invalid_datetime_format or datetime_field_overflow or check_violation then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'term ' || k);
    end;
    out := out || s;
  end loop;
  perform bnx.audit(a, 'declare_loan_terms', jsonb_build_object('loan_id', l.id, 'event_seqs', to_jsonb(out)), cmd, null);
  return bnx.idem_end(a, 'declare_loan_terms', cmd, jsonb_build_object('loan_id', l.id, 'event_seqs', to_jsonb(out)));
end $$;

-- link (or unlink) a posted journal as a payment of the loan; the amount is the journal's movement on the cash account
create function bnx.cmd_link_loan_payment(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; l bnx.loan; j uuid; cash uuid; ev text := coalesce(cmd->>'event', 'linked');
        v bigint; s int; cur text;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'link_loan_payment', cmd); if rc is not null then return rc; end if;
  begin select * into l from bnx.loan where id = (cmd->>'loan_id')::uuid; j := (cmd->>'journal_id')::uuid;
        cash := (cmd->>'cash_account_currency_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'loan_id, journal_id or cash_account_currency_id'); end;
  if l.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if ev not in ('linked','unlinked') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'event'); end if;
  perform bnx.r28_require_post(a, l);
  if cash is null or not bnx.actor_can_post(a, cash) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if not exists (select 1 from bnx.visible_at(9223372036854775807) x where x.journal_id = j)
     or not exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                     where jl.journal_id = j and ac.id = cash) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform 1 from bnx.loan where id = l.id for update;
  if ev = 'linked' and exists (select 1 from bnx.loan_payment_link k where k.journal_id = j and k.loan_id <> l.id and k.event = 'linked'
                                 and k.seq = (select max(seq) from bnx.loan_payment_link x where x.loan_id = k.loan_id and x.journal_id = j)) then
    perform bnx.fail('ALREADY_LINKED', 'P0409'); end if;                     -- one journal pays one loan
  if (select k.event from bnx.loan_payment_link k where k.loan_id = l.id and k.journal_id = j order by k.seq desc limit 1)
       is not distinct from (case ev when 'linked' then 'linked' else null end) or
     (ev = 'unlinked' and coalesce((select k.event from bnx.loan_payment_link k where k.loan_id = l.id and k.journal_id = j
                                     order by k.seq desc limit 1), 'unlinked') = 'unlinked') then
    perform bnx.fail('LINK_STATE', 'P0409'); end if;
  v := bnx.next_version();
  s := coalesce((select max(seq) from bnx.loan_payment_link where loan_id = l.id), 0) + 1;
  insert into bnx.loan_payment_link(loan_id, seq, journal_id, cash_account_currency_id, event, actor, recorded_version)
  values (l.id, s, j, cash, ev, a.member_id, v);
  perform bnx.audit(a, 'link_loan_payment', jsonb_build_object('loan_id', l.id, 'journal_id', j, 'event', ev), cmd, v);
  return bnx.idem_end(a, 'link_loan_payment', cmd, jsonb_build_object('loan_id', l.id, 'journal_id', j, 'event', ev, 'ledger_version', v));
end $$;

-- module-flag enforcement on the account-scoped loan tables (F-C2-07)
insert into bnx.flag_enforcement_point values
 ('loan','loan','INSERT','9012','bnx'), ('loan_term_event','loan_id','INSERT','9012','bnx'),
 ('loan_payment_link','loan_payment_link','INSERT','9012','bnx');
create trigger t_scope_flag_loan before insert on bnx.loan for each row execute function bnx.trg_scope_flag('loan');
create trigger t_scope_flag_loan_term_event before insert on bnx.loan_term_event for each row execute function bnx.trg_scope_flag('loan_id');
create trigger t_scope_flag_loan_payment_link before insert on bnx.loan_payment_link for each row execute function bnx.trg_scope_flag('loan_payment_link');

insert into bnx.function_scope values ('q_r28_loan_position', 'finance.read', false, false, true, 'fin.loans.position');

select bnx.apply_grants();
