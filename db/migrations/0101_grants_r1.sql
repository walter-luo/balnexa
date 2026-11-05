-- 0101 Grants (successor of Draft-04 0007, which needed RESET ROLE and superuser-level schema grants).
-- Runs entirely as bnx_definer. Schema usage and backup default privileges are established by B001.
set role bnx_definer;
revoke all on all tables    in schema bnx from public, bnx_app, bnx_worker, bnx_authn, bnx_auth;
revoke all on all sequences in schema bnx from public, bnx_app, bnx_worker, bnx_authn, bnx_auth;
revoke all on all functions in schema bnx from public;
-- tables created before B001 defaults existed would be covered here; the privilege audit (bnx.audit_privileges)
-- fails the migration if any bnx/auth table or sequence is not readable by bnx_backup.
grant select on all tables    in schema bnx to bnx_backup;
grant select on all sequences in schema bnx to bnx_backup;
