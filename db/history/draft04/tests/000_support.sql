-- Test-support functions (synthetic data only). NOT a production migration; loaded only by run_tests.py.
-- They imitate the version and ledger-lock behaviour of the Command Core for the objects in migrations 0001-0007.
create schema t authorization bnx_definer;
set role bnx_definer;

create function t.uuid(p text) returns uuid language sql immutable as $$ select md5(p)::uuid $$;

create function t.setup() returns void language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  insert into bnx.currency values ('CAD',2),('CNY',2);
  insert into bnx.member values (t.uuid('ann'),'Ann','owner','active'),(t.uuid('bo'),'Bo','member','active');
  insert into bnx.party(id,kind,display_name,normalized_name,created_by) values
    (t.uuid('p-ann'),'person','Ann','ann',t.uuid('ann')),(t.uuid('p-bo'),'person','Bo','bo',t.uuid('ann')),
    (t.uuid('p-co'),'organization','Example Co.','example co',t.uuid('ann'));
  insert into bnx.institution(id,name_en) values (t.uuid('bank-a'),'Bank A');
  insert into bnx.ledger_account values
    (t.uuid('la-chq'),'asset','CAD','Bank A chequing'),(t.uuid('la-sav'),'asset','CAD','Bank A savings'),
    (t.uuid('la-eq'),'equity','CAD','Opening Balances'),(t.uuid('la-exp'),'expense','CAD','Groceries');
  insert into bnx.account(id,kind,institution_id,label,reference_kind,visibility,timezone,origin,state,created_by) values
    (t.uuid('a-chq'),'bank_deposit',t.uuid('bank-a'),'Chequing','managed','household','America/Toronto','manual','active',t.uuid('ann')),
    (t.uuid('a-sav'),'bank_deposit',t.uuid('bank-a'),'Savings','managed','private','America/Toronto','manual','active',t.uuid('ann'));
  insert into bnx.account_currency values (t.uuid('ac-chq'),t.uuid('a-chq'),'CAD',t.uuid('la-chq')),
                                         (t.uuid('ac-sav'),t.uuid('a-sav'),'CAD',t.uuid('la-sav'));
  insert into bnx.account_grant(member_id,account_id,can_view,can_post,granted_by) values
    (t.uuid('ann'),t.uuid('a-chq'),true,true,t.uuid('ann')),(t.uuid('ann'),t.uuid('a-sav'),true,true,t.uuid('ann')),
    (t.uuid('bo'),t.uuid('a-chq'),true,false,t.uuid('ann')),(t.uuid('bo'),t.uuid('a-sav'),true,false,t.uuid('ann'));
end $$;

create function t.cur() returns bigint language sql as $$ select version from bnx.ledger_state $$;

-- Direct posting of a two-line journal: debit p_dr, credit p_cr
create function t.post(p_desc text, p_date date, p_amount numeric, p_dr uuid, p_cr uuid,
                       p_type bnx.economic_type default 'consumption_expense') returns uuid
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare v bigint := bnx.next_version(); j uuid := gen_random_uuid();
begin
  insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,
    ledger_version,origin_channel,created_by_member,confirmed_by_member)
  values (j,p_type,p_date,p_date,'estimated',p_desc,v,'pwa',t.uuid('ann'),t.uuid('ann'));
  insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
    (gen_random_uuid(),j,p_dr,'CAD',p_amount),(gen_random_uuid(),j,p_cr,'CAD',-p_amount);
  return j;
end $$;

-- Posting at a given version (used inside an anchor-change transaction, INV-29)
create function t.post_v(p_v bigint, p_desc text, p_date date, p_amount numeric, p_dr uuid, p_cr uuid) returns uuid
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare j uuid := gen_random_uuid();
begin
  insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,
    ledger_version,origin_channel,created_by_member,confirmed_by_member)
  values (j,'income',p_date,p_date,'statement_confirmed',p_desc,p_v,'pwa',t.uuid('ann'),t.uuid('ann'));
  insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
    (gen_random_uuid(),j,p_dr,'CAD',p_amount),(gen_random_uuid(),j,p_cr,'CAD',-p_amount);
  return j;
end $$;

create function t.confirm_date(p_journal uuid, p_date date) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare v bigint := bnx.next_version(); s int;
begin
  select coalesce(max(seq),0)+1 into s from bnx.posting_date_confirmation where journal_id = p_journal;
  insert into bnx.posting_date_confirmation(journal_id,seq,confirmed_posting_date,source,recorded_version)
  values (p_journal,s,p_date,'statement',v);
  return v;
end $$;

-- Install an anchor version: reverse the previous opening journal (dated on its own date) and post the new one,
-- all at ONE version (INV-29 shape). Optional history journals are posted by the caller in the same transaction.
create function t.set_anchor(p_ac uuid, p_date date, p_amount numeric, p_reason text) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare v bigint := bnx.next_version(); prev bnx.opening_anchor_version; la uuid; j uuid; rj uuid; rev int;
begin
  select ledger_account_id into la from bnx.account_currency where id = p_ac;
  prev := bnx.anchor_at(p_ac, v);
  if prev.journal_id is not null then
    rj := gen_random_uuid();
    insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,
      ledger_version,origin_channel,created_by_member,confirmed_by_member)
    values (rj,'correction_reversal',prev.anchor_date,prev.anchor_date,'user_confirmed','Reverse opening',v,'pwa',t.uuid('ann'),t.uuid('ann'));
    insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
      (gen_random_uuid(),rj,la,'CAD',-prev.amount),(gen_random_uuid(),rj,t.uuid('la-eq'),'CAD',prev.amount);
  end if;
  if p_amount <> 0 then
    j := gen_random_uuid();
    insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,
      ledger_version,origin_channel,created_by_member,confirmed_by_member)
    values (j,'opening_balance',p_date,p_date,'user_confirmed','Opening',v,'system_opening',t.uuid('ann'),t.uuid('ann'));
    insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
      (gen_random_uuid(),j,la,'CAD',p_amount),(gen_random_uuid(),j,t.uuid('la-eq'),'CAD',-p_amount);
  end if;
  rev := coalesce(prev.revision,0)+1;
  insert into bnx.opening_anchor_version(id,account_currency_id,anchor_date,amount,journal_id,reversed_journal_id,source,
    certainty,revision,reason,valid_from_version,recorded_by)
  values (gen_random_uuid(),p_ac,p_date,p_amount,j,rj,'manual_declaration','declared',rev,p_reason,v,t.uuid('ann'));
  return v;
end $$;

create function t.own(p_account uuid, p_party uuid, p_kind text, p_event text, p_share numeric, p_eff date) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare v bigint := bnx.next_version(); total numeric;
begin
  insert into bnx.account_ownership_event(id,account_id,party_id,kind,event,share,effective_from,evidence_kind,recorded_version,actor)
  values (gen_random_uuid(),p_account,p_party,p_kind,p_event,p_share,p_eff,'owner_confirmed',v,t.uuid('ann'));
  select coalesce(sum(share),0) into total from bnx.ownership_at(p_account,p_eff,v) where kind = p_kind;
  if total > 100 then raise exception 'OWNERSHIP_OVER_100 %', total using errcode = 'P0422'; end if;
  return v;
end $$;
reset role;
