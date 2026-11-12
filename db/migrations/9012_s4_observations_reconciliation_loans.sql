-- 9012 Observations, reconciliation, imports, onboarding, FX, cards and loans (UA V1.2 §5.6, §5.7, §10; OBJ-026, OBJ-248,
-- OBJ-249, OBJ-333, OBJ-373). Built in sub-stages; this file is not final until the last one (docs/s4/S4_9012_Implementation_Notes.md).
--   9012a (this block): R28 intra-household loans: bnx.loan_convention (registry), bnx.loan, bnx.loan_term_event (bitemporal
--          terms), bnx.loan_payment_link (payments are posted journals), the engine bnx.r28_evaluate (exact numeric; the CI
--          oracle is tests/oracle/r28_reference.py), bnx.r28_contract, q_r28_loan_position, cmd_declare_loan,
--          cmd_declare_loan_terms, cmd_link_loan_payment; module-flag enforcement on the three account-scoped tables.
--   9012b: FX quotes (bnx.fx_quote, bnx.fx_rate_at, q_fx_rate, cmd_record_fx_quote, cmd_fx_override on the R1
--          bnx.fx_override_event), investment lots (bnx.investment_lot, bnx.investment_lot_disposal, cmd_record_investment_lot,
--          cmd_record_lot_disposal, cmd_record_valuation on the R1 bnx.valuation, q_investment_position), card annual-fee policy
--          and events (bnx.card_fee_policy, bnx.card_fee_event, cmd_set_card_fee_policy, cmd_record_card_fee_event,
--          q_card_fee_progress); module-flag enforcement on the four account-scoped tables.
--   9012c-1 (OWNER_DECISION 2026-11-11, option 2): bnx.balance_observation_event, cmd_record_observation (RC-POST),
--          q_balance_observations, bnx.statement_period (view) / bnx.statement_period_at.
--   9012c-2 (Draft-04 §D1-§D7, located 2026-11-11): bnx.reconciliation_run, bnx.reconciliation_exception(+event) with the
--          §D5 classification and the §D7 lifecycle, the deterministic engine (bnx.recon_evaluate_statement /
--          recon_evaluate_observation: stage 1, stage 2, RC-01...RC-14), cmd_run_reconciliation, cmd_set_reconciliation_exception_state,
--          q_reconciliation_exceptions, q_reconciliation_coverage.
--   9012d (Draft-04 §C4/§C5; S2-02): matching MR-08...MR-13 (bnx.match_propose, cmd_match_source_rows, cmd_decide_match,
--          cmd_match_clearing, q_transfer_matching on R1 match_decision_event/current), bnx.onboarding_job(+event),
--          bnx.source_file_state, bnx.account_history_state with the SF-/AH- transitions, posting_plan.job_id FK,
--          cmd_onboarding_*, wrk_onboarding_step, q_onboarding_job; bnx.import_mapping, bnx.payment_attribute,
--          bnx.cross_source_match(+event).
--   NOT_IMPLEMENTED (need WP-DOC extraction runs, staged rows, running balances): MR-01...MR-07, the onboarding scheduler tick,
--          account discovery wiring, onboarding exceptions and the completion report (L-9012-11).
-- MODIFY: bnx.trg_scope_flag (9007) adds the modes 'loan', 'loan_id', 'loan_payment_link' (9012a), 'lot_id' and 'card_fee' (9012b).
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

-- trg_scope_flag MODIFY (9007 body; adds the 9012a modes 'loan', 'loan_id', 'loan_payment_link' and the 9012b modes 'lot_id', 'card_fee')
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
    when 'lot_id' then                                                         -- 9012b
      perform bnx.pol_require_module_for_ac((select l.account_currency_id from bnx.investment_lot l where l.id = new.lot_id));
    when 'card_fee' then perform bnx.pol_require_module_for_account(new.card_account_id);               -- 9012b
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

-- FAMILY pseudo-institution (OWNER_DECISION 2026-11-11, L-9012-1 option 2): loan accounts between family members name the
-- registry institution FAMILY instead of a bank. It has no jurisdiction, so such an account declares its region_scope
-- (cmd_create_account, F-C2-05 path). It is eligible only for loan_receivable and loan_payable accounts, on every writer of
-- bnx.account (create, reassignment, any later kind change); restore replays are exempt as for the 9006 triggers.
insert into bnx.institution(id, name_en, name_zh, country, code, kind, jurisdiction, classification, seed_set, status, verification_provenance)
select gen_random_uuid(), 'Family', '家庭', null, 'FAMILY', 'other', null, 'HOUSEHOLD_PSEUDO_INSTITUTION', null, 'ACTIVE_SEED',
       jsonb_build_object('source', 'migration:9012', 'decision', 'OWNER_DECISION 2026-11-11 L-9012-1 option 2',
                          'scope', 'loan_receivable and loan_payable accounts only')
 where not exists (select 1 from bnx.institution where code = 'FAMILY');
insert into bnx.institution_name(institution_id, name_kind, lang, value, normalized, verification, source)
select i.id, 'display', x.lang, x.val, bnx.normalize_institution_name(x.val), 'VERIFIED', '{"source":"OWNER_DECISION 2026-11-11 L-9012-1"}'
  from bnx.institution i cross join lateral (values ('en', 'Family'), ('zh-CN', '家庭')) x(lang, val)
 where i.code = 'FAMILY' and bnx.normalize_institution_name(x.val) is not null
   and not exists (select 1 from bnx.institution_name n where n.institution_id = i.id and n.lang = x.lang and n.name_kind = 'display');

create function bnx.trg_account_family_institution() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.restore_mode() then return new; end if;
  if new.institution_id is not null and new.kind not in ('loan_receivable','loan_payable')
     and exists (select 1 from bnx.institution where id = new.institution_id and code = 'FAMILY') then
    raise exception 'INSTITUTION_NOT_ELIGIBLE' using errcode = 'P0422',
          detail = 'FAMILY is for loan_receivable and loan_payable accounts only';
  end if;
  return new;
end $$;
create trigger t_account_family_institution before insert or update of institution_id, kind on bnx.account
  for each row execute function bnx.trg_account_family_institution();

-- ---------- 9012b: FX quotes, investment lots, card fee policy and events (UA V1.2 §5.7; BNX-S2-02 §4.7; OR-R-07/08/09) ----------
-- Every money figure is exact numeric until output; output rounding is HALF_EVEN at the currency's minor units (S4B-F19).
-- A figure that cannot be computed is null with a reason, never zero (as OR-L-03).

-- decimal string (or JSON number) -> numeric; null when not a plain decimal, negative, above the scale or too large
create function bnx.fin_dec(t text, p_scale int, p_int_digits int) returns numeric
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when t ~ '^[0-9]{1,40}(\.[0-9]{1,40})?$' and bnx.r28_scale(t) <= p_scale
               and length(split_part(ltrim(t, '0'), '.', 1)) <= p_int_digits then t::numeric end $$;
-- output: HALF_EVEN at mu decimals as a decimal string; null stays null
create function bnx.fin_money(x numeric, mu int) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when x is not null then bnx.r28_round(x, mu, 'HALF_EVEN')::text end $$;
-- the economic type a journal counts as: a replacement counts as the type of the journal it replaces (9008: "follows original")
create function bnx.effective_economic_type(p_journal uuid) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with recursive up(id, et, depth) as (
    select je.id, je.economic_type::text, 0 from bnx.journal_entry je where je.id = p_journal
    union all
    select jc.original_journal_id, o.economic_type::text, up.depth + 1
      from up join bnx.journal_correction jc on jc.replacement_journal_id = up.id
      join bnx.journal_entry o on o.id = jc.original_journal_id
     where up.et = 'correction_replacement' and up.depth < 100)
  select et from up order by depth desc limit 1
$$;
-- a journal counts at ledger version v when it is visible at v and not corrected at or before v. Visibility is the R1
-- bnx.visible_at (0006) rule for one journal (a direct posting at or before v, or a plan posting whose batch was activated
-- at or before v), written per journal so that it uses the primary key instead of scanning every journal per call.
create function bnx.journal_counts_at(p_journal uuid, p_v bigint) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from bnx.journal_entry je where je.id = p_journal
                   and (je.ledger_version <= p_v
                        or exists (select 1 from bnx.posting_batch_event ev where ev.batch_id = je.posting_batch_id
                                     and ev.event = 'activated' and ev.recorded_version <= p_v)))
     and not exists (select 1 from bnx.journal_correction jc where jc.original_journal_id = p_journal and jc.recorded_version <= p_v)
$$;
-- the journal's movement on one account-currency
create function bnx.journal_movement(p_journal uuid, p_ac uuid) returns numeric
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select sum(jl.amount) from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
   where jl.journal_id = p_journal and ac.id = p_ac
$$;

-- ---------- FX quotes (OR-R-09) ----------
create table bnx.fx_quote(
  id uuid primary key, base char(3) not null references bnx.currency, quote char(3) not null references bnx.currency,
  rate numeric(28,10), as_of date not null, source text not null check (source ~ '^[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,63}$'),
  quality text not null check (quality in ('REFERENCE','EVIDENCED_SETTLEMENT','MISSING','STALE')),
  evidence_ref jsonb, journal_id uuid references bnx.journal_entry,
  recorded_by uuid not null references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  check (base <> quote), check ((rate is null) = (quality = 'MISSING')), check (rate is null or rate > 0),
  check (evidence_ref is null or jsonb_typeof(evidence_ref) = 'object'),
  check (quality <> 'EVIDENCED_SETTLEMENT' or evidence_ref is not null or journal_id is not null));
create index fx_quote_pair on bnx.fx_quote(base, quote, as_of);
create trigger t_append_only before update or delete on bnx.fx_quote for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('fx_quote','F');

-- the rate for base -> quote on a date at ledger version v. Precedence: Owner override for that date, then an evidenced
-- settlement rate for that date, then the latest reference quote on or before the date (STALE when older than 7 days or
-- recorded as STALE), else MISSING with a null rate. Each quality is tried directly, then as the inverse pair (1 / rate,
-- 10 decimals, HALF_EVEN). Same currency is IDENTITY (1).
create function bnx.fx_rate_at(p_base char(3), p_quote char(3), p_date date, p_v bigint) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare inv boolean; b char(3); c char(3); o record; r numeric; miss record;
begin
  if p_base = p_quote then
    return jsonb_build_object('base', p_base, 'quote', p_quote, 'date', p_date, 'rate', '1', 'quality', 'IDENTITY', 'inverse', false);
  end if;
  for inv in select unnest(array[false, true]) loop                           -- 1. override
    b := case when inv then p_quote else p_base end; c := case when inv then p_base else p_quote end;
    select e.id, e.rate into o from bnx.fx_override_event e
     where e.base = b and e.quote = c and e.rate_date = p_date and e.recorded_version <= p_v
     order by e.recorded_version desc, e.id desc limit 1;
    if found then
      r := case when inv then bnx.r28_round(bnx.r28_div(1, o.rate), 10, 'HALF_EVEN') else o.rate end;
      return jsonb_build_object('base', p_base, 'quote', p_quote, 'date', p_date, 'rate', trim_scale(r)::text, 'quality', 'OVERRIDE',
                                'rate_date', p_date, 'override_id', o.id, 'inverse', inv);
    end if;
  end loop;
  for inv in select unnest(array[false, true]) loop                           -- 2. evidenced settlement for that date
    b := case when inv then p_quote else p_base end; c := case when inv then p_base else p_quote end;
    select q.id, q.rate, q.source into o from bnx.fx_quote q
     where q.base = b and q.quote = c and q.as_of = p_date and q.quality = 'EVIDENCED_SETTLEMENT' and q.recorded_version <= p_v
       and (q.journal_id is null or bnx.journal_counts_at(q.journal_id, p_v))
     order by q.recorded_version desc, q.id desc limit 1;
    if found then
      r := case when inv then bnx.r28_round(bnx.r28_div(1, o.rate), 10, 'HALF_EVEN') else o.rate end;
      return jsonb_build_object('base', p_base, 'quote', p_quote, 'date', p_date, 'rate', trim_scale(r)::text,
                                'quality', 'EVIDENCED_SETTLEMENT', 'rate_date', p_date, 'quote_id', o.id, 'source', o.source, 'inverse', inv);
    end if;
  end loop;
  for inv in select unnest(array[false, true]) loop                           -- 3. reference on or before the date
    b := case when inv then p_quote else p_base end; c := case when inv then p_base else p_quote end;
    select q.id, q.rate, q.source, q.as_of, q.quality into o from bnx.fx_quote q
     where q.base = b and q.quote = c and q.as_of <= p_date and q.quality in ('REFERENCE','STALE') and q.recorded_version <= p_v
     order by q.as_of desc, q.recorded_version desc, q.id desc limit 1;
    if found then
      r := case when inv then bnx.r28_round(bnx.r28_div(1, o.rate), 10, 'HALF_EVEN') else o.rate end;
      return jsonb_build_object('base', p_base, 'quote', p_quote, 'date', p_date, 'rate', trim_scale(r)::text,
                                'quality', case when o.quality = 'STALE' or p_date - o.as_of > 7 then 'STALE' else 'REFERENCE' end,
                                'rate_date', o.as_of, 'quote_id', o.id, 'source', o.source, 'inverse', inv);
    end if;
  end loop;
  select q.id, q.source into miss from bnx.fx_quote q                         -- 4. missing (a recorded MISSING names its source)
   where ((q.base = p_base and q.quote = p_quote) or (q.base = p_quote and q.quote = p_base)) and q.as_of = p_date
     and q.quality = 'MISSING' and q.recorded_version <= p_v order by q.recorded_version desc, q.id desc limit 1;
  return jsonb_strip_nulls(jsonb_build_object('base', p_base, 'quote', p_quote, 'date', p_date, 'quality', 'MISSING',
                                              'quote_id', miss.id, 'source', miss.source, 'inverse', false)) || '{"rate": null}';
end $$;

create function bnx.q_fx_rate(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); b text; c text; d date; v bigint; vnow bigint;
begin
  perform bnx.require(a, 0);
  begin
    b := q->>'base'; c := q->>'quote'; d := coalesce((q->>'date')::date, current_date); v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'base, quote, date or ledger_version');
  end;
  if not exists (select 1 from bnx.currency where code = b) or not exists (select 1 from bnx.currency where code = c) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'currency'); end if;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  return bnx.fx_rate_at(b, c, d, v) || jsonb_build_object('ledger_version', v,
           'fx_policy', 'OVERRIDE > EVIDENCED_SETTLEMENT (same date) > REFERENCE (on or before; STALE after 7 days) > MISSING; inverse pair 1/rate at 10 decimals HALF_EVEN');
end $$;

-- record a quote (tier 2). A settlement rate needs evidence or a posted journal the actor can post on.
create function bnx.cmd_record_fx_quote(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; qu text := cmd->>'quality'; r numeric; d date; j uuid; v bigint; nid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_fx_quote', cmd); if rc is not null then return rc; end if;
  begin d := (cmd->>'as_of')::date; j := (cmd->>'journal_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of or journal_id'); end;
  if d is null or coalesce(qu, '') not in ('REFERENCE','EVIDENCED_SETTLEMENT','MISSING','STALE')
     or not exists (select 1 from bnx.currency where code = cmd->>'base') or not exists (select 1 from bnx.currency where code = cmd->>'quote')
     or cmd->>'base' = cmd->>'quote' or coalesce(cmd->>'source', '') !~ '^[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,63}$'
     or (cmd ? 'evidence_ref' and jsonb_typeof(cmd->'evidence_ref') <> 'object') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'base, quote, as_of, quality, source or evidence_ref'); end if;
  if qu = 'MISSING' then
    if cmd ? 'rate' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'a MISSING quote has no rate'); end if;
  else
    r := bnx.fin_dec(cmd->>'rate', 10, 18);
    if r is null or r <= 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'rate'); end if;
  end if;
  if qu = 'EVIDENCED_SETTLEMENT' and not (cmd ? 'evidence_ref' or j is not null) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'a settlement rate needs evidence_ref or journal_id'); end if;
  if j is not null then
    if not bnx.journal_counts_at(j, 9223372036854775807)
       or not exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                       where jl.journal_id = j and bnx.actor_can_post(a, ac.id)) then
      perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  end if;
  v := bnx.next_version();
  insert into bnx.fx_quote(id, base, quote, rate, as_of, source, quality, evidence_ref, journal_id, recorded_by, recorded_version)
  values (nid, cmd->>'base', cmd->>'quote', r, d, cmd->>'source', qu, cmd->'evidence_ref', j, a.member_id, v);
  perform bnx.audit(a, 'record_fx_quote', jsonb_build_object('quote_id', nid), cmd, v);
  return bnx.idem_end(a, 'record_fx_quote', cmd, jsonb_build_object('quote_id', nid, 'ledger_version', v));
end $$;

-- Owner override (tier 3: owner or admin, PWA only; R1 bnx.fx_override_event, reused unchanged); always audited with its reason
create function bnx.cmd_fx_override(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; r numeric; d date; v bigint; nid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'fx_override', cmd); if rc is not null then return rc; end if;
  begin d := (cmd->>'rate_date')::date; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'rate_date'); end;
  r := bnx.fin_dec(cmd->>'rate', 10, 18);
  if d is null or r is null or r <= 0 or not exists (select 1 from bnx.currency where code = cmd->>'base')
     or not exists (select 1 from bnx.currency where code = cmd->>'quote') or cmd->>'base' = cmd->>'quote'
     or jsonb_typeof(cmd->'reason') is distinct from 'string' or length(btrim(cmd->>'reason')) not between 1 and 500 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'base, quote, rate_date, rate or reason'); end if;
  v := bnx.next_version();
  insert into bnx.fx_override_event(id, base, quote, rate_date, rate, reason, actor, recorded_version)
  values (nid, cmd->>'base', cmd->>'quote', d, r, btrim(cmd->>'reason'), a.member_id, v);
  perform bnx.audit(a, 'fx_override', jsonb_build_object('override_id', nid, 'base', cmd->>'base', 'quote', cmd->>'quote',
                                                         'rate_date', d), cmd, v);
  return bnx.idem_end(a, 'fx_override', cmd, jsonb_build_object('override_id', nid, 'ledger_version', v));
end $$;

-- ---------- investment lots, disposals and valuations (OR-R-08) ----------
create table bnx.investment_lot(
  id uuid primary key, account_currency_id uuid not null references bnx.account_currency, instrument_id uuid not null,
  units numeric(28,8) not null check (units > 0), cost numeric(20,4) not null check (cost >= 0), acquired_on date not null,
  source_journal_id uuid references bnx.journal_entry, evidence_ref jsonb check (evidence_ref is null or jsonb_typeof(evidence_ref) = 'object'),
  recorded_by uuid not null references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now());
create index investment_lot_ac on bnx.investment_lot(account_currency_id, instrument_id);
create table bnx.investment_lot_disposal(
  id uuid primary key, lot_id uuid not null references bnx.investment_lot, units numeric(28,8) not null check (units > 0),
  proceeds numeric(20,4) not null check (proceeds >= 0), disposed_on date not null,
  proceeds_quality text not null check (proceeds_quality in ('ESTIMATED','CONFIRMED')),
  journal_id uuid references bnx.journal_entry, supersedes_disposal_id uuid unique references bnx.investment_lot_disposal,
  evidence_ref jsonb check (evidence_ref is null or jsonb_typeof(evidence_ref) = 'object'),
  recorded_by uuid not null references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  check (proceeds_quality <> 'CONFIRMED' or journal_id is not null));
create index investment_lot_disposal_lot on bnx.investment_lot_disposal(lot_id);
create trigger t_append_only before update or delete on bnx.investment_lot for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.investment_lot_disposal for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('investment_lot','F'), ('investment_lot_disposal','F');

-- disposals in effect at ledger version v: recorded at or before v and not superseded by a disposal recorded at or before v
create function bnx.lot_disposals_at(p_lot uuid, p_v bigint) returns setof bnx.investment_lot_disposal
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select d.* from bnx.investment_lot_disposal d
   where d.lot_id = p_lot and d.recorded_version <= p_v
     and not exists (select 1 from bnx.investment_lot_disposal s where s.supersedes_disposal_id = d.id and s.recorded_version <= p_v)
$$;

create function bnx.cmd_record_investment_lot(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; acid uuid; ins uuid; d date; j uuid; u numeric; c numeric; mu int; k text;
        v bigint; nid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_investment_lot', cmd); if rc is not null then return rc; end if;
  begin acid := (cmd->>'account_currency_id')::uuid; ins := (cmd->>'instrument_id')::uuid; d := (cmd->>'acquired_on')::date;
        j := (cmd->>'source_journal_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, instrument_id, acquired_on or source_journal_id'); end;
  select acc.kind, cu.minor_units into k, mu from bnx.account_currency ac join bnx.account acc on acc.id = ac.account_id
    join bnx.currency cu on cu.code = ac.currency where ac.id = acid;
  if k is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  u := bnx.fin_dec(cmd->>'units', 8, 20); c := bnx.fin_dec(cmd->>'cost', mu, 16);
  if k <> 'investment' or ins is null or d is null or u is null or u <= 0 or c is null
     or (cmd ? 'evidence_ref' and jsonb_typeof(cmd->'evidence_ref') <> 'object') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'investment account, instrument_id, units, cost, acquired_on or evidence_ref'); end if;
  if j is not null and (not bnx.journal_counts_at(j, 9223372036854775807) or bnx.journal_movement(j, acid) is null) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  v := bnx.next_version();
  insert into bnx.investment_lot(id, account_currency_id, instrument_id, units, cost, acquired_on, source_journal_id, evidence_ref,
                                 recorded_by, recorded_version)
  values (nid, acid, ins, u, c, d, j, cmd->'evidence_ref', a.member_id, v);
  perform bnx.audit(a, 'record_investment_lot', jsonb_build_object('lot_id', nid), cmd, v);
  return bnx.idem_end(a, 'record_investment_lot', cmd, jsonb_build_object('lot_id', nid, 'ledger_version', v));
end $$;

-- a disposal of units of one lot. ESTIMATED proceeds can later be superseded (once) by a disposal of the same lot, normally
-- CONFIRMED by the posted redemption journal; a CONFIRMED disposal is final.
create function bnx.cmd_record_lot_disposal(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; l bnx.investment_lot; sup bnx.investment_lot_disposal; d date; j uuid;
        u numeric; p numeric; mu int; pq text := cmd->>'proceeds_quality'; held numeric; v bigint; nid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_lot_disposal', cmd); if rc is not null then return rc; end if;
  begin select * into l from bnx.investment_lot where id = (cmd->>'lot_id')::uuid; d := (cmd->>'disposed_on')::date;
        j := (cmd->>'journal_id')::uuid; select * into sup from bnx.investment_lot_disposal where id = (cmd->>'supersedes_disposal_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'lot_id, disposed_on, journal_id or supersedes_disposal_id'); end;
  if l.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, l.account_currency_id) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  perform 1 from bnx.investment_lot where id = l.id for update;              -- serialises disposals of one lot
  select cu.minor_units into mu from bnx.account_currency ac join bnx.currency cu on cu.code = ac.currency where ac.id = l.account_currency_id;
  u := bnx.fin_dec(cmd->>'units', 8, 20); p := bnx.fin_dec(cmd->>'proceeds', mu, 16);
  if d is null or d < l.acquired_on or u is null or u <= 0 or p is null or coalesce(pq, '') not in ('ESTIMATED','CONFIRMED')
     or (cmd ? 'evidence_ref' and jsonb_typeof(cmd->'evidence_ref') <> 'object') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'units, proceeds, proceeds_quality, disposed_on or evidence_ref'); end if;
  if pq = 'CONFIRMED' and j is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'CONFIRMED proceeds need the posted journal'); end if;
  if j is not null and (not bnx.journal_counts_at(j, 9223372036854775807) or bnx.journal_movement(j, l.account_currency_id) is null) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if cmd ? 'supersedes_disposal_id' then
    if sup.id is null or sup.lot_id <> l.id or sup.proceeds_quality <> 'ESTIMATED'
       or exists (select 1 from bnx.investment_lot_disposal s where s.supersedes_disposal_id = sup.id) then
      perform bnx.fail('SUPERSEDE_STATE', 'P0409'); end if;
  end if;
  select coalesce(sum(x.units), 0) into held from bnx.lot_disposals_at(l.id, 9223372036854775807) x where x.id is distinct from sup.id;
  if held + u > l.units then perform bnx.fail('UNITS_EXCEEDED', 'P0422'); end if;
  v := bnx.next_version();
  insert into bnx.investment_lot_disposal(id, lot_id, units, proceeds, disposed_on, proceeds_quality, journal_id, supersedes_disposal_id,
                                          evidence_ref, recorded_by, recorded_version)
  values (nid, l.id, u, p, d, pq, j, sup.id, cmd->'evidence_ref', a.member_id, v);
  perform bnx.audit(a, 'record_lot_disposal', jsonb_build_object('disposal_id', nid, 'lot_id', l.id), cmd, v);
  return bnx.idem_end(a, 'record_lot_disposal', cmd, jsonb_build_object('disposal_id', nid, 'ledger_version', v));
end $$;

-- a price (NAV) for an instrument on a date (R1 bnx.valuation, reused unchanged). The instrument must be held in a lot on an
-- account-currency the actor can post on.
create function bnx.cmd_record_valuation(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; ins uuid; d date; p numeric; v bigint; nid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_valuation', cmd); if rc is not null then return rc; end if;
  begin ins := (cmd->>'instrument_id')::uuid; d := (cmd->>'valuation_date')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'instrument_id or valuation_date'); end;
  if not exists (select 1 from bnx.investment_lot l where l.instrument_id = ins and bnx.actor_can_post(a, l.account_currency_id)) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  p := bnx.fin_dec(cmd->>'price', 10, 18);
  if d is null or p is null or not exists (select 1 from bnx.currency where code = cmd->>'currency')
     or coalesce(cmd->>'source', '') !~ '^[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,63}$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'valuation_date, price, currency or source'); end if;
  v := bnx.next_version();
  insert into bnx.valuation(id, instrument_id, valuation_date, price, currency, source, recorded_version)
  values (nid, ins, d, p, cmd->>'currency', cmd->>'source', v);
  perform bnx.audit(a, 'record_valuation', jsonb_build_object('valuation_id', nid, 'instrument_id', ins), cmd, v);
  return bnx.idem_end(a, 'record_valuation', cmd, jsonb_build_object('valuation_id', nid, 'ledger_version', v));
end $$;

-- holdings of one investment account-currency at (as_of, ledger version): per instrument, units and remaining cost; realized
-- gain split by CONFIRMED and ESTIMATED proceeds; unrealized gain from the latest NAV on or before as_of (MISSING_NAV: null,
-- never zero); with a reporting currency, the same figures translated and the FX effect shown separately (cost at the rate of
-- each lot's acquisition date, proceeds at the disposal date's rate, market value at the as_of rate).
create function bnx.q_investment_position(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); acid uuid; as_of date; v bigint; vnow bigint; rc text; acr record; mu int; rmu int;
        ins uuid; l record; d record; val record; fx jsonb; fxn jsonb; rnow numeric; rnow_q text; racq numeric; rdisp numeric;
        out jsonb := '[]'; tw text[] := '{}'; w text[];
        u_acq numeric; c_acq numeric; u_disp numeric; alloc numeric; c_alloc numeric; rz_c numeric; rz_e numeric; pr_c numeric; pr_e numeric;
        lot_rem numeric; mv numeric; px numeric; nav text; rc_ok boolean; cost_rc numeric; rz_rc_c numeric; rz_rc_e numeric; rz_fx numeric;
        t_cost numeric := 0; t_mv numeric := 0; t_rzc numeric := 0; t_rze numeric := 0; t_mv_null boolean := false;
        t_cost_rc numeric := 0; t_mv_rc numeric := 0; t_rz_rc_c numeric := 0; t_rz_rc_e numeric := 0; t_fx_u numeric := 0; t_fx_r numeric := 0;
        t_rc_null boolean := false; rep jsonb;
begin
  perform bnx.require(a, 0);
  begin
    acid := (q->>'account_currency_id')::uuid; as_of := coalesce((q->>'as_of')::date, current_date);
    v := (q->>'ledger_version')::bigint; rc := q->>'reporting_currency';
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, as_of, ledger_version or reporting_currency');
  end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if rc is not null then
    select minor_units into rmu from bnx.currency where code = rc;
    if rmu is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'reporting_currency'); end if;
  end if;
  select ac.id, ac.currency, acc.kind, cu.minor_units into acr from bnx.account_currency ac join bnx.account acc on acc.id = ac.account_id
    join bnx.currency cu on cu.code = ac.currency where ac.id = acid;
  if acr.id is null or acr.kind <> 'investment' or not exists (select 1 from bnx.actor_visible_acs(a) x where x = acid) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;                            -- no existence leak
  perform bnx.pol_require_module_for_ac(acid);
  mu := acr.minor_units;
  if rc is not null then
    fx := bnx.fx_rate_at(acr.currency, rc, as_of, v); rnow := (fx->>'rate')::numeric; rnow_q := fx->>'quality';
    if rnow_q = 'STALE' then tw := array_append(tw, 'FX_STALE'::text); end if;
  end if;
  for ins in select distinct x.instrument_id from bnx.investment_lot x
              where x.account_currency_id = acid and x.recorded_version <= v and x.acquired_on <= as_of order by 1 loop
    u_acq := 0; c_acq := 0; u_disp := 0; c_alloc := 0; rz_c := 0; rz_e := 0; pr_c := 0; pr_e := 0; w := '{}';
    rc_ok := rc is not null and rnow is not null; cost_rc := 0; rz_rc_c := 0; rz_rc_e := 0; rz_fx := 0;
    for l in select * from bnx.investment_lot x where x.account_currency_id = acid and x.instrument_id = ins and x.recorded_version <= v
                and x.acquired_on <= as_of order by x.acquired_on, x.id loop
      u_acq := u_acq + l.units; c_acq := c_acq + l.cost; lot_rem := l.cost;
      if rc_ok then
        racq := (bnx.fx_rate_at(acr.currency, rc, l.acquired_on, v)->>'rate')::numeric;
        if racq is null then rc_ok := false; end if;
      end if;
      for d in select * from bnx.lot_disposals_at(l.id, v) x where x.disposed_on <= as_of order by x.disposed_on, x.id loop
        alloc := bnx.r28_div(l.cost * d.units, l.units);                     -- cost of the disposed units, pro rata within the lot
        u_disp := u_disp + d.units; c_alloc := c_alloc + alloc; lot_rem := lot_rem - alloc;
        if d.proceeds_quality = 'CONFIRMED' then rz_c := rz_c + d.proceeds - alloc; pr_c := pr_c + d.proceeds;
        else rz_e := rz_e + d.proceeds - alloc; pr_e := pr_e + d.proceeds; end if;
        if rc_ok then
          rdisp := (bnx.fx_rate_at(acr.currency, rc, d.disposed_on, v)->>'rate')::numeric;
          if rdisp is null then rc_ok := false;
          else
            if d.proceeds_quality = 'CONFIRMED' then rz_rc_c := rz_rc_c + d.proceeds * rdisp - alloc * racq;
            else rz_rc_e := rz_rc_e + d.proceeds * rdisp - alloc * racq; end if;
            rz_fx := rz_fx + alloc * (rdisp - racq);
          end if;
        end if;
      end loop;
      if rc_ok then cost_rc := cost_rc + lot_rem * racq; end if;
    end loop;
    if pr_e > 0 or exists (select 1 from bnx.investment_lot x join bnx.lot_disposals_at(x.id, v) dd on true
                            where x.account_currency_id = acid and x.instrument_id = ins and dd.proceeds_quality = 'ESTIMATED'
                              and dd.disposed_on <= as_of and x.recorded_version <= v) then
      w := array_append(w, 'ESTIMATED_PROCEEDS'::text); end if;
    select x.* into val from bnx.valuation x where x.instrument_id = ins and x.valuation_date <= as_of and x.recorded_version <= v
     order by x.valuation_date desc, x.recorded_version desc, x.id desc limit 1;
    mv := null; nav := 'OK'; px := null;
    if u_acq - u_disp = 0 then nav := 'NO_UNITS_HELD'; mv := 0;
    elsif val.id is null then nav := 'MISSING_NAV'; w := array_append(w, 'MISSING_NAV'::text);
    else
      px := val.price;
      if val.currency <> acr.currency then
        fxn := bnx.fx_rate_at(val.currency, acr.currency, val.valuation_date, v);
        px := px * (fxn->>'rate')::numeric;
        if px is null then nav := 'NAV_FX_MISSING'; w := array_append(w, 'NAV_FX_MISSING'::text);
        elsif fxn->>'quality' = 'STALE' then w := array_append(w, 'NAV_FX_STALE'::text); end if;
      end if;
      if px is not null then
        mv := (u_acq - u_disp) * px;
        if as_of - val.valuation_date > 31 then nav := 'STALE_NAV'; w := array_append(w, 'STALE_NAV'::text); end if;
      end if;
    end if;
    t_cost := t_cost + (c_acq - c_alloc); t_rzc := t_rzc + rz_c; t_rze := t_rze + rz_e;
    if mv is null then t_mv_null := true; else t_mv := t_mv + mv; end if;
    rep := null;
    if rc is not null then
      if not rc_ok then w := array_append(w, 'FX_MISSING'::text); t_rc_null := true; end if;
      if rc_ok and mv is null then t_rc_null := true; end if;
      rep := jsonb_build_object('currency', rc,
        'cost_remaining', case when rc_ok then bnx.fin_money(cost_rc, rmu) end,
        'market_value', case when rc_ok and mv is not null then bnx.fin_money(mv * rnow, rmu) end,
        'unrealized', case when rc_ok and mv is not null then bnx.fin_money(mv * rnow - cost_rc, rmu) end,
        'unrealized_fx_effect', case when rc_ok then bnx.fin_money((c_acq - c_alloc) * rnow - cost_rc, rmu) end,
        'realized_confirmed', case when rc_ok then bnx.fin_money(rz_rc_c, rmu) end,
        'realized_estimated', case when rc_ok then bnx.fin_money(rz_rc_e, rmu) end,
        'realized_fx_effect', case when rc_ok then bnx.fin_money(rz_fx, rmu) end);
      if rc_ok then
        t_cost_rc := t_cost_rc + cost_rc; t_rz_rc_c := t_rz_rc_c + rz_rc_c; t_rz_rc_e := t_rz_rc_e + rz_rc_e; t_fx_r := t_fx_r + rz_fx;
        t_fx_u := t_fx_u + (c_acq - c_alloc) * rnow - cost_rc;
        if mv is not null then t_mv_rc := t_mv_rc + mv * rnow; end if;
      end if;
    end if;
    tw := tw || w;
    out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'instrument_id', ins, 'units_held', trim_scale(u_acq - u_disp)::text, 'units_disposed', trim_scale(u_disp)::text,
      'cost_remaining', bnx.fin_money(c_acq - c_alloc, mu),
      'realized', jsonb_build_object('confirmed', bnx.fin_money(rz_c, mu), 'estimated', bnx.fin_money(rz_e, mu),
                                     'proceeds_confirmed', bnx.fin_money(pr_c, mu), 'proceeds_estimated', bnx.fin_money(pr_e, mu)),
      'valuation', jsonb_strip_nulls(jsonb_build_object('status', nav, 'price', trim_scale(val.price)::text, 'price_currency', val.currency,
                                                        'valuation_date', val.valuation_date, 'source', val.source, 'valuation_id', val.id)),
      'warnings', to_jsonb(w))) || jsonb_build_object(
      'market_value', bnx.fin_money(mv, mu), 'unrealized', case when mv is not null then bnx.fin_money(mv - (c_acq - c_alloc), mu) end,
      'reporting', rep));
  end loop;
  return jsonb_build_object('account_currency_id', acid, 'currency', acr.currency, 'as_of', as_of, 'ledger_version', v,
    'instruments', out,
    'totals', jsonb_build_object('cost_remaining', bnx.fin_money(t_cost, mu), 'realized_confirmed', bnx.fin_money(t_rzc, mu),
                                 'realized_estimated', bnx.fin_money(t_rze, mu),
                                 'market_value', case when not t_mv_null then bnx.fin_money(t_mv, mu) end,
                                 'unrealized', case when not t_mv_null then bnx.fin_money(t_mv - t_cost, mu) end),
    'reporting', case when rc is not null then jsonb_build_object('currency', rc, 'rate_as_of', fx->>'rate', 'rate_quality', rnow_q,
                                 'cost_remaining', case when not t_rc_null then bnx.fin_money(t_cost_rc, rmu) end,
                                 'market_value', case when not t_rc_null and not t_mv_null then bnx.fin_money(t_mv_rc, rmu) end,
                                 'unrealized', case when not t_rc_null and not t_mv_null then bnx.fin_money(t_mv_rc - t_cost_rc, rmu) end,
                                 'unrealized_fx_effect', case when not t_rc_null then bnx.fin_money(t_fx_u, rmu) end,
                                 'realized_confirmed', case when not t_rc_null then bnx.fin_money(t_rz_rc_c, rmu) end,
                                 'realized_estimated', case when not t_rc_null then bnx.fin_money(t_rz_rc_e, rmu) end,
                                 'realized_fx_effect', case when not t_rc_null then bnx.fin_money(t_fx_r, rmu) end) end,
    'warnings', coalesce((select to_jsonb(array_agg(distinct x order by x)) from unnest(tw) x), '[]'),
    'rounding', 'HALF_EVEN at output; exact numeric before',
    'fx_policy', case when rc is not null then 'bnx.fx_rate_at: OVERRIDE > EVIDENCED_SETTLEMENT > REFERENCE (STALE after 7 days) > MISSING' end);
end $$;

-- ---------- card annual-fee policy and events (OR-R-07; R19 calculated, R20 issuer-confirmed, posted: never merged) ----------
create table bnx.card_fee_policy(
  card_account_id uuid not null references bnx.account, seq int not null,
  effective_from date not null, effective_to date, annual_fee numeric(20,4) not null check (annual_fee >= 0),
  currency char(3) not null references bnx.currency,
  period_rule text not null check (period_rule in ('CARD_YEAR','CALENDAR_YEAR')), anniversary date,
  criteria jsonb not null check (jsonb_typeof(criteria) = 'object'), issuer_confirmed boolean not null,
  evidence_ref jsonb not null check (jsonb_typeof(evidence_ref) = 'object'),
  recorded_by uuid not null references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  primary key (card_account_id, seq), check (effective_to is null or effective_to >= effective_from),
  check ((period_rule = 'CARD_YEAR') = (anniversary is not null)));
create table bnx.card_fee_event(
  card_account_id uuid not null references bnx.account, seq int not null,
  kind text not null check (kind in ('CALCULATED_QUALIFICATION','ISSUER_CONFIRMED_WAIVER','FEE_POSTED','FEE_REFUNDED')),
  period_start date not null, period_end date not null, policy_seq int not null,
  amount numeric(20,4) check (amount is null or amount > 0), currency char(3) references bnx.currency,
  journal_id uuid references bnx.journal_entry, evidence_ref jsonb check (evidence_ref is null or jsonb_typeof(evidence_ref) = 'object'),
  detail jsonb, recorded_by uuid not null references bnx.member, recorded_version bigint not null,
  recorded_at timestamptz not null default now(), primary key (card_account_id, seq),
  foreign key (card_account_id, policy_seq) references bnx.card_fee_policy(card_account_id, seq),
  check (period_end >= period_start),
  check ((kind in ('FEE_POSTED','FEE_REFUNDED')) = (journal_id is not null)),
  check (kind not in ('FEE_POSTED','FEE_REFUNDED') or (amount is not null and currency is not null)),
  check (kind <> 'ISSUER_CONFIRMED_WAIVER' or evidence_ref is not null),
  check ((kind = 'CALCULATED_QUALIFICATION') = (detail is not null)));
create unique index card_fee_event_journal on bnx.card_fee_event(journal_id) where journal_id is not null;   -- one journal, one event
create trigger t_append_only before update or delete on bnx.card_fee_policy for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.card_fee_event for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('card_fee_policy','F'), ('card_fee_event','F');

-- the anniversary in year y (29 February falls on 28 February in other years)
create function bnx.card_anniversary(p_anniv date, y int) returns date
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select make_date(y, extract(month from p_anniv)::int,
                   least(extract(day from p_anniv)::int,
                         extract(day from (make_date(y, extract(month from p_anniv)::int, 1) + interval '1 month - 1 day'))::int)) $$;
-- the fee period that contains p_d
create function bnx.card_period(p_rule text, p_anniv date, p_d date, out p_start date, out p_end date)
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare y int := extract(year from p_d)::int;
begin
  if p_rule = 'CALENDAR_YEAR' then p_start := make_date(y, 1, 1); p_end := make_date(y, 12, 31); return; end if;
  p_start := bnx.card_anniversary(p_anniv, y);
  if p_start > p_d then p_start := bnx.card_anniversary(p_anniv, y - 1); end if;
  p_end := bnx.card_anniversary(p_anniv, extract(year from p_start)::int + 1) - 1;
end $$;
-- the policy in force on a date at ledger version v: the latest recorded policy whose effective range contains the date
create function bnx.card_policy_at(p_card uuid, p_d date, p_v bigint) returns bnx.card_fee_policy
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select p.* from bnx.card_fee_policy p
   where p.card_account_id = p_card and p.recorded_version <= p_v and p.effective_from <= p_d
     and (p.effective_to is null or p.effective_to >= p_d)
   order by p.seq desc limit 1
$$;

-- progress of one fee period. Spend = purchases (card_spend, consumption_expense) minus refunds on the card's account-currency
-- in the policy currency, by effective posting date within the period up to as_of, from journals visible at v and not
-- corrected at or before v (a replacement counts as the type it replaces); journals named by a fee event, other economic types
-- (repayments, transfers, fees, interest, FX, clearing, opening) and the policy's exclusions do not count. A refund therefore
-- regresses progress. The calculated status, the issuer's confirmation and the posted fee are reported separately.
create function bnx.card_fee_progress(p_card uuid, p_as_of date, p_v bigint, p_period_start date default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare pol bnx.card_fee_policy; ps date; pe date; acid uuid; lid uuid; mu int; excl text[]; upto date;
        purch numeric; refd numeric; cnt int; nref int; spend numeric; qs numeric; qc int; comb text; met_s boolean; met_c boolean;
        calc text; waiver boolean; posted numeric; refunded numeric; fee_st text; lastcalc jsonb; warn text[] := '{}';
begin
  pol := bnx.card_policy_at(p_card, coalesce(p_period_start, p_as_of), p_v);
  if pol.seq is null then
    return jsonb_build_object('status', 'NO_POLICY', 'card_account_id', p_card, 'as_of', p_as_of, 'ledger_version', p_v);
  end if;
  select x.p_start, x.p_end into ps, pe from bnx.card_period(pol.period_rule, pol.anniversary, coalesce(p_period_start, p_as_of)) x;
  if p_period_start is not null and ps <> p_period_start then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'period_start'); end if;
  select ac.id, ac.ledger_account_id, cu.minor_units into acid, lid, mu from bnx.account_currency ac
    join bnx.currency cu on cu.code = ac.currency where ac.account_id = p_card and ac.currency = pol.currency;
  excl := array(select jsonb_array_elements_text(coalesce(pol.criteria->'excluded_economic_types', '[]')));
  upto := least(pe, p_as_of);
  with mv as (
    select j.journal_id, bnx.effective_economic_type(j.journal_id) et, bnx.effective_posting_date(j.journal_id, p_v) pd,
           (select sum(jl.amount) from bnx.journal_line jl where jl.journal_id = j.journal_id and jl.ledger_account_id = lid) amt
      from (select distinct jl.journal_id from bnx.journal_line jl where jl.ledger_account_id = lid) j
     where bnx.journal_counts_at(j.journal_id, p_v)
       and not exists (select 1 from bnx.card_fee_event e where e.journal_id = j.journal_id and e.recorded_version <= p_v))
  select coalesce(sum(-amt) filter (where et in ('card_spend','consumption_expense')), 0),
         count(*) filter (where et in ('card_spend','consumption_expense') and amt < 0),
         coalesce(sum(amt) filter (where et = 'refund'), 0), count(*) filter (where et = 'refund' and amt > 0)
    into purch, cnt, refd, nref
    from mv where pd between ps and upto and et in ('card_spend','consumption_expense','refund') and et <> all(excl);
  spend := purch - refd;
  qs := bnx.r28_dec(pol.criteria->>'qualifying_spend'); qc := (pol.criteria->>'qualifying_count')::int;
  comb := coalesce(pol.criteria->>'combine', 'ALL');
  met_s := case when qs is not null then spend >= qs end; met_c := case when qc is not null then cnt >= qc end;
  calc := case when qs is null and qc is null then 'NO_CRITERIA'
               when (comb = 'ALL' and coalesce(met_s, true) and coalesce(met_c, true))
                 or (comb = 'ANY' and (coalesce(met_s, false) or coalesce(met_c, false))) then 'QUALIFIED'
               when p_as_of >= pe then 'NOT_QUALIFIED' else 'NOT_YET_QUALIFIED' end;
  waiver := exists (select 1 from bnx.card_fee_event e where e.card_account_id = p_card and e.kind = 'ISSUER_CONFIRMED_WAIVER'
                     and e.period_start = ps and e.recorded_version <= p_v);
  select coalesce(sum(e.amount) filter (where e.kind = 'FEE_POSTED'), 0), coalesce(sum(e.amount) filter (where e.kind = 'FEE_REFUNDED'), 0)
    into posted, refunded from bnx.card_fee_event e
   where e.card_account_id = p_card and e.period_start = ps and e.recorded_version <= p_v and e.kind in ('FEE_POSTED','FEE_REFUNDED')
     and bnx.journal_counts_at(e.journal_id, p_v);
  fee_st := case when posted = 0 and refunded = 0 then 'NOT_POSTED' when posted <= refunded then 'REFUNDED'
                 when refunded > 0 then 'PARTIALLY_REFUNDED' else 'POSTED' end;
  select e.detail->'calculated' || jsonb_build_object('event_seq', e.seq, 'recorded_version', e.recorded_version) into lastcalc
    from bnx.card_fee_event e where e.card_account_id = p_card and e.kind = 'CALCULATED_QUALIFICATION' and e.period_start = ps
     and e.recorded_version <= p_v order by e.seq desc limit 1;
  if not pol.issuer_confirmed then warn := array_append(warn, 'POLICY_NOT_ISSUER_CONFIRMED'::text); end if;
  if calc = 'QUALIFIED' and not waiver then warn := array_append(warn, 'QUALIFICATION_NOT_CONFIRMED_BY_ISSUER'::text); end if;
  if (calc = 'QUALIFIED' or waiver) and posted > refunded then warn := array_append(warn, 'FEE_POSTED_DESPITE_QUALIFICATION_OR_WAIVER'::text); end if;
  return jsonb_build_object('status', 'OK', 'card_account_id', p_card, 'account_currency_id', acid, 'as_of', p_as_of, 'ledger_version', p_v,
    'period', jsonb_build_object('rule', pol.period_rule, 'start', ps, 'end', pe, 'counted_through', upto),
    'policy', jsonb_strip_nulls(jsonb_build_object('seq', pol.seq, 'effective_from', pol.effective_from, 'effective_to', pol.effective_to,
              'annual_fee', bnx.fin_money(pol.annual_fee, mu), 'currency', pol.currency, 'criteria', pol.criteria,
              'issuer_confirmed', pol.issuer_confirmed)),
    'progress', jsonb_strip_nulls(jsonb_build_object('spend', bnx.fin_money(spend, mu), 'purchases', bnx.fin_money(purch, mu),
              'refunds', bnx.fin_money(refd, mu), 'purchase_count', cnt, 'refund_count', nref,
              'qualifying_spend', bnx.fin_money(qs, mu), 'qualifying_count', qc, 'combine', comb,
              'spend_met', met_s, 'count_met', met_c,
              'spend_remaining', case when qs is not null then bnx.fin_money(greatest(qs - spend, 0), mu) end,
              'count_remaining', case when qc is not null then greatest(qc - cnt, 0) end)),
    'calculated', jsonb_build_object('status', calc, 'basis', 'card ledger lines at ledger_version; not an issuer decision'),
    'issuer', jsonb_build_object('waiver_confirmed', waiver),
    'fee', jsonb_build_object('status', fee_st, 'posted', bnx.fin_money(posted, mu), 'refunded', bnx.fin_money(refunded, mu),
                              'net', bnx.fin_money(posted - refunded, mu)),
    'last_recorded_calculation', lastcalc, 'warnings', to_jsonb(warn));
end $$;

-- the card account for a fee command: a credit card on which the actor can post in every currency
create function bnx.card_require_post(a bnx.actor, p_card uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare k text;
begin
  select kind into k from bnx.account where id = p_card;
  if k is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if k <> 'credit_card' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'not a credit card account'); end if;
  if exists (select 1 from bnx.account_currency ac where ac.account_id = p_card and not bnx.actor_can_post(a, ac.id))
     or not exists (select 1 from bnx.account_currency ac where ac.account_id = p_card) then
    perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
end $$;

create function bnx.q_card_fee_progress(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); card uuid; as_of date; v bigint; vnow bigint; ps date; r jsonb;
begin
  perform bnx.require(a, 0);
  begin
    card := (q->>'card_account_id')::uuid; as_of := coalesce((q->>'as_of')::date, current_date);
    v := (q->>'ledger_version')::bigint; ps := (q->>'period_start')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'card_account_id, as_of, ledger_version or period_start');
  end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if not exists (select 1 from bnx.account acc join bnx.account_currency ac on ac.account_id = acc.id
                  join bnx.actor_visible_acs(a) x on x = ac.id where acc.id = card and acc.kind = 'credit_card') then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;                            -- no existence leak
  perform bnx.pol_require_module_for_account(card);
  r := bnx.card_fee_progress(card, as_of, v, ps);
  if r->>'status' = 'OK' and not exists (select 1 from bnx.actor_visible_acs(a) x where x = (r->>'account_currency_id')::uuid) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  return r;
end $$;

-- a new policy version (append-only; the latest recorded version in force on a date governs). Criteria keys are closed.
create function bnx.cmd_set_card_fee_policy(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; card uuid; ef date; et date; an date; fee numeric; mu int; cr jsonb;
        s int; v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'set_card_fee_policy', cmd); if rc is not null then return rc; end if;
  begin card := (cmd->>'card_account_id')::uuid; ef := (cmd->>'effective_from')::date; et := (cmd->>'effective_to')::date;
        an := (cmd->>'anniversary')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'card_account_id, effective_from, effective_to or anniversary'); end;
  perform bnx.card_require_post(a, card);
  select cu.minor_units into mu from bnx.account_currency ac join bnx.currency cu on cu.code = ac.currency
   where ac.account_id = card and ac.currency = cmd->>'currency';
  if mu is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'the card has no account in that currency'); end if;
  fee := bnx.fin_dec(cmd->>'annual_fee', mu, 16); cr := cmd->'criteria';
  if ef is null or (et is not null and et < ef) or fee is null or coalesce(cmd->>'period_rule', '') not in ('CARD_YEAR','CALENDAR_YEAR')
     or ((cmd->>'period_rule' = 'CARD_YEAR') <> (an is not null)) or jsonb_typeof(cmd->'issuer_confirmed') is distinct from 'boolean'
     or jsonb_typeof(cmd->'evidence_ref') is distinct from 'object' or jsonb_typeof(cr) is distinct from 'object' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'policy fields'); end if;
  if exists (select 1 from jsonb_object_keys(cr) k where k not in ('qualifying_spend','qualifying_count','excluded_economic_types','combine'))
     or (cr ? 'qualifying_spend' and bnx.fin_dec(cr->>'qualifying_spend', mu, 16) is null)
     or (cr ? 'qualifying_count' and coalesce(cr->>'qualifying_count', '') !~ '^[1-9][0-9]{0,4}$')
     or (cr ? 'combine' and coalesce(cr->>'combine', '') not in ('ALL','ANY'))
     or (cr ? 'excluded_economic_types' and (jsonb_typeof(cr->'excluded_economic_types') <> 'array'
         or exists (select 1 from jsonb_array_elements(cr->'excluded_economic_types') x
                     where jsonb_typeof(x) <> 'string' or not (x #>> '{}') in ('card_spend','consumption_expense','refund')))) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'criteria'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.card_fee:' || card));
  s := coalesce((select max(seq) from bnx.card_fee_policy where card_account_id = card), 0) + 1;
  v := bnx.next_version();
  insert into bnx.card_fee_policy(card_account_id, seq, effective_from, effective_to, annual_fee, currency, period_rule, anniversary,
                                  criteria, issuer_confirmed, evidence_ref, recorded_by, recorded_version)
  values (card, s, ef, et, fee, cmd->>'currency', cmd->>'period_rule', an, cr, (cmd->>'issuer_confirmed')::boolean, cmd->'evidence_ref',
          a.member_id, v);
  perform bnx.audit(a, 'set_card_fee_policy', jsonb_build_object('card_account_id', card, 'seq', s), cmd, v);
  return bnx.idem_end(a, 'set_card_fee_policy', cmd, jsonb_build_object('card_account_id', card, 'seq', s, 'ledger_version', v));
end $$;

-- a fee event for one period (identified by its start under the policy in force on that date):
--   CALCULATED_QUALIFICATION stores the server's own calculation at the current ledger version (the client supplies nothing);
--   ISSUER_CONFIRMED_WAIVER needs the issuer's evidence; FEE_POSTED / FEE_REFUNDED link a posted fee / refund journal on the
--   card, whose movement on the card is the amount. Each kind stays separate (R19 != R20 != posting).
create function bnx.cmd_record_card_fee_event(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; card uuid; ps date; asof date; j uuid; k text := cmd->>'kind';
        pol bnx.card_fee_policy; pe date; acid uuid; mv numeric; amt numeric; det jsonb; s int; v bigint; vnow bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_card_fee_event', cmd); if rc is not null then return rc; end if;
  begin card := (cmd->>'card_account_id')::uuid; ps := (cmd->>'period_start')::date; j := (cmd->>'journal_id')::uuid;
        asof := coalesce((cmd->>'as_of')::date, current_date);
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'card_account_id, period_start, as_of or journal_id'); end;
  perform bnx.card_require_post(a, card);
  if ps is null or coalesce(k, '') not in ('CALCULATED_QUALIFICATION','ISSUER_CONFIRMED_WAIVER','FEE_POSTED','FEE_REFUNDED')
     or (cmd ? 'evidence_ref' and jsonb_typeof(cmd->'evidence_ref') <> 'object') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'kind, period_start or evidence_ref'); end if;
  select version into vnow from bnx.ledger_state;
  pol := bnx.card_policy_at(card, ps, vnow);
  if pol.seq is null then perform bnx.fail('NO_POLICY', 'P0422'); end if;
  select x.p_end into pe from bnx.card_period(pol.period_rule, pol.anniversary, ps) x;
  if (select x.p_start from bnx.card_period(pol.period_rule, pol.anniversary, ps) x) <> ps then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'period_start'); end if;
  select ac.id into acid from bnx.account_currency ac where ac.account_id = card and ac.currency = pol.currency;
  if k = 'ISSUER_CONFIRMED_WAIVER' and not cmd ? 'evidence_ref' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'an issuer waiver needs evidence_ref'); end if;
  if k in ('FEE_POSTED','FEE_REFUNDED') then
    if j is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'journal_id'); end if;
    mv := bnx.journal_movement(j, acid);
    if not bnx.journal_counts_at(j, vnow) or mv is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
    if (k = 'FEE_POSTED' and (bnx.effective_economic_type(j) <> 'fee' or mv >= 0))
       or (k = 'FEE_REFUNDED' and (bnx.effective_economic_type(j) <> 'refund' or mv <= 0)) then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'FEE_POSTED needs a fee journal charging the card; FEE_REFUNDED a refund journal crediting it'); end if;
    if exists (select 1 from bnx.card_fee_event e where e.journal_id = j) then perform bnx.fail('ALREADY_LINKED', 'P0409'); end if;
    amt := abs(mv);
  elsif j is not null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'journal_id only for FEE_POSTED and FEE_REFUNDED');
  end if;
  if k = 'CALCULATED_QUALIFICATION' then
    if asof < ps then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of before the period'); end if;
    det := bnx.card_fee_progress(card, least(asof, pe), vnow, ps);
    det := jsonb_build_object('calculated', jsonb_build_object('status', det->'calculated'->>'status', 'as_of', det->'as_of',
                                                               'ledger_version', vnow, 'progress', det->'progress'));
  end if;
  perform pg_advisory_xact_lock(hashtext('bnx.card_fee:' || card));
  s := coalesce((select max(seq) from bnx.card_fee_event where card_account_id = card), 0) + 1;
  v := bnx.next_version();
  insert into bnx.card_fee_event(card_account_id, seq, kind, period_start, period_end, policy_seq, amount, currency, journal_id, evidence_ref,
                                 detail, recorded_by, recorded_version)
  values (card, s, k, ps, pe, pol.seq, amt, case when amt is not null then pol.currency end, j, cmd->'evidence_ref', det, a.member_id, v);
  perform bnx.audit(a, 'record_card_fee_event', jsonb_build_object('card_account_id', card, 'seq', s, 'kind', k), cmd, v);
  return bnx.idem_end(a, 'record_card_fee_event', cmd, jsonb_build_object('card_account_id', card, 'seq', s, 'kind', k, 'ledger_version', v,
                                                                         'calculated_status', det->'calculated'->>'status'));
end $$;

-- module-flag enforcement on the account-scoped 9012b tables (F-C2-07; card_fee_event is a UA §4.4.1 table)
insert into bnx.flag_enforcement_point values
 ('investment_lot','account_currency_id','INSERT','9012','bnx'), ('investment_lot_disposal','lot_id','INSERT','9012','bnx'),
 ('card_fee_policy','card_fee','INSERT','9012','bnx'), ('card_fee_event','card_fee','INSERT','9012','bnx');
create trigger t_scope_flag_investment_lot before insert on bnx.investment_lot for each row execute function bnx.trg_scope_flag('account_currency_id');
create trigger t_scope_flag_investment_lot_disposal before insert on bnx.investment_lot_disposal for each row execute function bnx.trg_scope_flag('lot_id');
create trigger t_scope_flag_card_fee_policy before insert on bnx.card_fee_policy for each row execute function bnx.trg_scope_flag('card_fee');
create trigger t_scope_flag_card_fee_event before insert on bnx.card_fee_event for each row execute function bnx.trg_scope_flag('card_fee');

insert into bnx.function_scope values
 ('q_fx_rate', 'finance.read', false, false, false, 'fin.fx.rate'),
 ('q_investment_position', 'finance.read', false, false, true, 'fin.investments.holdings'),
 ('q_card_fee_progress', 'finance.read', false, false, true, 'fin.cards.fee_eligibility');

-- ---------- 9012c-1: balance observations, statement periods, reconciliation exception structure (UA V1.2 §5.6) ----------
-- OWNER_DECISION 2026-11-11 (option 2): build the parts of 9012c that do not depend on the Draft-04 rule texts. The RC-01...14
-- rules, the D5 classification policy, the D7 resolution actions and the BAL01-12 cases are not implemented here: no exception
-- is computed yet, and rule_code / resolution_action are constrained by format only.

-- observations never post and never update: each is an event; the current one per (account-currency, observed_at, source)
-- is the latest by event_seq, and a revision also supersedes the event it names. Different sources at the same instant are
-- all kept (conflicts are visible, never resolved here).
create table bnx.balance_observation_event(
  account_currency_id uuid not null references bnx.account_currency, event_seq int not null,
  checkpoint_id uuid references bnx.balance_checkpoint,
  source text not null check (source in ('MEMBER','STATEMENT','EXPORT','EMAIL_NOTICE')),
  observed_at timestamptz not null, tz text not null, amount numeric(20,4) not null, currency char(3) not null references bnx.currency,
  sign_convention text not null check (sign_convention in ('asset_positive','owed_positive')),
  evidence_ref jsonb check (evidence_ref is null or jsonb_typeof(evidence_ref) = 'object'), revision_of int,
  actor uuid not null references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  primary key (account_currency_id, event_seq),
  foreign key (account_currency_id, revision_of) references bnx.balance_observation_event(account_currency_id, event_seq),
  foreign key (account_currency_id, currency) references bnx.account_currency(id, currency),
  check ((source = 'MEMBER') = (checkpoint_id is not null)),
  check (source = 'MEMBER' or evidence_ref is not null),
  check (revision_of is null or revision_of < event_seq));
create trigger t_append_only before update or delete on bnx.balance_observation_event for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('balance_observation_event','F');

-- the observations in effect at ledger version v
create function bnx.observations_at(p_ac uuid, p_v bigint) returns setof bnx.balance_observation_event
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select o.* from bnx.balance_observation_event o
   where o.account_currency_id = p_ac and o.recorded_version <= p_v
     and not exists (select 1 from bnx.balance_observation_event n
                      where n.account_currency_id = o.account_currency_id and n.recorded_version <= p_v and n.event_seq > o.event_seq
                        and ((n.observed_at = o.observed_at and n.source = o.source) or n.revision_of = o.event_seq))
$$;

-- RC-POST (tier 2; post rights on the account-currency): record one observation; a MEMBER observation also writes the R1
-- balance_checkpoint row (kind member_spot_check, as_of = the local date in tz), which is never updated
create function bnx.cmd_record_observation(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; acid uuid; src text := cmd->>'source'; at_ timestamptz; tz_ text; amt numeric;
        acr record; sc text; rev int; cp uuid; s int; v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'record_observation', cmd); if rc is not null then return rc; end if;
  begin acid := (cmd->>'account_currency_id')::uuid; at_ := (cmd->>'observed_at')::timestamptz; rev := (cmd->>'revision_of')::int;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, observed_at or revision_of'); end;
  select ac.id, ac.currency, acc.kind, acc.timezone, cu.minor_units into acr from bnx.account_currency ac
    join bnx.account acc on acc.id = ac.account_id join bnx.currency cu on cu.code = ac.currency where ac.id = acid;
  if acr.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  tz_ := coalesce(cmd->>'tz', acr.timezone);
  begin perform now() at time zone tz_; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'tz'); end;
  amt := bnx.r28_dec(cmd->>'amount');
  sc := coalesce(cmd->>'sign_convention', case when acr.kind in ('credit_card','loan_payable') then 'owed_positive' else 'asset_positive' end);
  if at_ is null or coalesce(src, '') not in ('MEMBER','STATEMENT','EXPORT','EMAIL_NOTICE') or amt is null
     or bnx.r28_scale(cmd->>'amount') > acr.minor_units or abs(amt) >= 1e16 or sc not in ('asset_positive','owed_positive')
     or (cmd ? 'currency' and cmd->>'currency' is distinct from acr.currency)
     or (cmd ? 'evidence_ref' and jsonb_typeof(cmd->'evidence_ref') <> 'object')
     or (src <> 'MEMBER' and not cmd ? 'evidence_ref') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'source, observed_at, amount, currency, sign_convention or evidence_ref'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.observation:' || acid));
  if rev is not null and not exists (select 1 from bnx.balance_observation_event o where o.account_currency_id = acid
                                       and o.event_seq = rev and o.source = src) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'revision_of names no observation of this account-currency and source'); end if;
  if src = 'MEMBER' then
    cp := gen_random_uuid();
    insert into bnx.balance_checkpoint(id, account_currency_id, as_of, amount, kind, evidence, recorded_by)
    values (cp, acid, (at_ at time zone tz_)::date, amt, 'member_spot_check', cmd->'evidence_ref', a.member_id);
  end if;
  s := coalesce((select max(event_seq) from bnx.balance_observation_event where account_currency_id = acid), 0) + 1;
  v := bnx.next_version();
  insert into bnx.balance_observation_event(account_currency_id, event_seq, checkpoint_id, source, observed_at, tz, amount, currency,
                                            sign_convention, evidence_ref, revision_of, actor, recorded_version)
  values (acid, s, cp, src, at_, tz_, amt, acr.currency, sc, cmd->'evidence_ref', rev, a.member_id, v);
  perform bnx.audit(a, 'record_observation', jsonb_build_object('account_currency_id', acid, 'event_seq', s), cmd, v);
  return bnx.idem_end(a, 'record_observation', cmd, jsonb_build_object('account_currency_id', acid, 'event_seq', s, 'checkpoint_id', cp,
                                                                      'ledger_version', v));
end $$;

-- observations of one account-currency at a ledger version: the ones in effect, and (on request) the superseded ones; the
-- instants where sources disagree are listed as conflicts. Nothing is compared with the ledger here (that is RC-01...14).
create function bnx.q_balance_observations(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); acid uuid; v bigint; vnow bigint; mu int; allv boolean;
begin
  perform bnx.require(a, 0);
  begin acid := (q->>'account_currency_id')::uuid; v := (q->>'ledger_version')::bigint; allv := coalesce((q->>'include_superseded')::boolean, false);
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, ledger_version or include_superseded'); end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if not exists (select 1 from bnx.actor_visible_acs(a) x where x = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform bnx.pol_require_module_for_ac(acid);
  select cu.minor_units into mu from bnx.account_currency ac join bnx.currency cu on cu.code = ac.currency where ac.id = acid;
  return jsonb_build_object('account_currency_id', acid, 'ledger_version', v,
    'observations', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('event_seq', o.event_seq, 'source', o.source,
                     'observed_at', o.observed_at, 'tz', o.tz, 'amount', bnx.fin_money(o.amount, mu), 'currency', o.currency,
                     'sign_convention', o.sign_convention, 'revision_of', o.revision_of, 'checkpoint_id', o.checkpoint_id,
                     'evidence_ref', o.evidence_ref, 'recorded_version', o.recorded_version,
                     'current', exists (select 1 from bnx.observations_at(acid, v) c where c.event_seq = o.event_seq)))
                   order by o.observed_at, o.source, o.event_seq)
               from bnx.balance_observation_event o
              where o.account_currency_id = acid and o.recorded_version <= v
                and (allv or exists (select 1 from bnx.observations_at(acid, v) c where c.event_seq = o.event_seq))), '[]'),
    'conflicts', coalesce((select jsonb_agg(jsonb_build_object('observed_at', x.observed_at, 'event_seqs', x.seqs) order by x.observed_at)
               from (select c.observed_at, jsonb_agg(c.event_seq order by c.event_seq) seqs from bnx.observations_at(acid, v) c
                      group by c.observed_at having count(distinct (c.amount, c.sign_convention)) > 1) x), '[]'));
end $$;

-- statement coverage (R15): one row per statement that is not withdrawn at version v, with its account-currency (the
-- printed assignment or the latest 'assigned' event), period, printed balances, confirmation, latest version role and
-- 'partial' (a period bound or the closing balance is missing). A partial period is never final.
create function bnx.statement_period_at(p_v bigint)
returns table(statement_id uuid, document_id uuid, account_currency_id uuid, currency char(3), period_start date, period_end date,
              opening_balance numeric, closing_balance numeric, sign_convention text, version_group uuid, version_role text,
              confirmed boolean, partial boolean, final boolean, last_event_version bigint)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select s.id, s.document_id,
         coalesce(s.account_currency_id, (select (e.payload->>'account_currency_id')::uuid from bnx.statement_event e
                                           where e.statement_id = s.id and e.event = 'assigned' and e.recorded_version <= p_v
                                           order by e.seq desc limit 1)),
         s.currency, s.period_start, s.period_end, s.opening_balance, s.closing_balance, s.sign_convention, s.version_group,
         (select e.payload->>'role' from bnx.statement_event e where e.statement_id = s.id and e.event = 'version_role_set'
           and e.recorded_version <= p_v order by e.seq desc limit 1),
         c.confirmed, p.partial, c.confirmed and not p.partial,
         (select max(e.recorded_version) from bnx.statement_event e where e.statement_id = s.id and e.recorded_version <= p_v)
    from bnx.statement s
    cross join lateral (select exists (select 1 from bnx.statement_event e where e.statement_id = s.id and e.event = 'confirmed'
                                         and e.recorded_version <= p_v) confirmed) c
    cross join lateral (select s.period_start is null or s.period_end is null or s.closing_balance is null partial) p
   where coalesce((select e.event from bnx.statement_event e where e.statement_id = s.id and e.recorded_version <= p_v
                    order by e.seq desc limit 1), '') <> 'withdrawn'
$$;
create view bnx.statement_period as select * from bnx.statement_period_at((select version from bnx.ledger_state));

-- ---------- 9012c-2: deterministic reconciliation (Draft-04 §D1-§D7 as carried by UA V1.2 §5.6 and BNX-S2-02) ----------
-- Authority: Balnexa_Unified_Architecture_V1.0_R6.2_Draft04.md (SHA-256 4ad49225...) §D1-§D7, mapped onto the V1.2 objects
-- (reconciliation_exception with rule_code; S2 states OPEN/EXPLAINED/RESOLVED). Statement rows are R1 bnx.source_txn rows of the
-- account-currency inside the statement period (V1.2 carries no staged_row table; D-9012c2-1). Only journals visible at the
-- ledger version and not corrected take part; pending batches are counted, never summed (§D1, INV-27).

-- the journal a statement row is linked to at version v (R1 source_link_event: the latest event of the pair is 'linked')
create function bnx.source_link_at(p_src uuid, p_v bigint) returns uuid
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select x.journal_id from (
    select distinct on (e.journal_id) e.journal_id, e.event from bnx.source_link_event e
     where e.source_txn_id = p_src and e.recorded_version <= p_v order by e.journal_id, e.event_id desc) x
   where x.event = 'linked' and bnx.journal_counts_at(x.journal_id, p_v) limit 1
$$;

-- one engine evaluation (class F, append-only): the subject is a statement or a balance observation; the result in force at V
-- is the latest run of the subject evaluated at or before V (Draft-04 §D7 Δ3 recon_result_at)
create table bnx.reconciliation_run(
  id uuid primary key, account_currency_id uuid not null references bnx.account_currency,
  subject_kind text not null check (subject_kind in ('statement','observation')),
  statement_id uuid references bnx.statement, observation_event_seq int,
  period_start date, period_end date not null,
  stage1_state text not null check (stage1_state in ('pass','fail','fail_accepted_by_member','insufficient_data','not_applicable')),
  stage1 jsonb not null,
  stage2_state text not null check (stage2_state in ('not_evaluated','no_opening','before_opening','incomplete_history','matched','difference_open')),
  observed numeric(20,4), ledger numeric(20,4), difference numeric(20,4), pending_batch_count int not null,
  conflicting_observation_event_seqs int[], evaluated_at_version bigint not null, actor uuid references bnx.member,
  recorded_version bigint not null, recorded_at timestamptz not null default now(),
  foreign key (account_currency_id, observation_event_seq) references bnx.balance_observation_event(account_currency_id, event_seq),
  check ((subject_kind = 'statement') = (statement_id is not null)), check ((subject_kind = 'observation') = (observation_event_seq is not null)),
  check (difference is null or difference = observed - ledger));
create index reconciliation_run_subject on bnx.reconciliation_run(account_currency_id, statement_id, observation_event_seq, evaluated_at_version);

-- a finding (Draft-04 recon_finding as a V1.2 reconciliation_exception): computed, never posted
create table bnx.reconciliation_exception(
  id uuid primary key, run_id uuid not null references bnx.reconciliation_run, account_currency_id uuid not null references bnx.account_currency,
  as_of_at timestamptz not null, observed numeric(20,4), ledger numeric(20,4), difference numeric(20,4),
  rule_code text check (rule_code ~ '^RC-(0[1-9]|1[0-4])$'),
  classification text not null check (classification in ('confirmed','probable','unresolved','ruled_out')),
  confirmation text check (confirmation in ('deterministic','member','resolved_by_action')),
  source text not null check (source in ('deterministic','ai_hypothesis','member')),
  criteria jsonb not null check (jsonb_typeof(criteria) = 'object'), amount_effect numeric(20,4),
  evidence jsonb not null check (jsonb_typeof(evidence) = 'object'),
  conflicting_observation_event_seqs int[], supersedes_id uuid unique references bnx.reconciliation_exception,
  author_member uuid references bnx.member, ledger_version bigint not null, created_at timestamptz not null default now(),
  check (difference is null or (observed is not null and ledger is not null and difference = observed - ledger)),
  check (rule_code is not null or classification = 'unresolved'),                       -- an unexplained remainder has no rule
  check (source <> 'ai_hypothesis' or classification in ('probable','unresolved','ruled_out')),   -- §D5: AI at most probable
  check (classification <> 'confirmed' or confirmation is not null),
  check (confirmation is distinct from 'deterministic'
         or coalesce(criteria->>'C1' = 'true' and criteria->'C2'->>'ok' = 'true' and criteria->'C3'->>'ok' = 'true'
                     and criteria->'C4'->>'ok' = 'true' and criteria->'C5'->>'ok' = 'true', false)));   -- §D5: all five stored and true
-- the state of a finding (S2 OPEN/EXPLAINED/RESOLVED) with the Draft-04 §D7 lifecycle phase and actions
create table bnx.reconciliation_exception_event(
  exception_id uuid not null references bnx.reconciliation_exception, seq int not null,
  state text not null check (state in ('OPEN','EXPLAINED','RESOLVED')),
  phase text not null check (phase in ('open','investigating','findings_ready','unresolved_parked','resolved_explained','resolved_matched')),
  explanation_kind text check (explanation_kind in ('timing_in_transit','issuer_error_disputed','missing_history_accepted','bridge_accepted','other')),
  resolution_action text check (resolution_action in ('POST_MISSING_ROW','REVERSE_DUPLICATE','CONFIRM_POSTING_DATE','REMAP_ACCOUNT',
                                                      'REVISE_ANCHOR','RERUN_MATCHED')),
  note jsonb check (note is null or jsonb_typeof(note) = 'object'),
  actor uuid references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  primary key (exception_id, seq),
  check ((state = 'OPEN') = (phase in ('open','investigating','findings_ready','unresolved_parked'))),
  check ((state = 'EXPLAINED') = (phase = 'resolved_explained')), check ((state = 'RESOLVED') = (phase = 'resolved_matched')),
  check ((state = 'EXPLAINED') = (explanation_kind is not null)), check ((state = 'RESOLVED') = (resolution_action is not null)));
create trigger t_append_only before update or delete on bnx.reconciliation_run for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.reconciliation_exception for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.reconciliation_exception_event for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('reconciliation_run','F'), ('reconciliation_exception','F'), ('reconciliation_exception_event','F');

-- state machine: OPEN first; OPEN -> OPEN (another phase), EXPLAINED, RESOLVED; EXPLAINED -> OPEN, RESOLVED; RESOLVED -> OPEN
-- (a later visible change re-opens, §D7). Restore replays are exempt.
create function bnx.trg_reconciliation_exception_state() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev record;
begin
  if bnx.restore_mode() then return new; end if;
  select e.seq, e.state, e.phase into prev from bnx.reconciliation_exception_event e where e.exception_id = new.exception_id
   order by e.seq desc limit 1;
  if new.seq <> coalesce(prev.seq, 0) + 1
     or (prev.state is null and new.state <> 'OPEN')
     or (prev.state = 'OPEN' and new.state = 'OPEN' and new.phase = prev.phase)
     or (prev.state = 'EXPLAINED' and new.state = 'EXPLAINED')
     or (prev.state = 'RESOLVED' and new.state <> 'OPEN') then
    raise exception 'EXCEPTION_STATE' using errcode = 'P0409',
      detail = coalesce(prev.state || '/' || prev.phase, 'none') || ' -> ' || new.state || '/' || new.phase;
  end if;
  return new;
end $$;
create trigger t_reconciliation_exception_state before insert on bnx.reconciliation_exception_event
  for each row execute function bnx.trg_reconciliation_exception_state();

-- the statement-to-ledger sign (§D3): asset_positive as printed; owed_positive is negated
create function bnx.recon_eq(p_amount numeric, p_sign text) returns numeric
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select case when p_amount is null then null when p_sign = 'owed_positive' then -p_amount else p_amount end $$;

-- RC-13 helper: |a| in minor units with two adjacent digits swapped differs from |a| by exactly |d|
create function bnx.recon_transposes(p_a numeric, p_d numeric, mu int) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare s text := (abs(p_a) * 10 ^ mu)::numeric(30,0)::text; d numeric := abs(p_d) * 10 ^ mu; i int; t text;
begin
  if d = 0 or d % 9 <> 0 then return false; end if;
  for i in 1 .. length(s) - 1 loop
    if substr(s, i, 1) <> substr(s, i + 1, 1) then
      t := substr(s, 1, i - 1) || substr(s, i + 1, 1) || substr(s, i, 1) || substr(s, i + 2);
      if abs(t::numeric - s::numeric) = d then return true; end if;
    end if;
  end loop;
  return false;
end $$;

-- RC-14 helper: the subsets (at most 20 candidates; Gray-code walk) whose effects sum to p_target; returns up to 2 subsets as
-- arrays of candidate indexes (1-based), so a second subset shows that the explanation is not unique (§D5 C5)
create function bnx.recon_subset_sum(p_effects numeric[], p_target numeric) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare n int := coalesce(array_length(p_effects, 1), 0); mask bigint := 0; g bigint; prevg bigint := 0; bit int; s numeric := 0;
        found jsonb := '[]'; k int; sub int[];
begin
  if n = 0 or n > 20 or p_target = 0 then return jsonb_build_object('searched', n between 1 and 20, 'candidates', n, 'subsets', found); end if;
  for mask in 1 .. (1::bigint << n) - 1 loop
    g := mask # (mask >> 1);
    bit := 0;
    while ((g # prevg) >> bit) & 1 = 0 loop bit := bit + 1; end loop;
    if (g >> bit) & 1 = 1 then s := s + p_effects[bit + 1]; else s := s - p_effects[bit + 1]; end if;
    prevg := g;
    if s = p_target then
      sub := '{}';
      for k in 0 .. n - 1 loop if (g >> k) & 1 = 1 then sub := sub || (k + 1); end if; end loop;
      found := found || jsonb_build_array(to_jsonb(sub));
      exit when jsonb_array_length(found) >= 2;
    end if;
  end loop;
  return jsonb_build_object('searched', true, 'candidates', n, 'subsets', found);
end $$;

-- coverage (R15, §D3 incomplete_history): the days after the anchor date up to p_end that no final statement covers
create function bnx.recon_coverage_gap(p_ac uuid, p_from date, p_end date, p_v bigint) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case when p_from is null or p_from >= p_end then false else not coalesce(
    daterange(p_from + 1, p_end, '[]')::datemultirange <@
      (select range_agg(daterange(s.period_start, s.period_end, '[]')) from bnx.statement_period_at(p_v) s
        where s.account_currency_id = p_ac and s.final and coalesce(s.version_role, 'sole') in ('sole','authoritative')), false) end
$$;

-- the deterministic engine for one statement at version v (§D2-§D5). Pure: returns the run and its findings as JSON.
create function bnx.recon_evaluate_statement(p_statement uuid, p_v bigint, p_accept_stage1_fail boolean default false) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare st record; sp record; prev record; ac record; mu int; eo text; bal bnx.balance_result; pre bnx.balance_result;
        rows_sum numeric; arith_diff numeric; s1 text; s1j jsonb; s2 text := 'not_evaluated'; why text; cmpv numeric; ledg numeric; d numeric;
        pend int; gap boolean := false; chain text; f jsonb := '[]'; r record; j uuid; mv numeric; other uuid; rem numeric;
        det_sum numeric := 0; det_n int := 0; cands numeric[] := '{}'; cand_ref jsonb := '[]'; ss jsonb; c2 jsonb; c3 jsonb; c4ok boolean;
        c5 jsonb; x jsonb; out jsonb := '[]'; competing boolean := false;
begin
  select * into sp from bnx.statement_period_at(p_v) x where x.statement_id = p_statement;
  if sp.statement_id is null then return jsonb_build_object('error', 'STATEMENT_NOT_AVAILABLE'); end if;
  select ac0.id, ac0.currency, ac0.ledger_account_id, cu.minor_units into ac from bnx.account_currency ac0
    join bnx.currency cu on cu.code = ac0.currency where ac0.id = sp.account_currency_id;
  mu := ac.minor_units;
  select e.integrity_state into eo from bnx.document dct join bnx.evidence_object e on e.id = dct.evidence_object_id where dct.id = sp.document_id;
  -- ---------- stage 1 (§D2) ----------
  select coalesce(sum(t.amount), 0) into rows_sum from bnx.source_txn t
   where t.account_currency_id = ac.id and t.posting_date between sp.period_start and sp.period_end;
  select p.* into prev from bnx.statement_period_at(p_v) p
   where p.account_currency_id = ac.id and p.final and coalesce(p.version_role, 'sole') in ('sole','authoritative')
     and p.statement_id <> p_statement and p.period_end < coalesce(sp.period_end, 'infinity')
   order by p.period_end desc limit 1;
  chain := case when prev.statement_id is null then 'first'
                when sp.period_start is null or sp.opening_balance is null then 'insufficient_data'
                when prev.period_end + 1 < sp.period_start then 'gap'
                when prev.period_end >= sp.period_start then 'overlap'
                when bnx.recon_eq(prev.closing_balance, prev.sign_convention) = bnx.recon_eq(sp.opening_balance, sp.sign_convention) then 'pass'
                else 'opening_differs' end;
  if sp.opening_balance is null or sp.closing_balance is null or sp.period_start is null or sp.period_end is null then
    s1 := 'insufficient_data';
  else
    arith_diff := bnx.recon_eq(sp.opening_balance, sp.sign_convention) + rows_sum - bnx.recon_eq(sp.closing_balance, sp.sign_convention);
    s1 := case when arith_diff = 0 then 'pass' when p_accept_stage1_fail then 'fail_accepted_by_member' else 'fail' end;
  end if;
  s1j := jsonb_build_object('S1-ARITH', case when arith_diff is null then 'insufficient_data' when arith_diff = 0 then 'pass' else 'fail' end,
                            'arith_difference', arith_diff::text, 'S1-RUNBAL', 'not_available', 'S1-CHAIN', chain,
                            'previous_statement_id', prev.statement_id, 'S1-PERIOD', 'pass', 'S1-CURRENCY', 'pass', 'rows', rows_sum::text);
  select count(distinct je.posting_batch_id) into pend from bnx.journal_entry je join bnx.journal_line jl on jl.journal_id = je.id
   where jl.ledger_account_id = ac.ledger_account_id and je.posting_batch_id is not null and not bnx.journal_counts_at(je.id, p_v)
     and not exists (select 1 from bnx.posting_batch_event ev where ev.batch_id = je.posting_batch_id and ev.event = 'voided');
  -- ---------- stage 2 (§D3) ----------
  if not sp.confirmed then why := 'not_confirmed';
  elsif coalesce(sp.version_role, 'sole') not in ('sole','authoritative') then why := 'version_role';
  elsif s1 not in ('pass','fail_accepted_by_member') then why := 'stage1_' || s1;
  else
    cmpv := bnx.recon_eq(sp.closing_balance, sp.sign_convention);
    bal := bnx.balance_at(ac.id, sp.period_end, p_v);
    if bal.status = 'NO_OPENING' then s2 := 'no_opening';
    elsif bal.status = 'BEFORE_OPENING' then s2 := 'before_opening';
    else
      ledg := bal.amount; d := cmpv - ledg;
      gap := bnx.recon_coverage_gap(ac.id, (bal.anchor).anchor_date, sp.period_end, p_v);
      s2 := case when gap then 'incomplete_history' when d = 0 then 'matched' else 'difference_open' end;
    end if;
  end if;
  -- ---------- deterministic rules (§D4) ----------
  if s2 in ('difference_open','incomplete_history','matched') then
    -- RC-01 / RC-05 (subtype) missing in ledger, RC-07 same amount and date on another account-currency, RC-08 FX settlement,
    -- RC-04 (b) row linked to a journal posted after the period, RC-02 duplicate journal
    for r in select t.* from bnx.source_txn t where t.account_currency_id = ac.id and t.posting_date between sp.period_start and sp.period_end
               order by t.posting_date, t.id loop
      j := bnx.source_link_at(r.id, p_v);
      if j is null then
        f := f || jsonb_build_object('rule', case when r.normalized_description ~* '\m(fee|fees|interest|service charge|frais|interets|intérêts)\M'
                                                  then 'RC-05' else 'RC-01' end, 'effect', r.amount, 'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id)));
        for other in select je.id from bnx.journal_entry je join bnx.journal_line jl on jl.journal_id = je.id
                       join bnx.account_currency oac on oac.ledger_account_id = jl.ledger_account_id and oac.id <> ac.id and oac.currency = ac.currency
                      where jl.amount = r.amount and bnx.effective_posting_date(je.id, p_v) = r.posting_date and bnx.journal_counts_at(je.id, p_v)
                        and not exists (select 1 from bnx.source_link_event e where e.journal_id = je.id and e.recorded_version <= p_v
                                          and e.event = 'linked') loop
          f := f || jsonb_build_object('rule', 'RC-07', 'effect', r.amount, 'alternative', true,
                                       'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id), jsonb_build_object('journal_id', other)));
        end loop;
      else
        mv := bnx.journal_movement(j, ac.id);
        if bnx.effective_posting_date(j, p_v) > sp.period_end then
          f := f || jsonb_build_object('rule', 'RC-04', 'effect', r.amount, 'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id),
                                       jsonb_build_object('journal_id', j)), 'timing', 'ledger_after_period');
        elsif mv is distinct from r.amount and (select je.original_currency from bnx.journal_entry je where je.id = j) is not null then
          f := f || jsonb_build_object('rule', 'RC-08', 'effect', r.amount - coalesce(mv, 0), 'items',
                                       jsonb_build_array(jsonb_build_object('source_txn_id', r.id), jsonb_build_object('journal_id', j)));
        end if;
        for other in select je.id from bnx.journal_entry je join bnx.journal_line jl on jl.journal_id = je.id
                      where jl.ledger_account_id = ac.ledger_account_id and je.id <> j and jl.amount = r.amount
                        and bnx.effective_posting_date(je.id, p_v) = bnx.effective_posting_date(j, p_v) and bnx.journal_counts_at(je.id, p_v)
                        and not exists (select 1 from bnx.source_link_event e where e.journal_id = je.id and e.recorded_version <= p_v and e.event = 'linked')
                        and (select count(*) from bnx.source_txn t2 where t2.account_currency_id = ac.id and t2.amount = r.amount
                               and t2.posting_date = r.posting_date) = 1 loop
          f := f || jsonb_build_object('rule', 'RC-02', 'effect', -r.amount, 'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id),
                                       jsonb_build_object('journal_id', j), jsonb_build_object('journal_id', other)), 'duplicate_journal_id', other);
        end loop;
      end if;
    end loop;
    -- RC-03 ledger legs in the period with no statement row (RC-04 (a) when the row is in a later statement; RC-02 duplicates excluded)
    for r in select je.id jid, bnx.journal_movement(je.id, ac.id) amt from bnx.journal_entry je
              where exists (select 1 from bnx.journal_line jl where jl.journal_id = je.id and jl.ledger_account_id = ac.ledger_account_id)
                and bnx.journal_counts_at(je.id, p_v) and bnx.effective_posting_date(je.id, p_v) between sp.period_start and sp.period_end
                and not exists (select 1 from bnx.source_txn t where t.account_currency_id = ac.id and t.posting_date between sp.period_start
                                  and sp.period_end and bnx.source_link_at(t.id, p_v) = je.id)
                and not exists (select 1 from jsonb_array_elements(f) y where y->>'duplicate_journal_id' = je.id::text)
                and je.economic_type <> 'opening_balance'
              order by je.posting_date, je.id loop
      if exists (select 1 from bnx.source_txn t where t.account_currency_id = ac.id and t.posting_date > sp.period_end
                   and bnx.source_link_at(t.id, p_v) = r.jid) then
        f := f || jsonb_build_object('rule', 'RC-04', 'effect', -r.amt, 'items', jsonb_build_array(jsonb_build_object('journal_id', r.jid)),
                                     'timing', 'row_in_later_statement');
      else
        f := f || jsonb_build_object('rule', 'RC-03', 'effect', -r.amt, 'items', jsonb_build_array(jsonb_build_object('journal_id', r.jid)));
      end if;
    end loop;
    -- RC-06 open clearing items (transfer legs) on the account-currency
    for r in select c.id, c.amount from bnx.clearing_item c where c.account_currency_id = ac.id and bnx.journal_counts_at(c.opened_journal, p_v)
               and not exists (select 1 from bnx.clearing_item_event e where e.clearing_item_id = c.id and e.event = 'resolved'
                                 and e.recorded_version <= p_v) loop
      f := f || jsonb_build_object('rule', 'RC-06', 'effect', null, 'items', jsonb_build_array(jsonb_build_object('clearing_item_id', r.id)),
                                   'clearing_amount', r.amount);
    end loop;
    -- RC-10 the first statement's opening against the ledger on the day before the period
    if chain = 'first' and sp.opening_balance is not null then
      pre := bnx.balance_at(ac.id, sp.period_start - 1, p_v);
      if pre.status = 'ok' and bnx.recon_eq(sp.opening_balance, sp.sign_convention) <> pre.amount then
        f := f || jsonb_build_object('rule', 'RC-10', 'effect', bnx.recon_eq(sp.opening_balance, sp.sign_convention) - pre.amount,
                                     'items', jsonb_build_array(jsonb_build_object('statement_opening', p_statement), jsonb_build_object('anchor_id', (pre.anchor).id)));
      end if;
    end if;
  end if;
  if s1 in ('fail','fail_accepted_by_member') then
    f := f || jsonb_build_object('rule', 'RC-09', 'effect', null, 'items', jsonb_build_array(jsonb_build_object('statement_id', p_statement)),
                                 'arith_difference', arith_diff::text);
  end if;
  if s2 = 'incomplete_history' or chain in ('gap','overlap') then
    f := f || jsonb_build_object('rule', 'RC-11', 'effect', null, 'items', jsonb_build_array(jsonb_build_object('statement_id', p_statement)),
                                 'chain', chain);
  end if;
  -- hypotheses on the open difference: RC-12 sign, RC-13 transposition, RC-14 subset sum of the unmatched items
  if s2 in ('difference_open','incomplete_history') and d <> 0 then
    for r in select t.id, t.amount from bnx.source_txn t where t.account_currency_id = ac.id and t.posting_date between sp.period_start and sp.period_end
               and abs(2 * t.amount) = abs(d) loop
      f := f || jsonb_build_object('rule', 'RC-12', 'effect', d, 'alternative', true, 'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id)));
    end loop;
    for r in select t.id, t.amount from bnx.source_txn t where t.account_currency_id = ac.id and t.posting_date between sp.period_start and sp.period_end
               and bnx.recon_transposes(t.amount, d, mu) loop
      f := f || jsonb_build_object('rule', 'RC-13', 'effect', d, 'alternative', true, 'items', jsonb_build_array(jsonb_build_object('source_txn_id', r.id)));
    end loop;
    for x in select y from jsonb_array_elements(f) y where y->>'rule' in ('RC-01','RC-03','RC-05') loop
      cands := cands || (x->>'effect')::numeric; cand_ref := cand_ref || jsonb_build_array(x->'items');
    end loop;
    ss := bnx.recon_subset_sum(cands, d);
    -- RC-14 is a hypothesis only when the item findings do not already close the difference (otherwise it repeats them)
    if jsonb_array_length(ss->'subsets') > 0 and (select coalesce(sum((y->>'effect')::numeric), 0) from jsonb_array_elements(f) y
                                                  where y->>'rule' in ('RC-01','RC-02','RC-03','RC-04','RC-05','RC-08','RC-10')) <> d then
      f := f || jsonb_build_object('rule', 'RC-14', 'effect', d, 'alternative', true, 'subset_search', ss,
                                   'items', (select jsonb_agg(cand_ref->(i::int - 1)) from jsonb_array_elements_text(ss->'subsets'->0) i));
    end if;
  end if;
  -- ---------- classification (§D5) ----------
  select coalesce(sum((y->>'effect')::numeric), 0), count(*) into det_sum, det_n from jsonb_array_elements(f) y
   where y->>'rule' in ('RC-01','RC-02','RC-03','RC-04','RC-05','RC-08','RC-10') and y->>'effect' is not null;
  competing := exists (select 1 from jsonb_array_elements(f) y where (y->>'alternative')::boolean is true and y->>'rule' <> 'RC-14')
               or jsonb_array_length(coalesce(ss->'subsets', '[]')) > 1;
  c2 := jsonb_build_object('ok', sp.confirmed and coalesce(sp.version_role, 'sole') in ('sole','authoritative') and eo = 'verified',
                           'statement_confirmed', sp.confirmed, 'version_role', coalesce(sp.version_role, 'sole'), 'evidence_integrity', eo,
                           'page_reference', jsonb_build_object('document_id', sp.document_id, 'granularity', 'document'));
  c3 := jsonb_build_object('ok', s1 = 'pass' and not gap and chain in ('first','pass'), 'stage1', s1, 'chain', chain, 'coverage_gap', gap);
  c4ok := d is not null and det_n > 0 and det_sum = d;
  c5 := jsonb_build_object('ok', not competing, 'competing_explanations', competing, 'subset_search', ss);
  for x in select y from jsonb_array_elements(f) y loop
    if x->>'rule' in ('RC-01','RC-02','RC-04','RC-05','RC-08','RC-10') and (c2->>'ok')::boolean and (c3->>'ok')::boolean and c4ok
       and (c5->>'ok')::boolean and (x->>'rule' <> 'RC-04' or x->>'timing' = 'row_in_later_statement' or x->>'timing' = 'ledger_after_period') then
      x := x || jsonb_build_object('classification', 'confirmed', 'confirmation', 'deterministic');
    elsif x->>'rule' = 'RC-11' then x := x || jsonb_build_object('classification', 'unresolved');
    else x := x || jsonb_build_object('classification', 'probable');
    end if;
    out := out || jsonb_build_array(x || jsonb_build_object('criteria', jsonb_build_object(
             'C1', x->>'rule' in ('RC-01','RC-02','RC-04','RC-05','RC-08','RC-10'), 'C2', c2, 'C3', c3,
             'C4', jsonb_build_object('ok', c4ok, 'deterministic_sum', det_sum::text, 'difference', d::text), 'C5', c5)));
  end loop;
  rem := case when s2 = 'difference_open' then d - det_sum end;
  if rem is not null and rem <> 0 then
    out := out || jsonb_build_array(jsonb_build_object('rule', null, 'effect', rem, 'classification', 'unresolved', 'items', '[]'::jsonb,
             'remainder', true, 'criteria', jsonb_build_object('C1', false, 'remainder_of', d::text, 'explained', det_sum::text)));
  end if;
  return jsonb_build_object('statement_id', p_statement, 'account_currency_id', ac.id, 'period_start', sp.period_start, 'period_end', sp.period_end,
    'stage1_state', s1, 'stage1', s1j, 'stage2_state', s2, 'not_evaluated_reason', why, 'observed', cmpv::text, 'ledger', ledg::text,
    'difference', d::text, 'pending_batch_count', pend, 'ledger_version', p_v, 'findings', out);
end $$;

-- a balance observation compared with the ledger on its local date (§D3 "checkpoint" cases: same comparison, member-reported
-- or document evidence). Only the remainder is reported; rules that need statement rows do not apply.
create function bnx.recon_evaluate_observation(p_ac uuid, p_seq int, p_v bigint) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare o bnx.balance_observation_event; dt date; bal bnx.balance_result; cmpv numeric; d numeric; s2 text; conf int[]; out jsonb := '[]';
begin
  select x.* into o from bnx.observations_at(p_ac, p_v) x where x.event_seq = p_seq;
  if o.event_seq is null then return jsonb_build_object('error', 'OBSERVATION_NOT_IN_EFFECT'); end if;
  dt := (o.observed_at at time zone o.tz)::date; cmpv := bnx.recon_eq(o.amount, o.sign_convention);
  conf := array(select c.event_seq from bnx.observations_at(p_ac, p_v) c where c.observed_at = o.observed_at and c.event_seq <> o.event_seq
                  and bnx.recon_eq(c.amount, c.sign_convention) <> cmpv order by 1);
  bal := bnx.balance_at(p_ac, dt, p_v);
  s2 := case when bal.status = 'NO_OPENING' then 'no_opening' when bal.status = 'BEFORE_OPENING' then 'before_opening'
             when cmpv = bal.amount then 'matched' else 'difference_open' end;
  if s2 = 'difference_open' then d := cmpv - bal.amount;
    out := jsonb_build_array(jsonb_build_object('rule', null, 'effect', d, 'classification', 'unresolved', 'items',
             jsonb_build_array(jsonb_build_object('observation_event_seq', p_seq)), 'remainder', true,
             'criteria', jsonb_build_object('C1', false, 'evidence', case o.source when 'MEMBER' then 'member_reported' else 'document' end)));
  end if;
  return jsonb_build_object('account_currency_id', p_ac, 'observation_event_seq', p_seq, 'period_end', dt, 'stage1_state', 'not_applicable',
    'stage1', '{}'::jsonb, 'stage2_state', s2, 'observed', cmpv::text, 'ledger', bal.amount::text, 'difference', d::text,
    'pending_batch_count', 0, 'conflicting_observation_event_seqs', to_jsonb(conf), 'ledger_version', p_v, 'findings', out);
end $$;

-- RC-POST (tier 2; post rights on the account-currency): run the engine for one subject at the current version and record the
-- run and its findings (each OPEN / findings_ready). Open findings of earlier runs of the same subject get RESOLVED / RERUN_MATCHED
-- when this run is matched, otherwise they stay as they are (the newest run's findings are the ones in force).
create function bnx.cmd_run_reconciliation(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; sid uuid; acid uuid; seq_ int; vnow bigint; res jsonb; v bigint; rid uuid := gen_random_uuid();
        x jsonb; xid uuid; n int := 0; old record;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'run_reconciliation', cmd); if rc is not null then return rc; end if;
  begin sid := (cmd->>'statement_id')::uuid; acid := (cmd->>'account_currency_id')::uuid; seq_ := (cmd->>'observation_event_seq')::int;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'statement_id, account_currency_id or observation_event_seq'); end;
  if (sid is null) = (seq_ is null) or (seq_ is not null and acid is null) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'one subject: statement_id, or account_currency_id with observation_event_seq'); end if;
  select version into vnow from bnx.ledger_state;
  if sid is not null then
    select s.account_currency_id into acid from bnx.statement_period_at(vnow) s where s.statement_id = sid;
    if acid is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  end if;
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.recon:' || acid));
  res := case when sid is not null then bnx.recon_evaluate_statement(sid, vnow, coalesce((cmd->>'accept_stage1_fail')::boolean, false))
              else bnx.recon_evaluate_observation(acid, seq_, vnow) end;
  if res ? 'error' then perform bnx.fail('NOT_FOUND', 'P0404', res->>'error'); end if;
  v := bnx.next_version();
  insert into bnx.reconciliation_run(id, account_currency_id, subject_kind, statement_id, observation_event_seq, period_start, period_end,
                                     stage1_state, stage1, stage2_state, observed, ledger, difference, pending_batch_count,
                                     conflicting_observation_event_seqs, evaluated_at_version, actor, recorded_version)
  values (rid, acid, case when sid is not null then 'statement' else 'observation' end, sid, seq_, (res->>'period_start')::date,
          (res->>'period_end')::date, res->>'stage1_state', res->'stage1', res->>'stage2_state', (res->>'observed')::numeric,
          (res->>'ledger')::numeric, (res->>'difference')::numeric, (res->>'pending_batch_count')::int,
          array(select jsonb_array_elements_text(coalesce(res->'conflicting_observation_event_seqs', '[]'))::int), vnow, a.member_id, v);
  for x in select y from jsonb_array_elements(res->'findings') y loop
    xid := gen_random_uuid(); n := n + 1;
    insert into bnx.reconciliation_exception(id, run_id, account_currency_id, as_of_at, observed, ledger, difference, rule_code, classification,
                                             confirmation, source, criteria, amount_effect, evidence, conflicting_observation_event_seqs, ledger_version)
    values (xid, rid, acid, ((res->>'period_end')::date + 1)::timestamptz, (res->>'observed')::numeric, (res->>'ledger')::numeric,
            (res->>'difference')::numeric, x->>'rule', x->>'classification', x->>'confirmation', 'deterministic', x->'criteria',
            (x->>'effect')::numeric, jsonb_build_object('items', x->'items') || (x - 'rule' - 'classification' - 'confirmation' - 'criteria' - 'effect' - 'items'),
            array(select jsonb_array_elements_text(coalesce(res->'conflicting_observation_event_seqs', '[]'))::int), vnow);
    insert into bnx.reconciliation_exception_event(exception_id, seq, state, phase, actor, recorded_version) values (xid, 1, 'OPEN', 'findings_ready', a.member_id, v);
  end loop;
  if res->>'stage2_state' = 'matched' then
    for old in select x.id, (select max(e.seq) from bnx.reconciliation_exception_event e where e.exception_id = x.id) s
                 from bnx.reconciliation_exception x join bnx.reconciliation_run r on r.id = x.run_id
                where r.account_currency_id = acid and r.id <> rid and r.statement_id is not distinct from sid
                  and r.observation_event_seq is not distinct from seq_
                  and (select e.state from bnx.reconciliation_exception_event e where e.exception_id = x.id order by e.seq desc limit 1) = 'OPEN' loop
      insert into bnx.reconciliation_exception_event(exception_id, seq, state, phase, resolution_action, actor, recorded_version)
      values (old.id, old.s + 1, 'RESOLVED', 'resolved_matched', 'RERUN_MATCHED', a.member_id, v);
    end loop;
  end if;
  perform bnx.audit(a, 'run_reconciliation', jsonb_build_object('run_id', rid, 'account_currency_id', acid), cmd, v);
  return bnx.idem_end(a, 'run_reconciliation', cmd, jsonb_build_object('run_id', rid, 'stage1_state', res->>'stage1_state',
           'stage2_state', res->>'stage2_state', 'difference', res->>'difference', 'findings', n, 'ledger_version', v));
end $$;

-- a member action on a finding (§D7, PWA, tier 2): investigate, park, explain (reason kind, no journal), mark resolved by one of
-- the D7 actions, or reopen; member confirmation (§D5) records a member-confirmed copy that supersedes the finding
create function bnx.cmd_set_reconciliation_exception_state(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; x bnx.reconciliation_exception; ph text := cmd->>'phase'; st text; s int; v bigint;
        nid uuid;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'set_reconciliation_exception_state', cmd); if rc is not null then return rc; end if;
  begin select * into x from bnx.reconciliation_exception where id = (cmd->>'exception_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'exception_id'); end;
  if x.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, x.account_currency_id) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if (cmd ? 'note' and jsonb_typeof(cmd->'note') <> 'object') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'note'); end if;
  v := bnx.next_version();
  if ph = 'member_confirmed' then                       -- §D5 member confirmation: needs cited evidence; never for a remainder
    if x.rule_code is null or jsonb_typeof(cmd->'evidence_ref') is distinct from 'object' or x.classification = 'confirmed' then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'member confirmation needs evidence_ref and a probable rule finding'); end if;
    nid := gen_random_uuid();
    insert into bnx.reconciliation_exception(id, run_id, account_currency_id, as_of_at, observed, ledger, difference, rule_code, classification,
                                             confirmation, source, criteria, amount_effect, evidence, conflicting_observation_event_seqs, supersedes_id,
                                             author_member, ledger_version)
    values (nid, x.run_id, x.account_currency_id, x.as_of_at, x.observed, x.ledger, x.difference, x.rule_code, 'confirmed', 'member', 'member',
            x.criteria, x.amount_effect, x.evidence || jsonb_build_object('member_evidence', cmd->'evidence_ref'), x.conflicting_observation_event_seqs,
            x.id, a.member_id, v);
    insert into bnx.reconciliation_exception_event(exception_id, seq, state, phase, actor, recorded_version) values (nid, 1, 'OPEN', 'findings_ready', a.member_id, v);
  else
    st := case when ph in ('open','investigating','unresolved_parked','findings_ready') then 'OPEN' when ph = 'resolved_explained' then 'EXPLAINED'
               when ph = 'resolved_matched' then 'RESOLVED' end;
    if st is null or (st = 'RESOLVED' and cmd->>'resolution_action' = 'RERUN_MATCHED') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'phase'); end if;
    s := coalesce((select max(seq) from bnx.reconciliation_exception_event where exception_id = x.id), 0) + 1;
    begin
      insert into bnx.reconciliation_exception_event(exception_id, seq, state, phase, explanation_kind, resolution_action, note, actor, recorded_version)
      values (x.id, s, st, ph, cmd->>'explanation_kind', cmd->>'resolution_action', cmd->'note', a.member_id, v);
    exception when check_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'explanation_kind or resolution_action for the phase');
    end;
  end if;
  perform bnx.audit(a, 'set_reconciliation_exception_state', jsonb_build_object('exception_id', x.id, 'phase', ph), cmd, v);
  return bnx.idem_end(a, 'set_reconciliation_exception_state', cmd, jsonb_build_object('exception_id', coalesce(nid, x.id), 'phase', ph, 'ledger_version', v));
end $$;

-- findings in force on the actor's visible account-currencies (OBJ-249): the latest run of each subject at V, each finding with its
-- current state; superseded (member-confirmed) findings are replaced by their successor
create function bnx.q_reconciliation_exceptions(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); acid uuid; st text := q->>'state'; v bigint; vnow bigint;
begin
  perform bnx.require(a, 0);
  begin acid := (q->>'account_currency_id')::uuid; v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id or ledger_version'); end;
  if st is not null and st not in ('OPEN','EXPLAINED','RESOLVED') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'state'); end if;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if acid is not null and not exists (select 1 from bnx.actor_visible_acs(a) x where x = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  return jsonb_build_object('ledger_version', v, 'exceptions', coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('exception_id', x.id, 'run_id', x.run_id, 'account_currency_id', x.account_currency_id,
             'subject', case when r.statement_id is not null then jsonb_build_object('statement_id', r.statement_id)
                             else jsonb_build_object('observation_event_seq', r.observation_event_seq) end,
             'stage2_state', r.stage2_state, 'observed', x.observed::text, 'ledger', x.ledger::text, 'difference', x.difference::text,
             'rule_code', x.rule_code, 'classification', x.classification, 'confirmation', x.confirmation, 'source', x.source,
             'amount_effect', x.amount_effect::text, 'criteria', x.criteria, 'evidence', x.evidence,
             'conflicting_observation_event_seqs', to_jsonb(x.conflicting_observation_event_seqs),
             'state', cur.state, 'phase', cur.phase, 'explanation_kind', cur.explanation_kind, 'resolution_action', cur.resolution_action))
             order by r.period_end, x.rule_code nulls last, x.id)
      from bnx.reconciliation_exception x
      join bnx.reconciliation_run r on r.id = x.run_id
      join bnx.actor_visible_acs(a) vis on vis = x.account_currency_id
      cross join lateral (select e.state, e.phase, e.explanation_kind, e.resolution_action from bnx.reconciliation_exception_event e
                           where e.exception_id = x.id and e.recorded_version <= v order by e.seq desc limit 1) cur
     where x.ledger_version <= v and (acid is null or x.account_currency_id = acid) and (st is null or cur.state = st)
       and not exists (select 1 from bnx.reconciliation_exception s where s.supersedes_id = x.id and s.ledger_version <= v)
       and r.id = (select r2.id from bnx.reconciliation_run r2 where r2.account_currency_id = r.account_currency_id
                     and r2.statement_id is not distinct from r.statement_id and r2.observation_event_seq is not distinct from r.observation_event_seq
                     and r2.recorded_version <= v order by r2.recorded_version desc limit 1)), '[]'));
end $$;

-- statement coverage and reconciliation state per account-currency (OBJ-249 q_reconciliation_coverage; R15): every final or
-- partial statement at V with its latest run, and the gaps after the anchor date that no final statement covers
create function bnx.q_reconciliation_coverage(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); acid uuid; v bigint; vnow bigint; an bnx.opening_anchor_version; last_end date;
begin
  perform bnx.require(a, 0);
  begin acid := (q->>'account_currency_id')::uuid; v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id or ledger_version'); end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if not exists (select 1 from bnx.actor_visible_acs(a) x where x = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform bnx.pol_require_module_for_ac(acid);
  an := bnx.anchor_at(acid, v);
  select max(s.period_end) into last_end from bnx.statement_period_at(v) s where s.account_currency_id = acid and s.final;
  return jsonb_build_object('account_currency_id', acid, 'ledger_version', v, 'anchor_date', an.anchor_date,
    'statements', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('statement_id', s.statement_id, 'period_start', s.period_start,
                     'period_end', s.period_end, 'partial', s.partial, 'final', s.final, 'version_role', s.version_role,
                     'stage1_state', r.stage1_state, 'stage2_state', r.stage2_state, 'difference', r.difference::text,
                     'evaluated_at_version', r.evaluated_at_version)) order by s.period_start nulls last, s.statement_id)
               from bnx.statement_period_at(v) s
               left join lateral (select r0.* from bnx.reconciliation_run r0 where r0.statement_id = s.statement_id and r0.recorded_version <= v
                                   order by r0.recorded_version desc limit 1) r on true
              where s.account_currency_id = acid), '[]'),
    'gaps', coalesce((select jsonb_agg(jsonb_build_object('from', lower(g), 'to', upper(g) - 1) order by lower(g))
               from unnest(case when an.id is not null and last_end is not null and last_end > an.anchor_date then
                             daterange(an.anchor_date + 1, last_end, '[]')::datemultirange
                             - coalesce((select range_agg(daterange(s.period_start, s.period_end, '[]')) from bnx.statement_period_at(v) s
                                          where s.account_currency_id = acid and s.final), '{}'::datemultirange)
                           else '{}'::datemultirange end) g), '[]'));
end $$;

-- module flags (F-C2-07; balance_observation_event is a UA §4.4.1 table)
insert into bnx.flag_enforcement_point values
 ('balance_observation_event','account_currency_id','INSERT','9012','bnx'),
 ('reconciliation_run','account_currency_id','INSERT','9012','bnx'),
 ('reconciliation_exception','account_currency_id','INSERT','9012','bnx');
create trigger t_scope_flag_balance_observation_event before insert on bnx.balance_observation_event
  for each row execute function bnx.trg_scope_flag('account_currency_id');
create trigger t_scope_flag_reconciliation_run before insert on bnx.reconciliation_run
  for each row execute function bnx.trg_scope_flag('account_currency_id');
create trigger t_scope_flag_reconciliation_exception before insert on bnx.reconciliation_exception
  for each row execute function bnx.trg_scope_flag('account_currency_id');

insert into bnx.function_scope values
 ('q_balance_observations', 'finance.read', false, false, true, 'fin.balances.observations'),
 ('q_reconciliation_exceptions', 'finance.read', false, false, true, 'fin.reconciliation.exceptions'),
 ('q_reconciliation_coverage', 'finance.read', false, false, true, 'fin.reconciliation.coverage');

-- ---------- 9012d: matching MR-08...MR-13, onboarding jobs, imports, payment attributes, cross-source matches ----------
-- Authority: UA V1.2 §5.6 (objects), BNX-S2-02 (import_mapping, payment_attribute, cross_source_match), Draft-04 §C4 (matching
-- rules) and §C5 (onboarding states), SHA-256 4ad49225... MR-01...MR-07 need extraction runs, staged rows and running balances
-- (WP-DOC) and are not implemented here (L-9012-11).

-- ---------- import mappings (S2: data, not code; T-38) ----------
create table bnx.import_mapping(
  mapping_id uuid not null, version int not null check (version >= 1),
  provider text not null check (provider in ('GENERIC_CSV','GENERIC_XLSX','OFX','QFX','WECHAT_PAY','ALIPAY','PAYPAL','APPLE_PAY',
                                             'UNIONPAY','SUISHOUJI')),
  label text not null check (label ~ '^[A-Za-z0-9][A-Za-z0-9 ._()/-]{0,79}$'),
  column_map jsonb not null check (jsonb_typeof(column_map) = 'object'), date_rules jsonb not null check (jsonb_typeof(date_rules) = 'object'),
  amount_rules jsonb not null check (jsonb_typeof(amount_rules) = 'object'),
  status text not null check (status in ('DRAFT','ACTIVE','RETIRED')),
  recorded_by uuid references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  primary key (mapping_id, version));
create trigger t_append_only before update or delete on bnx.import_mapping for each row execute function bnx.trg_append_only();

-- a new version of a mapping (Owner or admin: mappings change how files become rows). Keys of the maps are closed.
create function bnx.cmd_set_import_mapping(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; mid uuid; ver int; v bigint;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'set_import_mapping', cmd); if rc is not null then return rc; end if;
  begin mid := coalesce((cmd->>'mapping_id')::uuid, gen_random_uuid());
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'mapping_id'); end;
  if jsonb_typeof(cmd->'column_map') is distinct from 'object' or jsonb_typeof(cmd->'date_rules') is distinct from 'object'
     or jsonb_typeof(cmd->'amount_rules') is distinct from 'object'
     or exists (select 1 from jsonb_object_keys(cmd->'column_map') k where k not in ('posting_date','transaction_date','amount','debit','credit',
                  'currency','description','bank_ref','balance','counterparty','payment_method'))
     or exists (select 1 from jsonb_each(cmd->'column_map') e where jsonb_typeof(e.value) <> 'string' or length(e.value #>> '{}') > 80)
     or exists (select 1 from jsonb_object_keys(cmd->'date_rules') k where k not in ('format','timezone'))
     or exists (select 1 from jsonb_object_keys(cmd->'amount_rules') k where k not in ('decimal_separator','thousands_separator','sign','outflow_negative'))
     or coalesce(cmd->>'status', '') not in ('DRAFT','ACTIVE','RETIRED') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'provider, label, column_map, date_rules, amount_rules or status'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.import_mapping:' || mid));
  ver := coalesce((select max(version) from bnx.import_mapping where mapping_id = mid), 0) + 1;
  if ver > 1 and (select provider from bnx.import_mapping where mapping_id = mid and version = 1) is distinct from cmd->>'provider' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'a mapping keeps its provider'); end if;
  v := bnx.next_version();
  begin
    insert into bnx.import_mapping(mapping_id, version, provider, label, column_map, date_rules, amount_rules, status, recorded_by, recorded_version)
    values (mid, ver, cmd->>'provider', cmd->>'label', cmd->'column_map', cmd->'date_rules', cmd->'amount_rules', cmd->>'status', a.member_id, v);
  exception when check_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'provider or label'); end;
  perform bnx.audit(a, 'set_import_mapping', jsonb_build_object('mapping_id', mid, 'version', ver), cmd, v);
  return bnx.idem_end(a, 'set_import_mapping', cmd, jsonb_build_object('mapping_id', mid, 'version', ver, 'ledger_version', v));
end $$;

-- ---------- payment attributes (OR-I-11: Apple Pay, UnionPay ... are attributes of a journal, never accounts) ----------
create table bnx.payment_attribute(
  journal_id uuid not null references bnx.journal_entry, seq int not null,
  payment_method text check (payment_method in ('APPLE_PAY','GOOGLE_PAY','SAMSUNG_PAY','WECHAT_PAY','ALIPAY','PAYPAL','INTERAC','OTHER')),
  payment_network text check (payment_network in ('UNIONPAY','VISA','MASTERCARD','JCB','AMEX','INTERAC','OTHER')),
  recorded_by uuid references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(),
  primary key (journal_id, seq), check (payment_method is not null or payment_network is not null));
create trigger t_append_only before update or delete on bnx.payment_attribute for each row execute function bnx.trg_append_only();

create function bnx.cmd_set_payment_attribute(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; j uuid; s int; v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'set_payment_attribute', cmd); if rc is not null then return rc; end if;
  begin j := (cmd->>'journal_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'journal_id'); end;
  if j is null or not bnx.journal_counts_at(j, 9223372036854775807)
     or exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                 where jl.journal_id = j and not bnx.actor_can_post(a, ac.id))
     or not exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id where jl.journal_id = j) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.payment_attribute:' || j));
  s := coalesce((select max(seq) from bnx.payment_attribute where journal_id = j), 0) + 1;
  v := bnx.next_version();
  begin
    insert into bnx.payment_attribute(journal_id, seq, payment_method, payment_network, recorded_by, recorded_version)
    values (j, s, cmd->>'payment_method', cmd->>'payment_network', a.member_id, v);
  exception when check_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'payment_method or payment_network'); end;
  perform bnx.audit(a, 'set_payment_attribute', jsonb_build_object('journal_id', j, 'seq', s), cmd, v);
  return bnx.idem_end(a, 'set_payment_attribute', cmd, jsonb_build_object('journal_id', j, 'seq', s, 'ledger_version', v));
end $$;

-- ---------- cross-source matches (S2: one economic event seen by two sources; OR-I-11, AT-PAY-02, AT-COV-06) ----------
create table bnx.cross_source_match(
  id uuid primary key, primary_source_txn_id uuid not null references bnx.source_txn, supporting_source_txn_id uuid not null references bnx.source_txn,
  kind text not null check (kind in ('CARD_FUNDED_WALLET','EMAIL_NOTICE_VS_STATEMENT','WALLET_VS_BANK')),
  created_by uuid references bnx.member, recorded_version bigint not null, created_at timestamptz not null default now(),
  check (primary_source_txn_id <> supporting_source_txn_id));
create table bnx.cross_source_match_event(match_id uuid not null references bnx.cross_source_match, seq int not null,
  state text not null check (state in ('PROPOSED','CONFIRMED','REJECTED')), actor uuid references bnx.member,
  recorded_version bigint not null, recorded_at timestamptz not null default now(), primary key (match_id, seq));
create unique index cross_source_match_pair on bnx.cross_source_match(least(primary_source_txn_id, supporting_source_txn_id),
                                                                      greatest(primary_source_txn_id, supporting_source_txn_id));
create trigger t_append_only before update or delete on bnx.cross_source_match for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.cross_source_match_event for each row execute function bnx.trg_append_only();

-- propose (state PROPOSED) or decide (CONFIRMED / REJECTED) a cross-source match. The supporting row is evidence of the same
-- event and must never be posted as a second journal: confirming refuses a supporting row that is already linked to a journal.
create function bnx.cmd_cross_source_match(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; m bnx.cross_source_match; p bnx.source_txn; sp bnx.source_txn; st text := cmd->>'state';
        s int; v bigint; nid uuid; prev text;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'cross_source_match', cmd); if rc is not null then return rc; end if;
  begin select * into m from bnx.cross_source_match where id = (cmd->>'match_id')::uuid;
        select * into p from bnx.source_txn where id = coalesce(m.primary_source_txn_id, (cmd->>'primary_source_txn_id')::uuid);
        select * into sp from bnx.source_txn where id = coalesce(m.supporting_source_txn_id, (cmd->>'supporting_source_txn_id')::uuid);
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'match_id or source rows'); end;
  if p.id is null or sp.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, p.account_currency_id) or not bnx.actor_can_post(a, sp.account_currency_id) then
    perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if coalesce(st, '') not in ('PROPOSED','CONFIRMED','REJECTED') or (m.id is null and st <> 'PROPOSED')
     or (m.id is null and coalesce(cmd->>'kind', '') not in ('CARD_FUNDED_WALLET','EMAIL_NOTICE_VS_STATEMENT','WALLET_VS_BANK')) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'state or kind'); end if;
  if m.id is not null then
    select e.state, e.seq into prev, s from bnx.cross_source_match_event e where e.match_id = m.id order by e.seq desc limit 1;
    if prev <> 'PROPOSED' then perform bnx.fail('MATCH_STATE', 'P0409', prev || ' -> ' || st); end if;
  end if;
  if st = 'CONFIRMED' and bnx.source_link_at(sp.id, 9223372036854775807) is not null then
    perform bnx.fail('SUPPORTING_ROW_POSTED', 'P0409'); end if;
  v := bnx.next_version();
  if m.id is null then
    nid := gen_random_uuid();
    begin
      insert into bnx.cross_source_match(id, primary_source_txn_id, supporting_source_txn_id, kind, created_by, recorded_version)
      values (nid, p.id, sp.id, cmd->>'kind', a.member_id, v);
    exception when unique_violation then perform bnx.fail('ALREADY_MATCHED', 'P0409'); end;
    s := 1;
  else
    nid := m.id;
    s := s + 1;
  end if;
  insert into bnx.cross_source_match_event(match_id, seq, state, actor, recorded_version) values (nid, s, st, a.member_id, v);
  perform bnx.audit(a, 'cross_source_match', jsonb_build_object('match_id', nid, 'state', st), cmd, v);
  return bnx.idem_end(a, 'cross_source_match', cmd, jsonb_build_object('match_id', nid, 'state', st, 'ledger_version', v));
end $$;

-- ---------- matching MR-08...MR-13 (Draft-04 §C4.3) ----------
-- trigram similarity of two descriptions (lower case, words padded as pg_trgm does): |common| / |union|
create function bnx.text_similarity(a text, b text) returns numeric
language sql immutable set search_path = pg_catalog, pg_temp as $$
  with ta as (select distinct substr(w, i, 3) g from regexp_split_to_table(lower(regexp_replace(coalesce(a, ''), '[^[:alnum:]]+', ' ', 'g')), ' ') x,
                lateral (select '  ' || x || ' ' w) p, generate_series(1, greatest(length('  ' || x || ' ') - 2, 0)) i where x <> ''),
       tb as (select distinct substr(w, i, 3) g from regexp_split_to_table(lower(regexp_replace(coalesce(b, ''), '[^[:alnum:]]+', ' ', 'g')), ' ') x,
                lateral (select '  ' || x || ' ' w) p, generate_series(1, greatest(length('  ' || x || ' ') - 2, 0)) i where x <> '')
  select case when (select count(*) from (select g from ta union select g from tb) u) = 0 then 0
              else round((select count(*) from ta join tb using (g))::numeric / (select count(*) from (select g from ta union select g from tb) u), 4) end
$$;

-- a transfer-like description (§C4.3 MR-11/12; D-9012d-3)
create function bnx.transfer_like(d text) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select coalesce(d, '') ~* '\m(transfer|e-transfer|etransfer|xfer|tfr|virement|wire)\M|转账|轉帳' $$;

-- the ledger legs a row could match (same account-currency and amount, journal counting at v and not linked to any row, within
-- +/- 2 days) and, for one leg, the rows that could match it (same amount, not posted, within +/- 2 days)
create function bnx.match_leg_candidates(p_src uuid, p_v bigint) returns table(journal_line_id uuid, journal_id uuid, leg_date date, description text)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select jl.id, je.id, bnx.effective_posting_date(je.id, p_v), je.description
    from bnx.source_txn t join bnx.account_currency ac on ac.id = t.account_currency_id
    join bnx.journal_line jl on jl.ledger_account_id = ac.ledger_account_id and jl.amount = t.amount
    join bnx.journal_entry je on je.id = jl.journal_id
   where t.id = p_src and bnx.journal_counts_at(je.id, p_v) and abs(bnx.effective_posting_date(je.id, p_v) - t.posting_date) <= 2
     and not exists (select 1 from bnx.source_link_event e where e.journal_id = je.id and e.recorded_version <= p_v and e.event = 'linked'
                       and bnx.source_link_at(e.source_txn_id, p_v) = je.id)
     and not exists (select 1 from bnx.match_decision_current c join bnx.match_decision_event me on me.id = c.decision_event_id
                      where c.kind = 'ledger' and c.journal_line_id = jl.id and me.decision = 'confirmed' and c.source_txn_id <> p_src)
$$;
create function bnx.match_row_candidates(p_leg uuid, p_v bigint) returns setof uuid
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select t.id from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
    join bnx.source_txn t on t.account_currency_id = ac.id and t.amount = jl.amount
   where jl.id = p_leg and abs(t.posting_date - bnx.effective_posting_date(jl.journal_id, p_v)) <= 2 and bnx.source_link_at(t.id, p_v) is null
     and not exists (select 1 from bnx.match_decision_current c join bnx.match_decision_event me on me.id = c.decision_event_id
                      where c.source_txn_id = t.id and c.kind = 'ledger' and me.decision = 'confirmed' and c.journal_line_id <> p_leg)
$$;

-- the proposal for one row at version v: posted / ledger (MR-08 strong, MR-09 single, MR-10 ambiguous) / transfer pair (MR-11,
-- ambiguous when several) / clearing resolution (MR-13) / clearing_post or counterpart missing (MR-12) / new
create function bnx.match_propose(p_src uuid, p_v bigint) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare t bnx.source_txn; legs jsonb; nlegs int; leg record; nrows int; sim numeric; pairs jsonb; ci record; cov boolean;
begin
  select * into t from bnx.source_txn where id = p_src;
  if bnx.source_link_at(t.id, p_v) is not null then
    return jsonb_build_object('state', 'posted', 'journal_id', bnx.source_link_at(t.id, p_v)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('journal_line_id', c.journal_line_id, 'journal_id', c.journal_id, 'date', c.leg_date)
                            order by c.leg_date, c.journal_line_id), '[]'), count(*) into legs, nlegs
    from bnx.match_leg_candidates(t.id, p_v) c;
  if nlegs = 1 then
    select * into leg from bnx.match_leg_candidates(t.id, p_v);
    select count(*) into nrows from bnx.match_row_candidates(leg.journal_line_id, p_v);
    if nrows = 1 then
      sim := bnx.text_similarity(t.normalized_description, leg.description);
      if leg.leg_date = t.posting_date and sim >= 0.85 then
        return jsonb_build_object('state', 'ledger_match_confirmed', 'kind', 'ledger', 'rule', 'MR-08', 'journal_line_id', leg.journal_line_id,
                                  'journal_id', leg.journal_id, 'similarity', sim);
      end if;
      return jsonb_build_object('state', 'ledger_match_proposed', 'kind', 'ledger', 'rule', 'MR-09', 'journal_line_id', leg.journal_line_id,
                                'journal_id', leg.journal_id, 'similarity', sim);
    end if;
    return jsonb_build_object('state', 'ledger_match_ambiguous', 'kind', 'ledger', 'rule', 'MR-10', 'candidates', legs, 'competing_rows', nrows);
  elsif nlegs > 1 then
    return jsonb_build_object('state', 'ledger_match_ambiguous', 'kind', 'ledger', 'rule', 'MR-10', 'candidates', legs);
  end if;
  -- MR-13: an open clearing item hinting at this account-currency, opposite amount, within its window (default 10 days)
  for ci in select c.id, c.amount, (c.counterpart_hint->>'window_days')::int w, bnx.effective_posting_date(c.opened_journal, p_v) od
              from bnx.clearing_item c
             where c.counterpart_hint->>'account_currency_id' = t.account_currency_id::text and c.amount = -t.amount
               and bnx.journal_counts_at(c.opened_journal, p_v)
               and not exists (select 1 from bnx.clearing_item_event e where e.clearing_item_id = c.id and e.event = 'resolved' and e.recorded_version <= p_v)
             order by 4, 1 loop
    if abs(t.posting_date - ci.od) <= coalesce(ci.w, 10) then
      return jsonb_build_object('state', 'clearing_resolution_proposed', 'kind', 'clearing_resolution', 'rule', 'MR-13', 'clearing_item_id', ci.id);
    end if;
  end loop;
  if bnx.transfer_like(t.normalized_description) then
    -- MR-11: exactly one opposite, unposted row on another household account-currency of the same currency within +/- 5 days
    select coalesce(jsonb_agg(o.id order by o.posting_date, o.id), '[]') into pairs from bnx.source_txn o
      join bnx.account_currency oac on oac.id = o.account_currency_id
     where o.account_currency_id <> t.account_currency_id and oac.currency = t.currency and o.amount = -t.amount
       and abs(o.posting_date - t.posting_date) <= 5 and bnx.source_link_at(o.id, p_v) is null;
    if jsonb_array_length(pairs) = 1 then
      return jsonb_build_object('state', 'transfer_pair_proposed', 'kind', 'transfer_pair', 'rule', 'MR-11', 'counterpart_source_txn_id', pairs->>0);
    elsif jsonb_array_length(pairs) > 1 then
      return jsonb_build_object('state', 'transfer_pair_ambiguous', 'kind', 'transfer_pair', 'rule', 'MR-11', 'candidates', pairs);
    end if;
    -- MR-12: no counterpart row. If every other same-currency account-currency has final statement coverage on that date the
    -- counterpart is missing; otherwise the counterpart may sit in history not yet loaded -> clearing with a hint
    cov := not exists (select 1 from bnx.account_currency oac join bnx.account acc on acc.id = oac.account_id
                        where oac.id <> t.account_currency_id and oac.currency = t.currency
                          and not exists (select 1 from bnx.statement_period_at(p_v) s where s.account_currency_id = oac.id and s.final
                                            and t.posting_date between s.period_start and s.period_end));
    return jsonb_build_object('state', case when cov then 'transfer_counterpart_missing' else 'clearing_post' end, 'rule', 'MR-12');
  end if;
  return jsonb_build_object('state', 'new');
end $$;

-- record the current proposal of a row when it changed (append-only events; match_decision_current maintained in the same
-- transaction, §C4.9). MR-08 is recorded confirmed (automatic, reversible before plan approval); the rest proposed.
create function bnx.match_record(p_src uuid, p_prop jsonb, p_actor uuid, p_v bigint) returns boolean
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare k text := p_prop->>'kind'; cur record; eid uuid := gen_random_uuid(); dec text;
begin
  if k is null then return false; end if;
  select c.decision_event_id, me.rule_code, me.journal_line_id, me.counterpart_source_txn, me.clearing_item_id, me.decision, me.evidence,
         me.decided_by into cur
    from bnx.match_decision_current c join bnx.match_decision_event me on me.id = c.decision_event_id
   where c.source_txn_id = p_src and c.kind = k;
  if cur.decided_by is not null then return false; end if;                     -- member decisions stand (incl. a reversed MR-08)
  if cur.decision_event_id is not null and cur.rule_code = p_prop->>'rule' and cur.journal_line_id is not distinct from (p_prop->>'journal_line_id')::uuid
     and cur.counterpart_source_txn is not distinct from (p_prop->>'counterpart_source_txn_id')::uuid
     and cur.clearing_item_id is not distinct from (p_prop->>'clearing_item_id')::uuid and cur.evidence->>'state' = p_prop->>'state' then
    return false; end if;
  dec := case when p_prop->>'rule' = 'MR-08' then 'confirmed' else 'proposed' end;
  insert into bnx.match_decision_event(id, source_txn_id, kind, decision, counterpart_source_txn, journal_line_id, clearing_item_id, rule_code, evidence,
                                       supersedes, decided_by, recorded_version)
  values (eid, p_src, k, dec, (p_prop->>'counterpart_source_txn_id')::uuid,
          case when p_prop->>'state' <> 'ledger_match_ambiguous' then (p_prop->>'journal_line_id')::uuid end,
          (p_prop->>'clearing_item_id')::uuid, p_prop->>'rule', p_prop, cur.decision_event_id, p_actor, p_v);
  insert into bnx.match_decision_current(source_txn_id, kind, decision_event_id, journal_line_id)
  values (p_src, k, eid, case when p_prop->>'state' <> 'ledger_match_ambiguous' then (p_prop->>'journal_line_id')::uuid end)
  on conflict (source_txn_id, kind) do update set decision_event_id = excluded.decision_event_id, journal_line_id = excluded.journal_line_id;
  return true;
end $$;

-- RC-POST (tier 2): run the matcher over the rows of one account-currency in a date range
create function bnx.cmd_match_source_rows(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; acid uuid; d0 date; d1 date; vnow bigint; v bigint; t record; prop jsonb;
        counts jsonb := '{}'; n int := 0;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'match_source_rows', cmd); if rc is not null then return rc; end if;
  begin acid := (cmd->>'account_currency_id')::uuid; d0 := (cmd->>'date_from')::date; d1 := (cmd->>'date_to')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, date_from or date_to'); end;
  if acid is null or d0 is null or d1 is null or d1 < d0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'range'); end if;
  if not exists (select 1 from bnx.account_currency where id = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.match:' || acid));
  select version into vnow from bnx.ledger_state;
  v := bnx.next_version();
  for t in select s.id from bnx.source_txn s where s.account_currency_id = acid and s.posting_date between d0 and d1 order by s.posting_date, s.id loop
    prop := bnx.match_propose(t.id, vnow);
    counts := jsonb_set(counts, array[prop->>'state'], to_jsonb(coalesce((counts->>(prop->>'state'))::int, 0) + 1));
    if bnx.match_record(t.id, prop, null, v) then n := n + 1; end if;
  end loop;
  perform bnx.audit(a, 'match_source_rows', jsonb_build_object('account_currency_id', acid), cmd, v);
  return bnx.idem_end(a, 'match_source_rows', cmd, jsonb_build_object('by_state', counts, 'decisions_recorded', n, 'ledger_version', v));
end $$;

-- a member decision on a row's current proposal (§C4.6): confirm or reject; for MR-10 the member names the leg; MR-08 can be
-- reversed (rejected). An ambiguous transfer pair is confirmed by naming the counterpart row.
create function bnx.cmd_decide_match(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; t bnx.source_txn; k text := cmd->>'kind'; dec text := cmd->>'decision'; cur record;
        leg uuid; cp uuid; v bigint; eid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'decide_match', cmd); if rc is not null then return rc; end if;
  begin select * into t from bnx.source_txn where id = (cmd->>'source_txn_id')::uuid; leg := (cmd->>'journal_line_id')::uuid;
        cp := (cmd->>'counterpart_source_txn_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'source_txn_id, journal_line_id or counterpart_source_txn_id'); end;
  if t.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, t.account_currency_id) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if coalesce(dec, '') not in ('confirmed','rejected') or coalesce(k, '') not in ('ledger','transfer_pair','clearing_resolution') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'kind or decision'); end if;
  select me.* into cur from bnx.match_decision_current c join bnx.match_decision_event me on me.id = c.decision_event_id
   where c.source_txn_id = t.id and c.kind = k;
  if cur.id is null or (cur.decision <> 'proposed' and not (cur.rule_code = 'MR-08' and dec = 'rejected')) then
    perform bnx.fail('MATCH_STATE', 'P0409'); end if;
  if dec = 'confirmed' and cur.evidence->>'state' = 'ledger_match_ambiguous'
     and not exists (select 1 from jsonb_array_elements(cur.evidence->'candidates') x where (x->>'journal_line_id')::uuid = leg) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'an ambiguous match is confirmed by naming one candidate leg'); end if;
  if dec = 'confirmed' and cur.evidence->>'state' = 'transfer_pair_ambiguous'
     and not exists (select 1 from jsonb_array_elements_text(cur.evidence->'candidates') x where x::uuid = cp) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'an ambiguous pair is confirmed by naming one counterpart row'); end if;
  v := bnx.next_version();
  insert into bnx.match_decision_event(id, source_txn_id, kind, decision, counterpart_source_txn, journal_line_id, clearing_item_id, rule_code, evidence,
                                       supersedes, decided_by, recorded_version)
  values (eid, t.id, k, dec, coalesce(cp, cur.counterpart_source_txn), case when dec = 'confirmed' then coalesce(leg, cur.journal_line_id) end,
          cur.clearing_item_id, cur.rule_code, cur.evidence || jsonb_build_object('member_decision', dec), cur.id, a.member_id, v);
  begin
    update bnx.match_decision_current set decision_event_id = eid, journal_line_id = case when dec = 'confirmed' then coalesce(leg, cur.journal_line_id) end
     where source_txn_id = t.id and kind = k;
  exception when unique_violation then perform bnx.fail('LEG_ALREADY_MATCHED', 'P0409'); end;
  perform bnx.audit(a, 'decide_match', jsonb_build_object('source_txn_id', t.id, 'kind', k, 'decision', dec), cmd, v);
  return bnx.idem_end(a, 'decide_match', cmd, jsonb_build_object('decision_event_id', eid, 'decision', dec, 'ledger_version', v));
end $$;

-- OBJ-249 cmd_match_clearing: the member confirms that a row resolves an open clearing item (MR-13). The resolving journal is
-- posted through a plan as usual; this records the decision only.
create function bnx.cmd_match_clearing(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; t bnx.source_txn; c bnx.clearing_item; cur uuid; v bigint; eid uuid := gen_random_uuid();
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'match_clearing', cmd); if rc is not null then return rc; end if;
  begin select * into t from bnx.source_txn where id = (cmd->>'source_txn_id')::uuid;
        select * into c from bnx.clearing_item where id = (cmd->>'clearing_item_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'source_txn_id or clearing_item_id'); end;
  if t.id is null or c.id is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, t.account_currency_id) or not bnx.actor_can_post(a, c.account_currency_id) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if c.amount <> -t.amount or c.currency <> t.currency
     or exists (select 1 from bnx.clearing_item_event e where e.clearing_item_id = c.id and e.event = 'resolved') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'the row must be the opposite amount of an open clearing item'); end if;
  if exists (select 1 from bnx.match_decision_current mc join bnx.match_decision_event me on me.id = mc.decision_event_id
              where mc.kind = 'clearing_resolution' and me.clearing_item_id = c.id and me.decision = 'confirmed' and mc.source_txn_id <> t.id) then
    perform bnx.fail('ALREADY_MATCHED', 'P0409'); end if;
  select decision_event_id into cur from bnx.match_decision_current where source_txn_id = t.id and kind = 'clearing_resolution';
  v := bnx.next_version();
  insert into bnx.match_decision_event(id, source_txn_id, kind, decision, clearing_item_id, rule_code, evidence, supersedes, decided_by, recorded_version)
  values (eid, t.id, 'clearing_resolution', 'confirmed', c.id, 'MR-13', jsonb_build_object('state', 'clearing_resolution_confirmed'), cur, a.member_id, v);
  insert into bnx.match_decision_current(source_txn_id, kind, decision_event_id, journal_line_id) values (t.id, 'clearing_resolution', eid, null)
  on conflict (source_txn_id, kind) do update set decision_event_id = excluded.decision_event_id;
  perform bnx.audit(a, 'match_clearing', jsonb_build_object('source_txn_id', t.id, 'clearing_item_id', c.id), cmd, v);
  return bnx.idem_end(a, 'match_clearing', cmd, jsonb_build_object('decision_event_id', eid, 'ledger_version', v));
end $$;

-- OBJ-249 q_transfer_matching: the current decision of every row of one account-currency in a range at version V
create function bnx.q_transfer_matching(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); acid uuid; d0 date; d1 date; v bigint; vnow bigint;
begin
  perform bnx.require(a, 0);
  begin acid := (q->>'account_currency_id')::uuid; d0 := coalesce((q->>'date_from')::date, '-infinity'); d1 := coalesce((q->>'date_to')::date, 'infinity');
        v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id, dates or ledger_version'); end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  if not exists (select 1 from bnx.actor_visible_acs(a) x where x = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  perform bnx.pol_require_module_for_ac(acid);
  return jsonb_build_object('account_currency_id', acid, 'ledger_version', v, 'rows', coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('source_txn_id', t.id, 'posting_date', t.posting_date, 'amount', t.amount::text,
             'posted_journal_id', bnx.source_link_at(t.id, v),
             'decisions', (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('kind', d.kind, 'decision', d.decision, 'rule', d.rule_code,
                                   'state', d.evidence->>'state', 'journal_line_id', d.journal_line_id, 'counterpart_source_txn_id', d.counterpart_source_txn,
                                   'clearing_item_id', d.clearing_item_id, 'candidates', d.evidence->'candidates')) order by d.kind)
                           from (select distinct on (me.kind) me.* from bnx.match_decision_event me
                                  where me.source_txn_id = t.id and me.recorded_version <= v order by me.kind, me.recorded_version desc, me.recorded_at desc) d)))
             order by t.posting_date, t.id)
      from bnx.source_txn t where t.account_currency_id = acid and t.posting_date between d0 and d1), '[]'));
end $$;

-- ---------- onboarding (Draft-04 §C5; UA V1.2 names onboarding_job, source_file_state, account_history_state) ----------
create table bnx.onboarding_job(
  id uuid primary key, kind text not null check (kind in ('history_onboarding','periodic_import')),
  title text not null check (title ~ '^[[:alnum:]][[:alnum:] ._()/-]{0,79}$'),
  scope jsonb not null check (jsonb_typeof(scope) = 'object'), created_by uuid not null references bnx.member,
  created_via text not null check (created_via in ('pwa','mcp')), recorded_version bigint not null, created_at timestamptz not null default now(),
  check (scope->>'start_policy' in ('earliest_evidence','household_start_date','manual')),
  check ((scope->>'start_policy' = 'household_start_date') = (scope ? 'household_start_date')));
create table bnx.onboarding_job_event(job_id uuid not null references bnx.onboarding_job, seq int not null,
  event text not null check (event in ('created','collection_closed','paused','resumed','cancelled')),
  actor uuid references bnx.member, recorded_version bigint not null, recorded_at timestamptz not null default now(), primary key (job_id, seq));
create table bnx.source_file_state(job_id uuid not null references bnx.onboarding_job, evidence_object_id uuid not null references bnx.evidence_object,
  seq int not null, state text not null check (state in ('SF-QUEUED','SF-CLASSIFIED','SF-DUPLICATE_FILE','SF-NOT_STATEMENT','SF-UNSUPPORTED',
                                                         'SF-ASSIGNED','SF-EXTRACTED','SF-STAGED','SF-DONE','SF-FAILED','SF-DEAD')),
  attempts int not null default 0, detail jsonb, actor uuid references bnx.member, recorded_version bigint not null,
  recorded_at timestamptz not null default now(), primary key (job_id, evidence_object_id, seq));
create table bnx.account_history_state(job_id uuid not null references bnx.onboarding_job, account_currency_id uuid not null references bnx.account_currency,
  seq int not null, state text not null check (state in ('AH-PROPOSED','AH-APPROVED','AH-ORDERED','AH-EXTRACTED','AH-MATCHED','AH-CLASSIFIED',
                                                         'AH-READY','AH-PLANNED','AH-PLAN_APPROVED','AH-POSTING','AH-ACTIVE','AH-RECONCILED',
                                                         'AH-RECONCILED_WITH_EXCEPTIONS','AH-BLOCKED','AH-EXCLUDED')),
  coverage jsonb, anchor_plan jsonb, plan_id uuid references bnx.posting_plan, actor uuid references bnx.member,
  recorded_version bigint not null, recorded_at timestamptz not null default now(), primary key (job_id, account_currency_id, seq));
alter table bnx.posting_plan add constraint posting_plan_job_fk foreign key (job_id) references bnx.onboarding_job;   -- UA V1.2 §5.6
create trigger t_append_only before update or delete on bnx.onboarding_job for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.onboarding_job_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.source_file_state for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.account_history_state for each row execute function bnx.trg_append_only();

-- allowed transitions (§C5.3 SF-*, §C5.4 AH-*); restore replays are exempt
create function bnx.trg_onboarding_transition() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev text; s int; ok boolean;
begin
  if bnx.restore_mode() then return new; end if;
  if tg_table_name = 'source_file_state' then
    select x.state, x.seq into prev, s from bnx.source_file_state x where x.job_id = new.job_id and x.evidence_object_id = new.evidence_object_id
     order by x.seq desc limit 1;
    ok := case coalesce(prev, '')
      when '' then new.state = 'SF-QUEUED'
      when 'SF-QUEUED' then new.state in ('SF-CLASSIFIED','SF-DUPLICATE_FILE','SF-NOT_STATEMENT','SF-UNSUPPORTED','SF-FAILED')
      when 'SF-CLASSIFIED' then new.state in ('SF-ASSIGNED','SF-FAILED')
      when 'SF-ASSIGNED' then new.state in ('SF-EXTRACTED','SF-FAILED')
      when 'SF-EXTRACTED' then new.state in ('SF-STAGED','SF-FAILED')
      when 'SF-STAGED' then new.state in ('SF-DONE','SF-FAILED')
      when 'SF-FAILED' then new.state in ('SF-QUEUED','SF-DEAD')
      else false end;
    if ok and new.state = 'SF-DEAD' and new.attempts < 3 then ok := false; end if;     -- dead after 3 attempts
  else
    select x.state, x.seq into prev, s from bnx.account_history_state x where x.job_id = new.job_id and x.account_currency_id = new.account_currency_id
     order by x.seq desc limit 1;
    ok := new.state in ('AH-BLOCKED','AH-EXCLUDED') and prev is not null and prev not in ('AH-EXCLUDED','AH-RECONCILED','AH-RECONCILED_WITH_EXCEPTIONS')
       or case coalesce(prev, '')
      when '' then new.state = 'AH-PROPOSED'
      when 'AH-PROPOSED' then new.state = 'AH-APPROVED'
      when 'AH-APPROVED' then new.state = 'AH-ORDERED'
      when 'AH-ORDERED' then new.state = 'AH-EXTRACTED'
      when 'AH-EXTRACTED' then new.state = 'AH-MATCHED'
      when 'AH-MATCHED' then new.state = 'AH-CLASSIFIED'
      when 'AH-CLASSIFIED' then new.state = 'AH-READY'
      when 'AH-READY' then new.state = 'AH-PLANNED'
      when 'AH-PLANNED' then new.state in ('AH-PLAN_APPROVED','AH-READY')
      when 'AH-PLAN_APPROVED' then new.state = 'AH-POSTING'
      when 'AH-POSTING' then new.state in ('AH-ACTIVE','AH-READY')
      when 'AH-ACTIVE' then new.state in ('AH-RECONCILED','AH-RECONCILED_WITH_EXCEPTIONS')
      when 'AH-BLOCKED' then new.state in ('AH-READY','AH-ORDERED','AH-MATCHED','AH-CLASSIFIED')
      else false end;
  end if;
  if not ok or new.seq <> coalesce(s, 0) + 1 then
    raise exception 'ONBOARDING_STATE' using errcode = 'P0409', detail = coalesce(prev, 'none') || ' -> ' || new.state;
  end if;
  return new;
end $$;
create trigger t_onboarding_transition before insert on bnx.source_file_state for each row execute function bnx.trg_onboarding_transition();
create trigger t_onboarding_transition before insert on bnx.account_history_state for each row execute function bnx.trg_onboarding_transition();

-- the job state (§C5.2), derived from its events and item states at version v
create function bnx.onboarding_state_at(p_job uuid, p_v bigint) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with ev as (select e.event from bnx.onboarding_job_event e where e.job_id = p_job and e.recorded_version <= p_v order by e.seq desc limit 1),
       sf as (select distinct on (x.evidence_object_id) x.state from bnx.source_file_state x where x.job_id = p_job and x.recorded_version <= p_v
               order by x.evidence_object_id, x.seq desc),
       ah as (select distinct on (x.account_currency_id) x.state from bnx.account_history_state x where x.job_id = p_job and x.recorded_version <= p_v
               order by x.account_currency_id, x.seq desc),
       closed as (select exists (select 1 from bnx.onboarding_job_event e where e.job_id = p_job and e.event = 'collection_closed' and e.recorded_version <= p_v) c)
  select case
    when (select event from ev) = 'cancelled' then 'ONB-CANCELLED'
    when (select event from ev) = 'paused' then 'ONB-PAUSED'
    when not exists (select 1 from sf) and not exists (select 1 from ah) then 'ONB-DRAFT'
    when exists (select 1 from ah) and not exists (select 1 from ah where state not in ('AH-RECONCILED','AH-RECONCILED_WITH_EXCEPTIONS','AH-EXCLUDED'))
         and (select c from closed) then
      case when exists (select 1 from ah where state = 'AH-RECONCILED_WITH_EXCEPTIONS') then 'ONB-COMPLETED_WITH_EXCEPTIONS' else 'ONB-COMPLETED' end
    when exists (select 1 from ah where state = 'AH-ACTIVE') then 'ONB-RECONCILING'
    when exists (select 1 from ah where state in ('AH-PLAN_APPROVED','AH-POSTING')) then 'ONB-POSTING'
    when exists (select 1 from ah where state = 'AH-PLANNED') then 'ONB-PLANNED'
    when exists (select 1 from ah where state in ('AH-PROPOSED','AH-BLOCKED','AH-READY')) then 'ONB-REVIEW'   -- a member decision is next
    when exists (select 1 from sf where state in ('SF-QUEUED','SF-CLASSIFIED','SF-ASSIGNED','SF-EXTRACTED','SF-FAILED'))
      or exists (select 1 from ah where state in ('AH-APPROVED','AH-ORDERED','AH-EXTRACTED','AH-MATCHED','AH-CLASSIFIED')) then
      case when not (select c from closed) and not exists (select 1 from ah) then 'ONB-COLLECTING' else 'ONB-PROCESSING' end
    when not (select c from closed) then 'ONB-COLLECTING'
    else 'ONB-PROCESSING' end
$$;

-- the job's creator, or an owner or admin, may act on a job
create function bnx.onboarding_admin(a bnx.actor) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select m.role in ('owner','admin') from bnx.member m where m.id = a.member_id), false) $$;

-- member commands (PWA or MCP propose channel creates; tier 2 for every change). One command per §C5 member action.
create function bnx.cmd_onboarding_create_job(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; nid uuid := gen_random_uuid(); sc jsonb := cmd->'scope';
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'onboarding_create_job', cmd); if rc is not null then return rc; end if;
  if jsonb_typeof(sc) is distinct from 'object'
     or exists (select 1 from jsonb_object_keys(sc) k where k not in ('start_policy','household_start_date','account_overrides','clearing_defaults'))
     or (sc ? 'household_start_date' and (sc->>'household_start_date') !~ '^\d{4}-\d{2}-\d{2}$') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'scope'); end if;
  v := bnx.next_version();
  begin
    insert into bnx.onboarding_job(id, kind, title, scope, created_by, created_via, recorded_version)
    values (nid, coalesce(cmd->>'kind', 'history_onboarding'), cmd->>'title', sc, a.member_id, 'pwa', v);
  exception when check_violation or not_null_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'kind, title or start_policy'); end;
  insert into bnx.onboarding_job_event values (nid, 1, 'created', a.member_id, v);
  perform bnx.audit(a, 'onboarding_create_job', jsonb_build_object('job_id', nid), cmd, v);
  return bnx.idem_end(a, 'onboarding_create_job', cmd, jsonb_build_object('job_id', nid, 'ledger_version', v));
end $$;

-- add a stored file to a job (SF-QUEUED); a file already queued in any job is MR-01 (same SHA-256) -> SF-DUPLICATE_FILE path
create function bnx.cmd_onboarding_add_file(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; job bnx.onboarding_job; eo uuid; v bigint; st text;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'onboarding_add_file', cmd); if rc is not null then return rc; end if;
  begin select * into job from bnx.onboarding_job where id = (cmd->>'job_id')::uuid; eo := (cmd->>'evidence_object_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'job_id or evidence_object_id'); end;
  if job.id is null or job.created_by <> a.member_id and not bnx.onboarding_admin(a) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not exists (select 1 from bnx.evidence_object where id = eo) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if exists (select 1 from bnx.onboarding_job_event e where e.job_id = job.id and e.event in ('collection_closed','cancelled')) then
    perform bnx.fail('COLLECTION_CLOSED', 'P0409'); end if;
  if exists (select 1 from bnx.source_file_state x where x.job_id = job.id and x.evidence_object_id = eo) then perform bnx.fail('ALREADY_ADDED', 'P0409'); end if;
  v := bnx.next_version();
  insert into bnx.source_file_state(job_id, evidence_object_id, seq, state, actor, recorded_version) values (job.id, eo, 1, 'SF-QUEUED', a.member_id, v);
  st := bnx.onboarding_state_at(job.id, v);
  perform bnx.audit(a, 'onboarding_add_file', jsonb_build_object('job_id', job.id, 'evidence_object_id', eo), cmd, v);
  return bnx.idem_end(a, 'onboarding_add_file', cmd, jsonb_build_object('job_state', st, 'ledger_version', v));
end $$;

-- job events: close collection, pause, resume, cancel
create function bnx.cmd_onboarding_job_event(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; job bnx.onboarding_job; ev text := cmd->>'event'; last text; s int; v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'onboarding_job_event', cmd); if rc is not null then return rc; end if;
  begin select * into job from bnx.onboarding_job where id = (cmd->>'job_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'job_id'); end;
  if job.id is null or job.created_by <> a.member_id and not bnx.onboarding_admin(a) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  select e.event, e.seq into last, s from bnx.onboarding_job_event e where e.job_id = job.id order by e.seq desc limit 1;
  if coalesce(ev, '') not in ('collection_closed','paused','resumed','cancelled') or last = 'cancelled'
     or (ev = 'resumed' and last <> 'paused') or (ev = 'paused' and last = 'paused')
     or (ev = 'collection_closed' and exists (select 1 from bnx.onboarding_job_event e where e.job_id = job.id and e.event = 'collection_closed')) then
    perform bnx.fail('ONBOARDING_STATE', 'P0409', coalesce(last, 'none') || ' -> ' || coalesce(ev, '')); end if;
  v := bnx.next_version();
  insert into bnx.onboarding_job_event values (job.id, s + 1, ev, a.member_id, v);
  perform bnx.audit(a, 'onboarding_job_event', jsonb_build_object('job_id', job.id, 'event', ev), cmd, v);
  return bnx.idem_end(a, 'onboarding_job_event', cmd, jsonb_build_object('job_state', bnx.onboarding_state_at(job.id, v), 'ledger_version', v));
end $$;

-- a history step: the member proposes, approves, excludes or unblocks an account-currency history; the worker records the
-- deterministic stages (wrk_onboarding_step) - both go through the same transition trigger
create function bnx.onboarding_step(p_job uuid, p_kind text, p_subject uuid, p_state text, p_detail jsonb, p_actor uuid) returns bigint
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare v bigint := bnx.next_version(); s int;
begin
  if p_kind = 'file' then
    s := coalesce((select max(seq) from bnx.source_file_state where job_id = p_job and evidence_object_id = p_subject), 0) + 1;
    insert into bnx.source_file_state(job_id, evidence_object_id, seq, state, attempts, detail, actor, recorded_version)
    values (p_job, p_subject, s, p_state, coalesce((p_detail->>'attempts')::int,
            (select attempts from bnx.source_file_state where job_id = p_job and evidence_object_id = p_subject order by seq desc limit 1), 0)
            + case when p_state = 'SF-FAILED' then 1 else 0 end, p_detail, p_actor, v);
  else
    s := coalesce((select max(seq) from bnx.account_history_state where job_id = p_job and account_currency_id = p_subject), 0) + 1;
    insert into bnx.account_history_state(job_id, account_currency_id, seq, state, coverage, anchor_plan, plan_id, actor, recorded_version)
    values (p_job, p_subject, s, p_state, p_detail->'coverage', p_detail->'anchor_plan', (p_detail->>'plan_id')::uuid, p_actor, v);
  end if;
  return v;
end $$;

create function bnx.cmd_onboarding_history(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; job bnx.onboarding_job; acid uuid; st text := cmd->>'state'; v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'onboarding_history', cmd); if rc is not null then return rc; end if;
  begin select * into job from bnx.onboarding_job where id = (cmd->>'job_id')::uuid; acid := (cmd->>'account_currency_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'job_id or account_currency_id'); end;
  if job.id is null or job.created_by <> a.member_id and not bnx.onboarding_admin(a) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not exists (select 1 from bnx.account_currency where id = acid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if coalesce(st, '') not in ('AH-PROPOSED','AH-APPROVED','AH-EXCLUDED','AH-READY') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'members propose, approve, exclude or unblock (AH-READY from AH-BLOCKED)'); end if;
  if st = 'AH-READY' and (select x.state from bnx.account_history_state x where x.job_id = job.id and x.account_currency_id = acid
                           order by x.seq desc limit 1) is distinct from 'AH-BLOCKED' then
    perform bnx.fail('ONBOARDING_STATE', 'P0409'); end if;
  v := bnx.onboarding_step(job.id, 'history', acid, st, jsonb_strip_nulls(jsonb_build_object('coverage', cmd->'coverage')), a.member_id);
  perform bnx.audit(a, 'onboarding_history', jsonb_build_object('job_id', job.id, 'account_currency_id', acid, 'state', st), cmd, v);
  return bnx.idem_end(a, 'onboarding_history', cmd, jsonb_build_object('job_state', bnx.onboarding_state_at(job.id, v), 'ledger_version', v));
end $$;

create function bnx.wrk_onboarding_step(p_job uuid, p_kind text, p_subject uuid, p_state text, p_detail jsonb default null) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare v bigint;
begin
  if p_kind not in ('file','history') or (p_kind = 'history' and p_state in ('AH-PROPOSED','AH-APPROVED','AH-EXCLUDED')) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'the worker records deterministic stages only'); end if;
  if not exists (select 1 from bnx.onboarding_job where id = p_job) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if exists (select 1 from bnx.onboarding_job_event e where e.job_id = p_job and e.event = 'cancelled')
     or (select e.event from bnx.onboarding_job_event e where e.job_id = p_job order by e.seq desc limit 1) = 'paused' then
    perform bnx.fail('ONBOARDING_STATE', 'P0409', 'job paused or cancelled'); end if;
  v := bnx.onboarding_step(p_job, p_kind, p_subject, p_state, p_detail, null);
  return jsonb_build_object('job_state', bnx.onboarding_state_at(p_job, v), 'ledger_version', v);
end $$;

-- §C5.5 progress: counters computed from the tables, never from conversation memory
create function bnx.q_onboarding_job(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); job bnx.onboarding_job; v bigint; vnow bigint;
begin
  perform bnx.require(a, 0);
  begin select * into job from bnx.onboarding_job where id = (q->>'job_id')::uuid; v := (q->>'ledger_version')::bigint;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'job_id or ledger_version'); end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if job.id is null or v > vnow or v < job.recorded_version or (job.created_by <> a.member_id and not bnx.onboarding_admin(a)) then
    perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  return jsonb_build_object('job_id', job.id, 'kind', job.kind, 'title', job.title, 'scope', job.scope, 'ledger_version', v,
    'state', bnx.onboarding_state_at(job.id, v),
    'files_by_state', coalesce((select jsonb_object_agg(s, n) from (select x.state s, count(*) n from (select distinct on (f.evidence_object_id) f.state
                        from bnx.source_file_state f where f.job_id = job.id and f.recorded_version <= v order by f.evidence_object_id, f.seq desc) x
                        group by x.state) y), '{}'),
    'histories', coalesce((select jsonb_agg(jsonb_build_object('account_currency_id', x.account_currency_id, 'state', x.state, 'plan_id', x.plan_id)
                        order by x.account_currency_id)
                        from (select distinct on (h.account_currency_id) h.* from bnx.account_history_state h
                               where h.job_id = job.id and h.recorded_version <= v
                                 and h.account_currency_id in (select bnx.actor_visible_acs(a)) order by h.account_currency_id, h.seq desc) x), '[]'),
    'plans', coalesce((select jsonb_agg(jsonb_build_object('plan_id', p.id, 'kind', p.kind) order by p.id) from bnx.posting_plan p where p.job_id = job.id), '[]'),
    'source_rows_by_match_state', coalesce((select jsonb_object_agg(s, n) from (select coalesce(me.evidence->>'state', 'new') s, count(*) n
                        from bnx.account_history_state h0 join bnx.source_txn t on t.account_currency_id = h0.account_currency_id
                        left join bnx.match_decision_current c on c.source_txn_id = t.id and c.kind = 'ledger'
                        left join bnx.match_decision_event me on me.id = c.decision_event_id
                       where h0.job_id = job.id and h0.seq = 1 and h0.account_currency_id in (select bnx.actor_visible_acs(a)) group by 1) y), '{}'));
end $$;

-- module flags: the account-scoped onboarding table; catalog rows for the queries
insert into bnx.flag_enforcement_point values ('account_history_state','account_currency_id','INSERT','9012','bnx');
create trigger t_scope_flag_account_history_state before insert on bnx.account_history_state
  for each row execute function bnx.trg_scope_flag('account_currency_id');
insert into bnx.table_class values ('import_mapping','F'), ('payment_attribute','F'), ('cross_source_match','E'), ('cross_source_match_event','F'),
 ('onboarding_job','E'), ('onboarding_job_event','F'), ('source_file_state','F'), ('account_history_state','F');
insert into bnx.function_scope values
 ('q_transfer_matching', 'finance.read', false, false, true, 'fin.matching.transfers'),
 ('q_onboarding_job', 'finance.read', false, false, false, 'fin.onboarding.job');

select bnx.apply_grants();
