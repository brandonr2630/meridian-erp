-- BEFORE the a2a_schema migration: none of the A2a objects exist (positive control; the Phase A migration is already applied).
BEGIN;
DO $$
BEGIN
  PERFORM t_expect('before: job_task_links exists (Phase A applied)', coalesce(to_regclass('public.job_task_links')::text, 'none'), 'job_task_links');
  PERFORM t_expect('before: no link_type / msp_uid / parent_task_id columns',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema='public'
      AND ((table_name='job_task_links' AND column_name='link_type')
        OR (table_name IN ('job_phases','job_tasks') AND column_name='msp_uid')
        OR (table_name='job_tasks' AND column_name='parent_task_id'))), '0');
  PERFORM t_expect('before: no a2a indexes',
    (SELECT count(*)::text FROM pg_indexes WHERE indexname IN ('job_phases_msp_uid_uq','job_tasks_msp_uid_uq','job_tasks_parent_idx')), '0');
  PERFORM t_expect('before: no parent guard function or trigger',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'job_tasks_parent_guard')
    || '/' || (SELECT count(*)::text FROM pg_trigger WHERE tgname = 'job_tasks_parent_guard'), '0/0');
  PERFORM t_expect('before: no company guard function, trigger or msp_uid constraint',
    (SELECT count(*)::text FROM pg_proc WHERE proname = 'job_schedule_company_guard') || '/' || (SELECT count(*)::text FROM pg_trigger WHERE tgname LIKE '%company_guard')
    || '/' || (SELECT count(*)::text FROM pg_constraint WHERE conname LIKE '%msp_uid%'), '0/0/0');
  PERFORM t_expect('before: job_tasks triggers are the Phase A three',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal),
    'job_tasks_baseline_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
  PERFORM t_expect('before: the legacy backfilled links exist (3 rows)', (SELECT count(*)::text FROM job_task_links), '3');
END $$;
ROLLBACK;
