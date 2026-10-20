-- BEFORE d0c_entries: the legacy hole exists (positive control for the after-suite).
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111';
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  ops2 uuid := '77777777-7777-7777-7777-777777777777';
  fin uuid := '99999999-9999-9999-9999-999999999999';
  client uuid := '88888888-8888-8888-8888-888888888888';
  j1 text := 'b1000000-0000-0000-0000-000000000001';
  j2 text := 'b2000000-0000-0000-0000-000000000002';
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    PERFORM t_expect(t || ': company-1 staff reads company-2 rows too (hole)', t_count('authenticated', ops, 'select * from public.' || t), 'n:2');
    PERFORM t_expect(t || ': finance_manager (no ops atom) reads all (hole)',  t_count('authenticated', fin, 'select * from public.' || t), 'n:2');
    PERFORM t_expect(t || ': viewer inserts (hole)', t_dml('authenticated', viewer, 'insert into public.' || t || ' (job_id) values (''' || j1 || ''')'), 'rows:1');
    PERFORM t_expect(t || ': company-2 staff inserts into company-1 job (hole)', t_dml('authenticated', ops2, 'insert into public.' || t || ' (job_id) values (''' || j1 || ''')'), 'rows:1');
    PERFORM t_expect(t || ': viewer updates (hole)', t_dml('authenticated', viewer, 'update public.' || t || ' set sort_order = 9'), 'rows:4');
    PERFORM t_expect(t || ': viewer deletes (hole)', t_dml('authenticated', viewer, 'delete from public.' || t), 'rows:4');
    PERFORM t_expect(t || ': client (no staff row) still blocked by D0a', t_count('authenticated', client, 'select * from public.' || t), 'n:0');
  END LOOP;
END $$;
ROLLBACK;
