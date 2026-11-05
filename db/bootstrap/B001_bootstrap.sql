-- B001 Privileged bootstrap (AUD-049, AUD-050). Supersedes the privileged half of Draft-04 0001 (preserved unchanged in
-- db/history/draft04). Run ONCE per database by the installer identity that may create roles and extensions
-- (local test: superuser; Neon: the project owner role — Neon semantics M0_PENDING, M0-C-06).
-- After this file, every migration is applied by bnx_migrator, which may SET ROLE bnx_definer but inherits nothing.
-- Passwords are never set here; the installer sets them out of band and stores them as secrets.
\set ON_ERROR_STOP 1
do $$
declare r record;
begin
  for r in select * from (values
      ('bnx_definer', false), ('bnx_migrator', true), ('bnx_app', true), ('bnx_worker', true),
      ('bnx_authn', true), ('bnx_auth', true), ('bnx_backup', true)) as t(name, login)
  loop
    if not exists (select 1 from pg_roles where rolname = r.name) then
      execute format('create role %I %s nosuperuser nocreatedb nocreaterole noreplication nobypassrls',
                     r.name, case when r.login then 'login' else 'nologin' end);
    end if;
  end loop;
end $$;
-- The migrator may switch to the owner role but does not inherit its privileges (PostgreSQL 16+ syntax).
grant bnx_definer to bnx_migrator with inherit false, set true;
alter role bnx_migrator noinherit;

alter role bnx_app    connection limit 20;
alter role bnx_worker connection limit 10;
alter role bnx_authn  connection limit 5;
alter role bnx_auth   connection limit 5;
alter role bnx_backup connection limit 2;
alter role bnx_migrator connection limit 2;
alter role bnx_app    set statement_timeout = '15s';
alter role bnx_worker set statement_timeout = '30s';
alter role bnx_authn  set statement_timeout = '5s';
alter role bnx_app    set idle_in_transaction_session_timeout = '5s';
alter role bnx_backup set default_transaction_read_only = on;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create schema bnx     authorization bnx_definer;
create schema bnx_rpt authorization bnx_definer;
create schema auth    authorization bnx_auth;
revoke all on schema public from public;
revoke create on schema public from public;
revoke all on schema bnx, bnx_rpt from public;
revoke all on schema auth from public;
grant usage on schema bnx to bnx_app, bnx_worker, bnx_authn;
grant usage on schema bnx, bnx_rpt, auth to bnx_backup;

-- AUD-050: future objects created by either owner are readable by the backup role (tables AND sequences),
-- and no function is executable by PUBLIC by default.
alter default privileges for role bnx_definer in schema bnx, bnx_rpt revoke all on tables from public;
alter default privileges for role bnx_definer in schema bnx, bnx_rpt revoke all on sequences from public;
alter default privileges for role bnx_definer revoke execute on functions from public;
alter default privileges for role bnx_auth    revoke execute on functions from public;
alter default privileges for role bnx_definer in schema bnx, bnx_rpt grant select on tables to bnx_backup;
alter default privileges for role bnx_definer in schema bnx, bnx_rpt grant select on sequences to bnx_backup;
alter default privileges for role bnx_auth    in schema auth grant select on tables to bnx_backup;
alter default privileges for role bnx_auth    in schema auth grant select on sequences to bnx_backup;

-- Migration ledger, owned by the owner role. Only a session that switched to bnx_definer can write it.
create table bnx.schema_migrations(version text primary key, sha256 text not null,
  applied_at timestamptz not null default now(), applied_by_session text not null default session_user);
alter table bnx.schema_migrations owner to bnx_definer;
create table bnx.schema_bootstrap(version text primary key, applied_at timestamptz not null default now(),
  applied_by_session text not null default session_user);
alter table bnx.schema_bootstrap owner to bnx_definer;
insert into bnx.schema_bootstrap(version) values ('B001');
grant select on bnx.schema_migrations, bnx.schema_bootstrap to bnx_backup;
