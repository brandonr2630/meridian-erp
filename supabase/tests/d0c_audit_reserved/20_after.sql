-- AFTER the reserved-actions migration: reserved types are refused from a session, everything else about D0c is unchanged. One rolled-back transaction.
BEGIN;
DO $$
DECLARE
  ops1   uuid := '11111111-1111-1111-1111-111111111111';  -- operations_tech, C1
  viewer uuid := '22222222-2222-2222-2222-222222222222';  -- viewer, C1
  cadm   uuid := '33333333-3333-3333-3333-333333333333';  -- company_admin, C1
  sup    uuid := '44444444-4444-4444-4444-444444444444';  -- super_admin, C1 + C2
  ops2   uuid := '77777777-7777-7777-7777-777777777777';  -- operations_tech, C2
  b1 text := 'b1000000-0000-0000-0000-000000000001';
  b2 text := 'b2000000-0000-0000-0000-000000000002';
  a text; u uuid; nm text;
BEGIN
  PERFORM t_expect('policy: one insert policy, still the D0c name', (SELECT string_agg(policyname || ':' || cmd, ',') FROM pg_policies WHERE tablename = 'job_audit_log' AND policyname = 'd0c_job_audit_log_insert'), 'd0c_job_audit_log_insert:INSERT');
  PERFORM t_expect('policy: the check names every reserved type', (SELECT (with_check LIKE '%baseline_locked%' AND with_check LIKE '%baseline_reset%' AND with_check LIKE '%visibility_changed%' AND with_check LIKE '%schedule_exported%' AND with_check LIKE '%schedule_imported%')::text FROM pg_policies WHERE policyname = 'd0c_job_audit_log_insert'), 'true');
  PERFORM t_expect('policy: documented in the database', (SELECT (obj_description(oid, 'pg_policy') LIKE '%schedule_imported%' AND obj_description(oid, 'pg_policy') LIKE '%verify-audit-reserved%')::text FROM pg_policy WHERE polname = 'd0c_job_audit_log_insert'), 'true');
  PERFORM t_expect('policy: applies to authenticated only', (SELECT roles::text FROM pg_policies WHERE policyname = 'd0c_job_audit_log_insert'), '{authenticated}');
  PERFORM t_expect('policy: no other permissive policy lets inserts through', (SELECT count(*)::text FROM pg_policies WHERE tablename = 'job_audit_log' AND permissive = 'PERMISSIVE' AND cmd IN ('INSERT', 'ALL')), '1');

  -- reserved types are refused for every staff identity that can write, in their own company, under their own name
  FOREACH a IN ARRAY ARRAY['baseline_locked', 'baseline_reset', 'visibility_changed', 'schedule_exported', 'schedule_imported'] LOOP
    PERFORM t_expect('reserved ' || a || ': operations_tech is refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''' || a || ''')'), 'err:42501');
    PERFORM t_expect('reserved ' || a || ': company_admin is refused', t_dml('authenticated', cadm, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || cadm || ''', ''' || a || ''')'), 'err:42501');
    PERFORM t_expect('reserved ' || a || ': super_admin is refused too', t_dml('authenticated', sup, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || sup || ''', ''' || a || ''')'), 'err:42501');
  END LOOP;

  -- what the web app writes keeps working, and so do types nobody has reserved (deny-list, not allow-list)
  PERFORM t_expect('allowed job_saved', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''job_saved'')'), 'rows:1');
  PERFORM t_expect('allowed job_deleted with RETURNING (the ERP sends return=representation)', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''job_deleted'') RETURNING id'), 'rows:1');
  PERFORM t_expect('allowed: a new type the app might start writing (not reserved) is not lost', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''po_approved'')'), 'rows:1');
  PERFORM t_expect('allowed: a type that merely starts like a reserved one', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''schedule_imported_note'')'), 'rows:1');
  PERFORM t_expect('allowed: other-company super admin on its own job', t_dml('authenticated', ops2, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''', ''' || ops2 || ''', ''job_saved'')'), 'rows:1');

  -- everything D0c already guaranteed is unchanged
  PERFORM t_expect('d0c: another user''s id is still refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || cadm || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: NULL user_id is still refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, action_type) VALUES (''' || b1 || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: a staff.access.* row is still refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || ops1 || ''', ''staff.access.remove'')'), 'err:42501');
  PERFORM t_expect('d0c: a job of another company is still refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''', ''' || ops1 || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: a row without a job is still refused', t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (user_id, action_type) VALUES (''' || ops1 || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: a viewer (no write atom) is still refused', t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''', ''' || viewer || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: anon is still refused', t_dml('anon', NULL, 'INSERT INTO job_audit_log (job_id, action_type) VALUES (''' || b1 || ''', ''job_saved'')'), 'err:42501');
  PERFORM t_expect('d0c: update is still impossible', t_dml('authenticated', ops1, 'UPDATE job_audit_log SET description = ''x'''), 'err:42501');
  PERFORM t_expect('d0c: delete is still impossible', t_dml('authenticated', ops1, 'DELETE FROM job_audit_log'), 'err:42501');

  -- the real writers are unaffected: a SECURITY DEFINER function owned by the migration owner still writes every reserved type
  FOREACH a IN ARRAY ARRAY['baseline_locked', 'baseline_reset', 'visibility_changed', 'schedule_exported', 'schedule_imported'] LOOP
    PERFORM t_expect('definer writes ' || a, t_dml('authenticated', ops1, format('SELECT t_definer_audit(%L, %L)', b1, a)), 'rows:1');
  END LOOP;
  PERFORM t_expect('definer rows are readable by the caller''s company', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log WHERE action_type = ''schedule_imported'' AND description = ''written by a function'''), 'n:1');
  PERFORM t_expect('definer rows are not readable by another company', t_count('authenticated', ops2, 'SELECT 1 FROM job_audit_log WHERE action_type = ''schedule_imported'''), 'n:0');
  RAISE NOTICE 'PASS after-suite done';
END $$;
ROLLBACK;
