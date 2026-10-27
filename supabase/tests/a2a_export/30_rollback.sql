-- AFTER the down script: both functions are gone; the audit rows and assigned uids written while the function existed stay.
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('down: prepare_schedule_export is gone', (SELECT count(*)::text FROM pg_proc WHERE proname = 'prepare_schedule_export'), '0');
  PERFORM t_expect('down: schedule_export_core is gone', (SELECT count(*)::text FROM pg_proc WHERE proname = 'schedule_export_core'), '0');
  PERFORM t_expect('down: Phase A lock_job_baseline stays', (SELECT count(*)::text FROM pg_proc WHERE proname = 'lock_job_baseline'), '1');
  PERFORM t_expect('down: schedule_exported audit rows untouched (committed marker export)',
    (SELECT count(*)::text FROM job_audit_log WHERE action_type = 'schedule_exported' AND job_id = 'b1000000-0000-0000-0000-0000000000f1'), '1');
  PERFORM t_expect('down: assigned uids untouched',
    (SELECT string_agg(k || '=' || u, ',' ORDER BY k) FROM (SELECT 'p' AS k, msp_uid::text AS u FROM job_phases WHERE job_id = 'b1000000-0000-0000-0000-0000000000f1'
      UNION ALL SELECT 't', msp_uid::text FROM job_tasks WHERE job_id = 'b1000000-0000-0000-0000-0000000000f1') s), 'p=1,t=2');
  PERFORM t_expect('down: msp_uid columns still there (they belong to the schema migration)',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'msp_uid' AND table_name IN ('job_phases', 'job_tasks')), '2');
END $$;
ROLLBACK;
