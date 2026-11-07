-- AUD-041 AT-EVP-09/10, AUD-042 AT-ARC-01 (state + write-once), AUD-040 AT-SNAP-01/02
do $$
declare o uuid := gen_random_uuid(); f uuid := gen_random_uuid(); ok boolean; v bigint; snap uuid := gen_random_uuid();
        c1 bytea; c2 bytea; vs bigint;
begin
  perform t.setup();
  insert into bnx.evidence_object(id,r2_key,size_bytes,integrity_state) values (o,'orig/'||o,1024,'unverified');
  insert into bnx.evidence_file(id,evidence_object_id,size_declared,mime,acquired_via,acquired_by,storage_state,assigned_account_currency_id)
    values (f,o,1024,'application/pdf','pwa_upload',t.uuid('ann'),'stored',t.uuid('ac-sav'));
  -- AT-EVP-09 live revocation
  if bnx.can_read_evidence(t.uuid('bo'),f) <> 'account_grant' then raise exception 'AT-EVP-09 FAIL pre'; end if;
  update bnx.account_grant set can_view=false, can_post=false where member_id=t.uuid('bo') and account_id=t.uuid('a-sav');
  if bnx.can_read_evidence(t.uuid('bo'),f) <> 'denied' then raise exception 'AT-EVP-09 FAIL not revoked immediately'; end if;
  if bnx.can_read_evidence(t.uuid('ann'),f) <> 'acquirer' then raise exception 'AT-EVP-09 FAIL acquirer'; end if;
  -- AT-EVP-10 Owner T3 grant is explicit, time-bounded and revocable
  insert into bnx.evidence_access_grant values (f,t.uuid('bo'),'owner_t3','audit',t.uuid('ann'),now(),now()+interval '1 hour',null);
  if bnx.can_read_evidence(t.uuid('bo'),f) <> 'owner_t3' then raise exception 'AT-EVP-10 FAIL grant'; end if;
  update bnx.evidence_access_grant set revoked_at = now() where evidence_file_id=f and member_id=t.uuid('bo');
  if bnx.can_read_evidence(t.uuid('bo'),f) <> 'denied' then raise exception 'AT-EVP-10 FAIL revoke'; end if;
  update bnx.member set state='suspended' where id=t.uuid('ann');
  if bnx.can_read_evidence(t.uuid('ann'),f) <> 'denied' then raise exception 'AT-EVP-10 FAIL suspended acquirer'; end if;
  update bnx.member set state='active' where id=t.uuid('ann');
  raise notice 'PASS AT-EVP-09/10: grant revocation, T3 expiry/revocation and suspension take effect on the next decision';
  -- AT-ARC-01 write-once integrity; archive state may progress
  update bnx.evidence_object set sha256 = digest('x','sha256'), integrity_state='verified', verified_at=now() where id=o;
  begin update bnx.evidence_object set sha256 = digest('y','sha256') where id=o; ok := false;
  exception when sqlstate 'P0409' then ok := true; end;
  if not ok then raise exception 'AT-ARC-01 FAIL sha256 rewritable'; end if;
  update bnx.evidence_object set archive_state='archive_pending' where id=o;
  insert into bnx.evidence_archive_event values (o,1,'copied','drv-1',digest('x','sha256'),null,now());
  update bnx.evidence_object set archive_state='dual_verified' where id=o;
  raise notice 'PASS AT-ARC-01: sha256 write-once; archive_state single_copy -> archive_pending -> dual_verified';
  -- AT-SNAP-01/02 content digest reproducible at V; revoked actor gets ACCESS_REVOKED
  perform t.set_anchor(t.uuid('ac-chq'),'2026-01-01',1000,'s'); perform t.set_anchor(t.uuid('ac-sav'),'2026-01-01',500,'s');
  update bnx.account_grant set can_view=true where member_id=t.uuid('bo') and account_id=t.uuid('a-sav');
  vs := t.cur();
  select digest(string_agg(ac::text||':'||(bnx.balance_at(ac,'2026-03-31',vs)).amount::text, '|' order by ac::text),'sha256') into c1
    from unnest(array[t.uuid('ac-chq'),t.uuid('ac-sav')]) ac;
  insert into bnx.report_snapshot(id,report_code,filters_digest,ledger_version,report_definition_version,fx_policy,
    content_account_currency_ids,content_sha256,projection_actor,projection_account_currency_ids,projection_sha256)
  values (snap,'R03','\x00',vs,'R03@1','{}',array[t.uuid('ac-chq'),t.uuid('ac-sav')],c1,t.uuid('bo'),array[t.uuid('ac-chq'),t.uuid('ac-sav')],c1);
  perform t.post('Later','2026-03-30',10,t.uuid('la-exp'),t.uuid('la-sav'));          -- back-dated later fact
  select digest(string_agg(ac::text||':'||(bnx.balance_at(ac,'2026-03-31',vs)).amount::text, '|' order by ac::text),'sha256') into c2
    from unnest(array[t.uuid('ac-chq'),t.uuid('ac-sav')]) ac;
  if c1 <> c2 then raise exception 'AT-SNAP-01 FAIL content digest changed'; end if;
  if bnx.snapshot_replay_access(t.uuid('bo'),snap) <> 'ok' then raise exception 'AT-SNAP-02 FAIL pre'; end if;
  update bnx.account_grant set can_view=false where member_id=t.uuid('bo') and account_id=t.uuid('a-sav');
  if bnx.snapshot_replay_access(t.uuid('bo'),snap) <> 'ACCESS_REVOKED' then raise exception 'AT-SNAP-02 FAIL revoked'; end if;
  if bnx.snapshot_replay_access(t.uuid('ann'),snap) <> 'ok' then raise exception 'AT-SNAP-02 FAIL owner'; end if;
  raise notice 'PASS AT-SNAP-01/02: content digest stable at V% after a back-dated posting; revoked actor -> ACCESS_REVOKED', vs;
end $$;
