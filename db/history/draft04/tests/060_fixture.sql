-- Synthetic Draft-02 logical state (loaded into a database migrated only up to 0007)
\i ../fixtures/draft02_logical_state.sql
grant usage on schema d02 to bnx_definer;
grant select on all tables in schema d02 to bnx_definer;
select t.setup();
set role bnx_definer;
insert into bnx.journal_entry(id,economic_type,transaction_date,posting_date,posting_date_status,description,ledger_version,origin_channel,created_by_member,confirmed_by_member)
values (t.uuid('j1'),'opening_balance','2024-01-01','2024-01-01','user_confirmed','Opening v1',1,'system_opening',t.uuid('ann'),t.uuid('ann')),
       (t.uuid('j2'),'opening_balance','2024-01-01','2024-01-01','user_confirmed','Opening v2',2,'system_opening',t.uuid('ann'),t.uuid('ann')),
       (t.uuid('j3'),'consumption_expense','2024-03-31','2024-03-31','estimated','Groceries',3,'pwa',t.uuid('ann'),t.uuid('ann'));
insert into bnx.journal_line(id,journal_id,ledger_account_id,currency,amount) values
 (gen_random_uuid(),t.uuid('j1'),t.uuid('la-chq'),'CAD',5000),(gen_random_uuid(),t.uuid('j1'),t.uuid('la-eq'),'CAD',-5000),
 (gen_random_uuid(),t.uuid('j2'),t.uuid('la-chq'),'CAD',5200),(gen_random_uuid(),t.uuid('j2'),t.uuid('la-eq'),'CAD',-5200),
 (t.uuid('l3'),t.uuid('j3'),t.uuid('la-exp'),'CAD',60),(gen_random_uuid(),t.uuid('j3'),t.uuid('la-chq'),'CAD',-60);
update bnx.ledger_state set version = 3;
insert into bnx.source_txn values (t.uuid('st1'),t.uuid('ac-chq'),'2024-04-01',null,-60,'CAD','groceries',null,1,'\x01');
reset role;
insert into d02.opening_anchor values (t.uuid('ac-chq'),'2024-01-01',5200,t.uuid('j2'),'manual_declaration','declared',null,2);
insert into d02.opening_anchor_history values (t.uuid('ac-chq'),1,'2024-01-01',5000,t.uuid('j1'),null,null,null,'typo corrected',t.uuid('ann'),'2026-01-05');
insert into d02.posting_date_confirmation values (t.uuid('j3'),'2024-04-01','2026-02-01'),(t.uuid('j3'),'2024-04-02','2026-02-03');
insert into d02.match_decision values (t.uuid('md1'),t.uuid('st1'),'ledger',t.uuid('l3'),'MR-09','superseded','{}',t.uuid('ann'),'2026-02-01',null),
                                      (t.uuid('md2'),t.uuid('st1'),'ledger',t.uuid('l3'),'MR-08','confirmed','{}',t.uuid('ann'),'2026-02-02',t.uuid('md1'));
