-- AFTER the down script: the exact legacy policies are back, no d0c_ policy remains, D0a restrictive guards still hold.
BEGIN;
DO $$
DECLARE
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  sales  uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  client uuid := '88888888-8888-8888-8888-888888888888';
  t text;
BEGIN
  PERFORM t_expect('rollback: no d0c policies', (SELECT count(*)::text FROM pg_policies WHERE policyname LIKE 'd0c\_%'), '0');
  PERFORM t_expect('rollback: legacy full-access policy on 10 tables',
    (SELECT count(*)::text FROM pg_policies WHERE policyname = 'authenticated users full access' AND permissive = 'PERMISSIVE'
       AND cmd = 'ALL' AND roles = '{authenticated}' AND qual = 'true' AND with_check = 'true'
       AND tablename IN ('config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
                         'config_qc_checklists','config_tasks','config_tooling','employees')), '10');
  PERFORM t_expect('rollback: notif_types_read restored',
    (SELECT count(*)::text FROM pg_policies WHERE tablename='notification_types' AND policyname='notif_types_read' AND cmd='SELECT' AND qual='true'), '1');
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
    'config_qc_checklists','config_tasks','config_tooling','employees'] LOOP
    PERFORM t_expect('rollback ' || t || ': viewer reads again', t_count('authenticated', viewer, 'select * from public.' || t), 'n:2');
    PERFORM t_expect('rollback ' || t || ': client still blocked (D0a)', t_count('authenticated', client, 'select * from public.' || t), 'n:0');
    PERFORM t_expect('rollback ' || t || ': sales_rep deletes again', t_dml('authenticated', sales, 'delete from public.' || t), 'rows:2');
  END LOOP;
  PERFORM t_expect('rollback notification_types: sales_rep reads', t_count('authenticated', sales, 'select * from public.notification_types'), 'n:2');
  PERFORM t_expect('rollback notification_types: still no writes', t_dml('authenticated', viewer, 'update public.notification_types set enabled = false'), 'rows:0');
END $$;
ROLLBACK;
