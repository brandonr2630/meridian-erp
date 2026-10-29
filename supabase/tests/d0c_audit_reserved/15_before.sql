-- BEFORE the reserved-actions migration (D0c is in force): the remaining hole exists (positive control).
BEGIN;
DO $$
DECLARE
  ops1 uuid := '11111111-1111-1111-1111-111111111111';
  b1 text := 'b1000000-0000-0000-0000-000000000001';
BEGIN
  PERFORM t_expect('before: D0c insert policy is in force', (SELECT count(*)::text FROM pg_policies WHERE tablename = 'job_audit_log' AND policyname = 'd0c_job_audit_log_insert'), '1');
  PERFORM t_expect('before: a writer can insert a made-up schedule_imported row under their own name',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type, metadata) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''schedule_imported'', ''{"recovery":"forged"}'')'), 'rows:1');
  PERFORM t_expect('before: ... and a made-up baseline_locked row',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''baseline_locked'')'), 'rows:1');
  RAISE NOTICE 'PASS before-suite done';
END $$;
ROLLBACK;
