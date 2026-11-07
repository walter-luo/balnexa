-- 9001 One-time conversion of a Draft-02 logical state (schema d02) into Draft-04 tables. Applied only if d02 exists.
-- Mapping: each historical anchor revision becomes an opening_anchor_version with valid_from_version taken from the
-- order of revised_at (the Draft-02 state had no versions, so versions are assigned in commit-time order and the
-- conversion is recorded as such); confirmations and match decisions receive versions in timestamp order.
-- History cannot be made more precise than the source: reports produced under Draft-02 cannot be replayed exactly.
set role bnx_definer;
do $$
declare r record; v bigint;
begin
  if to_regnamespace('d02') is null then raise notice '9001: no d02 schema, nothing to convert'; return; end if;
  for r in
    select h.account_currency_id, h.revision, h.anchor_date, h.amount, h.journal_id, h.reason, h.revised_by, h.revised_at,
           h.bridge_difference, a.source, a.certainty, a.evidence, false as is_current
      from d02.opening_anchor_history h join d02.opening_anchor a using (account_currency_id)
    union all
    select a.account_currency_id, a.revision, a.anchor_date, a.amount, a.journal_id, 'current at conversion', null, now(),
           null, a.source, a.certainty, a.evidence, true
      from d02.opening_anchor a
    order by revised_at, revision
  loop
    v := bnx.next_version();
    insert into bnx.opening_anchor_version(id,account_currency_id,anchor_date,amount,journal_id,source,certainty,evidence,
      revision,bridge_difference,reason,valid_from_version,recorded_by)
    values (gen_random_uuid(), r.account_currency_id, r.anchor_date, r.amount,
            case when r.amount = 0 then null else r.journal_id end, r.source, r.certainty, r.evidence, r.revision,
            r.bridge_difference, 'converted from Draft-02: '||r.reason, v,
            coalesce(r.revised_by, '00000000-0000-0000-0000-000000000000'));
  end loop;
  for r in select journal_id, confirmed_posting_date, row_number() over (partition by journal_id order by confirmed_at) seq
             from d02.posting_date_confirmation order by confirmed_at loop
    v := bnx.next_version();
    insert into bnx.posting_date_confirmation(journal_id,seq,confirmed_posting_date,source,recorded_version)
    values (r.journal_id, r.seq, r.confirmed_posting_date, 'statement', v);
  end loop;
  for r in select * from d02.match_decision order by decided_at nulls first loop
    v := bnx.next_version();
    insert into bnx.match_decision_event(id,source_txn_id,kind,decision,journal_line_id,rule_code,evidence,supersedes,decided_by,recorded_version)
    values (r.id, r.source_txn_id, r.kind, r.state, r.journal_line_id, r.rule_code, r.evidence, r.supersedes, r.decided_by, v);
    if r.state = 'confirmed' then
      insert into bnx.match_decision_current(source_txn_id,kind,decision_event_id,journal_line_id)
      values (r.source_txn_id, r.kind, r.id, r.journal_line_id)
      on conflict (source_txn_id, kind) do update set decision_event_id = excluded.decision_event_id, journal_line_id = excluded.journal_line_id;
    end if;
  end loop;
  raise notice '9001: converted Draft-02 logical state';
end $$;
