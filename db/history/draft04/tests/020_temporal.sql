-- AT-TMP-01 (E1 date move), AT-TMP-02 (E2 anchor earlier with bridge), AT-TMP-03 (same-date revision), AT-TMP-04 (batch void)
do $$
declare v_a bigint; v_post bigint; v_conf bigint; j uuid; b bnx.balance_result;
        v_old bigint; v_new bigint; s uuid := t.uuid('ac-sav'); pl uuid; bt uuid; jb uuid; v_act bigint;
begin
  perform t.setup();
  -- E1
  v_a := t.set_anchor(t.uuid('ac-chq'), '2026-01-01', 1000, 'E1');
  j := t.post('Groceries','2026-03-31',60,t.uuid('la-exp'),t.uuid('la-chq')); v_post := t.cur();
  v_conf := t.confirm_date(j,'2026-04-01');
  b := bnx.balance_at(t.uuid('ac-chq'),'2026-03-31',v_post); if b.amount <> -60 + 1000 then raise exception 'AT-TMP-01 FAIL v_post %', b.amount; end if;
  b := bnx.balance_at(t.uuid('ac-chq'),'2026-03-31',v_conf); if b.amount <> 1000 then raise exception 'AT-TMP-01 FAIL v_conf %', b.amount; end if;
  b := bnx.balance_at(t.uuid('ac-chq'),'2026-04-30',v_conf); if b.amount <> 940 then raise exception 'AT-TMP-01 FAIL april %', b.amount; end if;
  raise notice 'PASS AT-TMP-01: Mar-31 at V% = 940, at V% = 1000; Apr-30 = 940', v_post, v_conf;
  -- E2 on savings: old anchor (2024-01-01, 5000); backdated anchor (2019-01-01, 1200) + history 3765 at ONE version
  v_old := t.set_anchor(s,'2024-01-01',5000,'declared');
  v_new := t.set_anchor(s,'2019-01-01',1200,'history reconstruction');
  perform t.post_v(v_new,'Salary 2019','2019-06-01',2000,t.uuid('la-sav'),t.uuid('la-eq'));
  perform t.post_v(v_new,'Salary 2022','2022-06-01',1765,t.uuid('la-sav'),t.uuid('la-eq'));
  b := bnx.balance_at(s,'2020-06-30',v_old); if b.status <> 'BEFORE_OPENING' then raise exception 'AT-TMP-02 FAIL old %', b.status; end if;
  b := bnx.balance_at(s,'2020-06-30',v_new); if b.status <> 'ok' or b.amount <> 3200 then raise exception 'AT-TMP-02 FAIL new 2020 %', b.amount; end if;
  if (bnx.balance_at(s,'2024-06-30',v_new)).amount - (bnx.balance_at(s,'2024-06-30',v_old)).amount <> -35 then
    raise exception 'AT-TMP-02 FAIL bridge'; end if;
  raise notice 'PASS AT-TMP-02: BEFORE_OPENING at V%, 3200 at V%, 2024 delta = bridge -35', v_old, v_new;
  -- AT-TMP-03 same-date revision on chequing
  v_a := t.set_anchor(t.uuid('ac-chq'),'2026-01-01',1100,'same-date revision');
  if (bnx.balance_at(t.uuid('ac-chq'),'2026-01-15',v_a-1)).amount <> 1000 or (bnx.balance_at(t.uuid('ac-chq'),'2026-01-15',v_a)).amount <> 1100 then
    raise exception 'AT-TMP-03 FAIL'; end if;
  raise notice 'PASS AT-TMP-03: 1000 at V%, 1100 at V%', v_a-1, v_a;
  -- AT-TMP-04 batch voided never visible; activated batch visible from its activation version only
  pl := gen_random_uuid(); bt := gen_random_uuid();
  insert into bnx.posting_plan(id,kind,scope,item_count,control_totals,plan_hash,state) values (pl,'import','{}',1,'{}','\x00','approved');
  insert into bnx.posting_batch(id,plan_id,state) values (bt,pl,'open');
  insert into bnx.posting_batch_event(batch_id,event,recorded_version) values (bt,'opened',t.cur());
  jb := gen_random_uuid();
  insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,posting_batch_id,
    origin_channel,created_by_member,confirmed_by_member) values (jb,'consumption_expense','2026-02-01','2026-02-01','estimated','batched',bt,'plan',t.uuid('ann'),t.uuid('ann'));
  insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
    (gen_random_uuid(),jb,t.uuid('la-exp'),'CAD',25),(gen_random_uuid(),jb,t.uuid('la-chq'),'CAD',-25);
  if exists (select 1 from bnx.visible_at(t.cur()) where journal_id = jb) then raise exception 'AT-TMP-04 FAIL open batch visible'; end if;
  v_act := bnx.next_version();
  insert into bnx.posting_batch_event(batch_id,event,recorded_version) values (bt,'activated',v_act);
  if exists (select 1 from bnx.visible_at(v_act-1) where journal_id = jb) or not exists (select 1 from bnx.visible_at(v_act) where journal_id = jb) then
    raise exception 'AT-TMP-04 FAIL activation visibility'; end if;
  begin insert into bnx.posting_batch_event(batch_id,event,recorded_version) values (bt,'voided',t.cur());
        raise exception 'AT-TMP-04 FAIL void after activation allowed';
  exception when unique_violation then null; end;
  raise notice 'PASS AT-TMP-04: invisible before V%, visible from V%; void after activation rejected', v_act, v_act;
end $$;
