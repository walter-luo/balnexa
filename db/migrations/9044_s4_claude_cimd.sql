-- Copyright 2026 Walter Luo
-- SPDX-License-Identifier: Apache-2.0
-- 9044_s4_claude_cimd.sql -- Claude's custom connector identifies itself with a Client ID Metadata Document (CIMD).
-- Found on the synthetic test instance on 2026-11-19 (first real AI-host connection, L-AIH-2): Claude (claude.ai web, Desktop,
-- mobile) selects CIMD whenever the authorization server metadata advertises client_id_metadata_document_supported and the
-- auth method "none", which Balnexa does; it then sends client_id = https://claude.ai/oauth/mcp-oauth-client-metadata even when
-- the member picks "Register automatically". The CIMD allowlist (9009) held ChatGPT patterns only, so /oauth/authorize answered
-- "Unknown client or unregistered redirect URI" and nothing reached the consent screen. Observed values (PLATFORM_FACT,
-- 2026-11-19): the authorize request's client_id and redirect_uri, and the metadata document served at that client_id
-- ({"client_id": <same URL>, "client_name": "Claude", "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
-- "token_endpoint_auth_method": "none"}).
--   SEED bnx.host_profile_redirect (9009): claude_remote_mcp cimd_client_id = the exact metadata URL above.
--   SEED bnx.host_profile_redirect (9009): claude_remote_mcp redirect_uri https://claude.com/api/mcp/auth_callback (Anthropic
--        states that the callback may move from claude.ai to claude.com and asks servers that allowlist it to accept both).
-- No function, table or catalog change; existing clients and connections are untouched. The Gateway's CIMD path (fetch once,
-- check client_id and auth method, register as CIMD, host profile inferred from the redirect URIs) is unchanged since AIH-1.
-- Authority: OD-AI-4 (runtime AI = Claude), AIH §4.4; docs/s4/S4_AIH_Implementation_Notes.md (D-AIH-16).
set role bnx_definer;

insert into bnx.host_profile_redirect values
 ('claude_remote_mcp', 'cimd_client_id', '^https://claude\.ai/oauth/mcp-oauth-client-metadata$', 'any', 'PLATFORM_FACT',
  '9044: observed 2026-11-19 (Claude custom connector authorize request and its metadata document)'),
 ('claude_remote_mcp', 'redirect_uri', '^https://claude\.com/api/mcp/auth_callback$', 'any', 'PLATFORM_FACT',
  '9044: Claude connector documentation (callback may change to claude.com)');

select bnx.apply_grants();
