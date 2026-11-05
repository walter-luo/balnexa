-- 0001 Roles, schemas, extensions. Run by the installer as a role allowed to create roles and extensions
-- (local: superuser; Neon: the project owner role — role semantics on Neon REQUIRES_M0_EVIDENCE, NEW-010).
-- Login passwords are NOT set here; the installer sets them out of band and stores them as secrets (§H8).
do $$
declare r record;
begin
  for r in select * from (values
      ('bnx_definer', false), ('bnx_app', true), ('bnx_worker', true), ('bnx_authn', true),
      ('bnx_auth', true), ('bnx_backup', true)) as t(name, login)
  loop
    if not exists (select 1 from pg_roles where rolname = r.name) then
      execute format('create role %I %s', r.name, case when r.login then 'login' else 'nologin' end);
    end if;
  end loop;
end $$;
alter role bnx_app    connection limit 20;
alter role bnx_worker connection limit 10;
alter role bnx_authn  connection limit 5;
alter role bnx_auth   connection limit 5;
alter role bnx_backup connection limit 2;

-- The migrator may SET ROLE bnx_definer but does not inherit its privileges (PostgreSQL 16 syntax; §H2).
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'bnx_migrator') then
    execute 'grant bnx_definer to bnx_migrator with inherit false, set true';
  end if;
end $$;

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create schema bnx     authorization bnx_definer;
create schema bnx_rpt authorization bnx_definer;
create schema auth    authorization bnx_auth;
revoke all on schema public from public;
revoke all on schema bnx, bnx_rpt from public;
grant usage on schema bnx to bnx_app, bnx_worker, bnx_authn;
alter default privileges for role bnx_definer in schema bnx, bnx_rpt revoke all on tables from public;
alter default privileges for role bnx_definer revoke execute on functions from public;

alter role bnx_app    set statement_timeout = '15s';
alter role bnx_worker set statement_timeout = '30s';
alter role bnx_authn  set statement_timeout = '5s';
alter role bnx_app    set idle_in_transaction_session_timeout = '5s';
alter role bnx_backup set default_transaction_read_only = on;

create table bnx.schema_migrations(version text primary key, sha256 text not null, applied_at timestamptz not null default now());
alter table bnx.schema_migrations owner to bnx_definer;
