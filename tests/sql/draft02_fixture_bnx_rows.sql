-- R1 successor of Draft-04 tests/060_fixture.sql without t.* helpers: the pre-existing ledger rows of a synthetic
-- Draft-02 installation, loaded by the migrator under SET ROLE bnx_definer (installer/conversion step), before 9001.
set role bnx_definer;
insert into bnx.member values (md5('ann')::uuid, 'Ann (synthetic)', 'owner', 'active', now());
insert into bnx.ledger_account values (md5('la-chq')::uuid, 'asset', 'CAD', 'Chequing CAD'),
  (md5('la-eq')::uuid, 'equity', 'CAD', 'Opening Balances'), (md5('la-exp')::uuid, 'expense', 'CAD', 'Groceries');
insert into bnx.account(id, kind, label, reference_kind, visibility, timezone, origin, state, created_by)
  values (md5('acc')::uuid, 'cash', 'Wallet', 'none', 'household', 'America/Toronto', 'manual', 'active', md5('ann')::uuid);
insert into bnx.account_currency values (md5('ac-chq')::uuid, md5('acc')::uuid, 'CAD', md5('la-chq')::uuid);
insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,ledger_version,origin_channel,created_by_member,confirmed_by_member)
values (md5('j1')::uuid,'opening_balance','2024-01-01','2024-01-01','user_confirmed','Opening v1',1,'system_opening',md5('ann')::uuid,md5('ann')::uuid),
       (md5('j2')::uuid,'opening_balance','2024-01-01','2024-01-01','user_confirmed','Opening v2',2,'system_opening',md5('ann')::uuid,md5('ann')::uuid),
       (md5('j3')::uuid,'consumption_expense','2024-03-31','2024-03-31','estimated','Groceries',3,'pwa',md5('ann')::uuid,md5('ann')::uuid);
insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
 (gen_random_uuid(),md5('j1')::uuid,md5('la-chq')::uuid,'CAD',5000),(gen_random_uuid(),md5('j1')::uuid,md5('la-eq')::uuid,'CAD',-5000),
 (gen_random_uuid(),md5('j2')::uuid,md5('la-chq')::uuid,'CAD',5200),(gen_random_uuid(),md5('j2')::uuid,md5('la-eq')::uuid,'CAD',-5200),
 (md5('l3')::uuid,md5('j3')::uuid,md5('la-exp')::uuid,'CAD',60),(gen_random_uuid(),md5('j3')::uuid,md5('la-chq')::uuid,'CAD',-60);
update bnx.ledger_state set version = 3;
insert into bnx.source_txn values (md5('st1')::uuid,md5('ac-chq')::uuid,'2024-04-01',null,-60,'CAD','groceries',null,1,'\x01');
