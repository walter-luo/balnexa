-- Executed AFTER migration 9001 has converted the fixture loaded by 060_fixture (see run_tests.py)
do $$
declare ac uuid := t.uuid('ac-chq'); vmax bigint := t.cur(); v_first bigint;
begin
  if (select count(*) from bnx.opening_anchor_version where account_currency_id = ac) <> 2 then raise exception 'CONV FAIL anchor versions'; end if;
  select min(valid_from_version) into v_first from bnx.opening_anchor_version where account_currency_id = ac;
  if (bnx.anchor_at(ac, v_first)).amount <> 5000 or (bnx.anchor_at(ac, vmax)).amount <> 5200 then raise exception 'CONV FAIL anchor_at'; end if;
  if (select amount from bnx.opening_anchor where account_currency_id = ac) <> 5200 then raise exception 'CONV FAIL current view'; end if;
  if (select count(*) from bnx.posting_date_confirmation) <> 2
     or (select count(distinct recorded_version) from bnx.posting_date_confirmation) <> 2 then raise exception 'CONV FAIL confirmations'; end if;
  if (select count(*) from bnx.match_decision_event) <> 2 or (select count(*) from bnx.match_decision_current) <> 1 then raise exception 'CONV FAIL decisions'; end if;
  raise notice 'PASS 060 Draft-02 -> Draft-04 conversion: 2 anchor versions (5000 then 5200), 2 versioned confirmations, 2 decision events, 1 current';
end $$;
