-- AFTER the rollback script: the D0c insert policy is back exactly (no reserved list); the rest of D0c is untouched.
BEGIN;
DO $$
DECLARE
  ops1 uuid := '11111111-1111-1111-1111-111111111111';
  b1 text := 'b1000000-0000-0000-0000-000000000001';
BEGIN
  PERFORM t_expect('rollback: the D0c insert and select policies are still there', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename = 'job_audit_log' AND policyname LIKE 'd0c\_%'), 'd0c_job_audit_log_insert,d0c_job_audit_log_select');
  PERFORM t_expect('rollback: the reserved list is gone from the policy', (SELECT (with_check LIKE '%schedule_imported%')::text FROM pg_policies WHERE policyname = 'd0c_job_audit_log_insert'), 'false');
  PERFORM t_expect('rollback: the policy comment is gone', (SELECT coalesce(obj_description(oid, 'pg_policy'), 'none') FROM pg_policy WHERE polname = 'd0c_job_audit_log_insert'), 'none');
  PERFORM t_expect('rollback: D0c still refuses a forged identity', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''22222222-2222-2222-2222-222222222222'', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('rollback: D0c still refuses staff.access.*', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''staff.access.remove'')'), 'err:42501');
  PERFORM t_expect('rollback: a writer can insert a reserved type again (the D0c state)', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''schedule_imported'')'), 'rows:1');
  RAISE NOTICE 'PASS rollback-suite done';
END $$;
ROLLBACK;
