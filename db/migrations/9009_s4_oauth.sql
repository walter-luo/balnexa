-- 9009 OAuth 2.1 for AI hosts (V1.2 UA §7.2; AIH §4; OBJ-023; S4B-F09; CROSS-02).
-- R1 defects fixed: authn_oauth_token fails closed on missing client_id/redirect_uri (IS DISTINCT FROM), redeems a code
-- single-use (UPDATE ... WHERE used_at IS NULL RETURNING; a replay revokes the connection's tokens and RETURNS
-- {"error":"invalid_grant"} so the revocation is not rolled back by an exception), cmd_revoke_ai_connection revokes tokens
-- only of the caller's own connection. Additions: catalog scopes (CHECK replaced; legacy R1 'read'/'propose' kept only for
-- rows created under R1), subsets, refresh tokens (30-day sliding rotation; reuse revokes the connection; never for legacy
-- connections), RFC 7009 revocation, RFC 7591 DCR / CIMD registration against host-profile allowlists, resource audience.
-- Authorization on the MCP channel (require() MODIFY): every cmd_/q_ function reachable by an AI connection is listed in
-- bnx.function_scope with the catalog scope it needs; the caller is identified from the PL/pgSQL call stack; an unlisted
-- function is refused (fail closed). Legacy 'read' reaches only balances and R-BAL/F1 snapshots; legacy 'propose' only the
-- finance draft functions (none exist before 9010). snapshot_decision() MODIFY applies the same boundary to replays.
set role bnx_definer;

-- ---------- clients and host profiles ----------
alter table bnx.oauth_client add column registration_kind text not null default 'PREREGISTERED'
  check (registration_kind in ('DCR','CIMD','PREREGISTERED'));
alter table bnx.oauth_client add column host_profile text;
alter table bnx.oauth_client add column metadata_digest text;
alter table bnx.oauth_client add column created_at timestamptz not null default now();

create table bnx.host_profile_redirect(host_profile text not null, kind text not null check (kind in ('redirect_uri','cimd_client_id')),
  pattern text not null, environment text not null default 'any' check (environment in ('any','non_production')),
  verification text not null check (verification in ('PLATFORM_FACT','UNVERIFIED')), source text not null,
  primary key (host_profile, kind, pattern));
insert into bnx.host_profile_redirect values
 ('claude_remote_mcp', 'redirect_uri', '^https://claude\.ai/api/mcp/auth_callback$', 'any', 'PLATFORM_FACT', 'AIH §4.4 [PF-A3]'),
 ('claude_remote_mcp', 'redirect_uri', '^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/[A-Za-z0-9/_.-]*$', 'non_production', 'PLATFORM_FACT', 'AIH §4.4 loopback (OD-22)'),
 ('chatgpt_plugin_mcp', 'redirect_uri', '^https://chatgpt\.com/connector_platform_oauth_redirect$', 'any', 'PLATFORM_FACT', 'AIH §4.4 [PF-O3]'),
 ('chatgpt_plugin_mcp', 'redirect_uri', '^https://chatgpt\.com/connector/oauth/[A-Za-z0-9_-]{1,128}$', 'any', 'PLATFORM_FACT', 'AIH §4.4 [PF-O3]'),
 ('chatgpt_plugin_mcp', 'cimd_client_id', '^https://chatgpt\.com/oauth/client\.json$', 'any', 'PLATFORM_FACT', 'AIH §4.4 [PF-O3]'),
 ('chatgpt_plugin_mcp', 'cimd_client_id', '^https://chatgpt\.com/oauth/[A-Za-z0-9_-]{1,128}/client\.json$', 'any', 'PLATFORM_FACT', 'AIH §4.4 [PF-O3]');
insert into bnx.table_class values ('host_profile_redirect','M');
insert into bnx.migration_seeded_table values ('bnx.host_profile_redirect', '9009', 'host-profile redirect / CIMD allowlists');

-- ---------- connections ----------
do $$
declare old text;
begin
  old := bnx.check_constraint_of('bnx.ai_connection'::regclass, 'scopes');
  execute $c$alter table bnx.ai_connection add constraint ai_connection_scopes_v2 check (scopes <@ array['finance.read','finance.draft',
    'documents.read','documents.propose','tax.read','tax.propose','reports.read','handoff.read','handoff.prepare','alerts.summary.read',
    'offline_access','read','propose']::text[] and not (scopes && array['read','propose']::text[] and not scopes <@ array['read','propose']::text[]))
    not valid$c$;
  alter table bnx.ai_connection validate constraint ai_connection_scopes_v2;
  execute format('alter table bnx.ai_connection drop constraint %I', old);
end $$;
alter table bnx.ai_connection add column legacy boolean generated always as (scopes <@ array['read','propose']::text[]) stored;
alter table bnx.ai_connection add column refresh_eligible boolean
  generated always as ('offline_access' = any(scopes) and not (scopes <@ array['read','propose']::text[])) stored;
alter table bnx.ai_connection add column resource text;
alter table bnx.ai_connection add column host_profile text;

create table bnx.ai_connection_subset(connection_id uuid not null references bnx.ai_connection,
  kind text not null check (kind in ('account_currency','taxpayer','document_class')), value text not null,
  recorded_at timestamptz not null default now(), primary key (connection_id, kind, value));
create trigger t_append_only before update or delete on bnx.ai_connection_subset for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('ai_connection_subset','F');
-- R1 connections: their account-currency consent becomes subset rows (they stay legacy)
insert into bnx.ai_connection_subset(connection_id, kind, value)
select c.id, 'account_currency', x::text from bnx.ai_connection c cross join lateral unnest(c.account_currency_ids) x;

alter table bnx.ai_connection_token add column rotated_from bytea;
alter table bnx.ai_connection_token add column issued_at timestamptz not null default now();
alter table bnx.ai_connection_token add column resource text;

-- ---------- function -> scope catalog for the MCP channel ----------
create table bnx.function_scope(function_name text primary key, scope text, legacy_read boolean not null default false,
  legacy_propose boolean not null default false, needs_ac_subset boolean not null default false, note text);
insert into bnx.function_scope values
 ('q_balances', 'finance.read', true, false, true, 'fin.balances.as_of'),
 ('q_replay_snapshot', 'reports.read', true, false, true, 'R-BAL/F1 only for legacy read (snapshot_decision)'),
 ('cmd_create_report_snapshot', 'reports.read', true, false, true, 'R-BAL'),
 ('q_whoami', null, true, true, false, 'any connection'),
 ('q_evidence_access', 'documents.read', false, false, false, 'documents need a new consent'),
 ('cmd_register_evidence', 'documents.propose', false, false, false, null),
 ('q_institutions_search', 'finance.read', false, false, false, null),
 ('cmd_propose_institution_candidate', 'finance.draft', false, false, false, null);
insert into bnx.table_class values ('function_scope','M');
insert into bnx.migration_seeded_table values ('bnx.function_scope', '9009+', 'MCP function -> scope catalog');

-- name of the cmd_/q_ function that called require() (PL/pgSQL call stack)
create function bnx.calling_function() returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare ctx text; m text[];
begin
  get diagnostics ctx = pg_context;
  m := regexp_match(ctx, 'function bnx\.((?:cmd|q)_[a-z0-9_]+)\(');
  return m[1];
end $$;

-- require() MODIFY (same signature): R1 tier and role rules unchanged; the MCP scope check uses the function catalog
create or replace function bnx.require(a bnx.actor, p_tier int) returns text
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare role text; fn text; fs record; c record;
begin
  select m.role into role from bnx.member m where m.id = a.member_id and m.state = 'active';
  if role is null then perform bnx.fail('UNAUTHENTICATED', 'P0401'); end if;
  if a.channel = 'mcp' then
    if p_tier >= 2 then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
    fn := bnx.calling_function();
    select * into fs from bnx.function_scope where function_name = fn;
    select * into c from bnx.ai_connection where id = a.connection_id;
    if fs.function_name is null or c.id is null then perform bnx.fail('SCOPE_NOT_CONSENTED', 'P0403', coalesce(fn, 'unknown function')); end if;
    if c.legacy then
      if not ((fs.legacy_read and 'read' = any(c.scopes)) or (fs.legacy_propose and 'propose' = any(c.scopes))) then
        perform bnx.fail('SCOPE_NOT_CONSENTED', 'P0403', fn || ' needs a new consent (legacy connection)');
      end if;
    elsif fs.scope is not null and not (fs.scope = any(c.scopes)) then
      perform bnx.fail('SCOPE_NOT_CONSENTED', 'P0403', fs.scope);
    end if;
    if fs.needs_ac_subset and coalesce(cardinality(c.account_currency_ids), 0) = 0 then
      perform bnx.fail('NOT_AVAILABLE', 'P0404');
    end if;
  end if;
  if p_tier >= 2 and role = 'viewer' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if p_tier >= 3 and role not in ('owner','admin') then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  return role;
end $$;

-- snapshot_decision() MODIFY (same signature): the connection check uses catalog scopes; legacy 'read' replays only
-- R-BAL/F1 snapshots (CROSS-02); everything else as R1 0107
create or replace function bnx.snapshot_decision(a bnx.actor, p_snapshot uuid) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare s bnx.report_snapshot; vis uuid[]; c record;
begin
  select * into s from bnx.report_snapshot where id = p_snapshot;
  if s.id is null or s.projection_actor is distinct from a.member_id then return 'NOT_AVAILABLE'; end if;
  if a.channel = 'mcp' and s.projection_connection_id is not null and s.projection_connection_id <> a.connection_id then
    return 'NOT_AVAILABLE';
  end if;
  if not exists (select 1 from bnx.member m where m.id = a.member_id and m.state = 'active') then return 'ACCESS_REVOKED'; end if;
  if a.channel = 'mcp' then
    select * into c from bnx.ai_connection where id = a.connection_id;
    if c.id is null or c.revoked_at is not null
       or not (case when c.legacy then 'read' = any(c.scopes) else c.scopes && array['reports.read','finance.read'] end) then
      return 'ACCESS_REVOKED';
    end if;
    if c.legacy and s.report_code not in ('R-BAL','F1') then return 'NOT_AVAILABLE'; end if;
  end if;
  vis := array(select bnx.actor_visible_acs(a));
  if s.projection_requested_acs is null or not (s.projection_requested_acs <@ vis)
     or not (s.projection_account_currency_ids <@ vis) then
    return 'ACCESS_REVOKED';
  end if;
  return 'ok';
end $$;

-- ---------- consent ----------
create or replace function bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); c uuid := gen_random_uuid(); code text := bnx.new_secret();
        acs uuid[]; scopes text[]; cl record; tp text[]; dc text[];
begin
  perform bnx.require(a, 2);
  select * into cl from bnx.oauth_client where client_id = cmd->>'client_id';
  if not found or not (coalesce(cmd->>'redirect_uri', '') = any(cl.redirect_uris)) then perform bnx.fail('INVALID_CLIENT', 'P0422'); end if;
  if coalesce(cmd->>'code_challenge','') !~ '^[A-Za-z0-9_-]{43}$' then perform bnx.fail('PKCE_REQUIRED', 'P0422'); end if;
  select coalesce(array_agg(x::uuid), '{}') into acs from jsonb_array_elements_text(coalesce(cmd->'account_currency_ids','[]')) x;
  select coalesce(array_agg(distinct x), '{}') into scopes from jsonb_array_elements_text(coalesce(cmd->'scopes','[]')) x;
  if cardinality(scopes) = 0 or scopes = array['offline_access'] then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'scopes'); end if;
  if scopes && array['read','propose'] then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'legacy scopes read/propose are not granted to new consents'); end if;
  if not (scopes <@ array['finance.read','finance.draft','documents.read','documents.propose','tax.read','tax.propose','reports.read',
                          'handoff.read','handoff.prepare','alerts.summary.read','offline_access']) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'unknown scope'); end if;
  if scopes && array['finance.read','finance.draft','reports.read'] and cardinality(acs) = 0 then
    perform bnx.fail('SUBSET_REQUIRED', 'P0422', 'account_currency_ids'); end if;
  select coalesce(array_agg(x), '{}') into tp from jsonb_array_elements_text(coalesce(cmd->'taxpayer_ids','[]')) x;
  select coalesce(array_agg(x), '{}') into dc from jsonb_array_elements_text(coalesce(cmd->'document_classes','[]')) x;
  if 'tax.read' = any(scopes) and cardinality(tp) = 0 then perform bnx.fail('SUBSET_REQUIRED', 'P0422', 'taxpayer_ids'); end if;
  if 'documents.read' = any(scopes) and cardinality(dc) = 0 then perform bnx.fail('SUBSET_REQUIRED', 'P0422', 'document_classes'); end if;
  if exists (select 1 from unnest(acs) x where x not in (select bnx.actor_visible_acs(a))) then
    perform bnx.fail('NOT_VISIBLE', 'P0403');
  end if;
  insert into bnx.ai_connection(id, member_id, client_id, scopes, account_currency_ids, resource, host_profile)
  values (c, a.member_id, cl.client_id, scopes, acs, cmd->>'resource', cl.host_profile);
  insert into bnx.ai_connection_subset(connection_id, kind, value)
  select c, 'account_currency', x::text from unnest(acs) x
  union all select c, 'taxpayer', x from unnest(tp) x
  union all select c, 'document_class', x from unnest(dc) x;
  insert into bnx.oauth_code values (bnx.h(code), c, cmd->>'code_challenge', cmd->>'redirect_uri', now() + interval '2 minutes', null);
  perform bnx.audit(a, 'approve_ai_connection', jsonb_build_object('connection_id', c, 'client_id', cl.client_id,
          'scopes', scopes, 'account_currency_ids', acs), cmd, null);
  return jsonb_build_object('code', code, 'connection_id', c);
end $$;

create or replace function bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); n int;
begin
  perform bnx.require(a, 2);
  update bnx.ai_connection set revoked_at = coalesce(revoked_at, now())
   where id = (cmd->>'connection_id')::uuid and member_id = a.member_id;
  get diagnostics n = row_count;
  if n = 0 then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  update bnx.ai_connection_token t set revoked_at = coalesce(t.revoked_at, now())
    from bnx.ai_connection c where t.connection_id = c.id and c.id = (cmd->>'connection_id')::uuid and c.member_id = a.member_id;
  perform bnx.audit(a, 'revoke_ai_connection', jsonb_build_object('connection_id', cmd->>'connection_id'), '{}', null);
  return jsonb_build_object('status', 'revoked');
end $$;

-- ---------- token endpoint ----------
create function bnx.oauth_issue(p_conn uuid, p_resource text, p_refresh boolean, p_from bytea) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare tok text := bnx.new_secret(); rt text; r jsonb;
begin
  insert into bnx.ai_connection_token(token_sha256, connection_id, kind, expires_at, revoked_at, resource)
  values (bnx.h(tok), p_conn, 'access', now() + interval '15 minutes', null, p_resource);
  r := jsonb_build_object('access_token', tok, 'token_type', 'Bearer', 'expires_in', 900);
  if p_refresh then
    rt := bnx.new_secret();
    insert into bnx.ai_connection_token(token_sha256, connection_id, kind, expires_at, revoked_at, rotated_from, resource)
    values (bnx.h(rt), p_conn, 'refresh', now() + interval '30 days', null, p_from, p_resource);
    r := r || jsonb_build_object('refresh_token', rt);
  end if;
  return r;
end $$;

create function bnx.oauth_revoke_connection(p_conn uuid, p_whole boolean) returns void
language sql set search_path = pg_catalog, pg_temp as $$
  update bnx.ai_connection_token set revoked_at = coalesce(revoked_at, now()) where connection_id = p_conn;
  update bnx.ai_connection set revoked_at = coalesce(revoked_at, now()) where id = p_conn and p_whole;
$$;

create or replace function bnx.authn_oauth_token(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare r record; verifier text := req->>'code_verifier'; ch text; used record;
begin
  select o.*, c.client_id, c.revoked_at crev, c.refresh_eligible, c.resource conn_resource into r
    from bnx.oauth_code o join bnx.ai_connection c on c.id = o.connection_id
   where o.code_sha256 = bnx.h(coalesce(req->>'code',''));
  if not found or now() > r.expires_at or r.crev is not null
     or r.client_id is distinct from req->>'client_id' or r.redirect_uri is distinct from req->>'redirect_uri'
     or verifier is null or verifier !~ '^[A-Za-z0-9._~-]{43,128}$' then
    perform bnx.fail('INVALID_GRANT', 'P0401');
  end if;
  ch := rtrim(translate(encode(sha256(convert_to(verifier, 'UTF8')), 'base64'), '+/', '-_'), '=');
  if ch <> r.pkce_challenge then perform bnx.fail('INVALID_GRANT', 'P0401'); end if;
  if req ? 'resource' and r.conn_resource is not null and req->>'resource' is distinct from r.conn_resource then
    perform bnx.fail('INVALID_TARGET', 'P0401');
  end if;
  update bnx.oauth_code set used_at = now() where code_sha256 = r.code_sha256 and used_at is null returning * into used;
  if used.code_sha256 is null then
    -- replay (incl. a concurrent second redemption): revoke every token of the connection; returned, not raised, so the
    -- revocation commits (RFC 6749 §4.1.2)
    perform bnx.oauth_revoke_connection(r.connection_id, false);
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'authorization code reuse; tokens revoked');
  end if;
  return bnx.oauth_issue(r.connection_id, coalesce(r.conn_resource, req->>'resource'), r.refresh_eligible, null);
end $$;

create function bnx.authn_oauth_refresh(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare t record;
begin
  select tk.*, c.client_id, c.revoked_at crev, c.refresh_eligible, c.member_id, m.state mstate into t
    from bnx.ai_connection_token tk join bnx.ai_connection c on c.id = tk.connection_id join bnx.member m on m.id = c.member_id
   where tk.token_sha256 = bnx.h(coalesce(req->>'refresh_token', '')) and tk.kind = 'refresh' for update of tk;
  if not found or t.client_id is distinct from req->>'client_id' or not t.refresh_eligible then
    perform bnx.fail('INVALID_GRANT', 'P0401'); end if;
  if t.revoked_at is not null or exists (select 1 from bnx.ai_connection_token x where x.rotated_from = t.token_sha256) then
    -- reuse of a rotated (or revoked) refresh token: the whole connection is revoked; returned so it commits
    perform bnx.oauth_revoke_connection(t.connection_id, true);
    return jsonb_build_object('error', 'invalid_grant', 'error_description', 'refresh token reuse; connection revoked');
  end if;
  if now() > t.expires_at or t.crev is not null or t.mstate <> 'active' then perform bnx.fail('INVALID_GRANT', 'P0401'); end if;
  update bnx.ai_connection_token set revoked_at = now() where token_sha256 = t.token_sha256;
  return bnx.oauth_issue(t.connection_id, t.resource, true, t.token_sha256);
end $$;

-- RFC 7009: always succeeds from the client's point of view
create function bnx.authn_oauth_revoke(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
begin
  update bnx.ai_connection_token t set revoked_at = coalesce(t.revoked_at, now())
    from bnx.ai_connection c where c.id = t.connection_id and t.token_sha256 = bnx.h(coalesce(req->>'token', ''))
     and c.client_id is not distinct from req->>'client_id';
  return '{}'::jsonb;
end $$;

-- RFC 7591 DCR and CIMD: redirect URIs (and a CIMD client id) must match the claimed host profile's allowlist
create function bnx.authn_register_client(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare prof text := req->>'host_profile'; kind text := coalesce(req->>'registration_kind', 'DCR'); cid text; u text; envr text; ex record;
begin
  -- the environment comes from the instance, never from the caller (same-family review finding 9): loopback/dev redirect
  -- patterns only on a synthetic-data instance
  envr := case when (select value #>> '{}' from bnx.household_setting where key = 'data_class') = 'synthetic' then 'non_production'
               else 'production' end;
  if prof is null or not exists (select 1 from bnx.host_profile_redirect where host_profile = prof) then
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'host_profile'); end if;
  if kind not in ('DCR','CIMD') or jsonb_typeof(req->'redirect_uris') <> 'array' or jsonb_array_length(req->'redirect_uris') = 0 then
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'redirect_uris'); end if;
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
      return jsonb_build_object('client_id', cid, 'token_endpoint_auth_method', 'none', 'grant_types', jsonb_build_array('authorization_code','refresh_token'));
    end if;
    perform bnx.fail('INVALID_CLIENT_METADATA', 'P0422', 'client_id already registered');
  end if;
  insert into bnx.oauth_client(client_id, display_name, redirect_uris, registration_kind, host_profile, metadata_digest)
  values (cid, coalesce(left(req->>'client_name', 100), prof), array(select jsonb_array_elements_text(req->'redirect_uris')), kind, prof,
          encode(bnx.h(req::text), 'hex'));
  return jsonb_build_object('client_id', cid, 'token_endpoint_auth_method', 'none', 'grant_types', jsonb_build_array('authorization_code','refresh_token'));
end $$;

select bnx.apply_grants();
