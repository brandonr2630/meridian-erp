-- BEFORE the migration: the import RPC and its helpers do not exist (positive control); the base columns it needs do.
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('before: import_job_schedule does not exist', coalesce(to_regprocedure('public.import_job_schedule(uuid,text,jsonb,text)')::text, 'none'), 'none');
  PERFORM t_expect('before: no import_sched_ helpers',
    (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'import\_sched\_%'), '0');
  PERFORM t_expect('before: base columns exist (link_type, msp_uid x2, parent_task_id)',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema='public'
       AND ((table_name='job_task_links' AND column_name='link_type') OR (table_name IN ('job_phases','job_tasks') AND column_name='msp_uid')
            OR (table_name='job_tasks' AND column_name='parent_task_id'))), '4');
  PERFORM t_expect('before: lock_job_baseline exists (owner reference for the baseline guard)',
    (to_regprocedure('public.lock_job_baseline(uuid,text)') IS NOT NULL)::text, 'true');
  PERFORM t_expect('before: no schedule_imported audit rows', (SELECT count(*)::text FROM job_audit_log WHERE action_type = 'schedule_imported'), '0');
END $$;
ROLLBACK;
