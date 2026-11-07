-- 0007 Grants. No login role receives table, sequence or view privileges. Readers are internal (called by
-- q_*/cmd_* definer functions, which are added with the Command Core migrations and granted by prefix).
set role bnx_definer;
revoke all on all tables in schema bnx from public, bnx_app, bnx_worker, bnx_authn, bnx_auth;
revoke all on all sequences in schema bnx from public, bnx_app, bnx_worker, bnx_authn, bnx_auth;
revoke all on all functions in schema bnx from public;
reset role;
grant usage on schema bnx, auth to bnx_backup;
grant select on all tables in schema bnx, auth to bnx_backup;    -- read-only backup role (§H2)
