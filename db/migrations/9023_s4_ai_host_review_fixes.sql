-- 9023_s4_ai_host_review_fixes.sql -- S4 AIH review remediation (independent review RV-AIH, 2026-11-12). Expand-only.
-- Not in the V1.2 migration register (D-AIHR-1).
--   MODIFY: bnx.authn_oauth_client (9021 body; changed only where marked "9023"): a registered redirect URI of a DCR/CIMD
--           client is usable only while it still matches its host profile's allowlist on this instance's environment. A
--           loopback client registered on a synthetic instance stops working when data_class becomes real (RV-AIH-07); the
--           Gateway checks this at GET /oauth/authorize, at describe/deny and again at approval.
set role bnx_definer;

create or replace function bnx.authn_oauth_client(req jsonb) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare c record; cid text := req->>'client_id'; ru text := req->>'redirect_uri'; envr text;                         -- 9023: envr
begin
  if cid is null or length(cid) > 300 or cid !~ '^[ -~]+$' then
    return jsonb_build_object('known', false, 'cimd_allowed', false);
  end if;
  select * into c from bnx.oauth_client where client_id = cid;
  if not found then
    return jsonb_build_object('known', false, 'cimd_allowed',
      exists (select 1 from bnx.host_profile_redirect h where h.kind = 'cimd_client_id' and cid ~ h.pattern));
  end if;
  -- 9023: the environment comes from the instance, as at registration (authn_register_client)
  envr := case when (select value #>> '{}' from bnx.household_setting where key = 'data_class') = 'synthetic' then 'non_production'
               else 'production' end;
  return jsonb_build_object('known', true, 'client_id', c.client_id, 'client_name', c.display_name, 'host_profile', c.host_profile,
    'registration_kind', c.registration_kind,
    'redirect_ok', ru is not null and ru = any(c.redirect_uris)
      and (c.registration_kind = 'PREREGISTERED' or c.host_profile is null                                            -- 9023
           or exists (select 1 from bnx.host_profile_redirect h where h.host_profile = c.host_profile and h.kind = 'redirect_uri'
                       and ru ~ h.pattern and (h.environment = 'any' or envr <> 'production'))));
end $$;

select bnx.apply_grants();
