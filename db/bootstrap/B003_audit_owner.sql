-- B003 Audit chain under its own owner (G0 finding F-01, 2026-11-11; migration 9011 block G0R). Run by the installer
-- identity, the same way as B002, after the migrations up to 9010 and before 9011. The runner stops before 9011 with
-- BOOTSTRAP_MISSING until this file has been applied. Re-runnable: a repeat run is a no-op.
--
-- Why: bnx.audit_event was owned by bnx_definer, and bnx_migrator can SET ROLE bnx_definer. A table owner may TRUNCATE
-- the table and disable its triggers, and a schema owner may drop any table in its schema. So the migrator credential
-- could empty, shorten or replace the audit chain while bnx.audit_verify() still returned 0.
-- After B003 the table is bnx_audit.audit_event: schema bnx_audit and the table belong to balnexa_audit_owner (NOLOGIN; no
-- member may SET or INHERIT it). bnx_definer keeps only SELECT and INSERT on the table and USAGE on the schema, so every
-- audited write path keeps working, while TRUNCATE, DELETE, UPDATE, DROP, trigger changes and ownership changes are
-- refused to it. bnx.audit_event remains as a view owned by bnx_definer, for readers and for the R1/9005 functions until
-- 9011 points them at bnx_audit.audit_event. A superuser can still do anything (the documented V8.6 residual; the
-- external anchor of 9016 and tools/s4/audit_chain_verify.py --anchor cover it).
--
-- Fresh install order: B001 -> B002 -> run_migrations.py (stops before 9011, exit 6) -> B003 -> run_migrations.py.
-- A non-superuser CREATEROLE installer runs this file with PGOPTIONS='-c createrole_self_grant=set,inherit', like B002.
-- Installer names must not start with 'bnx_' (that prefix is reserved for the product's roles; G0 finding F-02).
-- The owner role is named balnexa_audit_owner, outside the bnx_ prefix: roles are cluster-wide, and the immutable privilege
-- audits of 9002..9010 count exactly nine bnx_* roles when a second database is installed in the same cluster.
-- Backups must include schema bnx_audit (pg_dump ... --schema=bnx --schema=bnx_audit --schema=auth).
\set ON_ERROR_STOP 1
-- Re-run guard from the system catalogs only: after B002 the installer holds ADMIN-only memberships and cannot read bnx.
select exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'bnx_audit' and c.relname = 'audit_event' and c.relkind = 'r'
                  and pg_get_userbyid(c.relowner) = 'balnexa_audit_owner') as b003_applied \gset
\if :b003_applied
\echo 'B003 already applied: no change'
\quit
\endif
do $$
begin
  if (select count(*) from pg_namespace where nspname in ('bnx_doc','bnx_intake','bnx_tax','bnx_fed')) <> 4 then
    raise exception 'B003_ORDER: B002 has not been applied' using errcode = 'P0412';
  end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'bnx' and c.relname = 'audit_event' and c.relkind = 'r') then
    raise exception 'B003_ORDER: table bnx.audit_event does not exist; run the migrations up to 9010 first' using errcode = 'P0412';
  end if;
  if current_user like 'bnx\_%' or current_user = 'balnexa_audit_owner' then
    raise exception 'B003_INSTALLER_NAME: the installer name must not start with bnx_ (reserved prefix)' using errcode = 'P0412';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'balnexa_audit_owner') then
    create role balnexa_audit_owner nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls connection limit 0;
  end if;
end $$;

-- temporary memberships of the installer, needed for the moves below; removed again at the end of this file
grant bnx_definer to current_user with inherit true, set true;
grant balnexa_audit_owner to current_user with inherit true, set true;

create schema bnx_audit authorization balnexa_audit_owner;
revoke all on schema bnx_audit from public;
grant usage on schema bnx_audit to bnx_definer, bnx_backup;
alter default privileges for role balnexa_audit_owner in schema bnx_audit revoke all on tables from public;
alter default privileges for role balnexa_audit_owner in schema bnx_audit revoke all on sequences from public;
alter default privileges for role balnexa_audit_owner in schema bnx_audit grant select on tables to bnx_backup;
alter default privileges for role balnexa_audit_owner in schema bnx_audit grant select on sequences to bnx_backup;

alter table bnx.audit_event set schema bnx_audit;
alter table bnx_audit.audit_event owner to balnexa_audit_owner;
revoke all on bnx_audit.audit_event from bnx_definer;
grant select, insert on bnx_audit.audit_event to bnx_definer;   -- bnx.audit() and the verifiers; nothing else
grant select on bnx_audit.audit_event to bnx_backup;

-- 9011 review R-10: every inserted row must extend the chain exactly (next seq, prev_hash = current head hash, chain version
-- not decreasing, hash recomputed from the row). The function and the trigger belong to balnexa_audit_owner, so the owner
-- path (bnx_migrator -> SET ROLE bnx_definer) can neither replace nor disable them: an INSERT that would break the chain
-- (a wrong hash, a gap, a fork) is refused instead of poisoning bnx.audit_verify() forever. A correctly hashed forged
-- append stays possible to the definer, as bnx.audit() itself must be (residual R-3, G0R §4).
set role balnexa_audit_owner;
create function bnx_audit.trg_chain_append() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $f$
declare h record; c bytea;
begin
  select seq, hash, chain_version into h from bnx_audit.audit_event order by seq desc limit 1;
  if new.seq is distinct from coalesce(h.seq, 0) + 1 then
    raise exception 'AUDIT_CHAIN_APPEND' using errcode = 'P0409', detail = 'seq'; end if;
  if new.prev_hash is distinct from h.hash then
    raise exception 'AUDIT_CHAIN_APPEND' using errcode = 'P0409', detail = 'prev_hash'; end if;
  if new.chain_version is null or new.chain_version < coalesce(h.chain_version, 1) then
    raise exception 'AUDIT_CHAIN_APPEND' using errcode = 'P0409', detail = 'chain_version'; end if;
  if new.chain_version = 1 then
    c := convert_to(concat_ws('|', new.seq, new.member_id, new.connection_id, new.channel, new.command, new.subject::text,
                              encode(new.payload_sha256, 'hex'), new.ledger_version), 'UTF8');
  else
    c := convert_to(jsonb_build_array(new.seq, new.member_id, new.connection_id, new.channel, new.command, new.subject,
                                      encode(new.payload_sha256, 'hex'), new.ledger_version,
                                      to_char(new.at_hashed at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), new.chain_version,
                                      new.host_profile, new.tool_name, new.tool_version, new.trace_id)::text, 'UTF8');
  end if;
  if new.hash is distinct from sha256(coalesce(new.prev_hash, '\x'::bytea) || c) then
    raise exception 'AUDIT_CHAIN_APPEND' using errcode = 'P0409', detail = 'hash'; end if;
  return new;
end $f$;
revoke all on function bnx_audit.trg_chain_append() from public;
create trigger t_chain_append before insert on bnx_audit.audit_event for each row execute function bnx_audit.trg_chain_append();
reset role;

-- compatibility view, owned by bnx_definer (the definer's default privileges give bnx_backup SELECT on it)
set role bnx_definer;
create view bnx.audit_event as select * from bnx_audit.audit_event;
comment on view bnx.audit_event is 'B003: read path to bnx_audit.audit_event (G0 F-01); inserts pass through to the table';
reset role;

insert into bnx.schema_bootstrap(version) values ('B003') on conflict (version) do nothing;

-- Remove every membership this installer granted to itself (here or through createrole_self_grant). The ADMIN-only
-- membership PostgreSQL keeps for a CREATEROLE installer stays; it is the only one audit_privileges() accepts.
-- No-op for a superuser installer beyond the two grants above.
do $$
declare r record;
begin
  for r in select g.rolname from pg_auth_members am join pg_roles g on g.oid = am.roleid
            where am.member = (select oid from pg_roles where rolname = current_user)
              and am.grantor = (select oid from pg_roles where rolname = current_user) and (g.rolname like 'bnx\_%' or g.rolname = 'balnexa_audit_owner') loop
    execute format('revoke %I from %I', r.rolname, current_user);
  end loop;
end $$;
