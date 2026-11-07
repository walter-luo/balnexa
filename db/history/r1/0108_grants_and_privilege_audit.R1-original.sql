-- 0108 Worker revalidation step (AUD-053/INV-43), prefix-based EXECUTE grants, and the machine-checked privilege
-- audit (AUD-049/AUD-050). bnx.apply_grants() and bnx.audit_privileges() are re-run by the migration runner after
-- every migration; any violation aborts the run.
set role bnx_definer;

-- after a fail-closed activation refusal: stale (new approval required) or suspended (approver lost authority)
create function bnx.wrk_revalidate_plan(p_plan uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare pl record; ap bnx.actor;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into pl from bnx.posting_plan where id = p_plan for update;
  if not found or pl.state not in ('approved','executing','sealed') then return coalesce(pl.state, 'not_found'); end if;
  ap := row(pl.approved_by, null, 'pwa', null, array['post'])::bnx.actor;
  if not bnx.actor_can_post(ap, (pl.scope->>'account_currency_id')::uuid) then
    perform bnx.plan_terminate(p_plan, 'suspended', 'approver no longer authorized'); return 'suspended';
  end if;
  if bnx.scope_delta_exists(p_plan, pl.last_validated_version) then
    perform bnx.plan_terminate(p_plan, 'stale', 'scope changed after approval; new approval required'); return 'stale';
  end if;
  return pl.state;
end $$;

create function bnx.apply_grants() returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'bnx' loop
    execute format('revoke all on function %s from public, bnx_app, bnx_worker, bnx_authn, bnx_auth, bnx_backup', f.sig);
    if f.proname like 'cmd\_%' or f.proname like 'q\_%' then execute format('grant execute on function %s to bnx_app', f.sig);
    elsif f.proname like 'wrk\_%' then execute format('grant execute on function %s to bnx_worker', f.sig);
    elsif f.proname like 'authn\_%' then execute format('grant execute on function %s to bnx_authn', f.sig);
    end if;
  end loop;
end $$;

-- Returns {"violations":[...], "matrix":[...]}; an empty violations array is required by the runner.
create function bnx.audit_privileges() returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v jsonb := '[]'; m jsonb; r record; runtime text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup'];
        role_ text; p text;
begin
  -- roles
  for r in select rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolinherit, rolcanlogin
             from pg_roles where rolname like 'bnx\_%' loop
    if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then
      v := v || jsonb_build_object('rule', 'ROLE_ATTRIBUTE', 'role', r.rolname); end if;
    if r.rolname = 'bnx_definer' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'DEFINER_LOGIN'); end if;
    if r.rolname = 'bnx_migrator' and r.rolinherit then v := v || jsonb_build_object('rule', 'MIGRATOR_INHERITS'); end if;
  end loop;
  for r in select g.rolname grp, u.rolname mem, am.inherit_option, am.set_option, am.admin_option
             from pg_auth_members am join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member
            where g.rolname like 'bnx\_%' or u.rolname like 'bnx\_%' loop
    if not (r.grp = 'bnx_definer' and r.mem = 'bnx_migrator' and not r.inherit_option and r.set_option and not r.admin_option) then
      v := v || jsonb_build_object('rule', 'UNEXPECTED_MEMBERSHIP', 'group', r.grp, 'member', r.mem); end if;
  end loop;
  -- schemas: nobody but the owner may CREATE; runtime roles never own anything
  for r in select n.nspname, pg_get_userbyid(n.nspowner) owner from pg_namespace n where n.nspname in ('bnx','bnx_rpt','auth','public') loop
    foreach role_ in array runtime || array['bnx_migrator'] loop
      if has_schema_privilege(role_, r.nspname, 'CREATE') then
        v := v || jsonb_build_object('rule', 'SCHEMA_CREATE', 'schema', r.nspname, 'role', role_); end if;
    end loop;
  end loop;
  -- relations
  for r in select n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner) owner, c.oid
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname in ('bnx','bnx_rpt','auth') and c.relkind in ('r','p','S','v','m') loop
    if r.nspname in ('bnx','bnx_rpt') and r.owner <> 'bnx_definer' then
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
    foreach role_ in array array['bnx_app','bnx_worker','bnx_authn','bnx_migrator'] loop
      if r.relkind <> 'S' and (has_table_privilege(role_, r.oid, 'SELECT') or has_table_privilege(role_, r.oid, 'INSERT')
          or has_table_privilege(role_, r.oid, 'UPDATE') or has_table_privilege(role_, r.oid, 'DELETE')
          or has_table_privilege(role_, r.oid, 'TRUNCATE')) then
        v := v || jsonb_build_object('rule', 'RUNTIME_TABLE_PRIVILEGE', 'object', r.nspname || '.' || r.relname, 'role', role_); end if;
      if r.relkind = 'S' and has_sequence_privilege(role_, r.oid, 'USAGE,SELECT,UPDATE') then
        v := v || jsonb_build_object('rule', 'RUNTIME_SEQUENCE_PRIVILEGE', 'object', r.relname, 'role', role_); end if;
    end loop;
  end loop;
  -- functions
  for r in select p.oid, p.proname, p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner) owner,
                  has_function_privilege('public', p.oid, 'EXECUTE') pub,
                  has_function_privilege('bnx_app', p.oid, 'EXECUTE') app,
                  has_function_privilege('bnx_worker', p.oid, 'EXECUTE') wrk,
                  has_function_privilege('bnx_authn', p.oid, 'EXECUTE') authn,
                  has_function_privilege('bnx_backup', p.oid, 'EXECUTE') bak
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bnx' loop
    if r.pub then v := v || jsonb_build_object('rule', 'PUBLIC_EXECUTE', 'function', r.proname); end if;
    if r.prosecdef and not coalesce('search_path=pg_catalog, pg_temp' = any(r.proconfig), false) then
      v := v || jsonb_build_object('rule', 'DEFINER_SEARCH_PATH', 'function', r.proname); end if;
    if r.owner <> 'bnx_definer' then v := v || jsonb_build_object('rule', 'FUNCTION_OWNER', 'function', r.proname); end if;
    if r.app <> (r.proname like 'cmd\_%' or r.proname like 'q\_%') or r.wrk <> (r.proname like 'wrk\_%')
       or r.authn <> (r.proname like 'authn\_%') or r.bak then
      v := v || jsonb_build_object('rule', 'EXECUTE_GRANT', 'function', r.proname, 'app', r.app, 'worker', r.wrk,
                                   'authn', r.authn, 'backup', r.bak); end if;
  end loop;
  -- default privileges must cover future tables and sequences of both creators
  foreach role_ in array array['bnx_definer:bnx:r','bnx_definer:bnx:S','bnx_definer:bnx_rpt:r','bnx_definer:bnx_rpt:S',
                               'bnx_auth:auth:r','bnx_auth:auth:S'] loop
    if not exists (select 1 from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
                    where pg_get_userbyid(d.defaclrole) = split_part(role_, ':', 1) and n.nspname = split_part(role_, ':', 2)
                      and d.defaclobjtype = split_part(role_, ':', 3)
                      and exists (select 1 from aclexplode(d.defaclacl) x where x.grantee = 'bnx_backup'::regrole and x.privilege_type = 'SELECT')) then
      v := v || jsonb_build_object('rule', 'DEFAULT_PRIVILEGE_MISSING', 'entry', role_); end if;
  end loop;
  select jsonb_agg(jsonb_build_object('object', n.nspname || '.' || c.relname, 'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner),
           'backup_select', has_table_privilege('bnx_backup', c.oid, 'SELECT'),
           'app_any', has_table_privilege('bnx_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE'),
           'worker_any', has_table_privilege('bnx_worker', c.oid, 'SELECT,INSERT,UPDATE,DELETE'))
           order by n.nspname, c.relname) into m
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in ('bnx','bnx_rpt','auth') and c.relkind in ('r','p','S','v');
  return jsonb_build_object('violations', v, 'matrix', coalesce(m, '[]'));
end $$;

select bnx.apply_grants();
