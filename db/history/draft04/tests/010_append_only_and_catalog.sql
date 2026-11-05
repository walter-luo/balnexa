-- INV-37 / AT-TMP-10: class registry complete; class F tables append-only; login roles hold no table privileges.
do $$
declare r record; j uuid; ok boolean;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
            where n.nspname='bnx' and c.relkind='r' loop
    if not exists (select 1 from bnx.table_class where table_name = r.relname) then
      raise exception 'AT-TMP-10 FAIL: table % has no class', r.relname; end if;
  end loop;
  for r in select table_name from bnx.table_class where class='F' loop
    if not exists (select 1 from pg_trigger tg join pg_class c on c.oid=tg.tgrelid join pg_namespace n on n.oid=c.relnamespace
                   where n.nspname='bnx' and c.relname=r.table_name and tg.tgname='t_append_only') then
      raise exception 'AT-TMP-10 FAIL: class F table % lacks t_append_only', r.table_name; end if;
  end loop;
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='bnx' and c.relkind in ('r','v') loop
    if has_table_privilege('bnx_app','bnx.'||quote_ident(r.relname),'select')
       or has_table_privilege('bnx_worker','bnx.'||quote_ident(r.relname),'insert')
       or has_table_privilege('bnx_authn','bnx.'||quote_ident(r.relname),'select') then
      raise exception 'AT-SEC FAIL: login role has privilege on %', r.relname; end if;
  end loop;
  perform t.setup();
  perform t.set_anchor(t.uuid('ac-chq'), '2026-01-01', 1000, 'test');
  j := t.post('Groceries','2026-03-31',60,t.uuid('la-exp'),t.uuid('la-chq'));
  begin update bnx.journal_line set amount = amount where journal_id = j; ok := false;
  exception when sqlstate 'P0409' then ok := true; end;
  if not ok then raise exception 'INV-37 FAIL: journal_line update allowed'; end if;
  begin delete from bnx.opening_anchor_version; ok := false;
  exception when sqlstate 'P0409' then ok := true; end;
  if not ok then raise exception 'INV-37 FAIL: anchor version delete allowed'; end if;
  raise notice 'PASS 010 append-only, class registry, privileges';
end $$;
