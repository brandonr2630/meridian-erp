-- AFTER the down script: every A2a object is gone, Phase A is untouched.
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('down: no link_type / msp_uid / parent_task_id columns',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema='public'
      AND ((table_name='job_task_links' AND column_name='link_type')
        OR (table_name IN ('job_phases','job_tasks') AND column_name='msp_uid')
        OR (table_name='job_tasks' AND column_name='parent_task_id'))), '0');
  PERFORM t_expect('down: no a2a indexes',
    (SELECT count(*)::text FROM pg_indexes WHERE indexname IN ('job_phases_msp_uid_uq','job_tasks_msp_uid_uq','job_tasks_parent_idx')), '0');
  PERFORM t_expect('down: parent guard function and trigger are gone',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'job_tasks_parent_guard')
    || '/' || (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'job_tasks_parent_guard'), '0/0');
  PERFORM t_expect('down: the company guard function, its three triggers and the msp_uid range constraints are gone',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'job_schedule_company_guard') || '/' || (SELECT count(*)::text FROM pg_trigger WHERE tgname LIKE '%company_guard')
    || '/' || (SELECT count(*)::text FROM pg_constraint WHERE conname LIKE '%msp_uid%'), '0/0/0');
  PERFORM t_expect('down: job_phases and job_task_links triggers do not include a company guard',
    (SELECT count(*)::text FROM pg_trigger WHERE tgrelid IN ('public.job_phases'::regclass, 'public.job_task_links'::regclass) AND NOT tgisinternal AND tgname LIKE '%company%'), '0');
  PERFORM t_expect('down: job_tasks triggers are the Phase A three again',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal),
    'job_tasks_baseline_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
  PERFORM t_expect('down: the free-uid helper and the jobs company guard are gone', (SELECT count(*)::text FROM pg_proc WHERE proname IN ('sched_free_uids', 'jobs_company_change_guard')) || '/' || (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'jobs_company_change_guard'), '0/0');
  PERFORM t_expect('down: job_task_links_no_cycle still guards (Phase A intact)',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'job_task_links_no_cycle'), '1');
  PERFORM t_expect('down: legacy links and tasks survive (3 links, 7 tasks)',
    (SELECT count(*)::text FROM job_task_links) || '/' || (SELECT count(*)::text FROM job_tasks), '3/7');
END $$;
ROLLBACK;
