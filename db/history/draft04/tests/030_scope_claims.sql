-- INV-40 / AT-CONC-05: overlapping held claims rejected; released claims and adjacent ranges allowed.
do $$
declare p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid(); p3 uuid := gen_random_uuid(); ok boolean;
begin
  perform t.setup();
  insert into bnx.posting_plan(id,kind,scope,item_count,control_totals,plan_hash,state) values
    (p1,'onboarding_scope','{}',0,'{}','\x01','frozen'),(p2,'onboarding_scope','{}',0,'{}','\x02','draft'),(p3,'import','{}',0,'{}','\x03','draft');
  insert into bnx.posting_scope_claim values (p1,t.uuid('ac-chq'),'[2019-01-01,2023-01-01)','held',1,null);
  begin insert into bnx.posting_scope_claim values (p2,t.uuid('ac-chq'),'[2022-06-01,2024-01-01)','held',2,null); ok := false;
  exception when exclusion_violation then ok := true; end;
  if not ok then raise exception 'AT-CONC-05 FAIL overlap accepted'; end if;
  insert into bnx.posting_scope_claim values (p3,t.uuid('ac-chq'),'[2023-01-01,2024-01-01)','held',2,null);   -- adjacent: allowed
  insert into bnx.posting_scope_claim values (p2,t.uuid('ac-sav'),'[2019-01-01,2024-01-01)','held',2,null);   -- other account: allowed
  update bnx.posting_scope_claim set claim_state='released', released_version=3 where plan_id=p1;
  update bnx.posting_scope_claim set during='[2019-01-01,2022-12-31)' where plan_id=p2 and account_currency_id=t.uuid('ac-sav');
  insert into bnx.posting_scope_claim values (p2,t.uuid('ac-chq'),'[2020-01-01,2022-01-01)','held',4,null);  -- after release: allowed
  raise notice 'PASS 030 INV-40: overlap rejected (exclusion_violation); adjacent/other-account/after-release accepted';
end $$;
