-- 9011 (S4 V1.2, WP-DOC): documents, evidence, renditions. Increment 9011a: the SIN/ITN detector and the database guards.
-- Addendum A1 Rev 1 (branch s4/design-addendum-a1): §3 detector (guard C1), §7 DOC-SIN-10, guard C2. Later increments of this
-- work package (9011b intake states and declaration, 9011c Executor validators) extend this file before it is merged.
-- Synthetic data only. No function here is granted to a runtime role; they run inside SECURITY DEFINER callers.
--
-- MODIFY (bodies copied from their last version and changed only where marked "9011"):
--   bnx.audit                      (9005)  refuses SIN/ITN candidates in payload and subject (D-9011a-3)
--   bnx.stage_write                (9010)  masks index payloads, refuses other kinds (DOC-SIN-10, D-9011a-2)
--   bnx.wrk_consume_shared_index   (9010)  blocks masked records, stores no columns for them (DOC-SIN-10)
--   bnx.wrk_promote_staged         (9010)  dispatches doc_discovered / doc_validated / doc_archived to the 9011b promoters
-- 9011c adds no MODIFY: it writes bnx.evidence_object and bnx.evidence_file (0004, 9004) through new code in the admission
-- gate bnx.wrk_doc_archived, within the existing R1 constraints and write-once triggers.
-- G0R (G0 remediation, 2026-11-11) requires bootstrap B003 (db/bootstrap/B003_audit_owner.sql) before this file and MODIFYs:
--   bnx.audit_privileges           (9002)  ten roles; schema bnx_audit; AUDIT_TABLE_OWNER, AUDIT_TABLE_PRIVILEGE, AUDIT_TRIGGER,
--                                          AUDIT_OWNER_LOGIN; relation owner = registered schema owner
--   bnx.audit_verify, bnx.audit_head, bnx.trg_audit_chain_version (9005)  read bnx_audit.audit_event
--   bnx.envelope_value, bnx.resolve_actor (9005)  envelope values printable ASCII only (F-04)
--   bnx.audit (above, 9011a)       writes bnx_audit.audit_event

-- ---------- G0R: remediation of G0 findings F-01 and F-04 (G0 report 2026-11-11; docs/s4/G0_REMEDIATION_2026-11-11.md) ----------
-- F-01: bootstrap B003 has moved the audit chain to bnx_audit.audit_event, owned (with its schema) by balnexa_audit_owner;
-- bnx_definer keeps SELECT and INSERT only, and bnx.audit_event is a view. The runner refuses this file until B003 is
-- applied; this check is defence in depth.
do $$
begin
  if not exists (select 1 from bnx.schema_bootstrap where version = 'B003') or to_regclass('bnx_audit.audit_event') is null
     or (select pg_get_userbyid(relowner) from pg_class where oid = 'bnx_audit.audit_event'::regclass) <> 'balnexa_audit_owner' then
    raise exception 'BOOTSTRAP_MISSING: B003 has not been applied (bnx_audit.audit_event owned by balnexa_audit_owner)' using errcode = 'P0412';
  end if;
end $$;
insert into bnx.schema_registry values ('bnx_audit', 'balnexa_audit_owner', array['bnx_backup'], 'B003');

-- the chain functions write and read the table itself, not the compatibility view (the view belongs to bnx_definer and
-- could be redefined by the owner path; the table cannot). MODIFY of 9005 bodies; only the table name changed.
create or replace function bnx.trg_audit_chain_version() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.restore_mode() then return new; end if;
  if new.chain_version < coalesce((select max(chain_version) from bnx_audit.audit_event), 1) then
    raise exception 'AUDIT_CHAIN_VERSION: v% after v%', new.chain_version, (select max(chain_version) from bnx_audit.audit_event)
      using errcode = 'P0409';
  end if;
  return new;
end $$;

create or replace function bnx.audit_verify() returns bigint   -- returns 0 when intact, else the first bad seq
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare r record; prev bytea := null; expect bigint := 1; cv smallint := 1; h bytea;
begin
  for r in select * from bnx_audit.audit_event order by seq loop
    if r.seq <> expect or r.prev_hash is distinct from prev or r.chain_version < cv then return r.seq; end if;
    if r.chain_version = 1 then
      h := sha256(coalesce(prev, '\x'::bytea) || convert_to(concat_ws('|', r.seq, r.member_id, r.connection_id, r.channel, r.command,
             r.subject::text, encode(r.payload_sha256,'hex'), r.ledger_version), 'UTF8'));
    else
      h := sha256(coalesce(prev, '\x'::bytea) || bnx.audit_canonical_v2(r.seq, r.member_id, r.connection_id, r.channel, r.command,
             r.subject, encode(r.payload_sha256,'hex'), r.ledger_version, r.at_hashed, r.chain_version, r.host_profile, r.tool_name,
             r.tool_version, r.trace_id));
    end if;
    if r.hash <> h then return r.seq; end if;
    prev := r.hash; expect := expect + 1; cv := r.chain_version;
  end loop;
  return 0;
end $$;

create or replace function bnx.audit_head() returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select jsonb_build_object('seq', seq, 'hash', encode(hash, 'hex'), 'chain_version', chain_version)
                     from bnx_audit.audit_event order by seq desc limit 1), jsonb_build_object('seq', 0))
$$;

-- audit_privileges MODIFY (9002 body; changed only where marked "9011 G0R"): ten roles, schema bnx_audit, the audit table
-- owner, the audit table privileges of bnx_definer and its two append-only triggers.
create or replace function bnx.audit_privileges() returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v jsonb := '[]'; m jsonb; r record; role_ text; p text; s record; installer text;
        nine text[] := array['bnx_definer','bnx_migrator','bnx_app','bnx_worker','bnx_authn','bnx_auth','bnx_backup',
                             'bnx_fed_reader','bnx_stager','balnexa_audit_owner'];   -- 9011 G0R: + audit owner (B003)
        runtime text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'];
        nonowner text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader','bnx_migrator'];
        regs text[];
begin
  select array_agg(nspname order by nspname) into regs from bnx.schema_registry;
  select applied_by_session into installer from bnx.schema_bootstrap where version = 'B001';
  -- role inventory: exactly nine bnx_* roles (CROSS-01) plus balnexa_audit_owner (9011 G0R; outside the bnx_ prefix because
  -- roles are cluster-wide and the 9002..9010 audits of a second database in the same cluster count bnx_* roles)
  for r in select rolname from pg_roles where rolname like 'bnx\_%' and rolname <> all(nine) loop
    v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'extra', r.rolname); end loop;
  foreach role_ in array nine loop
    if not exists (select 1 from pg_roles where rolname = role_) then
      v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'missing', role_); end if;
  end loop;
  -- role attributes
  for r in select rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolinherit, rolcanlogin
             from pg_roles where rolname like 'bnx\_%' or rolname = 'balnexa_audit_owner' loop   -- 9011 G0R
    if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then
      v := v || jsonb_build_object('rule', 'ROLE_ATTRIBUTE', 'role', r.rolname); end if;
    if r.rolname = 'bnx_definer' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'DEFINER_LOGIN'); end if;  -- R1 rule; bnx_auth is LOGIN in B001
    if r.rolname = 'bnx_migrator' and r.rolinherit then v := v || jsonb_build_object('rule', 'MIGRATOR_INHERITS'); end if;
    if r.rolname = 'balnexa_audit_owner' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'AUDIT_OWNER_LOGIN'); end if;  -- 9011 G0R
  end loop;
  -- memberships: the documented definer->migrator SET-only grant; and (S4B-F17) the installer's automatic ADMIN
  -- ADMIN-only membership (no INHERIT, no SET) in the roles it created when the installer is a non-superuser CREATEROLE
  -- role (Neon project owner); same rule as amended 0108. B002 removes the installer's own SET/INHERIT self-grants.
  for r in select g.rolname grp, u.rolname mem, am.inherit_option, am.set_option, am.admin_option
             from pg_auth_members am join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member
            where g.rolname like 'bnx\_%' or u.rolname like 'bnx\_%' or 'balnexa_audit_owner' in (g.rolname, u.rolname) loop   -- 9011 G0R
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
    foreach role_ in array nonowner || (case when r.nspname = 'bnx_audit' then array['bnx_definer'] else array['balnexa_audit_owner'] end) loop   -- 9011 G0R
      if has_schema_privilege(role_, r.nspname, 'CREATE') then
        v := v || jsonb_build_object('rule', 'SCHEMA_CREATE', 'schema', r.nspname, 'role', role_); end if;
    end loop;
  end loop;
  -- relations
  for r in select n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner) owner, c.oid
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = any(regs) and c.relkind in ('r','p','S','v','m') loop
    -- 9011 G0R: the owner expected for every relation is the registered owner of its schema (bnx_auth for auth,
    -- balnexa_audit_owner for bnx_audit, bnx_definer for the others; identical to the 9002 rule for the 9002 schemas)
    if r.owner <> (select g.owner from bnx.schema_registry g where g.nspname = r.nspname) then
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
      -- column-level grants are invisible to has_table_privilege (same-family review finding 7)
      if r.relkind <> 'S' and has_any_column_privilege(role_, r.oid, 'SELECT,INSERT,UPDATE,REFERENCES') then
        v := v || jsonb_build_object('rule', 'RUNTIME_COLUMN_PRIVILEGE', 'object', r.nspname || '.' || r.relname, 'role', role_); end if;
    end loop;
    if r.relkind <> 'S' and has_any_column_privilege('bnx_backup', r.oid, 'INSERT,UPDATE,REFERENCES') then
      v := v || jsonb_build_object('rule', 'BACKUP_WRITE', 'object', r.relname, 'priv', 'COLUMN'); end if;
  end loop;
  -- 9011 G0R (G0 finding F-01): the audit chain is a table in bnx_audit; bnx_definer, which bnx_migrator can SET ROLE to,
  -- may only read and append it; both append-only triggers are present and enabled; bnx.audit_event is only a view
  if to_regclass('bnx_audit.audit_event') is null or (select relkind from pg_class where oid = to_regclass('bnx_audit.audit_event')) <> 'r' then
    v := v || jsonb_build_object('rule', 'AUDIT_TABLE_OWNER', 'object', 'bnx_audit.audit_event', 'missing', true);
  else
    if not has_table_privilege('bnx_definer', 'bnx_audit.audit_event', 'SELECT') or not has_table_privilege('bnx_definer', 'bnx_audit.audit_event', 'INSERT') then
      v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'missing', 'SELECT,INSERT'); end if;
    foreach p in array array['UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('bnx_definer', 'bnx_audit.audit_event', p) then
        v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'priv', p); end if;
    end loop;
    if has_any_column_privilege('bnx_definer', 'bnx_audit.audit_event', 'UPDATE,REFERENCES') then
      v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'priv', 'COLUMN'); end if;
    for r in select t.tgname from (values ('t_append_only'), ('t_chain_version')) t(tgname)
              where not exists (select 1 from pg_trigger g where g.tgrelid = 'bnx_audit.audit_event'::regclass and g.tgname = t.tgname
                                  and g.tgenabled = 'O') loop
      v := v || jsonb_build_object('rule', 'AUDIT_TRIGGER', 'trigger', r.tgname); end loop;
  end if;
  if coalesce((select relkind from pg_class where oid = to_regclass('bnx.audit_event')), 'v') <> 'v' then
    v := v || jsonb_build_object('rule', 'AUDIT_TABLE_OWNER', 'object', 'bnx.audit_event', 'kind', 'not a view'); end if;
  -- nothing owned by a bnx_* role may live in schema public (excluded from the schema loop because extensions live there):
  -- a SECURITY DEFINER function there would run with bnx privileges outside every rule above
  for r in select 'function' k, p.proname nm, pg_get_userbyid(p.proowner) owner from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and pg_get_userbyid(p.proowner) like 'bnx\_%'
           union all
           select 'relation', c.relname, pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and pg_get_userbyid(c.relowner) like 'bnx\_%' loop
    v := v || jsonb_build_object('rule', 'PUBLIC_SCHEMA_OBJECT', 'kind', r.k, 'object', 'public.' || r.nm, 'owner', r.owner);
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

-- F-04: envelope values are printable ASCII only (U+0020..U+007E), independent of the cluster locale. [[:print:]] accepted
-- invisible format characters such as U+200B under C.UTF-8.
create or replace function bnx.envelope_value(p_name text) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v text := nullif(current_setting('bnx.' || p_name, true), '');
begin
  if v is not null and (length(v) > 100 or v !~ '^[ -~]+$') then          -- 9011 G0R
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'envelope.' || p_name);
  end if;
  return v;
end $$;

-- resolve_actor MODIFY (9005 body; only the envelope rule changed, marked "9011 G0R")
create or replace function bnx.resolve_actor(cred jsonb) returns bnx.actor
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare h bytea; r record; a bnx.actor; k text; val text;
begin
  if cred is null or cred->>'secret' is null or length(cred->>'secret') < 32 then
    perform bnx.fail('UNAUTHENTICATED', 'P0401');
  end if;
  h := bnx.h(cred->>'secret');
  if cred->>'kind' = 'session' then
    select s.id, s.member_id, s.revoked_at, s.absolute_expires_at, s.last_seen_at, m.state into r
      from bnx.member_session s join bnx.member m on m.id = s.member_id where s.token_sha256 = h;
    if not found or r.revoked_at is not null or now() > r.absolute_expires_at
       or now() > r.last_seen_at + interval '30 days' or r.state <> 'active' then
      perform bnx.fail('UNAUTHENTICATED', 'P0401');
    end if;
    if r.last_seen_at < now() - interval '1 hour' then update bnx.member_session set last_seen_at = now() where id = r.id; end if;
    a := row(r.member_id, null, 'pwa', r.id, array['read','propose','post'])::bnx.actor;
  elsif cred->>'kind' = 'bearer' then
    select c.id cid, c.member_id, c.scopes, c.revoked_at crev, t.expires_at, t.revoked_at trev, m.state into r
      from bnx.ai_connection_token t join bnx.ai_connection c on c.id = t.connection_id
      join bnx.member m on m.id = c.member_id where t.token_sha256 = h and t.kind = 'access';
    if not found or r.trev is not null or r.crev is not null or now() > r.expires_at or r.state <> 'active' then
      perform bnx.fail('UNAUTHENTICATED', 'P0401');
    end if;
    a := row(r.member_id, r.cid, 'mcp', null, r.scopes)::bnx.actor;
  else
    perform bnx.fail('UNAUTHENTICATED', 'P0401');
  end if;
  perform set_config('bnx.actor_member', a.member_id::text, true);
  foreach k in array array['host_profile','tool_name','tool_version','trace_id'] loop
    val := cred->'envelope'->>k;
    if val is not null and (length(val) > 100 or val !~ '^[ -~]+$') then          -- 9011 G0R
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'envelope.' || k);
    end if;
    perform set_config('bnx.' || k, coalesce(val, ''), true);
  end loop;
  return a;
end $$;

-- ---------- SIN/ITN detector (Addendum A1 Rev 1 §3; guard C1; spec/sin-detector/sin_detector_v1.json) ----------
-- Same algorithm as apps/executor/bnx_exec/sin_detector.py and apps/worker/src/sin_detector.js for origins 'native' and
-- 'typed' ('ocr' exists only in the Executor). Values are never returned, logged or stored: a hit is {rule, start, end}
-- in 0-based code-point positions of the original text. Internal functions: no runtime role holds EXECUTE on them.

create function bnx.sin_detector_spec() returns jsonb
language sql immutable set search_path = pg_catalog, pg_temp as $f$ select $spec${"spec": "bnx-sin-detector", "version": "1.1.0", "source": "Addendum A1 Rev 1 §3 (S4 V1.2); Owner decisions A1-OD-1 (2026-11-10) and DELEGATED_DECISION D-A1-1..4; v1.1.0: 9011 review remediation D-9011R-1..6 (docs/s4/S4_9011R_Remediation_2026-11-11.md)", "unicode_version": "15.1.0", "origins": ["native", "typed", "ocr"], "origins_sql_js": ["native", "typed"], "ignorable_ranges": [[173, 173], [768, 879], [1155, 1161], [1425, 1469], [1471, 1471], [1473, 1474], [1476, 1477], [1479, 1479], [1536, 1541], [1552, 1562], [1564, 1564], [1611, 1631], [1648, 1648], [1750, 1757], [1759, 1764], [1767, 1768], [1770, 1773], [1807, 1807], [1809, 1809], [1840, 1866], [1958, 1968], [2027, 2035], [2045, 2045], [2070, 2073], [2075, 2083], [2085, 2087], [2089, 2093], [2137, 2139], [2192, 2193], [2200, 2207], [2250, 2306], [2362, 2362], [2364, 2364], [2369, 2376], [2381, 2381], [2385, 2391], [2402, 2403], [2433, 2433], [2492, 2492], [2497, 2500], [2509, 2509], [2530, 2531], [2558, 2558], [2561, 2562], [2620, 2620], [2625, 2626], [2631, 2632], [2635, 2637], [2641, 2641], [2672, 2673], [2677, 2677], [2689, 2690], [2748, 2748], [2753, 2757], [2759, 2760], [2765, 2765], [2786, 2787], [2810, 2815], [2817, 2817], [2876, 2876], [2879, 2879], [2881, 2884], [2893, 2893], [2901, 2902], [2914, 2915], [2946, 2946], [3008, 3008], [3021, 3021], [3072, 3072], [3076, 3076], [3132, 3132], [3134, 3136], [3142, 3144], [3146, 3149], [3157, 3158], [3170, 3171], [3201, 3201], [3260, 3260], [3263, 3263], [3270, 3270], [3276, 3277], [3298, 3299], [3328, 3329], [3387, 3388], [3393, 3396], [3405, 3405], [3426, 3427], [3457, 3457], [3530, 3530], [3538, 3540], [3542, 3542], [3633, 3633], [3636, 3642], [3655, 3662], [3761, 3761], [3764, 3772], [3784, 3790], [3864, 3865], [3893, 3893], [3895, 3895], [3897, 3897], [3953, 3966], [3968, 3972], [3974, 3975], [3981, 3991], [3993, 4028], [4038, 4038], [4141, 4144], [4146, 4151], [4153, 4154], [4157, 4158], [4184, 4185], [4190, 4192], [4209, 4212], [4226, 4226], [4229, 4230], [4237, 4237], [4253, 4253], [4447, 4448], [4957, 4959], [5906, 5908], [5938, 5939], [5970, 5971], [6002, 6003], [6068, 6069], [6071, 6077], [6086, 6086], [6089, 6099], [6109, 6109], [6155, 6159], [6277, 6278], [6313, 6313], [6432, 6434], [6439, 6440], [6450, 6450], [6457, 6459], [6679, 6680], [6683, 6683], [6742, 6742], [6744, 6750], [6752, 6752], [6754, 6754], [6757, 6764], [6771, 6780], [6783, 6783], [6832, 6862], [6912, 6915], [6964, 6964], [6966, 6970], [6972, 6972], [6978, 6978], [7019, 7027], [7040, 7041], [7074, 7077], [7080, 7081], [7083, 7085], [7142, 7142], [7144, 7145], [7149, 7149], [7151, 7153], [7212, 7219], [7222, 7223], [7376, 7378], [7380, 7392], [7394, 7400], [7405, 7405], [7412, 7412], [7416, 7417], [7616, 7679], [8203, 8207], [8234, 8238], [8288, 8292], [8294, 8303], [8400, 8432], [11503, 11505], [11647, 11647], [11744, 11775], [12330, 12333], [12441, 12442], [12644, 12644], [42607, 42610], [42612, 42621], [42654, 42655], [42736, 42737], [43010, 43010], [43014, 43014], [43019, 43019], [43045, 43046], [43052, 43052], [43204, 43205], [43232, 43249], [43263, 43263], [43302, 43309], [43335, 43345], [43392, 43394], [43443, 43443], [43446, 43449], [43452, 43453], [43493, 43493], [43561, 43566], [43569, 43570], [43573, 43574], [43587, 43587], [43596, 43596], [43644, 43644], [43696, 43696], [43698, 43700], [43703, 43704], [43710, 43711], [43713, 43713], [43756, 43757], [43766, 43766], [44005, 44005], [44008, 44008], [44013, 44013], [64286, 64286], [65024, 65039], [65056, 65071], [65279, 65279], [65440, 65440], [65529, 65531], [66045, 66045], [66272, 66272], [66422, 66426], [68097, 68099], [68101, 68102], [68108, 68111], [68152, 68154], [68159, 68159], [68325, 68326], [68900, 68903], [69291, 69292], [69373, 69375], [69446, 69456], [69506, 69509], [69633, 69633], [69688, 69702], [69744, 69744], [69747, 69748], [69759, 69761], [69811, 69814], [69817, 69818], [69821, 69821], [69826, 69826], [69837, 69837], [69888, 69890], [69927, 69931], [69933, 69940], [70003, 70003], [70016, 70017], [70070, 70078], [70089, 70092], [70095, 70095], [70191, 70193], [70196, 70196], [70198, 70199], [70206, 70206], [70209, 70209], [70367, 70367], [70371, 70378], [70400, 70401], [70459, 70460], [70464, 70464], [70502, 70508], [70512, 70516], [70712, 70719], [70722, 70724], [70726, 70726], [70750, 70750], [70835, 70840], [70842, 70842], [70847, 70848], [70850, 70851], [71090, 71093], [71100, 71101], [71103, 71104], [71132, 71133], [71219, 71226], [71229, 71229], [71231, 71232], [71339, 71339], [71341, 71341], [71344, 71349], [71351, 71351], [71453, 71455], [71458, 71461], [71463, 71467], [71727, 71735], [71737, 71738], [71995, 71996], [71998, 71998], [72003, 72003], [72148, 72151], [72154, 72155], [72160, 72160], [72193, 72202], [72243, 72248], [72251, 72254], [72263, 72263], [72273, 72278], [72281, 72283], [72330, 72342], [72344, 72345], [72752, 72758], [72760, 72765], [72767, 72767], [72850, 72871], [72874, 72880], [72882, 72883], [72885, 72886], [73009, 73014], [73018, 73018], [73020, 73021], [73023, 73029], [73031, 73031], [73104, 73105], [73109, 73109], [73111, 73111], [73459, 73460], [73472, 73473], [73526, 73530], [73536, 73536], [73538, 73538], [78896, 78912], [78919, 78933], [92912, 92916], [92976, 92982], [94031, 94031], [94095, 94098], [94180, 94180], [113821, 113822], [113824, 113827], [118528, 118573], [118576, 118598], [119143, 119145], [119155, 119170], [119173, 119179], [119210, 119213], [119362, 119364], [121344, 121398], [121403, 121452], [121461, 121461], [121476, 121476], [121499, 121503], [121505, 121519], [122880, 122886], [122888, 122904], [122907, 122913], [122915, 122916], [122918, 122922], [123023, 123023], [123184, 123190], [123566, 123566], [123628, 123631], [124140, 124143], [125136, 125142], [125252, 125258], [917504, 921599]], "digit_map": [[4969, 1], [4970, 2], [4971, 3], [4972, 4], [4973, 5], [4974, 6], [4975, 7], [4976, 8], [4977, 9], [6618, 1], [9461, 1], [9462, 2], [9463, 3], [9464, 4], [9465, 5], [9466, 6], [9467, 7], [9468, 8], [9469, 9], [9471, 0], [10102, 1], [10103, 2], [10104, 3], [10105, 4], [10106, 5], [10107, 6], [10108, 7], [10109, 8], [10110, 9], [10112, 1], [10113, 2], [10114, 3], [10115, 4], [10116, 5], [10117, 6], [10118, 7], [10119, 8], [10120, 9], [10122, 1], [10123, 2], [10124, 3], [10125, 4], [10126, 5], [10127, 6], [10128, 7], [10129, 8], [10130, 9], [68160, 1], [68161, 2], [68162, 3], [68163, 4], [69216, 1], [69217, 2], [69218, 3], [69219, 4], [69220, 5], [69221, 6], [69222, 7], [69223, 8], [69224, 9], [69714, 1], [69715, 2], [69716, 3], [69717, 4], [69718, 5], [69719, 6], [69720, 7], [69721, 8], [69722, 9]], "whitespace": [9, 10, 11, 12, 13, 32, 133, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12288], "line_breaks": [10, 11, 12, 13, 133, 8232, 8233], "hard_separators": [9, 10, 11, 12, 13, 133, 8232, 8233], "dash_separators": [45, 8208, 8209, 8210, 8211, 8212, 8213], "apostrophes": [8217, 8216, 700], "nd_zeros": [48, 1632, 1776, 1984, 2406, 2534, 2662, 2790, 2918, 3046, 3174, 3302, 3430, 3558, 3664, 3792, 3872, 4160, 4240, 6112, 6160, 6470, 6608, 6784, 6800, 6992, 7088, 7232, 7248, 42528, 43216, 43264, 43472, 43504, 43600, 44016, 65296, 66720, 68912, 69734, 69872, 69942, 70096, 70384, 70736, 70864, 71248, 71360, 71472, 71904, 72016, 72784, 73040, 73120, 73552, 92768, 92864, 93008, 120782, 120792, 120802, 120812, 120822, 123200, 123632, 124144, 125264, 130032], "sequence": {"digits": 9, "strict_max_groups": 3, "strict_min_group": 2, "link_strict_regex": "^(?: +| *[‐‑‒–—―−-]{1,2} *)$", "link_loose_regex": "^(?: *[./_·•]{1,2} *|,)$", "note": "groups are maximal ASCII digit runs after §3.2; consecutive groups are linked by a separator matching the strict regex (S: spaces, dashes) or the loose regex (L: dot, slash, underscore, middle dot, bullet, bare comma); a strict link whose original characters include a hard separator (tab, line break) counts as L; a window of linked groups holding exactly nine digits is a sequence when: (a) all links are S, it has at most strict_max_groups groups and every group has at least strict_min_group digits; or (b) it is three groups of three digits (S or L links); near a label, under a labelled key and in origin ocr also (c) any grouping whose links are all S"}, "uuid_regex": "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "uuid_note": "a window of two or more groups lying inside a UUID-shaped substring is the token's own dash structure, not a sequence; a single nine-digit group inside it remains a sequence (D-9011R-1)", "label_window_after": 64, "label_window_before": 32, "label_line_max": 256, "labels": [{"lang": "en", "label": "SIN", "kind": "sin", "folded": "sin", "pattern": "sin", "word_start": true, "word_end": true}, {"lang": "en", "label": "S.I.N.", "kind": "sin", "folded": "s.i.n.", "pattern": "s\\.i\\.n\\.", "word_start": true, "word_end": false}, {"lang": "en", "label": "Social Insurance Number", "kind": "sin", "folded": "social insurance number", "pattern": "social +insurance +number", "word_start": true, "word_end": true}, {"lang": "en", "label": "Social Insurance No", "kind": "sin", "folded": "social insurance no", "pattern": "social +insurance +no", "word_start": true, "word_end": true}, {"lang": "en", "label": "Social Insurance #", "kind": "sin", "folded": "social insurance #", "pattern": "social +insurance +#", "word_start": true, "word_end": false}, {"lang": "en", "label": "Soc. Ins. No", "kind": "sin", "folded": "soc. ins. no", "pattern": "soc\\. +ins\\. +no", "word_start": true, "word_end": true}, {"lang": "en", "label": "Individual Tax Number", "kind": "itn", "folded": "individual tax number", "pattern": "individual +tax +number", "word_start": true, "word_end": true}, {"lang": "en", "label": "ITN", "kind": "itn", "folded": "itn", "pattern": "itn", "word_start": true, "word_end": true}, {"lang": "fr", "label": "NAS", "kind": "sin", "folded": "nas", "pattern": "nas", "word_start": true, "word_end": true}, {"lang": "fr", "label": "N.A.S.", "kind": "sin", "folded": "n.a.s.", "pattern": "n\\.a\\.s\\.", "word_start": true, "word_end": false}, {"lang": "fr", "label": "numéro d'assurance sociale", "kind": "sin", "folded": "numero d'assurance sociale", "pattern": "numero +d'assurance +sociale", "word_start": true, "word_end": true}, {"lang": "fr", "label": "no d'assurance sociale", "kind": "sin", "folded": "no d'assurance sociale", "pattern": "no +d'assurance +sociale", "word_start": true, "word_end": true}, {"lang": "fr", "label": "n° d'assurance sociale", "kind": "sin", "folded": "n° d'assurance sociale", "pattern": "n° +d'assurance +sociale", "word_start": true, "word_end": true}, {"lang": "zh-Hans", "label": "社会保险号", "kind": "sin", "folded": "社会保险号", "pattern": "社会保险号", "word_start": false, "word_end": false}, {"lang": "zh-Hans", "label": "社会保险号码", "kind": "sin", "folded": "社会保险号码", "pattern": "社会保险号码", "word_start": false, "word_end": false}, {"lang": "zh-Hans", "label": "社会保障号", "kind": "sin", "folded": "社会保障号", "pattern": "社会保障号", "word_start": false, "word_end": false}, {"lang": "zh-Hant", "label": "社會保險號", "kind": "sin", "folded": "社會保險號", "pattern": "社會保險號", "word_start": false, "word_end": false}, {"lang": "zh-Hant", "label": "社會保險號碼", "kind": "sin", "folded": "社會保險號碼", "pattern": "社會保險號碼", "word_start": false, "word_end": false}], "key_split_chars": [33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 94, 95, 96, 123, 124, 125, 126], "key_tokens": [["sin"], ["nas"], ["itn"], ["social", "insurance"], ["assurance", "sociale"], ["individual", "tax"], ["s", "i", "n"], ["n", "a", "s"], ["i", "t", "n"]], "program_identifiers": ["RT", "RP", "RC", "RZ", "RR", "RG", "RD", "RE", "RM", "RN", "LT", "RU", "PT"], "bn15_suffix_regex": "[ -]?(?:RT|RP|RC|RZ|RR|RG|RD|RE|RM|RN|LT|RU|PT)[ -]?[0-9]{4}(?![0-9A-Za-z])", "itn_prefixes": ["08", "09"], "hex_exempt": {"key_tokens": ["id", "ids", "uid", "uuid", "uuids", "guid", "sha1", "sha256", "sha512", "md5", "hash", "hashes", "digest", "checksum", "etag", "key", "keys", "nonce", "token"], "value_regex": "^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32}|[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64}|[0-9A-Fa-f]{128})$", "note": "structured data only (JSON string values), never under a labelled key; free text has no exemption (D-9011R-1)"}, "ocr": {"confusables": {"O": "0", "o": "0", "I": "1", "l": "1", "|": "1", "S": "5", "B": "8", "Z": "2", "G": "6"}, "t_ocr": 0.9, "run_digits": [8, 10, 11, 12], "t_ocr_note": "set in 9011c from the corpus (D-9011c-3)"}, "mask": "[MASKED:SIN]", "rules": {"R_LABEL": "nine-digit sequence near a SIN/ITN label or under a labelled key", "R_MOD10": "nine-digit sequence passing Mod 10 (Luhn; assumption A-1 accepted as D-A1-2)", "R_ITN": "nine-digit sequence beginning 08 or 09 (D-A1-1)", "R_OCR9": "any nine-digit sequence in OCR text", "R_OCR_RUN": "8-, 10-, 11- or 12-digit OCR run with a low-confidence or confusable glyph"}}$spec$::jsonb $f$;

create function bnx.sin_luhn(d text) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t int := 0; v int; k int;
begin
  for k in 0 .. length(d) - 1 loop
    v := ascii(substr(d, length(d) - k, 1)) - 48;
    if k % 2 = 1 then v := v * 2; if v > 9 then v := v - 9; end if; end if;
    t := t + v;
  end loop;
  return t % 10 = 0;
end $$;

-- v1.1 (R-02, R-41): default-ignorable, format and combining characters are removed before matching (binary search over
-- the spec's code-point ranges)
create function bnx.sin_ignorable(cp int, lo int[], hi int[]) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare a int := 1; b int := coalesce(array_length(lo, 1), 0); m int; k int := 0;
begin
  if cp < 173 then return false; end if;
  while a <= b loop
    m := (a + b) / 2;
    if lo[m] <= cp then k := m; a := m + 1; else b := m - 1; end if;
  end loop;
  return k > 0 and cp <= hi[k];
end $$;

-- normalized text; per character, the 0-based code-point index of the original character it came from and whether it was
-- a line break (idx and brk are null when the text is ASCII: then normalization only maps ASCII whitespace to spaces)
create function bnx.sin_normalize(p text, out n text, out idx int[], out brk boolean[])
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare sp jsonb := bnx.sin_detector_spec(); lo int[]; hi int[]; ws int[]; lbs int[]; zeros int[]; dm_cp int[]; dm_d int[];
        i int; k int; ch text; t text; c text; cp int; z int; buf text[] := '{}'; ix int[] := '{}'; bk boolean[] := '{}';
begin
  if p is null then return; end if;
  if octet_length(p) = length(p) then
    n := translate(p, E'\t\n\x0b\x0c\r', '     '); idx := null; brk := null; return;
  end if;
  lo := array(select (x->>0)::int from jsonb_array_elements(sp->'ignorable_ranges') x);
  hi := array(select (x->>1)::int from jsonb_array_elements(sp->'ignorable_ranges') x);
  ws := array(select jsonb_array_elements_text(sp->'whitespace')::int);
  lbs := array(select jsonb_array_elements_text(sp->'line_breaks')::int);
  zeros := array(select jsonb_array_elements_text(sp->'nd_zeros')::int);
  dm_cp := array(select (x->>0)::int from jsonb_array_elements(sp->'digit_map') x);
  dm_d := array(select (x->>1)::int from jsonb_array_elements(sp->'digit_map') x);
  for i in 1 .. length(p) loop
    ch := substr(p, i, 1);
    continue when bnx.sin_ignorable(ascii(ch), lo, hi);
    t := normalize(ch, NFKC);
    for k in 1 .. length(t) loop
      c := substr(t, k, 1); cp := ascii(c);
      continue when bnx.sin_ignorable(cp, lo, hi);
      if cp >= 128 then
        select x into z from unnest(zeros) x where cp - x between 0 and 9;
        if found then c := chr(48 + cp - z); cp := ascii(c);
        else
          z := array_position(dm_cp, cp);
          if z is not null then c := chr(48 + dm_d[z]); cp := ascii(c); end if;
        end if;
      end if;
      bk := bk || (cp = any(lbs));
      if cp = any(ws) then c := ' '; end if;
      buf := buf || c; ix := ix || (i - 1);
    end loop;
  end loop;
  n := array_to_string(buf, ''); idx := ix; brk := bk;
end $$;

create function bnx.sin_fold(n text) returns text
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare ap int[] := array(select jsonb_array_elements_text(bnx.sin_detector_spec()->'apostrophes')::int); buf text[] := '{}'; c text; i int;
begin
  if n is null then return null; end if;
  if octet_length(n) = length(n) then return lower(n); end if;
  for i in 1 .. length(n) loop
    c := substr(n, i, 1);
    if ascii(c) = any(ap) then buf := buf || ''''::text;
    else buf := buf || left(lower(left(normalize(c, NFD), 1)), 1); end if;
  end loop;
  return array_to_string(buf, '');
end $$;

-- label spans [la, lb) (0-based) in folded text, whole words per the spec
create function bnx.sin_label_spans(f text, out la int[], out lb int[])
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare lab jsonb; pat text; st int; a int; b int;
begin
  la := '{}'; lb := '{}';
  for lab in select x from jsonb_array_elements(bnx.sin_detector_spec()->'labels') x loop
    pat := lab->>'pattern'; st := 1;
    loop
      a := regexp_instr(f, pat, st, 1, 0); exit when a = 0;
      b := regexp_instr(f, pat, st, 1, 1);
      st := greatest(b, a + 1);
      continue when (lab->>'word_start')::boolean and a > 1 and substr(f, a - 1, 1) ~ '^[A-Za-z]$';
      continue when (lab->>'word_end')::boolean and b <= length(f) and substr(f, b, 1) ~ '^[A-Za-z]$';
      la := la || (a - 1); lb := lb || (b - 1);
    end loop;
  end loop;
end $$;

-- v1.1: windows of linked digit groups holding exactly nine digits (spec "sequence"); near a label by the character window
-- or by line (same line, or the next non-empty line, within label_line_max)
create function bnx.sin_scan(p text, p_origin text default 'native', p_force_label boolean default false) returns jsonb
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare sp jsonb := bnx.sin_detector_spec(); sq jsonb := sp->'sequence'; r record; l record; n text; idx int[]; brk boolean[];
        ls text := sq->>'link_strict_regex'; ll text := sq->>'link_loose_regex'; nd int := (sq->>'digits')::int;
        gs int[] := '{}'; ge int[] := '{}'; lk text[] := '{}'; g int; st int; a int; b int; ga int; gb int; tot int; mn int;
        allstrict boolean; ok boolean; oknear boolean; mx int; f333 boolean; ng int; ii int; jj int; d text; near boolean; rule text; k int; q int; p1 int; p2 int;
        sep text; isb boolean; hits jsonb := '[]';
        hs int[] := array(select jsonb_array_elements_text(sp->'hard_separators')::int); ua int[] := '{}'; ub int[] := '{}'; skip boolean;
        wa int := (sp->>'label_window_after')::int; wb int := (sp->>'label_window_before')::int; lm int := (sp->>'label_line_max')::int;
begin
  if p_origin is null or not (p_origin = any(array(select jsonb_array_elements_text(sp->'origins_sql_js')))) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'sin detector origin'); end if;
  if p is null then return hits; end if;
  select * into r from bnx.sin_normalize(p); n := r.n; idx := r.idx; brk := r.brk;
  if length(regexp_replace(n, '[^0-9]', '', 'g')) < nd then return hits; end if;   -- fewer than nine digits in all
  select * into l from bnx.sin_label_spans(bnx.sin_fold(n));
  st := 1;
  loop
    a := regexp_instr(n, '[0-9]+', st, 1, 0); exit when a = 0;
    b := regexp_instr(n, '[0-9]+', st, 1, 1);
    gs := gs || (a - 1); ge := ge || (b - 1); st := b;
  end loop;
  g := coalesce(array_length(gs, 1), 0);
  st := 1;
  loop                                                                       -- UUID-shaped substrings (D-9011R-1)
    a := regexp_instr(n, sp->>'uuid_regex', st, 1, 0); exit when a = 0;
    b := regexp_instr(n, sp->>'uuid_regex', st, 1, 1);
    ua := ua || (a - 1); ub := ub || (b - 1); st := b;
  end loop;
  for k in 1 .. g - 1 loop
    sep := substr(n, ge[k] + 1, gs[k + 1] - ge[k]);
    if sep ~ ls then
      -- a strict link holding a hard separator (tab, line break) in the original text counts as L
      isb := false;
      for q in ge[k] .. gs[k + 1] - 1 loop
        isb := ascii(case when idx is null then substr(p, q + 1, 1) else substr(p, idx[q + 1] + 1, 1) end) = any(hs);
        exit when isb;
      end loop;
      lk := lk || case when isb then 'L' else 'S' end;
    else
      lk := lk || case when sep ~ ll then 'L' else null end;
    end if;
  end loop;
  for ga in 1 .. g loop
    tot := 0; allstrict := true; mn := 99; mx := 0;
    for gb in ga .. g loop
      if gb > ga then
        exit when lk[gb - 1] is null;
        allstrict := allstrict and lk[gb - 1] = 'S';
      end if;
      tot := tot + (ge[gb] - gs[gb]); mn := least(mn, ge[gb] - gs[gb]); mx := greatest(mx, ge[gb] - gs[gb]);
      exit when tot > nd;
      continue when tot < nd;
      ng := gb - ga + 1; ii := gs[ga]; jj := ge[gb];                              -- 0-based [ii, jj)
      f333 := ng = 3 and mn = 3 and mx = 3;
      ok := (allstrict and ng <= (sq->>'strict_max_groups')::int and mn >= (sq->>'strict_min_group')::int) or f333;
      oknear := allstrict or f333;
      continue when not oknear;
      skip := false;
      if ng > 1 then
        for k in 1 .. coalesce(array_length(ua, 1), 0) loop
          if ua[k] <= ii and jj <= ub[k] then skip := true; exit; end if;
        end loop;
      end if;
      continue when skip;
      d := regexp_replace(substr(n, ii + 1, jj - ii), '[^0-9]', '', 'g');
      near := p_force_label;
      for k in 1 .. coalesce(array_length(l.la, 1), 0) loop
        exit when near;
        if (l.lb[k] <= ii and ii - l.lb[k] <= wa) or (jj <= l.la[k] and l.la[k] - jj <= wb) or (l.la[k] < jj and ii < l.lb[k]) then
          near := true; exit;
        end if;
        if l.lb[k] <= ii and ii - l.lb[k] <= lm then
          p1 := null; p2 := null;
          for q in l.lb[k] .. ii - 1 loop
            isb := case when brk is null then substr(p, q + 1, 1) in (E'\n', E'\x0b', E'\x0c', E'\r') else brk[q + 1] end;
            if isb then p1 := coalesce(p1, q); p2 := q; end if;
          end loop;
          if p1 is null or substr(n, p1 + 1, p2 - p1 + 1) ~ '^ *$' then near := true; exit; end if;
        end if;
        if jj <= l.la[k] and l.la[k] - jj <= lm then
          isb := false;
          for q in jj .. l.la[k] - 1 loop
            isb := case when brk is null then substr(p, q + 1, 1) in (E'\n', E'\x0b', E'\x0c', E'\r') else brk[q + 1] end;
            exit when isb;
          end loop;
          if not isb then near := true; exit; end if;
        end if;
      end loop;
      continue when not (ok or near);
      if near then rule := 'R_LABEL';
      elsif ng = 1 and not (ii > 0 and substr(n, ii, 1) ~ '^[A-Za-z]$') and regexp_instr(n, sp->>'bn15_suffix_regex', jj + 1) = jj + 1 then
        continue;                                                              -- complete CRA program account (§3.5)
      elsif bnx.sin_luhn(d) then rule := 'R_MOD10';
      elsif left(d, 2) = any(array(select jsonb_array_elements_text(sp->'itn_prefixes'))) then rule := 'R_ITN';
      else continue;
      end if;
      hits := hits || jsonb_build_object('rule', rule,
                'start', case when idx is null then ii else idx[ii + 1] end,
                'end', case when idx is null then jj else idx[jj] + 1 end);
    end loop;
  end loop;
  return coalesce((select jsonb_agg(x order by (x->>'start')::int, (x->>'end')::int, x->>'rule')
                     from (select distinct x from jsonb_array_elements(hits) x) s), '[]');
end $$;

create function bnx.sin_candidate(p text, p_origin text default 'native') returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$ select jsonb_array_length(bnx.sin_scan(p, p_origin)) > 0 $$;

-- v1.1 (R-04): key tokens: camelCase and acronym boundaries, letter/digit boundaries (p_digits), ASCII punctuation separates
create function bnx.sin_key_split(p_key text, p_digits boolean default true) returns text[]
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare k text := coalesce(p_key, ''); punct text;
begin
  punct := (select string_agg(chr(x::int), '' order by o) from jsonb_array_elements_text(bnx.sin_detector_spec()->'key_split_chars') with ordinality a(x, o));
  k := regexp_replace(k, '([a-z0-9])([A-Z])', '\1 \2', 'g');
  k := regexp_replace(k, '([A-Z]+)([A-Z][a-z])', '\1 \2', 'g');
  if p_digits then
    k := regexp_replace(k, '([A-Za-z])([0-9])', '\1 \2', 'g');
    k := regexp_replace(k, '([0-9])([A-Za-z])', '\1 \2', 'g');
  end if;
  k := translate(bnx.sin_fold((bnx.sin_normalize(k)).n), punct, repeat(' ', length(punct)));
  return array(select t from unnest(string_to_array(k, ' ')) t where t <> '');
end $$;

create function bnx.sin_key_is_label(p_key text) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare toks text[] := bnx.sin_key_split(p_key); pat jsonb; s int; m int; ok boolean;
begin
  for pat in select x from jsonb_array_elements(bnx.sin_detector_spec()->'key_tokens') x loop
    for s in 1 .. coalesce(array_length(toks, 1), 0) - jsonb_array_length(pat) + 1 loop
      ok := true;
      for m in 0 .. jsonb_array_length(pat) - 1 loop
        if toks[s + m] is distinct from pat->>m then ok := false; exit; end if;
      end loop;
      if ok then return true; end if;
    end loop;
  end loop;
  return coalesce(array_length((bnx.sin_label_spans(array_to_string(toks, ' '))).la, 1), 0) > 0;
end $$;

-- v1.1 (D-9011R-1): a key whose last token names an id or a hash
create function bnx.sin_key_is_hex(p_key text) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare toks text[] := bnx.sin_key_split(p_key, false);
begin
  return coalesce(array_length(toks, 1), 0) > 0
     and toks[array_length(toks, 1)] = any(array(select jsonb_array_elements_text(bnx.sin_detector_spec()->'hex_exempt'->'key_tokens')));
end $$;

-- hits in a JSON value: keys, strings and numbers; values under a labelled key are judged with force_label; a string that is
-- exactly a UUID or a hex digest under an id/hash key (and not under a labelled key) is machine data (v1.1, D-9011R-1)
create function bnx.sin_scan_json(p jsonb, p_origin text default 'native', p_path text default '$', p_labelled boolean default false,
                                  p_hexkey boolean default false)
returns jsonb language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare out jsonb := '[]'; e record; h jsonb;
begin
  case jsonb_typeof(p)
  when 'object' then
    for e in select key, value from jsonb_each(p) loop
      for h in select x from jsonb_array_elements(bnx.sin_scan(e.key, p_origin)) x loop
        out := out || (h || jsonb_build_object('path', p_path || '.' || e.key, 'part', 'key'));
      end loop;
      out := out || bnx.sin_scan_json(e.value, p_origin, p_path || '.' || e.key, p_labelled or bnx.sin_key_is_label(e.key),
                                      bnx.sin_key_is_hex(e.key));
    end loop;
  when 'array' then
    for e in select value, ordinality from jsonb_array_elements(p) with ordinality loop
      out := out || bnx.sin_scan_json(e.value, p_origin, p_path || '[' || (e.ordinality - 1) || ']', p_labelled, p_hexkey);
    end loop;
  when 'string', 'number' then
    if jsonb_typeof(p) = 'string' and p_hexkey and not p_labelled
       and (p #>> '{}') ~ (bnx.sin_detector_spec()->'hex_exempt'->>'value_regex') then
      return out;
    end if;
    for h in select x from jsonb_array_elements(bnx.sin_scan(p #>> '{}', p_origin, p_labelled)) x loop
      out := out || (h || jsonb_build_object('path', p_path, 'part', 'value'));
    end loop;
  else null;
  end case;
  return out;
end $$;

-- cheap pre-filter on the JSON text (fewer than nine digits in all), then the full scan
create function bnx.sin_json_has(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t text;
begin
  if p is null then return false; end if;
  t := p::text;
  if octet_length(t) = length(t) and length(regexp_replace(t, '[^0-9]', '', 'g')) < 9 then
    return false;
  end if;
  return jsonb_array_length(bnx.sin_scan_json(p)) > 0;
end $$;

-- copy of p with every key, string or number that holds a candidate replaced by the mask
create function bnx.sin_mask_json(p jsonb, p_origin text default 'native', p_labelled boolean default false, p_hexkey boolean default false)
returns jsonb language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare mask text := bnx.sin_detector_spec()->>'mask'; out jsonb; e record; nk text;
begin
  case jsonb_typeof(p)
  when 'object' then
    out := '{}';
    for e in select key, value from jsonb_each(p) loop
      nk := case when bnx.sin_candidate(e.key, p_origin) then mask else e.key end;
      if out ? nk then nk := nk || '#' || (select count(*) from jsonb_object_keys(out)); end if;
      out := out || jsonb_build_object(nk, bnx.sin_mask_json(e.value, p_origin, p_labelled or bnx.sin_key_is_label(e.key),
                                                             bnx.sin_key_is_hex(e.key)));
    end loop;
    return out;
  when 'array' then
    return coalesce((select jsonb_agg(bnx.sin_mask_json(x, p_origin, p_labelled, p_hexkey) order by o)
                       from jsonb_array_elements(p) with ordinality a(x, o)), '[]');
  when 'string', 'number' then
    if jsonb_typeof(p) = 'string' and p_hexkey and not p_labelled
       and (p #>> '{}') ~ (bnx.sin_detector_spec()->'hex_exempt'->>'value_regex') then
      return p;
    end if;
    return case when jsonb_array_length(bnx.sin_scan(p #>> '{}', p_origin, p_labelled)) > 0 then to_jsonb(mask) else p end;
  else return p;
  end case;
end $$;

-- ---------- intake exception class for blocked shared-index records (DOC-SIN-10) ----------
alter table bnx_intake.intake_exception drop constraint intake_exception_class_check,
  add constraint intake_exception_class_check check (class in ('UNCLASSIFIED','SCOPE_DISABLED','ACCESS_UNVERIFIED','BLOCKED',
    'INSTITUTION_UNVERIFIED','OWNER_TYPE_AMBIGUOUS','COUNTRY_UNKNOWN','HASH_MISMATCH','INCOMPLETE_ATTACHMENTS','UPSTREAM_OPEN_ITEM',
    'STALE_NON_TERMINAL','SIN_CANDIDATE'));

-- ======================================================================================================================
-- 9011b: discovery, transient scan verdicts, Owner redaction declaration and admission (Addendum A1 Rev 1 §2, §4, §5, §7;
-- Owner decisions A1-OD-2 and A1-OD-3). Document bytes never reach the database: the Executor stages identities and verdicts
-- only (zones Z0-Z2). 9011c registers the admitted copy in Z3 (bnx.evidence_object, bnx.evidence_file and the link table
-- bnx_doc.document_evidence) inside the admission gate, under the R1 write-once rules.
-- ======================================================================================================================

create table bnx_doc.document_discovery(
  id uuid primary key default gen_random_uuid(),
  source_kind text not null check (source_kind in ('DRIVE_INBOX','MAIL_ATTACHMENT')),
  source_file_id text, head_revision_id text, md5 text, size_bytes bigint, source_mtime timestamptz,
  mail_message_id text, mime_part text,
  module text not null check (module in ('FINANCE','TAX','SYSTEM')), period_key text,
  original_name text, name_withheld boolean not null,
  staging_id uuid, discovered_at timestamptz not null default now(),
  check (source_kind <> 'DRIVE_INBOX' or (source_file_id is not null and head_revision_id is not null and md5 is not null)),
  check (source_kind <> 'MAIL_ATTACHMENT' or (mail_message_id is not null and mime_part is not null)),
  check (name_withheld = (original_name is null)),
  unique nulls not distinct (source_kind, source_file_id, head_revision_id, md5, mail_message_id, mime_part));

create table bnx_doc.document_scan(
  id uuid primary key default gen_random_uuid(),
  discovery_id uuid not null references bnx_doc.document_discovery,
  sha256 bytea not null check (octet_length(sha256) = 32),
  sin_detector_version text not null,
  scan_result text not null check (scan_result in ('PASSED','SIN_CANDIDATE','SCAN_INCOMPLETE')),
  rule_codes text[] not null default '{}', locators jsonb not null default '[]',
  doc_class text check (doc_class ~ '^[A-Z0-9_]{1,40}$'), class_uncertain boolean not null, sin_bearing boolean not null,
  staging_id uuid, scanned_at timestamptz not null default now());

create table bnx_doc.document_declaration(
  id uuid primary key default gen_random_uuid(),
  discovery_id uuid not null references bnx_doc.document_discovery,
  sha256 bytea not null check (octet_length(sha256) = 32),
  source_kind text not null, source_file_id text, head_revision_id text, md5 text, mail_message_id text, mime_part text,
  declared_by uuid not null, declared_at timestamptz not null default now(),
  unique (discovery_id, sha256));

create table bnx_doc.document_state_event(
  seq bigint generated always as identity primary key,
  discovery_id uuid not null references bnx_doc.document_discovery,
  state text not null check (state in ('DISCOVERED','SCANNING','QUARANTINED','SCAN_INCOMPLETE','PENDING_DECLARATION','ADMISSIBLE',
                                       'ARCHIVED','INVALIDATED')),
  reason text, staging_id uuid, at timestamptz not null default now());
create index on bnx_doc.document_state_event(discovery_id, seq desc);

create trigger t_append_only before update or delete on bnx_doc.document_discovery for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_scan for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_declaration for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx_doc.document_state_event for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('document_discovery','E'),('document_scan','E'),('document_declaration','E'),('document_state_event','E');

-- 9011c: the Z3 registration of an admitted document (one row per admission; write-once). source_fidelity and the declaration
-- are copied at admission so the evidence keeps the three fields of A1-OD-3 separately even after a later re-scan.
create table bnx_doc.document_evidence(
  discovery_id uuid primary key references bnx_doc.document_discovery,
  evidence_object_id uuid not null references bnx.evidence_object,
  evidence_file_id uuid not null references bnx.evidence_file,
  scan_id uuid not null references bnx_doc.document_scan,
  declaration_id uuid references bnx_doc.document_declaration,
  source_fidelity text not null check (source_fidelity in ('OWNER_REDACTED_SOURCE','AS_RECEIVED_FROM_OWNER')),
  archived_file_id text not null, staging_id uuid not null, registered_at timestamptz not null default now(),
  check ((source_fidelity = 'OWNER_REDACTED_SOURCE') = (declaration_id is not null)));
create trigger t_append_only before update or delete on bnx_doc.document_evidence for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('document_evidence','E');

-- SIN-bearing classes (Addendum A1 Rev 1 §2); an uncertain class or an Owner tag also requires a declaration
create function bnx.doc_class_sin_bearing(p_class text) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select coalesce(p_class = any(array['T4','T4A','T4A_P','T4A_OAS','T4E','T4RSP','T4RIF','T4FHSA','T5','T3','T5008','T5007','RC62',
                                      'RRSP_RECEIPT','NOA','NOR','CRA_CORRESPONDENCE','T1_SCHEDULE']), false)
$$;

create function bnx.doc_state(p_disc uuid) returns text
language sql stable set search_path = pg_catalog, pg_temp as $$
  select state from bnx_doc.document_state_event where discovery_id = p_disc order by seq desc limit 1
$$;

create function bnx.doc_latest_scan(p_disc uuid) returns bnx_doc.document_scan
language sql stable set search_path = pg_catalog, pg_temp as $$
  select * from bnx_doc.document_scan where discovery_id = p_disc order by scanned_at desc, id desc limit 1
$$;

create function bnx.doc_needs_declaration(p_disc uuid) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  -- 9011c: a scan without a class is uncertain (fail closed, D-9011c-5)
  select coalesce((select s.sin_bearing or s.class_uncertain or s.doc_class is null or bnx.doc_class_sin_bearing(s.doc_class)
                     from bnx.doc_latest_scan(p_disc) s), true)
      or exists (select 1 from bnx_doc.document_state_event e where e.discovery_id = p_disc and e.reason = 'OWNER_TAGGED')
$$;

-- the scan is usable only under the current detector version (DOC-SIN-14)
create function bnx.doc_scan_current(p_disc uuid) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  select coalesce((select s.scan_result = 'PASSED' and s.sin_detector_version = bnx.sin_detector_spec()->>'version'
                   from bnx.doc_latest_scan(p_disc) s), false)
$$;

-- state machine (Addendum A1 Rev 1 §5.3). QUARANTINED and INVALIDATED are terminal: there is no release path (A1-OD-2,
-- DOC-SIN-13). SCAN_INCOMPLETE may be scanned again only after a detector version change.
create function bnx.trg_doc_state_transition() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev text := bnx.doc_state(new.discovery_id); ok boolean;
begin
  ok := case
    when prev is null then new.state = 'DISCOVERED'
    when prev = 'DISCOVERED' then new.state in ('SCANNING','INVALIDATED')
    when prev = 'SCANNING' then new.state in ('QUARANTINED','SCAN_INCOMPLETE','PENDING_DECLARATION','ADMISSIBLE')
    when prev = 'PENDING_DECLARATION' then new.state in ('ADMISSIBLE','SCANNING','INVALIDATED')
    when prev = 'ADMISSIBLE' then new.state in ('ARCHIVED','PENDING_DECLARATION','SCANNING','DISCOVERED','INVALIDATED')
    when prev = 'ARCHIVED' then new.state = 'SCANNING'
    when prev = 'SCAN_INCOMPLETE' then new.state = 'SCANNING' and coalesce(
           (select s.sin_detector_version from bnx.doc_latest_scan(new.discovery_id) s) <> bnx.sin_detector_spec()->>'version', false)
    else false end;
  if not ok then
    raise exception 'DOC_STATE_TRANSITION' using errcode = 'P0409', detail = coalesce(prev, 'none') || ' -> ' || new.state;
  end if;
  return new;
end $$;
create trigger t_doc_state_transition before insert on bnx_doc.document_state_event for each row execute function bnx.trg_doc_state_transition();

create function bnx.doc_event(p_disc uuid, p_state text, p_reason text, p_staging uuid) returns void
language sql set search_path = pg_catalog, pg_temp as $$
  insert into bnx_doc.document_state_event(discovery_id, state, reason, staging_id) values (p_disc, p_state, p_reason, p_staging)
$$;

-- current view: state, scan, declaration status and source fidelity, without any content
create view bnx_doc.document_current as
  select d.id as discovery_id, d.source_kind, d.module, d.period_key, d.original_name, d.name_withheld,
         bnx.doc_state(d.id) as state, s.sha256, s.scan_result, s.sin_detector_version, s.doc_class, s.class_uncertain,
         case when bnx.doc_state(d.id) = 'INVALIDATED' then 'INVALIDATED'
              when not bnx.doc_needs_declaration(d.id) then 'NOT_REQUIRED'
              when exists (select 1 from bnx_doc.document_declaration x where x.discovery_id = d.id and x.sha256 = s.sha256) then 'DECLARED'
              else 'PENDING' end as declaration_status,
         case when bnx.doc_needs_declaration(d.id) then 'OWNER_REDACTED_SOURCE' else 'AS_RECEIVED_FROM_OWNER' end as source_fidelity
    from bnx_doc.document_discovery d left join lateral (select * from bnx.doc_latest_scan(d.id)) s on true;

-- payload helpers
create function bnx.doc_payload_keys_ok(p jsonb, p_allowed text[]) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'object' and not exists (select 1 from jsonb_object_keys(p) k where not k = any(p_allowed))
$$;

-- a locator carries positions only: integers, short lower-case tokens, or a bounding box of at most four integers
create function bnx.doc_locators_ok(p jsonb) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 200 and not exists (
    select 1 from jsonb_array_elements(p) l
     where jsonb_typeof(l) <> 'object'
        or exists (select 1 from jsonb_each(l) e
                    where not e.key = any(array['part','kind','page','offset','length','bbox','revision','path_depth'])
                       or not (jsonb_typeof(e.value) = 'number'
                               or (jsonb_typeof(e.value) = 'string' and e.value #>> '{}' ~ '^[a-z_]{1,32}$')
                               or (jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) <= 4
                                   and not exists (select 1 from jsonb_array_elements(e.value) b where jsonb_typeof(b) <> 'number')))))
$$;

create function bnx.doc_reject(p_staging uuid, p_reason text) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare res jsonb := jsonb_build_object('status', 'REJECTED', 'reason', p_reason);
begin
  update bnx_intake.staging_payload set state = 'REJECTED', promoted_at = now(), result = res where id = p_staging;
  return res;
end $$;

create function bnx.doc_done(p_staging uuid, p_res jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = p_res where id = p_staging;
  return p_res;
end $$;

-- step 1, Z0 -> Z2: a discovered file identity (no bytes, no content). A new revision of the same source invalidates the
-- earlier discoveries that were not archived (a declaration never carries over to changed content: A1-OD-3).
create function bnx.wrk_doc_discovered(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; old uuid;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_discovered' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['source_kind','source_file_id','head_revision_id','md5','size_bytes','source_mtime',
                                         'mail_message_id','mime_part','module','period_key','original_name']) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  select id into did from bnx_doc.document_discovery
   where source_kind = pl->>'source_kind' and source_file_id is not distinct from pl->>'source_file_id'
     and head_revision_id is not distinct from pl->>'head_revision_id' and md5 is not distinct from pl->>'md5'
     and mail_message_id is not distinct from pl->>'mail_message_id' and mime_part is not distinct from pl->>'mime_part';
  if did is not null then
    return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'new', false));
  end if;
  begin
    insert into bnx_doc.document_discovery(source_kind, source_file_id, head_revision_id, md5, size_bytes, source_mtime, mail_message_id,
                                           mime_part, module, period_key, original_name, name_withheld, staging_id)
    values (pl->>'source_kind', pl->>'source_file_id', pl->>'head_revision_id', pl->>'md5', (pl->>'size_bytes')::bigint,
            (pl->>'source_mtime')::timestamptz, pl->>'mail_message_id', pl->>'mime_part', pl->>'module', pl->>'period_key',
            nullif(pl->>'original_name', ''), nullif(pl->>'original_name', '') is null, p_staging)
    returning id into did;
  exception when check_violation or not_null_violation or invalid_text_representation or invalid_datetime_format
            or datetime_field_overflow then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  perform bnx.doc_event(did, 'DISCOVERED', null, p_staging);
  if pl->>'source_kind' = 'DRIVE_INBOX' then
    for old in select d.id from bnx_doc.document_discovery d
                where d.source_kind = 'DRIVE_INBOX' and d.source_file_id = pl->>'source_file_id' and d.id <> did
                  and bnx.doc_state(d.id) in ('DISCOVERED','PENDING_DECLARATION','ADMISSIBLE') loop
      perform bnx.doc_event(old, 'INVALIDATED', 'NEW_REVISION', p_staging);
    end loop;
  end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'new', true));
end $$;

-- step 2, Z1 verdict -> Z2: the Executor stages the verdict of the transient scan, never content (DOC-SIN-01/04/07/08)
create function bnx.wrk_doc_validated(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; st text; sha bytea; res text; nxt text; d record; nm text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_validated' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['discovery_id','sha256','sin_detector_version','scan_result','rule_codes','locators','doc_class',
                                         'class_uncertain','sin_bearing']) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  if coalesce(pl->>'sha256', '') !~ '^[0-9a-f]{64}$' or not bnx.doc_locators_ok(coalesce(pl->'locators', '[]'))
     or jsonb_typeof(coalesce(pl->'rule_codes', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(coalesce(pl->'rule_codes', '[]')) r where r !~ '^R_[A-Z0-9_]{1,30}$') then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end if;
  if pl->>'sin_detector_version' is distinct from bnx.sin_detector_spec()->>'version' then
    return bnx.doc_reject(p_staging, 'DETECTOR_VERSION_STALE'); end if;
  begin did := (pl->>'discovery_id')::uuid; exception when others then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then return bnx.doc_reject(p_staging, 'DISCOVERY_UNKNOWN'); end if;
  st := bnx.doc_state(did);
  if st in ('QUARANTINED','INVALIDATED') then return bnx.doc_reject(p_staging, 'TERMINAL_STATE'); end if;
  if st = 'SCANNING' then return bnx.doc_reject(p_staging, 'SCAN_IN_PROGRESS'); end if;
  sha := decode(pl->>'sha256', 'hex'); res := pl->>'scan_result';
  -- the SCANNING transition is checked against the previous scan before the new verdict is stored; both or neither
  begin
    perform bnx.doc_event(did, 'SCANNING', null, p_staging);
    insert into bnx_doc.document_scan(discovery_id, sha256, sin_detector_version, scan_result, rule_codes, locators, doc_class,
                                      class_uncertain, sin_bearing, staging_id)
    values (did, sha, pl->>'sin_detector_version', res, array(select jsonb_array_elements_text(coalesce(pl->'rule_codes', '[]'))),
            coalesce(pl->'locators', '[]'), nullif(pl->>'doc_class', ''), coalesce((pl->>'class_uncertain')::boolean, true),
            coalesce((pl->>'sin_bearing')::boolean, false), p_staging);
  exception
    when sqlstate 'P0409' then return bnx.doc_reject(p_staging, 'RESCAN_NOT_ALLOWED');
    when check_violation or not_null_violation or invalid_text_representation then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  -- notification metadata keys are fixed (9010); a file name is included only when it contains no digit at all (DOC-SIN-08)
  nm := case when d.original_name is null or d.original_name ~ '[0-9]' then null else left(d.original_name, 80) end;
  if res = 'SIN_CANDIDATE' then
    nxt := 'QUARANTINED';
    perform bnx.notify('EXCEPTION', 'SIN_QUARANTINE:' || encode(sha, 'hex'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'SIN_CANDIDATE_QUARANTINED', 'source_id', d.module, 'record_key', did, 'masked_subject', nm,
                                          'caveat', 'replace the Inbox file with a newly redacted copy')));
  elsif res = 'SCAN_INCOMPLETE' then
    nxt := 'SCAN_INCOMPLETE';
    perform bnx.notify('EXCEPTION', 'SCAN_INCOMPLETE:' || encode(sha, 'hex') || ':' || (pl->>'sin_detector_version'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'SCAN_INCOMPLETE', 'source_id', d.module, 'record_key', did, 'masked_subject', nm)));
  elsif not bnx.doc_needs_declaration(did) then
    nxt := 'ADMISSIBLE';
  elsif exists (select 1 from bnx_doc.document_declaration x where x.discovery_id = did and x.sha256 = sha) then
    nxt := 'ADMISSIBLE';
  else
    nxt := 'PENDING_DECLARATION';
    perform bnx.notify('EXCEPTION', 'DECLARE:' || did || ':' || encode(sha, 'hex'), true,
                       jsonb_strip_nulls(jsonb_build_object('kind', 'REDACTION_DECLARATION_PENDING', 'source_id', d.module, 'record_key', did, 'masked_subject', nm)));
  end if;
  perform bnx.doc_event(did, nxt, res, p_staging);
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', nxt));
end $$;

-- the Owner's redaction declaration (A1-OD-3): Owner only, PWA only, bound to identity, revision and SHA-256 (DOC-SIN-11)
create function bnx.cmd_doc_declare_redacted(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; role text; did uuid; d record; sc bnx_doc.document_scan; sha bytea;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if a.channel is distinct from 'pwa' then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'doc_declare_redacted', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'sha256', '') !~ '^[0-9a-f]{64}$' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'sha256'); end if;
  sha := decode(cmd->>'sha256', 'hex');
  begin did := (cmd->>'discovery_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'discovery_id'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  sc := bnx.doc_latest_scan(did);
  if bnx.doc_state(did) <> 'PENDING_DECLARATION' or sc.sha256 is distinct from sha or not bnx.doc_scan_current(did) then
    perform bnx.fail('DECLARATION_NOT_APPLICABLE', 'P0409'); end if;
  insert into bnx_doc.document_declaration(discovery_id, sha256, source_kind, source_file_id, head_revision_id, md5, mail_message_id,
                                           mime_part, declared_by)
  values (did, sha, d.source_kind, d.source_file_id, d.head_revision_id, d.md5, d.mail_message_id, d.mime_part, a.member_id);
  perform bnx.doc_event(did, 'ADMISSIBLE', 'OWNER_DECLARED_REDACTED', null);
  perform bnx.audit(a, 'doc_declare_redacted', jsonb_build_object('discovery_id', did),
                    jsonb_build_object('sha256', cmd->>'sha256', 'source_kind', d.source_kind), null);
  return bnx.idem_end(a, 'doc_declare_redacted', cmd, jsonb_build_object('discovery_id', did, 'state', 'ADMISSIBLE',
                      'declaration_status', 'DECLARED', 'source_fidelity', 'OWNER_REDACTED_SOURCE'));
end $$;

-- the Owner tags a document as SIN-bearing before it is archived: it then needs a declaration (Addendum A1 Rev 1 §2)
create function bnx.cmd_doc_tag_sin_bearing(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; role text; did uuid;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if a.channel is distinct from 'pwa' then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'doc_tag_sin_bearing', cmd); if rc is not null then return rc; end if;
  begin did := (cmd->>'discovery_id')::uuid; exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'discovery_id'); end;
  if bnx.doc_state(did) is distinct from 'ADMISSIBLE' then perform bnx.fail('DECLARATION_NOT_APPLICABLE', 'P0409'); end if;
  perform bnx.doc_event(did, 'PENDING_DECLARATION', 'OWNER_TAGGED', null);
  perform bnx.audit(a, 'doc_tag_sin_bearing', jsonb_build_object('discovery_id', did), '{}', null);
  return bnx.idem_end(a, 'doc_tag_sin_bearing', cmd, jsonb_build_object('discovery_id', did, 'state', 'PENDING_DECLARATION'));
end $$;

-- step 5 gate (Addendum A1 Rev 1 §5.4, DOC-SIN-12): the Executor re-fetched the bytes for archiving and reports their SHA-256
-- and identity. Admission only if identity and hash are unchanged, the scan passed under the current detector and the
-- declaration (when required) is bound to that hash. Any mismatch writes nothing and returns the document to DISCOVERED.
create function bnx.wrk_doc_archived(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; did uuid; d record; sc bnx_doc.document_scan; why text; obj uuid; fil uuid;
        dec uuid; own uuid;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'doc_archived' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.doc_payload_keys_ok(pl, array['discovery_id','sha256','source_file_id','head_revision_id','md5','mail_message_id','mime_part',
                                         'archived_file_id','size_bytes','mime']) or coalesce(pl->>'sha256', '') !~ '^[0-9a-f]{64}$'
     or coalesce(pl->>'archived_file_id', '') !~ '^[A-Za-z0-9_-]{1,128}$'
     or coalesce(pl->>'size_bytes', '') !~ '^[0-9]{1,9}$' or (pl->>'size_bytes')::bigint not between 1 and 26214400
     or not coalesce(pl->>'mime', '') = any(array['application/pdf','image/png','image/jpeg','text/csv','text/plain','text/markdown',
                                                 'message/rfc822','application/x-ofx',
                                                 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']) then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end if;
  begin did := (pl->>'discovery_id')::uuid; exception when others then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED'); end;
  select * into d from bnx_doc.document_discovery where id = did for update;
  if not found then return bnx.doc_reject(p_staging, 'DISCOVERY_UNKNOWN'); end if;
  if bnx.doc_state(did) is distinct from 'ADMISSIBLE' then return bnx.doc_reject(p_staging, 'NOT_ADMISSIBLE'); end if;
  sc := bnx.doc_latest_scan(did);
  why := case
    when d.source_file_id is distinct from pl->>'source_file_id' or d.head_revision_id is distinct from pl->>'head_revision_id'
         or d.md5 is distinct from pl->>'md5' or d.mail_message_id is distinct from pl->>'mail_message_id'
         or d.mime_part is distinct from pl->>'mime_part' then 'IDENTITY_CHANGED'
    when sc.sha256 is distinct from decode(pl->>'sha256', 'hex') then 'HASH_MISMATCH'
    when not bnx.doc_scan_current(did) then 'SCAN_NOT_CURRENT'
    when bnx.doc_needs_declaration(did) and not exists (select 1 from bnx_doc.document_declaration x
                                                         where x.discovery_id = did and x.sha256 = sc.sha256) then 'DECLARATION_MISSING'
    end;
  if why is not null then
    perform bnx.doc_event(did, 'DISCOVERED', why, p_staging);
    return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', 'DISCOVERED', 'reason', why));
  end if;
  -- 9011c: Z3 registration (R1 write-once rules, 0004/9004). The object is identified by the SHA-256 the Executor computed
  -- over the re-fetched bytes; the copy lives in the Drive Processed folder until O-7 (storage_kind drive_processed, r2_key
  -- NULL, archive_state single_copy). Identical bytes admitted twice share one object (the R1 unique index on sha256).
  -- re-admission after a re-scan (DOC-SIN-14): the evidence is write-once and already registered for these bytes
  select e.evidence_object_id, e.evidence_file_id into obj, fil from bnx_doc.document_evidence e where e.discovery_id = did;
  if obj is not null then
    perform bnx.doc_event(did, 'ARCHIVED', 'READMITTED', p_staging);
    return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', 'ARCHIVED',
                                                      'evidence_object_id', obj, 'evidence_file_id', fil));
  end if;
  fil := gen_random_uuid();
  select id into own from bnx.member where role = 'owner' and state = 'active' order by created_at limit 1;
  if own is null then return bnx.doc_reject(p_staging, 'NO_OWNER'); end if;
  select x.id into dec from bnx_doc.document_declaration x where x.discovery_id = did and x.sha256 = sc.sha256;
  if not bnx.doc_needs_declaration(did) then dec := null; end if;
  select id into obj from bnx.evidence_object where sha256 = sc.sha256 and integrity_state = 'verified' and dedup_into is null;
  if obj is null then
    obj := gen_random_uuid();
    insert into bnx.evidence_object(id, r2_key, storage_kind, size_bytes, sha256, integrity_state, verified_by_execution, verified_at)
    values (obj, null, 'drive_processed', (pl->>'size_bytes')::bigint, sc.sha256, 'verified', 'executor:doc_archived:' || p_staging, now());
  elsif (select size_bytes from bnx.evidence_object where id = obj) <> (pl->>'size_bytes')::bigint then
    return bnx.doc_reject(p_staging, 'SIZE_MISMATCH');
  end if;
  insert into bnx.evidence_file(id, evidence_object_id, sha256_declared, size_declared, mime, original_name, acquired_via, acquired_by,
                                storage_state)
  values (fil, obj, sc.sha256, (pl->>'size_bytes')::bigint, pl->>'mime', d.original_name,
          case d.source_kind when 'DRIVE_INBOX' then 'drive_inbox' else 'mail_exact_fetch' end, own, 'archived');
  insert into bnx_doc.document_evidence(discovery_id, evidence_object_id, evidence_file_id, scan_id, declaration_id, source_fidelity,
                                        archived_file_id, staging_id)
  values (did, obj, fil, sc.id, dec, case when dec is null then 'AS_RECEIVED_FROM_OWNER' else 'OWNER_REDACTED_SOURCE' end,
          pl->>'archived_file_id', p_staging);
  perform bnx.doc_event(did, 'ARCHIVED', 'ADMITTED', p_staging);
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'discovery_id', did, 'state', 'ARCHIVED',
                                                    'evidence_object_id', obj, 'evidence_file_id', fil));
end $$;

-- DOC-SIN-14: documents whose last scan predates the current detector version and that are not terminal
create function bnx.wrk_doc_rescan_due() returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  return coalesce((select jsonb_agg(c.discovery_id order by c.discovery_id) from bnx_doc.document_current c
                    where c.state in ('PENDING_DECLARATION','ADMISSIBLE','ARCHIVED','SCAN_INCOMPLETE')
                      and c.sin_detector_version is distinct from bnx.sin_detector_spec()->>'version'), '[]');
end $$;

-- the Owner's view of pending and quarantined documents (DOC-SIN-06 label); no content, no locators
create function bnx.q_doc_redaction_queue(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  return jsonb_build_object('items', coalesce((select jsonb_agg(jsonb_build_object(
           'discovery_id', c.discovery_id, 'module', c.module, 'period_key', c.period_key, 'state', c.state,
           'file', case when c.name_withheld then null else c.original_name end, 'sha256', encode(c.sha256, 'hex'),
           'doc_class', c.doc_class, 'declaration_status', c.declaration_status, 'source_fidelity', c.source_fidelity,
           'label', case when c.source_fidelity = 'OWNER_REDACTED_SOURCE' then 'Owner-redacted copy — not the issuer''s original' end)
           order by c.discovery_id)
         from bnx_doc.document_current c where c.state in ('PENDING_DECLARATION','QUARANTINED','SCAN_INCOMPLETE','ADMISSIBLE')), '[]'));
end $$;

-- C4 (Worker): an MCP tool response that carried a candidate was refused; record the refusal without any value
create function bnx.wrk_audit_sin_refusal(p jsonb) returns bigint
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  if coalesce(p->>'tool', '') !~ '^[a-z_]{1,64}$' or jsonb_typeof(coalesce(p->'rules', '[]')) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(coalesce(p->'rules', '[]')) r where r !~ '^R_[A-Z0-9_]{1,30}$') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'refusal record'); end if;
  return bnx.audit(row(null, null, 'mcp', null, null)::bnx.actor, 'mcp_response_refused',
                   jsonb_build_object('tool', p->>'tool'), jsonb_build_object('rules', p->'rules'), null);
end $$;

-- ---------- MODIFY bnx.audit (9005) ----------
create or replace function bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev bytea; s bigint; ph bytea := bnx.h(coalesce(p_payload,'{}'::jsonb)::text); t timestamptz := now();
        hp text := bnx.envelope_value('host_profile'); tn text := bnx.envelope_value('tool_name');
        tv text := bnx.envelope_value('tool_version'); tr text := bnx.envelope_value('trace_id');
begin
  -- 9011 (Addendum A1 Rev 1 guard C2, DELEGATED_DECISION D-9011a-3): a SIN or ITN candidate anywhere in an audited payload or
  -- subject refuses the command; nothing is stored or hashed, and the value is never echoed
  if bnx.sin_json_has(p_payload) or bnx.sin_json_has(p_subject) then
    perform bnx.fail('SIN_CANDIDATE', 'P0422', p_command);
  end if;
  perform pg_advisory_xact_lock(hashtext('bnx.audit'));
  select seq, hash into s, prev from bnx_audit.audit_event order by seq desc limit 1;
  s := coalesce(s, 0) + 1;
  insert into bnx_audit.audit_event(seq, at, member_id, connection_id, channel, command, subject, payload_sha256, ledger_version, prev_hash,
                              hash, chain_version, at_hashed, host_profile, tool_name, tool_version, trace_id)
  values (s, t, a.member_id, a.connection_id, coalesce(a.channel,'system'), p_command, p_subject, ph, p_version, prev,
          sha256(coalesce(prev, '\x'::bytea) || bnx.audit_canonical_v2(s, a.member_id, a.connection_id, coalesce(a.channel,'system'),
                 p_command, p_subject, encode(ph,'hex'), p_version, t, 2::smallint, hp, tn, tv, tr)),
          2, t, hp, tn, tv, tr);
  return s;
end $$;

-- ---------- MODIFY bnx.stage_write (9010) ----------
create or replace function bnx.stage_write(p_nonce text, p_kind text, p_payload jsonb, p_via text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare l record; sid uuid; ph bytea;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or octet_length(p_payload::text) > 262144 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'staging payload (object, <= 256 KiB)'); end if;
  if bnx.stage_jobs(p_kind) is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'staging kind'); end if;
  -- 9011 DOC-SIN-10 (DELEGATED_DECISION D-9011a-2): index records are masked here so that the consumer can block the affected
  -- records without the value ever being staged; every other kind is refused (the Executor quarantines before staging)
  if p_kind = 'index_consumed' then
    p_payload := bnx.sin_mask_json(p_payload);
  elsif bnx.sin_json_has(p_payload) then
    perform bnx.fail('SIN_CANDIDATE', 'P0422', 'staging payload ' || p_kind);
  end if;
  select * into l from bnx.exec_lease where nonce = bnx.h(coalesce(p_nonce, '')) for update;
  if not found then perform bnx.fail('LEASE_INVALID', 'P0401'); end if;
  if l.completed_at is not null then perform bnx.fail('LEASE_USED', 'P0409'); end if;
  if l.expires_at <= now() then perform bnx.fail('LEASE_EXPIRED', 'P0401'); end if;
  if not (l.job_kind = any(bnx.stage_jobs(p_kind))) then perform bnx.fail('LEASE_KIND_MISMATCH', 'P0403', l.job_kind || ' -> ' || p_kind); end if;
  -- field allowlist for the kinds promoted here (the Gateway validates the full JSON Schema; mail subject/body never staged)
  if p_kind in ('index_consumed','mail_fetched') and exists (select 1 from jsonb_object_keys(p_payload) k where not k = any(case p_kind
       when 'index_consumed' then array['source_id','header','records','open_items','coverage','availability','run_log']
       else array['op','source_ref','canonical_key_sha256','message_id','provider_message_id','folder_ref','received_at','sender_domain',
                  'content_class','attachments_expected','attachments_fetched','evidence_sha256','ok'] end)) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'unknown staging field for ' || p_kind); end if;
  ph := bnx.h(p_payload::text);
  insert into bnx_intake.staging_payload(lease_id, stg_kind, payload, payload_sha256, staged_by)
  values (l.lease_id, p_kind, p_payload, ph, p_via) returning id into sid;
  update bnx.exec_lease set completed_at = now(), completion_sha256 = ph where lease_id = l.lease_id;
  perform bnx.enqueue('staging.promote', jsonb_build_object('staging_id', sid));
  return jsonb_build_object('staging_id', sid, 'state', 'STAGED', 'queue_generation', (select generation from bnx.queue_state));
end $$;

-- ---------- MODIFY bnx.wrk_consume_shared_index (9010) ----------
create or replace function bnx.wrk_consume_shared_index(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; src record; hdr text[]; rec jsonb; rk text; weak boolean; vh bytea; st text; reason text; region text; flag text;
        owner_type text; avail text; item uuid; inst uuid; j text; is_cra boolean; cra jsonb := '[]'; cnt jsonb := '{}'; res jsonb; c text;
        maxd date; n int := 0; oi jsonb; sinb boolean; mask text := bnx.sin_detector_spec()->>'mask';
        contract text[] := array['File ID','Original Name','Current Name','Document Date','Processed Date','Domain','Type','Tags','Source',
                                 'Sensitivity','Status','Summary','Record Path','Related Open Item','Notes'];
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'index_consumed' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;                        -- idempotent replay
  pl := s.payload;
  select * into src from bnx_intake.external_index_source where source_id = pl->>'source_id';
  if not found or not src.enabled then
    res := jsonb_build_object('status', 'REJECTED', 'reason', 'SOURCE_UNKNOWN_OR_DISABLED');
    update bnx_intake.staging_payload set state = 'REJECTED', promoted_at = now(), result = res where id = p_staging;
    return res;
  end if;
  hdr := array(select jsonb_array_elements_text(coalesce(pl->'header', '[]')));
  if not (cardinality(hdr) = 15 and hdr @> contract and contract @> hdr) then              -- order-insensitive, case-sensitive
    item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':run', 'EXCEPTION');
    perform bnx.intake_exception_new(item, 'BLOCKED', true, jsonb_build_object('reason', 'CONTRACT_MISMATCH', 'source_id', src.source_id));
    update bnx_intake.index_consumer_cursor set failed_runs = failed_runs + 1 where source_id = src.source_id and tab = 'Records';
    res := jsonb_build_object('status', 'BLOCKED', 'reason', 'CONTRACT_MISMATCH', 'consumed', 0);
    update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = res where id = p_staging;
    return res;
  end if;
  for rec in select x from jsonb_array_elements(coalesce(pl->'records', '[]')) x loop
    n := n + 1;
    rk := coalesce(nullif(rec->>'File ID', ''), nullif(rec->>'Record Path', ''));
    weak := rk is null;
    -- 9011 DOC-SIN-10: a record that stage_write masked is blocked; its columns are not stored, only key and version hash
    sinb := position(mask in rec::text) > 0;
    if sinb and coalesce(rk, '') like '%' || mask || '%' then rk := null; weak := true; end if;
    if weak and sinb then rk := 'sin:' || encode(bnx.h(rec::text), 'hex');
    elsif weak then rk := 'weak:' || encode(bnx.h(coalesce(rec->>'Original Name','') || '|' || coalesce(rec->>'Document Date','') || '|'
                                                || coalesce(rec->>'Source','')), 'hex'); end if;
    -- version hash over the 15 columns in contract order (F-C4-05: deterministic canonical form, not RFC 8785 JCS)
    vh := bnx.h((select jsonb_agg(coalesce(rec->k, 'null'::jsonb) order by o) from unnest(contract) with ordinality u(k, o))::text);
    if exists (select 1 from bnx_intake.index_record_ack where source_id = src.source_id and record_key = rk and record_version_hash = vh
                and status in ('CONSUMED','SKIPPED_SCOPE','SKIPPED_DOMAIN','DEAD_LETTER')) then
      cnt := jsonb_set(cnt, '{REPLAYED}', to_jsonb(coalesce((cnt->>'REPLAYED')::int, 0) + 1)); continue;
    end if;
    insert into bnx_intake.external_index_record(source_id, record_key, record_version_hash, weak_key, columns)
    values (src.source_id, rk, vh, weak, case when sinb then '{}'::jsonb else (select jsonb_object_agg(k, rec->k) from unnest(contract) k where rec ? k) end)
    on conflict (source_id, record_key, record_version_hash) do update set last_seen_at = now();
    begin maxd := greatest(maxd, (rec->>'Processed Date')::date); exception when others then null; end;
    item := null; reason := null; region := null;
    if sinb then
      st := 'BLOCKED'; reason := 'SIN_CANDIDATE';
      item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk, 'BLOCKED');
      perform bnx.intake_exception_new(item, reason, true, jsonb_build_object('source_id', src.source_id, 'record_key', rk),
                                       'idx:' || src.source_id || ':' || rk || ':' || reason);
    elsif rec->>'Domain' is distinct from 'Banking_Tax' then
      st := 'SKIPPED_DOMAIN';
    else
      is_cra := coalesce(rec->>'Type', '') ~* '\mCRA\M' or coalesce(rec->>'Tags', '') ~* '\mCRA\M';
      owner_type := case when coalesce(rec->>'Tags', '') ~* '\m(corporate|business)\M' then 'CORPORATE'
                         when coalesce(rec->>'Tags', '') ~* 'owner[:_ ]?unknown' then 'UNKNOWN' else 'PERSONAL' end;
      if is_cra then region := 'CA'; flag := 'CRA';
      else
        inst := bnx.sender_institution(coalesce(nullif(split_part(rec->>'Source', '@', 2), ''), rec->>'Source'));
        select jurisdiction into j from bnx.institution where id = inst;
        region := coalesce(bnx.region_of_jurisdiction(j), 'UNKNOWN');
        flag := bnx.pol_region_flag(region);
      end if;
      avail := case when not weak and coalesce(rec->>'File ID', '') <> '' and pl->'availability'->>rk = 'FILED_VERIFIED'
                    then 'FILED_VERIFIED' else 'INDEXED_SOURCE_ONLY' end;
      update bnx_intake.external_index_record set derived_category = case when is_cra then 'CRA' else 'Banking' end,
             derived_banking_region = region, derived_country_code = case when region like 'OTHER:%' then substr(region, 7) else region end,
             derived_account_owner_type = owner_type, availability = avail
       where source_id = src.source_id and record_key = rk and record_version_hash = vh;
      if owner_type <> 'PERSONAL' then st := 'BLOCKED'; reason := 'OWNER_TYPE_AMBIGUOUS';
      elsif region = 'UNKNOWN' then st := 'BLOCKED'; reason := 'COUNTRY_UNKNOWN';
      elsif bnx.pol_flag(flag) is distinct from 'YES' then st := 'SKIPPED_SCOPE'; reason := flag;
      else
        st := 'CONSUMED';
        item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk,
                                    case when avail = 'FILED_VERIFIED' then 'RECEIVED' else 'EVIDENCE_PENDING' end);
        if is_cra then cra := cra || jsonb_build_object('record_key', rk, 'document_date', rec->>'Document Date',
                                                          'masked_subject', coalesce(nullif(rec->>'Current Name', ''), rec->>'Original Name')); end if;
      end if;
      if st = 'BLOCKED' then
        item := bnx.intake_item_new('SHARED_INDEX', src.source_id || ':' || rk, 'BLOCKED');
        perform bnx.intake_exception_new(item, reason, true, jsonb_build_object('source_id', src.source_id, 'record_key', rk),
                                         'idx:' || src.source_id || ':' || rk || ':' || reason);
      end if;
    end if;
    st := bnx.index_ack(src.source_id, rk, vh, st, item, reason);                             -- same transaction as the item
    cnt := jsonb_set(cnt, array[st], to_jsonb(coalesce((cnt->>st)::int, 0) + 1));
  end loop;
  -- upstream open items -> Owner-only exceptions (deduplicated by upstream key)
  for oi in select x from jsonb_array_elements(coalesce(pl->'open_items', '[]')) x loop
    perform bnx.intake_exception_new(null, 'UPSTREAM_OPEN_ITEM', true, jsonb_build_object('source_id', src.source_id, 'key', left(oi->>'key', 120)),
                                     'open:' || src.source_id || ':' || left(oi->>'key', 120));
  end loop;
  -- CRA correspondence: never an assessment; unresolved taxpayer -> Owner-only; > 20 in one run -> one NOTICE_BURST exception
  if jsonb_array_length(cra) > 20 then
    perform bnx.notify('EXCEPTION', 'NOTICE_BURST:' || src.source_id || ':' || p_staging, true,
                       jsonb_build_object('kind', 'NOTICE_BURST', 'source_id', src.source_id, 'count', jsonb_array_length(cra)));
  else
    for rec in select x from jsonb_array_elements(cra) x loop
      perform bnx.notify('CRA_CORRESPONDENCE', 'CRA_CORRESPONDENCE:' || (rec->>'record_key'), true,
                         jsonb_build_object('kind', 'UNASSIGNED_TAX_NOTICE', 'record_key', rec->>'record_key', 'document_date', rec->>'document_date',
                                            'masked_subject', rec->>'masked_subject', 'caveat', 'an email may not contain the full CRA document'));
    end loop;
  end if;
  insert into bnx_intake.index_consumer_cursor(source_id, tab, last_run_at, rows_seen, max_processed_date_seen, coverage_declaration, failed_runs)
  values (src.source_id, 'Records', now(), n, maxd, coalesce(pl->'coverage', '{}'), 0)
  on conflict (source_id, tab) do update set last_run_at = now(), rows_seen = n,
    max_processed_date_seen = greatest(bnx_intake.index_consumer_cursor.max_processed_date_seen, maxd),
    coverage_declaration = coalesce(pl->'coverage', bnx_intake.index_consumer_cursor.coverage_declaration), failed_runs = 0;
  res := jsonb_build_object('status', 'PROMOTED', 'rows_seen', n, 'acks', cnt, 'cra_notices', jsonb_array_length(cra));
  update bnx_intake.staging_payload set state = 'PROMOTED', promoted_at = now(), result = res where id = p_staging;
  return res;
end $$;

-- ---------- MODIFY bnx.wrk_promote_staged (9010): document promoters (9011b) ----------
create or replace function bnx.wrk_promote_staged(p_staging uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; r jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging;
  if not found then return 'not_found'; end if;
  if s.state in ('PROMOTED','REJECTED') then return lower(s.state); end if;
  if s.stg_kind = 'index_consumed' then r := bnx.wrk_consume_shared_index(p_staging);
  elsif s.stg_kind = 'mail_fetched' and s.payload->>'op' = 'move' then r := bnx.wrk_mail_move_result(p_staging);
  elsif s.stg_kind = 'mail_fetched' then r := bnx.wrk_mail_evidence_registered(p_staging);
  elsif s.stg_kind = 'doc_discovered' then r := bnx.wrk_doc_discovered(p_staging);       -- 9011b
  elsif s.stg_kind = 'doc_validated' then r := bnx.wrk_doc_validated(p_staging);         -- 9011b
  elsif s.stg_kind = 'doc_archived' then r := bnx.wrk_doc_archived(p_staging);           -- 9011b (admission gate)
  else
    update bnx_intake.staging_payload set state = 'AWAITING_PROMOTER' where id = p_staging;   -- 9011c / 9014 / 9016 promoters
    return 'awaiting_promoter';
  end if;
  return lower(coalesce(r->>'status', 'promoted'));
end $$;

select bnx.apply_grants();
