-- AUD-039 AT-OWN-01..04: transfer, percentage change, reversion reproducible at old and new versions; grants separate.
do $$
declare a uuid; v1 bigint; v3 bigint; v5 bigint; v7 bigint; v9 bigint; ok boolean; n int;
begin
  perform t.setup(); a := t.uuid('a-chq');
  v1 := t.own(a,t.uuid('p-ann'),'legal_owner','set',100,'2020-01-01');
  perform t.own(a,t.uuid('p-ann'),'legal_owner','ended',null,'2025-01-01');
  v3 := t.own(a,t.uuid('p-bo'),'legal_owner','set',100,'2025-01-01');
  -- AT-OWN-01 transfer
  if (select array_agg(party_id) from bnx.ownership_at(a,'2025-06-30',v1)) <> array[t.uuid('p-ann')] then raise exception 'AT-OWN-01 FAIL old'; end if;
  if (select array_agg(party_id) from bnx.ownership_at(a,'2025-06-30',v3)) <> array[t.uuid('p-bo')] then raise exception 'AT-OWN-01 FAIL new'; end if;
  if (select array_agg(party_id) from bnx.ownership_at(a,'2024-06-30',v3)) <> array[t.uuid('p-ann')] then raise exception 'AT-OWN-01 FAIL history'; end if;
  -- AT-OWN-02 percentage change (beneficial)
  perform t.own(a,t.uuid('p-ann'),'beneficial_owner','set',60,'2023-01-01');
  v5 := t.own(a,t.uuid('p-bo'),'beneficial_owner','set',40,'2023-01-01');
  perform t.own(a,t.uuid('p-ann'),'beneficial_owner','set',50,'2024-01-01');
  v7 := t.own(a,t.uuid('p-bo'),'beneficial_owner','set',50,'2024-01-01');
  if (select sum(share) filter (where party_id=t.uuid('p-ann')) from bnx.ownership_at(a,'2024-06-30',v5) where kind='beneficial_owner') <> 60 then raise exception 'AT-OWN-02 FAIL v5'; end if;
  if (select sum(share) filter (where party_id=t.uuid('p-ann')) from bnx.ownership_at(a,'2024-06-30',v7) where kind='beneficial_owner') <> 50 then raise exception 'AT-OWN-02 FAIL v7'; end if;
  if (select sum(share) filter (where party_id=t.uuid('p-ann')) from bnx.ownership_at(a,'2023-06-30',v7) where kind='beneficial_owner') <> 60 then raise exception 'AT-OWN-02 FAIL 2023'; end if;
  -- AT-OWN-03 reversion of legal ownership to Ann from 2026
  perform t.own(a,t.uuid('p-bo'),'legal_owner','ended',null,'2026-01-01');
  v9 := t.own(a,t.uuid('p-ann'),'legal_owner','set',100,'2026-01-01');
  if (select array_agg(party_id) from bnx.ownership_at(a,'2026-02-01',v9) where kind='legal_owner') <> array[t.uuid('p-ann')] then raise exception 'AT-OWN-03 FAIL'; end if;
  if (select array_agg(party_id) from bnx.ownership_at(a,'2025-06-30',v9) where kind='legal_owner') <> array[t.uuid('p-bo')] then raise exception 'AT-OWN-03 FAIL mid'; end if;
  -- over 100 % rejected
  begin perform t.own(a,t.uuid('p-co'),'beneficial_owner','set',10,'2024-06-01'); ok := false;
  exception when sqlstate 'P0422' then ok := true; end;
  if not ok then raise exception 'AT-OWN FAIL >100%% accepted'; end if;
  -- AT-OWN-04 ownership and grants are distinct
  delete from bnx.account_grant where member_id=t.uuid('bo') and account_id=a;
  if (select array_agg(party_id) from bnx.ownership_at(a,'2025-06-30',v9) where kind='legal_owner') <> array[t.uuid('p-bo')] then raise exception 'AT-OWN-04 FAIL grant changed ownership'; end if;
  if t.uuid('ac-chq') in (select bnx.visible_account_currency_ids(t.uuid('bo'))) then raise exception 'AT-OWN-04 FAIL ownership implied grant'; end if;
  insert into bnx.account_scope_event values (gen_random_uuid(),a,'joint','2023-01-01',v5,t.uuid('ann'));
  if bnx.account_scope_at(a,'2022-12-31',v9) <> 'individual' or bnx.account_scope_at(a,'2023-06-30',v9) <> 'joint' or bnx.account_scope_at(a,'2023-06-30',v1) <> 'individual' then
    raise exception 'AT-OWN scope FAIL'; end if;
  raise notice 'PASS 040 AT-OWN-01..04: transfer, 60/40->50/50, reversion, >100%% rejected, grants distinct, scope versioned';
end $$;
