-- 9005 Audit chain v2 (V1.2 UA §5.10; OBJ-020; S4B-F08). MODIFY bnx.audit(), bnx.audit_verify(), bnx.resolve_actor()
-- (same signatures; bnx.actor composite unchanged). v1 rows (seq < first v2 seq) keep the R1 concat_ws encoding and verify
-- byte-identically; new rows use the v2 canonical encoding: sha256(prev_hash || jsonb_build_array(...)::text) with explicit
-- NULLs, fixed field order and JSON escaping (no field-boundary ambiguity) and the event time covered.
-- Implementation note F-C2-01: at_hashed is encoded as a UTC text 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"', not as a raw
-- timestamptz inside jsonb_build_array, because to_jsonb(timestamptz) renders the session TimeZone (a verifier running
-- with another TimeZone would compute a different hash).
set role bnx_definer;

alter table bnx.audit_event add column chain_version smallint not null default 1 check (chain_version in (1, 2));
alter table bnx.audit_event add column at_hashed timestamptz;
alter table bnx.audit_event add column host_profile text;
alter table bnx.audit_event add column tool_name text;
alter table bnx.audit_event add column tool_version text;
alter table bnx.audit_event add column trace_id text;
alter table bnx.audit_event alter column chain_version set default 2;
alter table bnx.audit_event add constraint audit_event_v2_time_ck check (chain_version = 1 or at_hashed is not null);

-- v1 rows can never follow v2 rows; the chain version never decreases
create function bnx.trg_audit_chain_version() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.restore_mode() then return new; end if;
  if new.chain_version < coalesce((select max(chain_version) from bnx.audit_event), 1) then
    raise exception 'AUDIT_CHAIN_VERSION: v% after v%', new.chain_version, (select max(chain_version) from bnx.audit_event)
      using errcode = 'P0409';
  end if;
  return new;
end $$;
create trigger t_chain_version before insert on bnx.audit_event for each row execute function bnx.trg_audit_chain_version();

create function bnx.audit_canonical_v2(p_seq bigint, p_member uuid, p_conn uuid, p_channel text, p_command text, p_subject jsonb,
    p_payload_hex text, p_version bigint, p_at timestamptz, p_cv smallint, p_host text, p_tool text, p_tool_ver text, p_trace text)
returns bytea language sql immutable set search_path = pg_catalog, pg_temp as $$
  select convert_to(jsonb_build_array(p_seq, p_member, p_conn, p_channel, p_command, p_subject, p_payload_hex, p_version,
           to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'), p_cv, p_host, p_tool, p_tool_ver, p_trace)::text, 'UTF8')
$$;

-- envelope fields (host profile, tool, trace) travel as transaction-local GUCs set by resolve_actor
-- the same rule as resolve_actor (<= 100 printable characters) is enforced at the point of use, because Worker and authn
-- sessions audit without resolve_actor and can set the GUCs themselves (same-family review finding 6)
create function bnx.envelope_value(p_name text) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v text := nullif(current_setting('bnx.' || p_name, true), '');
begin
  if v is not null and (length(v) > 100 or v !~ '^[[:print:]]+$') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'envelope.' || p_name);
  end if;
  return v;
end $$;

create or replace function bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) returns bigint
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare prev bytea; s bigint; ph bytea := bnx.h(coalesce(p_payload,'{}'::jsonb)::text); t timestamptz := now();
        hp text := bnx.envelope_value('host_profile'); tn text := bnx.envelope_value('tool_name');
        tv text := bnx.envelope_value('tool_version'); tr text := bnx.envelope_value('trace_id');
begin
  perform pg_advisory_xact_lock(hashtext('bnx.audit'));
  select seq, hash into s, prev from bnx.audit_event order by seq desc limit 1;
  s := coalesce(s, 0) + 1;
  insert into bnx.audit_event(seq, at, member_id, connection_id, channel, command, subject, payload_sha256, ledger_version, prev_hash,
                              hash, chain_version, at_hashed, host_profile, tool_name, tool_version, trace_id)
  values (s, t, a.member_id, a.connection_id, coalesce(a.channel,'system'), p_command, p_subject, ph, p_version, prev,
          sha256(coalesce(prev, '\x'::bytea) || bnx.audit_canonical_v2(s, a.member_id, a.connection_id, coalesce(a.channel,'system'),
                 p_command, p_subject, encode(ph,'hex'), p_version, t, 2::smallint, hp, tn, tv, tr)),
          2, t, hp, tn, tv, tr);
  return s;
end $$;

create or replace function bnx.audit_verify() returns bigint   -- returns 0 when intact, else the first bad seq
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare r record; prev bytea := null; expect bigint := 1; cv smallint := 1; h bytea;
begin
  for r in select * from bnx.audit_event order by seq loop
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

-- head of the chain for external anchoring (backup header, vault manifest; 9016)
create function bnx.audit_head() returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select jsonb_build_object('seq', seq, 'hash', encode(hash, 'hex'), 'chain_version', chain_version)
                     from bnx.audit_event order by seq desc limit 1), jsonb_build_object('seq', 0))
$$;

-- resolve_actor MODIFY: R1 body unchanged, plus the optional credential envelope {host_profile, tool_name, tool_version,
-- trace_id} (printable, at most 100 characters each) stored as transaction-local GUCs for bnx.audit().
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
    if val is not null and (length(val) > 100 or val !~ '^[[:print:]]+$') then
      perform bnx.fail('VALIDATION_FAILED', 'P0422', 'envelope.' || k);
    end if;
    perform set_config('bnx.' || k, coalesce(val, ''), true);
  end loop;
  return a;
end $$;

select bnx.apply_grants();
