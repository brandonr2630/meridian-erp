-- AFTER the d0c_bills down script: the exact legacy state is back.
BEGIN;
DO $$
DECLARE
  ops    uuid := '11111111-1111-1111-1111-111111111111';
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  client uuid := '88888888-8888-8888-8888-888888888888';
  b1 text := 'd1000000-0000-0000-0000-000000000001';
BEGIN
  PERFORM t_expect('rollback: legacy policy back (events)',  (select count(*)::text from pg_policies where tablename='bill_edit_events'  and policyname='authenticated users full access' and permissive='PERMISSIVE' and cmd='ALL' and qual='true' and with_check='true' and roles='{authenticated}'), '1');
  PERFORM t_expect('rollback: legacy policy back (archive)', (select count(*)::text from pg_policies where tablename='bill_lines_archive' and policyname='authenticated users full access' and permissive='PERMISSIVE' and cmd='ALL' and qual='true' and with_check='true' and roles='{authenticated}'), '1');
  PERFORM t_expect('rollback: no d0c_ policies left', (select count(*)::text from pg_policies where policyname like 'd0c_%' and tablename in ('bill_edit_events','bill_lines_archive')), '0');
  PERFORM t_expect('rollback: D0a pair intact', (select count(*)::text from pg_policies where policyname in ('d0_staff_only','d0_no_anon') and tablename in ('bill_edit_events','bill_lines_archive')), '4');
  PERFORM t_expect('rollback: ops reads all again',      t_count('authenticated', ops, 'select * from public.bill_edit_events'), 'n:7');
  PERFORM t_expect('rollback: viewer writes again',      t_dml('authenticated', viewer, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', null, ''x'')'), 'rows:1');
  PERFORM t_expect('rollback: non-staff still blocked by D0a', t_count('authenticated', client, 'select * from public.bill_lines_archive'), 'n:0');
END $$;
ROLLBACK;
