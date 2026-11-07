-- Draft-02 logical rows (schema d02, created by the installer from db/history/draft04/fixtures/draft02_logical_state.sql)
insert into d02.opening_anchor values (md5('ac-chq')::uuid,'2024-01-01',5200,md5('j2')::uuid,'manual_declaration','declared',null,2);
insert into d02.opening_anchor_history values (md5('ac-chq')::uuid,1,'2024-01-01',5000,md5('j1')::uuid,null,null,null,'typo corrected',md5('ann')::uuid,'2026-01-05');
insert into d02.posting_date_confirmation values (md5('j3')::uuid,'2024-04-01','2026-02-01'),(md5('j3')::uuid,'2024-04-02','2026-02-03');
insert into d02.match_decision values (md5('md1')::uuid,md5('st1')::uuid,'ledger',md5('l3')::uuid,'MR-09','superseded','{}',md5('ann')::uuid,'2026-02-01',null),
                                      (md5('md2')::uuid,md5('st1')::uuid,'ledger',md5('l3')::uuid,'MR-08','confirmed','{}',md5('ann')::uuid,'2026-02-02',md5('md1')::uuid);
grant usage on schema d02 to bnx_definer;
grant select on all tables in schema d02 to bnx_definer;
