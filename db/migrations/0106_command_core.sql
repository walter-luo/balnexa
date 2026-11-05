-- 0106 AUD-053 Command Core vertical slice (milestone M0 prototype scope). Every member-facing write is ONE call
-- bnx.cmd_<name>(cred jsonb, cmd jsonb) executed by bnx_app; worker steps are bnx.wrk_* executed by bnx_worker;
-- identity steps are bnx.authn_* executed by bnx_authn. All are SECURITY DEFINER, search_path pg_catalog,pg_temp.
-- Implemented: sessions, Google identity binding, OAuth code + PKCE (S256) for AI connections, actor resolution,
-- channel/tier policy, idempotency with request hash, hash-chained audit, outbox, durable work queue, accounts,
-- categories, parties, grants, direct posting, correction, posting-date confirmation, openings, ownership events,
-- evidence registration/assignment/access decisions, import plans (freeze, approve, chunk, seal, fail-closed
-- activation, staleness, suspension), versioned balance query.
-- NOT implemented here (later milestones): statement extraction/matching pipeline, onboarding jobs, reconciliation,
-- reports R01–R34 beyond the balance surface, notifications delivery, executor leases, FX valuation.
set role bnx_definer;

create type bnx.actor as (member_id uuid, connection_id uuid, channel text, session_id uuid, scopes text[]);

insert into bnx.currency values ('CAD',2),('CNY',2),('USD',2),('JPY',0),('EUR',2) on conflict do nothing;

create table bnx.member_identity(iss text not null, sub text not null, member_id uuid not null references bnx.member,
  primary key (iss, sub));
create table bnx.member_session(id uuid primary key, member_id uuid not null references bnx.member,
  token_sha256 bytea not null unique, created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(), absolute_expires_at timestamptz not null, revoked_at timestamptz);
create table bnx.oauth_client(client_id text primary key, display_name text not null, redirect_uris text[] not null);
create table bnx.ai_connection(id uuid primary key, member_id uuid not null references bnx.member,
  client_id text not null references bnx.oauth_client, scopes text[] not null check (scopes <@ array['read','propose']),
  account_currency_ids uuid[] not null, approved_at timestamptz not null default now(), revoked_at timestamptz);
create table bnx.oauth_code(code_sha256 bytea primary key, connection_id uuid not null references bnx.ai_connection,
  pkce_challenge text not null, redirect_uri text not null, expires_at timestamptz not null, used_at timestamptz);
create table bnx.ai_connection_token(token_sha256 bytea primary key, connection_id uuid not null references bnx.ai_connection,
  kind text not null check (kind in ('access','refresh')), expires_at timestamptz not null, revoked_at timestamptz);
create table bnx.idempotency(member_id uuid not null, idem_key text not null, command text not null,
  request_sha256 bytea not null, receipt jsonb not null, created_at timestamptz not null default now(),
  primary key (member_id, idem_key));
create table bnx.audit_event(seq bigint primary key, at timestamptz not null default now(), member_id uuid,
  connection_id uuid, channel text not null, command text not null, subject jsonb not null, payload_sha256 bytea not null,
  ledger_version bigint, prev_hash bytea, hash bytea not null);
create table bnx.outbox(id bigint generated always as identity primary key, topic text not null, payload jsonb not null,
  created_version bigint, state text not null default 'pending' check (state in ('pending','delivered','dead')),
  attempts int not null default 0, next_attempt_at timestamptz not null default now());
create table bnx.journal_correction(original_journal_id uuid primary key references bnx.journal_entry,
  reversal_journal_id uuid not null unique references bnx.journal_entry,
  replacement_journal_id uuid unique references bnx.journal_entry, reason text not null, recorded_version bigint not null);
-- durable work queue (AUD-046): Neon is the authority; KV only carries generation hints
create table bnx.work_item(id bigint generated always as identity primary key, kind text not null, payload jsonb not null,
  state text not null default 'queued' check (state in ('queued','leased','done','dead')),
  enqueued_at timestamptz not null default now(), lease_until timestamptz, attempts int not null default 0);
create table bnx.queue_state(singleton boolean primary key default true check (singleton),
  generation bigint not null, drained_generation bigint not null);
insert into bnx.queue_state values (true, 0, 0);

create trigger t_append_only before update or delete on bnx.audit_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.journal_correction for each row execute function bnx.trg_append_only();
insert into bnx.table_class values ('member_identity','M'),('member_session','M'),('oauth_client','M'),('ai_connection','M'),
 ('oauth_code','M'),('ai_connection_token','M'),('idempotency','M'),('audit_event','E'),('outbox','M'),
 ('journal_correction','F'),('work_item','M'),('queue_state','M');

-- ---------- helpers ----------
create function bnx.fail(p_code text, p_state text, p_detail text default null) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin raise exception '%', p_code using errcode = p_state, detail = coalesce(p_detail, ''); end $$;

create function bnx.h(p text) returns bytea language sql immutable set search_path = pg_catalog, pg_temp as
$$ select sha256(convert_to(p, 'UTF8')) $$;

create function bnx.new_secret() returns text language sql volatile set search_path = pg_catalog, pg_temp as $$
  select translate(encode(decode(replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''), 'hex'),
         'base64'), '+/=', '-_')
$$;

create function bnx.dec(p jsonb, p_field text) returns numeric language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare t text := p->>p_field;
begin
  if t is null or t !~ '^-?[0-9]{1,15}(\.[0-9]{1,4})?$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', p_field || ' must be a decimal string');
  end if;
  return t::numeric;
end $$;

create function bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev bytea; s bigint; ph bytea := bnx.h(coalesce(p_payload,'{}'::jsonb)::text);
begin
  perform pg_advisory_xact_lock(hashtext('bnx.audit'));
  select seq, hash into s, prev from bnx.audit_event order by seq desc limit 1;
  s := coalesce(s, 0) + 1;
  insert into bnx.audit_event(seq, member_id, connection_id, channel, command, subject, payload_sha256, ledger_version, prev_hash, hash)
  values (s, a.member_id, a.connection_id, coalesce(a.channel,'system'), p_command, p_subject, ph, p_version, prev,
          sha256(coalesce(prev, '\x'::bytea) || convert_to(concat_ws('|', s, a.member_id, a.connection_id, coalesce(a.channel,'system'),
                 p_command, p_subject::text, encode(ph,'hex'), p_version), 'UTF8')));
  return s;
end $$;

create function bnx.audit_verify() returns bigint   -- returns 0 when intact, else the first bad seq
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare r record; prev bytea := null; expect bigint := 1;
begin
  for r in select * from bnx.audit_event order by seq loop
    if r.seq <> expect or r.prev_hash is distinct from prev or r.hash <> sha256(coalesce(prev, '\x'::bytea) ||
         convert_to(concat_ws('|', r.seq, r.member_id, r.connection_id, r.channel, r.command, r.subject::text,
                    encode(r.payload_sha256,'hex'), r.ledger_version), 'UTF8')) then
      return r.seq;
    end if;
    prev := r.hash; expect := expect + 1;
  end loop;
  return 0;
end $$;

create function bnx.enqueue(p_kind text, p_payload jsonb) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare wid bigint;
begin
  insert into bnx.work_item(kind, payload) values (p_kind, p_payload) returning work_item.id into wid;
  update bnx.queue_state set generation = generation + 1;
  return wid;
end $$;

-- ---------- identity ----------
create function bnx.resolve_actor(cred jsonb) returns bnx.actor
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare h bytea; r record; a bnx.actor;
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
  return a;
end $$;

-- tier policy: T0 read, T1 propose, T2 post/create, T3 owner-level. MCP never executes T2/T3 (INV-14).
create function bnx.require(a bnx.actor, p_tier int) returns text
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare role text;
begin
  select m.role into role from bnx.member m where m.id = a.member_id and m.state = 'active';
  if role is null then perform bnx.fail('UNAUTHENTICATED', 'P0401'); end if;
  if a.channel = 'mcp' and p_tier >= 2 then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  if a.channel = 'mcp' and p_tier = 1 and not ('propose' = any(a.scopes)) then perform bnx.fail('FORBIDDEN_SCOPE', 'P0403'); end if;
  if a.channel = 'mcp' and p_tier = 0 and not ('read' = any(a.scopes)) then perform bnx.fail('FORBIDDEN_SCOPE', 'P0403'); end if;
  if p_tier >= 2 and role = 'viewer' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if p_tier >= 3 and role not in ('owner','admin') then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  return role;
end $$;

create function bnx.actor_visible_acs(a bnx.actor) returns setof uuid
language sql stable set search_path = pg_catalog, pg_temp as $$
  select v from bnx.visible_account_currency_ids(a.member_id) v
   where a.channel <> 'mcp' or v = any (select unnest(account_currency_ids) from bnx.ai_connection where id = a.connection_id)
$$;

create function bnx.actor_can_post(a bnx.actor, p_ac uuid) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  select a.channel = 'pwa' and exists (select 1 from bnx.account_currency ac
     join bnx.account_grant g on g.account_id = ac.account_id and g.member_id = a.member_id and g.can_post
     join bnx.member m on m.id = a.member_id and m.state = 'active' and m.role <> 'viewer'
    where ac.id = p_ac)
$$;

create function bnx.idem_begin(a bnx.actor, p_command text, p_cmd jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare k text := p_cmd->>'idempotency_key'; req bytea; r record;
begin
  if k is null or length(k) < 8 or length(k) > 80 then perform bnx.fail('IDEMPOTENCY_KEY_REQUIRED', 'P0422'); end if;
  perform pg_advisory_xact_lock(hashtext('idem:' || a.member_id || ':' || k));
  req := bnx.h(p_command || '|' || (p_cmd - 'idempotency_key')::text);
  select * into r from bnx.idempotency where member_id = a.member_id and idem_key = k;
  if found then
    if r.request_sha256 = req and r.command = p_command then return r.receipt || '{"replayed": true}'::jsonb; end if;
    perform bnx.fail('IDEMPOTENCY_CONFLICT', 'P0409');
  end if;
  return null;
end $$;

create function bnx.idem_end(a bnx.actor, p_command text, p_cmd jsonb, p_receipt jsonb) returns jsonb
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  insert into bnx.idempotency(member_id, idem_key, command, request_sha256, receipt)
  values (a.member_id, p_cmd->>'idempotency_key', p_command, bnx.h(p_command || '|' || (p_cmd - 'idempotency_key')::text), p_receipt);
  return p_receipt || '{"replayed": false}'::jsonb;
end $$;

-- installer step (run by bnx_migrator after SET ROLE bnx_definer; never granted to a runtime role)
create function bnx.install_household(p_owner_name text, p_iss text, p_sub text) returns uuid
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare m uuid := gen_random_uuid();
begin
  if exists (select 1 from bnx.member where role = 'owner') then perform bnx.fail('ALREADY_INSTALLED', 'P0409'); end if;
  insert into bnx.member(id, display_name, role, state) values (m, p_owner_name, 'owner', 'active');
  insert into bnx.member_identity values (p_iss, p_sub, m);
  insert into bnx.party(id, kind, display_name, normalized_name, member_id, created_by)
  values (gen_random_uuid(), 'person', p_owner_name, lower(p_owner_name), m, m);
  perform bnx.audit(row(m, null, 'installer', null, null)::bnx.actor, 'install_household', jsonb_build_object('member_id', m), '{}', null);
  return m;
end $$;

create function bnx.authn_begin_session(claims jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare m uuid; tok text := bnx.new_secret(); sid uuid := gen_random_uuid();
begin
  if claims->>'iss' not in ('https://accounts.google.com', 'accounts.google.com')
     or coalesce((claims->>'email_verified')::boolean, false) is not true or coalesce(claims->>'sub','') = '' then
    perform bnx.fail('UNAUTHENTICATED', 'P0401');
  end if;
  select i.member_id into m from bnx.member_identity i join bnx.member mm on mm.id = i.member_id and mm.state = 'active'
   where i.iss = 'https://accounts.google.com' and i.sub = claims->>'sub';
  if m is null then perform bnx.fail('UNAUTHENTICATED', 'P0401'); end if;
  insert into bnx.member_session(id, member_id, token_sha256, absolute_expires_at) values (sid, m, bnx.h(tok), now() + interval '90 days');
  perform bnx.audit(row(m, null, 'auth', sid, null)::bnx.actor, 'authn_begin_session', jsonb_build_object('session_id', sid), '{}', null);
  return jsonb_build_object('session_token', tok, 'member_id', m, 'session_id', sid);
end $$;

create function bnx.cmd_revoke_session(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred);
begin
  perform bnx.require(a, 0);
  update bnx.member_session set revoked_at = now() where id = a.session_id;
  perform bnx.audit(a, 'revoke_session', jsonb_build_object('session_id', a.session_id), '{}', null);
  return jsonb_build_object('status', 'revoked');
end $$;

-- OAuth 2.1 authorization code + PKCE (S256) for AI connections. Consent runs under a PWA session (T2; the owner
-- must hold view rights on every exposed account-currency).
create function bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); c uuid := gen_random_uuid(); code text := bnx.new_secret();
        acs uuid[]; scopes text[];
begin
  perform bnx.require(a, 2);
  if not exists (select 1 from bnx.oauth_client where client_id = cmd->>'client_id'
                  and cmd->>'redirect_uri' = any(redirect_uris)) then perform bnx.fail('INVALID_CLIENT', 'P0422'); end if;
  if coalesce(cmd->>'code_challenge','') !~ '^[A-Za-z0-9_-]{43}$' then perform bnx.fail('PKCE_REQUIRED', 'P0422'); end if;
  select coalesce(array_agg(x::uuid), '{}') into acs from jsonb_array_elements_text(coalesce(cmd->'account_currency_ids','[]')) x;
  select coalesce(array_agg(x), '{}') into scopes from jsonb_array_elements_text(coalesce(cmd->'scopes','["read"]')) x;
  if exists (select 1 from unnest(acs) x where x not in (select bnx.actor_visible_acs(a))) then
    perform bnx.fail('NOT_VISIBLE', 'P0403');
  end if;
  insert into bnx.ai_connection(id, member_id, client_id, scopes, account_currency_ids) values (c, a.member_id, cmd->>'client_id', scopes, acs);
  insert into bnx.oauth_code values (bnx.h(code), c, cmd->>'code_challenge', cmd->>'redirect_uri', now() + interval '2 minutes', null);
  perform bnx.audit(a, 'approve_ai_connection', jsonb_build_object('connection_id', c, 'client_id', cmd->>'client_id',
          'scopes', scopes, 'account_currency_ids', acs), cmd, null);
  return jsonb_build_object('code', code, 'connection_id', c);
end $$;

create function bnx.authn_oauth_token(req jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare r record; tok text := bnx.new_secret(); verifier text := req->>'code_verifier'; ch text;
begin
  select o.*, c.client_id, c.revoked_at crev into r from bnx.oauth_code o join bnx.ai_connection c on c.id = o.connection_id
   where o.code_sha256 = bnx.h(coalesce(req->>'code',''));
  if not found or r.used_at is not null or now() > r.expires_at or r.crev is not null
     or r.client_id <> req->>'client_id' or r.redirect_uri <> req->>'redirect_uri'
     or verifier is null or verifier !~ '^[A-Za-z0-9._~-]{43,128}$' then
    perform bnx.fail('INVALID_GRANT', 'P0401');
  end if;
  ch := rtrim(translate(encode(sha256(convert_to(verifier, 'UTF8')), 'base64'), '+/', '-_'), '=');
  if ch <> r.pkce_challenge then perform bnx.fail('INVALID_GRANT', 'P0401'); end if;
  update bnx.oauth_code set used_at = now() where code_sha256 = r.code_sha256;
  insert into bnx.ai_connection_token values (bnx.h(tok), r.connection_id, 'access', now() + interval '15 minutes', null);
  return jsonb_build_object('access_token', tok, 'token_type', 'Bearer', 'expires_in', 900);
end $$;

create function bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred);
begin
  perform bnx.require(a, 2);
  update bnx.ai_connection set revoked_at = now() where id = (cmd->>'connection_id')::uuid and member_id = a.member_id;
  update bnx.ai_connection_token set revoked_at = now() where connection_id = (cmd->>'connection_id')::uuid;
  perform bnx.audit(a, 'revoke_ai_connection', jsonb_build_object('connection_id', cmd->>'connection_id'), '{}', null);
  return jsonb_build_object('status', 'revoked');
end $$;

-- ---------- members, parties, grants ----------
create function bnx.cmd_invite_member(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); m uuid := gen_random_uuid(); rc jsonb;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'invite_member', cmd); if rc is not null then return rc; end if;
  if cmd->>'role' not in ('admin','member','viewer') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'role'); end if;
  insert into bnx.member(id, display_name, role, state) values (m, cmd->>'display_name', cmd->>'role', 'active');
  insert into bnx.member_identity values ('https://accounts.google.com', cmd->>'google_sub', m);
  insert into bnx.party(id, kind, display_name, normalized_name, member_id, created_by)
  values (gen_random_uuid(), 'person', cmd->>'display_name', lower(cmd->>'display_name'), m, a.member_id);
  perform bnx.audit(a, 'invite_member', jsonb_build_object('member_id', m, 'role', cmd->>'role'), cmd - 'google_sub', null);
  return bnx.idem_end(a, 'invite_member', cmd, jsonb_build_object('member_id', m));
end $$;

create function bnx.cmd_set_member_state(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'set_member_state', cmd); if rc is not null then return rc; end if;
  if cmd->>'state' not in ('active','suspended') or (cmd->>'member_id')::uuid = a.member_id then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'state'); end if;
  update bnx.member set state = cmd->>'state' where id = (cmd->>'member_id')::uuid and role <> 'owner';
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if cmd->>'state' = 'suspended' then
    update bnx.member_session set revoked_at = now() where member_id = (cmd->>'member_id')::uuid and revoked_at is null;
    update bnx.ai_connection set revoked_at = now() where member_id = (cmd->>'member_id')::uuid and revoked_at is null;
  end if;
  perform bnx.audit(a, 'set_member_state', jsonb_build_object('member_id', cmd->>'member_id', 'state', cmd->>'state'), cmd, null);
  return bnx.idem_end(a, 'set_member_state', cmd, jsonb_build_object('status', cmd->>'state'));
end $$;

create function bnx.cmd_create_party(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); p uuid := gen_random_uuid(); rc jsonb;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'create_party', cmd); if rc is not null then return rc; end if;
  if cmd->>'kind' not in ('person','organization') or coalesce(cmd->>'display_name','') = '' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'party'); end if;
  insert into bnx.party(id, kind, display_name, normalized_name, created_by)
  values (p, cmd->>'kind', cmd->>'display_name', lower(cmd->>'display_name'), a.member_id);
  perform bnx.audit(a, 'create_party', jsonb_build_object('party_id', p), cmd, null);
  return bnx.idem_end(a, 'create_party', cmd, jsonb_build_object('party_id', p));
end $$;

create function bnx.cmd_set_grant(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v boolean := coalesce((cmd->>'can_view')::boolean, false);
        p boolean := coalesce((cmd->>'can_post')::boolean, false); role text; acc record;
begin
  role := bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'set_grant', cmd); if rc is not null then return rc; end if;
  if p and not v then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'can_post requires can_view'); end if;
  select * into acc from bnx.account where id = (cmd->>'account_id')::uuid;
  -- household accounts: owner/admin (T3). Private accounts: only their creator; owner/admin cannot grant themselves
  -- access to another member's private account (that is an audited T3 evidence/audit path, never a silent grant).
  if acc.id is null or (acc.visibility = 'private' and acc.created_by <> a.member_id)
     or not exists (select 1 from bnx.member where id = (cmd->>'member_id')::uuid) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if acc.visibility = 'household' and role not in ('owner','admin') then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  if v then
    insert into bnx.account_grant(member_id, account_id, can_view, can_post, granted_by)
    values ((cmd->>'member_id')::uuid, (cmd->>'account_id')::uuid, v, p, a.member_id)
    on conflict (member_id, account_id) do update set can_view = excluded.can_view, can_post = excluded.can_post,
       granted_by = excluded.granted_by, granted_at = now();
  else
    delete from bnx.account_grant where member_id = (cmd->>'member_id')::uuid and account_id = (cmd->>'account_id')::uuid;
  end if;
  perform bnx.audit(a, 'set_grant', jsonb_build_object('member_id', cmd->>'member_id', 'account_id', cmd->>'account_id',
          'can_view', v, 'can_post', p), cmd, null);
  return bnx.idem_end(a, 'set_grant', cmd, jsonb_build_object('can_view', v, 'can_post', p));
end $$;

-- ---------- accounts and categories ----------
create function bnx.system_ledger_account(p_kind text, p_currency char(3), p_name text) returns uuid
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare lid uuid;
begin
  select la.id into lid from bnx.ledger_account la where la.kind = p_kind and la.currency = p_currency and la.name = p_name;
  if lid is null then
    lid := gen_random_uuid();
    insert into bnx.ledger_account values (lid, p_kind, p_currency, p_name);
  end if;
  return lid;
end $$;

create function bnx.cmd_create_account(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; acc uuid := gen_random_uuid(); inst uuid; cur text;
        la uuid; acid uuid; res jsonb := '[]'; v bigint; kind text := cmd->>'kind'; lkind text; vis text := coalesce(cmd->>'visibility','household');
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'create_account', cmd); if rc is not null then return rc; end if;
  if kind not in ('bank_deposit','cash','e_wallet','credit_card','investment','loan_payable','loan_receivable','other_asset')
     or vis not in ('household','private') or coalesce(cmd->>'label','') = ''
     or jsonb_typeof(cmd->'currencies') <> 'array' or jsonb_array_length(cmd->'currencies') = 0 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'account');
  end if;
  if kind not in ('cash','other_asset') then
    if coalesce(cmd->>'institution','') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'institution required'); end if;
    select id into inst from bnx.institution where name_en = cmd->>'institution';
    if inst is null then inst := gen_random_uuid(); insert into bnx.institution(id, name_en, created_by) values (inst, cmd->>'institution', a.member_id); end if;
  end if;
  v := bnx.next_version();
  insert into bnx.account(id, kind, institution_id, label, reference_kind, visibility, timezone, origin, state, created_by)
  values (acc, kind, inst, cmd->>'label', 'managed', vis, 'America/Toronto', 'manual', 'active', a.member_id);
  lkind := case when kind in ('credit_card','loan_payable') then 'liability' else 'asset' end;
  for cur in select jsonb_array_elements_text(cmd->'currencies') loop
    if not exists (select 1 from bnx.currency where code = cur) then perform bnx.fail('UNKNOWN_CURRENCY', 'P0422', cur); end if;
    la := gen_random_uuid(); acid := gen_random_uuid();
    insert into bnx.ledger_account values (la, lkind, cur, (cmd->>'label') || ' ' || cur);
    insert into bnx.account_currency values (acid, acc, cur, la);
    res := res || jsonb_build_object('account_currency_id', acid, 'currency', cur, 'ledger_account_id', la);
  end loop;
  insert into bnx.account_grant(member_id, account_id, can_view, can_post, granted_by) values (a.member_id, acc, true, true, a.member_id);
  if vis = 'household' then
    insert into bnx.account_grant(member_id, account_id, can_view, can_post, granted_by)
    select m.id, acc, true, false, a.member_id from bnx.member m where m.state = 'active' and m.id <> a.member_id;
  end if;
  insert into bnx.account_event values (acc, 1, 'created', jsonb_build_object('label', cmd->>'label', 'visibility', vis), v, a.member_id, now());
  perform bnx.audit(a, 'create_account', jsonb_build_object('account_id', acc), cmd, v);
  return bnx.idem_end(a, 'create_account', cmd, jsonb_build_object('account_id', acc, 'account_currencies', res, 'ledger_version', v));
end $$;

create function bnx.cmd_create_category(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; la uuid := gen_random_uuid(); v bigint;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'create_category', cmd); if rc is not null then return rc; end if;
  if cmd->>'kind' not in ('income','expense') or not exists (select 1 from bnx.currency where code = cmd->>'currency')
     or coalesce(cmd->>'name_en','') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'category'); end if;
  v := bnx.next_version();
  insert into bnx.ledger_account values (la, cmd->>'kind', cmd->>'currency', cmd->>'name_en');
  insert into bnx.category_version values (la, v, null, cmd->>'name_en', coalesce(cmd->>'name_zh', cmd->>'name_en'), 'active');
  perform bnx.audit(a, 'create_category', jsonb_build_object('ledger_account_id', la), cmd, v);
  return bnx.idem_end(a, 'create_category', cmd, jsonb_build_object('ledger_account_id', la, 'ledger_version', v));
end $$;

-- ---------- posting ----------
-- Lines: [{ledger_account_id, currency, amount}] (decimal strings). A line on an account-currency needs can_post;
-- other lines may only hit income, expense, fx_trading or clearing ledger accounts. Equity is reserved for openings.
create function bnx.insert_journal(a bnx.actor, p_v bigint, p_batch uuid, p_type text, p_tdate date, p_pdate date,
  p_desc text, p_lines jsonb, p_orig_amount numeric, p_orig_currency text, p_rate numeric, p_plan uuid) returns uuid
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare j uuid := gen_random_uuid(); l jsonb; la record; n_ac int := 0; ac uuid; anc bnx.opening_anchor_version;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 or jsonb_array_length(p_lines) > 200 then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'lines');
  end if;
  insert into bnx.journal_entry(id, economic_type, transaction_date, posting_date, posting_date_status, description,
    original_amount, original_currency, settled_rate, ledger_version, posting_batch_id, approval_plan_id, origin_channel,
    created_by_member, confirmed_by_member, created_via_connection)
  values (j, p_type::bnx.economic_type, p_tdate, coalesce(p_pdate, p_tdate), 'estimated', p_desc, p_orig_amount, p_orig_currency,
    p_rate, case when p_batch is null then p_v end, p_batch, p_plan, case when p_batch is null then 'pwa' else 'plan' end,
    a.member_id, a.member_id, a.connection_id);
  for l in select * from jsonb_array_elements(p_lines) loop
    select la2.id, la2.kind, la2.currency, ac2.id acid into la
      from bnx.ledger_account la2 left join bnx.account_currency ac2 on ac2.ledger_account_id = la2.id
     where la2.id = (l->>'ledger_account_id')::uuid;
    if not found then perform bnx.fail('LEDGER_ACCOUNT_NOT_FOUND', 'P0422'); end if;
    if la.acid is not null then
      if p_batch is null and not bnx.actor_can_post(a, la.acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
      anc := bnx.anchor_at(la.acid, 9223372036854775807);
      if anc.id is not null and coalesce(p_pdate, p_tdate) < anc.anchor_date and p_type <> 'opening_balance' then
        perform bnx.fail('POSTINGS_BEFORE_ANCHOR', 'P0422');
      end if;
      n_ac := n_ac + 1;
    elsif la.kind not in ('income','expense','fx_trading','clearing') and p_type <> 'opening_balance' then
      perform bnx.fail('LEDGER_ACCOUNT_NOT_POSTABLE', 'P0403');
    end if;
    insert into bnx.journal_line(id, journal_id, ledger_account_id, currency, amount)
    values (gen_random_uuid(), j, la.id, l->>'currency', bnx.dec(l, 'amount'));
  end loop;
  if n_ac = 0 then perform bnx.fail('NO_ACCOUNT_LINE', 'P0422'); end if;
  perform bnx.assert_journal_complete(j);
  return j;
end $$;

create function bnx.cmd_post_transaction(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; j uuid;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'post_transaction', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'economic_type','') in ('opening_balance','correction_reversal','correction_replacement','') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'economic_type'); end if;
  v := bnx.next_version();
  j := bnx.insert_journal(a, v, null, cmd->>'economic_type', (cmd->>'transaction_date')::date, (cmd->>'posting_date')::date,
         cmd->>'description', cmd->'lines', case when cmd ? 'original_amount' then bnx.dec(cmd, 'original_amount') end,
         cmd->>'original_currency', case when cmd ? 'settled_rate' then (cmd->>'settled_rate')::numeric end, null);
  perform bnx.audit(a, 'post_transaction', jsonb_build_object('journal_id', j), cmd, v);
  insert into bnx.outbox(topic, payload, created_version) values ('journal.posted', jsonb_build_object('journal_id', j), v);
  return bnx.idem_end(a, 'post_transaction', cmd, jsonb_build_object('journal_id', j, 'ledger_version', v, 'status', 'committed'));
end $$;

create function bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; o record; rj uuid; nj uuid; lines jsonb; ac uuid;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'correct_transaction', cmd); if rc is not null then return rc; end if;
  select je.* into o from bnx.journal_entry je join bnx.visible_at(9223372036854775807) vv on vv.journal_id = je.id
   where je.id = (cmd->>'journal_id')::uuid;
  if not found or o.economic_type in ('correction_reversal','opening_balance') then perform bnx.fail('NOT_CORRECTABLE', 'P0422'); end if;
  for ac in select ac2.id from bnx.journal_line jl join bnx.account_currency ac2 on ac2.ledger_account_id = jl.ledger_account_id
             where jl.journal_id = o.id loop
    if not bnx.actor_can_post(a, ac) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  end loop;
  if exists (select 1 from bnx.journal_correction where original_journal_id = o.id) then perform bnx.fail('ALREADY_CORRECTED', 'P0409'); end if;
  v := bnx.next_version();
  select jsonb_agg(jsonb_build_object('ledger_account_id', ledger_account_id, 'currency', currency, 'amount', (-amount)::text))
    into lines from bnx.journal_line where journal_id = o.id;
  rj := bnx.insert_journal(a, v, null, 'correction_reversal', o.transaction_date, bnx.effective_posting_date(o.id, v),
          'Reversal: ' || o.description, lines, null, null, null, null);
  if cmd ? 'replacement' then
    nj := bnx.insert_journal(a, v, null, 'correction_replacement', (cmd->'replacement'->>'transaction_date')::date,
            (cmd->'replacement'->>'posting_date')::date, cmd->'replacement'->>'description', cmd->'replacement'->'lines',
            null, null, null, null);
  end if;
  insert into bnx.journal_correction values (o.id, rj, nj, coalesce(cmd->>'reason','correction'), v);
  perform bnx.audit(a, 'correct_transaction', jsonb_build_object('original', o.id, 'reversal', rj, 'replacement', nj), cmd, v);
  return bnx.idem_end(a, 'correct_transaction', cmd, jsonb_build_object('reversal_journal_id', rj, 'replacement_journal_id', nj, 'ledger_version', v));
end $$;

create function bnx.cmd_confirm_posting_date(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; j uuid := (cmd->>'journal_id')::uuid; s int; ac uuid;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'confirm_posting_date', cmd); if rc is not null then return rc; end if;
  if not exists (select 1 from bnx.visible_at(9223372036854775807) where journal_id = j) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  for ac in select ac2.id from bnx.journal_line jl join bnx.account_currency ac2 on ac2.ledger_account_id = jl.ledger_account_id
             where jl.journal_id = j loop
    if not bnx.actor_can_post(a, ac) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  end loop;
  v := bnx.next_version();
  select coalesce(max(seq), 0) + 1 into s from bnx.posting_date_confirmation where journal_id = j;
  insert into bnx.posting_date_confirmation(journal_id, seq, confirmed_posting_date, source, recorded_version, actor)
  values (j, s, (cmd->>'posting_date')::date, 'member', v, a.member_id);
  perform bnx.audit(a, 'confirm_posting_date', jsonb_build_object('journal_id', j), cmd, v);
  return bnx.idem_end(a, 'confirm_posting_date', cmd, jsonb_build_object('ledger_version', v));
end $$;

-- opening anchor: install or revise (T3 when revising). Reverses the previous opening journal and posts the new one
-- at ONE version (INV-29). Later-date revisions that would exclude postings are refused (INV-11).
create function bnx.cmd_set_opening(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; acid uuid := (cmd->>'account_currency_id')::uuid;
        ac record; prev bnx.opening_anchor_version; amt numeric; d date := (cmd->>'anchor_date')::date; eq uuid; j uuid; rj uuid;
begin
  select ac2.*, la.kind lkind into ac from bnx.account_currency ac2 join bnx.ledger_account la on la.id = ac2.ledger_account_id where ac2.id = acid;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  prev := bnx.anchor_at(acid, 9223372036854775807);
  perform bnx.require(a, case when prev.id is null then 2 else 3 end);
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'set_opening', cmd); if rc is not null then return rc; end if;
  amt := bnx.dec(cmd, 'amount');
  if exists (select 1 from bnx.visible_at(9223372036854775807) vv join bnx.journal_entry je on je.id = vv.journal_id
              join bnx.journal_line jl on jl.journal_id = je.id
             where jl.ledger_account_id = ac.ledger_account_id and je.economic_type not in ('opening_balance','correction_reversal')
               and bnx.effective_posting_date(je.id, 9223372036854775807) < d) then
    perform bnx.fail('ANCHOR_WOULD_EXCLUDE_POSTINGS', 'P0422');
  end if;
  v := bnx.next_version();
  eq := bnx.system_ledger_account('equity', ac.currency, 'Opening Balances');
  if prev.journal_id is not null then
    rj := bnx.insert_journal(a, v, null, 'opening_balance', prev.anchor_date, prev.anchor_date, 'Reverse opening',
      jsonb_build_array(jsonb_build_object('ledger_account_id', ac.ledger_account_id, 'currency', ac.currency, 'amount', (-prev.amount)::text),
                        jsonb_build_object('ledger_account_id', eq, 'currency', ac.currency, 'amount', prev.amount::text)), null, null, null, null);
  end if;
  if amt <> 0 then
    j := bnx.insert_journal(a, v, null, 'opening_balance', d, d, 'Opening',
      jsonb_build_array(jsonb_build_object('ledger_account_id', ac.ledger_account_id, 'currency', ac.currency, 'amount', amt::text),
                        jsonb_build_object('ledger_account_id', eq, 'currency', ac.currency, 'amount', (-amt)::text)), null, null, null, null);
  end if;
  insert into bnx.opening_anchor_version(id, account_currency_id, anchor_date, amount, journal_id, reversed_journal_id, source,
    certainty, revision, reason, valid_from_version, recorded_by)
  values (gen_random_uuid(), acid, d, amt, j, rj, 'manual_declaration', coalesce(cmd->>'certainty','declared'),
          coalesce(prev.revision, 0) + 1, coalesce(cmd->>'reason','opening'), v, a.member_id);
  perform bnx.audit(a, 'set_opening', jsonb_build_object('account_currency_id', acid, 'revision', coalesce(prev.revision, 0) + 1), cmd, v);
  return bnx.idem_end(a, 'set_opening', cmd, jsonb_build_object('ledger_version', v, 'journal_id', j));
end $$;

-- ownership facts (T3). All events of one command share one version; ties and > 100 % are rejected (AUD-052).
create function bnx.cmd_record_ownership(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint; e jsonb;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'record_ownership', cmd); if rc is not null then return rc; end if;
  if not exists (select 1 from bnx.account where id = (cmd->>'account_id')::uuid) then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  v := bnx.next_version();
  for e in select * from jsonb_array_elements(cmd->'events') loop
    begin
      insert into bnx.account_ownership_event(id, account_id, party_id, kind, event, share, effective_from, evidence_kind,
        recorded_version, actor)
      values (gen_random_uuid(), (cmd->>'account_id')::uuid, (e->>'party_id')::uuid, e->>'kind', e->>'event',
              case when e->>'event' = 'set' then bnx.dec(e, 'share') end, (e->>'effective_from')::date,
              coalesce(cmd->>'evidence_kind', 'owner_confirmed'), v, a.member_id);
    exception when unique_violation then perform bnx.fail('OWNERSHIP_TIE', 'P0409');
    end;
  end loop;
  set constraints all immediate;   -- surface OWNERSHIP_OVER_100 inside the command
  perform bnx.audit(a, 'record_ownership', jsonb_build_object('account_id', cmd->>'account_id'), cmd, v);
  return bnx.idem_end(a, 'record_ownership', cmd, jsonb_build_object('ledger_version', v));
end $$;

create function bnx.cmd_set_account_scope(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; v bigint;
begin
  perform bnx.require(a, 3);
  rc := bnx.idem_begin(a, 'set_account_scope', cmd); if rc is not null then return rc; end if;
  v := bnx.next_version();
  begin
    insert into bnx.account_scope_event(id, account_id, ownership_scope, effective_from, recorded_version, actor)
    values (gen_random_uuid(), (cmd->>'account_id')::uuid, cmd->>'ownership_scope', (cmd->>'effective_from')::date, v, a.member_id);
  exception when unique_violation then perform bnx.fail('SCOPE_TIE', 'P0409');
  end;
  perform bnx.audit(a, 'set_account_scope', jsonb_build_object('account_id', cmd->>'account_id'), cmd, v);
  return bnx.idem_end(a, 'set_account_scope', cmd, jsonb_build_object('ledger_version', v));
end $$;

-- ---------- evidence (registration and access decisions; bytes and presigning live in the Worker/R2) ----------
create function bnx.cmd_register_evidence(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; o uuid := gen_random_uuid(); f uuid := gen_random_uuid();
begin
  perform bnx.require(a, 1);
  if a.channel = 'mcp' then perform bnx.fail('FORBIDDEN_CHANNEL', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'register_evidence', cmd); if rc is not null then return rc; end if;
  if coalesce(cmd->>'size','') !~ '^[0-9]{1,9}$' or (cmd->>'size')::bigint not between 1 and 52428800
     or coalesce(cmd->>'sha256_declared','') !~ '^[0-9a-f]{64}$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'size 1..50 MiB and sha256_declared hex required'); end if;
  insert into bnx.evidence_object(id, r2_key, size_bytes, integrity_state) values (o, 'orig/' || o, (cmd->>'size')::bigint, 'unverified');
  insert into bnx.evidence_file(id, evidence_object_id, sha256_declared, size_declared, mime, original_name, acquired_via, acquired_by, storage_state)
  values (f, o, decode(cmd->>'sha256_declared', 'hex'), (cmd->>'size')::bigint, coalesce(cmd->>'mime','application/pdf'),
          cmd->>'name', 'pwa_upload', a.member_id, 'upload_pending');
  perform bnx.audit(a, 'register_evidence', jsonb_build_object('evidence_file_id', f), cmd - 'name', null);
  -- uniform response: never depends on other members' evidence (INV-41)
  return bnx.idem_end(a, 'register_evidence', cmd, jsonb_build_object('evidence_file_id', f));
end $$;

create function bnx.cmd_assign_evidence(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'assign_evidence', cmd); if rc is not null then return rc; end if;
  if not bnx.actor_can_post(a, (cmd->>'account_currency_id')::uuid)
     or bnx.can_read_evidence(a.member_id, (cmd->>'evidence_file_id')::uuid) = 'denied' then
    perform bnx.fail('NOT_AVAILABLE', 'P0404');
  end if;
  update bnx.evidence_file set assigned_account_currency_id = (cmd->>'account_currency_id')::uuid where id = (cmd->>'evidence_file_id')::uuid;
  perform bnx.audit(a, 'assign_evidence', jsonb_build_object('evidence_file_id', cmd->>'evidence_file_id'), cmd, null);
  return bnx.idem_end(a, 'assign_evidence', cmd, jsonb_build_object('status', 'assigned'));
end $$;

-- decision for a new URL or stream request; logged; 'denied' is identical for unknown and forbidden files
create function bnx.q_evidence_access(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); d text; f uuid;
begin
  perform bnx.require(a, 0);
  begin f := (q->>'evidence_file_id')::uuid; exception when others then f := null; end;
  d := case when a.channel = 'mcp' or f is null then 'denied' else bnx.can_read_evidence(a.member_id, f) end;
  insert into bnx.evidence_access_log(evidence_file_id, member_id, purpose, decision, url_expires_at)
  values (coalesce(f, '00000000-0000-0000-0000-000000000000'), a.member_id, coalesce(q->>'purpose','view'),
          case when d = 'denied' then 'denied' else 'granted' end, case when d <> 'denied' then now() + interval '60 seconds' end);
  return jsonb_build_object('decision', case when d = 'denied' then 'denied' else 'granted' end,
                            'url_ttl_seconds', case when d = 'denied' then 0 else 60 end);
end $$;

-- ---------- queries ----------
create function bnx.q_balances(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); vnow bigint; v bigint; d date := coalesce((q->>'as_of')::date, current_date); res jsonb;
begin
  perform bnx.require(a, 0);
  select version into vnow from bnx.ledger_state;
  v := coalesce((q->>'ledger_version')::bigint, vnow);
  if v > vnow or v < 0 then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('account_currency_id', x.id, 'currency', ac.currency, 'status', (b).status,
           'amount', (b).amount::text) order by x.id), '[]') into res
    from (select id from bnx.actor_visible_acs(a) id
           where not (q ? 'account_currency_ids') or id::text in (select jsonb_array_elements_text(q->'account_currency_ids'))) x
    join bnx.account_currency ac on ac.id = x.id
    cross join lateral (select bnx.balance_at(x.id, d, v) b) bb;
  return jsonb_build_object('ledger_version', v, 'as_of', d, 'balances', res);
end $$;

-- ---------- import plans (freeze → approve → chunk/seal → fail-closed activation) ----------
create function bnx.plan_scope(p_plan uuid) returns table(acid uuid, la uuid, during daterange)
language sql stable set search_path = pg_catalog, pg_temp as $$
  select c.account_currency_id, ac.ledger_account_id, c.during from bnx.posting_scope_claim c
    join bnx.account_currency ac on ac.id = c.account_currency_id where c.plan_id = p_plan
$$;

create function bnx.scope_digest(p_la uuid, p_acid uuid, p_during daterange, p_v bigint) returns bytea
language sql stable set search_path = pg_catalog, pg_temp as $$
  select sha256(convert_to(coalesce((select string_agg(vv.journal_id::text || ':' || jl.amount::text || ':' ||
           bnx.effective_posting_date(vv.journal_id, p_v)::text, ',' order by vv.journal_id, jl.id)
      from bnx.visible_at(p_v) vv join bnx.journal_line jl on jl.journal_id = vv.journal_id
     where jl.ledger_account_id = p_la and bnx.effective_posting_date(vv.journal_id, p_v) <@ p_during), '') || '|anchor:' ||
     coalesce((bnx.anchor_at(p_acid, p_v)).id::text, 'none'), 'UTF8'))
$$;

-- any reporting-affecting fact in the plan's scope recorded after p_since (moves into or out of the range included)
create function bnx.scope_delta_exists(p_plan uuid, p_since bigint) returns boolean
language sql stable set search_path = pg_catalog, pg_temp as $$
  select exists (
    select 1 from bnx.plan_scope(p_plan) s
     where exists (select 1 from bnx.visible_at(9223372036854775807) vv join bnx.journal_line jl on jl.journal_id = vv.journal_id
                    where vv.visible_version > p_since and jl.ledger_account_id = s.la
                      and (bnx.effective_posting_date(vv.journal_id, 9223372036854775807) <@ s.during))
        or exists (select 1 from bnx.posting_date_confirmation c join bnx.journal_line jl on jl.journal_id = c.journal_id
                    where c.recorded_version > p_since and jl.ledger_account_id = s.la
                      and (c.confirmed_posting_date <@ s.during or bnx.effective_posting_date(c.journal_id, p_since) <@ s.during))
        or exists (select 1 from bnx.opening_anchor_version o where o.account_currency_id = s.acid and o.valid_from_version > p_since))
$$;

create function bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; p uuid := gen_random_uuid(); acid uuid := (cmd->>'account_currency_id')::uuid;
        ac record; it jsonb; i int := 0; vnow bigint; rng daterange; ph bytea; sd bytea; cla record;
begin
  perform bnx.require(a, 2);
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'create_import_plan', cmd); if rc is not null then return rc; end if;
  select * into ac from bnx.account_currency where id = acid;
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));            -- freeze against a stable version
  select version into vnow from bnx.ledger_state;
  rng := daterange((cmd->>'date_from')::date - 10, (cmd->>'date_to')::date + 11, '[)');
  for it in select * from jsonb_array_elements(cmd->'items') loop
    select * into cla from bnx.ledger_account where id = (it->>'counter_ledger_account_id')::uuid;
    if not found or cla.kind not in ('income','expense','clearing') or cla.currency <> ac.currency then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'counter ledger account');
    end if;
    perform bnx.assert_scale(bnx.dec(it, 'amount'), ac.currency, 'plan item');
    if (it->>'transaction_date')::date not between (cmd->>'date_from')::date and (cmd->>'date_to')::date then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'item date outside plan range'); end if;
  end loop;
  ph := bnx.h(acid::text || '|' || rng::text || '|' || (cmd->'items')::text);
  sd := bnx.scope_digest(ac.ledger_account_id, acid, rng, vnow);
  insert into bnx.posting_plan(id, kind, scope, item_count, control_totals, plan_hash, state, frozen_at_version, last_validated_version, scope_digest)
  values (p, 'import', jsonb_build_object('account_currency_id', acid, 'range', rng::text), jsonb_array_length(cmd->'items'),
          jsonb_build_object('sum', (select sum((x->>'amount')::numeric) from jsonb_array_elements(cmd->'items') x)::text),
          ph, 'frozen', vnow, vnow, sd);
  for it in select * from jsonb_array_elements(cmd->'items') loop
    i := i + 1;
    insert into bnx.posting_plan_item values (p, i, 'new_journal', '{}', it, bnx.h(it::text), 1, null);
  end loop;
  begin
    insert into bnx.posting_scope_claim values (p, acid, rng, 'held', vnow, null);
  exception when exclusion_violation then perform bnx.fail('SCOPE_CLAIM_CONFLICT', 'P0409');
  end;
  insert into bnx.plan_event values (p, 1, 'frozen', vnow, vnow, null, null, a.member_id, now());
  perform bnx.audit(a, 'create_import_plan', jsonb_build_object('plan_id', p), cmd, null);
  return bnx.idem_end(a, 'create_import_plan', cmd, jsonb_build_object('plan_id', p, 'plan_hash', encode(ph,'hex'),
         'scope_digest', encode(sd,'hex'), 'frozen_at_version', vnow));
end $$;

create function bnx.cmd_approve_plan(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; pl record; s int;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'approve_plan', cmd); if rc is not null then return rc; end if;
  select * into pl from bnx.posting_plan where id = (cmd->>'plan_id')::uuid for update;
  if not found or pl.state <> 'frozen' then perform bnx.fail('PLAN_NOT_APPROVABLE', 'P0409'); end if;
  if not bnx.actor_can_post(a, (pl.scope->>'account_currency_id')::uuid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if encode(pl.plan_hash,'hex') <> cmd->>'plan_hash' or encode(pl.scope_digest,'hex') <> cmd->>'scope_digest' then
    perform bnx.fail('PLAN_DIGEST_MISMATCH', 'P0409'); end if;
  if bnx.scope_delta_exists(pl.id, pl.last_validated_version) then perform bnx.fail('PLAN_REQUIRES_REVALIDATION', 'P0409'); end if;
  update bnx.posting_plan set state = 'approved', approved_by = a.member_id, approved_at = now(), approval_tier = 'T2' where id = pl.id;
  select coalesce(max(seq),0)+1 into s from bnx.plan_event where plan_id = pl.id;
  insert into bnx.plan_event values (pl.id, s, 'approved', null, null, null, null, a.member_id, now());
  perform bnx.enqueue('plan.execute', jsonb_build_object('plan_id', pl.id));
  perform bnx.audit(a, 'approve_plan', jsonb_build_object('plan_id', pl.id, 'plan_hash', cmd->>'plan_hash'), cmd, null);
  return bnx.idem_end(a, 'approve_plan', cmd, jsonb_build_object('status', 'approved_pending_activation',
         'queue_generation', (select generation from bnx.queue_state)));
end $$;

create function bnx.plan_terminate(p_plan uuid, p_state text, p_reason text) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare b uuid; s int; vnow bigint;
begin
  select version into vnow from bnx.ledger_state;
  update bnx.posting_plan set state = p_state where id = p_plan;
  select id into b from bnx.posting_batch where plan_id = p_plan and state in ('open','sealed');
  if b is not null then
    update bnx.posting_batch set state = 'void', void_reason = p_reason where id = b;
    insert into bnx.posting_batch_event(batch_id, event, recorded_version, reason) values (b, 'voided', vnow, p_reason);
  end if;
  update bnx.posting_scope_claim set claim_state = 'released', released_version = vnow where plan_id = p_plan and claim_state = 'held';
  select coalesce(max(seq),0)+1 into s from bnx.plan_event where plan_id = p_plan;
  insert into bnx.plan_event values (p_plan, s, p_state, vnow, vnow, null, jsonb_build_object('reason', p_reason), null, now());
  perform bnx.audit(row(null, null, 'worker', null, null)::bnx.actor, 'plan_' || p_state, jsonb_build_object('plan_id', p_plan), '{}', null);
  insert into bnx.outbox(topic, payload, created_version) values ('plan.' || p_state, jsonb_build_object('plan_id', p_plan, 'reason', p_reason), vnow);
end $$;

create function bnx.wrk_post_plan_chunk(p_plan uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare pl record; b uuid; it record; acid uuid; ac record; j uuid; ap bnx.actor; vnow bigint;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into pl from bnx.posting_plan where id = p_plan for update;
  if not found or pl.state not in ('approved','executing') then return coalesce(pl.state, 'not_found'); end if;
  acid := (pl.scope->>'account_currency_id')::uuid;
  ap := row(pl.approved_by, null, 'pwa', null, array['post'])::bnx.actor;
  if not bnx.actor_can_post(ap, acid) then perform bnx.plan_terminate(p_plan, 'suspended', 'approver no longer authorized'); return 'suspended'; end if;
  if bnx.scope_delta_exists(p_plan, pl.last_validated_version) then
    perform bnx.plan_terminate(p_plan, 'stale', 'scope changed after approval; new approval required'); return 'stale';
  end if;
  select version into vnow from bnx.ledger_state;
  update bnx.posting_plan set last_validated_version = vnow, state = 'executing' where id = p_plan;
  select id into b from bnx.posting_batch where plan_id = p_plan;
  if b is null then
    b := gen_random_uuid();
    insert into bnx.posting_batch(id, plan_id, state) values (b, p_plan, 'open');
    insert into bnx.posting_batch_event(batch_id, event, recorded_version) values (b, 'opened', vnow);
  end if;
  select * into ac from bnx.account_currency where id = acid;
  for it in select * from bnx.posting_plan_item where plan_id = p_plan and posted_journal_id is null order by seq loop
    if bnx.h(it.payload::text) <> it.payload_sha256 then perform bnx.fail('PLAN_ITEM_TAMPERED', 'P0409'); end if;  -- INV-26
    j := bnx.insert_journal(ap, null, b, case when (it.payload->>'amount')::numeric >= 0 then 'income' else 'consumption_expense' end,
           (it.payload->>'transaction_date')::date, null, it.payload->>'description',
           jsonb_build_array(jsonb_build_object('ledger_account_id', ac.ledger_account_id, 'currency', ac.currency, 'amount', it.payload->>'amount'),
                             jsonb_build_object('ledger_account_id', it.payload->>'counter_ledger_account_id', 'currency', ac.currency,
                                                'amount', (-(it.payload->>'amount')::numeric)::text)), null, null, null, p_plan);
    update bnx.posting_plan_item set posted_journal_id = j where plan_id = p_plan and seq = it.seq;
  end loop;
  update bnx.posting_batch set state = 'sealed' where id = b;
  insert into bnx.posting_batch_event(batch_id, event, recorded_version) values (b, 'sealed', vnow) on conflict do nothing;
  update bnx.posting_plan set state = 'sealed' where id = p_plan;
  return 'sealed';
end $$;

create function bnx.wrk_activate_plan(p_plan uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare pl record; b uuid; v bigint; s int; ap bnx.actor;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
  select * into pl from bnx.posting_plan where id = p_plan for update;
  if not found or pl.state <> 'sealed' then return coalesce(pl.state, 'not_found'); end if;
  -- fail closed (INV-43): any unvalidated fact in scope → no writes at all
  if bnx.scope_delta_exists(p_plan, pl.last_validated_version) then return 'revalidation_required'; end if;
  ap := row(pl.approved_by, null, 'pwa', null, array['post'])::bnx.actor;
  if not bnx.actor_can_post(ap, (pl.scope->>'account_currency_id')::uuid) then return 'revalidation_required'; end if;
  select id into b from bnx.posting_batch where plan_id = p_plan and state = 'sealed';
  if (select count(*) from bnx.posting_plan_item where plan_id = p_plan and posted_journal_id is not null) <> pl.item_count then
    perform bnx.fail('BATCH_INCOMPLETE', 'P0409'); end if;
  v := bnx.next_version();
  insert into bnx.posting_batch_event(batch_id, event, recorded_version) values (b, 'activated', v);
  update bnx.posting_batch set state = 'active', activated_version = v, activated_at = now(), activated_by = pl.approved_by where id = b;
  update bnx.posting_plan set state = 'activated' where id = p_plan;
  update bnx.posting_scope_claim set claim_state = 'released', released_version = v where plan_id = p_plan;
  select coalesce(max(seq),0)+1 into s from bnx.plan_event where plan_id = p_plan;
  insert into bnx.plan_event values (p_plan, s, 'activated', null, v, null, null, null, now());
  perform bnx.audit(row(pl.approved_by, null, 'plan', null, null)::bnx.actor, 'activate_plan', jsonb_build_object('plan_id', p_plan), '{}', v);
  insert into bnx.outbox(topic, payload, created_version) values ('plan.activated', jsonb_build_object('plan_id', p_plan), v);
  return 'activated';
end $$;

-- AUD-046: queue status and claim for the dispatcher (Neon is authoritative)
create function bnx.wrk_queue_status() returns jsonb
language sql security definer set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('generation', q.generation, 'drained_generation', q.drained_generation,
         'queued', (select count(*) from bnx.work_item where state = 'queued' or (state = 'leased' and lease_until < now())))
    from bnx.queue_state q
$$;

create function bnx.wrk_claim(p_max int) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare g bigint; res jsonb;
begin
  -- the queue_state row lock orders this claim against every enqueue (bnx.enqueue updates the same row)
  select generation into g from bnx.queue_state for update;
  with c as (select id from bnx.work_item where state = 'queued' or (state = 'leased' and lease_until < now())
              order by id limit greatest(1, least(p_max, 25)) for update skip locked),
       u as (update bnx.work_item w set state = 'leased', lease_until = now() + interval '10 minutes', attempts = attempts + 1
               from c where w.id = c.id returning w.id, w.kind, w.payload)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'payload', payload) order by id), '[]') into res from u;
  -- drained_generation only advances to the generation observed under the lock, and only when nothing is left
  if not exists (select 1 from bnx.work_item where state = 'queued' or (state = 'leased' and lease_until < now())) then
    update bnx.queue_state set drained_generation = g;
  end if;
  return jsonb_build_object('generation', g, 'items', res);
end $$;

create function bnx.wrk_complete(p_id bigint, p_ok boolean) returns void
language sql security definer set search_path = pg_catalog, pg_temp as $$
  update bnx.work_item set state = case when p_ok then 'done' when attempts >= 5 then 'dead' else 'queued' end,
         lease_until = null where id = p_id
$$;
