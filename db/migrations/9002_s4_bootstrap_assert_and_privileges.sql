-- 9002 S4 bootstrap assertion and privilege model for nine roles and seven schemas (V1.2 UA §6.1–§6.3; OBJ-383;
-- CROSS-01; S4B-F01/F10/F17). MODIFY bnx.apply_grants() and bnx.audit_privileges() (same signatures, OBJ MODIFY rows);
-- NEW bnx.schema_registry, bnx.migration_seeded_table, bnx.rule_activation_version.
set role bnx_definer;

-- B002 must be present (the runner checks the same before applying this file; this is defence in depth)
do $$
begin
  if not exists (select 1 from bnx.schema_bootstrap where version = 'B002') then
    raise exception 'BOOTSTRAP_MISSING: B002 has not been applied' using errcode = 'P0412';
  end if;
  if (select count(*) from pg_namespace where nspname in ('bnx_doc','bnx_intake','bnx_tax','bnx_fed')
        and pg_get_userbyid(nspowner) = 'bnx_definer') <> 4 then
    raise exception 'BOOTSTRAP_MISSING: S4 schemas absent or not owned by bnx_definer' using errcode = 'P0412';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'bnx_stager') or not exists (select 1 from pg_roles where rolname = 'bnx_fed_reader') then
    raise exception 'BOOTSTRAP_MISSING: S4 roles absent' using errcode = 'P0412';
  end if;
end $$;

-- Registered schemas and the roles that must (and alone may) hold USAGE on each (RUNTIME_SCHEMA_USAGE).
create table bnx.schema_registry(nspname text primary key, owner text not null, usage_roles text[] not null,
  registered_by text not null);
insert into bnx.schema_registry values
 ('bnx',        'bnx_definer', array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'], 'B001+B002'),
 ('bnx_rpt',    'bnx_definer', array['bnx_backup','bnx_stager','bnx_fed_reader'], 'B001+B002'),
 ('auth',       'bnx_auth',    array['bnx_backup','bnx_stager','bnx_fed_reader'], 'B001+B002'),
 ('bnx_doc',    'bnx_definer', array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'], 'B002'),
 ('bnx_intake', 'bnx_definer', array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'], 'B002'),
 ('bnx_tax',    'bnx_definer', array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'], 'B002'),
 ('bnx_fed',    'bnx_definer', array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'], 'B002');

-- Tables whose rows are written by migrations (seed data); the backup preamble generator (9016) reads this list so a
-- data-only restore does not duplicate seeded rows (S4B-F11).
create table bnx.migration_seeded_table(table_name text primary key, seeded_by text not null, note text not null);
insert into bnx.migration_seeded_table values
 ('bnx.ledger_state', '0002', 'singleton version clock'),
 ('bnx.table_class',  '0002+', 'class register; every migration adds rows'),
 ('bnx.currency',     '0106', 'ISO 4217 seed; extended in 9006'),
 ('bnx.queue_state',  '0106', 'singleton queue authority'),
 ('bnx.schema_registry', '9002', 'registered schemas'),
 ('bnx.migration_seeded_table', '9002', 'this register');

-- Version at which a rule became active; rules never re-judge facts recorded before (S4B-F15; used from 9008).
create table bnx.rule_activation_version(rule_key text primary key, activated_at_version bigint not null,
  migration text not null, activated_at timestamptz not null default now());

insert into bnx.table_class values ('schema_registry','M'),('migration_seeded_table','M'),('rule_activation_version','F');
create trigger t_append_only before update or delete on bnx.rule_activation_version
  for each row execute function bnx.trg_append_only();

-- Restore mode: S4 triggers reuse R1 bnx.restore_mode() (0102; session_user = bnx_migrator AND GUC on) - REUSE, not redefined.

-- Prefix-based EXECUTE grants over every registered bnx-owned schema (MODIFY of 0108; same signature).
create or replace function bnx.apply_grants() returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('bnx','bnx_rpt','bnx_doc','bnx_intake','bnx_tax','bnx_fed') loop
    execute format('revoke all on function %s from public, bnx_app, bnx_worker, bnx_authn, bnx_auth, bnx_backup, bnx_stager, bnx_fed_reader',
                   f.sig);
    if f.proname like 'cmd\_%' or f.proname like 'q\_%' then execute format('grant execute on function %s to bnx_app', f.sig);
    elsif f.proname like 'wrk\_%' then execute format('grant execute on function %s to bnx_worker', f.sig);
    elsif f.proname like 'authn\_%' then execute format('grant execute on function %s to bnx_authn', f.sig);
    elsif f.proname like 'stg\_%' then execute format('grant execute on function %s to bnx_stager', f.sig);
    elsif f.proname like 'fed\_%' then execute format('grant execute on function %s to bnx_fed_reader', f.sig);
    end if;  -- pol_*, install_*, helpers: no runtime EXECUTE
  end loop;
end $$;

-- Machine-checked privilege audit (MODIFY of 0108; same signature). Returns {"violations":[...], "matrix":[...]}.
create or replace function bnx.audit_privileges() returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v jsonb := '[]'; m jsonb; r record; role_ text; p text; s record; installer text;
        nine text[] := array['bnx_definer','bnx_migrator','bnx_app','bnx_worker','bnx_authn','bnx_auth','bnx_backup',
                             'bnx_fed_reader','bnx_stager'];
        runtime text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'];
        nonowner text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader','bnx_migrator'];
        regs text[];
begin
  select array_agg(nspname order by nspname) into regs from bnx.schema_registry;
  select applied_by_session into installer from bnx.schema_bootstrap where version = 'B001';
  -- role inventory: exactly nine bnx_* roles (CROSS-01)
  for r in select rolname from pg_roles where rolname like 'bnx\_%' and rolname <> all(nine) loop
    v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'extra', r.rolname); end loop;
  foreach role_ in array nine loop
    if not exists (select 1 from pg_roles where rolname = role_) then
      v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'missing', role_); end if;
  end loop;
  -- role attributes
  for r in select rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolinherit, rolcanlogin
             from pg_roles where rolname like 'bnx\_%' loop
    if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then
      v := v || jsonb_build_object('rule', 'ROLE_ATTRIBUTE', 'role', r.rolname); end if;
    if r.rolname = 'bnx_definer' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'DEFINER_LOGIN'); end if;  -- R1 rule; bnx_auth is LOGIN in B001
    if r.rolname = 'bnx_migrator' and r.rolinherit then v := v || jsonb_build_object('rule', 'MIGRATOR_INHERITS'); end if;
  end loop;
  -- memberships: the documented definer->migrator SET-only grant; and (S4B-F17) the installer's automatic ADMIN
  -- ADMIN-only membership (no INHERIT, no SET) in the roles it created when the installer is a non-superuser CREATEROLE
  -- role (Neon project owner); same rule as amended 0108. B002 removes the installer's own SET/INHERIT self-grants.
  for r in select g.rolname grp, u.rolname mem, am.inherit_option, am.set_option, am.admin_option
             from pg_auth_members am join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member
            where g.rolname like 'bnx\_%' or u.rolname like 'bnx\_%' loop
    if r.grp = 'bnx_definer' and r.mem = 'bnx_migrator' and not r.inherit_option and r.set_option and not r.admin_option then
      null;
    elsif r.grp = any(nine) and r.mem = installer and r.mem not like 'bnx\_%' and r.admin_option and not r.inherit_option and not r.set_option then
      null;  -- INSTALLER_MEMBERSHIP accepted
    elsif r.grp = any(nine) and r.mem not like 'bnx\_%' then
      v := v || jsonb_build_object('rule', 'INSTALLER_MEMBERSHIP', 'group', r.grp, 'member', r.mem, 'inherit', r.inherit_option,
                                   'admin', r.admin_option);
    else
      v := v || jsonb_build_object('rule', 'UNEXPECTED_MEMBERSHIP', 'group', r.grp, 'member', r.mem);
    end if;
  end loop;
  -- schemas: registered ones only; owner as registered; nobody else may CREATE; USAGE exactly as registered
  -- an unregistered schema is a violation when a bnx_* role owns it or any object in it, or holds any privilege on it
  -- (foreign schemas of the installer, e.g. the Draft-02 conversion source d02 read by bnx_definer in 9001, are ignored)
  -- runtime roles: any USAGE/CREATE on an unregistered schema is a violation
  for r in select n.oid, n.nspname, pg_get_userbyid(n.nspowner) owner from pg_namespace n
            where n.nspname not like 'pg\_%' and n.nspname not in ('information_schema','public') loop
    select * into s from bnx.schema_registry where nspname = r.nspname;
    if not found then
      if r.owner like 'bnx\_%'
         or exists (select 1 from pg_class c where c.relnamespace = r.oid and pg_get_userbyid(c.relowner) like 'bnx\_%')
         or exists (select 1 from pg_proc p where p.pronamespace = r.oid and pg_get_userbyid(p.proowner) like 'bnx\_%')
         or exists (select 1 from unnest(runtime) x where has_schema_privilege(x, r.oid, 'USAGE') or has_schema_privilege(x, r.oid, 'CREATE')) then
        v := v || jsonb_build_object('rule', 'NEW_SCHEMA_UNREGISTERED', 'schema', r.nspname, 'owner', r.owner);
      end if;
      continue;
    end if;
    if r.owner <> s.owner then v := v || jsonb_build_object('rule', 'SCHEMA_OWNER', 'schema', r.nspname, 'owner', r.owner); end if;
    if not has_schema_privilege('bnx_backup', r.nspname, 'USAGE') then
      v := v || jsonb_build_object('rule', 'BACKUP_SCHEMA_USAGE', 'schema', r.nspname); end if;
    foreach role_ in array runtime loop
      if has_schema_privilege(role_, r.nspname, 'USAGE') <> (role_ = any(s.usage_roles)) then
        v := v || jsonb_build_object('rule', 'RUNTIME_SCHEMA_USAGE', 'schema', r.nspname, 'role', role_,
                                     'has_usage', has_schema_privilege(role_, r.nspname, 'USAGE')); end if;
    end loop;
  end loop;
  for r in select n.nspname from pg_namespace n where n.nspname = any(regs || array['public']) loop
    foreach role_ in array nonowner loop
      if has_schema_privilege(role_, r.nspname, 'CREATE') then
        v := v || jsonb_build_object('rule', 'SCHEMA_CREATE', 'schema', r.nspname, 'role', role_); end if;
    end loop;
  end loop;
  -- relations
  for r in select n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner) owner, c.oid
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = any(regs) and c.relkind in ('r','p','S','v','m') loop
    if r.nspname <> 'auth' and r.owner <> 'bnx_definer' then
      v := v || jsonb_build_object('rule', 'OWNER', 'object', r.nspname || '.' || r.relname, 'owner', r.owner); end if;
    if r.nspname = 'auth' and r.owner <> 'bnx_auth' then
      v := v || jsonb_build_object('rule', 'OWNER', 'object', r.nspname || '.' || r.relname, 'owner', r.owner); end if;
    if r.relkind in ('r','p','S') and not has_table_privilege('bnx_backup', r.oid, 'SELECT') then
      v := v || jsonb_build_object('rule', 'BACKUP_CANNOT_READ', 'object', r.nspname || '.' || r.relname); end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if r.relkind <> 'S' and has_table_privilege('bnx_backup', r.oid, p) then
        v := v || jsonb_build_object('rule', 'BACKUP_WRITE', 'object', r.relname, 'priv', p); end if;
    end loop;
    if r.relkind = 'S' and has_sequence_privilege('bnx_backup', r.oid, 'USAGE,UPDATE') then
      v := v || jsonb_build_object('rule', 'BACKUP_SEQUENCE_WRITE', 'object', r.relname); end if;
    foreach role_ in array array['bnx_app','bnx_worker','bnx_authn','bnx_migrator','bnx_stager','bnx_fed_reader'] loop
      if r.relkind <> 'S' and (has_table_privilege(role_, r.oid, 'SELECT') or has_table_privilege(role_, r.oid, 'INSERT')
          or has_table_privilege(role_, r.oid, 'UPDATE') or has_table_privilege(role_, r.oid, 'DELETE')
          or has_table_privilege(role_, r.oid, 'TRUNCATE')) then
        v := v || jsonb_build_object('rule', 'RUNTIME_TABLE_PRIVILEGE', 'object', r.nspname || '.' || r.relname, 'role', role_); end if;
      if r.relkind = 'S' and has_sequence_privilege(role_, r.oid, 'USAGE,SELECT,UPDATE') then
        v := v || jsonb_build_object('rule', 'RUNTIME_SEQUENCE_PRIVILEGE', 'object', r.relname, 'role', role_); end if;
    end loop;
  end loop;
  -- functions in every registered schema except auth (auth functions are owned by bnx_auth and never granted)
  for r in select n.nspname, p.oid, p.proname, p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner) owner,
                  has_function_privilege('public', p.oid, 'EXECUTE') pub,
                  has_function_privilege('bnx_app', p.oid, 'EXECUTE') app,
                  has_function_privilege('bnx_worker', p.oid, 'EXECUTE') wrk,
                  has_function_privilege('bnx_authn', p.oid, 'EXECUTE') authn,
                  has_function_privilege('bnx_backup', p.oid, 'EXECUTE') bak,
                  has_function_privilege('bnx_stager', p.oid, 'EXECUTE') stg,
                  has_function_privilege('bnx_fed_reader', p.oid, 'EXECUTE') fed
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = any(regs) and n.nspname <> 'auth' loop
    if r.pub then v := v || jsonb_build_object('rule', 'PUBLIC_EXECUTE', 'function', r.proname); end if;
    if r.prosecdef and not coalesce('search_path=pg_catalog, pg_temp' = any(r.proconfig), false) then
      v := v || jsonb_build_object('rule', 'DEFINER_SEARCH_PATH', 'function', r.proname); end if;
    if r.owner <> 'bnx_definer' then v := v || jsonb_build_object('rule', 'FUNCTION_OWNER', 'function', r.proname); end if;
    if r.app <> (r.proname like 'cmd\_%' or r.proname like 'q\_%') or r.wrk <> (r.proname like 'wrk\_%')
       or r.authn <> (r.proname like 'authn\_%') or r.bak or r.fed <> (r.proname like 'fed\_%') then
      v := v || jsonb_build_object('rule', 'EXECUTE_GRANT', 'function', r.nspname || '.' || r.proname, 'app', r.app,
                                   'worker', r.wrk, 'authn', r.authn, 'backup', r.bak, 'fed_reader', r.fed); end if;
    if r.stg <> (r.proname like 'stg\_%') then
      v := v || jsonb_build_object('rule', 'STAGER_NO_POSTING', 'function', r.nspname || '.' || r.proname, 'stager', r.stg); end if;
  end loop;
  -- default privileges must cover future tables and sequences of both creators in every registered schema
  for r in select g.nspname, g.owner, k.kind from bnx.schema_registry g cross join (values ('r'), ('S')) k(kind) loop
    if not exists (select 1 from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
                    where pg_get_userbyid(d.defaclrole) = r.owner and n.nspname = r.nspname and d.defaclobjtype = r.kind::"char"
                      and exists (select 1 from aclexplode(d.defaclacl) x where x.grantee = 'bnx_backup'::regrole and x.privilege_type = 'SELECT')) then
      v := v || jsonb_build_object('rule', 'DEFAULT_PRIVILEGE_MISSING', 'entry', r.owner || ':' || r.nspname || ':' || r.kind); end if;
  end loop;
  select jsonb_agg(jsonb_build_object('object', n.nspname || '.' || c.relname, 'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner),
           'backup_select', has_table_privilege('bnx_backup', c.oid, 'SELECT'),
           'app_any', has_table_privilege('bnx_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE'),
           'worker_any', has_table_privilege('bnx_worker', c.oid, 'SELECT,INSERT,UPDATE,DELETE'))
           order by n.nspname, c.relname) into m
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = any(regs) and c.relkind in ('r','p','S','v');
  return jsonb_build_object('violations', v, 'matrix', coalesce(m, '[]'));
end $$;

grant select on bnx.schema_registry, bnx.migration_seeded_table, bnx.rule_activation_version to bnx_backup;
select bnx.apply_grants();
