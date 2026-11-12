-- 9013_s4_report_families_snapshot_status.sql -- S4 V1.2 report families, snapshot status and artifacts (UA V1.2 §5.8; OBJ-027,
-- OBJ-216, OBJ-250, OBJ-251, OBJ-374). Expand-only.
--   NEW: bnx.report_definition (versioned; R-BAL/1 is the R1 definition), the family queries q_f1_balances ... q_f7_reconciliation,
--        q_cashflow_statement (R09), q_r30_review_queue (R30; the 9010 q_review_queue of plans stays), q_evidence_trace (R31), bnx.report_snapshot_artifact (append-only) written by
--        wrk_snapshot_artifact, q_snapshot_status (CURRENT / STALE / ACCESS_REVOKED), q_snapshot_list, q_snapshot_artifact.
--   MODIFY: bnx.cmd_create_report_snapshot (0107): the requested account-currencies pass pol_scope_filter before balance_rows; the
--        definition version comes from report_definition. bnx.report_snapshot and bnx.balance_rows are untouched (S4B-F04).
-- Every family result carries ledger_version, as_of, reporting_currency, fx_policy, fx_snapshot_ref, grants_digest,
-- scope_warnings[] and evidence_refs[]; amounts are decimal strings; unlike currencies are never summed (OR-R-02).

-- ---------- report definitions (versioned) ----------
create table bnx.report_definition(report_id text not null check (report_id ~ '^(R-BAL|F[1-7]|R09|R28|R30|R31)$'), version int not null,
  query_function text not null, parameters_schema jsonb not null check (jsonb_typeof(parameters_schema) = 'object'),
  crosswalk text[] not null, recorded_version bigint not null default 0, primary key (report_id, version));
create trigger t_append_only before update or delete on bnx.report_definition for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('report_definition','E');
insert into bnx.report_definition(report_id, version, query_function, parameters_schema, crosswalk) values
 ('R-BAL', 1, 'bnx.balance_rows', '{"as_of":"date","account_currency_ids":"uuid[]"}', '{R03}'),
 ('F1', 1, 'bnx.q_f1_balances', '{"as_of":"date","ledger_version":"int","reporting_currency":"char(3)","account_currency_ids":"uuid[]"}', '{R03,R11,R16,R27,R33}'),
 ('F2', 1, 'bnx.q_f2_transactions', '{"date_from":"date","date_to":"date","account_currency_id":"uuid","ledger_version":"int","limit":"int"}', '{R12,R09,R18,R24}'),
 ('F3', 1, 'bnx.q_f3_income_expense', '{"date_from":"date","date_to":"date","ledger_version":"int"}', '{R05,R06,R07,R08,R09,R18}'),
 ('F4', 1, 'bnx.q_f4_investments', '{"as_of":"date","date_from":"date","ledger_version":"int","reporting_currency":"char(3)"}', '{R22,R23,R24,R25,R33}'),
 ('F5', 1, 'bnx.q_f5_networth', '{"as_of":"date","ledger_version":"int","reporting_currency":"char(3)"}', '{R01,R02,R04,R16,R27,R28,R33}'),
 ('F6', 1, 'bnx.q_f6_cards', '{"as_of":"date","ledger_version":"int"}', '{R17,R19,R20,R21}'),
 ('F7', 1, 'bnx.q_f7_reconciliation', '{"account_currency_id":"uuid","ledger_version":"int"}', '{R13,R14,R15}'),
 ('R09', 1, 'bnx.q_cashflow_statement', '{"date_from":"date","date_to":"date","ledger_version":"int"}', '{R09}'),
 ('R28', 1, 'bnx.q_r28_loan_position', '{"loan_id":"uuid","as_of":"date","ledger_version":"int"}', '{R28}'),
 ('R30', 1, 'bnx.q_r30_review_queue', '{}', '{R30}'),
 ('R31', 1, 'bnx.q_evidence_trace', '{"journal_id":"uuid","source_txn_id":"uuid"}', '{R31}');
insert into bnx.migration_seeded_table values ('bnx.report_definition', '9013', 'report families F1-F7, R09, R28, R30, R31 and the R1 R-BAL/1');

-- ---------- common parts ----------
-- the ledger version a query asks for (default current), validated
create function bnx.rpt_version(q jsonb) returns bigint
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare v bigint; vnow bigint;
begin
  begin v := (q->>'ledger_version')::bigint; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end;
  select version into vnow from bnx.ledger_state;
  v := coalesce(v, vnow);
  if v < 0 or v > vnow then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  return v;
end $$;

-- the common envelope (UA V1.2 §5.8.1)
create function bnx.rpt_envelope(a bnx.actor, p_v bigint, p_as_of date, p_rc text, p_warn text[]) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('ledger_version', p_v, 'as_of', p_as_of, 'reporting_currency', p_rc,
    'fx_policy', case when p_rc is null then 'native (no conversion)'
                      else 'bnx.fx_rate_at: OVERRIDE > EVIDENCED_SETTLEMENT > REFERENCE (STALE after 7 days) > MISSING' end,
    'fx_snapshot_ref', 'fx@' || greatest(coalesce((select max(recorded_version) from bnx.fx_quote where recorded_version <= p_v), 0),
                                         coalesce((select max(recorded_version) from bnx.fx_override_event where recorded_version <= p_v), 0)),
    'grants_digest', encode(bnx.h(coalesce((select string_agg(x::text, ',' order by x::text) from bnx.actor_visible_acs(a) x), '')), 'hex'),
    'scope_warnings', coalesce((select to_jsonb(array_agg(distinct w order by w)) from unnest(p_warn) w), '[]'::jsonb),
    'rounding', 'HALF_EVEN at output; exact numeric before')
$$;

-- a journal is shown to an actor only when every account line of it (asset or liability on an account-currency) is visible;
-- category, equity, clearing and FX lines carry no account (AT-GRANT-01: a private account is absent from totals)
create function bnx.rpt_journal_visible(a bnx.actor, p_journal uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id where jl.journal_id = p_journal)
     and not exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                      where jl.journal_id = p_journal and ac.id not in (select bnx.actor_visible_acs(a)))
$$;

-- convert at the as-of rate; null when the rate is missing
create function bnx.rpt_convert(p_amount numeric, p_from text, p_to text, p_date date, p_v bigint) returns numeric
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select p_amount * ((bnx.fx_rate_at(p_from, p_to, p_date, p_v))->>'rate')::numeric $$;

-- ---------- F1 balances (R03, R11, R16, R27, R33) ----------
-- one row per visible account-currency: institution, account, holders (verified ownership at as_of; none -> unknown), native
-- balance at (as_of, V), the latest final statement closing as a separate evidence column (never merged), and the
-- reporting-currency value with its rate quality. Grouping is by the internal account id only (R11: never by suffix or name).
create function bnx.q_f1_balances(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d date; rc text := q->>'reporting_currency'; rmu int; req uuid[]; r record;
        b bnx.balance_result; fx jsonb; rws jsonb := '[]'; warn text[] := '{}'; conv numeric; tot_rc numeric := 0; rc_ok boolean := true;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d := coalesce((q->>'as_of')::date, current_date);
        req := case when q ? 'account_currency_ids' then array(select x::uuid from jsonb_array_elements_text(q->'account_currency_ids') x) end;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of or account_currency_ids'); end;
  if rc is not null then select minor_units into rmu from bnx.currency where code = rc;
    if rmu is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'reporting_currency'); end if; end if;
  if req is not null and not (req <@ array(select bnx.actor_visible_acs(a))) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  for r in select ac.id acid, ac.currency, acc.id account_id, acc.kind, acc.label, acc.state, i.name_en inst, cu.minor_units mu
             from bnx.actor_visible_acs(a) x join bnx.account_currency ac on ac.id = x join bnx.account acc on acc.id = ac.account_id
             left join bnx.institution i on i.id = acc.institution_id join bnx.currency cu on cu.code = ac.currency
            where req is null or ac.id = any(req)
            order by i.name_en nulls last, acc.label, acc.id, ac.currency loop
    b := bnx.balance_at(r.acid, d, v);
    conv := null; fx := null;
    if rc is not null and b.status = 'ok' then
      fx := bnx.fx_rate_at(r.currency, rc, d, v); conv := b.amount * (fx->>'rate')::numeric;
      if conv is null then rc_ok := false; warn := array_append(warn, 'FX_MISSING'::text); else tot_rc := tot_rc + conv; end if;
      if fx->>'quality' = 'STALE' then warn := array_append(warn, 'FX_STALE'::text); end if;
    elsif rc is not null then rc_ok := false;
    end if;
    if b.status <> 'ok' then warn := array_append(warn, 'BALANCE_' || b.status); end if;
    rws := rws || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('account_currency_id', r.acid, 'account_id', r.account_id,
      'institution', r.inst, 'account_label', r.label, 'account_kind', r.kind, 'account_state', r.state, 'currency', r.currency,
      'holders', coalesce((select jsonb_agg(jsonb_build_object('party_id', o.party_id, 'kind', o.kind, 'share', o.share::text) order by o.kind, o.party_id)
                           from bnx.ownership_at(r.account_id, d, v) o), '"unknown"'::jsonb),
      'status', b.status, 'balance', bnx.fin_money(b.amount, r.mu),
      'latest_statement', (select jsonb_build_object('statement_id', s.statement_id, 'period_end', s.period_end, 'closing_balance', s.closing_balance::text,
                                                     'sign_convention', s.sign_convention)
                             from bnx.statement_period_at(v) s where s.account_currency_id = r.acid and s.final and s.period_end <= d
                            order by s.period_end desc limit 1),
      'reporting', case when rc is not null then jsonb_build_object('currency', rc, 'value', bnx.fin_money(conv, rmu), 'rate', fx->>'rate',
                                                                    'rate_quality', fx->>'quality', 'rate_date', fx->>'rate_date') end)));
  end loop;
  return bnx.rpt_envelope(a, v, d, rc, warn) || jsonb_build_object('report', 'F1/1', 'rows', rws,
    'totals_by_currency', coalesce((select jsonb_object_agg(c, t) from (select x->>'currency' c, sum((x->>'balance')::numeric)::text t
                                      from jsonb_array_elements(rws) x where x->>'status' = 'ok' group by 1) y), '{}'),
    'total_reporting', case when rc is not null and rc_ok then bnx.fin_money(tot_rc, rmu) end, 'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- F2 transactions (R12 ledger with provenance; calendar aggregates for OR-U-03) ----------
create function bnx.q_f2_transactions(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d0 date; d1 date; acid uuid; lim int; rws jsonb; vis uuid[];
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d0 := (q->>'date_from')::date; d1 := (q->>'date_to')::date; acid := (q->>'account_currency_id')::uuid; lim := coalesce((q->>'limit')::int, 500);
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'date_from, date_to, account_currency_id or limit'); end;
  if d0 is null or d1 is null or d1 < d0 or lim not between 1 and 5000 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'range or limit'); end if;
  vis := array(select bnx.actor_visible_acs(a));
  if acid is not null and not acid = any(vis) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  with j as (select je.id, je.transaction_date, je.description, je.origin_channel, bnx.effective_posting_date(je.id, v) pd,
                    bnx.effective_economic_type(je.id) et
               from bnx.journal_entry je
              where exists (select 1 from bnx.journal_line jl join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                             where jl.journal_id = je.id and ac.id = any(vis) and (acid is null or ac.id = acid))
                and exists (select 1 from bnx.visible_at(v) x where x.journal_id = je.id))
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('journal_id', j.id, 'posting_date', j.pd, 'transaction_date', j.transaction_date,
           'economic_type', j.et, 'flow_class', r.flow_class, 'description', j.description, 'origin_channel', j.origin_channel,
           -- a line on an account-currency the reader cannot see is masked (the journal shows because one of its lines is visible)
           'lines', (select jsonb_agg(case when ac.id is not null and not ac.id = any(vis) then jsonb_build_object('masked', true, 'ledger_kind', la.kind)
                                      else jsonb_strip_nulls(jsonb_build_object('account_currency_id', ac.id, 'ledger_account', case when ac.id is null then la.name end,
                                       'ledger_kind', la.kind, 'currency', la.currency, 'amount', jl.amount::text)) end order by ac.id nulls last, la.name)
                       from bnx.journal_line jl join bnx.ledger_account la on la.id = jl.ledger_account_id
                       left join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id where jl.journal_id = j.id),
           'corrected', exists (select 1 from bnx.journal_correction jc where jc.original_journal_id = j.id and jc.recorded_version <= v),
           'correction_of', (select jc.original_journal_id from bnx.journal_correction jc
                              where (jc.reversal_journal_id = j.id or jc.replacement_journal_id = j.id) and jc.recorded_version <= v limit 1),
           'source_txn_ids', (select jsonb_agg(t.id order by t.id) from bnx.source_txn t join bnx.account_currency ac on ac.id = t.account_currency_id
                               where ac.id = any(vis) and bnx.source_link_at(t.id, v) = j.id)))
           order by j.pd, j.id), '[]')
    into rws from (select * from j where j.pd between d0 and d1 order by j.pd, j.id limit lim) j
    join bnx.economic_type_rule r on r.economic_type::text = j.et;
  return bnx.rpt_envelope(a, v, d1, null, case when jsonb_array_length(rws) >= lim then array['LIMIT_REACHED'] else '{}' end)
    || jsonb_build_object('report', 'F2/1', 'date_from', d0, 'date_to', d1, 'rows', rws,
    'calendar', coalesce((select jsonb_agg(jsonb_build_object('date', c.dt, 'currency', c.cur, 'inflow', c.i::text, 'outflow', c.o::text) order by c.dt, c.cur)
                 from (select (x->>'posting_date')::date dt, l->>'currency' cur,
                              sum(greatest((l->>'amount')::numeric, 0)) i, sum(least((l->>'amount')::numeric, 0)) o
                         from jsonb_array_elements(rws) x, jsonb_array_elements(x->'lines') l
                        where l ? 'account_currency_id' and (acid is null or l->>'account_currency_id' = acid::text) group by 1, 2) c), '[]'),
    'evidence_refs', coalesce((select jsonb_agg(distinct s) from jsonb_array_elements(rws) x, jsonb_array_elements(x->'source_txn_ids') s), '[]'));
end $$;

-- ---------- F3 income and expense (R05-R08): income and expense category lines; operating vs investing results ----------
create function bnx.q_f3_income_expense(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d0 date; d1 date; cats jsonb;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d0 := (q->>'date_from')::date; d1 := (q->>'date_to')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'date_from or date_to'); end;
  if d0 is null or d1 is null or d1 < d0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'range'); end if;
  with l as (select la.id, la.name, la.kind, la.currency, r.flow_class, jl.amount
               from bnx.visible_at(v) x join bnx.journal_line jl on jl.journal_id = x.journal_id
               join bnx.ledger_account la on la.id = jl.ledger_account_id and la.kind in ('income','expense')
               join bnx.economic_type_rule r on r.economic_type::text = bnx.effective_economic_type(x.journal_id)
              where bnx.effective_posting_date(x.journal_id, v) between d0 and d1 and bnx.rpt_journal_visible(a, x.journal_id))
  select coalesce(jsonb_agg(jsonb_build_object('ledger_account_id', c.id, 'category', c.name, 'kind', c.kind, 'currency', c.currency,
                  'flow_class', c.flow_class, 'amount', c.amt::text) order by c.kind desc, c.currency, c.name), '[]') into cats
    from (select id, name, kind, currency, flow_class, case when kind = 'income' then -sum(amount) else sum(amount) end amt
            from l group by 1, 2, 3, 4, 5 having sum(amount) <> 0) c;
  return bnx.rpt_envelope(a, v, d1, null, '{}') || jsonb_build_object('report', 'F3/1', 'date_from', d0, 'date_to', d1, 'categories', cats,
    'totals_by_currency', coalesce((select jsonb_object_agg(t.currency, jsonb_build_object(
          'operating_income', t.oi::text, 'operating_expense', t.oe::text, 'operating_net', (t.oi - t.oe)::text,
          'investing_result', t.ir::text, 'other', t.ot::text))
        from (select x->>'currency' currency,
                     coalesce(sum((x->>'amount')::numeric) filter (where x->>'kind' = 'income' and x->>'flow_class' = 'OPERATING'), 0) oi,
                     coalesce(sum((x->>'amount')::numeric) filter (where x->>'kind' = 'expense' and x->>'flow_class' = 'OPERATING'), 0) oe,
                     coalesce(sum(case when x->>'kind' = 'income' then 1 else -1 end * (x->>'amount')::numeric) filter (where x->>'flow_class' = 'INVESTING'), 0) ir,
                     coalesce(sum(case when x->>'kind' = 'income' then 1 else -1 end * (x->>'amount')::numeric)
                              filter (where x->>'flow_class' not in ('OPERATING','INVESTING')), 0) ot
                from jsonb_array_elements(cats) x group by 1) t), '{}'), 'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- R09 cash flow (P0): movements on liquid accounts by flow class; opening + flows = closing per currency ----------
create function bnx.q_cashflow_statement(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d0 date; d1 date; liq uuid[]; res jsonb := '{}'; c text; op numeric; cl numeric;
        fl jsonb; s numeric; ok boolean; warn text[] := '{}';
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d0 := (q->>'date_from')::date; d1 := (q->>'date_to')::date;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'date_from or date_to'); end;
  if d0 is null or d1 is null or d1 < d0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'range'); end if;
  liq := array(select ac.id from bnx.actor_visible_acs(a) x join bnx.account_currency ac on ac.id = x join bnx.account acc on acc.id = ac.account_id
                where acc.kind in ('bank_deposit','cash','e_wallet'));
  for c in select distinct ac.currency from bnx.account_currency ac where ac.id = any(liq) order by 1 loop
    ok := true;
    select sum((bnx.balance_at(x, d0 - 1, v)).amount), bool_and((bnx.balance_at(x, d0 - 1, v)).status = 'ok') into op, ok
      from unnest(liq) x join bnx.account_currency ac on ac.id = x and ac.currency = c;
    select sum((bnx.balance_at(x, d1, v)).amount), ok and bool_and((bnx.balance_at(x, d1, v)).status = 'ok') into cl, ok
      from unnest(liq) x join bnx.account_currency ac on ac.id = x and ac.currency = c;
    select coalesce(jsonb_object_agg(f.flow_class, jsonb_build_object('inflow', f.i::text, 'outflow', f.o::text, 'net', (f.i + f.o)::text)), '{}'),
           coalesce(sum(f.i + f.o), 0) into fl, s
      from (select r.flow_class, sum(greatest(jl.amount, 0)) i, sum(least(jl.amount, 0)) o
              from bnx.visible_at(v) x join bnx.journal_line jl on jl.journal_id = x.journal_id
              join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id and ac.id = any(liq) and ac.currency = c
              join bnx.economic_type_rule r on r.economic_type::text = bnx.effective_economic_type(x.journal_id)
             where bnx.effective_posting_date(x.journal_id, v) between d0 and d1 group by 1) f;
    if not ok then warn := array_append(warn, 'BALANCE_NOT_AVAILABLE'::text); end if;
    res := res || jsonb_build_object(c, jsonb_build_object('opening', case when ok then op::text end, 'closing', case when ok then cl::text end,
             'flows', fl, 'operating_net', coalesce(fl->'OPERATING'->>'net', '0'),
             'reconciles', case when ok then op + s = cl end));
  end loop;
  return bnx.rpt_envelope(a, v, d1, null, warn) || jsonb_build_object('report', 'R09/1', 'date_from', d0, 'date_to', d1,
    'basis', 'cash movements on visible bank, cash and e-wallet accounts, classed by bnx.economic_type_rule.flow_class of the effective type',
    'by_currency', res, 'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- F4 investments (R22-R25, R33): holdings and performance per investment account-currency; R24 movements ----------
create function bnx.q_f4_investments(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d date; d0 date; acs jsonb := '[]'; r record;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d := coalesce((q->>'as_of')::date, current_date); d0 := coalesce((q->>'date_from')::date, d - 365);
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of or date_from'); end;
  for r in select ac.id from bnx.actor_visible_acs(a) x join bnx.account_currency ac on ac.id = x join bnx.account acc on acc.id = ac.account_id
            where acc.kind = 'investment' order by ac.id loop
    acs := acs || jsonb_build_array(bnx.q_investment_position(cred, jsonb_strip_nulls(jsonb_build_object('account_currency_id', r.id, 'as_of', d,
             'ledger_version', v, 'reporting_currency', q->>'reporting_currency')))
             || jsonb_build_object('movements', (bnx.q_f2_transactions(cred, jsonb_build_object('account_currency_id', r.id, 'date_from', d0,
                                                   'date_to', d, 'ledger_version', v)))->'rows'));
  end loop;
  return bnx.rpt_envelope(a, v, d, q->>'reporting_currency', array['MATURITIES_NOT_MODELLED']) || jsonb_build_object('report', 'F4/1',
    'accounts', acs, 'maturities', '[]'::jsonb, 'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- F5 net worth (R01, R02, R04, R16, R27, R28, R33) ----------
-- assets and liabilities at book value per visible account-currency; R28 receivable/payable pairs whose both sides are visible
-- household account-currencies are eliminated (INV-23b) and shown separately; ownership view by verified shares (unknown apart)
create function bnx.q_f5_networth(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d date; rc text := q->>'reporting_currency'; rmu int; vis uuid[]; elim uuid[];
        warn text[] := '{}'; lines jsonb; tot jsonb; rep jsonb;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d := coalesce((q->>'as_of')::date, current_date); exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of'); end;
  if rc is not null then select minor_units into rmu from bnx.currency where code = rc;
    if rmu is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'reporting_currency'); end if; end if;
  vis := array(select bnx.actor_visible_acs(a));
  elim := array(select x from bnx.loan l, unnest(array[l.receivable_account_currency_id, l.payable_account_currency_id]) x
                 where l.receivable_account_currency_id = any(vis) and l.payable_account_currency_id = any(vis));
  if exists (select 1 from bnx.loan l where (l.receivable_account_currency_id = any(vis)) <> (l.payable_account_currency_id = any(vis))
                                         and l.receivable_account_currency_id is not null and l.payable_account_currency_id is not null) then
    warn := array_append(warn, 'R28_COUNTERPART_NOT_VISIBLE'::text); end if;
  with b as (select ac.id, ac.currency, acc.id account_id, acc.kind, (bnx.balance_at(ac.id, d, v)).status st, (bnx.balance_at(ac.id, d, v)).amount amt,
                    ac.id = any(elim) eliminated
               from unnest(vis) x join bnx.account_currency ac on ac.id = x join bnx.account acc on acc.id = ac.account_id)
  select jsonb_agg(jsonb_build_object('account_currency_id', b.id, 'account_kind', b.kind, 'currency', b.currency, 'status', b.st,
                   'class', case when b.kind in ('credit_card','loan_payable') then 'liability' else 'asset' end, 'balance', b.amt::text,
                   'eliminated_r28', b.eliminated) order by b.kind, b.id),
         (select jsonb_object_agg(t.currency, jsonb_build_object('assets', t.assets::text, 'liabilities', t.liab::text, 'net_worth', (t.assets + t.liab)::text,
                                  'eliminated_r28', t.el::text))
            from (select currency, coalesce(sum(amt) filter (where not eliminated and kind not in ('credit_card','loan_payable')), 0.0000) assets,
                         coalesce(sum(amt) filter (where not eliminated and kind in ('credit_card','loan_payable')), 0.0000) liab,
                         coalesce(sum(amt) filter (where eliminated), 0.0000) el
                    from b where st = 'ok' group by currency) t)
    into lines, tot from b;
  if exists (select 1 from jsonb_array_elements(coalesce(lines, '[]')) x where x->>'status' <> 'ok') then warn := array_append(warn, 'BALANCE_NOT_AVAILABLE'::text); end if;
  if rc is not null then
    select jsonb_build_object('currency', rc, 'net_worth', case when bool_and(c.val is not null) then bnx.fin_money(sum(c.val), rmu) end)
      into rep from (select bnx.rpt_convert((t.value->>'net_worth')::numeric, t.key, rc, d, v) val from jsonb_each(coalesce(tot, '{}')) t) c;
    if rep->>'net_worth' is null then warn := array_append(warn, 'FX_MISSING'::text); end if;
  end if;
  return bnx.rpt_envelope(a, v, d, rc, warn) || jsonb_build_object('report', 'F5/1', 'basis', 'book value at the ledger version',
    'lines', coalesce(lines, '[]'), 'totals_by_currency', coalesce(tot, '{}'), 'reporting', rep,
    'by_owner', coalesce((select jsonb_agg(jsonb_build_object('party_id', o.p, 'currency', o.cur, 'net', bnx.r28_round(o.n, 4, 'HALF_EVEN')::text) order by o.p, o.cur)
        from (select coalesce(ow.party_id::text, 'unknown') p, ac.currency cur,
                     sum((bnx.balance_at(ac.id, d, v)).amount * coalesce(ow.share, 100) / 100) n
                from unnest(vis) x join bnx.account_currency ac on ac.id = x
                left join lateral (select o2.party_id, o2.share from bnx.ownership_at(ac.account_id, d, v) o2 where o2.kind = 'legal_owner') ow on true
               where not ac.id = any(elim) and (bnx.balance_at(ac.id, d, v)).status = 'ok' group by 1, 2) o), '[]'),
    'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- F6 cards (R17, R19, R20, R21) ----------
create function bnx.q_f6_cards(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; d date; cards jsonb := '[]'; r record; b bnx.balance_result; st record;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin d := coalesce((q->>'as_of')::date, current_date); exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'as_of'); end;
  for r in select ac.id acid, ac.currency, acc.id account_id, acc.label, cu.minor_units mu from bnx.actor_visible_acs(a) x
             join bnx.account_currency ac on ac.id = x join bnx.account acc on acc.id = ac.account_id join bnx.currency cu on cu.code = ac.currency
            where acc.kind = 'credit_card' order by acc.label, ac.currency loop
    b := bnx.balance_at(r.acid, d, v);
    select s.* into st from bnx.statement_period_at(v) s where s.account_currency_id = r.acid and s.final and s.period_end <= d order by s.period_end desc limit 1;
    cards := cards || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('account_currency_id', r.acid, 'card_account_id', r.account_id,
      'label', r.label, 'currency', r.currency, 'status', b.status, 'owed', bnx.fin_money(-b.amount, r.mu),
      'latest_statement', case when st.statement_id is not null then jsonb_build_object('statement_id', st.statement_id, 'period_end', st.period_end,
                                                                         'closing_balance', st.closing_balance::text) end,
      'repayments_since_statement', (select coalesce(sum(bnx.journal_movement(x.journal_id, r.acid)), 0)::text from bnx.visible_at(v) x
                                      where bnx.effective_economic_type(x.journal_id) = 'card_repayment' and bnx.journal_movement(x.journal_id, r.acid) is not null
                                        and bnx.effective_posting_date(x.journal_id, v) between coalesce(st.period_end + 1, '-infinity') and d),
      'annual_fee', bnx.card_fee_progress(r.account_id, d, v))));
  end loop;
  return bnx.rpt_envelope(a, v, d, null, array['DUE_DATE_NOT_MODELLED']) || jsonb_build_object('report', 'F6/1', 'cards', cards, 'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- F7 reconciliation (R13, R14, R15) ----------
create function bnx.q_f7_reconciliation(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; acid uuid; vis uuid[]; cov jsonb := '[]'; r record;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  begin acid := (q->>'account_currency_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account_currency_id'); end;
  vis := array(select bnx.actor_visible_acs(a));
  if acid is not null and not acid = any(vis) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  for r in select x from unnest(vis) x where (acid is null or x = acid)
             and (exists (select 1 from bnx.statement s where s.account_currency_id = x) or (bnx.anchor_at(x, v)).id is not null) order by 1 loop
    cov := cov || jsonb_build_array(bnx.q_reconciliation_coverage(cred, jsonb_build_object('account_currency_id', r.x, 'ledger_version', v)));
  end loop;
  return bnx.rpt_envelope(a, v, null, null, '{}') || jsonb_build_object('report', 'F7/1',
    'exceptions', (bnx.q_reconciliation_exceptions(cred, jsonb_strip_nulls(jsonb_build_object('account_currency_id', acid, 'ledger_version', v))))->'exceptions',
    'coverage', cov,
    'transfer_matching', jsonb_build_object(
      'open_clearing_items', coalesce((select jsonb_agg(jsonb_build_object('clearing_item_id', c.id, 'account_currency_id', c.account_currency_id,
                                  'kind', c.kind, 'amount', c.amount::text, 'opened', bnx.effective_posting_date(c.opened_journal, v)) order by c.id)
                                  from bnx.clearing_item c where c.account_currency_id = any(vis) and (acid is null or c.account_currency_id = acid)
                                   and bnx.journal_counts_at(c.opened_journal, v)
                                   and not exists (select 1 from bnx.clearing_item_event e where e.clearing_item_id = c.id and e.event = 'resolved'
                                                     and e.recorded_version <= v)), '[]'),
      'decisions_by_state', coalesce((select jsonb_object_agg(s, n) from (select me.evidence->>'state' s, count(*) n
                                  from bnx.match_decision_current mc join bnx.match_decision_event me on me.id = mc.decision_event_id
                                  join bnx.source_txn t on t.id = mc.source_txn_id
                                 where mc.kind in ('transfer_pair','clearing_resolution') and t.account_currency_id = any(vis)
                                   and (acid is null or t.account_currency_id = acid) and me.recorded_version <= v group by 1) y), '{}')),
    'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- R30 review queue (P0): derived from the open facts; there is no dismiss path, so it cannot be bypassed ----------
create function bnx.q_r30_review_queue(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; vis uuid[]; items jsonb;
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  vis := array(select bnx.actor_visible_acs(a));
  select coalesce(jsonb_agg(i order by i->>'kind', i->>'ref'), '[]') into items from (
    select jsonb_build_object('kind', 'reconciliation_exception', 'ref', x->>'exception_id', 'account_currency_id', x->>'account_currency_id',
                              'detail', jsonb_build_object('rule_code', x->>'rule_code', 'classification', x->>'classification', 'phase', x->>'phase')) i
      from jsonb_array_elements((bnx.q_reconciliation_exceptions(cred, jsonb_build_object('state', 'OPEN', 'ledger_version', v)))->'exceptions') x
    union all
    select jsonb_build_object('kind', 'open_clearing_item', 'ref', c.id, 'account_currency_id', c.account_currency_id,
                              'detail', jsonb_build_object('clearing_kind', c.kind, 'amount', c.amount::text))
      from bnx.clearing_item c where c.account_currency_id = any(vis) and bnx.journal_counts_at(c.opened_journal, v)
       and not exists (select 1 from bnx.clearing_item_event e where e.clearing_item_id = c.id and e.event = 'resolved' and e.recorded_version <= v)
    union all
    select jsonb_build_object('kind', 'match_decision_pending', 'ref', t.id, 'account_currency_id', t.account_currency_id,
                              'detail', jsonb_build_object('match_kind', mc.kind, 'state', me.evidence->>'state', 'rule', me.rule_code))
      from bnx.match_decision_current mc join bnx.match_decision_event me on me.id = mc.decision_event_id join bnx.source_txn t on t.id = mc.source_txn_id
     where t.account_currency_id = any(vis) and me.decision = 'proposed' and bnx.source_link_at(t.id, v) is null
    union all
    select jsonb_build_object('kind', 'unmatched_source_row', 'ref', t.id, 'account_currency_id', t.account_currency_id,
                              'detail', jsonb_build_object('posting_date', t.posting_date, 'amount', t.amount::text))
      from bnx.source_txn t where t.account_currency_id = any(vis) and bnx.source_link_at(t.id, v) is null
       and not exists (select 1 from bnx.match_decision_current mc join bnx.match_decision_event me on me.id = mc.decision_event_id
                        where mc.source_txn_id = t.id and me.decision = 'confirmed')
       and not exists (select 1 from bnx.match_decision_current mc join bnx.match_decision_event me on me.id = mc.decision_event_id
                        where mc.source_txn_id = t.id and me.decision = 'proposed')
    union all
    select jsonb_build_object('kind', case when p.state = 'frozen' then 'plan_awaiting_approval' else 'plan_not_activated' end, 'ref', p.id,
                              'account_currency_id', p.scope->>'account_currency_id',
                              'detail', jsonb_build_object('plan_kind', p.kind, 'state', p.state, 'hold_reasons', to_jsonb(p.hold_reasons)))
      from bnx.posting_plan p
     where (p.scope->>'account_currency_id')::uuid = any(vis) and p.state in ('frozen','approved','executing','sealed','stale')
  ) z;
  return bnx.rpt_envelope(a, v, null, null, '{}') || jsonb_build_object('report', 'R30/1', 'items', items,
    'counts', coalesce((select jsonb_object_agg(k, n) from (select x->>'kind' k, count(*) n from jsonb_array_elements(items) x group by 1) y), '{}'),
    'evidence_refs', '[]'::jsonb);
end $$;

-- ---------- R31 traceability (P0): evidence -> document -> statement -> source row -> journal -> correction -> snapshot ----------
-- the journal a row is linked to at V even when that journal was corrected later (traceability keeps corrected history)
create function bnx.source_link_raw_at(p_src uuid, p_v bigint) returns uuid
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select x.journal_id from (
    select distinct on (e.journal_id) e.journal_id, e.event from bnx.source_link_event e
     where e.source_txn_id = p_src and e.recorded_version <= p_v order by e.journal_id, e.event_id desc) x
   where x.event = 'linked' and exists (select 1 from bnx.visible_at(p_v) y where y.journal_id = x.journal_id) limit 1
$$;
create function bnx.q_evidence_trace(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); v bigint; vnow bigint; j uuid; src uuid; t bnx.source_txn; rws jsonb; fam uuid[];
begin
  perform bnx.require(a, 0);
  v := bnx.rpt_version(q);
  select version into vnow from bnx.ledger_state;
  begin j := (q->>'journal_id')::uuid; src := (q->>'source_txn_id')::uuid;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'journal_id or source_txn_id'); end;
  if src is not null then
    select * into t from bnx.source_txn where id = src;
    if t.id is null or not t.account_currency_id in (select bnx.actor_visible_acs(a)) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
    j := bnx.source_link_raw_at(src, v);
  end if;
  if j is not null and (not bnx.rpt_journal_visible(a, j) or not exists (select 1 from bnx.visible_at(v) x where x.journal_id = j)) then
    perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if j is null and src is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'journal_id or source_txn_id'); end if;
  -- the correction family of the journal: the original, its reversal and replacement (and theirs)
  fam := case when j is null then '{}' else array(
    with recursive c(id) as (select j union select x from c, bnx.journal_correction jc,
                              unnest(array[jc.original_journal_id, jc.reversal_journal_id, jc.replacement_journal_id]) x
                              where c.id in (jc.original_journal_id, jc.reversal_journal_id, jc.replacement_journal_id) and jc.recorded_version <= v and x is not null)
    select id from c) end;
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('source_txn_id', s.id, 'account_currency_id', s.account_currency_id,
           'posting_date', s.posting_date, 'amount', s.amount::text, 'linked_journal_id', bnx.source_link_raw_at(s.id, v),
           'statements', (select jsonb_agg(jsonb_build_object('statement_id', sp.statement_id, 'period_start', sp.period_start, 'period_end', sp.period_end,
                                 'final', sp.final, 'document_id', sp.document_id, 'evidence_object_id', eo.id, 'integrity_state', eo.integrity_state))
                            from bnx.statement_period_at(v) sp join bnx.document dc on dc.id = sp.document_id join bnx.evidence_object eo on eo.id = dc.evidence_object_id
                           where sp.account_currency_id = s.account_currency_id and s.posting_date between sp.period_start and sp.period_end))) order by s.id), '[]')
    into rws from bnx.source_txn s
   where s.id = src or (j is not null and bnx.source_link_raw_at(s.id, v) = any(fam));
  return bnx.rpt_envelope(a, v, null, null, case when jsonb_array_length(rws) = 0 then array['NO_SOURCE_ROW'] else '{}' end)
    || jsonb_build_object('report', 'R31/1', 'journal_id', j, 'source_rows', rws,
    'corrections', coalesce((select jsonb_agg(jsonb_build_object('original_journal_id', jc.original_journal_id, 'reversal_journal_id', jc.reversal_journal_id,
                               'replacement_journal_id', jc.replacement_journal_id, 'recorded_version', jc.recorded_version) order by jc.recorded_version)
                              from bnx.journal_correction jc where jc.original_journal_id = any(fam) and jc.recorded_version <= v), '[]'),
    'snapshots', coalesce((select jsonb_agg(jsonb_build_object('snapshot_id', rs.id, 'report_code', rs.report_code, 'ledger_version', rs.ledger_version,
                             'as_of', rs.filters->>'as_of', 'definition_version', rs.report_definition_version) order by rs.ledger_version, rs.id)
                            from bnx.report_snapshot rs
                           where bnx.snapshot_decision(a, rs.id) = 'ok' and exists (
                                 select 1 from unnest(fam) f join bnx.journal_line jl on jl.journal_id = f
                                   join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                                  where ac.id = any(rs.projection_account_currency_ids)
                                    and exists (select 1 from bnx.visible_at(rs.ledger_version) x where x.journal_id = f)
                                    and bnx.effective_posting_date(f, rs.ledger_version) <= (rs.filters->>'as_of')::date)), '[]'),
    'evidence_refs', coalesce((select jsonb_agg(distinct st->'evidence_object_id') from jsonb_array_elements(rws) r, jsonb_array_elements(r->'statements') st), '[]'));
end $$;

-- ---------- snapshots: artifact facts, status, listing (UA V1.2 §5.8.2) ----------
create table bnx.report_snapshot_artifact(snapshot_id uuid not null references bnx.report_snapshot, seq int not null,
  artifact_ref text not null check (artifact_ref ~ '^(drive|gs|r2):[A-Za-z0-9._/:-]+$' and length(artifact_ref) <= 512),
  artifact_sha256 text not null check (artifact_sha256 ~ '^[0-9a-f]{64}$'), rendered_at timestamptz not null,
  renderer_version text not null check (renderer_version ~ '^[A-Za-z0-9._-]{1,40}$'), source_revision bigint not null, ownership_revision bigint not null,
  fx_nav_snapshot_ref text, coverage jsonb check (coverage is null or jsonb_typeof(coverage) = 'object'), warnings text[] not null default '{}',
  recorded_version bigint not null, primary key (snapshot_id, seq));
create trigger t_append_only before update or delete on bnx.report_snapshot_artifact for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('report_snapshot_artifact','F');

-- the Executor's REPORT_RENDER completion records the rendered artifact (via the staging completion path; worker role only)
create function bnx.wrk_snapshot_artifact(p_snapshot uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s int; v bigint;
begin
  if not exists (select 1 from bnx.report_snapshot where id = p_snapshot) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  select version into v from bnx.ledger_state;
  perform pg_advisory_xact_lock(hashtext('bnx.snapshot_artifact:' || p_snapshot));
  s := coalesce((select max(seq) from bnx.report_snapshot_artifact where snapshot_id = p_snapshot), 0) + 1;
  begin
    insert into bnx.report_snapshot_artifact(snapshot_id, seq, artifact_ref, artifact_sha256, rendered_at, renderer_version, source_revision,
                                             ownership_revision, fx_nav_snapshot_ref, coverage, warnings, recorded_version)
    values (p_snapshot, s, p->>'artifact_ref', p->>'artifact_sha256', coalesce((p->>'rendered_at')::timestamptz, now()), p->>'renderer_version',
            (p->>'source_revision')::bigint, (p->>'ownership_revision')::bigint, p->>'fx_nav_snapshot_ref', p->'coverage',
            coalesce(array(select jsonb_array_elements_text(p->'warnings')), '{}'), v);
  exception when check_violation or not_null_violation or invalid_text_representation then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'artifact facts');
  end;
  return jsonb_build_object('snapshot_id', p_snapshot, 'seq', s);
end $$;

-- CURRENT / STALE / ACCESS_REVOKED without AI (OR-R-05): STALE when anything that can change the snapshot's figures was recorded
-- after its ledger version on the account-currencies it shows (a posting dated on or before as_of, a correction of such a posting, an anchor, an
-- ownership change, an FX fact for a converted snapshot, a later artifact source revision). Over-invalidation is allowed.
create function bnx.snapshot_status_reasons(s bnx.report_snapshot) returns text[]
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select array_remove(array[
    case when exists (select 1 from bnx.journal_entry je join bnx.journal_line jl on jl.journal_id = je.id
                        join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                       where ac.id = any(s.projection_account_currency_ids)
                         and bnx.journal_counts_at(je.id, 9223372036854775807) and not exists (select 1 from bnx.visible_at(s.ledger_version) x where x.journal_id = je.id)
                         and bnx.effective_posting_date(je.id, (select version from bnx.ledger_state)) <= (s.filters->>'as_of')::date)
         then 'LEDGER_CHANGED_IN_SCOPE' end,
    case when exists (select 1 from bnx.journal_correction jc join bnx.journal_line jl on jl.journal_id = jc.original_journal_id
                        join bnx.account_currency ac on ac.ledger_account_id = jl.ledger_account_id
                       where jc.recorded_version > s.ledger_version and ac.id = any(s.projection_account_currency_ids)
                         and bnx.effective_posting_date(jc.original_journal_id, s.ledger_version) <= (s.filters->>'as_of')::date)
         then 'BACKDATED_CORRECTION' end,
    case when exists (select 1 from bnx.opening_anchor_version o where o.account_currency_id = any(s.projection_account_currency_ids)
                        and o.valid_from_version > s.ledger_version) then 'ANCHOR_CHANGED' end,
    case when exists (select 1 from bnx.account_ownership_event e join bnx.account_currency ac on ac.account_id = e.account_id
                       where ac.id = any(s.projection_account_currency_ids) and e.recorded_version > s.ledger_version) then 'OWNERSHIP_CHANGED' end,
    case when s.fx_policy->>'mode' is distinct from 'native'
          and (exists (select 1 from bnx.fx_quote f where f.recorded_version > s.ledger_version)
               or exists (select 1 from bnx.fx_override_event f where f.recorded_version > s.ledger_version)) then 'FX_CHANGED' end], null)
$$;

create function bnx.q_snapshot_status(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); sid uuid; dec text; s bnx.report_snapshot; why text[];
begin
  perform bnx.require(a, 0);
  begin sid := (q->>'snapshot_id')::uuid; exception when others then sid := null; end;
  dec := bnx.snapshot_decision(a, sid);
  if dec = 'NOT_AVAILABLE' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if dec = 'ACCESS_REVOKED' then
    return jsonb_build_object('snapshot_id', sid, 'status', 'ACCESS_REVOKED');                -- nothing else is disclosed
  end if;
  select * into s from bnx.report_snapshot where id = sid;
  why := bnx.snapshot_status_reasons(s);
  return jsonb_build_object('snapshot_id', sid, 'status', case when cardinality(why) = 0 then 'CURRENT' else 'STALE' end, 'reasons', to_jsonb(why),
    'ledger_version', s.ledger_version, 'current_ledger_version', (select version from bnx.ledger_state),
    'definition_version', s.report_definition_version);
end $$;

create function bnx.q_snapshot_list(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred);
begin
  perform bnx.require(a, 0);
  return jsonb_build_object('snapshots', coalesce((select jsonb_agg(jsonb_build_object('snapshot_id', s.id, 'report_code', s.report_code,
           'definition_version', s.report_definition_version, 'ledger_version', s.ledger_version, 'as_of', s.filters->>'as_of',
           'status', case when bnx.snapshot_decision(a, s.id) = 'ACCESS_REVOKED' then 'ACCESS_REVOKED'
                          when cardinality(bnx.snapshot_status_reasons(s)) = 0 then 'CURRENT' else 'STALE' end) order by s.created_at, s.id)
      from bnx.report_snapshot s where bnx.snapshot_decision(a, s.id) <> 'NOT_AVAILABLE'
       and (q->>'report_code' is null or s.report_code = q->>'report_code')), '[]'));
end $$;

-- the proxy's database call (GET /api/v1/artifacts/{snapshot_id}): the current grant decides; a revoked snapshot discloses no
-- artifact reference (bytes are never streamed); the status travels as the X-BNX-Snapshot-Status header
create function bnx.q_snapshot_artifact(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); sid uuid; dec text; art bnx.report_snapshot_artifact; st jsonb;
begin
  perform bnx.require(a, 0);
  begin sid := (q->>'snapshot_id')::uuid; exception when others then sid := null; end;
  dec := bnx.snapshot_decision(a, sid);
  if dec = 'NOT_AVAILABLE' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if dec = 'ACCESS_REVOKED' then perform bnx.fail('ACCESS_REVOKED', 'P0403'); end if;
  select * into art from bnx.report_snapshot_artifact where snapshot_id = sid order by seq desc limit 1;
  if art.snapshot_id is null then perform bnx.fail('ARTIFACT_NOT_RENDERED', 'P0404'); end if;
  st := bnx.q_snapshot_status(cred, q);
  perform bnx.audit(a, 'read_snapshot_artifact', jsonb_build_object('snapshot_id', sid, 'seq', art.seq), q, (select version from bnx.ledger_state));
  return jsonb_build_object('snapshot_id', sid, 'artifact_ref', art.artifact_ref, 'artifact_sha256', art.artifact_sha256, 'seq', art.seq,
                            'renderer_version', art.renderer_version, 'status', st->>'status');
end $$;

-- ---------- cmd_create_report_snapshot MODIFY (OBJ-216): scope filter before balance_rows; definition version from the table ----------
create or replace function bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); snap uuid := gen_random_uuid(); vnow bigint; v bigint; d date;
        vis uuid[]; req uuid[]; content_acs uuid[]; proj uuid[]; defv text;
begin
  perform bnx.require(a, 0);
  if cmd->>'report_code' is distinct from 'R-BAL' then perform bnx.fail('REPORT_NOT_IMPLEMENTED', 'P0422', cmd->>'report_code'); end if;
  select 'R-BAL/' || max(version) into defv from bnx.report_definition where report_id = 'R-BAL';
  select version into vnow from bnx.ledger_state;
  v := coalesce((cmd->>'ledger_version')::bigint, vnow);
  if v < 0 or v > vnow then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  d := coalesce((cmd->>'as_of')::date, current_date);
  vis := array(select bnx.actor_visible_acs(a));
  if cmd ? 'account_currency_ids' then
    select coalesce(array_agg(x::uuid order by x::uuid), '{}') into req from jsonb_array_elements_text(cmd->'account_currency_ids') x;
    if not (req <@ vis) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;   -- no oracle on unseen accounts
  else
    req := array(select unnest(vis) order by 1);
  end if;
  req := array(select x from unnest(req) x where x in (select bnx.pol_scope_filter(a)) order by x);   -- 9013: scope filter first
  content_acs := array(select ac.id from bnx.account_currency ac order by ac.id);
  proj := array(select x from unnest(req) x order by x);
  insert into bnx.report_snapshot(id, report_code, filters_digest, ledger_version, report_definition_version, fx_policy,
    valuation_cutoff, content_account_currency_ids, content_sha256, projection_actor, projection_account_currency_ids,
    projection_sha256, canonicalization, projection_channel, projection_connection_id, projection_requested_acs, filters)
  values (snap, 'R-BAL', bnx.h(jsonb_build_object('as_of', d, 'acs', req)::text), v, defv, '{"mode":"native"}', null,
    content_acs, bnx.h(bnx.balance_rows(content_acs, d, v)::text), a.member_id, proj,
    bnx.h(bnx.balance_rows(proj, d, v)::text), 'jsonb-text/rows-sorted-by-account_currency_id',
    a.channel, a.connection_id, req, jsonb_build_object('as_of', d));
  perform bnx.audit(a, 'create_report_snapshot', jsonb_build_object('snapshot_id', snap), cmd, v);
  return jsonb_build_object('snapshot_id', snap, 'ledger_version', v, 'rows', bnx.balance_rows(proj, d, v), 'definition_version', defv,
                            'projection_sha256', encode(bnx.h(bnx.balance_rows(proj, d, v)::text), 'hex'));
end $$;

insert into bnx.function_scope values
 ('q_f1_balances', 'finance.read', false, false, true, 'fin.reports.f1'),
 ('q_f2_transactions', 'finance.read', false, false, true, 'fin.reports.f2'),
 ('q_f3_income_expense', 'finance.read', false, false, true, 'fin.reports.f3'),
 ('q_f4_investments', 'finance.read', false, false, true, 'fin.reports.f4'),
 ('q_f5_networth', 'finance.read', false, false, true, 'fin.reports.f5'),
 ('q_f6_cards', 'finance.read', false, false, true, 'fin.reports.f6'),
 ('q_f7_reconciliation', 'finance.read', false, false, true, 'fin.reports.f7'),
 ('q_cashflow_statement', 'finance.read', false, false, true, 'fin.reports.r09'),
 ('q_r30_review_queue', 'finance.read', false, false, true, 'fin.reports.r30'),
 ('q_evidence_trace', 'finance.read', false, false, true, 'fin.reports.r31'),
 ('q_snapshot_status', 'reports.read', false, false, false, 'reports.snapshot.status'),
 ('q_snapshot_list', 'reports.read', false, false, false, 'reports.snapshot.list'),
 ('q_snapshot_artifact', 'reports.read', false, false, false, 'reports.snapshot.artifact');

select bnx.apply_grants();
