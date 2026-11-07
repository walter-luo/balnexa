begin;
set role bnx_definer;
set local bnx.restore_mode = 'on';
truncate bnx.table_class, bnx.ledger_state, bnx.queue_state, bnx.currency, bnx.m1_future_fact cascade;
