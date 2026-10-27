-- BEFORE the migration: prepare_schedule_export does not exist (positive control). The base columns do (a2a_schema is applied by requires.txt).
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('before: prepare_schedule_export does not exist',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('prepare_schedule_export', 'schedule_export_core')), '0');
  PERFORM t_expect('before: msp_uid columns exist on both tables (base contract)',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'msp_uid'
       AND table_name IN ('job_phases', 'job_tasks')), '2');
  PERFORM t_expect('before: lock_job_baseline exists (owner reference)',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'lock_job_baseline'), '1');
  PERFORM t_expect('before: no schedule_exported audit rows',
    (SELECT count(*)::text FROM job_audit_log WHERE action_type = 'schedule_exported'), '0');
  PERFORM t_expect('before: job_audit_log has no CHECK on action_type (so schedule_exported is legal in the stub)',
    (SELECT count(*)::text FROM pg_constraint WHERE conrelid = 'public.job_audit_log'::regclass AND contype = 'c'), '0');
END $$;
ROLLBACK;
