-- 9003 Instance identity, configuration anchor and lifecycle, module flags, release/install events
-- (V1.2 UA §4.2-§4.3, AE §5; OBJ-019, OBJ-378/379/380; CROSS-04, CROSS-05, S4B-F18).
-- Lifecycle: NONE -> PENDING_OWNER_ACCEPTANCE -> PENDING_DEPLOY -> ACTIVE (-> SUPERSEDED); any non-terminal -> REJECTED.
-- Owner acceptance never activates. Activation only by the installer-only bnx.install_activate_config (no cmd_ prefix,
-- never granted by apply_grants). R1 bnx.install_household is unchanged (REUSE) and is called by install_household_v2.
set role bnx_definer;

create table bnx.instance_identity(
  singleton boolean primary key default true check (singleton),
  project_id text not null check (length(project_id) between 1 and 100),
  instance_uid uuid not null,
  product_id text not null default 'balnexa' check (product_id = 'balnexa'),
  origin text not null check (origin in ('install_v2','adopt','restore_as_new')),
  created_at timestamptz not null default now(),
  check (project_id <> product_id));

create table bnx.config_version_anchor(
  config_version int primary key check (config_version > 0),
  config_sha256 text check (config_sha256 ~ '^[0-9a-f]{64}$'),   -- NULL only for installer-created versions until activation binds it
  schema text not null,
  deployment_mode text,
  modules jsonb not null,
  state text not null check (state in ('PENDING_OWNER_ACCEPTANCE','PENDING_DEPLOY','ACTIVE','SUPERSEDED','REJECTED')),
  origin text not null check (origin in ('owner_draft','install_v2','adopt')),
  installer_policy jsonb,                 -- financial policy declared by the installer; materialized by 9006 (financial_policy)
  prepared_by uuid references bnx.member, accepted_by uuid references bnx.member, accepted_at timestamptz,
  activated_at timestamptz, deployed_digest text, migration_notes text,
  created_at timestamptz not null default now(),
  check (origin = 'owner_draft' or installer_policy is not null),
  check (origin <> 'owner_draft' or config_sha256 is not null));
create unique index config_version_anchor_one_active on bnx.config_version_anchor((true)) where state = 'ACTIVE';

create table bnx.config_state_event(
  config_version int not null references bnx.config_version_anchor,
  seq int not null, from_state text not null, to_state text not null,
  actor_member_id uuid references bnx.member, actor_session text not null default session_user,
  detail jsonb not null default '{}', xid xid8 not null default pg_current_xact_id(), at timestamptz not null default now(),
  primary key (config_version, seq));

create table bnx.instance_module_flag(
  config_version int not null references bnx.config_version_anchor,
  flag_key text not null check (flag_key in ('Canada','International','CRA')),
  value text not null check (value in ('YES','NO')),
  primary key (config_version, flag_key));

create table bnx.release_install_event(
  id bigint generated always as identity primary key,
  release_version text not null, manifest_sha256 text,
  kind text not null check (kind in ('INSTALL','ADOPT','UPGRADE','RESTORE')),
  pre_fingerprint text, post_fingerprint text, detail jsonb not null default '{}',
  recorded_by text not null default session_user, at timestamptz not null default now());

alter table bnx.member add column preference jsonb not null default '{}'::jsonb check (jsonb_typeof(preference) = 'object');

do $$
declare t text;
begin
  foreach t in array array['instance_identity','config_state_event','instance_module_flag','release_install_event'] loop
    execute format('create trigger t_append_only before update or delete on bnx.%I for each row execute function bnx.trg_append_only()', t);
  end loop;
end $$;
insert into bnx.table_class values ('instance_identity','F'),('config_version_anchor','M'),('config_state_event','F'),
  ('instance_module_flag','F'),('release_install_event','F');

-- The anchor's state is a projection of config_state_event: a state change needs an event for the same transition in the
-- same transaction; identity columns never change; config_sha256 may only be bound once (NULL -> digest).
create function bnx.trg_config_anchor_projection() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.restore_mode() then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then raise exception 'APPEND_ONLY: delete config_version_anchor' using errcode = 'P0409'; end if;
  if new.config_version <> old.config_version or new.schema <> old.schema or new.modules <> old.modules
     or new.origin <> old.origin or new.created_at <> old.created_at
     or (old.config_sha256 is not null and new.config_sha256 is distinct from old.config_sha256) then
    raise exception 'WRITE_ONCE: config_version_anchor %', old.config_version using errcode = 'P0409';
  end if;
  if new.state <> old.state and not exists (select 1 from bnx.config_state_event e where e.config_version = new.config_version
        and e.from_state = old.state and e.to_state = new.state and e.xid = pg_current_xact_id()) then
    raise exception 'CONFIG_STATE_PROJECTION: % -> % without event', old.state, new.state using errcode = 'P0409';
  end if;
  return new;
end $$;
create trigger t_projection before update or delete on bnx.config_version_anchor
  for each row execute function bnx.trg_config_anchor_projection();

-- Exactly three flag rows for every version that has been accepted or installed; none for an unaccepted draft.
create function bnx.trg_config_flags_complete() returns trigger
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare cv int := coalesce(new.config_version, old.config_version); st text; n int;
begin
  if bnx.restore_mode() then return null; end if;
  select state into st from bnx.config_version_anchor where config_version = cv;
  select count(*) into n from bnx.instance_module_flag where config_version = cv;
  if st in ('PENDING_DEPLOY','ACTIVE','SUPERSEDED') and n <> 3 then
    raise exception 'CONFIG_FLAGS_INCOMPLETE: version % has % flag rows', cv, n using errcode = 'P0422';
  end if;
  if st = 'PENDING_OWNER_ACCEPTANCE' and n <> 0 then
    raise exception 'CONFIG_FLAGS_BEFORE_ACCEPTANCE: version %', cv using errcode = 'P0422';
  end if;
  return null;
end $$;
create constraint trigger t_flags_complete after insert or update on bnx.config_version_anchor
  deferrable initially deferred for each row execute function bnx.trg_config_flags_complete();
create constraint trigger t_flags_complete after insert on bnx.instance_module_flag
  deferrable initially deferred for each row execute function bnx.trg_config_flags_complete();

-- ---------- helpers ----------
create function bnx.ledger_fingerprint() returns text
language sql stable set search_path = pg_catalog, pg_temp as $$
  select encode(sha256(convert_to(concat_ws(E'\n',
    (select version::text from bnx.ledger_state),
    (select string_agg(concat_ws('|', je.id, je.entry_no, je.economic_type, je.transaction_date, je.posting_date,
                                 je.description, je.original_amount, je.original_currency), E'\n' order by je.id) from bnx.journal_entry je),
    (select string_agg(concat_ws('|', jl.id, jl.journal_id, jl.ledger_account_id, jl.currency, jl.amount), E'\n' order by jl.id)
       from bnx.journal_line jl)), 'UTF8')), 'hex')
$$;

create function bnx.config_modules_valid(p jsonb) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'object'
     and (select array_agg(k order by k) from jsonb_object_keys(p) k) = array['CRA','Canada','International']
     and (select bool_and(p->>k in ('YES','NO')) from jsonb_object_keys(p) k)
$$;

create function bnx.config_transition(p_cv int, p_to text, p_member uuid, p_detail jsonb) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare cur text; n int;
begin
  select state into cur from bnx.config_version_anchor where config_version = p_cv for update;
  if not ((cur = 'PENDING_OWNER_ACCEPTANCE' and p_to in ('PENDING_DEPLOY','REJECTED'))
       or (cur = 'PENDING_DEPLOY' and p_to in ('ACTIVE','REJECTED'))
       or (cur = 'ACTIVE' and p_to = 'SUPERSEDED')) then
    perform bnx.fail('CONFIG_STATE', 'P0409', coalesce(cur, 'NONE') || ' -> ' || p_to);
  end if;
  select coalesce(max(seq), 0) + 1 into n from bnx.config_state_event where config_version = p_cv;
  insert into bnx.config_state_event(config_version, seq, from_state, to_state, actor_member_id, detail)
  values (p_cv, n, cur, p_to, p_member, coalesce(p_detail, '{}'));
  update bnx.config_version_anchor set state = p_to where config_version = p_cv;
end $$;

create function bnx.config_create(p_origin text, p_sha text, p_schema text, p_mode text, p_modules jsonb, p_policy jsonb,
                                  p_member uuid, p_notes text) returns int
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare cv int; st text := case when p_origin = 'owner_draft' then 'PENDING_OWNER_ACCEPTANCE' else 'PENDING_DEPLOY' end; k text;
begin
  if not bnx.config_modules_valid(p_modules) then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'modules'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.config'));
  select coalesce(max(config_version), 0) + 1 into cv from bnx.config_version_anchor;
  insert into bnx.config_version_anchor(config_version, config_sha256, schema, deployment_mode, modules, state, origin,
    installer_policy, prepared_by, migration_notes)
  values (cv, p_sha, p_schema, p_mode, p_modules, st, p_origin, p_policy, p_member, p_notes);
  insert into bnx.config_state_event(config_version, seq, from_state, to_state, actor_member_id, detail)
  values (cv, 1, 'NONE', st, p_member, jsonb_build_object('origin', p_origin));
  if st = 'PENDING_DEPLOY' then
    for k in select jsonb_object_keys(p_modules) loop
      insert into bnx.instance_module_flag values (cv, k, p_modules->>k);
    end loop;
  end if;
  return cv;
end $$;

-- ---------- installer-only functions (run by bnx_migrator under SET ROLE bnx_definer; no runtime EXECUTE) ----------
create function bnx.install_household_v2(p_owner_name text, p_iss text, p_sub text, p_project_id text, p_instance_uid uuid,
                                         p_modules jsonb, p_policy jsonb) returns uuid
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare m uuid; cv int; pre text;
begin
  if session_user <> 'bnx_migrator' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  if exists (select 1 from bnx.member) or exists (select 1 from bnx.instance_identity) then
    perform bnx.fail('ALREADY_INSTALLED', 'P0409'); end if;
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'policy'); end if;
  pre := bnx.ledger_fingerprint();
  m := bnx.install_household(p_owner_name, p_iss, p_sub);          -- R1, unchanged
  insert into bnx.instance_identity(project_id, instance_uid, origin) values (p_project_id, p_instance_uid, 'install_v2');
  cv := bnx.config_create('install_v2', null, 'ai-entry/2.1', null, p_modules, p_policy, null, 'fresh install');
  insert into bnx.release_install_event(release_version, kind, pre_fingerprint, post_fingerprint, detail)
  values ('S4-V1.2/CORE-1', 'INSTALL', pre, bnx.ledger_fingerprint(), jsonb_build_object('config_version', cv));
  perform bnx.audit(row(m, null, 'installer', null, null)::bnx.actor, 'install_household_v2',
                    jsonb_build_object('member_id', m, 'config_version', cv, 'project_id', p_project_id), p_modules, null);
  return m;
end $$;

create function bnx.adopt_existing_household(p_project_id text, p_instance_uid uuid, p_modules jsonb, p_policy jsonb) returns int
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare cv int; pre text; n int;
begin
  if session_user <> 'bnx_migrator' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select count(*) into n from bnx.member where role = 'owner';
  if n <> 1 then perform bnx.fail('NOT_ADOPTABLE', 'P0409', 'exactly one installed household required, found ' || n); end if;
  if exists (select 1 from bnx.instance_identity) then perform bnx.fail('ALREADY_ADOPTED', 'P0409'); end if;
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'policy'); end if;
  pre := bnx.ledger_fingerprint();
  insert into bnx.instance_identity(project_id, instance_uid, origin) values (p_project_id, p_instance_uid, 'adopt');
  cv := bnx.config_create('adopt', null, 'ai-entry/2.1', null, p_modules, p_policy, null, 'adoption of an installed R1 household');
  insert into bnx.release_install_event(release_version, kind, pre_fingerprint, post_fingerprint, detail)
  values ('S4-V1.2/CORE-1', 'ADOPT', pre, bnx.ledger_fingerprint(), jsonb_build_object('config_version', cv));
  perform bnx.audit(row(null, null, 'installer', null, null)::bnx.actor, 'adopt_existing_household',
                    jsonb_build_object('config_version', cv, 'project_id', p_project_id), p_modules, null);
  return cv;
end $$;

-- B1 identity, B2 digest and B8 flags against the deployed Worker environment (p_deployed_env: {project_id, instance_uid,
-- modules}); marks the version ACTIVE and the previous ACTIVE version SUPERSEDED. The only activation path.
create function bnx.install_activate_config(p_config_version int, p_deployed_digest text, p_deployed_env jsonb) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare an record; idt record; prev int; k text;
begin
  if session_user <> 'bnx_migrator' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into an from bnx.config_version_anchor where config_version = p_config_version for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if an.state <> 'PENDING_DEPLOY' then perform bnx.fail('CONFIG_STATE', 'P0409', an.state || ' -> ACTIVE'); end if;
  if p_deployed_digest is null or p_deployed_digest !~ '^[0-9a-f]{64}$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'deployed_digest'); end if;
  if an.config_sha256 is not null and an.config_sha256 <> p_deployed_digest then
    perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B2 config digest'); end if;
  select * into idt from bnx.instance_identity;
  if not found or p_deployed_env->>'project_id' is distinct from idt.project_id
     or p_deployed_env->>'instance_uid' is distinct from idt.instance_uid::text then
    perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B1 instance identity'); end if;
  if not bnx.config_modules_valid(p_deployed_env->'modules') then perform bnx.fail('BNX_FLAG_BINDING_MISMATCH', 'P0409', 'B8'); end if;
  for k in select flag_key from bnx.instance_module_flag where config_version = p_config_version loop
    if (select value from bnx.instance_module_flag where config_version = p_config_version and flag_key = k)
       is distinct from p_deployed_env->'modules'->>k then
      perform bnx.fail('BNX_FLAG_BINDING_MISMATCH', 'P0409', 'B8 ' || k); end if;
  end loop;
  select config_version into prev from bnx.config_version_anchor where state = 'ACTIVE' for update;
  if prev is not null then perform bnx.config_transition(prev, 'SUPERSEDED', null, jsonb_build_object('by_version', p_config_version)); end if;
  if an.config_sha256 is null then
    update bnx.config_version_anchor set config_sha256 = p_deployed_digest where config_version = p_config_version;
  end if;
  perform bnx.config_transition(p_config_version, 'ACTIVE', null,
            jsonb_build_object('deployed_digest', p_deployed_digest, 'digest_bound_at_activation', an.config_sha256 is null));
  update bnx.config_version_anchor set activated_at = now(), deployed_digest = p_deployed_digest where config_version = p_config_version;
  perform bnx.audit(row(null, null, 'installer', null, null)::bnx.actor, 'install_activate_config',
                    jsonb_build_object('config_version', p_config_version, 'superseded', prev), p_deployed_env, null);
  return 'ACTIVE';
end $$;

-- ---------- Owner commands (bnx_app) ----------
create function bnx.require_t3_fresh(a bnx.actor) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if a.channel <> 'pwa' or a.session_id is null then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  if not exists (select 1 from bnx.member_session where id = a.session_id and created_at >= now() - interval '15 minutes') then
    perform bnx.fail('REAUTH_REQUIRED', 'P0401', 'T3 requires a sign-in within 15 minutes'); end if;
end $$;

create function bnx.cmd_prepare_config_draft(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; cv int;
begin
  perform bnx.require(a, 3);
  perform bnx.require_t3_fresh(a);
  rc := bnx.idem_begin(a, 'prepare_config_draft', cmd); if rc is not null then return rc; end if;
  if not exists (select 1 from bnx.instance_identity) then perform bnx.fail('NOT_INSTALLED', 'P0409'); end if;
  if coalesce(cmd->>'config_sha256', '') !~ '^[0-9a-f]{64}$' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'config_sha256'); end if;
  if coalesce(cmd->>'schema', '') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'schema'); end if;
  cv := bnx.config_create('owner_draft', cmd->>'config_sha256', cmd->>'schema', cmd->>'deployment_mode', cmd->'modules', null,
                          a.member_id, cmd->>'migration_notes');
  perform bnx.audit(a, 'prepare_config_draft', jsonb_build_object('config_version', cv), cmd, null);
  return bnx.idem_end(a, 'prepare_config_draft', cmd, jsonb_build_object('config_version', cv, 'state', 'PENDING_OWNER_ACCEPTANCE'));
end $$;

create function bnx.cmd_accept_instance_config(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; rc jsonb; an record; k text; cv int := (cmd->>'config_version')::int;
        decision text := coalesce(cmd->>'decision', 'accept');
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  perform bnx.require_t3_fresh(a);
  rc := bnx.idem_begin(a, 'accept_instance_config', cmd); if rc is not null then return rc; end if;
  select * into an from bnx.config_version_anchor where config_version = cv for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if decision = 'reject' then
    perform bnx.config_transition(cv, 'REJECTED', a.member_id, jsonb_build_object('reason', cmd->>'reason'));
  elsif decision = 'accept' then
    if an.state <> 'PENDING_OWNER_ACCEPTANCE' then perform bnx.fail('CONFIG_STATE', 'P0409', an.state || ' -> PENDING_DEPLOY'); end if;
    if cmd->>'config_sha256' is distinct from an.config_sha256 then perform bnx.fail('CONFIG_DIGEST_MISMATCH', 'P0409'); end if;
    if cmd->'modules' is distinct from an.modules then perform bnx.fail('CONFIG_DIGEST_MISMATCH', 'P0409', 'modules'); end if;
    for k in select jsonb_object_keys(an.modules) loop
      insert into bnx.instance_module_flag values (cv, k, an.modules->>k);
    end loop;
    perform bnx.config_transition(cv, 'PENDING_DEPLOY', a.member_id, '{}');
    update bnx.config_version_anchor set accepted_by = a.member_id, accepted_at = now() where config_version = cv;
  else
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'decision');
  end if;
  perform bnx.audit(a, 'accept_instance_config', jsonb_build_object('config_version', cv, 'decision', decision), cmd, null);
  return bnx.idem_end(a, 'accept_instance_config', cmd, jsonb_build_object('config_version', cv,
           'state', case when decision = 'accept' then 'PENDING_DEPLOY' else 'REJECTED' end));
end $$;

create function bnx.q_config_status(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); act record; r jsonb;
begin
  perform bnx.require(a, 0);
  select * into act from bnx.config_version_anchor where state = 'ACTIVE';
  select jsonb_build_object(
      'active', case when act.config_version is null then null else jsonb_build_object('config_version', act.config_version,
                'config_sha256', act.config_sha256, 'deployment_mode', act.deployment_mode, 'activated_at', act.activated_at,
                'flags', (select jsonb_object_agg(flag_key, value) from bnx.instance_module_flag where config_version = act.config_version)) end,
      'pending', (select jsonb_agg(jsonb_build_object('config_version', config_version, 'state', state) order by config_version)
                    from bnx.config_version_anchor where state in ('PENDING_OWNER_ACCEPTANCE','PENDING_DEPLOY')),
      'identity', (select jsonb_build_object('project_id', project_id, 'instance_uid', instance_uid, 'origin', origin) from bnx.instance_identity),
      'schema_head', (select max(version) from bnx.schema_migrations)) into r;
  return r;
end $$;

-- answers without a credential (only endpoint left when a binding check fails); reveals no identity values
create function bnx.q_health(cred jsonb, q jsonb) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object(
    'status', case when exists (select 1 from bnx.config_version_anchor where state = 'ACTIVE') then 'ok' else 'unconfigured' end,
    'schema_head', (select max(version) from bnx.schema_migrations),
    'identity_present', exists (select 1 from bnx.instance_identity))
$$;

create function bnx.q_whoami(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); m record;
begin
  perform bnx.require(a, 0);
  select * into m from bnx.member where id = a.member_id;
  return jsonb_build_object('member_id', m.id, 'display_name', m.display_name, 'role', m.role, 'channel', a.channel,
                            'connection_id', a.connection_id, 'scopes', to_jsonb(a.scopes), 'preference', m.preference);
end $$;

select bnx.apply_grants();
