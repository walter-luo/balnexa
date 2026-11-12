-- 9029_s4_deploy_rule.sql -- S4 phase 2.6 (INS-1 deploy rule, UA V1.2 §9.1). Expand-only. Not in the V1.2 register (D-DPL-1).
--   MODIFY: bnx.install_activate_config (9003 body; changed only where marked "9029"): when p_deployed_env carries
--           worker_supports_extension ["lo","hi"] (from release/manifest.json or release.js), activation is refused with
--           BNX_BINDING_MISMATCH (B3) unless the applied extension head lies in that range. Callers that do not send the key
--           behave as before. deploy/install_instance.py sends it.
set role bnx_definer;

create or replace function bnx.install_activate_config(p_config_version int, p_deployed_digest text, p_deployed_env jsonb) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare an record; idt record; prev int; k text; hd text;                                       -- 9029: hd
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
  -- 9029 deploy rule (UA V1.2 §9.1; INS-1 R3): when the installer states the deployed Worker's schema range, the applied
  -- extension head must lie inside it, so a Worker that does not understand this schema is never activated against it
  if p_deployed_env ? 'worker_supports_extension' then                                                                  -- 9029
    hd := (select max(version) from bnx.schema_migrations where version >= '9000');
    if jsonb_typeof(p_deployed_env->'worker_supports_extension') <> 'array'
       or hd < p_deployed_env->'worker_supports_extension'->>0 or hd > p_deployed_env->'worker_supports_extension'->>1 then
      perform bnx.fail('BNX_BINDING_MISMATCH', 'P0409', 'B3 deployed worker range excludes schema head ' || coalesce(hd, 'none')); end if;
  end if;
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

select bnx.apply_grants();
