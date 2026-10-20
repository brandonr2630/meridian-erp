-- AFTER the down script: the legacy open policy is back exactly, d0c policies gone, D0a pair intact.
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111';
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  client uuid := '88888888-8888-8888-8888-888888888888';
  j1 text := 'b1000000-0000-0000-0000-000000000001';
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    PERFORM t_expect(t || ': legacy policy restored', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname='authenticated users full access' and cmd='ALL' and permissive='PERMISSIVE' and roles='{authenticated}' and qual='true' and with_check='true'), '1');
    PERFORM t_expect(t || ': d0c policies gone', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname like 'd0c\_%'), '0');
    PERFORM t_expect(t || ': D0a pair intact', (select count(*)::text from pg_policies where schemaname='public' and tablename=t and policyname in ('d0_staff_only','d0_no_anon')), '2');
    PERFORM t_expect(t || ': ops reads all again', t_count('authenticated', ops, 'select * from public.' || t), 'n:2');
    PERFORM t_expect(t || ': viewer writes again', t_dml('authenticated', viewer, 'insert into public.' || t || ' (job_id) values (''' || j1 || ''')'), 'rows:1');
    PERFORM t_expect(t || ': client still blocked by D0a', t_count('authenticated', client, 'select * from public.' || t), 'n:0');
  END LOOP;
END $$;
ROLLBACK;
