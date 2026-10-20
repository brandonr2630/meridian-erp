-- BEFORE d0c_bills: prove the legacy holes exist (positive control for the AFTER suite).
BEGIN;
DO $$
DECLARE
  ops    uuid := '11111111-1111-1111-1111-111111111111';
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  adm    uuid := '33333333-3333-3333-3333-333333333333';
  client uuid := '88888888-8888-8888-8888-888888888888';
  e2 text := 'f2000000-0000-0000-0000-000000000002';
  b1 text := 'd1000000-0000-0000-0000-000000000001';
BEGIN
  -- already closed by D0a: non-staff
  PERFORM t_expect('before: client sees no events (D0a)', t_count('authenticated', client, 'select * from public.bill_edit_events'), 'n:0');
  -- holes D0c closes
  PERFORM t_expect('before: ops (no AP atom) reads all companies events',  t_count('authenticated', ops, 'select * from public.bill_edit_events'), 'n:7');
  PERFORM t_expect('before: ops reads all companies archive',              t_count('authenticated', ops, 'select * from public.bill_lines_archive'), 'n:5');
  PERFORM t_expect('before: C1 admin sees C3 events',                      t_count('authenticated', adm, 'select * from public.bill_edit_events where bill_id = ''d3000000-0000-0000-0000-000000000003'''), 'n:1');
  PERFORM t_expect('before: viewer inserts an event',                      t_dml('authenticated', viewer, 'insert into public.bill_edit_events (bill_id, edited_by, reason) values (''' || b1 || ''', null, ''x'')'), 'rows:1');
  PERFORM t_expect('before: viewer rewrites another company event',        t_dml('authenticated', viewer, 'update public.bill_edit_events set reason = ''tampered'' where id = ''' || e2 || ''''), 'rows:1');
  PERFORM t_expect('before: viewer deletes archive rows',                  t_dml('authenticated', viewer, 'delete from public.bill_lines_archive'), 'rows:5');
END $$;
ROLLBACK;
