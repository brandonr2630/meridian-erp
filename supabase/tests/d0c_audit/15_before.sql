-- BEFORE the D0c audit migration: the legacy open policy is in place, so the holes exist (positive control).
BEGIN;
DO $$
DECLARE
  ops1   uuid := '11111111-1111-1111-1111-111111111111';
  viewer uuid := '22222222-2222-2222-2222-222222222222';
  b1 text := 'b1000000-0000-0000-0000-000000000001';
  b2 text := 'b2000000-0000-0000-0000-000000000002';
BEGIN
  PERFORM t_expect('before: policy "authenticated users full access" exists',
    (SELECT count(*)::text FROM pg_policies WHERE tablename='job_audit_log' AND policyname='authenticated users full access'), '1');
  PERFORM t_expect('before: C1 ops sees every row of every company and the NULL-job rows', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log'), 'n:3');
  PERFORM t_expect('before: viewer (read atoms only) can insert an audit row for ANOTHER company job',
    t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''', ''' || viewer || ''', ''job_saved'')'), 'rows:1');
  PERFORM t_expect('before: viewer can forge a row as another user',
    t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''job_saved'')'), 'rows:1');
  PERFORM t_expect('before: viewer can forge a staff.access row',
    t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (user_id, action_type) VALUES (''' || viewer || ''', ''staff.access.remove'')'), 'rows:1');
  PERFORM t_expect('before: viewer can rewrite audit history', t_dml('authenticated', viewer, 'UPDATE job_audit_log SET description = ''tampered'''), 'rows:6');
  PERFORM t_expect('before: viewer can erase audit history', t_dml('authenticated', viewer, 'DELETE FROM job_audit_log'), 'rows:6');
  PERFORM t_expect('before: authenticated holds TRUNCATE', has_table_privilege('authenticated', 'public.job_audit_log', 'TRUNCATE')::text, 'true');
  RAISE NOTICE 'PASS before-suite done';
END $$;
ROLLBACK;
