-- 0004 Evidence objects, acquisitions, explicit access, archive protection (AUD-030, AUD-041, AUD-042).
set role bnx_definer;

create table bnx.evidence_object(
  id uuid primary key, r2_key text not null unique,
  size_bytes bigint not null, md5_etag text,
  sha256 bytea,                                              -- write-once, set only by the cloud executor
  integrity_state text not null check (integrity_state in ('unverified','verified','failed')),
  verified_by_execution text, verified_at timestamptz,
  dedup_into uuid references bnx.evidence_object,            -- write-once
  -- AUD-042 archive protection (class M state; history in evidence_archive_event)
  archive_state text not null default 'single_copy'
    check (archive_state in ('single_copy','archive_pending','dual_verified','archive_failed')),
  single_copy_since timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check (integrity_state <> 'verified' or sha256 is not null));
create unique index evidence_object_sha_uq on bnx.evidence_object(sha256)
  where integrity_state = 'verified' and dedup_into is null;

-- Write-once enforcement for identity and integrity columns (§B2a.2)
create function bnx.trg_evidence_object_write_once() returns trigger
language plpgsql set search_path = pg_catalog, pg_temp as $$
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
create trigger t_write_once before update or delete on bnx.evidence_object
  for each row execute function bnx.trg_evidence_object_write_once();

create table bnx.evidence_archive_event(evidence_object_id uuid not null references bnx.evidence_object, seq int not null,
  event text not null check (event in ('queued','copied','verified','failed','retry_scheduled','primary_missing')),
  drive_file_id text, sha256_observed bytea, detail jsonb, at timestamptz not null default now(),
  primary key (evidence_object_id, seq));

create table bnx.evidence_file(
  id uuid primary key, evidence_object_id uuid not null references bnx.evidence_object,
  sha256_declared bytea, size_declared bigint not null, mime text not null, original_name text,
  acquired_via text not null check (acquired_via in ('pwa_upload','drive_selection','chat_file')),
  acquired_by uuid not null references bnx.member,           -- uploaded-by only; never holder evidence (INV-33)
  storage_state text not null check (storage_state in ('upload_pending','stored','archived','upload_failed',
                                                       'expired','archive_failed')),           -- class M
  assigned_account_currency_id uuid references bnx.account_currency,                          -- class M, set on assignment
  superseded_by uuid references bnx.evidence_file,
  created_at timestamptz not null default now());

-- AUD-041: only explicit, non-derived grants are persisted. Grant-derived access is evaluated live.
create table bnx.evidence_access_grant(evidence_file_id uuid not null references bnx.evidence_file,
  member_id uuid not null references bnx.member, basis text not null check (basis in ('owner_t3')),
  reason text not null, granted_by uuid not null, granted_at timestamptz not null default now(),
  expires_at timestamptz not null, revoked_at timestamptz,
  primary key (evidence_file_id, member_id, granted_at),
  check (expires_at <= granted_at + interval '7 days'));
create table bnx.evidence_access_log(id bigserial primary key, evidence_file_id uuid not null, member_id uuid,
  purpose text not null, decision text not null check (decision in ('granted','denied')), url_expires_at timestamptz,
  at timestamptz not null default now());

create table bnx.document(id uuid primary key, evidence_object_id uuid not null references bnx.evidence_object,
  seq int not null, page_from int, page_to int,
  doc_type text not null check (doc_type in ('bank_statement','card_statement','investment_statement','not_statement','unknown')),
  issue_date date, unique (evidence_object_id, seq));
create table bnx.statement(id uuid primary key, document_id uuid not null references bnx.document,
  account_currency_id uuid references bnx.account_currency, currency char(3) not null references bnx.currency,
  period_start date, period_end date, opening_balance numeric(20,4), closing_balance numeric(20,4),
  sign_convention text not null check (sign_convention in ('asset_positive','owed_positive')),
  version_group uuid);                                        -- printed values only (class E); state lives in statement_event
create table bnx.statement_event(statement_id uuid not null references bnx.statement, seq int not null,
  event text not null check (event in ('assigned','confirmed','version_role_set','withdrawn')), payload jsonb not null,
  recorded_version bigint not null, actor uuid not null, primary key (statement_id, seq));

create trigger t_append_only before update or delete on bnx.evidence_archive_event for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.document for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.statement for each row execute function bnx.trg_append_only();
create trigger t_append_only before update or delete on bnx.statement_event for each row execute function bnx.trg_append_only();

insert into bnx.table_class values
 ('evidence_object','E'),('evidence_archive_event','E'),('evidence_file','M'),('evidence_access_grant','M'),
 ('evidence_access_log','M'),('document','E'),('statement','E'),('statement_event','F');
