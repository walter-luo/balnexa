-- 9038_s4_collation_independence.sql -- G0 remediation (independent G0 run 2026-11-13, finding G0-IND-01).
-- Two results depended on the database's default collation. Under a linguistic collation (for example ICU en-US, the
-- default of many PostgreSQL installs) 'Canada' sorts before 'CRA', while under C 'CRA' sorts first:
--   MODIFY bnx.config_modules_valid (9003): the sorted module keys were compared with array['CRA','Canada','International'],
--          so every valid configuration was refused (VALIDATION_FAILED, modules) on such a database. Now sorts with
--          collate "C" (byte order, the order of the literal).
--   MODIFY bnx.cmd_propose_institution_candidate (9006): the candidate de-duplication key concatenated the identifiers in
--          collation order, so the same identifiers could give another key after a restore into a database with another
--          collation. Now collate "C". On C-collated databases (CI, local runs, the synthetic instance) both results are
--          unchanged, so no stored key changes there.
-- Authority: S4 G0 remediation; docs/s4/reviews/g0/20261113_chatgpt-codex/. Changed lines are marked "-- 9038".
set role bnx_definer;

create or replace function bnx.config_modules_valid(p jsonb) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select jsonb_typeof(p) = 'object'
     and (select array_agg(k order by k collate "C") from jsonb_object_keys(p) k) = array['CRA','Canada','International']  -- 9038
     and (select bool_and(p->>k in ('YES','NO')) from jsonb_object_keys(p) k)
$$;

create or replace function bnx.cmd_propose_institution_candidate(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); rc jsonb; norm text; j text := upper(cmd->>'jurisdiction'); key text; m uuid[]; c record;
        st text; cid uuid;
begin
  perform bnx.require(a, 1);
  rc := bnx.idem_begin(a, 'propose_institution_candidate', cmd); if rc is not null then return rc; end if;
  norm := coalesce(bnx.normalize_institution_name(cmd->>'name_en'), bnx.normalize_institution_name(cmd->>'name_zh'));
  if norm is null or (j is not null and j !~ '^[A-Z]{2}$') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'name/jurisdiction'); end if;
  select coalesce(array_agg(distinct n.institution_id), '{}') into m from bnx.institution_name n join bnx.institution i on i.id = n.institution_id
   where n.normalized = norm and i.status in ('ACTIVE_SEED','VERIFIED_ACTIVE') and (j is null or i.jurisdiction is null or i.jurisdiction = j);
  if array_length(m, 1) = 1 then
    perform bnx.audit(a, 'propose_institution_candidate', jsonb_build_object('matched_institution_id', m[1]), cmd, null);
    return bnx.idem_end(a, 'propose_institution_candidate', cmd, jsonb_build_object('result', 'MATCHED', 'institution_id', m[1]));
  end if;
  key := norm || '|' || coalesce(j, '--') || '|' || coalesce((select string_agg(x->>'kind' || ':' || (x->>'value'), ',' order by x->>'kind' collate "C", x->>'value' collate "C")  -- 9038
                                                             from jsonb_array_elements(coalesce(cmd->'identifiers', '[]')) x), '');
  st := case when coalesce(array_length(m, 1), 0) > 1 then 'AMBIGUOUS' else 'PENDING_VERIFICATION' end;
  select * into c from bnx.institution_discovery_candidate where candidate_key = key for update;
  if found then
    update bnx.institution_discovery_candidate set evidence = evidence || coalesce(cmd->'evidence', '[]') where id = c.id;
    cid := c.id; st := c.state;
  else
    insert into bnx.institution_discovery_candidate(candidate_key, state, names, jurisdiction, identifiers, evidence, matched_institution_ids, proposed_by)
    values (key, st, jsonb_build_object('en', cmd->>'name_en', 'zh-CN', cmd->>'name_zh'), j, coalesce(cmd->'identifiers', '[]'),
            coalesce(cmd->'evidence', '[]'), m, a.member_id) returning id into cid;
  end if;
  perform bnx.audit(a, 'propose_institution_candidate', jsonb_build_object('candidate_id', cid, 'state', st), cmd, null);
  return bnx.idem_end(a, 'propose_institution_candidate', cmd, jsonb_build_object('result', st, 'candidate_id', cid));
end $$;

-- No catalog delta: neither function's catalog entry changes.

select bnx.apply_grants();
