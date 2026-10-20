-- AFTER the down script: the original v1 state is restored and depends_on still works.
BEGIN;
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
BEGIN
  PERFORM t_expect('down: job_phases is gone', coalesce(to_regclass('public.job_phases')::text, 'none'), 'none');
  PERFORM t_expect('down: job_task_links is gone', coalesce(to_regclass('public.job_task_links')::text, 'none'), 'none');
  PERFORM t_expect('down: job_tasks is back to its 12 live columns',
    (SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='job_tasks'),
    'id,company_id,job_id,sort_order,task_name,start_date,end_date,progress,assignee,depends_on,created_at,updated_at');
  PERFORM t_expect('down: job_tasks has no triggers again',
    (SELECT count(*)::text FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal), '0');
  PERFORM t_expect('down: no Phase A functions remain',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('lock_job_baseline','job_visibility_guard','job_task_client_visible',
      'job_task_weight','job_task_planned_pct','job_schedule_status','job_task_links_no_cycle','job_tasks_baseline_guard')), '0');
  PERFORM t_expect('down: set_updated_at() itself stays', (SELECT count(*)::text FROM pg_proc WHERE proname='set_updated_at'), '1');
  PERFORM t_expect('down: the milestone/baseline/weight checks are gone, the v1 checks remain',
    (SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid='public.job_tasks'::regclass AND contype='c'),
    'job_tasks_dates_chk,job_tasks_progress_check');
  PERFORM t_expect('down: v1 FKs and PK remain',
    (SELECT string_agg(conname, ',' ORDER BY conname) FROM pg_constraint WHERE conrelid='public.job_tasks'::regclass AND contype IN ('f','p')),
    'job_tasks_company_id_fkey,job_tasks_depends_on_fkey,job_tasks_job_id_fkey,job_tasks_pkey');
  PERFORM t_expect('down: only the v1 indexes remain',
    (SELECT string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE tablename='job_tasks'),
    'idx_job_tasks_company_job,idx_job_tasks_depends_on,idx_job_tasks_job_id,job_tasks_pkey');
  PERFORM t_expect('down: the four job_tasks RLS policies are intact',
    (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='job_tasks'),
    'job_tasks members read,job_tasks writers delete,job_tasks writers insert,job_tasks writers update');
  PERFORM t_expect('down: depends_on values are untouched',
    (SELECT count(*)::text FROM job_tasks WHERE id::text LIKE 'd1000000-%' AND depends_on IS NOT NULL), '6');
  PERFORM t_expect('down: depends_on chain still resolves (T3 -> T2 -> T1)',
    (SELECT t3.depends_on::text || '>' || t2.depends_on::text FROM job_tasks t3 JOIN job_tasks t2 ON t2.id = t3.depends_on
      WHERE t3.id = 'd1000000-0000-0000-0000-000000000003'), 'd1000000-0000-0000-0000-000000000002>d1000000-0000-0000-0000-000000000001');
  PERFORM t_expect('down: v1 writer still edits a task incl. depends_on',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET depends_on=''d1000000-0000-0000-0000-000000000001'', progress=70 WHERE id=''d1000000-0000-0000-0000-000000000003'''), 'rows:1');
  PERFORM t_expect('down: v1 viewer still cannot write', t_dml('authenticated', viewr, 'UPDATE job_tasks SET progress=1'), 'rows:0');
  PERFORM t_expect('down: v1 viewer still reads', t_count('authenticated', viewr, 'SELECT 1 FROM job_tasks WHERE id::text LIKE ''d1000000-%'''), 'n:7');
  PERFORM t_expect('down: delete of the parent works', t_dml('postgres', NULL, 'DELETE FROM job_tasks WHERE id=''d1000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('down: depends_on FK still nulls the child when the parent is deleted',
    (SELECT coalesce(depends_on::text, 'null') FROM job_tasks WHERE id='d1000000-0000-0000-0000-000000000002'), 'null');
  PERFORM t_expect('down: a v1 insert without any new column works',
    t_dml('authenticated', ops, 'INSERT INTO job_tasks (company_id, job_id, task_name) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-000000000008'',''v1 insert'')'), 'rows:1');
  PERFORM t_expect('down: updated_at is client-controlled again (no trigger) - v1 behaviour: update accepted',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET updated_at=''2000-01-01'' WHERE task_name=''v1 insert'''), 'rows:1');
  PERFORM t_expect('down: ... and the old value sticks', (SELECT (updated_at < '2001-01-01')::text FROM job_tasks WHERE task_name='v1 insert'), 'true');
  PERFORM t_expect('down: the other tables the migration used are untouched (jobs, erp_users, job_audit_log)',
    (SELECT count(*)::text FROM pg_class WHERE relname IN ('jobs','erp_users','job_audit_log','companies') AND relkind='r'), '4');
END $$;
ROLLBACK;
