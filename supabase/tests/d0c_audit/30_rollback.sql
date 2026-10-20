-- AFTER the rollback script: legacy open policy and grants are back, d0c policies gone, D0a policies untouched.
BEGIN;
DO $$
DECLARE
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  ops1   uuid := '11111111-1111-1111-1111-111111111111';
  client uuid := '99999999-9999-9999-9999-999999999999';
  b2 text := 'b2000000-0000-0000-0000-000000000002';
BEGIN
  PERFORM t_expect('rollback: legacy policy restored', (SELECT count(*)::text FROM pg_policies WHERE tablename='job_audit_log' AND policyname='authenticated users full access' AND cmd='ALL' AND permissive='PERMISSIVE' AND qual='true' AND with_check='true' AND roles='{authenticated}'), '1');
  PERFORM t_expect('rollback: no d0c policy left', (SELECT count(*)::text FROM pg_policies WHERE tablename='job_audit_log' AND policyname LIKE 'd0c\_%'), '0');
  PERFORM t_expect('rollback: D0a restrictive policies still present', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='job_audit_log' AND permissive='RESTRICTIVE'), 'd0_no_anon,d0_staff_only');
  PERFORM t_expect('rollback: authenticated UPDATE privilege restored', has_table_privilege('authenticated','public.job_audit_log','UPDATE')::text, 'true');
  PERFORM t_expect('rollback: authenticated DELETE privilege restored', has_table_privilege('authenticated','public.job_audit_log','DELETE')::text, 'true');
  PERFORM t_expect('rollback: authenticated TRUNCATE privilege restored', has_table_privilege('authenticated','public.job_audit_log','TRUNCATE')::text, 'true');
  PERFORM t_expect('rollback: anon TRUNCATE privilege restored', has_table_privilege('anon','public.job_audit_log','TRUNCATE')::text, 'true');
  PERFORM t_expect('rollback: staff sees all rows again (legacy behaviour)', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log'), 'n:3');
  PERFORM t_expect('rollback: viewer can insert again (legacy behaviour)',
    t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''',''' || viewer || ''',''job_saved'')'), 'rows:1');
  PERFORM t_expect('rollback: viewer can update again (legacy behaviour)', t_dml('authenticated', viewer, 'UPDATE job_audit_log SET description = ''x'''), 'rows:4');
  PERFORM t_expect('rollback: client without staff row still sees nothing (D0a stays)', t_count('authenticated', client, 'SELECT 1 FROM job_audit_log'), 'n:0');
  PERFORM t_expect('rollback: anon still sees nothing (D0a stays)', t_count('anon', NULL, 'SELECT 1 FROM job_audit_log'), 'n:0');
END $$;
ROLLBACK;
