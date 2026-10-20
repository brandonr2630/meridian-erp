-- BEFORE d0c_config: the legacy holes exist (positive control). Active staff of any role can read and write every catalog and employee.
BEGIN;
DO $$
DECLARE
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  sales  uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  client uuid := '88888888-8888-8888-8888-888888888888';
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
    'config_qc_checklists','config_tasks','config_tooling','employees'] LOOP
    PERFORM t_expect('before ' || t || ': viewer reads', t_count('authenticated', viewer, 'select * from public.' || t), 'n:2');
    PERFORM t_expect('before ' || t || ': sales_rep (no catalog atoms) reads', t_count('authenticated', sales, 'select * from public.' || t), 'n:2');
    PERFORM t_expect('before ' || t || ': viewer updates', t_dml('authenticated', viewer, 'update public.' || t || ' set created_at = created_at'), 'rows:2');
    PERFORM t_expect('before ' || t || ': client (non-staff) already blocked by D0a', t_count('authenticated', client, 'select * from public.' || t), 'n:0');
    PERFORM t_expect('before ' || t || ': sales_rep deletes', t_dml('authenticated', sales, 'delete from public.' || t), 'rows:2');
  END LOOP;
  PERFORM t_expect('before employees: viewer inserts', t_dml('authenticated', viewer, 'insert into public.employees (name) values (''x'')'), 'rows:1');
  PERFORM t_expect('before notification_types: sales_rep reads', t_count('authenticated', sales, 'select * from public.notification_types'), 'n:2');
  PERFORM t_expect('before notification_types: legacy read policy present',
    (SELECT count(*)::text FROM pg_policies WHERE tablename='notification_types' AND policyname='notif_types_read'), '1');
END $$;
ROLLBACK;
