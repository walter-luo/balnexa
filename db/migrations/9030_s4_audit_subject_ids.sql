-- 9030_s4_audit_subject_ids.sql -- S4 finding F-AUD-01 (CI flake of AT-F7-P0 on #28, 2026-11-12). Expand-only.
-- Not in the V1.2 register (D-AUD-1).
-- The audit subject of correct_transaction named three journal UUIDs 'original', 'reversal' and 'replacement'. Those keys are
-- not identifier keys for the 9011 guard C2 (the UUID/hex exemption needs a key ending in id/uuid/...), so a UUID whose
-- 12-character group held a Luhn-valid 9-digit run refused the correction with SIN_CANDIDATE: about 0.1% per UUID, three per
-- correction. Every other bnx.audit subject was checked: its UUID values sit under *_id keys.
--   MODIFY: bnx.cmd_correct_transaction (0106 body; only the audit subject keys changed, marked "9030"): original_journal_id,
--           reversal_journal_id, replacement_journal_id. The command's result is unchanged. Earlier audit events keep their keys
--           (the chain is append-only); readers of the subject accept both spellings.
set role bnx_definer;

create or replace function bnx.cmd_correct_transaction(cred jsonb, cmd jsonb) returns jsonb
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
  perform bnx.audit(a, 'correct_transaction', jsonb_build_object('original_journal_id', o.id, 'reversal_journal_id', rj, 'replacement_journal_id', nj), cmd, v);   -- 9030
  return bnx.idem_end(a, 'correct_transaction', cmd, jsonb_build_object('reversal_journal_id', rj, 'replacement_journal_id', nj, 'ledger_version', v));
end $$;

select bnx.apply_grants();
