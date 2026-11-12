-- 9021_s4_ai_host_oauth.sql -- S4 AIH-1/AIH-2 stage: database support for the OAuth 2.1 endpoints and the catalog MCP server of
-- the Gateway (AIH V1.2 §3, §4; UA V1.2 §7.2, §8). Expand-only. Not in the V1.2 migration register (D-AIH-1): the register's
-- 9009 created the OAuth core but no function lets the Gateway validate a client and its redirect URI before the PWA
-- consent screen, infer the host profile of a DCR registration, or list a member's AI connections for revocation.
--   NEW: bnx.authn_oauth_client (bnx_authn; client and redirect check before any redirect, CIMD eligibility of an unknown
--        https client id: RFC 6749 §4.1.2.1, AIH §4.2/§4.4), bnx.q_ai_connections (PWA only; the caller's own connections
--        with client, host profile, scopes, consented subsets, last token issue and revocation: OR-M-05, PV-AIH-03).
--   MODIFY: bnx.authn_register_client (9009 body; changed only where marked "9021"): when the request names no host profile,
--        the profile is inferred from the redirect URIs (the single profile whose allowlist matches every URI on this
--        instance's environment; none or several -> INVALID_REDIRECT_URI). DCR clients such as Claude's custom connector
--        send RFC 7591 metadata only, never a Balnexa host profile.
--   MODIFY: bnx.resolve_actor (9017 body; changed only where marked "9021"): on a bearer credential the audit provenance
--        host_profile is the connection's own profile, never a value from the credential envelope (AIH §4.5; a client cannot
--        claim another host in the audit chain). tool_name, tool_version and trace_id still come from the Gateway envelope.
set role bnx_definer;

-- ---------- client and redirect check (bnx_authn; no credential) ----------
create function bnx.authn_oauth_client(req jsonb) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare c record; cid text := req->>'client_id'; ru text := req->>'redirect_uri';
begin
  if cid is null or length(cid) > 300 or cid !~ '^[ -~]+$' then
    return jsonb_build_object('known', false, 'cimd_allowed', false);
  end if;
  select * into c from bnx.oauth_client where client_id = cid;
  if not found then
    -- an unknown client id may be fetched as a Client ID Metadata Document only when it matches a host-profile allowlist
    return jsonb_build_object('known', false, 'cimd_allowed',
      exists (select 1 from bnx.host_profile_redirect h where h.kind = 'cimd_client_id' and cid ~ h.pattern));
  end if;
  return jsonb_build_object('known', true, 'client_id', c.client_id, 'client_name', c.display_name, 'host_profile', c.host_profile,
    'registration_kind', c.registration_kind, 'redirect_ok', ru is not null and ru = any(c.redirect_uris));
end $$;

-- ---------- DCR / CIMD registration (MODIFY, 9009 body) ----------
create or replace function bnx.authn_register_client(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare prof text := req->>'host_profile'; kind text := coalesce(req->>'registration_kind', 'DCR'); cid text; u text; envr text; ex record;
        cands text[];
begin
  -- the environment comes from the instance, never from the caller (same-family review finding 9): loopback/dev redirect
  -- patterns only on a synthetic-data instance
  envr := case when (select value #>> '{}' from bnx.household_setting where key = 'data_class') = 'synthetic' then 'non_production'
               else 'production' end;
  if kind not in ('DCR','CIMD') or jsonb_typeof(req->'redirect_uris') is distinct from 'array' or jsonb_array_length(req->'redirect_uris') = 0
     or jsonb_array_length(req->'redirect_uris') > 10 then
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'redirect_uris'); end if;
  -- 9021: no host profile named -> the single profile whose redirect allowlist matches every URI on this environment
  if prof is null then
    select array_agg(p order by p) into cands from (select distinct host_profile p from bnx.host_profile_redirect) x
     where not exists (select 1 from jsonb_array_elements_text(req->'redirect_uris') ru(v)
                        where not exists (select 1 from bnx.host_profile_redirect h where h.host_profile = x.p and h.kind = 'redirect_uri'
                                           and ru.v ~ h.pattern and (h.environment = 'any' or envr <> 'production')));
    if coalesce(cardinality(cands), 0) <> 1 then
      perform bnx.fail('INVALID_REDIRECT_URI', 'P0422', 'no single host profile matches the redirect URIs'); end if;
    prof := cands[1];
  end if;
  if not exists (select 1 from bnx.host_profile_redirect where host_profile = prof) then
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'host_profile'); end if;
  for u in select jsonb_array_elements_text(req->'redirect_uris') loop
    if not exists (select 1 from bnx.host_profile_redirect h where h.host_profile = prof and h.kind = 'redirect_uri' and u ~ h.pattern
                    and (h.environment = 'any' or envr <> 'production')) then
      perform bnx.fail('INVALID_REDIRECT_URI', 'P0422', u); end if;
  end loop;
  if kind = 'CIMD' then
    cid := req->>'client_id';
    if cid is null or not exists (select 1 from bnx.host_profile_redirect h where h.host_profile = prof and h.kind = 'cimd_client_id' and cid ~ h.pattern) then
      perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'client_id'); end if;
  else
    cid := 'dcr-' || replace(gen_random_uuid()::text, '-', '');
  end if;
  -- an existing client is never overwritten by an unauthenticated registration: an identical CIMD re-registration is
  -- idempotent, anything else is refused (metadata is fetched from the client_id URL by the Gateway when CIMD is routed)
  select * into ex from bnx.oauth_client where client_id = cid;
  if ex.client_id is not null then
    if ex.registration_kind = 'CIMD' and ex.host_profile = prof
       and ex.redirect_uris = array(select jsonb_array_elements_text(req->'redirect_uris')) then
      return jsonb_build_object('client_id', cid, 'host_profile', prof, 'token_endpoint_auth_method', 'none',
                                'grant_types', jsonb_build_array('authorization_code','refresh_token'));
    end if;
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'client_id already registered');
  end if;
  insert into bnx.oauth_client(client_id, display_name, redirect_uris, registration_kind, host_profile, metadata_digest)
  values (cid, coalesce(left(req->>'client_name', 100), prof), array(select jsonb_array_elements_text(req->'redirect_uris')), kind, prof,
          encode(bnx.h(req::text), 'hex'));
  return jsonb_build_object('client_id', cid, 'host_profile', prof, 'token_endpoint_auth_method', 'none',
                            'grant_types', jsonb_build_array('authorization_code','refresh_token'));
end $$;

-- ---------- the caller's AI connections (PWA Settings; revocation path) ----------
-- Not in function_scope, so never an MCP tool (require() refuses an unlisted function on the mcp channel).
create function bnx.q_ai_connections(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rows_ jsonb;
begin
  perform bnx.require(a, 0);
  select coalesce(jsonb_agg(x order by x->>'approved_at' desc, x->>'connection_id'), '[]') into rows_ from (
    select jsonb_build_object('connection_id', c.id, 'client_id', c.client_id, 'client_name', o.display_name,
             'host_profile', coalesce(c.host_profile, o.host_profile), 'registration_kind', o.registration_kind,
             'scopes', to_jsonb(c.scopes), 'legacy', c.legacy, 'refresh_eligible', c.refresh_eligible, 'resource', c.resource,
             'account_currency_ids', coalesce((select jsonb_agg(s.value order by s.value) from bnx.ai_connection_subset s
                                                where s.connection_id = c.id and s.kind = 'account_currency'), '[]'),
             'approved_at', c.approved_at, 'revoked_at', c.revoked_at,
             'last_token_at', (select max(t.issued_at) from bnx.ai_connection_token t where t.connection_id = c.id),
             'state', case when c.revoked_at is not null then 'revoked' else 'active' end) x
      from bnx.ai_connection c join bnx.oauth_client o on o.client_id = c.client_id
     where c.member_id = a.member_id) t;
  return jsonb_build_object('connections', rows_);
end $$;

-- ---------- host provenance from the connection (MODIFY, 9017 body) ----------
create or replace function bnx.resolve_actor(cred jsonb) returns bnx.actor
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare h bytea; r record; a bnx.actor; k text; val text; hp text;                                  -- 9021: hp
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
    select c.id cid, c.member_id, c.scopes, c.revoked_at crev, t.expires_at, t.revoked_at trev, m.state, t.resource,  -- 9017: resource
           coalesce(c.host_profile, o.host_profile) host_profile into r                                          -- 9021
      from bnx.ai_connection_token t join bnx.ai_connection c on c.id = t.connection_id
      join bnx.oauth_client o on o.client_id = c.client_id
      join bnx.member m on m.id = c.member_id where t.token_sha256 = h and t.kind = 'access';
    if not found or r.trev is not null or r.crev is not null or now() > r.expires_at or r.state <> 'active' then
      perform bnx.fail('UNAUTHENTICATED', 'P0401');
    end if;
    -- 9017 (B7): a token issued for a resource is accepted only by the Gateway of that resource
    if cred ? 'audience' and r.resource is not null and r.resource is distinct from cred->>'audience' then
      perform bnx.fail('UNAUTHENTICATED', 'P0401');
    end if;
    a := row(r.member_id, r.cid, 'mcp', null, r.scopes)::bnx.actor;
    hp := coalesce(r.host_profile, '');                                                                     -- 9021
  else
    perform bnx.fail('UNAUTHENTICATED', 'P0401');
  end if;
  perform set_config('bnx.actor_member', a.member_id::text, true);
  foreach k in array array['host_profile','tool_name','tool_version','trace_id'] loop
    val := cred->'envelope'->>k;
    if val is not null and (length(val) > 100 or val !~ '^[ -~]+$') then          -- 9011 G0R
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'envelope.' || k);
    end if;
    if k = 'host_profile' and a.channel = 'mcp' then val := hp; end if;                                    -- 9021
    perform set_config('bnx.' || k, coalesce(val, ''), true);
  end loop;
  return a;
end $$;

select bnx.apply_grants();

-- @@CATALOG-BEGIN (generated by tools/s4/catalog_build.py; do not edit)
comment on function bnx.q_ai_connections(jsonb, jsonb) is $c${"channels":["pwa"],"core_function":"bnx.q_ai_connections","description":"The caller's AI connections: client, host profile, scopes, consented account-currencies, last token issue, revocation state (PWA only)","errors":["UNAUTHENTICATED","FORBIDDEN_ROLE","FORBIDDEN_CHANNEL","FORBIDDEN_SCOPE","SCOPE_NOT_CONSENTED","NOT_AVAILABLE","VALIDATION_FAILED","SCOPE_DISABLED","BNX_BINDING_MISMATCH","BNX_FLAG_BINDING_MISMATCH"],"evidence_citation":false,"idempotency":"none","input_schema":{"additionalProperties":true,"properties":{},"type":"object"},"kind":"query","legacy":{"propose":false,"read":false},"masked_fields":[],"mcp":{"destructiveHint":false,"openWorldHint":false,"readOnlyHint":true,"ui_resource":null},"module_flags":[],"name":"sys.ai_connections","needs_ac_subset":false,"output_schema":{"type":"object"},"provenance":"derived","rest":"/api/v1/queries/ai_connections","risk_class":"RC-READ","scopes":[],"tier":0,"ui_profile":null,"version":"1.0.0"}$c$;
-- @@CATALOG-END
