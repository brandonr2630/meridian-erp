-- BEFORE the migration: the Phase A objects do not exist and job_tasks is still the v1 table (positive control).
BEGIN;
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111';
BEGIN
  PERFORM t_expect('before: job_phases does not exist', coalesce(to_regclass('public.job_phases')::text, 'none'), 'none');
  PERFORM t_expect('before: job_task_links does not exist', coalesce(to_regclass('public.job_task_links')::text, 'none'), 'none');
  PERFORM t_expect('before: no new job_tasks columns',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_name='job_tasks'
      AND column_name IN ('phase_id','is_milestone','is_critical','weight','baseline_start','baseline_end','baseline_locked_at','client_visible')), '0');
  PERFORM t_expect('before: job_tasks has the 12 live columns',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_name='job_tasks' AND table_schema='public'), '12');
  PERFORM t_expect('before: job_tasks has no user triggers',
    (SELECT count(*)::text FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal), '0');
  PERFORM t_expect('before: no Phase A functions',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('lock_job_baseline','job_visibility_guard','job_task_client_visible',
      'job_task_weight','job_task_planned_pct','job_schedule_status','job_task_links_no_cycle','job_tasks_baseline_guard')), '0');
  PERFORM t_expect('before: job_tasks has its four RLS policies',
    (SELECT count(*)::text FROM pg_policies WHERE tablename='job_tasks'), '4');
  PERFORM t_expect('before: legacy depends_on chain is there',
    (SELECT depends_on::text FROM job_tasks WHERE id='d1000000-0000-0000-0000-000000000002'), 'd1000000-0000-0000-0000-000000000001');
  -- no updated_at trigger yet: a client-supplied older updated_at sticks (the hole the new trigger closes)
  PERFORM t_expect('before: ops update with old updated_at keeps it',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET progress = 60, updated_at = ''2000-01-01'' WHERE id=''d1000000-0000-0000-0000-000000000002'''), 'rows:1');
  PERFORM t_expect('before: updated_at was not moved forward',
    (SELECT (updated_at < '2001-01-01')::text FROM job_tasks WHERE id='d1000000-0000-0000-0000-000000000002'), 'true');
END $$;
ROLLBACK;
