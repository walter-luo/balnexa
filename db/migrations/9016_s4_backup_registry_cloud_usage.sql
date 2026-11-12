-- 9016_s4_backup_registry_cloud_usage.sql -- S4 V1.2 backup/DR registries, cloud usage and admission, restore preamble
-- generator (UA V1.2 §9.2-§9.5; Draft-04 Backup and DR §3-§10 and Cloud Cost and Quota Model §5-§7; OBJ-030, OBJ-256, OBJ-257,
-- OBJ-334, OBJ-344; S4B-F10/F11/F24; 9011R R-09/R-10/R-11; G0R F-06). Expand-only. Synthetic data only; no cloud resource is
-- created, configured or contacted by anything in this file.
--   NEW: bnx.bkp_header_facts (SECURITY INVOKER, STABLE; the only function bnx_backup may EXECUTE: the header facts of UA §9.3
--        step 3, read inside the exported snapshot), bnx.bkp_header_compare, bnx.restore_preamble (generated from
--        bnx.migration_seeded_table and bnx.schema_registry; installer/drill identity only),
--        registries bnx.backup_key_registry + bnx.backup_key_event (fingerprints only, K2), bnx.backup_run, bnx.restore_drill,
--        bnx.restore_authorization, bnx.evidence_verification, bnx.audit_verification, bnx.cloud_usage, bnx.cost_policy,
--        bnx.capacity_event, bnx.admission_decision (all append-only),
--        promoters wrk_backup_recorded / wrk_evidence_state / wrk_restore_drill_recorded for the staging kinds that 9010 has
--        kept AWAITING_PROMOTER, wrk_backup_due, wrk_backup_key_pruned, wrk_audit_verified, wrk_cloud_usage_record,
--        wrk_capacity_update, wrk_admission_decide, Owner commands cmd_backup_key_register, cmd_backup_key_mark_compromised,
--        cmd_authorize_restore, cmd_set_cost_policy, queries q_backup_status, q_cost_status.
--   MODIFY: bnx.apply_grants (9002) and bnx.audit_privileges (9011): bnx_backup may EXECUTE exactly the bkp_* functions that
--        are SECURITY INVOKER and not VOLATILE (they run with bnx_backup's own read-only rights); bnx.wrk_promote_staged
--        (9011): dispatches backup_recorded and restore_drill_recorded; bnx.migration_seeded_table (9002): column
--        truncate_on_restore (UA V1.2 §5.1).
set role bnx_definer;

-- =====================================================================================================================
-- Part 1. Header facts (UA §9.3 step 3), comparison and the generated restore preamble (step 9; S4B-F10 b, S4B-F11)
-- =====================================================================================================================
alter table bnx.migration_seeded_table add column truncate_on_restore boolean not null default true;

-- Header facts of the database as seen by the caller's snapshot. Invoker rights: executed by bnx_backup inside
-- BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY + pg_export_snapshot(), so it can only read what bnx_backup reads. The
-- output depends on table content only (no clock, no server version, no session setting): the same function on the restored
-- database must return the same value (AT-BAK-04). Row text is canonical: the function fixes every output-affecting setting.
create function bnx.bkp_header_facts() returns jsonb
language plpgsql stable
set search_path = pg_catalog, pg_temp set timezone = 'UTC' set datestyle = 'ISO, YMD' set intervalstyle = 'postgres'
set bytea_output = 'hex' set extra_float_digits = '1'
as $$
declare r record; tabs jsonb := '{}'; n bigint; d text; total bigint := 0;
begin
  for r in select ns.nspname, c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
            where ns.nspname in (select nspname from bnx.schema_registry) and c.relkind = 'r' and not c.relispartition
              and not (ns.nspname = 'bnx' and c.relname in ('schema_migrations','schema_bootstrap'))
            order by ns.nspname collate "C", c.relname collate "C" loop
    execute format('select count(*), encode(sha256(convert_to(coalesce(string_agg(t::text, E''\n'' order by t::text collate "C"), ''''), '
                   '''UTF8'')), ''hex'') from %I.%I t', r.nspname, r.relname) into n, d;
    tabs := tabs || jsonb_build_object(r.nspname || '.' || r.relname, jsonb_build_object('rows', n, 'sha256', d));
    total := total + n;
  end loop;
  return jsonb_build_object(
    'format', 'bnx-backup-header-facts/1',
    'ledger_version', (select version from bnx.ledger_state),
    'audit_head', coalesce((select jsonb_build_object('seq', seq, 'hash', encode(hash, 'hex'), 'chain_version', chain_version)
                              from bnx_audit.audit_event order by seq desc limit 1), jsonb_build_object('seq', 0)),
    'migrations', coalesce((select jsonb_agg(jsonb_build_object('version', version, 'sha256', sha256) order by version collate "C")
                              from bnx.schema_migrations), '[]'),
    'config', (select jsonb_build_object('version', config_version, 'sha256', config_sha256) from bnx.config_version_anchor where state = 'ACTIVE'),
    'instance', (select jsonb_build_object('project_id', project_id, 'instance_uid', instance_uid, 'origin', origin) from bnx.instance_identity),
    'trial_balance', coalesce((select jsonb_object_agg(currency, jsonb_build_object('lines', k, 'sum', s::text, 'debits', dr::text))
                                 from (select currency, count(*) k, sum(amount) s, coalesce(sum(amount) filter (where amount > 0), 0) dr
                                         from bnx.journal_line group by currency) x), '{}'),
    'schemas', (select jsonb_agg(nspname order by nspname collate "C") from bnx.schema_registry),
    'row_total', total,
    'tables', tabs);
end $$;

-- Keys whose values differ (or exist on one side only); tables are compared one by one. Empty array = equal.
create function bnx.bkp_header_compare(a jsonb, b jsonb) returns jsonb
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select coalesce(jsonb_agg(k order by k collate "C"), '[]') from (
    select x k from (select jsonb_object_keys(coalesce(a, '{}')) x union select jsonb_object_keys(coalesce(b, '{}'))) u
     where x <> 'tables' and (a->x) is distinct from (b->x)
    union all
    select 'tables.' || t from (select jsonb_object_keys(coalesce(a->'tables', '{}')) t union select jsonb_object_keys(coalesce(b->'tables', '{}'))) v
     where (a->'tables'->t) is distinct from (b->'tables'->t)) z
$$;

-- The restore preamble, generated (never hand-written): the dump scope, the seeded tables to truncate before a data-only
-- load, the tables that are compared but never loaded, the load identities and the ordered loads (R-10). The SQL part runs
-- as bnx_migrator under SET ROLE bnx_definer with bnx.restore_mode = on and refuses a target that holds non-seeded data
-- (a restore never overwrites a live database: Draft-04 INV-45, AT-BKP-15).
create function bnx.restore_preamble() returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare sch text[]; trunc text[]; never text[] := array['bnx.schema_migrations','bnx.schema_bootstrap']; sql text;
begin
  select array_agg(nspname order by nspname collate "C") into sch from bnx.schema_registry;
  select array_agg(table_name order by table_name collate "C") into trunc from bnx.migration_seeded_table where truncate_on_restore;
  sql := 'set role bnx_definer;' || E'\n' || 'set local bnx.restore_mode = ''on'';' || E'\n'
      || 'do $g$ declare r record; n bigint; begin' || E'\n'
      || '  for r in select ns.nspname, c.relname from pg_class c join pg_namespace ns on ns.oid = c.relnamespace' || E'\n'
      || '            where ns.nspname = any(' || quote_literal(sch::text) || '::text[]) and ns.nspname <> ''auth'' and c.relkind = ''r''' || E'\n'
      || '              and (ns.nspname || ''.'' || c.relname) <> all(' || quote_literal((trunc || never)::text) || '::text[]) loop' || E'\n'
      || '    execute format(''select count(*) from %I.%I'', r.nspname, r.relname) into n;' || E'\n'
      || '    if n > 0 then raise exception ''RESTORE_TARGET_NOT_EMPTY: %.% holds % rows'', r.nspname, r.relname, n using errcode = ''P0409''; end if;' || E'\n'
      || '  end loop; end $g$;' || E'\n'
      || 'truncate ' || array_to_string(trunc, ', ') || ' cascade;' || E'\n';
  return jsonb_build_object('format', 'bnx-restore-preamble/1',
    'schemas', to_jsonb(sch),
    'pg_dump_args', to_jsonb(array['--format=custom', '--data-only'] || array(select '--schema=' || s from unnest(sch) s)),
    'truncate', to_jsonb(trunc), 'never_load', to_jsonb(never),
    'load_identity', jsonb_build_object('auth', 'bnx_auth', '*', 'bnx_migrator (SET ROLE bnx_definer; bnx.restore_mode = on)'),
    'ordered_loads', jsonb_build_object('bnx_audit.audit_event', 'seq'),
    'post_checks', jsonb_build_array('bnx.bkp_header_facts() equals the backup header facts (bnx.bkp_header_compare = [])',
                                     'bnx.audit_verify() = 0', 'bnx.assert_journal_complete for every journal', 'q_balances equal'),
    'sql', sql);
end $$;

-- =====================================================================================================================
-- Part 2. Registries (append-only). Key custody K2 (OBJ-344, SEC-K): fingerprints only, never key material.
-- =====================================================================================================================
create table bnx.backup_key_registry(key_id text primary key check (key_id ~ '^[a-z0-9][a-z0-9._-]{2,63}$'),
  role text not null check (role in ('OWNER','DRILL')),
  recipient_fingerprint text not null unique check (recipient_fingerprint ~ '^[0-9a-f]{64}$'),   -- SHA-256 of the age recipient
  note text check (note is null or (length(note) <= 200 and note !~* 'AGE-SECRET-KEY')),
  registered_by uuid not null references bnx.member, registered_at timestamptz not null default now());

create table bnx.backup_key_event(key_id text not null references bnx.backup_key_registry, seq int not null,
  event text not null check (event in ('ACTIVATED','RETIRED','COMPROMISED','PRUNED')),
  handling text check (handling is null or handling in ('KEEP_FOR_DRILLS','OWNER_KEY_TEST_ONLY')),
  by_member uuid references bnx.member, by_session text not null default session_user, detail jsonb not null default '{}',
  at timestamptz not null default now(), primary key (key_id, seq),
  check ((event = 'COMPROMISED') = (handling is not null)));

create table bnx.backup_run(run_id uuid primary key, staging_id uuid not null unique references bnx_intake.staging_payload,
  started_at timestamptz not null, ended_at timestamptz not null, local_date date not null,
  tier text not null check (tier in ('DAILY','WEEKLY','MONTHLY')), retain_until timestamptz not null,
  policy text not null check (policy in ('P-A','P-B','P-C','P-D')), destination text not null check (destination in ('OFF_PROVIDER')),
  outcome text not null check (outcome in ('VERIFIED','FAILED')), failure_reason text check (failure_reason is null or length(failure_reason) <= 200),
  object_name text check (object_name is null or object_name ~ '^[A-Za-z0-9/_.-]{1,200}$'), object_generation text,
  dump_sha256 text check (dump_sha256 ~ '^[0-9a-f]{64}$'), plaintext_sha256 text check (plaintext_sha256 ~ '^[0-9a-f]{64}$'),
  header_file_sha256 text check (header_file_sha256 ~ '^[0-9a-f]{64}$'),
  compressed_bytes bigint check (compressed_bytes >= 0), wire_bytes bigint check (wire_bytes >= 0),
  pg_dump_version text, pg_restore_version text, server_version text,
  owner_key_id text references bnx.backup_key_registry, drill_key_id text references bnx.backup_key_registry,
  header_facts jsonb, header_facts_sha256 bytea, migrations_sha256 bytea, ledger_version bigint,
  anchor_seq bigint, anchor_hash text check (anchor_hash is null or anchor_hash ~ '^[0-9a-f]{64}$'),
  anchor_check text check (anchor_check in ('MATCH','MISMATCH','EMPTY_CHAIN')),
  recorded_at timestamptz not null default now(),
  check (ended_at >= started_at and retain_until > started_at),
  check (outcome = 'FAILED' or (object_name is not null and object_generation is not null and dump_sha256 is not null and plaintext_sha256 is not null
         and header_facts is not null and owner_key_id is not null and drill_key_id is not null and anchor_check is not null)),
  check ((outcome = 'FAILED') = (failure_reason is not null)));
create unique index backup_run_one_verified_per_local_date on bnx.backup_run(local_date) where outcome = 'VERIFIED';

create table bnx.restore_authorization(id uuid primary key default gen_random_uuid(), backup_run_id uuid not null references bnx.backup_run,
  target text not null check (target in ('PRODUCTION','NEW_PROJECT')), reason text not null check (length(reason) between 3 and 300),
  authorized_by uuid not null references bnx.member, authorized_at timestamptz not null default now(),
  expires_at timestamptz not null, check (expires_at > authorized_at and expires_at <= authorized_at + interval '24 hours'));

create table bnx.restore_drill(drill_id uuid primary key, staging_id uuid not null unique references bnx_intake.staging_payload,
  backup_run_id uuid not null references bnx.backup_run,
  kind text not null check (kind in ('DRILL','RESTORE_SAME_IDENTITY','RESTORE_AS_NEW')),
  target text not null check (target in ('ISOLATED_DRILL','NEW_PROJECT','PRODUCTION')),
  decrypt_key_id text not null references bnx.backup_key_registry, started_at timestamptz not null, ended_at timestamptz not null,
  duration_seconds numeric(12,3) not null check (duration_seconds >= 0),
  reported_outcome text not null check (reported_outcome in ('PASS','FAIL')),
  outcome text not null check (outcome in ('PASS','FAIL')), reasons text[] not null default '{}',
  header_mismatches jsonb not null default '[]', cleanup_verified boolean not null, pg_restore_version text, server_version text,
  authorization_id uuid unique references bnx.restore_authorization, recorded_at timestamptz not null default now(),
  check (outcome = 'FAIL' or (reasons = '{}' and header_mismatches = '[]')),
  check (ended_at >= started_at));

create table bnx.evidence_verification(id bigint generated always as identity primary key,
  staging_id uuid not null references bnx_intake.staging_payload, evidence_object_id uuid not null references bnx.evidence_object,
  copy text not null check (copy in ('R2','DRIVE')), observed_sha256 text not null check (observed_sha256 ~ '^[0-9a-f]{64}$'),
  result text not null check (result in ('MATCH','MISMATCH','NO_REFERENCE')), evidence_status text not null,
  verified_at timestamptz not null default now(), unique (staging_id, evidence_object_id, copy));

create table bnx.audit_verification(id bigint generated always as identity primary key,
  source text not null check (source in ('WORKER_TICK','EXTERNAL_VERIFIER')),
  head_seq bigint not null, head_hash text, first_bad_seq bigint not null default 0,
  anchor_run_id uuid references bnx.backup_run, anchor_seq bigint, anchor_hash text,
  anchor_result text not null check (anchor_result in ('MATCH','MISMATCH','NO_ANCHOR','UNKNOWN_ANCHOR')),
  result text not null check (result in ('INTACT','FAILED')), tool_version text check (tool_version is null or length(tool_version) <= 40),
  verified_at timestamptz not null default now());

-- usage ledger (Cost §6.1): one row per execution and phase; EXPECTED (Worker at launch) < ACTUAL (job at exit) < RECONCILED
-- (billing export); the highest phase of an execution counts
create table bnx.cloud_usage(id bigint generated always as identity primary key,
  execution_id text not null check (execution_id ~ '^[A-Za-z0-9._:-]{1,120}$'),
  phase text not null check (phase in ('EXPECTED','ACTUAL','RECONCILED')),
  provider text not null check (provider in ('GCP_RUN','NEON','R2','GCS')),
  project text not null check (project in ('bnx-exec','bnx-vault','neon','r2')),
  job text not null check (job ~ '^[A-Z_]{2,40}$'), started_at timestamptz not null, ended_at timestamptz,
  instance_seconds numeric(14,3) not null default 0 check (instance_seconds >= 0), vcpu numeric(6,2) check (vcpu > 0),
  gib numeric(6,2) check (gib > 0), gross_estimate numeric(14,6) not null default 0 check (gross_estimate >= 0),
  egress_bytes bigint not null default 0 check (egress_bytes >= 0), cu_hours numeric(12,4) not null default 0 check (cu_hours >= 0),
  storage_bytes bigint check (storage_bytes >= 0), billing_month date not null check (extract(day from billing_month) = 1),
  recorded_by text not null default session_user, recorded_at timestamptz not null default now(),
  unique (execution_id, phase), check (ended_at is null or ended_at >= started_at));

-- cost policy (Cost §5.1, §5.3, §6.3): versioned; v1 = SC-V1 design default. Changing caps is an Owner decision, never automatic.
create table bnx.cost_policy(version int primary key check (version > 0),
  spend_cap_variant text not null check (spend_cap_variant in ('SC-V1','SC-V2','SC-V3')),
  exec_allocation numeric(8,4) not null check (exec_allocation > 0), vault_allocation numeric(8,4) not null check (vault_allocation >= 0),
  internal_ceiling_pct numeric(5,4) not null check (internal_ceiling_pct > 0 and internal_ceiling_pct <= 1),
  backup_reserve numeric(8,4) not null check (backup_reserve >= 0),
  gross_rate_2gib numeric(12,9) not null check (gross_rate_2gib > 0), gross_rate_1gib numeric(12,9) not null check (gross_rate_1gib > 0),
  execution_overhead_seconds int not null check (execution_overhead_seconds >= 60),
  neon_egress_bytes bigint not null check (neon_egress_bytes > 0), neon_backup_egress_pct numeric(5,4) not null,
  neon_storage_bytes bigint not null check (neon_storage_bytes > 0), neon_storage_pause_pct numeric(5,4) not null,
  neon_cu_hours numeric(8,2) not null check (neon_cu_hours > 0), neon_cu_pause_pct numeric(5,4) not null,
  run_egress_pause_bytes bigint not null, probe_backoff_hours int not null check (probe_backoff_hours between 1 and 48),
  declared_by uuid references bnx.member, declared_at timestamptz not null default now(), note text not null,
  check (spend_cap_variant <> 'SC-V2' or declared_by is not null));         -- SC-V2 needs explicit Owner approval (Cost §5.1)
insert into bnx.cost_policy(version, spend_cap_variant, exec_allocation, vault_allocation, internal_ceiling_pct, backup_reserve,
  gross_rate_2gib, gross_rate_1gib, execution_overhead_seconds, neon_egress_bytes, neon_backup_egress_pct, neon_storage_bytes,
  neon_storage_pause_pct, neon_cu_hours, neon_cu_pause_pct, run_egress_pause_bytes, probe_backoff_hours, note)
values (1, 'SC-V1', 0.85, 0.15, 0.70, 0.10, 0.000022, 0.000020, 60, 5368709120, 0.60, 1073741824, 0.80, 100, 0.80, 858993459, 6,
        'migration 9016: Cloud Cost and Quota Model R6.2-Draft-04 §5-§6 design defaults (estimates; M0-F replaces them)');

create table bnx.capacity_event(id bigint generated always as identity primary key,
  scope text not null check (scope in ('bnx-exec','bnx-vault')),
  state text not null check (state in ('normal','throttled_internal','provider_capped','provider_error')),
  signal text not null check (signal in ('budget_notification','launch_refused','task_killed','probe_result','usage_ledger','provider_error')),
  threshold_pct int check (threshold_pct is null or threshold_pct in (50, 80, 100)), next_probe_at timestamptz,
  billing_month date not null, detail jsonb not null default '{}', at timestamptz not null default now());

create table bnx.admission_decision(id bigint generated always as identity primary key,
  job text not null check (job ~ '^[A-Z_]{2,40}$'), admission_class text not null check (admission_class in ('backup','drill','maintenance','interactive','bulk')),
  scope text not null check (scope in ('bnx-exec','bnx-vault')), planned_items int not null check (planned_items >= 1),
  estimate_gross numeric(14,6) not null, month_gross numeric(14,6) not null, ceiling numeric(14,6) not null,
  admitted boolean not null, reason text not null, priority int not null, policy_version int not null references bnx.cost_policy,
  billing_month date not null, decided_at timestamptz not null default now());

do $$
declare t text;
begin
  foreach t in array array['backup_key_registry','backup_key_event','backup_run','restore_authorization','restore_drill',
                           'evidence_verification','audit_verification','cloud_usage','cost_policy','capacity_event','admission_decision'] loop
    execute format('create trigger t_append_only before update or delete on bnx.%I for each row execute function bnx.trg_append_only()', t);
  end loop;
end $$;
insert into bnx.table_class values ('backup_key_registry','F'),('backup_key_event','F'),('backup_run','F'),('restore_authorization','F'),
  ('restore_drill','F'),('evidence_verification','F'),('audit_verification','F'),('cloud_usage','F'),('cost_policy','F'),
  ('capacity_event','F'),('admission_decision','F');
insert into bnx.migration_seeded_table(table_name, seeded_by, note) values ('bnx.cost_policy', '9016', 'cost policy v1 (SC-V1 design defaults)');

-- =====================================================================================================================
-- Part 3. Derived state: key state, retention tier, backup policy, restorability, capacity, month usage
-- =====================================================================================================================
create function bnx.backup_local_tz() returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select household_timezone from bnx.financial_policy order by version desc limit 1), 'America/Toronto')
$$;

-- latest event of a key at a time (NULL before activation)
create function bnx.backup_key_state(p_key text, p_at timestamptz default now()) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select event from bnx.backup_key_event where key_id = p_key and at <= p_at order by seq desc limit 1
$$;

-- the key that was ACTIVE for a role at a time (rotation retires the previous one in the same transaction)
create function bnx.backup_key_active(p_role text, p_at timestamptz default now()) returns text
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select k.key_id from bnx.backup_key_registry k where k.role = p_role and bnx.backup_key_state(k.key_id, p_at) = 'ACTIVATED'
   order by k.registered_at desc limit 1
$$;

-- prune_after(key) = max(retain_until) of the runs encrypted to it (Backup §10.4)
create function bnx.backup_key_prune_after(p_key text) returns timestamptz
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select max(retain_until) from bnx.backup_run where drill_key_id = p_key or owner_key_id = p_key
$$;

-- Retention tier of a run that starts at p_at (Backup §3): local 1st of month -> MONTHLY 366 d; local Sunday -> WEEKLY 28 d;
-- otherwise DAILY 7 d; the longest applicable wins. Local = household timezone (DST-safe: dates, not hours).
create function bnx.backup_tier(p_at timestamptz) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with d as (select (p_at at time zone bnx.backup_local_tz())::date ld)
  select jsonb_build_object('local_date', ld,
    'tier', case when extract(day from ld) = 1 then 'MONTHLY' when extract(isodow from ld) = 7 then 'WEEKLY' else 'DAILY' end,
    'retain_until', p_at + case when extract(day from ld) = 1 then interval '366 days' when extract(isodow from ld) = 7 then interval '28 days'
                                else interval '7 days' end)
  from d
$$;

-- Egress-aware policy (Backup §5) from the latest measured wire size W of a verified off-provider run; budget = 60 % of the
-- Neon monthly egress. No measurement yet -> P-A.
create function bnx.backup_policy() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare cp bnx.cost_policy; w bigint; budget numeric; p text;
begin
  select * into cp from bnx.cost_policy order by version desc limit 1;
  select wire_bytes into w from bnx.backup_run where outcome = 'VERIFIED' and wire_bytes is not null order by started_at desc limit 1;
  budget := cp.neon_egress_bytes * cp.neon_backup_egress_pct;
  p := case when w is null or 30 * w <= budget then 'P-A' when 5 * w <= budget then 'P-B' when 3 * w <= budget then 'P-C' else 'P-D' end;
  return jsonb_build_object('policy', p, 'wire_bytes', w, 'budget_bytes', floor(budget)::bigint);
end $$;

-- Restorable (Backup §6 step 8, §8): verified, and a passing drill of this run or of a later run with the same migration set,
-- and no failed drill on that migration set after the latest pass.
create function bnx.backup_restorable(p_run uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with r as (select * from bnx.backup_run where run_id = p_run and outcome = 'VERIFIED'),
       ds as (select d.outcome, d.recorded_at, d.drill_id from bnx.restore_drill d join bnx.backup_run b on b.run_id = d.backup_run_id
                join r on b.migrations_sha256 = r.migrations_sha256),
       lastpass as (select max(d.recorded_at) t from bnx.restore_drill d join bnx.backup_run b on b.run_id = d.backup_run_id
                      join r on b.migrations_sha256 = r.migrations_sha256 and b.started_at >= r.started_at where d.outcome = 'PASS')
  select exists (select 1 from r) and (select t from lastpass) is not null
     and not exists (select 1 from ds where ds.outcome = 'FAIL' and ds.recorded_at > (select t from lastpass))
$$;

create function bnx.billing_month(p_at timestamptz) returns date
language sql immutable set search_path = pg_catalog, pg_temp as $$ select date_trunc('month', p_at at time zone 'UTC')::date $$;

-- usage of the month: highest phase per execution
create function bnx.usage_month(p_month date) returns table(project text, gross numeric, egress bigint, cu numeric, storage bigint)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  with cur as (select distinct on (execution_id) * from bnx.cloud_usage where billing_month = p_month
                order by execution_id, case phase when 'RECONCILED' then 3 when 'ACTUAL' then 2 else 1 end desc)
  select p.project, coalesce(sum(c.gross_estimate), 0), coalesce(sum(c.egress_bytes), 0)::bigint, coalesce(sum(c.cu_hours), 0),
         (select u.storage_bytes from bnx.cloud_usage u where u.project = p.project and u.billing_month = p_month and u.storage_bytes is not null
           order by u.recorded_at desc, u.id desc limit 1)
    from (values ('bnx-exec'), ('bnx-vault'), ('neon'), ('r2')) p(project) left join cur c on c.project = p.project
   group by p.project
$$;

-- capacity state of a scope now: the latest event of this billing month; a month that starts after a capped month starts in
-- probe_pending (Cost §7: the first admitted execution after the reset is a one-item batch)
create function bnx.capacity_state(p_scope text, p_at timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare e bnx.capacity_event; prev bnx.capacity_event; m date := bnx.billing_month(p_at);
begin
  select * into e from bnx.capacity_event where scope = p_scope and billing_month = m and at <= p_at order by at desc, id desc limit 1;
  if found then
    return jsonb_build_object('state', e.state, 'since', e.at, 'next_probe_at', e.next_probe_at, 'signal', e.signal);
  end if;
  select * into prev from bnx.capacity_event where scope = p_scope and billing_month < m order by at desc, id desc limit 1;
  if found and prev.state in ('provider_capped','provider_error') then
    return jsonb_build_object('state', 'probe_pending', 'since', m, 'next_probe_at', null, 'signal', 'period_reset');
  end if;
  return jsonb_build_object('state', 'normal', 'since', null, 'next_probe_at', null, 'signal', null);
end $$;

-- refuse key material and over-long values anywhere in a payload (K2: the private key never enters any cloud store)
create function bnx.backup_payload_ok(p jsonb) returns boolean
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select p::text !~* 'AGE-SECRET-KEY' and octet_length(p::text) <= 262144
$$;

create function bnx.backup_hex(p text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$ select case when p ~ '^[0-9a-f]{64}$' then p end $$;

create function bnx.backup_major(p text) returns int
language sql immutable set search_path = pg_catalog, pg_temp as $$ select nullif(substring(coalesce(p, '') from '^([0-9]+)'), '')::int $$;

-- Result payload contract (DELEGATED_DECISION D-9016-5): staged payloads pass the 9011 SIN guard (stage_write refuses any
-- Luhn-valid 9-digit run, a deliberate Owner rule), so a result never carries a bare byte count (100 MB ... 1 GB dumps are
-- 9-digit byte counts) or a path with an embedded UUID: sizes travel in KiB and the object name is derived here from run_id;
-- hex values travel only under keys the guard exempts as machine digests (suffix _sha256, e.g. drill_fingerprint_sha256).
create function bnx.backup_object_name(p_started timestamptz, p_run uuid) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select 'bnx-vault-backups/' || to_char(p_started at time zone 'UTC', 'YYYY/MM') || '/' || p_run::text || '.age'
$$;

-- =====================================================================================================================
-- Part 4. Owner commands (T3; Owner only; the database refuses them on an AI connection through bnx.require)
-- =====================================================================================================================
create function bnx.backup_owner(a bnx.actor) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.require(a, 3) <> 'owner' then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
end $$;

-- register a recipient fingerprint; the role's previously ACTIVE key is RETIRED in the same transaction (rotation)
create function bnx.cmd_backup_key_register(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); prev text; k text := cmd->>'key_id'; r text := cmd->>'role';
begin
  perform bnx.backup_owner(a);
  if not bnx.backup_payload_ok(cmd) then perform bnx.fail('KEY_MATERIAL_REFUSED', 'P0422', 'fingerprints only; never key material'); end if;
  if bnx.backup_hex(cmd->>'recipient_fingerprint_sha256') is null then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'recipient_fingerprint_sha256 (64 hex)'); end if;
  perform pg_advisory_xact_lock(hashtext('bnx.backup_key'));
  prev := bnx.backup_key_active(r);
  begin
    insert into bnx.backup_key_registry(key_id, role, recipient_fingerprint, note, registered_by) values (k, r, cmd->>'recipient_fingerprint_sha256', cmd->>'note', a.member_id);
  exception when check_violation or not_null_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'key');
            when unique_violation then perform bnx.fail('KEY_EXISTS', 'P0409');
  end;
  if prev is not null then
    insert into bnx.backup_key_event(key_id, seq, event, by_member, detail)
    values (prev, (select max(seq) + 1 from bnx.backup_key_event where key_id = prev), 'RETIRED', a.member_id, jsonb_build_object('superseded_by', k));
  end if;
  insert into bnx.backup_key_event(key_id, seq, event, by_member) values (k, 1, 'ACTIVATED', a.member_id);
  perform bnx.audit(a, 'backup_key_register', jsonb_build_object('key_id', k, 'role', r), cmd, null);
  return jsonb_build_object('key_id', k, 'role', r, 'state', 'ACTIVATED', 'retired', prev);
end $$;

-- Backup §10.4: the Owner decides at the time of a compromise how objects encrypted to the key are handled (option a/b)
create function bnx.cmd_backup_key_mark_compromised(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); k text := cmd->>'key_id'; st text; hd text := cmd->>'handling';
begin
  perform bnx.backup_owner(a);
  perform pg_advisory_xact_lock(hashtext('bnx.backup_key'));
  st := bnx.backup_key_state(k);
  if st is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if st in ('PRUNED','COMPROMISED') then perform bnx.fail('KEY_STATE', 'P0409', st); end if;
  if hd is null or hd not in ('KEEP_FOR_DRILLS','OWNER_KEY_TEST_ONLY') then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'handling'); end if;
  insert into bnx.backup_key_event(key_id, seq, event, handling, by_member, detail)
  values (k, (select max(seq) + 1 from bnx.backup_key_event where key_id = k), 'COMPROMISED', hd, a.member_id,
          jsonb_build_object('exposed_runs', (select count(*) from bnx.backup_run where (drill_key_id = k or owner_key_id = k) and retain_until > now())));
  perform bnx.notify('EXCEPTION', 'BACKUP_KEY_COMPROMISED:' || k, true, jsonb_build_object('kind', 'BACKUP_KEY_COMPROMISED', 'record_key', k));
  perform bnx.audit(a, 'backup_key_mark_compromised', jsonb_build_object('key_id', k), cmd, null);
  return jsonb_build_object('key_id', k, 'state', 'COMPROMISED', 'handling', hd,
    'next', 'register a new key of the same role; new backups use it (Backup §10.4 step 1)');
end $$;

-- Owner authorization for a restore that targets production or a new project (Draft-04 INV-45; AT-BKP-15); one use, 24 h
create function bnx.cmd_authorize_restore(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); id uuid;
begin
  perform bnx.backup_owner(a);
  if not exists (select 1 from bnx.backup_run where run_id = (cmd->>'backup_run_id')::uuid and outcome = 'VERIFIED') then
    perform bnx.fail('NOT_AVAILABLE', 'P0404'); end if;
  begin
    insert into bnx.restore_authorization(backup_run_id, target, reason, authorized_by, expires_at)
    values ((cmd->>'backup_run_id')::uuid, cmd->>'target', cmd->>'reason', a.member_id, now() + interval '24 hours') returning restore_authorization.id into id;
  exception when check_violation or not_null_violation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'authorization');
  end;
  perform bnx.audit(a, 'authorize_restore', jsonb_build_object('authorization_id', id), cmd, null);
  return jsonb_build_object('authorization_id', id, 'expires_in_hours', 24);
end $$;

-- a new cost policy version (caps and ceilings are Owner decisions; Balnexa never raises a vendor cap)
create function bnx.cmd_set_cost_policy(cred jsonb, cmd jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); cur bnx.cost_policy; v int; j jsonb;
begin
  perform bnx.backup_owner(a);
  perform pg_advisory_xact_lock(hashtext('bnx.cost_policy'));
  select * into cur from bnx.cost_policy order by version desc limit 1;
  if exists (select 1 from jsonb_object_keys(cmd) k where k not in ('spend_cap_variant','exec_allocation','vault_allocation','internal_ceiling_pct',
       'backup_reserve','note','idempotency_key')) then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'only caps, ceilings, reserve and note may change'); end if;
  if coalesce(cmd->>'note', '') = '' then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'note'); end if;
  j := to_jsonb(cur) || (cmd - 'note' - 'idempotency_key') || jsonb_build_object('version', cur.version + 1, 'note', cmd->>'note', 'declared_by', a.member_id,
                                                              'declared_at', now());
  begin
    insert into bnx.cost_policy select * from jsonb_populate_record(null::bnx.cost_policy, j) returning version into v;
  exception when check_violation or not_null_violation or invalid_text_representation then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'cost policy');
  end;
  perform bnx.audit(a, 'set_cost_policy', jsonb_build_object('version', v), cmd, null);
  return jsonb_build_object('version', v);
end $$;

-- =====================================================================================================================
-- Part 5. Promoters of the staged Executor results (UA §9.2: stg_* -> staging_payload -> Worker tick -> wrk_*)
-- =====================================================================================================================
-- BACKUP result (UA §9.3 steps 7-8). The database recomputes tier, retention, local date and policy, checks the recipients
-- against the registry (K2: Owner + current drill key, both ACTIVE at the start), the tool majors, the verification steps,
-- and the audit anchor (R-11 / G0R F-06): the recorded head (seq, hash) must be the live chain's row at that seq.
create function bnx.wrk_backup_recorded(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; job text; t jsonb; why text; st timestamptz; en timestamptz; hf jsonb; ac text; aseq bigint; ahash text;
        live bytea; outc text; pol jsonb; ok_keys text[] := array['run_id','started_at','ended_at','local_date','tier','retain_until',
        'destination','outcome','failure_reason','object','sizes','dump_sha256','plaintext_sha256','header_sha256','tools','verify',
        'recipients','header','usage'];
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id where p.id = p_staging for update of p;
  if not found or s.stg_kind <> 'backup_recorded' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  if s.job_kind = 'EVIDENCE_VERIFY' then return bnx.wrk_evidence_state(p_staging); end if;
  pl := s.payload;
  if not bnx.backup_payload_ok(pl) then
    perform bnx.notify('EXCEPTION', 'BACKUP_KEY_MATERIAL:' || p_staging, true, jsonb_build_object('kind', 'BACKUP_KEY_MATERIAL_IN_PAYLOAD', 'record_key', p_staging::text));
    return bnx.doc_reject(p_staging, 'KEY_MATERIAL_REFUSED');
  end if;
  if exists (select 1 from jsonb_object_keys(pl) k where k <> all(ok_keys))
     or (pl ? 'object' and (jsonb_typeof(pl->'object') <> 'object' or exists (select 1 from jsonb_object_keys(pl->'object') k where k <> 'generation')))
     or (pl ? 'sizes' and (jsonb_typeof(pl->'sizes') <> 'object' or exists (select 1 from jsonb_object_keys(pl->'sizes') k where k not in ('compressed_kib','wire_kib')))) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  begin
    st := (pl->>'started_at')::timestamptz; en := (pl->>'ended_at')::timestamptz;
  exception when others then return bnx.doc_reject(p_staging, 'TIMES');
  end;
  if st is null or en is null or en < st or pl->>'run_id' !~ '^[0-9a-f-]{36}$' then return bnx.doc_reject(p_staging, 'TIMES_OR_RUN_ID'); end if;
  if exists (select 1 from bnx.backup_run where run_id = (pl->>'run_id')::uuid) then return bnx.doc_reject(p_staging, 'DUPLICATE_RUN'); end if;
  t := bnx.backup_tier(st); pol := bnx.backup_policy(); outc := pl->>'outcome';
  if outc not in ('VERIFIED','FAILED') then return bnx.doc_reject(p_staging, 'OUTCOME'); end if;
  if coalesce(pl->>'local_date', '') <> t->>'local_date' or coalesce(pl->>'tier', '') <> t->>'tier' then return bnx.doc_reject(p_staging, 'TIER_MISMATCH'); end if;
  if outc = 'VERIFIED' then
    -- retention set on the object at creation must not be shorter than the tier's (1 h clock tolerance)
    begin
      if (pl->>'retain_until')::timestamptz < (t->>'retain_until')::timestamptz - interval '1 hour' then return bnx.doc_reject(p_staging, 'RETENTION_SHORT'); end if;
    exception when others then return bnx.doc_reject(p_staging, 'RETENTION');
    end;
    if coalesce(pl->>'destination', '') <> 'OFF_PROVIDER' then return bnx.doc_reject(p_staging, 'DESTINATION'); end if;
    if exists (select 1 from bnx.backup_run where local_date = (t->>'local_date')::date and outcome = 'VERIFIED') then
      perform bnx.notify('EXCEPTION', 'BACKUP_DUPLICATE_DATE:' || (t->>'local_date'), true, jsonb_build_object('kind', 'BACKUP_DUPLICATE_LOCAL_DATE', 'record_key', t->>'local_date'));
      return bnx.doc_reject(p_staging, 'DUPLICATE_LOCAL_DATE');
    end if;
    if bnx.backup_hex(pl->>'dump_sha256') is null or bnx.backup_hex(pl->>'plaintext_sha256') is null or bnx.backup_hex(pl->>'header_sha256') is null then
      return bnx.doc_reject(p_staging, 'DIGESTS'); end if;
    -- UA §9.3 step 7: pg_dump major >= server major; pg_restore of the same major as pg_dump
    if bnx.backup_major(pl#>>'{tools,pg_dump}') is null or bnx.backup_major(pl#>>'{tools,server}') is null
       or bnx.backup_major(pl#>>'{tools,pg_dump}') < bnx.backup_major(pl#>>'{tools,server}')
       or bnx.backup_major(pl#>>'{tools,pg_restore}') is distinct from bnx.backup_major(pl#>>'{tools,pg_dump}') then
      return bnx.doc_reject(p_staging, 'TOOL_MAJOR'); end if;
    -- K2 recipients: the Owner key and the drill key that were ACTIVE at the start, fingerprints equal to the registry
    -- (an archive without a drill recipient is refused: S4B-F24)
    if pl#>>'{recipients,owner_key_id}' is distinct from bnx.backup_key_active('OWNER', st)
       or pl#>>'{recipients,drill_key_id}' is distinct from bnx.backup_key_active('DRILL', st)
       or pl#>>'{recipients,owner_fingerprint_sha256}' is distinct from (select recipient_fingerprint from bnx.backup_key_registry where key_id = pl#>>'{recipients,owner_key_id}')
       or pl#>>'{recipients,drill_fingerprint_sha256}' is distinct from (select recipient_fingerprint from bnx.backup_key_registry where key_id = pl#>>'{recipients,drill_key_id}') then
      return bnx.doc_reject(p_staging, 'RECIPIENTS'); end if;
    -- step 8: re-downloaded, decrypted with the drill identity, pg_restore --list, hash compare
    if coalesce((pl#>>'{verify,redownload_sha256_equal}')::boolean, false) is not true or coalesce((pl#>>'{verify,pg_restore_list_ok}')::boolean, false) is not true
       or pl#>>'{verify,decrypted_with}' is distinct from pl#>>'{recipients,drill_key_id}' then
      return bnx.doc_reject(p_staging, 'NOT_VERIFIED'); end if;
    hf := pl->'header';
    if jsonb_typeof(hf) <> 'object' or hf->>'format' <> 'bnx-backup-header-facts/1' or jsonb_typeof(hf->'tables') <> 'object'
       or jsonb_typeof(hf->'migrations') <> 'array' or jsonb_typeof(hf->'audit_head') <> 'object' then
      return bnx.doc_reject(p_staging, 'HEADER'); end if;
    -- anchor (R-11): the live chain must hold the recorded head hash at the recorded seq
    aseq := (hf#>>'{audit_head,seq}')::bigint; ahash := hf#>>'{audit_head,hash}';
    if aseq = 0 then ac := 'EMPTY_CHAIN';
    else
      select hash into live from bnx_audit.audit_event where seq = aseq;
      ac := case when live is not null and encode(live, 'hex') = ahash then 'MATCH' else 'MISMATCH' end;
    end if;
    if ac = 'MISMATCH' then
      perform bnx.notify('EXCEPTION', 'AUDIT_ANCHOR_MISMATCH:' || (pl->>'run_id'), true, jsonb_build_object('kind', 'AUDIT_ANCHOR_MISMATCH', 'record_key', pl->>'run_id'));
    end if;
  else
    if coalesce(pl->>'failure_reason', '') = '' then return bnx.doc_reject(p_staging, 'FAILURE_REASON'); end if;
  end if;
  begin
    insert into bnx.backup_run(run_id, staging_id, started_at, ended_at, local_date, tier, retain_until, policy, destination, outcome, failure_reason,
      object_name, object_generation, dump_sha256, plaintext_sha256, header_file_sha256, compressed_bytes, wire_bytes, pg_dump_version,
      pg_restore_version, server_version, owner_key_id, drill_key_id, header_facts, header_facts_sha256, migrations_sha256, ledger_version,
      anchor_seq, anchor_hash, anchor_check)
    values ((pl->>'run_id')::uuid, p_staging, st, en, (t->>'local_date')::date, t->>'tier',
      greatest((t->>'retain_until')::timestamptz, coalesce((pl->>'retain_until')::timestamptz, (t->>'retain_until')::timestamptz)),
      pol->>'policy', 'OFF_PROVIDER', outc, case when outc = 'FAILED' then left(pl->>'failure_reason', 200) end,
      case when outc = 'VERIFIED' then bnx.backup_object_name(st, (pl->>'run_id')::uuid) end, pl#>>'{object,generation}', pl->>'dump_sha256',
      pl->>'plaintext_sha256', pl->>'header_sha256',
      (pl#>>'{sizes,compressed_kib}')::bigint * 1024, (pl#>>'{sizes,wire_kib}')::bigint * 1024, pl#>>'{tools,pg_dump}', pl#>>'{tools,pg_restore}',
      pl#>>'{tools,server}', pl#>>'{recipients,owner_key_id}', pl#>>'{recipients,drill_key_id}', hf, case when hf is not null then bnx.h(hf::text) end,
      case when hf is not null then bnx.h((hf->'migrations')::text) end, (hf->>'ledger_version')::bigint, aseq, ahash, ac);
  exception when check_violation or not_null_violation or foreign_key_violation or invalid_text_representation or numeric_value_out_of_range then
    return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  if outc = 'FAILED' then
    perform bnx.notify('EXCEPTION', 'BACKUP_FAILED:' || (t->>'local_date'), true, jsonb_build_object('kind', 'BACKUP_FAILED', 'record_key', t->>'local_date'));
  end if;
  -- a policy switch is an alert (AT-BKP-13); P-D is raised to the Owner
  if outc = 'VERIFIED' and (bnx.backup_policy()->>'policy') <> (pol->>'policy') then
    perform bnx.notify('EXCEPTION', 'BACKUP_POLICY:' || (bnx.backup_policy()->>'policy') || ':' || (t->>'local_date'), true,
      jsonb_build_object('kind', 'BACKUP_POLICY_CHANGED', 'record_key', bnx.backup_policy()->>'policy'));
  end if;
  if pl ? 'usage' then perform bnx.usage_insert(pl->'usage' || jsonb_build_object('job', 'BACKUP')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'run_id', pl->>'run_id', 'outcome', outc, 'tier', t->>'tier',
    'policy', pol->>'policy', 'anchor_check', ac));
end $$;

-- EVIDENCE_VERIFY result (Draft-04 §7 R8, AT-BKP-10): re-hash of evidence copies; reads evidence status through
-- bnx.evidence_status (9011R R-09); a mismatch is an Owner alert, never a silent state change
create function bnx.wrk_evidence_state(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; it jsonb; o bnx.evidence_object; res text; n int := 0; bad int := 0;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select p.*, l.job_kind into s from bnx_intake.staging_payload p join bnx.exec_lease l on l.lease_id = p.lease_id where p.id = p_staging for update of p;
  if not found or s.stg_kind <> 'backup_recorded' or s.job_kind <> 'EVIDENCE_VERIFY' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  if exists (select 1 from jsonb_object_keys(s.payload) k where k not in ('items','started_at','ended_at','usage'))
     or jsonb_typeof(s.payload->'items') <> 'array' or jsonb_array_length(s.payload->'items') = 0 or jsonb_array_length(s.payload->'items') > 500 then
    return bnx.doc_reject(p_staging, 'ITEMS'); end if;
  -- validate every item before writing any row (a rejected result leaves nothing behind)
  for it in select * from jsonb_array_elements(s.payload->'items') loop
    if jsonb_typeof(it) <> 'object' or exists (select 1 from jsonb_object_keys(it) k where k not in ('evidence_object_id','copy','observed_sha256'))
       or bnx.backup_hex(it->>'observed_sha256') is null or coalesce(it->>'copy', '') not in ('R2','DRIVE')
       or coalesce(it->>'evidence_object_id', '') !~ '^[0-9a-fA-F-]{36}$' then
      return bnx.doc_reject(p_staging, 'ITEM'); end if;
    if not exists (select 1 from bnx.evidence_object where id = (it->>'evidence_object_id')::uuid) then return bnx.doc_reject(p_staging, 'UNKNOWN_EVIDENCE'); end if;
  end loop;
  if (select count(*) from jsonb_array_elements(s.payload->'items') x) <>
     (select count(distinct (x->>'evidence_object_id', x->>'copy')) from jsonb_array_elements(s.payload->'items') x) then
    return bnx.doc_reject(p_staging, 'DUPLICATE_ITEM'); end if;
  for it in select * from jsonb_array_elements(s.payload->'items') loop
    select * into o from bnx.evidence_object where id = (it->>'evidence_object_id')::uuid;
    -- an object whose SHA-256 was never set by the executor has no reference to compare with (never reported as a mismatch)
    res := case when o.sha256 is null then 'NO_REFERENCE' when encode(o.sha256, 'hex') = it->>'observed_sha256' then 'MATCH' else 'MISMATCH' end;
    insert into bnx.evidence_verification(staging_id, evidence_object_id, copy, observed_sha256, result, evidence_status)
    values (p_staging, o.id, it->>'copy', it->>'observed_sha256', res, bnx.evidence_status(o.id));
    n := n + 1;
    if res = 'MISMATCH' then
      bad := bad + 1;
      perform bnx.notify('EXCEPTION', 'EVIDENCE_HASH_MISMATCH:' || o.id || ':' || (it->>'copy'), true,
        jsonb_build_object('kind', 'EVIDENCE_HASH_MISMATCH', 'record_key', o.id::text));
    end if;
  end loop;
  if s.payload ? 'usage' then perform bnx.usage_insert(s.payload->'usage' || jsonb_build_object('job', 'EVIDENCE_VERIFY')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'verified', n, 'mismatches', bad));
end $$;

-- RESTORE_DRILL result (UA §9.3 step 9; Backup §7-§8). The outcome is the database's: PASS only when the job reports PASS,
-- the restored header facts equal the backup's (bkp_header_compare = []), the decrypting key is a DRILL recipient of that run
-- that was not pruned (the drill identity never opens an Owner-only archive: AT-BKP-20), the cleanup was verified, and a
-- production or new-project target carries an unused, unexpired Owner authorization of that run (AT-BKP-15).
create function bnx.wrk_restore_drill_recorded(p_staging uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; pl jsonb; b bnx.backup_run; st timestamptz; en timestamptz; why text[] := '{}'; mm jsonb := '[]'; k bnx.backup_key_registry;
        ks text; kh text; auth bnx.restore_authorization; outc text; tgt text; knd text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging for update;
  if not found or s.stg_kind <> 'restore_drill_recorded' then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if s.state in ('PROMOTED','REJECTED') then return s.result; end if;
  pl := s.payload;
  if not bnx.backup_payload_ok(pl) then return bnx.doc_reject(p_staging, 'KEY_MATERIAL_REFUSED'); end if;
  if exists (select 1 from jsonb_object_keys(pl) jk where jk not in ('drill_id','backup_run_id','kind','target','decrypt_key_id','started_at',
       'ended_at','outcome','restored_header','cleanup_verified','tools','failure_reason','authorization_id','usage')) then
    return bnx.doc_reject(p_staging, 'UNKNOWN_FIELD'); end if;
  begin
    st := (pl->>'started_at')::timestamptz; en := (pl->>'ended_at')::timestamptz;
    select * into b from bnx.backup_run where run_id = (pl->>'backup_run_id')::uuid;
  exception when others then return bnx.doc_reject(p_staging, 'FIELDS');
  end;
  if b.run_id is null then return bnx.doc_reject(p_staging, 'UNKNOWN_BACKUP'); end if;
  if b.outcome <> 'VERIFIED' then return bnx.doc_reject(p_staging, 'BACKUP_NOT_VERIFIED'); end if;
  if st is null or en is null or en < st or coalesce(pl->>'drill_id', '') !~ '^[0-9a-f-]{36}$' then return bnx.doc_reject(p_staging, 'TIMES_OR_ID'); end if;
  knd := coalesce(pl->>'kind', 'DRILL'); tgt := coalesce(pl->>'target', 'ISOLATED_DRILL');
  if knd not in ('DRILL','RESTORE_SAME_IDENTITY','RESTORE_AS_NEW') or tgt not in ('ISOLATED_DRILL','NEW_PROJECT','PRODUCTION')
     or (knd = 'DRILL') <> (tgt = 'ISOLATED_DRILL') then return bnx.doc_reject(p_staging, 'KIND_TARGET'); end if;
  if coalesce(pl->>'outcome', '') not in ('PASS','FAIL') then return bnx.doc_reject(p_staging, 'OUTCOME'); end if;
  select * into k from bnx.backup_key_registry where key_id = pl->>'decrypt_key_id';
  if k.key_id is null then return bnx.doc_reject(p_staging, 'UNKNOWN_KEY'); end if;
  if pl->>'outcome' = 'FAIL' then why := why || coalesce(left(pl->>'failure_reason', 120), 'REPORTED_FAIL'); end if;
  -- key rules (S4B-F24; Backup §10.4)
  if knd = 'DRILL' and k.role <> 'DRILL' then why := why || 'DRILL_WITH_OWNER_KEY'::text; end if;
  if k.key_id is distinct from b.drill_key_id and k.key_id is distinct from b.owner_key_id then why := why || 'KEY_NOT_RECIPIENT'::text; end if;
  ks := bnx.backup_key_state(k.key_id, st);
  if ks = 'PRUNED' then why := why || 'KEY_PRUNED'::text; end if;
  select handling into kh from bnx.backup_key_event where key_id = k.key_id and event = 'COMPROMISED' and at <= st order by seq desc limit 1;
  if kh = 'OWNER_KEY_TEST_ONLY' and k.role = 'DRILL' then why := why || 'KEY_COMPROMISED_OWNER_TEST_ONLY'::text; end if;
  -- header facts of the restored database
  if jsonb_typeof(pl->'restored_header') <> 'object' then why := why || 'NO_RESTORED_HEADER'::text;
  else
    mm := bnx.bkp_header_compare(b.header_facts, pl->'restored_header');
    if mm <> '[]' then why := why || 'HEADER_FACTS_DIFFER'::text; end if;
  end if;
  if coalesce((pl->>'cleanup_verified')::boolean, false) is not true and knd = 'DRILL' then why := why || 'CLEANUP_NOT_VERIFIED'::text; end if;
  -- production / new project: Owner authorization (INV-45)
  if tgt <> 'ISOLATED_DRILL' then
    begin
      select * into auth from bnx.restore_authorization where id = (pl->>'authorization_id')::uuid;
    exception when others then auth := null;
    end;
    if auth.id is null or auth.backup_run_id <> b.run_id or auth.target <> tgt or auth.expires_at < st or auth.authorized_at > st
       or exists (select 1 from bnx.restore_drill d where d.authorization_id = auth.id) then
      perform bnx.notify('EXCEPTION', 'RESTORE_UNAUTHORIZED:' || p_staging, true, jsonb_build_object('kind', 'RESTORE_WITHOUT_AUTHORIZATION', 'record_key', b.run_id::text));
      return bnx.doc_reject(p_staging, 'RESTORE_NOT_AUTHORIZED');
    end if;
  end if;
  outc := case when cardinality(why) = 0 then 'PASS' else 'FAIL' end;
  begin
    insert into bnx.restore_drill(drill_id, staging_id, backup_run_id, kind, target, decrypt_key_id, started_at, ended_at, duration_seconds,
      reported_outcome, outcome, reasons, header_mismatches, cleanup_verified, pg_restore_version, server_version, authorization_id)
    values ((pl->>'drill_id')::uuid, p_staging, b.run_id, knd, tgt, k.key_id, st, en, extract(epoch from en - st), pl->>'outcome', outc,
      case when outc = 'FAIL' then why else '{}' end, case when outc = 'FAIL' then mm else '[]' end,
      coalesce((pl->>'cleanup_verified')::boolean, false), pl#>>'{tools,pg_restore}', pl#>>'{tools,server}', auth.id);
  exception when unique_violation then return bnx.doc_reject(p_staging, 'DUPLICATE_DRILL');
            when check_violation or not_null_violation or invalid_text_representation then return bnx.doc_reject(p_staging, 'VALIDATION_FAILED');
  end;
  if outc = 'FAIL' then
    perform bnx.notify('EXCEPTION', 'RESTORE_DRILL_FAILED:' || (pl->>'drill_id'), true, jsonb_build_object('kind', 'RESTORE_DRILL_FAILED', 'record_key', b.run_id::text));
  end if;
  if tgt <> 'ISOLATED_DRILL' and outc = 'PASS' then
    insert into bnx.release_install_event(release_version, kind, detail)
    values (coalesce(pl#>>'{tools,release}', 'unknown'), 'RESTORE', jsonb_build_object('drill_id', pl->>'drill_id', 'backup_run_id', b.run_id, 'restore_kind', knd, 'target', tgt));
  end if;
  if pl ? 'usage' then perform bnx.usage_insert(pl->'usage' || jsonb_build_object('job', 'RESTORE_DRILL')); end if;
  return bnx.doc_done(p_staging, jsonb_build_object('status', 'PROMOTED', 'drill_id', pl->>'drill_id', 'outcome', outc, 'reasons', to_jsonb(why),
    'restorable', bnx.backup_restorable(b.run_id)));
end $$;

-- ---------- MODIFY bnx.wrk_promote_staged (9011): backup and restore promoters (9016) ----------
create or replace function bnx.wrk_promote_staged(p_staging uuid) returns text
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare s record; r jsonb;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  select * into s from bnx_intake.staging_payload where id = p_staging;
  if not found then return 'not_found'; end if;
  if s.state in ('PROMOTED','REJECTED') then return lower(s.state); end if;
  if s.stg_kind = 'index_consumed' then r := bnx.wrk_consume_shared_index(p_staging);
  elsif s.stg_kind = 'mail_fetched' and s.payload->>'op' = 'move' then r := bnx.wrk_mail_move_result(p_staging);
  elsif s.stg_kind = 'mail_fetched' then r := bnx.wrk_mail_evidence_registered(p_staging);
  elsif s.stg_kind = 'doc_discovered' then r := bnx.wrk_doc_discovered(p_staging);       -- 9011b
  elsif s.stg_kind = 'doc_validated' then r := bnx.wrk_doc_validated(p_staging);         -- 9011b
  elsif s.stg_kind = 'doc_archived' then r := bnx.wrk_doc_archived(p_staging);           -- 9011b (admission gate)
  elsif s.stg_kind = 'backup_recorded' then r := bnx.wrk_backup_recorded(p_staging);     -- 9016 (BACKUP, EVIDENCE_VERIFY)
  elsif s.stg_kind = 'restore_drill_recorded' then r := bnx.wrk_restore_drill_recorded(p_staging);   -- 9016
  else
    update bnx_intake.staging_payload set state = 'AWAITING_PROMOTER' where id = p_staging;   -- 9011c / 9014 / CORE-8 promoters
    return 'awaiting_promoter';
  end if;
  return lower(coalesce(r->>'status', 'promoted'));
end $$;

-- =====================================================================================================================
-- Part 6. Worker functions: schedule, key pruning, audit verification, usage, capacity, admission (Cost §6-§7)
-- =====================================================================================================================
-- Is a backup due now (hourly C2)? One verified point per local date; Neon branch restore points (P-B...P-D daily tier) need the
-- Neon API key that is SECURITY_REVIEW_REQUIRED (Backup §5), so they are reported as a gap, not taken; the daily off-provider
-- dump stops when this month's Neon egress plus W would pass the backup egress budget (AT-NEON-03).
create function bnx.wrk_backup_due(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare at_ timestamptz; t jsonb; pol jsonb; dest text := 'OFF_PROVIDER'; why text; eg bigint; cp bnx.cost_policy; okey text; dkey text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  begin at_ := coalesce((p->>'now')::timestamptz, now()); exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'now'); end;
  t := bnx.backup_tier(at_); pol := bnx.backup_policy();
  select * into cp from bnx.cost_policy order by version desc limit 1;
  select egress into eg from bnx.usage_month(bnx.billing_month(at_)) where project = 'neon';
  okey := bnx.backup_key_active('OWNER', at_); dkey := bnx.backup_key_active('DRILL', at_);
  if exists (select 1 from bnx.backup_run where local_date = (t->>'local_date')::date and outcome = 'VERIFIED') then why := 'DONE_FOR_LOCAL_DATE';
  elsif okey is null or dkey is null then why := 'K2_RECIPIENTS_MISSING';
  elsif t->>'tier' = 'DAILY' and pol->>'policy' <> 'P-A' then why := 'DAILY_TIER_NEON_BRANCH_UNAVAILABLE';
  elsif t->>'tier' = 'WEEKLY' and pol->>'policy' = 'P-D' then why := 'WEEKLY_TIER_NOT_IN_POLICY';
  elsif t->>'tier' = 'WEEKLY' and pol->>'policy' = 'P-C' and (extract(week from (t->>'local_date')::date)::int % 2) = 1 then why := 'WEEKLY_TIER_ALTERNATE_SUNDAY';
  elsif t->>'tier' = 'DAILY' and coalesce(eg, 0) + coalesce((pol->>'wire_bytes')::bigint, 0) > cp.neon_egress_bytes * cp.neon_backup_egress_pct then
    why := 'NEON_EGRESS_BUDGET';
  end if;
  return jsonb_build_object('due', why is null, 'reason', why, 'local_date', t->>'local_date', 'tier', t->>'tier', 'retain_until', t->>'retain_until',
    'policy', pol->>'policy', 'destination', dest, 'neon_egress_bytes', coalesce(eg, 0),
    'recipients', jsonb_build_object('owner_key_id', okey, 'owner_fingerprint_sha256', (select recipient_fingerprint from bnx.backup_key_registry where key_id = okey),
                                     'drill_key_id', dkey, 'drill_fingerprint_sha256', (select recipient_fingerprint from bnx.backup_key_registry where key_id = dkey)),
    'pg_dump_args', bnx.restore_preamble()->'pg_dump_args',
    'result_contract', 'sizes in KiB (compressed_kib, wire_kib); object name = bnx-vault-backups/<UTC yyyy/mm>/<run_id>.age, derived, never sent');
end $$;

-- vault maintenance reports that a retired drill identity was removed from the keyring (AT-BKP-18): refused before
-- prune_after, while a retained run still lists the key, and for an ACTIVE key
create function bnx.wrk_backup_key_pruned(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare k text := p->>'key_id'; st text; pa timestamptz; at_ timestamptz;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  begin at_ := coalesce((p->>'now')::timestamptz, now()); exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'now'); end;
  perform pg_advisory_xact_lock(hashtext('bnx.backup_key'));
  st := bnx.backup_key_state(k);
  if st is null then perform bnx.fail('NOT_FOUND', 'P0404'); end if;
  if st not in ('RETIRED','COMPROMISED') then perform bnx.fail('PRUNE_REFUSED', 'P0409', 'key is ' || st); end if;
  pa := bnx.backup_key_prune_after(k);
  if pa is not null and pa > at_ then perform bnx.fail('PRUNE_PREMATURE', 'P0409', 'prune_after ' || pa); end if;
  insert into bnx.backup_key_event(key_id, seq, event, detail)
  values (k, (select max(seq) + 1 from bnx.backup_key_event where key_id = k), 'PRUNED', jsonb_build_object('prune_after', pa, 'reported_at', at_));
  return jsonb_build_object('key_id', k, 'state', 'PRUNED', 'prune_after', pa);
end $$;

-- AUDIT_CHAIN_VERIFY (UA §9.2 Worker tick) and the external verifier's report (tools/s4/audit_chain_verify.py --anchor):
-- the anchor is the (seq, head hash) recorded in the latest verified backup header (R-11, G0R F-06)
create function bnx.wrk_audit_verified(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare src text := coalesce(p->>'source', 'WORKER_TICK'); hd jsonb := bnx.audit_head(); bad bigint := 0; b bnx.backup_run;
        live bytea; ar text; res text; id bigint; aseq bigint; ahash text;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  if src not in ('WORKER_TICK','EXTERNAL_VERIFIER') or exists (select 1 from jsonb_object_keys(p) k where k not in ('source','result','anchor_seq','anchor_hash','tool_version')) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'audit verification report'); end if;
  if src = 'WORKER_TICK' then
    bad := bnx.audit_verify();
    select * into b from bnx.backup_run where outcome = 'VERIFIED' and anchor_check = 'MATCH' order by started_at desc limit 1;
    if b.run_id is null then ar := 'NO_ANCHOR';
    else
      select hash into live from bnx_audit.audit_event where seq = b.anchor_seq;
      ar := case when live is not null and encode(live, 'hex') = b.anchor_hash then 'MATCH' else 'MISMATCH' end;
      aseq := b.anchor_seq; ahash := b.anchor_hash;
    end if;
    res := case when bad = 0 and ar <> 'MISMATCH' then 'INTACT' else 'FAILED' end;
  else
    aseq := (p->>'anchor_seq')::bigint; ahash := p->>'anchor_hash';
    select * into b from bnx.backup_run where outcome = 'VERIFIED' and anchor_seq = aseq and anchor_hash = ahash order by started_at desc limit 1;
    ar := case when aseq is null then 'NO_ANCHOR' when b.run_id is null then 'UNKNOWN_ANCHOR'
               when p->>'result' = 'INTACT' then 'MATCH' else 'MISMATCH' end;
    res := case when p->>'result' = 'INTACT' and ar = 'MATCH' then 'INTACT' else 'FAILED' end;
  end if;
  insert into bnx.audit_verification(source, head_seq, head_hash, first_bad_seq, anchor_run_id, anchor_seq, anchor_hash, anchor_result, result, tool_version)
  values (src, (hd->>'seq')::bigint, hd->>'hash', bad, b.run_id, aseq, ahash, ar, res, p->>'tool_version') returning audit_verification.id into id;
  if res = 'FAILED' then
    perform bnx.notify('EXCEPTION', 'AUDIT_VERIFY_FAILED:' || id, true, jsonb_build_object('kind', 'AUDIT_VERIFY_FAILED', 'record_key', id::text));
  end if;
  return jsonb_build_object('verification_id', id, 'result', res, 'anchor_result', ar, 'first_bad_seq', bad, 'head_seq', hd->'seq');
end $$;

create function bnx.usage_insert(u jsonb) returns bigint
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare id bigint; st timestamptz;
begin
  if jsonb_typeof(u) <> 'object' or exists (select 1 from jsonb_object_keys(u) k where k not in ('execution_id','phase','provider','project','job','started_at','ended_at',
       'instance_seconds','vcpu','gib','gross_estimate','egress_bytes','cu_hours','storage_bytes','egress_kib','storage_kib')) then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'usage field'); end if;
  begin
    st := (u->>'started_at')::timestamptz;
    insert into bnx.cloud_usage(execution_id, phase, provider, project, job, started_at, ended_at, instance_seconds, vcpu, gib, gross_estimate,
      egress_bytes, cu_hours, storage_bytes, billing_month)
    values (u->>'execution_id', coalesce(u->>'phase', 'ACTUAL'), u->>'provider', u->>'project', u->>'job', st, (u->>'ended_at')::timestamptz,
      coalesce((u->>'instance_seconds')::numeric, 0), (u->>'vcpu')::numeric, (u->>'gib')::numeric, coalesce((u->>'gross_estimate')::numeric, 0),
      coalesce((u->>'egress_bytes')::bigint, (u->>'egress_kib')::bigint * 1024, 0), coalesce((u->>'cu_hours')::numeric, 0),
      coalesce((u->>'storage_bytes')::bigint, (u->>'storage_kib')::bigint * 1024), bnx.billing_month(st))
    returning cloud_usage.id into id;
  exception when check_violation or not_null_violation or invalid_text_representation or invalid_datetime_format or numeric_value_out_of_range then
              perform bnx.fail('VALIDATION_FAILED', 'P0422', 'usage');
            when unique_violation then perform bnx.fail('USAGE_DUPLICATE', 'P0409', u->>'execution_id' || '/' || coalesce(u->>'phase', 'ACTUAL'));
  end;
  return id;
end $$;

-- usage reported by the Worker (EXPECTED at launch; Neon meters) or reconciled from a billing export
create function bnx.wrk_cloud_usage_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare id bigint; cp bnx.cost_policy; g numeric;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  id := bnx.usage_insert(p);
  -- the usage ledger itself drives throttled_internal when the exec ceiling is passed (Cost §6.3 first row)
  select * into cp from bnx.cost_policy order by version desc limit 1;
  select gross into g from bnx.usage_month(bnx.billing_month((p->>'started_at')::timestamptz)) where project = 'bnx-exec';
  if p->>'project' = 'bnx-exec' and g > cp.exec_allocation * cp.internal_ceiling_pct
     and (bnx.capacity_state('bnx-exec', (p->>'started_at')::timestamptz)->>'state') = 'normal' then
    insert into bnx.capacity_event(scope, state, signal, billing_month, detail, at)
    values ('bnx-exec', 'throttled_internal', 'usage_ledger', bnx.billing_month((p->>'started_at')::timestamptz), jsonb_build_object('month_gross', g),
            (p->>'started_at')::timestamptz);
  end if;
  return jsonb_build_object('usage_id', id);
end $$;

-- capacity signals (Cost §6.3, §7): budget notifications 50/80/100 %, a refused launch or a task killed by the cap, the result
-- of the first execution after a period reset (success -> normal; failure -> back off), a provider error
create function bnx.wrk_capacity_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare sc text := p->>'scope'; sig text := p->>'signal'; th int; cur text; nst text; nxt timestamptz; cp bnx.cost_policy; at_ timestamptz;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  begin at_ := coalesce((p->>'now')::timestamptz, now()); th := (p->>'threshold_pct')::int;
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'capacity signal'); end;
  if sc not in ('bnx-exec','bnx-vault') or sig not in ('budget_notification','launch_refused','task_killed','probe_result','provider_error') then
    perform bnx.fail('VALIDATION_FAILED', 'P0422', 'capacity signal'); end if;
  select * into cp from bnx.cost_policy order by version desc limit 1;
  cur := bnx.capacity_state(sc, at_)->>'state';
  nst := case sig
    when 'budget_notification' then case th when 100 then 'provider_capped' when 80 then case when cur = 'provider_capped' then cur else 'throttled_internal' end
                                             else cur end
    when 'launch_refused' then 'provider_capped' when 'task_killed' then 'provider_capped' when 'provider_error' then 'provider_error'
    when 'probe_result' then case when coalesce((p->>'ok')::boolean, false) then 'normal' else 'provider_capped' end end;
  if nst = 'probe_pending' then nst := 'normal'; end if;   -- a 50 % notice in a fresh month logs, the probe rule still applies
  if sig = 'probe_result' and not coalesce((p->>'ok')::boolean, false) then nxt := at_ + make_interval(hours => cp.probe_backoff_hours); end if;
  if sig = 'budget_notification' and th = 50 and cur = 'probe_pending' then
    return jsonb_build_object('scope', sc, 'state', cur, 'logged', true);
  end if;
  insert into bnx.capacity_event(scope, state, signal, threshold_pct, next_probe_at, billing_month, detail, at)
  values (sc, nst, sig, th, nxt, bnx.billing_month(at_), coalesce(p->'detail', '{}'), at_);
  if nst in ('provider_capped','provider_error') and cur not in ('provider_capped','provider_error') then
    perform bnx.notify('EXCEPTION', 'CAPACITY:' || sc || ':' || nst || ':' || bnx.billing_month(at_), true,
      jsonb_build_object('kind', 'CAPACITY_' || upper(nst), 'record_key', sc));
  end if;
  return jsonb_build_object('scope', sc, 'state', nst, 'previous', cur, 'next_probe_at', nxt);
end $$;

-- Admission controller (Cost §6.2), called by the dispatcher before every executor launch. Classes and priorities:
-- backup (1) > drill (2) > maintenance (3, evidence verification) > interactive (4) > bulk onboarding (5).
create function bnx.wrk_admission_decide(p jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare cls text := p->>'admission_class'; job text := p->>'job'; items int; secs numeric; gib numeric; cp bnx.cost_policy; sc text;
        cap jsonb; m date; mg numeric; est numeric; ceil_ numeric; ok boolean; why text; prio int; nu record; at_ timestamptz;
begin
  if session_user <> 'bnx_worker' then perform bnx.fail('FORBIDDEN', 'P0403'); end if;
  begin
    items := coalesce((p->>'planned_items')::int, 1); secs := coalesce((p->>'estimated_instance_seconds')::numeric, 0);
    gib := coalesce((p->>'gib')::numeric, 2); at_ := coalesce((p->>'now')::timestamptz, now());
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'admission request'); end;
  if cls is null or cls not in ('backup','drill','maintenance','interactive','bulk') or coalesce(job, '') !~ '^[A-Z_]{2,40}$'
     or items < 1 or secs < 0 or gib not in (1, 2) then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'admission request'); end if;
  select * into cp from bnx.cost_policy order by version desc limit 1;
  sc := case when cls = 'drill' then 'bnx-vault' else 'bnx-exec' end;
  prio := case cls when 'backup' then 1 when 'drill' then 2 when 'maintenance' then 3 when 'interactive' then 4 else 5 end;
  m := bnx.billing_month(at_);
  select gross into mg from bnx.usage_month(m) where project = sc;
  est := (secs + cp.execution_overhead_seconds) * case when gib = 1 then cp.gross_rate_1gib else cp.gross_rate_2gib end;
  ceil_ := case when sc = 'bnx-vault' then cp.vault_allocation else cp.exec_allocation end * cp.internal_ceiling_pct;
  cap := bnx.capacity_state(sc, at_);
  if cap->>'state' in ('provider_capped','provider_error') and (cap->>'next_probe_at')::timestamptz > at_ then
    ok := false; why := 'PROBE_BACKOFF';
  elsif cap->>'state' = 'probe_pending' or (cap->>'state' in ('provider_capped','provider_error') and cap->>'next_probe_at' is not null) then
    ok := items = 1; why := case when items = 1 then 'PERIOD_RESET_PROBE' else 'PROBE_PENDING_ONE_ITEM_ONLY' end;   -- back-off over: probe again
  elsif cap->>'state' = 'provider_capped' and cap->>'signal' = 'budget_notification' and cls = 'backup' then
    -- AT-SPEND-03: at the 100 % notice backups are still tried within the reserve until the vendor refuses a launch
    ok := mg + est <= ceil_ + cp.backup_reserve; why := case when ok then 'ADMITTED_CAPPED_NOTICE_BACKUP_RESERVE' else 'BACKUP_RESERVE_EXHAUSTED' end;
  elsif cap->>'state' in ('provider_capped','provider_error') then
    ok := false; why := upper(cap->>'state');
  else
    select * into nu from bnx.usage_month(m) where project = 'neon';
    if cls = 'bulk' and nu.storage is not null and nu.storage >= cp.neon_storage_bytes * cp.neon_storage_pause_pct then
      ok := false; why := 'NEON_STORAGE';
    elsif cls = 'bulk' and nu.cu >= cp.neon_cu_hours * cp.neon_cu_pause_pct then ok := false; why := 'NEON_COMPUTE';
    elsif cls = 'backup' then
      ok := mg + est <= ceil_ + cp.backup_reserve; why := case when ok then 'ADMITTED' else 'BACKUP_RESERVE_EXHAUSTED' end;
    elsif cap->>'state' = 'throttled_internal' and cls in ('interactive','bulk') then ok := false; why := 'THROTTLED_INTERNAL';
    else
      ok := mg + est <= ceil_; why := case when ok then 'ADMITTED' when cls = 'drill' then 'VAULT_CEILING_NEXT_MONTH' else 'THROTTLED_INTERNAL' end;
      if not ok and cls in ('interactive','bulk','maintenance') and cap->>'state' = 'normal' then
        insert into bnx.capacity_event(scope, state, signal, billing_month, detail, at)
        values (sc, 'throttled_internal', 'usage_ledger', m, jsonb_build_object('month_gross', mg, 'estimate', est, 'ceiling', ceil_), at_);
      end if;
    end if;
  end if;
  insert into bnx.admission_decision(job, admission_class, scope, planned_items, estimate_gross, month_gross, ceiling, admitted, reason, priority,
    policy_version, billing_month, decided_at)
  values (job, cls, sc, items, est, mg, case when cls = 'backup' then ceil_ + cp.backup_reserve else ceil_ end, ok, why, prio, cp.version, m, at_);
  return jsonb_build_object('admitted', ok, 'reason', why, 'priority', prio, 'scope', sc, 'estimate_gross', est, 'month_gross', mg,
    'ceiling', case when cls = 'backup' then ceil_ + cp.backup_reserve else ceil_ end, 'capacity_state', cap->>'state', 'policy_version', cp.version);
end $$;

-- =====================================================================================================================
-- Part 7. Queries (Owner and admin; not in the MCP catalog: an AI connection gets SCOPE_NOT_CONSENTED)
-- =====================================================================================================================
create function bnx.backup_reader(a bnx.actor) returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
begin
  if bnx.require(a, 0) not in ('owner','admin') then perform bnx.fail('FORBIDDEN_ROLE', 'P0403'); end if;
end $$;

create function bnx.q_backup_status(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); lim int := least(greatest(coalesce((q->>'limit')::int, 25), 1), 200); last bnx.backup_run;
        ext bnx.audit_verification;
begin
  perform bnx.backup_reader(a);
  select * into last from bnx.backup_run where outcome = 'VERIFIED' order by started_at desc limit 1;
  select * into ext from bnx.audit_verification where source = 'EXTERNAL_VERIFIER' order by verified_at desc, id desc limit 1;
  return jsonb_build_object(
    'policy', bnx.backup_policy(),
    'retained_objects', (select count(*) from bnx.backup_run where outcome = 'VERIFIED' and retain_until > now()),
    'runs', coalesce((select jsonb_agg(x order by x->>'started_at' desc) from (
        select jsonb_build_object('run_id', r.run_id, 'local_date', r.local_date, 'tier', r.tier, 'retain_until', r.retain_until, 'policy', r.policy,
          'outcome', r.outcome, 'failure_reason', r.failure_reason, 'object_name', r.object_name, 'compressed_bytes', r.compressed_bytes,
          'wire_bytes', r.wire_bytes, 'ledger_version', r.ledger_version, 'anchor', jsonb_build_object('seq', r.anchor_seq, 'hash', r.anchor_hash, 'check', r.anchor_check),
          'owner_key_id', r.owner_key_id, 'drill_key_id', r.drill_key_id, 'pg_dump', r.pg_dump_version, 'server', r.server_version,
          'restorable', bnx.backup_restorable(r.run_id), 'started_at', r.started_at) x
          from bnx.backup_run r order by r.started_at desc limit lim) y), '[]'),
    'drills', coalesce((select jsonb_agg(jsonb_build_object('drill_id', d.drill_id, 'backup_run_id', d.backup_run_id, 'kind', d.kind, 'target', d.target,
          'outcome', d.outcome, 'reasons', to_jsonb(d.reasons), 'decrypt_key_id', d.decrypt_key_id, 'duration_seconds', d.duration_seconds,
          'at', d.recorded_at) order by d.recorded_at desc) from (select * from bnx.restore_drill order by recorded_at desc limit lim) d), '[]'),
    'keys', coalesce((select jsonb_agg(jsonb_build_object('key_id', k.key_id, 'role', k.role, 'recipient_fingerprint', k.recipient_fingerprint,
          'state', bnx.backup_key_state(k.key_id), 'prune_after', bnx.backup_key_prune_after(k.key_id),
          'retained_runs', (select count(*) from bnx.backup_run r where (r.drill_key_id = k.key_id or r.owner_key_id = k.key_id) and r.retain_until > now()))
          order by k.role, k.registered_at) from bnx.backup_key_registry k), '[]'),
    'evidence_verification', jsonb_build_object('checked', (select count(*) from bnx.evidence_verification),
          'mismatches', (select count(*) from bnx.evidence_verification where result = 'MISMATCH'),
          'last_at', (select max(verified_at) from bnx.evidence_verification)),
    'audit_verification', (select jsonb_build_object('source', v.source, 'result', v.result, 'anchor_result', v.anchor_result, 'head_seq', v.head_seq,
          'at', v.verified_at) from bnx.audit_verification v order by v.verified_at desc, v.id desc limit 1),
    -- 9011R R-11 precondition of gate O-8 (reported, never opened here): an anchor recorded outside the database (verified
    -- backup header with anchor MATCH) and the external verifier INTACT with that anchor
    'real_data_anchor_precondition', jsonb_build_object(
          'met', last.run_id is not null and last.anchor_check = 'MATCH' and ext.id is not null and ext.result = 'INTACT'
                 and ext.anchor_seq = last.anchor_seq and ext.anchor_hash = last.anchor_hash,
          'anchor', case when last.run_id is not null then jsonb_build_object('run_id', last.run_id, 'seq', last.anchor_seq, 'hash', last.anchor_hash, 'check', last.anchor_check) end,
          'external_verifier', case when ext.id is not null then jsonb_build_object('result', ext.result, 'anchor_seq', ext.anchor_seq, 'at', ext.verified_at) end,
          'gate', 'O-8 is opened by the Owner; this value is one of its preconditions'));
end $$;

create function bnx.q_cost_status(cred jsonb, q jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, pg_temp as $$
declare a bnx.actor := bnx.resolve_actor(cred); m date; cp bnx.cost_policy;
begin
  perform bnx.backup_reader(a);
  begin m := coalesce(date_trunc('month', (q->>'month')::date)::date, bnx.billing_month(now()));
  exception when others then perform bnx.fail('VALIDATION_FAILED', 'P0422', 'month'); end;
  select * into cp from bnx.cost_policy order by version desc limit 1;
  return jsonb_build_object('billing_month', m,
    'policy', to_jsonb(cp) - 'declared_by',
    'ceilings', jsonb_build_object('bnx-exec', cp.exec_allocation * cp.internal_ceiling_pct, 'bnx-exec_backup_reserve', cp.backup_reserve,
                                   'bnx-vault', cp.vault_allocation * cp.internal_ceiling_pct),
    'usage', coalesce((select jsonb_object_agg(u.project, jsonb_build_object('gross_estimate', u.gross::text, 'egress_bytes', u.egress, 'cu_hours', u.cu::text,
                                   'storage_bytes', u.storage)) from bnx.usage_month(m) u), '{}'),
    'capacity', jsonb_build_object('bnx-exec', bnx.capacity_state('bnx-exec'), 'bnx-vault', bnx.capacity_state('bnx-vault')),
    'admissions', jsonb_build_object('admitted', (select count(*) from bnx.admission_decision where billing_month = m and admitted),
                                     'refused', coalesce((select jsonb_object_agg(reason, n) from (select reason, count(*) n from bnx.admission_decision
                                                           where billing_month = m and not admitted group by reason) x), '{}')),
    'estimates_note', 'gross estimates from the usage ledger (Cost §1); billed charges come from the billing export (M0-F); no vendor-enforced maximum exists for the whole system (Cost §8.2)');
end $$;

-- =====================================================================================================================
-- Part 8. Privileges: bnx_backup may EXECUTE bkp_* functions that are SECURITY INVOKER and not VOLATILE (MODIFY 9002/9011)
-- =====================================================================================================================
create or replace function bnx.apply_grants() returns void
language plpgsql set search_path = pg_catalog, pg_temp as $$
declare f record;
begin
  for f in select p.oid::regprocedure sig, p.proname, p.prosecdef, p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('bnx','bnx_rpt','bnx_doc','bnx_intake','bnx_tax','bnx_fed') loop
    execute format('revoke all on function %s from public, bnx_app, bnx_worker, bnx_authn, bnx_auth, bnx_backup, bnx_stager, bnx_fed_reader',
                   f.sig);
    if f.proname like 'cmd\_%' or f.proname like 'q\_%' then execute format('grant execute on function %s to bnx_app', f.sig);
    elsif f.proname like 'wrk\_%' then execute format('grant execute on function %s to bnx_worker', f.sig);
    elsif f.proname like 'authn\_%' then execute format('grant execute on function %s to bnx_authn', f.sig);
    elsif f.proname like 'stg\_%' then execute format('grant execute on function %s to bnx_stager', f.sig);
    elsif f.proname like 'fed\_%' then execute format('grant execute on function %s to bnx_fed_reader', f.sig);
    elsif f.proname like 'bkp\_%' and not f.prosecdef and f.provolatile in ('s','i') then           -- 9016
      execute format('grant execute on function %s to bnx_backup', f.sig);
    end if;  -- pol_*, install_*, helpers, unsafe bkp_*: no runtime EXECUTE
  end loop;
end $$;

-- audit_privileges MODIFY (9011 body, which is the 9002 body changed where marked "9011 G0R"; changed here only where
-- marked "9016"): bnx_backup may EXECUTE exactly the bkp_* functions that are SECURITY INVOKER and not VOLATILE
create or replace function bnx.audit_privileges() returns jsonb
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare v jsonb := '[]'; m jsonb; r record; role_ text; p text; s record; installer text;
        nine text[] := array['bnx_definer','bnx_migrator','bnx_app','bnx_worker','bnx_authn','bnx_auth','bnx_backup',
                             'bnx_fed_reader','bnx_stager','balnexa_audit_owner'];   -- 9011 G0R: + audit owner (B003)
        runtime text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader'];
        nonowner text[] := array['bnx_app','bnx_worker','bnx_authn','bnx_backup','bnx_stager','bnx_fed_reader','bnx_migrator'];
        regs text[];
begin
  select array_agg(nspname order by nspname) into regs from bnx.schema_registry;
  select applied_by_session into installer from bnx.schema_bootstrap where version = 'B001';
  -- role inventory: exactly nine bnx_* roles (CROSS-01) plus balnexa_audit_owner (9011 G0R; outside the bnx_ prefix because
  -- roles are cluster-wide and the 9002..9010 audits of a second database in the same cluster count bnx_* roles)
  for r in select rolname from pg_roles where rolname like 'bnx\_%' and rolname <> all(nine) loop
    v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'extra', r.rolname); end loop;
  foreach role_ in array nine loop
    if not exists (select 1 from pg_roles where rolname = role_) then
      v := v || jsonb_build_object('rule', 'ROLE_INVENTORY', 'missing', role_); end if;
  end loop;
  -- role attributes
  for r in select rolname, rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolinherit, rolcanlogin
             from pg_roles where rolname like 'bnx\_%' or rolname = 'balnexa_audit_owner' loop   -- 9011 G0R
    if r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolreplication or r.rolbypassrls then
      v := v || jsonb_build_object('rule', 'ROLE_ATTRIBUTE', 'role', r.rolname); end if;
    if r.rolname = 'bnx_definer' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'DEFINER_LOGIN'); end if;  -- R1 rule; bnx_auth is LOGIN in B001
    if r.rolname = 'bnx_migrator' and r.rolinherit then v := v || jsonb_build_object('rule', 'MIGRATOR_INHERITS'); end if;
    if r.rolname = 'balnexa_audit_owner' and r.rolcanlogin then v := v || jsonb_build_object('rule', 'AUDIT_OWNER_LOGIN'); end if;  -- 9011 G0R
  end loop;
  -- memberships: the documented definer->migrator SET-only grant; and (S4B-F17) the installer's automatic ADMIN
  -- ADMIN-only membership (no INHERIT, no SET) in the roles it created when the installer is a non-superuser CREATEROLE
  -- role (Neon project owner); same rule as amended 0108. B002 removes the installer's own SET/INHERIT self-grants.
  for r in select g.rolname grp, u.rolname mem, am.inherit_option, am.set_option, am.admin_option
             from pg_auth_members am join pg_roles g on g.oid = am.roleid join pg_roles u on u.oid = am.member
            where g.rolname like 'bnx\_%' or u.rolname like 'bnx\_%' or 'balnexa_audit_owner' in (g.rolname, u.rolname) loop   -- 9011 G0R
    if r.grp = 'bnx_definer' and r.mem = 'bnx_migrator' and not r.inherit_option and r.set_option and not r.admin_option then
      null;
    elsif r.grp = any(nine) and r.mem = installer and r.mem not like 'bnx\_%' and r.admin_option and not r.inherit_option and not r.set_option then
      null;  -- INSTALLER_MEMBERSHIP accepted
    elsif r.grp = any(nine) and r.mem not like 'bnx\_%' then
      v := v || jsonb_build_object('rule', 'INSTALLER_MEMBERSHIP', 'group', r.grp, 'member', r.mem, 'inherit', r.inherit_option,
                                   'admin', r.admin_option);
    else
      v := v || jsonb_build_object('rule', 'UNEXPECTED_MEMBERSHIP', 'group', r.grp, 'member', r.mem);
    end if;
  end loop;
  -- schemas: registered ones only; owner as registered; nobody else may CREATE; USAGE exactly as registered
  -- an unregistered schema is a violation when a bnx_* role owns it or any object in it, or holds any privilege on it
  -- (foreign schemas of the installer, e.g. the Draft-02 conversion source d02 read by bnx_definer in 9001, are ignored)
  -- runtime roles: any USAGE/CREATE on an unregistered schema is a violation
  for r in select n.oid, n.nspname, pg_get_userbyid(n.nspowner) owner from pg_namespace n
            where n.nspname not like 'pg\_%' and n.nspname not in ('information_schema','public') loop
    select * into s from bnx.schema_registry where nspname = r.nspname;
    if not found then
      if r.owner like 'bnx\_%'
         or exists (select 1 from pg_class c where c.relnamespace = r.oid and pg_get_userbyid(c.relowner) like 'bnx\_%')
         or exists (select 1 from pg_proc p where p.pronamespace = r.oid and pg_get_userbyid(p.proowner) like 'bnx\_%')
         or exists (select 1 from unnest(runtime) x where has_schema_privilege(x, r.oid, 'USAGE') or has_schema_privilege(x, r.oid, 'CREATE')) then
        v := v || jsonb_build_object('rule', 'NEW_SCHEMA_UNREGISTERED', 'schema', r.nspname, 'owner', r.owner);
      end if;
      continue;
    end if;
    if r.owner <> s.owner then v := v || jsonb_build_object('rule', 'SCHEMA_OWNER', 'schema', r.nspname, 'owner', r.owner); end if;
    if not has_schema_privilege('bnx_backup', r.nspname, 'USAGE') then
      v := v || jsonb_build_object('rule', 'BACKUP_SCHEMA_USAGE', 'schema', r.nspname); end if;
    foreach role_ in array runtime loop
      if has_schema_privilege(role_, r.nspname, 'USAGE') <> (role_ = any(s.usage_roles)) then
        v := v || jsonb_build_object('rule', 'RUNTIME_SCHEMA_USAGE', 'schema', r.nspname, 'role', role_,
                                     'has_usage', has_schema_privilege(role_, r.nspname, 'USAGE')); end if;
    end loop;
  end loop;
  for r in select n.nspname from pg_namespace n where n.nspname = any(regs || array['public']) loop
    foreach role_ in array nonowner || (case when r.nspname = 'bnx_audit' then array['bnx_definer'] else array['balnexa_audit_owner'] end) loop   -- 9011 G0R
      if has_schema_privilege(role_, r.nspname, 'CREATE') then
        v := v || jsonb_build_object('rule', 'SCHEMA_CREATE', 'schema', r.nspname, 'role', role_); end if;
    end loop;
  end loop;
  -- relations
  for r in select n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner) owner, c.oid
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = any(regs) and c.relkind in ('r','p','S','v','m') loop
    -- 9011 G0R: the owner expected for every relation is the registered owner of its schema (bnx_auth for auth,
    -- balnexa_audit_owner for bnx_audit, bnx_definer for the others; identical to the 9002 rule for the 9002 schemas)
    if r.owner <> (select g.owner from bnx.schema_registry g where g.nspname = r.nspname) then
      v := v || jsonb_build_object('rule', 'OWNER', 'object', r.nspname || '.' || r.relname, 'owner', r.owner); end if;
    if r.relkind in ('r','p','S') and not has_table_privilege('bnx_backup', r.oid, 'SELECT') then
      v := v || jsonb_build_object('rule', 'BACKUP_CANNOT_READ', 'object', r.nspname || '.' || r.relname); end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if r.relkind <> 'S' and has_table_privilege('bnx_backup', r.oid, p) then
        v := v || jsonb_build_object('rule', 'BACKUP_WRITE', 'object', r.relname, 'priv', p); end if;
    end loop;
    if r.relkind = 'S' and has_sequence_privilege('bnx_backup', r.oid, 'USAGE,UPDATE') then
      v := v || jsonb_build_object('rule', 'BACKUP_SEQUENCE_WRITE', 'object', r.relname); end if;
    foreach role_ in array array['bnx_app','bnx_worker','bnx_authn','bnx_migrator','bnx_stager','bnx_fed_reader'] loop
      if r.relkind <> 'S' and (has_table_privilege(role_, r.oid, 'SELECT') or has_table_privilege(role_, r.oid, 'INSERT')
          or has_table_privilege(role_, r.oid, 'UPDATE') or has_table_privilege(role_, r.oid, 'DELETE')
          or has_table_privilege(role_, r.oid, 'TRUNCATE')) then
        v := v || jsonb_build_object('rule', 'RUNTIME_TABLE_PRIVILEGE', 'object', r.nspname || '.' || r.relname, 'role', role_); end if;
      if r.relkind = 'S' and has_sequence_privilege(role_, r.oid, 'USAGE,SELECT,UPDATE') then
        v := v || jsonb_build_object('rule', 'RUNTIME_SEQUENCE_PRIVILEGE', 'object', r.relname, 'role', role_); end if;
      -- column-level grants are invisible to has_table_privilege (same-family review finding 7)
      if r.relkind <> 'S' and has_any_column_privilege(role_, r.oid, 'SELECT,INSERT,UPDATE,REFERENCES') then
        v := v || jsonb_build_object('rule', 'RUNTIME_COLUMN_PRIVILEGE', 'object', r.nspname || '.' || r.relname, 'role', role_); end if;
    end loop;
    if r.relkind <> 'S' and has_any_column_privilege('bnx_backup', r.oid, 'INSERT,UPDATE,REFERENCES') then
      v := v || jsonb_build_object('rule', 'BACKUP_WRITE', 'object', r.relname, 'priv', 'COLUMN'); end if;
  end loop;
  -- 9011 G0R (G0 finding F-01): the audit chain is a table in bnx_audit; bnx_definer, which bnx_migrator can SET ROLE to,
  -- may only read and append it; both append-only triggers are present and enabled; bnx.audit_event is only a view
  if to_regclass('bnx_audit.audit_event') is null or (select relkind from pg_class where oid = to_regclass('bnx_audit.audit_event')) <> 'r' then
    v := v || jsonb_build_object('rule', 'AUDIT_TABLE_OWNER', 'object', 'bnx_audit.audit_event', 'missing', true);
  else
    if not has_table_privilege('bnx_definer', 'bnx_audit.audit_event', 'SELECT') or not has_table_privilege('bnx_definer', 'bnx_audit.audit_event', 'INSERT') then
      v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'missing', 'SELECT,INSERT'); end if;
    foreach p in array array['UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('bnx_definer', 'bnx_audit.audit_event', p) then
        v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'priv', p); end if;
    end loop;
    if has_any_column_privilege('bnx_definer', 'bnx_audit.audit_event', 'UPDATE,REFERENCES') then
      v := v || jsonb_build_object('rule', 'AUDIT_TABLE_PRIVILEGE', 'role', 'bnx_definer', 'priv', 'COLUMN'); end if;
    for r in select t.tgname from (values ('t_append_only'), ('t_chain_version'), ('t_chain_append')) t(tgname)
              where not exists (select 1 from pg_trigger g where g.tgrelid = 'bnx_audit.audit_event'::regclass and g.tgname = t.tgname
                                  and g.tgenabled = 'O') loop
      v := v || jsonb_build_object('rule', 'AUDIT_TRIGGER', 'trigger', r.tgname); end loop;
    -- 9011 review R-10/R-12: the chain-append check belongs to the audit owner; no row security, rules or inheritance children
    if coalesce((select pg_get_userbyid(f.proowner) from pg_trigger g join pg_proc f on f.oid = g.tgfoid
                  where g.tgrelid = 'bnx_audit.audit_event'::regclass and g.tgname = 't_chain_append'), '') <> 'balnexa_audit_owner' then
      v := v || jsonb_build_object('rule', 'AUDIT_TRIGGER', 'trigger', 't_chain_append', 'owner', 'not balnexa_audit_owner'); end if;
    if exists (select 1 from pg_class c where c.oid = 'bnx_audit.audit_event'::regclass
                and (c.relrowsecurity or c.relhasrules or c.relhassubclass))
       or exists (select 1 from pg_inherits i where i.inhparent = 'bnx_audit.audit_event'::regclass)
       or exists (select 1 from pg_publication_rel pr where pr.prrelid = 'bnx_audit.audit_event'::regclass) then
      v := v || jsonb_build_object('rule', 'AUDIT_TABLE_SHAPE', 'object', 'bnx_audit.audit_event'); end if;
  end if;
  if coalesce((select relkind from pg_class where oid = to_regclass('bnx.audit_event')), 'v') <> 'v' then
    v := v || jsonb_build_object('rule', 'AUDIT_TABLE_OWNER', 'object', 'bnx.audit_event', 'kind', 'not a view'); end if;
  -- nothing owned by a bnx_* role may live in schema public (excluded from the schema loop because extensions live there):
  -- a SECURITY DEFINER function there would run with bnx privileges outside every rule above
  for r in select 'function' k, p.proname nm, pg_get_userbyid(p.proowner) owner from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and pg_get_userbyid(p.proowner) like 'bnx\_%'
           union all
           select 'relation', c.relname, pg_get_userbyid(c.relowner) from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and pg_get_userbyid(c.relowner) like 'bnx\_%' loop
    v := v || jsonb_build_object('rule', 'PUBLIC_SCHEMA_OBJECT', 'kind', r.k, 'object', 'public.' || r.nm, 'owner', r.owner);
  end loop;
  -- functions in every registered schema except auth (auth functions are owned by bnx_auth and never granted)
  for r in select n.nspname, p.oid, p.proname, p.prosecdef, p.provolatile, p.proconfig, pg_get_userbyid(p.proowner) owner,   -- 9016: provolatile
                  has_function_privilege('public', p.oid, 'EXECUTE') pub,
                  has_function_privilege('bnx_app', p.oid, 'EXECUTE') app,
                  has_function_privilege('bnx_worker', p.oid, 'EXECUTE') wrk,
                  has_function_privilege('bnx_authn', p.oid, 'EXECUTE') authn,
                  has_function_privilege('bnx_backup', p.oid, 'EXECUTE') bak,
                  has_function_privilege('bnx_stager', p.oid, 'EXECUTE') stg,
                  has_function_privilege('bnx_fed_reader', p.oid, 'EXECUTE') fed
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = any(regs) and n.nspname <> 'auth' loop
    if r.pub then v := v || jsonb_build_object('rule', 'PUBLIC_EXECUTE', 'function', r.proname); end if;
    if r.prosecdef and not coalesce('search_path=pg_catalog, pg_temp' = any(r.proconfig), false) then
      v := v || jsonb_build_object('rule', 'DEFINER_SEARCH_PATH', 'function', r.proname); end if;
    -- functions in bnx_audit belong to the audit owner (9011 review R-10: the chain-append check); everything else to the definer
    if r.owner <> (case when r.nspname = 'bnx_audit' then 'balnexa_audit_owner' else 'bnx_definer' end) then
      v := v || jsonb_build_object('rule', 'FUNCTION_OWNER', 'function', r.proname); end if;
    if r.app <> (r.proname like 'cmd\_%' or r.proname like 'q\_%') or r.wrk <> (r.proname like 'wrk\_%')
       or r.authn <> (r.proname like 'authn\_%') or r.fed <> (r.proname like 'fed\_%')
       or r.bak <> (r.proname like 'bkp\_%' and not r.prosecdef and r.provolatile in ('s','i')) then   -- 9016: bkp_* invoker, not volatile
      v := v || jsonb_build_object('rule', 'EXECUTE_GRANT', 'function', r.nspname || '.' || r.proname, 'app', r.app,
                                   'worker', r.wrk, 'authn', r.authn, 'backup', r.bak, 'fed_reader', r.fed); end if;
    -- 9016: a bkp_* function must be SECURITY INVOKER and not VOLATILE (bnx_backup runs it with its own read-only rights)
    if r.proname like 'bkp\_%' and (r.prosecdef or r.provolatile = 'v') then
      v := v || jsonb_build_object('rule', 'BACKUP_FUNCTION_UNSAFE', 'function', r.nspname || '.' || r.proname,
                                   'security_definer', r.prosecdef, 'volatile', r.provolatile = 'v'); end if;
    if r.stg <> (r.proname like 'stg\_%') then
      v := v || jsonb_build_object('rule', 'STAGER_NO_POSTING', 'function', r.nspname || '.' || r.proname, 'stager', r.stg); end if;
  end loop;
  -- default privileges must cover future tables and sequences of both creators in every registered schema
  for r in select g.nspname, g.owner, k.kind from bnx.schema_registry g cross join (values ('r'), ('S')) k(kind) loop
    if not exists (select 1 from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace
                    where pg_get_userbyid(d.defaclrole) = r.owner and n.nspname = r.nspname and d.defaclobjtype = r.kind::"char"
                      and exists (select 1 from aclexplode(d.defaclacl) x where x.grantee = 'bnx_backup'::regrole and x.privilege_type = 'SELECT')) then
      v := v || jsonb_build_object('rule', 'DEFAULT_PRIVILEGE_MISSING', 'entry', r.owner || ':' || r.nspname || ':' || r.kind); end if;
  end loop;
  select jsonb_agg(jsonb_build_object('object', n.nspname || '.' || c.relname, 'kind', c.relkind, 'owner', pg_get_userbyid(c.relowner),
           'backup_select', has_table_privilege('bnx_backup', c.oid, 'SELECT'),
           'app_any', has_table_privilege('bnx_app', c.oid, 'SELECT,INSERT,UPDATE,DELETE'),
           'worker_any', has_table_privilege('bnx_worker', c.oid, 'SELECT,INSERT,UPDATE,DELETE'))
           order by n.nspname, c.relname) into m
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = any(regs) and c.relkind in ('r','p','S','v');
  return jsonb_build_object('violations', v, 'matrix', coalesce(m, '[]'));
end $$;

select bnx.apply_grants();
