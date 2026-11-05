--
-- PostgreSQL database dump
--

\restrict bRzsuzGeqVuoaa1epojLU8stvEyT2ANot6jb1gEv3Tp1Axvu8nYBh1NvNqOOrdF

-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: bnx_auth
--

CREATE SCHEMA auth;


ALTER SCHEMA auth OWNER TO bnx_auth;

--
-- Name: bnx; Type: SCHEMA; Schema: -; Owner: bnx_definer
--

CREATE SCHEMA bnx;


ALTER SCHEMA bnx OWNER TO bnx_definer;

--
-- Name: actor; Type: TYPE; Schema: bnx; Owner: bnx_definer
--

CREATE TYPE bnx.actor AS (
	member_id uuid,
	connection_id uuid,
	channel text,
	session_id uuid,
	scopes text[]
);


ALTER TYPE bnx.actor OWNER TO bnx_definer;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: opening_anchor_version; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.opening_anchor_version (
    id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    anchor_date date NOT NULL,
    amount numeric(20,4) NOT NULL,
    journal_id uuid,
    reversed_journal_id uuid,
    source text NOT NULL,
    certainty text NOT NULL,
    evidence jsonb,
    revision integer NOT NULL,
    installed_by_plan uuid,
    bridge_difference numeric(20,4),
    reason text NOT NULL,
    valid_from_version bigint NOT NULL,
    recorded_by uuid NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT opening_anchor_version_certainty_check CHECK ((certainty = ANY (ARRAY['evidenced'::text, 'declared'::text, 'estimated'::text]))),
    CONSTRAINT opening_anchor_version_check CHECK (((amount = (0)::numeric) = (journal_id IS NULL))),
    CONSTRAINT opening_anchor_version_source_check CHECK ((source = ANY (ARRAY['statement_opening'::text, 'statement_derived'::text, 'zero_new_account'::text, 'manual_declaration'::text, 'history_reconstruction'::text])))
);


ALTER TABLE bnx.opening_anchor_version OWNER TO bnx_definer;

--
-- Name: balance_result; Type: TYPE; Schema: bnx; Owner: bnx_definer
--

CREATE TYPE bnx.balance_result AS (
	status text,
	amount numeric(20,4),
	anchor bnx.opening_anchor_version,
	ledger_version bigint
);


ALTER TYPE bnx.balance_result OWNER TO bnx_definer;

--
-- Name: economic_type; Type: TYPE; Schema: bnx; Owner: bnx_definer
--

CREATE TYPE bnx.economic_type AS ENUM (
    'consumption_expense',
    'card_spend',
    'income',
    'interest_income',
    'refund',
    'fee',
    'interest_expense',
    'loan_interest',
    'internal_transfer',
    'card_repayment',
    'fx_conversion',
    'loan_disbursement',
    'loan_principal_repayment',
    'loan_lent',
    'loan_principal_collected',
    'intra_household_loan',
    'intra_household_loan_repayment',
    'investment_subscription',
    'investment_redemption',
    'investment_income',
    'transfer_to_clearing',
    'clearing_resolution',
    'opening_balance',
    'correction_reversal',
    'correction_replacement',
    'interledger_transfer'
);


ALTER TYPE bnx.economic_type OWNER TO bnx_definer;

--
-- Name: posting_date_status; Type: TYPE; Schema: bnx; Owner: bnx_definer
--

CREATE TYPE bnx.posting_date_status AS ENUM (
    'estimated',
    'user_confirmed',
    'statement_confirmed'
);


ALTER TYPE bnx.posting_date_status OWNER TO bnx_definer;

--
-- Name: account_scope_at(uuid, date, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.account_scope_at(p_account uuid, p_date date, p_v bigint) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select coalesce((select s.ownership_scope from bnx.account_scope_event s
     where s.account_id = p_account and s.recorded_version <= p_v and s.effective_from <= p_date
     order by s.effective_from desc, s.recorded_version desc, s.event_seq desc limit 1), 'individual')
$$;


ALTER FUNCTION bnx.account_scope_at(p_account uuid, p_date date, p_v bigint) OWNER TO bnx_definer;

--
-- Name: actor_can_post(bnx.actor, uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.actor_can_post(a bnx.actor, p_ac uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select a.channel = 'pwa' and exists (select 1 from bnx.account_currency ac
     join bnx.account_grant g on g.account_id = ac.account_id and g.member_id = a.member_id and g.can_post
     join bnx.member m on m.id = a.member_id and m.state = 'active' and m.role <> 'viewer'
    where ac.id = p_ac)
$$;


ALTER FUNCTION bnx.actor_can_post(a bnx.actor, p_ac uuid) OWNER TO bnx_definer;

--
-- Name: actor_visible_acs(bnx.actor); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.actor_visible_acs(a bnx.actor) RETURNS SETOF uuid
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select v from bnx.visible_account_currency_ids(a.member_id) v
   where a.channel <> 'mcp' or v = any (select unnest(account_currency_ids) from bnx.ai_connection where id = a.connection_id)
$$;


ALTER FUNCTION bnx.actor_visible_acs(a bnx.actor) OWNER TO bnx_definer;

--
-- Name: anchor_at(uuid, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.anchor_at(p_ac uuid, p_v bigint) RETURNS bnx.opening_anchor_version
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select a.* from bnx.opening_anchor_version a
   where a.account_currency_id = p_ac and a.valid_from_version <= p_v
   order by a.valid_from_version desc limit 1
$$;


ALTER FUNCTION bnx.anchor_at(p_ac uuid, p_v bigint) OWNER TO bnx_definer;

--
-- Name: apply_grants(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.apply_grants() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.apply_grants() OWNER TO bnx_definer;

--
-- Name: assert_journal_complete(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.assert_journal_complete(p_journal uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare je record; n int; bad record;
begin
  select * into je from bnx.journal_entry where id = p_journal;
  if not found then return; end if;
  select count(*) into n from bnx.journal_line where journal_id = p_journal;
  if n < 2 then
    raise exception 'JOURNAL_INCOMPLETE: journal % has % line(s) (INV-01)', p_journal, n using errcode = 'P0422';
  end if;
  select jl.currency, sum(jl.amount) s, bool_or(jl.amount > 0) d, bool_or(jl.amount < 0) c into bad
    from bnx.journal_line jl where jl.journal_id = p_journal
   group by jl.currency
  having sum(jl.amount) <> 0 or not bool_or(jl.amount > 0) or not bool_or(jl.amount < 0)
   limit 1;
  if found then
    raise exception 'JOURNAL_UNBALANCED: journal % currency % sum % debit % credit % (INV-02/03)',
      p_journal, bad.currency, bad.s, bad.d, bad.c using errcode = 'P0422';
  end if;
  select jl.id, jl.currency, la.currency la_currency into bad
    from bnx.journal_line jl join bnx.ledger_account la on la.id = jl.ledger_account_id
   where jl.journal_id = p_journal and jl.currency <> la.currency limit 1;
  if found then
    raise exception 'LINE_CURRENCY_MISMATCH: line % % vs ledger account % (INV-04)', bad.id, bad.currency, bad.la_currency
      using errcode = 'P0422';
  end if;
  select jl.id, jl.amount, c.minor_units into bad
    from bnx.journal_line jl join bnx.currency c on c.code = jl.currency
   where jl.journal_id = p_journal
     and (jl.amount <> round(jl.amount, c.minor_units) or abs(jl.amount) >= 1e15) limit 1;
  if found then
    raise exception 'AMOUNT_SCALE: line % amount % exceeds % minor units (INV-08)', bad.id, bad.amount, bad.minor_units
      using errcode = 'P0422';
  end if;
  if not bnx.restore_mode() and exists (select 1 from bnx.journal_line
       where journal_id = p_journal and created_xid <> je.created_xid) then
    raise exception 'LATE_LINE: journal % has lines from another transaction (INV-07)', p_journal using errcode = 'P0422';
  end if;
end $$;


ALTER FUNCTION bnx.assert_journal_complete(p_journal uuid) OWNER TO bnx_definer;

--
-- Name: assert_scale(numeric, character, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.assert_scale(p_amount numeric, p_currency character, p_what text) RETURNS void
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare mu smallint;
begin
  if p_amount is null then return; end if;
  select minor_units into mu from bnx.currency where code = p_currency;
  if mu is null then raise exception 'UNKNOWN_CURRENCY % (%)', p_currency, p_what using errcode = 'P0422'; end if;
  if p_amount <> round(p_amount, mu) or abs(p_amount) >= 1e15 then
    raise exception 'AMOUNT_SCALE: % % exceeds % minor units of % (INV-08)', p_what, p_amount, mu, p_currency using errcode = 'P0422';
  end if;
end $$;


ALTER FUNCTION bnx.assert_scale(p_amount numeric, p_currency character, p_what text) OWNER TO bnx_definer;

--
-- Name: audit(bnx.actor, text, jsonb, jsonb, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) OWNER TO bnx_definer;

--
-- Name: audit_privileges(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.audit_privileges() RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.audit_privileges() OWNER TO bnx_definer;

--
-- Name: audit_verify(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.audit_verify() RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.audit_verify() OWNER TO bnx_definer;

--
-- Name: authn_begin_session(jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.authn_begin_session(claims jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.authn_begin_session(claims jsonb) OWNER TO bnx_definer;

--
-- Name: authn_oauth_token(jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.authn_oauth_token(req jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
end $_$;


ALTER FUNCTION bnx.authn_oauth_token(req jsonb) OWNER TO bnx_definer;

--
-- Name: balance_at(uuid, date, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.balance_at(p_ac uuid, p_date date, p_v bigint) RETURNS bnx.balance_result
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.opening_anchor_version; r bnx.balance_result;
begin
  a := bnx.anchor_at(p_ac, p_v);
  r.ledger_version := p_v;
  if a.id is null then r.status := 'NO_OPENING'; return r; end if;
  r.anchor := a;
  if p_date < a.anchor_date then r.status := 'BEFORE_OPENING'; return r; end if;
  select coalesce(sum(jl.amount), 0) into r.amount
    from bnx.visible_at(p_v) v
    join bnx.journal_line jl on jl.journal_id = v.journal_id
    join bnx.account_currency ac on ac.id = p_ac and jl.ledger_account_id = ac.ledger_account_id and jl.currency = ac.currency
   where bnx.effective_posting_date(v.journal_id, p_v) <= p_date;
  r.status := 'ok';
  return r;
end $$;


ALTER FUNCTION bnx.balance_at(p_ac uuid, p_date date, p_v bigint) OWNER TO bnx_definer;

--
-- Name: balance_rows(uuid[], date, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.balance_rows(p_acs uuid[], p_date date, p_v bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('account_currency_id', x, 'currency', ac.currency,
           'status', (bnx.balance_at(x, p_date, p_v)).status, 'amount', (bnx.balance_at(x, p_date, p_v)).amount::text)
           order by x), '[]'::jsonb)
    from unnest(p_acs) x join bnx.account_currency ac on ac.id = x
$$;


ALTER FUNCTION bnx.balance_rows(p_acs uuid[], p_date date, p_v bigint) OWNER TO bnx_definer;

--
-- Name: can_read_evidence(uuid, uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.can_read_evidence(p_member uuid, p_file uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select case
    when not exists (select 1 from bnx.member m where m.id = p_member and m.state = 'active') then 'denied'
    when exists (select 1 from bnx.evidence_file f where f.id = p_file and f.acquired_by = p_member) then 'acquirer'
    when exists (select 1 from bnx.evidence_file f where f.id = p_file
                  and f.assigned_account_currency_id in (select bnx.visible_account_currency_ids(p_member))) then 'account_grant'
    when exists (select 1 from bnx.evidence_access_grant g where g.evidence_file_id = p_file and g.member_id = p_member
                  and g.revoked_at is null and g.expires_at > now()) then 'owner_t3'
    else 'denied' end
$$;


ALTER FUNCTION bnx.can_read_evidence(p_member uuid, p_file uuid) OWNER TO bnx_definer;

--
-- Name: cmd_approve_ai_connection(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
end $_$;


ALTER FUNCTION bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_approve_plan(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_approve_plan(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; pl record; s int; pend int;
begin
  perform bnx.require(a, 2);
  rc := bnx.idem_begin(a, 'approve_plan', cmd); if rc is not null then return rc; end if;
  select * into pl from bnx.posting_plan where id = (cmd->>'plan_id')::uuid for update;
  if not found or pl.state <> 'frozen' then perform bnx.fail('PLAN_NOT_APPROVABLE', 'P0409'); end if;
  if not bnx.actor_can_post(a, (pl.scope->>'account_currency_id')::uuid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  if encode(pl.plan_hash,'hex') <> cmd->>'plan_hash' or encode(pl.scope_digest,'hex') <> cmd->>'scope_digest' then
    perform bnx.fail('PLAN_DIGEST_MISMATCH', 'P0409'); end if;
  if bnx.scope_delta_exists(pl.id, pl.last_validated_version) then perform bnx.fail('PLAN_REQUIRES_REVALIDATION', 'P0409'); end if;
  if coalesce((select (value)::text::boolean from bnx.household_setting where key = 'require_dual_copy_before_approval'), false) then
    pend := bnx.plan_evidence_pending(pl.id);
    if pend > 0 then
      perform bnx.fail('PLAN_WAITING_DUAL_COPY', 'P0409', pend || ' evidence object(s) not dual_verified');
    end if;
  end if;
  update bnx.posting_plan set state = 'approved', approved_by = a.member_id, approved_at = now(), approval_tier = 'T2' where id = pl.id;
  select coalesce(max(seq),0)+1 into s from bnx.plan_event where plan_id = pl.id;
  insert into bnx.plan_event values (pl.id, s, 'approved', null, null, null, null, a.member_id, now());
  perform bnx.enqueue('plan.execute', jsonb_build_object('plan_id', pl.id));
  perform bnx.audit(a, 'approve_plan', jsonb_build_object('plan_id', pl.id, 'plan_hash', cmd->>'plan_hash'), cmd, null);
  return bnx.idem_end(a, 'approve_plan', cmd, jsonb_build_object('status', 'approved_pending_activation',
         'queue_generation', (select generation from bnx.queue_state)));
end $$;


ALTER FUNCTION bnx.cmd_approve_plan(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_assign_evidence(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_assign_evidence(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_assign_evidence(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_audit_replay_snapshot(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_audit_replay_snapshot(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; s bnx.report_snapshot; ok boolean;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  select * into s from bnx.report_snapshot where id = (cmd->>'snapshot_id')::uuid;
  if s.id is null then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  ok := bnx.h(bnx.balance_rows(s.content_account_currency_ids, (s.filters->>'as_of')::date, s.ledger_version)::text) = s.content_sha256;
  perform bnx.audit(a, 'audit_replay_snapshot', jsonb_build_object('snapshot_id', s.id, 'content_digest_verified', ok),
                    coalesce(cmd, '{}'), s.ledger_version);
  return jsonb_build_object('snapshot_id', s.id, 'content_digest_verified', ok, 'ledger_version', s.ledger_version);
end $$;


ALTER FUNCTION bnx.cmd_audit_replay_snapshot(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_confirm_posting_date(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_confirm_posting_date(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_confirm_posting_date(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_correct_transaction(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_create_account(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_create_account(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_create_account(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_create_category(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_create_category(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_create_category(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_create_import_plan(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; p uuid := gen_random_uuid(); acid uuid := (cmd->>'account_currency_id')::uuid;
        ac record; it jsonb; i int := 0; vnow bigint; rng daterange; ph bytea; sd bytea; cla record; ev jsonb := coalesce(cmd->'evidence_file_ids', '[]');
        f text;
begin
  perform bnx.require(a, 2);
  if not bnx.actor_can_post(a, acid) then perform bnx.fail('NOT_POSTABLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'create_import_plan', cmd); if rc is not null then return rc; end if;
  for f in select jsonb_array_elements_text(ev) loop
    if bnx.can_read_evidence(a.member_id, f::uuid) = 'denied' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  end loop;
  select * into ac from bnx.account_currency where id = acid;
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
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
  ph := bnx.h(acid::text || '|' || rng::text || '|' || (cmd->'items')::text || '|' || ev::text);
  sd := bnx.scope_digest(ac.ledger_account_id, acid, rng, vnow);
  insert into bnx.posting_plan(id, kind, scope, item_count, control_totals, plan_hash, state, frozen_at_version, last_validated_version, scope_digest)
  values (p, 'import', jsonb_build_object('account_currency_id', acid, 'range', rng::text, 'evidence_file_ids', ev), jsonb_array_length(cmd->'items'),
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


ALTER FUNCTION bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_create_party(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_create_party(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_create_party(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_create_report_snapshot(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); snap uuid := gen_random_uuid(); vnow bigint; v bigint; d date;
        vis uuid[]; req uuid[]; content_acs uuid[]; proj uuid[];
begin
  perform bnx.require(a, 0);
  if cmd->>'report_code' is distinct from 'R-BAL' then perform bnx.fail('REPORT_NOT_IMPLEMENTED', 'P0422', cmd->>'report_code'); end if;
  select version into vnow from bnx.ledger_state;
  v := coalesce((cmd->>'ledger_version')::bigint, vnow);
  if v < 0 or v > vnow then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'ledger_version'); end if;
  d := coalesce((cmd->>'as_of')::date, current_date);
  vis := array(select bnx.actor_visible_acs(a));
  if cmd ? 'account_currency_ids' then
    select coalesce(array_agg(x::uuid order by x::uuid), '{}') into req from jsonb_array_elements_text(cmd->'account_currency_ids') x;
    if not (req <@ vis) then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;   -- no oracle on unseen accounts
  else
    req := array(select unnest(vis) order by 1);
  end if;
  -- household report: accounting content covers all account-currencies; the projection is what this audience sees
  content_acs := array(select ac.id from bnx.account_currency ac order by ac.id);
  proj := array(select x from unnest(req) x order by x);
  insert into bnx.report_snapshot(id, report_code, filters_digest, ledger_version, report_definition_version, fx_policy,
    valuation_cutoff, content_account_currency_ids, content_sha256, projection_actor, projection_account_currency_ids,
    projection_sha256, canonicalization, projection_channel, projection_connection_id, projection_requested_acs, filters)
  values (snap, 'R-BAL', bnx.h(jsonb_build_object('as_of', d, 'acs', req)::text), v, 'R-BAL/1', '{"mode":"native"}', null,
    content_acs, bnx.h(bnx.balance_rows(content_acs, d, v)::text), a.member_id, proj,
    bnx.h(bnx.balance_rows(proj, d, v)::text), 'jsonb-text/rows-sorted-by-account_currency_id',
    a.channel, a.connection_id, req, jsonb_build_object('as_of', d));
  perform bnx.audit(a, 'create_report_snapshot', jsonb_build_object('snapshot_id', snap), cmd, v);
  return jsonb_build_object('snapshot_id', snap, 'ledger_version', v, 'rows', bnx.balance_rows(proj, d, v),
                            'projection_sha256', encode(bnx.h(bnx.balance_rows(proj, d, v)::text), 'hex'));
end $$;


ALTER FUNCTION bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_invite_member(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_invite_member(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_invite_member(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_post_transaction(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_post_transaction(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_post_transaction(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_record_ownership(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_record_ownership(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_record_ownership(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_register_evidence(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_register_evidence(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
end $_$;


ALTER FUNCTION bnx.cmd_register_evidence(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_revoke_ai_connection(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred);
begin
  perform bnx.require(a, 2);
  update bnx.ai_connection set revoked_at = now() where id = (cmd->>'connection_id')::uuid and member_id = a.member_id;
  update bnx.ai_connection_token set revoked_at = now() where connection_id = (cmd->>'connection_id')::uuid;
  perform bnx.audit(a, 'revoke_ai_connection', jsonb_build_object('connection_id', cmd->>'connection_id'), '{}', null);
  return jsonb_build_object('status', 'revoked');
end $$;


ALTER FUNCTION bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_revoke_session(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_revoke_session(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred);
begin
  perform bnx.require(a, 0);
  update bnx.member_session set revoked_at = now() where id = a.session_id;
  perform bnx.audit(a, 'revoke_session', jsonb_build_object('session_id', a.session_id), '{}', null);
  return jsonb_build_object('status', 'revoked');
end $$;


ALTER FUNCTION bnx.cmd_revoke_session(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_set_account_scope(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_set_account_scope(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_set_account_scope(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_set_grant(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_set_grant(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_set_grant(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_set_household_setting(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); role text; rc jsonb;
begin
  role := bnx.require(a, 3);
  if role <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
  rc := bnx.idem_begin(a, 'set_household_setting', cmd); if rc is not null then return rc; end if;
  if cmd->>'setting' is distinct from 'require_dual_copy_before_approval' or jsonb_typeof(cmd->'value') <> 'boolean' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'setting'); end if;
  insert into bnx.household_setting values (cmd->>'setting', cmd->'value', a.member_id, now())
    on conflict (key) do update set value = excluded.value, set_by = excluded.set_by, set_at = now();
  perform bnx.audit(a, 'set_household_setting', jsonb_build_object('setting', cmd->>'setting', 'value', cmd->'value'), cmd, null);
  return bnx.idem_end(a, 'set_household_setting', cmd, jsonb_build_object('setting', cmd->>'setting', 'value', cmd->'value'));
end $$;


ALTER FUNCTION bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_set_member_state(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_set_member_state(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_set_member_state(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: cmd_set_opening(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.cmd_set_opening(cred jsonb, cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.cmd_set_opening(cred jsonb, cmd jsonb) OWNER TO bnx_definer;

--
-- Name: dec(jsonb, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx."dec"(p jsonb, p_field text) RETURNS numeric
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
declare t text := p->>p_field;
begin
  if t is null or t !~ '^-?[0-9]{1,15}(\.[0-9]{1,4})?$' then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', p_field || ' must be a decimal string');
  end if;
  return t::numeric;
end $_$;


ALTER FUNCTION bnx."dec"(p jsonb, p_field text) OWNER TO bnx_definer;

--
-- Name: effective_posting_date(uuid, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.effective_posting_date(p_journal uuid, p_v bigint) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select coalesce(
    (select c.confirmed_posting_date from bnx.posting_date_confirmation c
      where c.journal_id = p_journal and c.recorded_version <= p_v
      order by c.recorded_version desc, c.seq desc limit 1),
    (select je.posting_date from bnx.journal_entry je where je.id = p_journal))
$$;


ALTER FUNCTION bnx.effective_posting_date(p_journal uuid, p_v bigint) OWNER TO bnx_definer;

--
-- Name: enqueue(text, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.enqueue(p_kind text, p_payload jsonb) RETURNS bigint
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare wid bigint;
begin
  insert into bnx.work_item(kind, payload) values (p_kind, p_payload) returning work_item.id into wid;
  update bnx.queue_state set generation = generation + 1;
  return wid;
end $$;


ALTER FUNCTION bnx.enqueue(p_kind text, p_payload jsonb) OWNER TO bnx_definer;

--
-- Name: fail(text, text, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.fail(p_code text, p_state text, p_detail text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin raise exception '%', p_code using errcode = p_state, detail = coalesce(p_detail, ''); end $$;


ALTER FUNCTION bnx.fail(p_code text, p_state text, p_detail text) OWNER TO bnx_definer;

--
-- Name: h(text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.h(p text) RETURNS bytea
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$ select sha256(convert_to(p, 'UTF8')) $$;


ALTER FUNCTION bnx.h(p text) OWNER TO bnx_definer;

--
-- Name: idem_begin(bnx.actor, text, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.idem_begin(a bnx.actor, p_command text, p_cmd jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.idem_begin(a bnx.actor, p_command text, p_cmd jsonb) OWNER TO bnx_definer;

--
-- Name: idem_end(bnx.actor, text, jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.idem_end(a bnx.actor, p_command text, p_cmd jsonb, p_receipt jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  insert into bnx.idempotency(member_id, idem_key, command, request_sha256, receipt)
  values (a.member_id, p_cmd->>'idempotency_key', p_command, bnx.h(p_command || '|' || (p_cmd - 'idempotency_key')::text), p_receipt);
  return p_receipt || '{"replayed": false}'::jsonb;
end $$;


ALTER FUNCTION bnx.idem_end(a bnx.actor, p_command text, p_cmd jsonb, p_receipt jsonb) OWNER TO bnx_definer;

--
-- Name: insert_journal(bnx.actor, bigint, uuid, text, date, date, text, jsonb, numeric, text, numeric, uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.insert_journal(a bnx.actor, p_v bigint, p_batch uuid, p_type text, p_tdate date, p_pdate date, p_desc text, p_lines jsonb, p_orig_amount numeric, p_orig_currency text, p_rate numeric, p_plan uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.insert_journal(a bnx.actor, p_v bigint, p_batch uuid, p_type text, p_tdate date, p_pdate date, p_desc text, p_lines jsonb, p_orig_amount numeric, p_orig_currency text, p_rate numeric, p_plan uuid) OWNER TO bnx_definer;

--
-- Name: install_household(text, text, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.install_household(p_owner_name text, p_iss text, p_sub text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.install_household(p_owner_name text, p_iss text, p_sub text) OWNER TO bnx_definer;

--
-- Name: new_secret(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.new_secret() RETURNS text
    LANGUAGE sql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select translate(encode(decode(replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''), 'hex'),
         'base64'), '+/=', '-_')
$$;


ALTER FUNCTION bnx.new_secret() OWNER TO bnx_definer;

--
-- Name: next_version(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.next_version() RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare v bigint;
begin
  perform pg_advisory_xact_lock(hashtext('bnx.ledger'));
  update bnx.ledger_state set version = version + 1 returning version into v;
  return v;
end $$;


ALTER FUNCTION bnx.next_version() OWNER TO bnx_definer;

--
-- Name: ownership_at(uuid, date, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.ownership_at(p_account uuid, p_date date, p_v bigint) RETURNS TABLE(party_id uuid, kind text, share numeric)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select x.party_id, x.kind, x.share from (
    select distinct on (e.party_id, e.kind) e.party_id, e.kind, e.event, e.share
      from bnx.account_ownership_event e
     where e.account_id = p_account and e.recorded_version <= p_v and e.effective_from <= p_date
     order by e.party_id, e.kind, e.effective_from desc, e.recorded_version desc, e.event_seq desc) x
  where x.event = 'set'
$$;


ALTER FUNCTION bnx.ownership_at(p_account uuid, p_date date, p_v bigint) OWNER TO bnx_definer;

--
-- Name: plan_evidence_pending(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.plan_evidence_pending(p_plan uuid) RETURNS integer
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select count(*)::int from bnx.posting_plan pl
    cross join lateral jsonb_array_elements_text(coalesce(pl.scope->'evidence_file_ids', '[]')) f(id)
    join bnx.evidence_file ef on ef.id = f.id::uuid join bnx.evidence_object eo on eo.id = ef.evidence_object_id
   where pl.id = p_plan and eo.archive_state <> 'dual_verified'
$$;


ALTER FUNCTION bnx.plan_evidence_pending(p_plan uuid) OWNER TO bnx_definer;

--
-- Name: plan_scope(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.plan_scope(p_plan uuid) RETURNS TABLE(acid uuid, la uuid, during daterange)
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select c.account_currency_id, ac.ledger_account_id, c.during from bnx.posting_scope_claim c
    join bnx.account_currency ac on ac.id = c.account_currency_id where c.plan_id = p_plan
$$;


ALTER FUNCTION bnx.plan_scope(p_plan uuid) OWNER TO bnx_definer;

--
-- Name: plan_terminate(uuid, text, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.plan_terminate(p_plan uuid, p_state text, p_reason text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.plan_terminate(p_plan uuid, p_state text, p_reason text) OWNER TO bnx_definer;

--
-- Name: q_balances(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.q_balances(cred jsonb, q jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.q_balances(cred jsonb, q jsonb) OWNER TO bnx_definer;

--
-- Name: q_evidence_access(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.q_evidence_access(cred jsonb, q jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.q_evidence_access(cred jsonb, q jsonb) OWNER TO bnx_definer;

--
-- Name: q_replay_snapshot(jsonb, jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.q_replay_snapshot(cred jsonb, q jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare a bnx.actor := bnx.resolve_actor(cred); sid uuid; decision text; s bnx.report_snapshot; r_rows jsonb;
begin
  perform bnx.require(a, 0);
  begin sid := (q->>'snapshot_id')::uuid; exception when others then sid := null; end;
  decision := bnx.snapshot_decision(a, sid);
  if decision = 'NOT_AVAILABLE' then perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  if decision = 'ACCESS_REVOKED' then perform bnx.fail('ACCESS_REVOKED', 'P0403'); end if;
  select * into s from bnx.report_snapshot where id = sid;
  r_rows := bnx.balance_rows(s.projection_account_currency_ids, (s.filters->>'as_of')::date, s.ledger_version);
  return jsonb_build_object('snapshot_id', sid, 'ledger_version', s.ledger_version, 'rows', r_rows,
    'projection_digest_verified', bnx.h(r_rows::text) = s.projection_sha256);
end $$;


ALTER FUNCTION bnx.q_replay_snapshot(cred jsonb, q jsonb) OWNER TO bnx_definer;

--
-- Name: require(bnx.actor, integer); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.require(a bnx.actor, p_tier integer) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.require(a bnx.actor, p_tier integer) OWNER TO bnx_definer;

--
-- Name: resolve_actor(jsonb); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.resolve_actor(cred jsonb) RETURNS bnx.actor
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.resolve_actor(cred jsonb) OWNER TO bnx_definer;

--
-- Name: restore_mode(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.restore_mode() RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  -- Only the migrator's own session (never a runtime role calling a definer function) can enable restore mode.
  select session_user = 'bnx_migrator' and coalesce(current_setting('bnx.restore_mode', true), '') = 'on'
$$;


ALTER FUNCTION bnx.restore_mode() OWNER TO bnx_definer;

--
-- Name: scope_delta_exists(uuid, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.scope_delta_exists(p_plan uuid, p_since bigint) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.scope_delta_exists(p_plan uuid, p_since bigint) OWNER TO bnx_definer;

--
-- Name: scope_digest(uuid, uuid, daterange, bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.scope_digest(p_la uuid, p_acid uuid, p_during daterange, p_v bigint) RETURNS bytea
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select sha256(convert_to(coalesce((select string_agg(vv.journal_id::text || ':' || jl.amount::text || ':' ||
           bnx.effective_posting_date(vv.journal_id, p_v)::text, ',' order by vv.journal_id, jl.id)
      from bnx.visible_at(p_v) vv join bnx.journal_line jl on jl.journal_id = vv.journal_id
     where jl.ledger_account_id = p_la and bnx.effective_posting_date(vv.journal_id, p_v) <@ p_during), '') || '|anchor:' ||
     coalesce((bnx.anchor_at(p_acid, p_v)).id::text, 'none'), 'UTF8'))
$$;


ALTER FUNCTION bnx.scope_digest(p_la uuid, p_acid uuid, p_during daterange, p_v bigint) OWNER TO bnx_definer;

--
-- Name: snapshot_decision(bnx.actor, uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.snapshot_decision(a bnx.actor, p_snapshot uuid) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare s bnx.report_snapshot; vis uuid[];
begin
  select * into s from bnx.report_snapshot where id = p_snapshot;
  if s.id is null or s.projection_actor is distinct from a.member_id then return 'NOT_AVAILABLE'; end if;
  -- a snapshot created through an AI connection is replayable by that connection or by the member's own PWA session;
  -- a snapshot created in the PWA is replayable through a connection only within the connection's current scope
  if a.channel = 'mcp' and s.projection_connection_id is not null and s.projection_connection_id <> a.connection_id then
    return 'NOT_AVAILABLE';
  end if;
  if not exists (select 1 from bnx.member m where m.id = a.member_id and m.state = 'active') then return 'ACCESS_REVOKED'; end if;
  if a.channel = 'mcp' and (a.connection_id is null or not exists (select 1 from bnx.ai_connection c
        where c.id = a.connection_id and c.revoked_at is null and 'read' = any(c.scopes))) then
    return 'ACCESS_REVOKED';
  end if;
  vis := array(select bnx.actor_visible_acs(a));
  -- requested scope covers zero-content snapshots (an empty projection is never vacuously authorized)
  if s.projection_requested_acs is null or not (s.projection_requested_acs <@ vis)
     or not (s.projection_account_currency_ids <@ vis) then
    return 'ACCESS_REVOKED';
  end if;
  return 'ok';
end $$;


ALTER FUNCTION bnx.snapshot_decision(a bnx.actor, p_snapshot uuid) OWNER TO bnx_definer;

--
-- Name: snapshot_replay_access(uuid, uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.snapshot_replay_access(p_member uuid, p_snapshot uuid) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select case d when 'NOT_AVAILABLE' then 'NOT_FOUND' else d end
    from bnx.snapshot_decision(row(p_member, null, 'pwa', null, array['read'])::bnx.actor, p_snapshot) d
$$;


ALTER FUNCTION bnx.snapshot_replay_access(p_member uuid, p_snapshot uuid) OWNER TO bnx_definer;

--
-- Name: system_ledger_account(text, character, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.system_ledger_account(p_kind text, p_currency character, p_name text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare lid uuid;
begin
  select la.id into lid from bnx.ledger_account la where la.kind = p_kind and la.currency = p_currency and la.name = p_name;
  if lid is null then
    lid := gen_random_uuid();
    insert into bnx.ledger_account values (lid, p_kind, p_currency, p_name);
  end if;
  return lid;
end $$;


ALTER FUNCTION bnx.system_ledger_account(p_kind text, p_currency character, p_name text) OWNER TO bnx_definer;

--
-- Name: trg_append_only(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_append_only() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  raise exception 'APPEND_ONLY: % on %', tg_op, tg_table_name using errcode = 'P0409';
end $$;


ALTER FUNCTION bnx.trg_append_only() OWNER TO bnx_definer;

--
-- Name: trg_archive_state_guard(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_archive_state_guard() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  if new.archive_state = 'dual_verified' and old.archive_state is distinct from 'dual_verified' then
    if new.integrity_state <> 'verified' or new.sha256 is null or not exists (
         select 1 from bnx.evidence_archive_event e where e.evidence_object_id = new.id and e.event = 'verified'
            and e.sha256_observed = new.sha256) then
      raise exception 'ARCHIVE_NOT_VERIFIED: object % has no verified independent copy matching its SHA-256', new.id
        using errcode = 'P0409';
    end if;
  end if;
  if old.archive_state = 'dual_verified' and new.archive_state not in ('dual_verified', 'archive_failed') then
    raise exception 'ARCHIVE_STATE_REGRESSION: % -> %', old.archive_state, new.archive_state using errcode = 'P0409';
  end if;
  return new;
end $$;


ALTER FUNCTION bnx.trg_archive_state_guard() OWNER TO bnx_definer;

--
-- Name: trg_evidence_object_write_once(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_evidence_object_write_once() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  if tg_op = 'DELETE' then raise exception 'APPEND_ONLY: delete evidence_object' using errcode = 'P0409'; end if;
  if new.r2_key <> old.r2_key or new.size_bytes <> old.size_bytes
     or (old.sha256 is not null and new.sha256 is distinct from old.sha256)
     or (old.dedup_into is not null and new.dedup_into is distinct from old.dedup_into)
     or (old.integrity_state <> 'unverified' and new.integrity_state <> old.integrity_state) then
    raise exception 'WRITE_ONCE: evidence_object %', old.id using errcode = 'P0409';
  end if;
  return new;
end $$;


ALTER FUNCTION bnx.trg_evidence_object_write_once() OWNER TO bnx_definer;

--
-- Name: trg_journal_complete(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_journal_complete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin
  if tg_table_name = 'journal_entry' then perform bnx.assert_journal_complete(new.id);
  else perform bnx.assert_journal_complete(new.journal_id); end if;
  return null;
end $$;


ALTER FUNCTION bnx.trg_journal_complete() OWNER TO bnx_definer;

--
-- Name: trg_line_same_txn(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_line_same_txn() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare x xid8;
begin
  select created_xid into x from bnx.journal_entry where id = new.journal_id;
  if not bnx.restore_mode() and (x is null or x <> pg_current_xact_id()) then
    raise exception 'LATE_LINE: journal % was created in another transaction (INV-07)', new.journal_id using errcode = 'P0422';
  end if;
  if not bnx.restore_mode() then new.created_xid := pg_current_xact_id(); end if;
  return new;
end $$;


ALTER FUNCTION bnx.trg_line_same_txn() OWNER TO bnx_definer;

--
-- Name: trg_ownership_share_total(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_ownership_share_total() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare d date; total numeric;
begin
  for d in select distinct effective_from from bnx.account_ownership_event
            where account_id = new.account_id and kind = new.kind and recorded_version <= new.recorded_version loop
    select coalesce(sum(share), 0) into total from bnx.ownership_at(new.account_id, d, new.recorded_version) where kind = new.kind;
    if total > 100 then
      raise exception 'OWNERSHIP_OVER_100: account % kind % on % totals % at version %', new.account_id, new.kind, d, total,
        new.recorded_version using errcode = 'P0422';
    end if;
  end loop;
  return null;
end $$;


ALTER FUNCTION bnx.trg_ownership_share_total() OWNER TO bnx_definer;

--
-- Name: trg_retired(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_retired() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
begin raise exception 'RETIRED_TABLE: % is read-only history; use bnx.source_link_event', tg_table_name using errcode = 'P0409'; end $$;


ALTER FUNCTION bnx.trg_retired() OWNER TO bnx_definer;

--
-- Name: trg_scale(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_scale() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare cur char(3);
begin
  if tg_table_name = 'source_txn' then perform bnx.assert_scale(new.amount, new.currency, 'source_txn.amount');
  elsif tg_table_name = 'statement' then
    perform bnx.assert_scale(new.opening_balance, new.currency, 'statement.opening_balance');
    perform bnx.assert_scale(new.closing_balance, new.currency, 'statement.closing_balance');
  elsif tg_table_name = 'clearing_item' then perform bnx.assert_scale(new.amount, new.currency, 'clearing_item.amount');
  elsif tg_table_name = 'opening_anchor_version' then
    select currency into cur from bnx.account_currency where id = new.account_currency_id;
    perform bnx.assert_scale(new.amount, cur, 'opening_anchor.amount');
  elsif tg_table_name = 'journal_entry' then
    perform bnx.assert_scale(new.original_amount, new.original_currency, 'journal.original_amount');
  end if;
  return new;
end $$;


ALTER FUNCTION bnx.trg_scale() OWNER TO bnx_definer;

--
-- Name: trg_source_link_transition(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.trg_source_link_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare last record; holder uuid;
begin
  -- restore: rows and the derived current-link table are reloaded verbatim from the verified dump (AUD-050)
  if bnx.restore_mode() then return new; end if;
  select event_id, event into last from bnx.source_link_event
   where source_txn_id = new.source_txn_id and journal_id = new.journal_id order by event_id desc limit 1;
  if (last.event is null and new.event = 'released')
     or (last.event = 'reserved' and new.event = 'reserved')
     or (last.event = 'linked' and new.event in ('reserved','linked'))
     or (last.event = 'released' and new.event = 'released') then
    raise exception 'SOURCE_LINK_TRANSITION: % -> % for source % journal %', coalesce(last.event,'none'), new.event,
      new.source_txn_id, new.journal_id using errcode = 'P0409';
  end if;
  new.prior_event_id := last.event_id;
  if new.event in ('reserved','linked') then
    select journal_id into holder from bnx.source_txn_current_link where source_txn_id = new.source_txn_id for update;
    if holder is not null and holder <> new.journal_id then
      raise exception 'SOURCE_TXN_ALREADY_LINKED: source % held by journal %', new.source_txn_id, holder using errcode = 'P0409';
    end if;
    insert into bnx.source_txn_current_link values (new.source_txn_id, new.journal_id)
      on conflict (source_txn_id) do nothing;
  else
    delete from bnx.source_txn_current_link where source_txn_id = new.source_txn_id and journal_id = new.journal_id;
  end if;
  return new;
end $$;


ALTER FUNCTION bnx.trg_source_link_transition() OWNER TO bnx_definer;

--
-- Name: visible_account_currency_ids(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.visible_account_currency_ids(p_member uuid) RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select ac.id from bnx.account_currency ac
    join bnx.account_grant g on g.account_id = ac.account_id and g.member_id = p_member and g.can_view
    join bnx.member m on m.id = p_member and m.state = 'active'
$$;


ALTER FUNCTION bnx.visible_account_currency_ids(p_member uuid) OWNER TO bnx_definer;

--
-- Name: visible_at(bigint); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.visible_at(p_v bigint) RETURNS TABLE(journal_id uuid, visible_version bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select je.id, je.ledger_version
    from bnx.journal_entry je
   where je.ledger_version is not null and je.ledger_version <= p_v
  union all
  select je.id, ev.recorded_version
    from bnx.journal_entry je
    join bnx.posting_batch_event ev
      on ev.batch_id = je.posting_batch_id and ev.event = 'activated' and ev.recorded_version <= p_v
$$;


ALTER FUNCTION bnx.visible_at(p_v bigint) OWNER TO bnx_definer;

--
-- Name: wrk_activate_plan(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_activate_plan(p_plan uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.wrk_activate_plan(p_plan uuid) OWNER TO bnx_definer;

--
-- Name: wrk_claim(integer); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_claim(p_max integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.wrk_claim(p_max integer) OWNER TO bnx_definer;

--
-- Name: wrk_complete(bigint, boolean); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_complete(p_id bigint, p_ok boolean) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  update bnx.work_item set state = case when p_ok then 'done' when attempts >= 5 then 'dead' else 'queued' end,
         lease_until = null where id = p_id
$$;


ALTER FUNCTION bnx.wrk_complete(p_id bigint, p_ok boolean) OWNER TO bnx_definer;

--
-- Name: wrk_post_plan_chunk(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_post_plan_chunk(p_plan uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.wrk_post_plan_chunk(p_plan uuid) OWNER TO bnx_definer;

--
-- Name: wrk_queue_status(); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_queue_status() RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
  select jsonb_build_object('generation', q.generation, 'drained_generation', q.drained_generation,
         'queued', (select count(*) from bnx.work_item where state = 'queued' or (state = 'leased' and lease_until < now())))
    from bnx.queue_state q
$$;


ALTER FUNCTION bnx.wrk_queue_status() OWNER TO bnx_definer;

--
-- Name: wrk_record_archive_event(uuid, text, text, text); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
declare o record; s int; obs bytea := case when p_sha_hex is null then null else decode(p_sha_hex, 'hex') end;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into o from bnx.evidence_object where id = p_object for update;
  if not found then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  select coalesce(max(seq), 0) + 1 into s from bnx.evidence_archive_event where evidence_object_id = p_object;
  if p_event = 'verified' and (o.sha256 is null or obs is distinct from o.sha256) then
    insert into bnx.evidence_archive_event values (p_object, s, 'failed', p_drive_file, obs, jsonb_build_object('reason', 'hash_mismatch'), now());
    update bnx.evidence_object set archive_state = 'archive_failed' where id = p_object and archive_state <> 'dual_verified';
    insert into bnx.outbox(topic, payload) values ('archive.failed', jsonb_build_object('evidence_object_id', p_object, 'reason', 'hash_mismatch'));
    return 'archive_failed';
  end if;
  insert into bnx.evidence_archive_event values (p_object, s, p_event, p_drive_file, obs, null, now());
  update bnx.evidence_object set archive_state = case p_event when 'queued' then 'archive_pending' when 'copied' then 'archive_pending'
      when 'verified' then 'dual_verified' when 'failed' then 'archive_failed' else archive_state end
   where id = p_object;
  if p_event = 'failed' then
    insert into bnx.outbox(topic, payload) values ('archive.failed', jsonb_build_object('evidence_object_id', p_object));
  end if;
  return (select archive_state from bnx.evidence_object where id = p_object);
end $$;


ALTER FUNCTION bnx.wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text) OWNER TO bnx_definer;

--
-- Name: wrk_revalidate_plan(uuid); Type: FUNCTION; Schema: bnx; Owner: bnx_definer
--

CREATE FUNCTION bnx.wrk_revalidate_plan(p_plan uuid) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
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


ALTER FUNCTION bnx.wrk_revalidate_plan(p_plan uuid) OWNER TO bnx_definer;

--
-- Name: future_identity_link; Type: TABLE; Schema: auth; Owner: bnx_auth
--

CREATE TABLE auth.future_identity_link (
    id integer NOT NULL,
    provider text NOT NULL
);


ALTER TABLE auth.future_identity_link OWNER TO bnx_auth;

--
-- Name: future_identity_link_id_seq; Type: SEQUENCE; Schema: auth; Owner: bnx_auth
--

CREATE SEQUENCE auth.future_identity_link_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE auth.future_identity_link_id_seq OWNER TO bnx_auth;

--
-- Name: future_identity_link_id_seq; Type: SEQUENCE OWNED BY; Schema: auth; Owner: bnx_auth
--

ALTER SEQUENCE auth.future_identity_link_id_seq OWNED BY auth.future_identity_link.id;


--
-- Name: account; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account (
    id uuid NOT NULL,
    kind text NOT NULL,
    institution_id uuid,
    label text NOT NULL,
    reference_kind text NOT NULL,
    reference_display text,
    visibility text NOT NULL,
    timezone text NOT NULL,
    origin text NOT NULL,
    state text NOT NULL,
    merged_into uuid,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_check CHECK (((kind = ANY (ARRAY['cash'::text, 'other_asset'::text])) OR (institution_id IS NOT NULL))),
    CONSTRAINT account_kind_check CHECK ((kind = ANY (ARRAY['bank_deposit'::text, 'cash'::text, 'e_wallet'::text, 'credit_card'::text, 'investment'::text, 'loan_payable'::text, 'loan_receivable'::text, 'other_asset'::text]))),
    CONSTRAINT account_origin_check CHECK ((origin = ANY (ARRAY['manual'::text, 'discovered'::text]))),
    CONSTRAINT account_reference_kind_check CHECK ((reference_kind = ANY (ARRAY['masked_number'::text, 'managed'::text, 'none'::text]))),
    CONSTRAINT account_state_check CHECK ((state = ANY (ARRAY['active'::text, 'closed'::text, 'merged_into'::text]))),
    CONSTRAINT account_visibility_check CHECK ((visibility = ANY (ARRAY['household'::text, 'private'::text])))
);


ALTER TABLE bnx.account OWNER TO bnx_definer;

--
-- Name: account_currency; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account_currency (
    id uuid NOT NULL,
    account_id uuid NOT NULL,
    currency character(3) NOT NULL,
    ledger_account_id uuid NOT NULL
);


ALTER TABLE bnx.account_currency OWNER TO bnx_definer;

--
-- Name: account_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account_event (
    account_id uuid NOT NULL,
    seq integer NOT NULL,
    event text NOT NULL,
    payload jsonb NOT NULL,
    recorded_version bigint NOT NULL,
    actor uuid NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_event_event_check CHECK ((event = ANY (ARRAY['created'::text, 'label_changed'::text, 'visibility_changed'::text, 'state_changed'::text])))
);


ALTER TABLE bnx.account_event OWNER TO bnx_definer;

--
-- Name: account_grant; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account_grant (
    member_id uuid NOT NULL,
    account_id uuid NOT NULL,
    can_view boolean NOT NULL,
    can_post boolean NOT NULL,
    granted_by uuid NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT account_grant_check CHECK ((can_view OR (NOT can_post)))
);


ALTER TABLE bnx.account_grant OWNER TO bnx_definer;

--
-- Name: account_ownership_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account_ownership_event (
    id uuid NOT NULL,
    account_id uuid NOT NULL,
    party_id uuid NOT NULL,
    kind text NOT NULL,
    event text NOT NULL,
    share numeric(7,4),
    effective_from date NOT NULL,
    evidence_kind text NOT NULL,
    evidence_ref jsonb,
    recorded_version bigint NOT NULL,
    actor uuid NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    event_seq bigint NOT NULL,
    CONSTRAINT account_ownership_event_check CHECK (((event = 'ended'::text) = (share IS NULL))),
    CONSTRAINT account_ownership_event_event_check CHECK ((event = ANY (ARRAY['set'::text, 'ended'::text]))),
    CONSTRAINT account_ownership_event_evidence_kind_check CHECK ((evidence_kind = ANY (ARRAY['statement_header'::text, 'member_declared'::text, 'owner_confirmed'::text, 'document'::text]))),
    CONSTRAINT account_ownership_event_kind_check CHECK ((kind = ANY (ARRAY['legal_owner'::text, 'beneficial_owner'::text]))),
    CONSTRAINT account_ownership_event_share_check CHECK (((share IS NULL) OR ((share > (0)::numeric) AND (share <= (100)::numeric))))
);


ALTER TABLE bnx.account_ownership_event OWNER TO bnx_definer;

--
-- Name: account_ownership_event_event_seq_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.account_ownership_event ALTER COLUMN event_seq ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.account_ownership_event_event_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: account_scope_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.account_scope_event (
    id uuid NOT NULL,
    account_id uuid NOT NULL,
    ownership_scope text NOT NULL,
    effective_from date NOT NULL,
    recorded_version bigint NOT NULL,
    actor uuid NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    event_seq bigint NOT NULL,
    CONSTRAINT account_scope_event_ownership_scope_check CHECK ((ownership_scope = ANY (ARRAY['individual'::text, 'joint'::text, 'corporate'::text])))
);


ALTER TABLE bnx.account_scope_event OWNER TO bnx_definer;

--
-- Name: account_scope_event_event_seq_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.account_scope_event ALTER COLUMN event_seq ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.account_scope_event_event_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ai_connection; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.ai_connection (
    id uuid NOT NULL,
    member_id uuid NOT NULL,
    client_id text NOT NULL,
    scopes text[] NOT NULL,
    account_currency_ids uuid[] NOT NULL,
    approved_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT ai_connection_scopes_check CHECK ((scopes <@ ARRAY['read'::text, 'propose'::text]))
);


ALTER TABLE bnx.ai_connection OWNER TO bnx_definer;

--
-- Name: ai_connection_token; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.ai_connection_token (
    token_sha256 bytea NOT NULL,
    connection_id uuid NOT NULL,
    kind text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT ai_connection_token_kind_check CHECK ((kind = ANY (ARRAY['access'::text, 'refresh'::text])))
);


ALTER TABLE bnx.ai_connection_token OWNER TO bnx_definer;

--
-- Name: audit_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.audit_event (
    seq bigint NOT NULL,
    at timestamp with time zone DEFAULT now() NOT NULL,
    member_id uuid,
    connection_id uuid,
    channel text NOT NULL,
    command text NOT NULL,
    subject jsonb NOT NULL,
    payload_sha256 bytea NOT NULL,
    ledger_version bigint,
    prev_hash bytea,
    hash bytea NOT NULL
);


ALTER TABLE bnx.audit_event OWNER TO bnx_definer;

--
-- Name: balance_checkpoint; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.balance_checkpoint (
    id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    as_of date NOT NULL,
    amount numeric(20,4) NOT NULL,
    kind text NOT NULL,
    evidence jsonb,
    recorded_by uuid NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT balance_checkpoint_kind_check CHECK ((kind = ANY (ARRAY['member_spot_check'::text, 'cash_count'::text, 'superseded_anchor'::text])))
);


ALTER TABLE bnx.balance_checkpoint OWNER TO bnx_definer;

--
-- Name: bridge_acceptance; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.bridge_acceptance (
    plan_id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    amount numeric(20,4) NOT NULL,
    accepted_by uuid NOT NULL,
    recorded_version bigint NOT NULL
);


ALTER TABLE bnx.bridge_acceptance OWNER TO bnx_definer;

--
-- Name: category_version; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.category_version (
    category_id uuid NOT NULL,
    valid_from_version bigint NOT NULL,
    parent_id uuid,
    name_en text NOT NULL,
    name_zh text NOT NULL,
    state text NOT NULL,
    CONSTRAINT category_version_state_check CHECK ((state = ANY (ARRAY['active'::text, 'retired'::text])))
);


ALTER TABLE bnx.category_version OWNER TO bnx_definer;

--
-- Name: clearing_item; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.clearing_item (
    id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    currency character(3) NOT NULL,
    kind text NOT NULL,
    amount numeric(20,4) NOT NULL,
    origin_source_txn uuid,
    counterpart_hint jsonb,
    opened_journal uuid NOT NULL,
    CONSTRAINT clearing_item_kind_check CHECK ((kind = ANY (ARRAY['transfer_in_transit'::text, 'unclassified_movement'::text])))
);


ALTER TABLE bnx.clearing_item OWNER TO bnx_definer;

--
-- Name: clearing_item_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.clearing_item_event (
    clearing_item_id uuid NOT NULL,
    seq integer NOT NULL,
    event text NOT NULL,
    resolved_by_journal uuid,
    recorded_version bigint NOT NULL,
    CONSTRAINT clearing_item_event_event_check CHECK ((event = ANY (ARRAY['opened'::text, 'resolved'::text])))
);


ALTER TABLE bnx.clearing_item_event OWNER TO bnx_definer;

--
-- Name: currency; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.currency (
    code character(3) NOT NULL,
    minor_units smallint NOT NULL,
    CONSTRAINT currency_iso CHECK ((code ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT currency_minor_units_check CHECK (((minor_units >= 0) AND (minor_units <= 4)))
);


ALTER TABLE bnx.currency OWNER TO bnx_definer;

--
-- Name: document; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.document (
    id uuid NOT NULL,
    evidence_object_id uuid NOT NULL,
    seq integer NOT NULL,
    page_from integer,
    page_to integer,
    doc_type text NOT NULL,
    issue_date date,
    CONSTRAINT document_doc_type_check CHECK ((doc_type = ANY (ARRAY['bank_statement'::text, 'card_statement'::text, 'investment_statement'::text, 'not_statement'::text, 'unknown'::text])))
);


ALTER TABLE bnx.document OWNER TO bnx_definer;

--
-- Name: evidence_access_grant; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.evidence_access_grant (
    evidence_file_id uuid NOT NULL,
    member_id uuid NOT NULL,
    basis text NOT NULL,
    reason text NOT NULL,
    granted_by uuid NOT NULL,
    granted_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT evidence_access_grant_basis_check CHECK ((basis = 'owner_t3'::text)),
    CONSTRAINT evidence_access_grant_check CHECK ((expires_at <= (granted_at + '7 days'::interval)))
);


ALTER TABLE bnx.evidence_access_grant OWNER TO bnx_definer;

--
-- Name: evidence_access_log; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.evidence_access_log (
    id bigint NOT NULL,
    evidence_file_id uuid NOT NULL,
    member_id uuid,
    purpose text NOT NULL,
    decision text NOT NULL,
    url_expires_at timestamp with time zone,
    at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT evidence_access_log_decision_check CHECK ((decision = ANY (ARRAY['granted'::text, 'denied'::text])))
);


ALTER TABLE bnx.evidence_access_log OWNER TO bnx_definer;

--
-- Name: evidence_access_log_id_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

CREATE SEQUENCE bnx.evidence_access_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE bnx.evidence_access_log_id_seq OWNER TO bnx_definer;

--
-- Name: evidence_access_log_id_seq; Type: SEQUENCE OWNED BY; Schema: bnx; Owner: bnx_definer
--

ALTER SEQUENCE bnx.evidence_access_log_id_seq OWNED BY bnx.evidence_access_log.id;


--
-- Name: evidence_archive_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.evidence_archive_event (
    evidence_object_id uuid NOT NULL,
    seq integer NOT NULL,
    event text NOT NULL,
    drive_file_id text,
    sha256_observed bytea,
    detail jsonb,
    at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT evidence_archive_event_event_check CHECK ((event = ANY (ARRAY['queued'::text, 'copied'::text, 'verified'::text, 'failed'::text, 'retry_scheduled'::text, 'primary_missing'::text])))
);


ALTER TABLE bnx.evidence_archive_event OWNER TO bnx_definer;

--
-- Name: evidence_file; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.evidence_file (
    id uuid NOT NULL,
    evidence_object_id uuid NOT NULL,
    sha256_declared bytea,
    size_declared bigint NOT NULL,
    mime text NOT NULL,
    original_name text,
    acquired_via text NOT NULL,
    acquired_by uuid NOT NULL,
    storage_state text NOT NULL,
    assigned_account_currency_id uuid,
    superseded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT evidence_file_acquired_via_check CHECK ((acquired_via = ANY (ARRAY['pwa_upload'::text, 'drive_selection'::text, 'chat_file'::text]))),
    CONSTRAINT evidence_file_storage_state_check CHECK ((storage_state = ANY (ARRAY['upload_pending'::text, 'stored'::text, 'archived'::text, 'upload_failed'::text, 'expired'::text, 'archive_failed'::text])))
);


ALTER TABLE bnx.evidence_file OWNER TO bnx_definer;

--
-- Name: evidence_object; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.evidence_object (
    id uuid NOT NULL,
    r2_key text NOT NULL,
    size_bytes bigint NOT NULL,
    md5_etag text,
    sha256 bytea,
    integrity_state text NOT NULL,
    verified_by_execution text,
    verified_at timestamp with time zone,
    dedup_into uuid,
    archive_state text DEFAULT 'single_copy'::text NOT NULL,
    single_copy_since timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT evidence_object_archive_state_check CHECK ((archive_state = ANY (ARRAY['single_copy'::text, 'archive_pending'::text, 'dual_verified'::text, 'archive_failed'::text]))),
    CONSTRAINT evidence_object_check CHECK (((integrity_state <> 'verified'::text) OR (sha256 IS NOT NULL))),
    CONSTRAINT evidence_object_integrity_state_check CHECK ((integrity_state = ANY (ARRAY['unverified'::text, 'verified'::text, 'failed'::text])))
);


ALTER TABLE bnx.evidence_object OWNER TO bnx_definer;

--
-- Name: fx_override_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.fx_override_event (
    id uuid NOT NULL,
    base character(3) NOT NULL,
    quote character(3) NOT NULL,
    rate_date date NOT NULL,
    rate numeric(28,10) NOT NULL,
    reason text NOT NULL,
    actor uuid NOT NULL,
    recorded_version bigint NOT NULL,
    CONSTRAINT fx_override_event_rate_check CHECK ((rate > (0)::numeric))
);


ALTER TABLE bnx.fx_override_event OWNER TO bnx_definer;

--
-- Name: fx_selection_log; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.fx_selection_log (
    id uuid NOT NULL,
    base character(3) NOT NULL,
    quote character(3) NOT NULL,
    rate_date date NOT NULL,
    rate numeric(28,10) NOT NULL,
    provider text NOT NULL,
    fetched_at timestamp with time zone NOT NULL,
    recorded_version bigint NOT NULL,
    CONSTRAINT fx_selection_log_rate_check CHECK ((rate > (0)::numeric))
);


ALTER TABLE bnx.fx_selection_log OWNER TO bnx_definer;

--
-- Name: household_setting; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.household_setting (
    key text NOT NULL,
    value jsonb NOT NULL,
    set_by uuid NOT NULL,
    set_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT household_setting_key_check CHECK ((key = 'require_dual_copy_before_approval'::text))
);


ALTER TABLE bnx.household_setting OWNER TO bnx_definer;

--
-- Name: idempotency; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.idempotency (
    member_id uuid NOT NULL,
    idem_key text NOT NULL,
    command text NOT NULL,
    request_sha256 bytea NOT NULL,
    receipt jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE bnx.idempotency OWNER TO bnx_definer;

--
-- Name: institution; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.institution (
    id uuid NOT NULL,
    name_en text,
    name_zh text,
    country character(2),
    bic text,
    created_by uuid
);


ALTER TABLE bnx.institution OWNER TO bnx_definer;

--
-- Name: journal_correction; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.journal_correction (
    original_journal_id uuid NOT NULL,
    reversal_journal_id uuid NOT NULL,
    replacement_journal_id uuid,
    reason text NOT NULL,
    recorded_version bigint NOT NULL
);


ALTER TABLE bnx.journal_correction OWNER TO bnx_definer;

--
-- Name: journal_entry; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.journal_entry (
    id uuid NOT NULL,
    entry_no bigint NOT NULL,
    economic_type bnx.economic_type NOT NULL,
    transaction_date date NOT NULL,
    posting_date date NOT NULL,
    posting_date_status bnx.posting_date_status NOT NULL,
    description text NOT NULL,
    original_amount numeric(20,4),
    original_currency character(3),
    settled_rate numeric(28,10),
    ledger_version bigint,
    posting_batch_id uuid,
    approval_plan_id uuid,
    source_proposal_id uuid,
    origin_channel text NOT NULL,
    created_by_member uuid NOT NULL,
    confirmed_by_member uuid NOT NULL,
    created_via_connection uuid,
    created_xid xid8 DEFAULT pg_current_xact_id() NOT NULL,
    CONSTRAINT journal_entry_check CHECK (((ledger_version IS NULL) <> (posting_batch_id IS NULL))),
    CONSTRAINT journal_entry_origin_channel_check CHECK ((origin_channel = ANY (ARRAY['pwa'::text, 'plan'::text, 'system_opening'::text]))),
    CONSTRAINT journal_original_pair CHECK ((((original_amount IS NULL) = (original_currency IS NULL)) AND ((settled_rate IS NULL) OR ((original_amount IS NOT NULL) AND (settled_rate > (0)::numeric)))))
);


ALTER TABLE bnx.journal_entry OWNER TO bnx_definer;

--
-- Name: journal_entry_entry_no_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

CREATE SEQUENCE bnx.journal_entry_entry_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE bnx.journal_entry_entry_no_seq OWNER TO bnx_definer;

--
-- Name: journal_entry_entry_no_seq; Type: SEQUENCE OWNED BY; Schema: bnx; Owner: bnx_definer
--

ALTER SEQUENCE bnx.journal_entry_entry_no_seq OWNED BY bnx.journal_entry.entry_no;


--
-- Name: journal_line; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.journal_line (
    id uuid NOT NULL,
    journal_id uuid NOT NULL,
    ledger_account_id uuid NOT NULL,
    currency character(3) NOT NULL,
    amount numeric(20,4) NOT NULL,
    clearing_item_id uuid,
    created_xid xid8 DEFAULT pg_current_xact_id() NOT NULL,
    CONSTRAINT journal_line_amount_check CHECK ((amount <> (0)::numeric))
);


ALTER TABLE bnx.journal_line OWNER TO bnx_definer;

--
-- Name: journal_source; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.journal_source (
    journal_id uuid NOT NULL,
    source_txn_id uuid NOT NULL,
    role text NOT NULL,
    CONSTRAINT journal_source_role_check CHECK ((role = ANY (ARRAY['origin'::text, 'counterpart'::text, 'matched_confirmation'::text])))
);


ALTER TABLE bnx.journal_source OWNER TO bnx_definer;

--
-- Name: ledger_account; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.ledger_account (
    id uuid NOT NULL,
    kind text NOT NULL,
    currency character(3) NOT NULL,
    name text NOT NULL,
    CONSTRAINT ledger_account_kind_check CHECK ((kind = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text, 'income'::text, 'expense'::text, 'fx_trading'::text, 'clearing'::text])))
);


ALTER TABLE bnx.ledger_account OWNER TO bnx_definer;

--
-- Name: ledger_state; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.ledger_state (
    singleton boolean DEFAULT true NOT NULL,
    version bigint NOT NULL,
    CONSTRAINT ledger_state_singleton_check CHECK (singleton)
);


ALTER TABLE bnx.ledger_state OWNER TO bnx_definer;

--
-- Name: m1_future_fact; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.m1_future_fact (
    id bigint NOT NULL,
    note text NOT NULL
);


ALTER TABLE bnx.m1_future_fact OWNER TO bnx_definer;

--
-- Name: m1_future_fact_id_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.m1_future_fact ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.m1_future_fact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: match_decision_current; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.match_decision_current (
    source_txn_id uuid NOT NULL,
    kind text NOT NULL,
    decision_event_id uuid NOT NULL,
    journal_line_id uuid
);


ALTER TABLE bnx.match_decision_current OWNER TO bnx_definer;

--
-- Name: match_decision_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.match_decision_event (
    id uuid NOT NULL,
    source_txn_id uuid NOT NULL,
    kind text NOT NULL,
    decision text NOT NULL,
    counterpart_source_txn uuid,
    journal_line_id uuid,
    clearing_item_id uuid,
    rule_code text NOT NULL,
    evidence jsonb NOT NULL,
    supersedes uuid,
    decided_by uuid,
    recorded_version bigint NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT match_decision_event_decision_check CHECK ((decision = ANY (ARRAY['proposed'::text, 'confirmed'::text, 'rejected'::text, 'superseded'::text]))),
    CONSTRAINT match_decision_event_kind_check CHECK ((kind = ANY (ARRAY['overlap'::text, 'ledger'::text, 'transfer_pair'::text, 'clearing_resolution'::text, 'duplicate_document'::text, 'exclude'::text])))
);


ALTER TABLE bnx.match_decision_event OWNER TO bnx_definer;

--
-- Name: member; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.member (
    id uuid NOT NULL,
    display_name text NOT NULL,
    role text NOT NULL,
    state text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT member_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text, 'viewer'::text]))),
    CONSTRAINT member_state_check CHECK ((state = ANY (ARRAY['active'::text, 'suspended'::text, 'removed'::text])))
);


ALTER TABLE bnx.member OWNER TO bnx_definer;

--
-- Name: member_identity; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.member_identity (
    iss text NOT NULL,
    sub text NOT NULL,
    member_id uuid NOT NULL
);


ALTER TABLE bnx.member_identity OWNER TO bnx_definer;

--
-- Name: member_session; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.member_session (
    id uuid NOT NULL,
    member_id uuid NOT NULL,
    token_sha256 bytea NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    absolute_expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone
);


ALTER TABLE bnx.member_session OWNER TO bnx_definer;

--
-- Name: oauth_client; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.oauth_client (
    client_id text NOT NULL,
    display_name text NOT NULL,
    redirect_uris text[] NOT NULL
);


ALTER TABLE bnx.oauth_client OWNER TO bnx_definer;

--
-- Name: oauth_code; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.oauth_code (
    code_sha256 bytea NOT NULL,
    connection_id uuid NOT NULL,
    pkce_challenge text NOT NULL,
    redirect_uri text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone
);


ALTER TABLE bnx.oauth_code OWNER TO bnx_definer;

--
-- Name: opening_anchor; Type: VIEW; Schema: bnx; Owner: bnx_definer
--

CREATE VIEW bnx.opening_anchor AS
 SELECT DISTINCT ON (account_currency_id) id,
    account_currency_id,
    anchor_date,
    amount,
    journal_id,
    reversed_journal_id,
    source,
    certainty,
    evidence,
    revision,
    installed_by_plan,
    bridge_difference,
    reason,
    valid_from_version,
    recorded_by,
    recorded_at
   FROM bnx.opening_anchor_version
  ORDER BY account_currency_id, valid_from_version DESC;


ALTER VIEW bnx.opening_anchor OWNER TO bnx_definer;

--
-- Name: outbox; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.outbox (
    id bigint NOT NULL,
    topic text NOT NULL,
    payload jsonb NOT NULL,
    created_version bigint,
    state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT outbox_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'delivered'::text, 'dead'::text])))
);


ALTER TABLE bnx.outbox OWNER TO bnx_definer;

--
-- Name: outbox_id_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.outbox ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.outbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: party; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.party (
    id uuid NOT NULL,
    kind text NOT NULL,
    display_name text NOT NULL,
    normalized_name text NOT NULL,
    aliases text[] DEFAULT '{}'::text[] NOT NULL,
    member_id uuid,
    created_by uuid NOT NULL,
    CONSTRAINT party_kind_check CHECK ((kind = ANY (ARRAY['person'::text, 'organization'::text])))
);


ALTER TABLE bnx.party OWNER TO bnx_definer;

--
-- Name: plan_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.plan_event (
    plan_id uuid NOT NULL,
    seq integer NOT NULL,
    event text NOT NULL,
    from_version bigint,
    to_version bigint,
    delta_digest bytea,
    diff jsonb,
    actor uuid,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT plan_event_event_check CHECK ((event = ANY (ARRAY['frozen'::text, 'approved'::text, 'rebased'::text, 'stale'::text, 'suspended'::text, 'superseded'::text, 'activated'::text, 'voided'::text])))
);


ALTER TABLE bnx.plan_event OWNER TO bnx_definer;

--
-- Name: posting_batch; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_batch (
    id uuid NOT NULL,
    plan_id uuid NOT NULL,
    state text NOT NULL,
    activated_version bigint,
    activated_at timestamp with time zone,
    activated_by uuid,
    void_reason text,
    CONSTRAINT posting_batch_state_check CHECK ((state = ANY (ARRAY['open'::text, 'sealed'::text, 'active'::text, 'void'::text])))
);


ALTER TABLE bnx.posting_batch OWNER TO bnx_definer;

--
-- Name: posting_batch_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_batch_event (
    batch_id uuid NOT NULL,
    event text NOT NULL,
    recorded_version bigint NOT NULL,
    actor uuid,
    reason text,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT posting_batch_event_check CHECK ((NOT ((event = 'activated'::text) AND (recorded_version IS NULL)))),
    CONSTRAINT posting_batch_event_event_check CHECK ((event = ANY (ARRAY['opened'::text, 'sealed'::text, 'activated'::text, 'voided'::text])))
);


ALTER TABLE bnx.posting_batch_event OWNER TO bnx_definer;

--
-- Name: posting_date_confirmation; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_date_confirmation (
    journal_id uuid NOT NULL,
    seq integer NOT NULL,
    confirmed_posting_date date NOT NULL,
    source text NOT NULL,
    evidence jsonb,
    recorded_version bigint NOT NULL,
    actor uuid,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT posting_date_confirmation_source_check CHECK ((source = ANY (ARRAY['statement'::text, 'member'::text])))
);


ALTER TABLE bnx.posting_date_confirmation OWNER TO bnx_definer;

--
-- Name: posting_plan; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_plan (
    id uuid NOT NULL,
    kind text NOT NULL,
    job_id uuid,
    scope jsonb NOT NULL,
    item_count integer NOT NULL,
    control_totals jsonb NOT NULL,
    anchor_changes jsonb DEFAULT '[]'::jsonb NOT NULL,
    bridge_results jsonb DEFAULT '{}'::jsonb NOT NULL,
    clearing_defaults jsonb DEFAULT '{}'::jsonb NOT NULL,
    plan_hash bytea NOT NULL,
    state text NOT NULL,
    frozen_at_version bigint,
    last_validated_version bigint,
    scope_digest bytea,
    supersedes_plan_id uuid,
    approved_by uuid,
    approved_at timestamp with time zone,
    approval_tier text,
    accepted_bridge_differences jsonb,
    auto_activate boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT posting_plan_kind_check CHECK ((kind = ANY (ARRAY['import'::text, 'onboarding_scope'::text, 'reclassification'::text, 'account_merge_repost'::text]))),
    CONSTRAINT posting_plan_state_check CHECK ((state = ANY (ARRAY['draft'::text, 'frozen'::text, 'approved'::text, 'executing'::text, 'sealed'::text, 'activated'::text, 'superseded'::text, 'stale'::text, 'suspended'::text, 'void'::text])))
);


ALTER TABLE bnx.posting_plan OWNER TO bnx_definer;

--
-- Name: posting_plan_item; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_plan_item (
    plan_id uuid NOT NULL,
    seq integer NOT NULL,
    kind text NOT NULL,
    source_txn_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    payload jsonb NOT NULL,
    payload_sha256 bytea NOT NULL,
    chunk_no integer NOT NULL,
    posted_journal_id uuid,
    CONSTRAINT posting_plan_item_kind_check CHECK ((kind = ANY (ARRAY['new_journal'::text, 'ledger_match'::text, 'transfer_pair'::text, 'clearing_post'::text, 'clearing_resolution'::text, 'correction_reversal'::text, 'correction_replacement'::text])))
);


ALTER TABLE bnx.posting_plan_item OWNER TO bnx_definer;

--
-- Name: posting_scope_claim; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.posting_scope_claim (
    plan_id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    during daterange NOT NULL,
    claim_state text NOT NULL,
    created_version bigint NOT NULL,
    released_version bigint,
    CONSTRAINT posting_scope_claim_claim_state_check CHECK ((claim_state = ANY (ARRAY['held'::text, 'released'::text])))
);


ALTER TABLE bnx.posting_scope_claim OWNER TO bnx_definer;

--
-- Name: queue_state; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.queue_state (
    singleton boolean DEFAULT true NOT NULL,
    generation bigint NOT NULL,
    drained_generation bigint NOT NULL,
    CONSTRAINT queue_state_singleton_check CHECK (singleton)
);


ALTER TABLE bnx.queue_state OWNER TO bnx_definer;

--
-- Name: report_snapshot; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.report_snapshot (
    id uuid NOT NULL,
    report_code text NOT NULL,
    filters_digest bytea NOT NULL,
    ledger_version bigint NOT NULL,
    report_definition_version text NOT NULL,
    fx_policy jsonb NOT NULL,
    valuation_cutoff date,
    content_account_currency_ids uuid[] NOT NULL,
    content_sha256 bytea NOT NULL,
    projection_actor uuid NOT NULL,
    projection_account_currency_ids uuid[] NOT NULL,
    projection_sha256 bytea NOT NULL,
    canonicalization text DEFAULT 'RFC8785-JCS/rows-sorted-by-key'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    projection_channel text,
    projection_connection_id uuid,
    projection_requested_acs uuid[],
    filters jsonb
);


ALTER TABLE bnx.report_snapshot OWNER TO bnx_definer;

--
-- Name: schema_bootstrap; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.schema_bootstrap (
    version text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by_session text DEFAULT SESSION_USER NOT NULL
);


ALTER TABLE bnx.schema_bootstrap OWNER TO bnx_definer;

--
-- Name: schema_migrations; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.schema_migrations (
    version text NOT NULL,
    sha256 text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by_session text DEFAULT SESSION_USER NOT NULL
);


ALTER TABLE bnx.schema_migrations OWNER TO bnx_definer;

--
-- Name: source_link_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.source_link_event (
    event_id bigint NOT NULL,
    source_txn_id uuid NOT NULL,
    journal_id uuid NOT NULL,
    event text NOT NULL,
    prior_event_id bigint,
    batch_id uuid,
    recorded_version bigint NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT source_link_event_event_check CHECK ((event = ANY (ARRAY['reserved'::text, 'linked'::text, 'released'::text])))
);


ALTER TABLE bnx.source_link_event OWNER TO bnx_definer;

--
-- Name: source_link_event_event_id_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.source_link_event ALTER COLUMN event_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.source_link_event_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: source_txn; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.source_txn (
    id uuid NOT NULL,
    account_currency_id uuid NOT NULL,
    posting_date date NOT NULL,
    transaction_date date,
    amount numeric(20,4) NOT NULL,
    currency character(3) NOT NULL,
    normalized_description text,
    bank_ref text,
    canonical_occurrence integer NOT NULL,
    source_fingerprint bytea NOT NULL
);


ALTER TABLE bnx.source_txn OWNER TO bnx_definer;

--
-- Name: source_txn_current_link; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.source_txn_current_link (
    source_txn_id uuid NOT NULL,
    journal_id uuid NOT NULL
);


ALTER TABLE bnx.source_txn_current_link OWNER TO bnx_definer;

--
-- Name: source_txn_link_event_d04_retired; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.source_txn_link_event_d04_retired (
    source_txn_id uuid NOT NULL,
    journal_id uuid NOT NULL,
    event text NOT NULL,
    batch_id uuid,
    recorded_version bigint NOT NULL,
    CONSTRAINT source_txn_link_event_event_check CHECK ((event = ANY (ARRAY['reserved'::text, 'linked'::text, 'released'::text])))
);


ALTER TABLE bnx.source_txn_link_event_d04_retired OWNER TO bnx_definer;

--
-- Name: source_txn_work; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.source_txn_work (
    source_txn_id uuid NOT NULL,
    match_state text NOT NULL,
    economic_type_proposed bnx.economic_type,
    category_id uuid,
    classification_source text,
    clearing_default_applied boolean DEFAULT false NOT NULL,
    revision integer DEFAULT 1 NOT NULL
);


ALTER TABLE bnx.source_txn_work OWNER TO bnx_definer;

--
-- Name: statement; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.statement (
    id uuid NOT NULL,
    document_id uuid NOT NULL,
    account_currency_id uuid,
    currency character(3) NOT NULL,
    period_start date,
    period_end date,
    opening_balance numeric(20,4),
    closing_balance numeric(20,4),
    sign_convention text NOT NULL,
    version_group uuid,
    CONSTRAINT statement_sign_convention_check CHECK ((sign_convention = ANY (ARRAY['asset_positive'::text, 'owed_positive'::text])))
);


ALTER TABLE bnx.statement OWNER TO bnx_definer;

--
-- Name: statement_event; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.statement_event (
    statement_id uuid NOT NULL,
    seq integer NOT NULL,
    event text NOT NULL,
    payload jsonb NOT NULL,
    recorded_version bigint NOT NULL,
    actor uuid NOT NULL,
    CONSTRAINT statement_event_event_check CHECK ((event = ANY (ARRAY['assigned'::text, 'confirmed'::text, 'version_role_set'::text, 'withdrawn'::text])))
);


ALTER TABLE bnx.statement_event OWNER TO bnx_definer;

--
-- Name: table_class; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.table_class (
    table_name text NOT NULL,
    class character(1) NOT NULL,
    CONSTRAINT table_class_class_check CHECK ((class = ANY (ARRAY['F'::bpchar, 'E'::bpchar, 'M'::bpchar])))
);


ALTER TABLE bnx.table_class OWNER TO bnx_definer;

--
-- Name: valuation; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.valuation (
    id uuid NOT NULL,
    instrument_id uuid NOT NULL,
    valuation_date date NOT NULL,
    price numeric(28,10) NOT NULL,
    currency character(3) NOT NULL,
    source text NOT NULL,
    recorded_version bigint NOT NULL
);


ALTER TABLE bnx.valuation OWNER TO bnx_definer;

--
-- Name: work_item; Type: TABLE; Schema: bnx; Owner: bnx_definer
--

CREATE TABLE bnx.work_item (
    id bigint NOT NULL,
    kind text NOT NULL,
    payload jsonb NOT NULL,
    state text DEFAULT 'queued'::text NOT NULL,
    enqueued_at timestamp with time zone DEFAULT now() NOT NULL,
    lease_until timestamp with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    CONSTRAINT work_item_state_check CHECK ((state = ANY (ARRAY['queued'::text, 'leased'::text, 'done'::text, 'dead'::text])))
);


ALTER TABLE bnx.work_item OWNER TO bnx_definer;

--
-- Name: work_item_id_seq; Type: SEQUENCE; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE bnx.work_item ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME bnx.work_item_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: future_identity_link id; Type: DEFAULT; Schema: auth; Owner: bnx_auth
--

ALTER TABLE ONLY auth.future_identity_link ALTER COLUMN id SET DEFAULT nextval('auth.future_identity_link_id_seq'::regclass);


--
-- Name: evidence_access_log id; Type: DEFAULT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_access_log ALTER COLUMN id SET DEFAULT nextval('bnx.evidence_access_log_id_seq'::regclass);


--
-- Name: journal_entry entry_no; Type: DEFAULT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry ALTER COLUMN entry_no SET DEFAULT nextval('bnx.journal_entry_entry_no_seq'::regclass);


--
-- Name: future_identity_link future_identity_link_pkey; Type: CONSTRAINT; Schema: auth; Owner: bnx_auth
--

ALTER TABLE ONLY auth.future_identity_link
    ADD CONSTRAINT future_identity_link_pkey PRIMARY KEY (id);


--
-- Name: account_currency account_currency_account_id_currency_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_account_id_currency_key UNIQUE (account_id, currency);


--
-- Name: account_currency account_currency_id_currency_uq; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_id_currency_uq UNIQUE (id, currency);


--
-- Name: account_currency account_currency_ledger_account_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_ledger_account_id_key UNIQUE (ledger_account_id);


--
-- Name: account_currency account_currency_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_pkey PRIMARY KEY (id);


--
-- Name: account_event account_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_event
    ADD CONSTRAINT account_event_pkey PRIMARY KEY (account_id, seq);


--
-- Name: account_grant account_grant_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_grant
    ADD CONSTRAINT account_grant_pkey PRIMARY KEY (member_id, account_id);


--
-- Name: account_ownership_event account_ownership_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_ownership_event
    ADD CONSTRAINT account_ownership_event_pkey PRIMARY KEY (id);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: account_scope_event account_scope_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_scope_event
    ADD CONSTRAINT account_scope_event_pkey PRIMARY KEY (id);


--
-- Name: ai_connection ai_connection_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ai_connection
    ADD CONSTRAINT ai_connection_pkey PRIMARY KEY (id);


--
-- Name: ai_connection_token ai_connection_token_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ai_connection_token
    ADD CONSTRAINT ai_connection_token_pkey PRIMARY KEY (token_sha256);


--
-- Name: account_ownership_event aoe_event_seq_uq; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_ownership_event
    ADD CONSTRAINT aoe_event_seq_uq UNIQUE (event_seq);


--
-- Name: account_ownership_event aoe_no_same_version_tie; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_ownership_event
    ADD CONSTRAINT aoe_no_same_version_tie UNIQUE (account_id, party_id, kind, effective_from, recorded_version);


--
-- Name: account_scope_event ase_event_seq_uq; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_scope_event
    ADD CONSTRAINT ase_event_seq_uq UNIQUE (event_seq);


--
-- Name: account_scope_event ase_no_same_version_tie; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_scope_event
    ADD CONSTRAINT ase_no_same_version_tie UNIQUE (account_id, effective_from, recorded_version);


--
-- Name: audit_event audit_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.audit_event
    ADD CONSTRAINT audit_event_pkey PRIMARY KEY (seq);


--
-- Name: balance_checkpoint balance_checkpoint_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.balance_checkpoint
    ADD CONSTRAINT balance_checkpoint_pkey PRIMARY KEY (id);


--
-- Name: bridge_acceptance bridge_acceptance_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.bridge_acceptance
    ADD CONSTRAINT bridge_acceptance_pkey PRIMARY KEY (plan_id, account_currency_id);


--
-- Name: category_version category_version_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.category_version
    ADD CONSTRAINT category_version_pkey PRIMARY KEY (category_id, valid_from_version);


--
-- Name: clearing_item_event clearing_item_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.clearing_item_event
    ADD CONSTRAINT clearing_item_event_pkey PRIMARY KEY (clearing_item_id, seq);


--
-- Name: clearing_item clearing_item_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.clearing_item
    ADD CONSTRAINT clearing_item_pkey PRIMARY KEY (id);


--
-- Name: currency currency_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.currency
    ADD CONSTRAINT currency_pkey PRIMARY KEY (code);


--
-- Name: document document_evidence_object_id_seq_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.document
    ADD CONSTRAINT document_evidence_object_id_seq_key UNIQUE (evidence_object_id, seq);


--
-- Name: document document_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.document
    ADD CONSTRAINT document_pkey PRIMARY KEY (id);


--
-- Name: evidence_access_grant evidence_access_grant_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_access_grant
    ADD CONSTRAINT evidence_access_grant_pkey PRIMARY KEY (evidence_file_id, member_id, granted_at);


--
-- Name: evidence_access_log evidence_access_log_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_access_log
    ADD CONSTRAINT evidence_access_log_pkey PRIMARY KEY (id);


--
-- Name: evidence_archive_event evidence_archive_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_archive_event
    ADD CONSTRAINT evidence_archive_event_pkey PRIMARY KEY (evidence_object_id, seq);


--
-- Name: evidence_file evidence_file_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_file
    ADD CONSTRAINT evidence_file_pkey PRIMARY KEY (id);


--
-- Name: evidence_object evidence_object_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_object
    ADD CONSTRAINT evidence_object_pkey PRIMARY KEY (id);


--
-- Name: evidence_object evidence_object_r2_key_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_object
    ADD CONSTRAINT evidence_object_r2_key_key UNIQUE (r2_key);


--
-- Name: fx_override_event fx_override_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_override_event
    ADD CONSTRAINT fx_override_event_pkey PRIMARY KEY (id);


--
-- Name: fx_selection_log fx_selection_log_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_selection_log
    ADD CONSTRAINT fx_selection_log_pkey PRIMARY KEY (id);


--
-- Name: household_setting household_setting_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.household_setting
    ADD CONSTRAINT household_setting_pkey PRIMARY KEY (key);


--
-- Name: idempotency idempotency_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.idempotency
    ADD CONSTRAINT idempotency_pkey PRIMARY KEY (member_id, idem_key);


--
-- Name: institution institution_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.institution
    ADD CONSTRAINT institution_pkey PRIMARY KEY (id);


--
-- Name: journal_correction journal_correction_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_pkey PRIMARY KEY (original_journal_id);


--
-- Name: journal_correction journal_correction_replacement_journal_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_replacement_journal_id_key UNIQUE (replacement_journal_id);


--
-- Name: journal_correction journal_correction_reversal_journal_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_reversal_journal_id_key UNIQUE (reversal_journal_id);


--
-- Name: journal_entry journal_entry_entry_no_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry
    ADD CONSTRAINT journal_entry_entry_no_key UNIQUE (entry_no);


--
-- Name: journal_entry journal_entry_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry
    ADD CONSTRAINT journal_entry_pkey PRIMARY KEY (id);


--
-- Name: journal_line journal_line_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_pkey PRIMARY KEY (id);


--
-- Name: journal_source journal_source_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_source
    ADD CONSTRAINT journal_source_pkey PRIMARY KEY (journal_id, source_txn_id);


--
-- Name: ledger_account ledger_account_id_currency_uq; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ledger_account
    ADD CONSTRAINT ledger_account_id_currency_uq UNIQUE (id, currency);


--
-- Name: ledger_account ledger_account_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ledger_account
    ADD CONSTRAINT ledger_account_pkey PRIMARY KEY (id);


--
-- Name: ledger_state ledger_state_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ledger_state
    ADD CONSTRAINT ledger_state_pkey PRIMARY KEY (singleton);


--
-- Name: m1_future_fact m1_future_fact_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.m1_future_fact
    ADD CONSTRAINT m1_future_fact_pkey PRIMARY KEY (id);


--
-- Name: match_decision_current match_decision_current_decision_event_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_current
    ADD CONSTRAINT match_decision_current_decision_event_id_key UNIQUE (decision_event_id);


--
-- Name: match_decision_current match_decision_current_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_current
    ADD CONSTRAINT match_decision_current_pkey PRIMARY KEY (source_txn_id, kind);


--
-- Name: match_decision_event match_decision_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_pkey PRIMARY KEY (id);


--
-- Name: member_identity member_identity_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member_identity
    ADD CONSTRAINT member_identity_pkey PRIMARY KEY (iss, sub);


--
-- Name: member member_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member
    ADD CONSTRAINT member_pkey PRIMARY KEY (id);


--
-- Name: member_session member_session_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member_session
    ADD CONSTRAINT member_session_pkey PRIMARY KEY (id);


--
-- Name: member_session member_session_token_sha256_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member_session
    ADD CONSTRAINT member_session_token_sha256_key UNIQUE (token_sha256);


--
-- Name: oauth_client oauth_client_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.oauth_client
    ADD CONSTRAINT oauth_client_pkey PRIMARY KEY (client_id);


--
-- Name: oauth_code oauth_code_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.oauth_code
    ADD CONSTRAINT oauth_code_pkey PRIMARY KEY (code_sha256);


--
-- Name: opening_anchor_version opening_anchor_version_account_currency_id_revision_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_account_currency_id_revision_key UNIQUE (account_currency_id, revision);


--
-- Name: opening_anchor_version opening_anchor_version_account_currency_id_valid_from_versi_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_account_currency_id_valid_from_versi_key UNIQUE (account_currency_id, valid_from_version);


--
-- Name: opening_anchor_version opening_anchor_version_journal_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_journal_id_key UNIQUE (journal_id);


--
-- Name: opening_anchor_version opening_anchor_version_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_pkey PRIMARY KEY (id);


--
-- Name: outbox outbox_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.outbox
    ADD CONSTRAINT outbox_pkey PRIMARY KEY (id);


--
-- Name: party party_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.party
    ADD CONSTRAINT party_pkey PRIMARY KEY (id);


--
-- Name: plan_event plan_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.plan_event
    ADD CONSTRAINT plan_event_pkey PRIMARY KEY (plan_id, seq);


--
-- Name: posting_batch posting_batch_activated_version_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch
    ADD CONSTRAINT posting_batch_activated_version_key UNIQUE (activated_version);


--
-- Name: posting_batch_event posting_batch_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch_event
    ADD CONSTRAINT posting_batch_event_pkey PRIMARY KEY (batch_id, event);


--
-- Name: posting_batch posting_batch_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch
    ADD CONSTRAINT posting_batch_pkey PRIMARY KEY (id);


--
-- Name: posting_batch posting_batch_plan_id_key; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch
    ADD CONSTRAINT posting_batch_plan_id_key UNIQUE (plan_id);


--
-- Name: posting_date_confirmation posting_date_confirmation_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_date_confirmation
    ADD CONSTRAINT posting_date_confirmation_pkey PRIMARY KEY (journal_id, seq);


--
-- Name: posting_plan_item posting_plan_item_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_plan_item
    ADD CONSTRAINT posting_plan_item_pkey PRIMARY KEY (plan_id, seq);


--
-- Name: posting_plan posting_plan_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_plan
    ADD CONSTRAINT posting_plan_pkey PRIMARY KEY (id);


--
-- Name: posting_scope_claim posting_scope_claim_no_overlap; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_scope_claim
    ADD CONSTRAINT posting_scope_claim_no_overlap EXCLUDE USING gist (account_currency_id WITH =, during WITH &&) WHERE ((claim_state = 'held'::text));


--
-- Name: posting_scope_claim posting_scope_claim_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_scope_claim
    ADD CONSTRAINT posting_scope_claim_pkey PRIMARY KEY (plan_id, account_currency_id);


--
-- Name: queue_state queue_state_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.queue_state
    ADD CONSTRAINT queue_state_pkey PRIMARY KEY (singleton);


--
-- Name: report_snapshot report_snapshot_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.report_snapshot
    ADD CONSTRAINT report_snapshot_pkey PRIMARY KEY (id);


--
-- Name: schema_bootstrap schema_bootstrap_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.schema_bootstrap
    ADD CONSTRAINT schema_bootstrap_pkey PRIMARY KEY (version);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: source_link_event source_link_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_link_event
    ADD CONSTRAINT source_link_event_pkey PRIMARY KEY (event_id);


--
-- Name: source_txn_current_link source_txn_current_link_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_current_link
    ADD CONSTRAINT source_txn_current_link_pkey PRIMARY KEY (source_txn_id);


--
-- Name: source_txn source_txn_fp_uq; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn
    ADD CONSTRAINT source_txn_fp_uq UNIQUE (account_currency_id, source_fingerprint);


--
-- Name: source_txn_link_event_d04_retired source_txn_link_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_link_event_d04_retired
    ADD CONSTRAINT source_txn_link_event_pkey PRIMARY KEY (source_txn_id, journal_id, event);


--
-- Name: source_txn source_txn_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn
    ADD CONSTRAINT source_txn_pkey PRIMARY KEY (id);


--
-- Name: source_txn_work source_txn_work_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_work
    ADD CONSTRAINT source_txn_work_pkey PRIMARY KEY (source_txn_id);


--
-- Name: statement_event statement_event_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement_event
    ADD CONSTRAINT statement_event_pkey PRIMARY KEY (statement_id, seq);


--
-- Name: statement statement_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement
    ADD CONSTRAINT statement_pkey PRIMARY KEY (id);


--
-- Name: table_class table_class_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.table_class
    ADD CONSTRAINT table_class_pkey PRIMARY KEY (table_name);


--
-- Name: valuation valuation_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.valuation
    ADD CONSTRAINT valuation_pkey PRIMARY KEY (id);


--
-- Name: work_item work_item_pkey; Type: CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.work_item
    ADD CONSTRAINT work_item_pkey PRIMARY KEY (id);


--
-- Name: aoe_lookup; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX aoe_lookup ON bnx.account_ownership_event USING btree (account_id, kind, party_id, recorded_version, effective_from);


--
-- Name: ase_lookup; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX ase_lookup ON bnx.account_scope_event USING btree (account_id, recorded_version, effective_from);


--
-- Name: evidence_object_sha_uq; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE UNIQUE INDEX evidence_object_sha_uq ON bnx.evidence_object USING btree (sha256) WHERE ((integrity_state = 'verified'::text) AND (dedup_into IS NULL));


--
-- Name: je_posting_date; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX je_posting_date ON bnx.journal_entry USING btree (posting_date);


--
-- Name: jl_account; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX jl_account ON bnx.journal_line USING btree (ledger_account_id, journal_id);


--
-- Name: mdc_ledger_leg_uq; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE UNIQUE INDEX mdc_ledger_leg_uq ON bnx.match_decision_current USING btree (journal_line_id) WHERE (kind = 'ledger'::text);


--
-- Name: pbe_one_terminal; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE UNIQUE INDEX pbe_one_terminal ON bnx.posting_batch_event USING btree (batch_id) WHERE (event = ANY (ARRAY['activated'::text, 'voided'::text]));


--
-- Name: pdc_version; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX pdc_version ON bnx.posting_date_confirmation USING btree (journal_id, recorded_version DESC);


--
-- Name: sle_pair; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE INDEX sle_pair ON bnx.source_link_event USING btree (source_txn_id, journal_id, event_id DESC);


--
-- Name: sle_prior_uq; Type: INDEX; Schema: bnx; Owner: bnx_definer
--

CREATE UNIQUE INDEX sle_prior_uq ON bnx.source_link_event USING btree (prior_event_id) WHERE (prior_event_id IS NOT NULL);


--
-- Name: account_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.account_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: account_ownership_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.account_ownership_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: account_scope_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.account_scope_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: audit_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.audit_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: balance_checkpoint t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.balance_checkpoint FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: bridge_acceptance t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.bridge_acceptance FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: category_version t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.category_version FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: clearing_item t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.clearing_item FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: clearing_item_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.clearing_item_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: document t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.document FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: evidence_archive_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.evidence_archive_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: fx_override_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.fx_override_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: fx_selection_log t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.fx_selection_log FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: journal_correction t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.journal_correction FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: journal_entry t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.journal_entry FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: journal_line t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.journal_line FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: journal_source t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.journal_source FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: match_decision_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.match_decision_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: opening_anchor_version t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.opening_anchor_version FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: plan_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.plan_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: posting_batch_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.posting_batch_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: posting_date_confirmation t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.posting_date_confirmation FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: report_snapshot t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.report_snapshot FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: source_link_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.source_link_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: source_txn t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.source_txn FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: source_txn_link_event_d04_retired t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.source_txn_link_event_d04_retired FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: statement t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.statement FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: statement_event t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.statement_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: valuation t_append_only; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_append_only BEFORE DELETE OR UPDATE ON bnx.valuation FOR EACH ROW EXECUTE FUNCTION bnx.trg_append_only();


--
-- Name: evidence_object t_archive_state_guard; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_archive_state_guard BEFORE UPDATE OF archive_state ON bnx.evidence_object FOR EACH ROW EXECUTE FUNCTION bnx.trg_archive_state_guard();


--
-- Name: journal_entry t_journal_complete_header; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE CONSTRAINT TRIGGER t_journal_complete_header AFTER INSERT ON bnx.journal_entry DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION bnx.trg_journal_complete();


--
-- Name: journal_line t_journal_complete_line; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE CONSTRAINT TRIGGER t_journal_complete_line AFTER INSERT ON bnx.journal_line DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION bnx.trg_journal_complete();


--
-- Name: journal_line t_line_same_txn; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_line_same_txn BEFORE INSERT ON bnx.journal_line FOR EACH ROW EXECUTE FUNCTION bnx.trg_line_same_txn();


--
-- Name: account_ownership_event t_ownership_share_total; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE CONSTRAINT TRIGGER t_ownership_share_total AFTER INSERT ON bnx.account_ownership_event DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION bnx.trg_ownership_share_total();


--
-- Name: source_txn_link_event_d04_retired t_retired; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_retired BEFORE INSERT ON bnx.source_txn_link_event_d04_retired FOR EACH ROW EXECUTE FUNCTION bnx.trg_retired();


--
-- Name: clearing_item t_scale; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_scale BEFORE INSERT ON bnx.clearing_item FOR EACH ROW EXECUTE FUNCTION bnx.trg_scale();


--
-- Name: journal_entry t_scale; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_scale BEFORE INSERT ON bnx.journal_entry FOR EACH ROW EXECUTE FUNCTION bnx.trg_scale();


--
-- Name: opening_anchor_version t_scale; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_scale BEFORE INSERT ON bnx.opening_anchor_version FOR EACH ROW EXECUTE FUNCTION bnx.trg_scale();


--
-- Name: source_txn t_scale; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_scale BEFORE INSERT ON bnx.source_txn FOR EACH ROW EXECUTE FUNCTION bnx.trg_scale();


--
-- Name: statement t_scale; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_scale BEFORE INSERT ON bnx.statement FOR EACH ROW EXECUTE FUNCTION bnx.trg_scale();


--
-- Name: source_link_event t_source_link_transition; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_source_link_transition BEFORE INSERT ON bnx.source_link_event FOR EACH ROW EXECUTE FUNCTION bnx.trg_source_link_transition();


--
-- Name: evidence_object t_write_once; Type: TRIGGER; Schema: bnx; Owner: bnx_definer
--

CREATE TRIGGER t_write_once BEFORE DELETE OR UPDATE ON bnx.evidence_object FOR EACH ROW EXECUTE FUNCTION bnx.trg_evidence_object_write_once();


--
-- Name: account_currency account_currency_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_account_id_fkey FOREIGN KEY (account_id) REFERENCES bnx.account(id);


--
-- Name: account_currency account_currency_currency_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_currency_fkey FOREIGN KEY (currency) REFERENCES bnx.currency(code);


--
-- Name: account_currency account_currency_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES bnx.ledger_account(id);


--
-- Name: account_currency account_currency_ledger_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_currency
    ADD CONSTRAINT account_currency_ledger_currency_fk FOREIGN KEY (ledger_account_id, currency) REFERENCES bnx.ledger_account(id, currency);


--
-- Name: account_event account_event_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_event
    ADD CONSTRAINT account_event_account_id_fkey FOREIGN KEY (account_id) REFERENCES bnx.account(id);


--
-- Name: account_grant account_grant_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_grant
    ADD CONSTRAINT account_grant_account_id_fkey FOREIGN KEY (account_id) REFERENCES bnx.account(id);


--
-- Name: account_grant account_grant_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_grant
    ADD CONSTRAINT account_grant_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: account account_institution_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account
    ADD CONSTRAINT account_institution_id_fkey FOREIGN KEY (institution_id) REFERENCES bnx.institution(id);


--
-- Name: account account_merged_into_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account
    ADD CONSTRAINT account_merged_into_fkey FOREIGN KEY (merged_into) REFERENCES bnx.account(id);


--
-- Name: account_ownership_event account_ownership_event_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_ownership_event
    ADD CONSTRAINT account_ownership_event_account_id_fkey FOREIGN KEY (account_id) REFERENCES bnx.account(id);


--
-- Name: account_ownership_event account_ownership_event_party_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_ownership_event
    ADD CONSTRAINT account_ownership_event_party_id_fkey FOREIGN KEY (party_id) REFERENCES bnx.party(id);


--
-- Name: account_scope_event account_scope_event_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.account_scope_event
    ADD CONSTRAINT account_scope_event_account_id_fkey FOREIGN KEY (account_id) REFERENCES bnx.account(id);


--
-- Name: ai_connection ai_connection_client_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ai_connection
    ADD CONSTRAINT ai_connection_client_id_fkey FOREIGN KEY (client_id) REFERENCES bnx.oauth_client(client_id);


--
-- Name: ai_connection ai_connection_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ai_connection
    ADD CONSTRAINT ai_connection_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: ai_connection_token ai_connection_token_connection_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ai_connection_token
    ADD CONSTRAINT ai_connection_token_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES bnx.ai_connection(id);


--
-- Name: balance_checkpoint balance_checkpoint_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.balance_checkpoint
    ADD CONSTRAINT balance_checkpoint_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: bridge_acceptance bridge_acceptance_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.bridge_acceptance
    ADD CONSTRAINT bridge_acceptance_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: bridge_acceptance bridge_acceptance_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.bridge_acceptance
    ADD CONSTRAINT bridge_acceptance_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: clearing_item clearing_item_account_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.clearing_item
    ADD CONSTRAINT clearing_item_account_currency_fk FOREIGN KEY (account_currency_id, currency) REFERENCES bnx.account_currency(id, currency);


--
-- Name: clearing_item clearing_item_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.clearing_item
    ADD CONSTRAINT clearing_item_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: clearing_item_event clearing_item_event_clearing_item_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.clearing_item_event
    ADD CONSTRAINT clearing_item_event_clearing_item_id_fkey FOREIGN KEY (clearing_item_id) REFERENCES bnx.clearing_item(id);


--
-- Name: document document_evidence_object_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.document
    ADD CONSTRAINT document_evidence_object_id_fkey FOREIGN KEY (evidence_object_id) REFERENCES bnx.evidence_object(id);


--
-- Name: evidence_access_grant evidence_access_grant_evidence_file_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_access_grant
    ADD CONSTRAINT evidence_access_grant_evidence_file_id_fkey FOREIGN KEY (evidence_file_id) REFERENCES bnx.evidence_file(id);


--
-- Name: evidence_access_grant evidence_access_grant_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_access_grant
    ADD CONSTRAINT evidence_access_grant_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: evidence_archive_event evidence_archive_event_evidence_object_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_archive_event
    ADD CONSTRAINT evidence_archive_event_evidence_object_id_fkey FOREIGN KEY (evidence_object_id) REFERENCES bnx.evidence_object(id);


--
-- Name: evidence_file evidence_file_acquired_by_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_file
    ADD CONSTRAINT evidence_file_acquired_by_fkey FOREIGN KEY (acquired_by) REFERENCES bnx.member(id);


--
-- Name: evidence_file evidence_file_assigned_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_file
    ADD CONSTRAINT evidence_file_assigned_account_currency_id_fkey FOREIGN KEY (assigned_account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: evidence_file evidence_file_evidence_object_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_file
    ADD CONSTRAINT evidence_file_evidence_object_id_fkey FOREIGN KEY (evidence_object_id) REFERENCES bnx.evidence_object(id);


--
-- Name: evidence_file evidence_file_superseded_by_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_file
    ADD CONSTRAINT evidence_file_superseded_by_fkey FOREIGN KEY (superseded_by) REFERENCES bnx.evidence_file(id);


--
-- Name: evidence_object evidence_object_dedup_into_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.evidence_object
    ADD CONSTRAINT evidence_object_dedup_into_fkey FOREIGN KEY (dedup_into) REFERENCES bnx.evidence_object(id);


--
-- Name: fx_override_event fx_override_event_base_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_override_event
    ADD CONSTRAINT fx_override_event_base_fkey FOREIGN KEY (base) REFERENCES bnx.currency(code);


--
-- Name: fx_override_event fx_override_event_quote_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_override_event
    ADD CONSTRAINT fx_override_event_quote_fkey FOREIGN KEY (quote) REFERENCES bnx.currency(code);


--
-- Name: fx_selection_log fx_selection_log_base_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_selection_log
    ADD CONSTRAINT fx_selection_log_base_fkey FOREIGN KEY (base) REFERENCES bnx.currency(code);


--
-- Name: fx_selection_log fx_selection_log_quote_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.fx_selection_log
    ADD CONSTRAINT fx_selection_log_quote_fkey FOREIGN KEY (quote) REFERENCES bnx.currency(code);


--
-- Name: journal_correction journal_correction_original_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_original_journal_id_fkey FOREIGN KEY (original_journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: journal_correction journal_correction_replacement_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_replacement_journal_id_fkey FOREIGN KEY (replacement_journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: journal_correction journal_correction_reversal_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_correction
    ADD CONSTRAINT journal_correction_reversal_journal_id_fkey FOREIGN KEY (reversal_journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: journal_entry journal_entry_approval_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry
    ADD CONSTRAINT journal_entry_approval_plan_id_fkey FOREIGN KEY (approval_plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: journal_entry journal_entry_posting_batch_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry
    ADD CONSTRAINT journal_entry_posting_batch_id_fkey FOREIGN KEY (posting_batch_id) REFERENCES bnx.posting_batch(id);


--
-- Name: journal_line journal_line_clearing_item_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_clearing_item_id_fkey FOREIGN KEY (clearing_item_id) REFERENCES bnx.clearing_item(id);


--
-- Name: journal_line journal_line_currency_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_currency_fkey FOREIGN KEY (currency) REFERENCES bnx.currency(code);


--
-- Name: journal_line journal_line_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: journal_line journal_line_ledger_account_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_ledger_account_id_fkey FOREIGN KEY (ledger_account_id) REFERENCES bnx.ledger_account(id);


--
-- Name: journal_line journal_line_ledger_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_line
    ADD CONSTRAINT journal_line_ledger_currency_fk FOREIGN KEY (ledger_account_id, currency) REFERENCES bnx.ledger_account(id, currency);


--
-- Name: journal_entry journal_original_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_entry
    ADD CONSTRAINT journal_original_currency_fk FOREIGN KEY (original_currency) REFERENCES bnx.currency(code);


--
-- Name: journal_source journal_source_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_source
    ADD CONSTRAINT journal_source_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: journal_source journal_source_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.journal_source
    ADD CONSTRAINT journal_source_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: ledger_account ledger_account_currency_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.ledger_account
    ADD CONSTRAINT ledger_account_currency_fkey FOREIGN KEY (currency) REFERENCES bnx.currency(code);


--
-- Name: match_decision_current match_decision_current_decision_event_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_current
    ADD CONSTRAINT match_decision_current_decision_event_id_fkey FOREIGN KEY (decision_event_id) REFERENCES bnx.match_decision_event(id);


--
-- Name: match_decision_current match_decision_current_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_current
    ADD CONSTRAINT match_decision_current_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: match_decision_event match_decision_event_clearing_item_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_clearing_item_id_fkey FOREIGN KEY (clearing_item_id) REFERENCES bnx.clearing_item(id);


--
-- Name: match_decision_event match_decision_event_counterpart_source_txn_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_counterpart_source_txn_fkey FOREIGN KEY (counterpart_source_txn) REFERENCES bnx.source_txn(id);


--
-- Name: match_decision_event match_decision_event_journal_line_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_journal_line_id_fkey FOREIGN KEY (journal_line_id) REFERENCES bnx.journal_line(id);


--
-- Name: match_decision_event match_decision_event_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: match_decision_event match_decision_event_supersedes_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.match_decision_event
    ADD CONSTRAINT match_decision_event_supersedes_fkey FOREIGN KEY (supersedes) REFERENCES bnx.match_decision_event(id);


--
-- Name: member_identity member_identity_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member_identity
    ADD CONSTRAINT member_identity_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: member_session member_session_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.member_session
    ADD CONSTRAINT member_session_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: oauth_code oauth_code_connection_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.oauth_code
    ADD CONSTRAINT oauth_code_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES bnx.ai_connection(id);


--
-- Name: opening_anchor_version opening_anchor_version_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: opening_anchor_version opening_anchor_version_installed_by_plan_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_installed_by_plan_fkey FOREIGN KEY (installed_by_plan) REFERENCES bnx.posting_plan(id);


--
-- Name: opening_anchor_version opening_anchor_version_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: opening_anchor_version opening_anchor_version_reversed_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.opening_anchor_version
    ADD CONSTRAINT opening_anchor_version_reversed_journal_id_fkey FOREIGN KEY (reversed_journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: party party_member_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.party
    ADD CONSTRAINT party_member_id_fkey FOREIGN KEY (member_id) REFERENCES bnx.member(id);


--
-- Name: plan_event plan_event_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.plan_event
    ADD CONSTRAINT plan_event_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: posting_batch_event posting_batch_event_batch_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch_event
    ADD CONSTRAINT posting_batch_event_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES bnx.posting_batch(id);


--
-- Name: posting_batch posting_batch_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_batch
    ADD CONSTRAINT posting_batch_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: posting_date_confirmation posting_date_confirmation_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_date_confirmation
    ADD CONSTRAINT posting_date_confirmation_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: posting_plan posting_plan_approved_by_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_plan
    ADD CONSTRAINT posting_plan_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES bnx.member(id);


--
-- Name: posting_plan_item posting_plan_item_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_plan_item
    ADD CONSTRAINT posting_plan_item_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: posting_plan posting_plan_supersedes_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_plan
    ADD CONSTRAINT posting_plan_supersedes_plan_id_fkey FOREIGN KEY (supersedes_plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: posting_scope_claim posting_scope_claim_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_scope_claim
    ADD CONSTRAINT posting_scope_claim_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: posting_scope_claim posting_scope_claim_plan_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.posting_scope_claim
    ADD CONSTRAINT posting_scope_claim_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES bnx.posting_plan(id);


--
-- Name: report_snapshot report_snapshot_projection_connection_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.report_snapshot
    ADD CONSTRAINT report_snapshot_projection_connection_id_fkey FOREIGN KEY (projection_connection_id) REFERENCES bnx.ai_connection(id);


--
-- Name: source_link_event source_link_event_batch_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_link_event
    ADD CONSTRAINT source_link_event_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES bnx.posting_batch(id);


--
-- Name: source_link_event source_link_event_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_link_event
    ADD CONSTRAINT source_link_event_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: source_link_event source_link_event_prior_event_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_link_event
    ADD CONSTRAINT source_link_event_prior_event_id_fkey FOREIGN KEY (prior_event_id) REFERENCES bnx.source_link_event(event_id);


--
-- Name: source_link_event source_link_event_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_link_event
    ADD CONSTRAINT source_link_event_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: source_txn source_txn_account_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn
    ADD CONSTRAINT source_txn_account_currency_fk FOREIGN KEY (account_currency_id, currency) REFERENCES bnx.account_currency(id, currency);


--
-- Name: source_txn source_txn_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn
    ADD CONSTRAINT source_txn_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: source_txn_current_link source_txn_current_link_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_current_link
    ADD CONSTRAINT source_txn_current_link_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: source_txn_current_link source_txn_current_link_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_current_link
    ADD CONSTRAINT source_txn_current_link_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: source_txn_link_event_d04_retired source_txn_link_event_batch_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_link_event_d04_retired
    ADD CONSTRAINT source_txn_link_event_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES bnx.posting_batch(id);


--
-- Name: source_txn_link_event_d04_retired source_txn_link_event_journal_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_link_event_d04_retired
    ADD CONSTRAINT source_txn_link_event_journal_id_fkey FOREIGN KEY (journal_id) REFERENCES bnx.journal_entry(id);


--
-- Name: source_txn_link_event_d04_retired source_txn_link_event_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_link_event_d04_retired
    ADD CONSTRAINT source_txn_link_event_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: source_txn_work source_txn_work_source_txn_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.source_txn_work
    ADD CONSTRAINT source_txn_work_source_txn_id_fkey FOREIGN KEY (source_txn_id) REFERENCES bnx.source_txn(id);


--
-- Name: statement statement_account_currency_fk; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement
    ADD CONSTRAINT statement_account_currency_fk FOREIGN KEY (account_currency_id, currency) REFERENCES bnx.account_currency(id, currency);


--
-- Name: statement statement_account_currency_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement
    ADD CONSTRAINT statement_account_currency_id_fkey FOREIGN KEY (account_currency_id) REFERENCES bnx.account_currency(id);


--
-- Name: statement statement_currency_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement
    ADD CONSTRAINT statement_currency_fkey FOREIGN KEY (currency) REFERENCES bnx.currency(code);


--
-- Name: statement statement_document_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement
    ADD CONSTRAINT statement_document_id_fkey FOREIGN KEY (document_id) REFERENCES bnx.document(id);


--
-- Name: statement_event statement_event_statement_id_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.statement_event
    ADD CONSTRAINT statement_event_statement_id_fkey FOREIGN KEY (statement_id) REFERENCES bnx.statement(id);


--
-- Name: valuation valuation_currency_fkey; Type: FK CONSTRAINT; Schema: bnx; Owner: bnx_definer
--

ALTER TABLE ONLY bnx.valuation
    ADD CONSTRAINT valuation_currency_fkey FOREIGN KEY (currency) REFERENCES bnx.currency(code);


--
-- Name: SCHEMA auth; Type: ACL; Schema: -; Owner: bnx_auth
--

GRANT USAGE ON SCHEMA auth TO bnx_backup;


--
-- Name: SCHEMA bnx; Type: ACL; Schema: -; Owner: bnx_definer
--

GRANT USAGE ON SCHEMA bnx TO bnx_app;
GRANT USAGE ON SCHEMA bnx TO bnx_worker;
GRANT USAGE ON SCHEMA bnx TO bnx_authn;
GRANT USAGE ON SCHEMA bnx TO bnx_backup;


--
-- Name: TABLE opening_anchor_version; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.opening_anchor_version TO bnx_backup;


--
-- Name: FUNCTION account_scope_at(p_account uuid, p_date date, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.account_scope_at(p_account uuid, p_date date, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION actor_can_post(a bnx.actor, p_ac uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.actor_can_post(a bnx.actor, p_ac uuid) FROM PUBLIC;


--
-- Name: FUNCTION actor_visible_acs(a bnx.actor); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.actor_visible_acs(a bnx.actor) FROM PUBLIC;


--
-- Name: FUNCTION anchor_at(p_ac uuid, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.anchor_at(p_ac uuid, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION apply_grants(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.apply_grants() FROM PUBLIC;


--
-- Name: FUNCTION assert_journal_complete(p_journal uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.assert_journal_complete(p_journal uuid) FROM PUBLIC;


--
-- Name: FUNCTION assert_scale(p_amount numeric, p_currency character, p_what text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.assert_scale(p_amount numeric, p_currency character, p_what text) FROM PUBLIC;


--
-- Name: FUNCTION audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.audit(a bnx.actor, p_command text, p_subject jsonb, p_payload jsonb, p_version bigint) FROM PUBLIC;


--
-- Name: FUNCTION audit_privileges(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.audit_privileges() FROM PUBLIC;


--
-- Name: FUNCTION audit_verify(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.audit_verify() FROM PUBLIC;


--
-- Name: FUNCTION authn_begin_session(claims jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.authn_begin_session(claims jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.authn_begin_session(claims jsonb) TO bnx_authn;


--
-- Name: FUNCTION authn_oauth_token(req jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.authn_oauth_token(req jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.authn_oauth_token(req jsonb) TO bnx_authn;


--
-- Name: FUNCTION balance_at(p_ac uuid, p_date date, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.balance_at(p_ac uuid, p_date date, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION balance_rows(p_acs uuid[], p_date date, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.balance_rows(p_acs uuid[], p_date date, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION can_read_evidence(p_member uuid, p_file uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.can_read_evidence(p_member uuid, p_file uuid) FROM PUBLIC;


--
-- Name: FUNCTION cmd_approve_ai_connection(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_approve_ai_connection(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_approve_plan(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_approve_plan(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_approve_plan(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_assign_evidence(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_assign_evidence(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_assign_evidence(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_audit_replay_snapshot(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_audit_replay_snapshot(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_audit_replay_snapshot(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_confirm_posting_date(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_confirm_posting_date(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_confirm_posting_date(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_correct_transaction(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_create_account(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_create_account(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_create_account(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_create_category(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_create_category(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_create_category(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_create_import_plan(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_create_import_plan(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_create_party(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_create_party(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_create_party(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_create_report_snapshot(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_create_report_snapshot(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_invite_member(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_invite_member(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_invite_member(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_post_transaction(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_post_transaction(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_post_transaction(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_record_ownership(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_record_ownership(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_record_ownership(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_register_evidence(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_register_evidence(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_register_evidence(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_revoke_ai_connection(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_revoke_ai_connection(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_revoke_session(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_revoke_session(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_revoke_session(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_set_account_scope(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_set_account_scope(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_set_account_scope(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_set_grant(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_set_grant(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_set_grant(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_set_household_setting(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_set_household_setting(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_set_member_state(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_set_member_state(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_set_member_state(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION cmd_set_opening(cred jsonb, cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.cmd_set_opening(cred jsonb, cmd jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.cmd_set_opening(cred jsonb, cmd jsonb) TO bnx_app;


--
-- Name: FUNCTION "dec"(p jsonb, p_field text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx."dec"(p jsonb, p_field text) FROM PUBLIC;


--
-- Name: FUNCTION effective_posting_date(p_journal uuid, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.effective_posting_date(p_journal uuid, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION enqueue(p_kind text, p_payload jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.enqueue(p_kind text, p_payload jsonb) FROM PUBLIC;


--
-- Name: FUNCTION fail(p_code text, p_state text, p_detail text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.fail(p_code text, p_state text, p_detail text) FROM PUBLIC;


--
-- Name: FUNCTION h(p text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.h(p text) FROM PUBLIC;


--
-- Name: FUNCTION idem_begin(a bnx.actor, p_command text, p_cmd jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.idem_begin(a bnx.actor, p_command text, p_cmd jsonb) FROM PUBLIC;


--
-- Name: FUNCTION idem_end(a bnx.actor, p_command text, p_cmd jsonb, p_receipt jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.idem_end(a bnx.actor, p_command text, p_cmd jsonb, p_receipt jsonb) FROM PUBLIC;


--
-- Name: FUNCTION insert_journal(a bnx.actor, p_v bigint, p_batch uuid, p_type text, p_tdate date, p_pdate date, p_desc text, p_lines jsonb, p_orig_amount numeric, p_orig_currency text, p_rate numeric, p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.insert_journal(a bnx.actor, p_v bigint, p_batch uuid, p_type text, p_tdate date, p_pdate date, p_desc text, p_lines jsonb, p_orig_amount numeric, p_orig_currency text, p_rate numeric, p_plan uuid) FROM PUBLIC;


--
-- Name: FUNCTION install_household(p_owner_name text, p_iss text, p_sub text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.install_household(p_owner_name text, p_iss text, p_sub text) FROM PUBLIC;


--
-- Name: FUNCTION new_secret(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.new_secret() FROM PUBLIC;


--
-- Name: FUNCTION next_version(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.next_version() FROM PUBLIC;


--
-- Name: FUNCTION ownership_at(p_account uuid, p_date date, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.ownership_at(p_account uuid, p_date date, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION plan_evidence_pending(p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.plan_evidence_pending(p_plan uuid) FROM PUBLIC;


--
-- Name: FUNCTION plan_scope(p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.plan_scope(p_plan uuid) FROM PUBLIC;


--
-- Name: FUNCTION plan_terminate(p_plan uuid, p_state text, p_reason text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.plan_terminate(p_plan uuid, p_state text, p_reason text) FROM PUBLIC;


--
-- Name: FUNCTION q_balances(cred jsonb, q jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.q_balances(cred jsonb, q jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.q_balances(cred jsonb, q jsonb) TO bnx_app;


--
-- Name: FUNCTION q_evidence_access(cred jsonb, q jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.q_evidence_access(cred jsonb, q jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.q_evidence_access(cred jsonb, q jsonb) TO bnx_app;


--
-- Name: FUNCTION q_replay_snapshot(cred jsonb, q jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.q_replay_snapshot(cred jsonb, q jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.q_replay_snapshot(cred jsonb, q jsonb) TO bnx_app;


--
-- Name: FUNCTION require(a bnx.actor, p_tier integer); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.require(a bnx.actor, p_tier integer) FROM PUBLIC;


--
-- Name: FUNCTION resolve_actor(cred jsonb); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.resolve_actor(cred jsonb) FROM PUBLIC;


--
-- Name: FUNCTION restore_mode(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.restore_mode() FROM PUBLIC;


--
-- Name: FUNCTION scope_delta_exists(p_plan uuid, p_since bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.scope_delta_exists(p_plan uuid, p_since bigint) FROM PUBLIC;


--
-- Name: FUNCTION scope_digest(p_la uuid, p_acid uuid, p_during daterange, p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.scope_digest(p_la uuid, p_acid uuid, p_during daterange, p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION snapshot_decision(a bnx.actor, p_snapshot uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.snapshot_decision(a bnx.actor, p_snapshot uuid) FROM PUBLIC;


--
-- Name: FUNCTION snapshot_replay_access(p_member uuid, p_snapshot uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.snapshot_replay_access(p_member uuid, p_snapshot uuid) FROM PUBLIC;


--
-- Name: FUNCTION system_ledger_account(p_kind text, p_currency character, p_name text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.system_ledger_account(p_kind text, p_currency character, p_name text) FROM PUBLIC;


--
-- Name: FUNCTION trg_append_only(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_append_only() FROM PUBLIC;


--
-- Name: FUNCTION trg_archive_state_guard(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_archive_state_guard() FROM PUBLIC;


--
-- Name: FUNCTION trg_evidence_object_write_once(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_evidence_object_write_once() FROM PUBLIC;


--
-- Name: FUNCTION trg_journal_complete(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_journal_complete() FROM PUBLIC;


--
-- Name: FUNCTION trg_line_same_txn(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_line_same_txn() FROM PUBLIC;


--
-- Name: FUNCTION trg_ownership_share_total(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_ownership_share_total() FROM PUBLIC;


--
-- Name: FUNCTION trg_retired(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_retired() FROM PUBLIC;


--
-- Name: FUNCTION trg_scale(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_scale() FROM PUBLIC;


--
-- Name: FUNCTION trg_source_link_transition(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.trg_source_link_transition() FROM PUBLIC;


--
-- Name: FUNCTION visible_account_currency_ids(p_member uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.visible_account_currency_ids(p_member uuid) FROM PUBLIC;


--
-- Name: FUNCTION visible_at(p_v bigint); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.visible_at(p_v bigint) FROM PUBLIC;


--
-- Name: FUNCTION wrk_activate_plan(p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_activate_plan(p_plan uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_activate_plan(p_plan uuid) TO bnx_worker;


--
-- Name: FUNCTION wrk_claim(p_max integer); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_claim(p_max integer) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_claim(p_max integer) TO bnx_worker;


--
-- Name: FUNCTION wrk_complete(p_id bigint, p_ok boolean); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_complete(p_id bigint, p_ok boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_complete(p_id bigint, p_ok boolean) TO bnx_worker;


--
-- Name: FUNCTION wrk_post_plan_chunk(p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_post_plan_chunk(p_plan uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_post_plan_chunk(p_plan uuid) TO bnx_worker;


--
-- Name: FUNCTION wrk_queue_status(); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_queue_status() FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_queue_status() TO bnx_worker;


--
-- Name: FUNCTION wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_record_archive_event(p_object uuid, p_event text, p_drive_file text, p_sha_hex text) TO bnx_worker;


--
-- Name: FUNCTION wrk_revalidate_plan(p_plan uuid); Type: ACL; Schema: bnx; Owner: bnx_definer
--

REVOKE ALL ON FUNCTION bnx.wrk_revalidate_plan(p_plan uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION bnx.wrk_revalidate_plan(p_plan uuid) TO bnx_worker;


--
-- Name: TABLE future_identity_link; Type: ACL; Schema: auth; Owner: bnx_auth
--

GRANT SELECT ON TABLE auth.future_identity_link TO bnx_backup;


--
-- Name: SEQUENCE future_identity_link_id_seq; Type: ACL; Schema: auth; Owner: bnx_auth
--

GRANT SELECT ON SEQUENCE auth.future_identity_link_id_seq TO bnx_backup;


--
-- Name: TABLE account; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account TO bnx_backup;


--
-- Name: TABLE account_currency; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account_currency TO bnx_backup;


--
-- Name: TABLE account_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account_event TO bnx_backup;


--
-- Name: TABLE account_grant; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account_grant TO bnx_backup;


--
-- Name: TABLE account_ownership_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account_ownership_event TO bnx_backup;


--
-- Name: SEQUENCE account_ownership_event_event_seq_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.account_ownership_event_event_seq_seq TO bnx_backup;


--
-- Name: TABLE account_scope_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.account_scope_event TO bnx_backup;


--
-- Name: SEQUENCE account_scope_event_event_seq_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.account_scope_event_event_seq_seq TO bnx_backup;


--
-- Name: TABLE ai_connection; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.ai_connection TO bnx_backup;


--
-- Name: TABLE ai_connection_token; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.ai_connection_token TO bnx_backup;


--
-- Name: TABLE audit_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.audit_event TO bnx_backup;


--
-- Name: TABLE balance_checkpoint; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.balance_checkpoint TO bnx_backup;


--
-- Name: TABLE bridge_acceptance; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.bridge_acceptance TO bnx_backup;


--
-- Name: TABLE category_version; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.category_version TO bnx_backup;


--
-- Name: TABLE clearing_item; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.clearing_item TO bnx_backup;


--
-- Name: TABLE clearing_item_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.clearing_item_event TO bnx_backup;


--
-- Name: TABLE currency; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.currency TO bnx_backup;


--
-- Name: TABLE document; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.document TO bnx_backup;


--
-- Name: TABLE evidence_access_grant; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.evidence_access_grant TO bnx_backup;


--
-- Name: TABLE evidence_access_log; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.evidence_access_log TO bnx_backup;


--
-- Name: SEQUENCE evidence_access_log_id_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.evidence_access_log_id_seq TO bnx_backup;


--
-- Name: TABLE evidence_archive_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.evidence_archive_event TO bnx_backup;


--
-- Name: TABLE evidence_file; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.evidence_file TO bnx_backup;


--
-- Name: TABLE evidence_object; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.evidence_object TO bnx_backup;


--
-- Name: TABLE fx_override_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.fx_override_event TO bnx_backup;


--
-- Name: TABLE fx_selection_log; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.fx_selection_log TO bnx_backup;


--
-- Name: TABLE household_setting; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.household_setting TO bnx_backup;


--
-- Name: TABLE idempotency; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.idempotency TO bnx_backup;


--
-- Name: TABLE institution; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.institution TO bnx_backup;


--
-- Name: TABLE journal_correction; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.journal_correction TO bnx_backup;


--
-- Name: TABLE journal_entry; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.journal_entry TO bnx_backup;


--
-- Name: SEQUENCE journal_entry_entry_no_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.journal_entry_entry_no_seq TO bnx_backup;


--
-- Name: TABLE journal_line; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.journal_line TO bnx_backup;


--
-- Name: TABLE journal_source; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.journal_source TO bnx_backup;


--
-- Name: TABLE ledger_account; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.ledger_account TO bnx_backup;


--
-- Name: TABLE ledger_state; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.ledger_state TO bnx_backup;


--
-- Name: TABLE m1_future_fact; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.m1_future_fact TO bnx_backup;


--
-- Name: SEQUENCE m1_future_fact_id_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.m1_future_fact_id_seq TO bnx_backup;


--
-- Name: TABLE match_decision_current; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.match_decision_current TO bnx_backup;


--
-- Name: TABLE match_decision_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.match_decision_event TO bnx_backup;


--
-- Name: TABLE member; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.member TO bnx_backup;


--
-- Name: TABLE member_identity; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.member_identity TO bnx_backup;


--
-- Name: TABLE member_session; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.member_session TO bnx_backup;


--
-- Name: TABLE oauth_client; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.oauth_client TO bnx_backup;


--
-- Name: TABLE oauth_code; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.oauth_code TO bnx_backup;


--
-- Name: TABLE opening_anchor; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.opening_anchor TO bnx_backup;


--
-- Name: TABLE outbox; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.outbox TO bnx_backup;


--
-- Name: SEQUENCE outbox_id_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.outbox_id_seq TO bnx_backup;


--
-- Name: TABLE party; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.party TO bnx_backup;


--
-- Name: TABLE plan_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.plan_event TO bnx_backup;


--
-- Name: TABLE posting_batch; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_batch TO bnx_backup;


--
-- Name: TABLE posting_batch_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_batch_event TO bnx_backup;


--
-- Name: TABLE posting_date_confirmation; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_date_confirmation TO bnx_backup;


--
-- Name: TABLE posting_plan; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_plan TO bnx_backup;


--
-- Name: TABLE posting_plan_item; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_plan_item TO bnx_backup;


--
-- Name: TABLE posting_scope_claim; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.posting_scope_claim TO bnx_backup;


--
-- Name: TABLE queue_state; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.queue_state TO bnx_backup;


--
-- Name: TABLE report_snapshot; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.report_snapshot TO bnx_backup;


--
-- Name: TABLE schema_bootstrap; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.schema_bootstrap TO bnx_backup;


--
-- Name: TABLE schema_migrations; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.schema_migrations TO bnx_backup;


--
-- Name: TABLE source_link_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.source_link_event TO bnx_backup;


--
-- Name: SEQUENCE source_link_event_event_id_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.source_link_event_event_id_seq TO bnx_backup;


--
-- Name: TABLE source_txn; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.source_txn TO bnx_backup;


--
-- Name: TABLE source_txn_current_link; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.source_txn_current_link TO bnx_backup;


--
-- Name: TABLE source_txn_link_event_d04_retired; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.source_txn_link_event_d04_retired TO bnx_backup;


--
-- Name: TABLE source_txn_work; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.source_txn_work TO bnx_backup;


--
-- Name: TABLE statement; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.statement TO bnx_backup;


--
-- Name: TABLE statement_event; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.statement_event TO bnx_backup;


--
-- Name: TABLE table_class; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.table_class TO bnx_backup;


--
-- Name: TABLE valuation; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.valuation TO bnx_backup;


--
-- Name: TABLE work_item; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON TABLE bnx.work_item TO bnx_backup;


--
-- Name: SEQUENCE work_item_id_seq; Type: ACL; Schema: bnx; Owner: bnx_definer
--

GRANT SELECT ON SEQUENCE bnx.work_item_id_seq TO bnx_backup;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: auth; Owner: bnx_auth
--

ALTER DEFAULT PRIVILEGES FOR ROLE bnx_auth IN SCHEMA auth GRANT SELECT ON SEQUENCES TO bnx_backup;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: auth; Owner: bnx_auth
--

ALTER DEFAULT PRIVILEGES FOR ROLE bnx_auth IN SCHEMA auth GRANT SELECT ON TABLES TO bnx_backup;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: bnx; Owner: bnx_definer
--

ALTER DEFAULT PRIVILEGES FOR ROLE bnx_definer IN SCHEMA bnx GRANT SELECT ON SEQUENCES TO bnx_backup;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: bnx; Owner: bnx_definer
--

ALTER DEFAULT PRIVILEGES FOR ROLE bnx_definer IN SCHEMA bnx GRANT SELECT ON TABLES TO bnx_backup;


--
-- PostgreSQL database dump complete
--

\unrestrict bRzsuzGeqVuoaa1epojLU8stvEyT2ANot6jb1gEv3Tp1Axvu8nYBh1NvNqOOrdF

