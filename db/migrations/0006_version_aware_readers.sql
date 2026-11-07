-- 0006 Version-aware readers (§B2a.3), ownership at (date, version) (AUD-039), live authorization (AUD-041),
-- snapshot replay access (AUD-040). All SECURITY DEFINER, search_path pg_catalog,pg_temp, schema-qualified (rule D1/D2).
set role bnx_definer;

create function bnx.visible_at(p_v bigint)
returns table(journal_id uuid, visible_version bigint)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select je.id, je.ledger_version
    from bnx.journal_entry je
   where je.ledger_version is not null and je.ledger_version <= p_v
  union all
  select je.id, ev.recorded_version
    from bnx.journal_entry je
    join bnx.posting_batch_event ev
      on ev.batch_id = je.posting_batch_id and ev.event = 'activated' and ev.recorded_version <= p_v
$$;

create function bnx.effective_posting_date(p_journal uuid, p_v bigint)
returns date language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce(
    (select c.confirmed_posting_date from bnx.posting_date_confirmation c
      where c.journal_id = p_journal and c.recorded_version <= p_v
      order by c.recorded_version desc, c.seq desc limit 1),
    (select je.posting_date from bnx.journal_entry je where je.id = p_journal))
$$;

create function bnx.anchor_at(p_ac uuid, p_v bigint)
returns bnx.opening_anchor_version language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select a.* from bnx.opening_anchor_version a
   where a.account_currency_id = p_ac and a.valid_from_version <= p_v
   order by a.valid_from_version desc limit 1
$$;

create function bnx.balance_at(p_ac uuid, p_date date, p_v bigint)
returns bnx.balance_result language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
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
    join bnx.account_currency ac on ac.id = p_ac and jl.ledger_account_id = ac.ledger_account_id
   where bnx.effective_posting_date(v.journal_id, p_v) <= p_date;
  r.status := 'ok';
  return r;
end $$;

-- AUD-039: ownership in force on business date D as recorded at version V.
-- Per (party, kind): the event with the latest effective_from <= D; ties broken by the later recorded_version
-- (a later correction of the same effective date wins). 'ended' removes the holding.
create function bnx.ownership_at(p_account uuid, p_date date, p_v bigint)
returns table(party_id uuid, kind text, share numeric) language sql stable security definer
set search_path = pg_catalog, pg_temp as $$
  select x.party_id, x.kind, x.share from (
    select distinct on (e.party_id, e.kind) e.party_id, e.kind, e.event, e.share
      from bnx.account_ownership_event e
     where e.account_id = p_account and e.recorded_version <= p_v and e.effective_from <= p_date
     order by e.party_id, e.kind, e.effective_from desc, e.recorded_version desc) x
  where x.event = 'set'
$$;

create function bnx.account_scope_at(p_account uuid, p_date date, p_v bigint)
returns text language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select coalesce((select s.ownership_scope from bnx.account_scope_event s
     where s.account_id = p_account and s.recorded_version <= p_v and s.effective_from <= p_date
     order by s.effective_from desc, s.recorded_version desc limit 1), 'individual')
$$;

-- Live authorization (never historical; AUD-040/041)
create function bnx.visible_account_currency_ids(p_member uuid)
returns setof uuid language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select ac.id from bnx.account_currency ac
    join bnx.account_grant g on g.account_id = ac.account_id and g.member_id = p_member and g.can_view
    join bnx.member m on m.id = p_member and m.state = 'active'
$$;

-- AUD-041: evidence read decision, evaluated live at every URL issuance or stream request
create function bnx.can_read_evidence(p_member uuid, p_file uuid)
returns text language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case
    when not exists (select 1 from bnx.member m where m.id = p_member and m.state = 'active') then 'denied'
    when exists (select 1 from bnx.evidence_file f where f.id = p_file and f.acquired_by = p_member) then 'acquirer'
    when exists (select 1 from bnx.evidence_file f where f.id = p_file
                  and f.assigned_account_currency_id in (select bnx.visible_account_currency_ids(p_member))) then 'account_grant'
    when exists (select 1 from bnx.evidence_access_grant g where g.evidence_file_id = p_file and g.member_id = p_member
                  and g.revoked_at is null and g.expires_at > now()) then 'owner_t3'
    else 'denied' end
$$;

-- AUD-040: an actor may replay a snapshot's projection only if every account-currency in it is still visible.
create function bnx.snapshot_replay_access(p_member uuid, p_snapshot uuid)
returns text language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select case
    when s.id is null then 'NOT_FOUND'
    when not (s.projection_account_currency_ids <@ array(select bnx.visible_account_currency_ids(p_member)))
      then 'ACCESS_REVOKED'
    else 'ok' end
  from (select 1) d left join bnx.report_snapshot s on s.id = p_snapshot
$$;
