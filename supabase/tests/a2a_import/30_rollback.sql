-- AFTER the down script: the RPC and its helpers are gone; the base columns, Phase A objects and audit rows are untouched.
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('down: import_job_schedule is gone', coalesce(to_regprocedure('public.import_job_schedule(uuid,text,jsonb,text)')::text, 'none'), 'none');
  PERFORM t_expect('down: no import_sched_ helpers remain', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'import\_sched\_%'), '0');
  PERFORM t_expect('down: lock_job_baseline and the baseline guard remain',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('lock_job_baseline', 'job_tasks_baseline_guard', 'job_visibility_guard')), '3');
  PERFORM t_expect('down: base columns remain',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema='public'
       AND ((table_name='job_task_links' AND column_name='link_type') OR (table_name IN ('job_phases','job_tasks') AND column_name='msp_uid')
            OR (table_name='job_tasks' AND column_name='parent_task_id'))), '4');
  PERFORM t_expect('down: no temp working tables survive', (SELECT count(*)::text FROM pg_class WHERE relname LIKE 'imp\_%' AND relpersistence = 'p'), '0');
END $$;
ROLLBACK;
