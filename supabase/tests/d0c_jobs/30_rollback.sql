-- AFTER the down script: the legacy open policy is back, the d0c objects are gone.
BEGIN;
DO $$
DECLARE
  viewer text := '22222222-2222-2222-2222-222222222222'; fin text := '88888888-8888-8888-8888-888888888888';
  opsc1 text := '11111111-1111-1111-1111-111111111111';
BEGIN
  PERFORM t_expect('rollback: no d0c_jobs policy left', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname LIKE 'd0c_jobs_%'), '0');
  PERFORM t_expect('rollback: legacy policy restored exactly', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname='authenticated users full access' AND cmd='ALL' AND permissive='PERMISSIVE' AND roles='{authenticated}' AND qual='true' AND with_check='true'), '1');
  PERFORM t_expect('rollback: D0a restrictive pair kept', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname IN ('d0_staff_only','d0_no_anon')), '2');
  PERFORM t_expect('rollback: trigger removed', (SELECT count(*)::text FROM pg_trigger WHERE tgname='d0c_jobs_lock_company'), '0');
  PERFORM t_expect('rollback: function removed', (SELECT count(*)::text FROM pg_proc WHERE proname='d0c_jobs_lock_company'), '0');
  PERFORM t_expect('rollback: ops C1 sees all companies again', t_count('authenticated', opsc1::uuid, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('rollback: finance_manager reads again', t_count('authenticated', fin::uuid, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('rollback: viewer can write again', t_dml('authenticated', viewer::uuid, 'UPDATE jobs SET customer=''x'' WHERE id=''b1000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('rollback: company move possible again', t_dml('authenticated', opsc1::uuid, 'UPDATE jobs SET company_id=''c2000000-0000-0000-0000-000000000002'' WHERE id=''b1000000-0000-0000-0000-000000000004'''), 'rows:1');
  PERFORM t_expect('rollback: anon still sees nothing (D0a)', t_count('anon', NULL, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('rollback: inactive staff still blocked (D0a)', t_count('authenticated', '66666666-6666-6666-6666-666666666666'::uuid, 'SELECT 1 FROM jobs'), 'n:0');
END $$;
ROLLBACK;
