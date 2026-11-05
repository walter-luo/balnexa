-- B002 Privileged bootstrap supplement for S4 (Balnexa V1.2 IL §3; OBJ-002). Run by the installer identity after B001
-- and before migration 9002. Idempotent: every statement can be repeated; the schema_bootstrap row is written once.
-- Creates the four S4 schemas and the two S4 roles (NOLOGIN; LOGIN is granted later only under the AI-ENTRY
-- database.neon.role_login conditions). Grants USAGE only (no table privileges) and the backup default privileges.
-- Migration 9002 (and run_migrations.py) refuse to continue unless this file has been applied.
\set ON_ERROR_STOP 1
do $$
declare r record;
begin
  for r in select * from (values ('bnx_fed_reader', 2), ('bnx_stager', 5)) as t(name, lim) loop
    if not exists (select 1 from pg_roles where rolname = r.name) then
      execute format('create role %I nologin nosuperuser nocreatedb nocreaterole noreplication nobypassrls connection limit %s',
                     r.name, r.lim);
    end if;
  end loop;
end $$;
alter role bnx_stager set statement_timeout = '10s';

create schema if not exists bnx_doc    authorization bnx_definer;
create schema if not exists bnx_intake authorization bnx_definer;
create schema if not exists bnx_tax    authorization bnx_definer;
create schema if not exists bnx_fed    authorization bnx_definer;
revoke all on schema bnx_doc, bnx_intake, bnx_tax, bnx_fed from public;

grant usage on schema bnx_doc, bnx_intake, bnx_tax, bnx_fed
  to bnx_backup, bnx_app, bnx_worker, bnx_authn, bnx_stager, bnx_fed_reader;
grant usage on schema bnx, bnx_rpt, auth to bnx_stager, bnx_fed_reader;   -- function resolution only; no table privileges

alter default privileges for role bnx_definer in schema bnx_doc, bnx_intake, bnx_tax, bnx_fed revoke all on tables from public;
alter default privileges for role bnx_definer in schema bnx_doc, bnx_intake, bnx_tax, bnx_fed revoke all on sequences from public;
alter default privileges for role bnx_definer in schema bnx_doc, bnx_intake, bnx_tax, bnx_fed grant select on tables to bnx_backup;
alter default privileges for role bnx_definer in schema bnx_doc, bnx_intake, bnx_tax, bnx_fed grant select on sequences to bnx_backup;

insert into bnx.schema_bootstrap(version) values ('B002') on conflict (version) do nothing;
