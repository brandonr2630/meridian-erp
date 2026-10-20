-- AFTER the migration: Phase A (Schedule v2) SQL behaviour. One transaction, rolled back. Every check prints NOTICE 'PASS ...'.
-- Identities: ops = operations_tech C1 (read/write/approve), viewr = viewer C1, wrt = write-only (no approve) C1,
--             cadm = company_admin C1, sup = super_admin C1+C2, ops2 = operations_tech C2, fin = finance (no ops atoms) C1,
--             clnt = client-shaped (no erp_users row), anon.
BEGIN;

-- ===== fixtures (as postgres) =====
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','WO-A01','Open'),
 ('b2000000-0000-0000-0000-0000000000a2','c2000000-0000-0000-0000-000000000002','WO-A02','Open'),
 ('b1000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000001','WO-A03','Open'),
 ('b1000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000001','WO-A04','Open');
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f2000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',10,'Assess'),
 ('f2000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',20,'Make'),
 ('f2000000-0000-0000-0000-000000000009','c2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-0000000000a2',10,'Other co');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress, phase_id) VALUES
 ('f1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',1,'A1','2026-04-01','2026-04-10',0,'f2000000-0000-0000-0000-000000000001'),
 ('f1000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',2,'A2','2026-04-11','2026-04-20',0,NULL),
 ('f1000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',3,'A3',NULL,NULL,0,NULL),
 ('f1000000-0000-0000-0000-000000000009','c2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-0000000000a2',1,'B1','2026-04-01','2026-04-10',0,NULL);

-- ===== 1. structure =====
DO $$
BEGIN
  PERFORM t_expect('struct: RLS enabled on job_phases and job_task_links',
    (SELECT count(*)::text FROM pg_class WHERE relname IN ('job_phases','job_task_links') AND relrowsecurity), '2');
  PERFORM t_expect('struct: 4 policies each, all TO authenticated, none open',
    (SELECT count(*)::text FROM pg_policies WHERE tablename IN ('job_phases','job_task_links') AND roles = '{authenticated}'
       AND coalesce(qual,'') <> 'true' AND coalesce(with_check,'') <> 'true'), '8');
  PERFORM t_expect('struct: policy count per table',
    (SELECT string_agg(tablename || '=' || c, ',' ORDER BY tablename) FROM (SELECT tablename, count(*) c FROM pg_policies
      WHERE tablename IN ('job_phases','job_task_links','job_tasks') GROUP BY tablename) s), 'job_phases=4,job_task_links=4,job_tasks=4');
  PERFORM t_expect('struct: 8 new job_tasks columns',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_schema='public' AND table_name='job_tasks'
      AND column_name IN ('phase_id','is_milestone','is_critical','weight','baseline_start','baseline_end','baseline_locked_at','client_visible')), '8');
  PERFORM t_expect('struct: new defaults (client_visible false, flags false, weight null)',
    (SELECT client_visible::text || is_milestone::text || is_critical::text || coalesce(weight::text,'null') FROM job_tasks
      WHERE id='f1000000-0000-0000-0000-000000000001'), 'falsefalsefalsenull');
  PERFORM t_expect('struct: job_tasks triggers',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_tasks'::regclass AND NOT tgisinternal),
    'job_tasks_baseline_guard,job_tasks_set_updated_at,job_tasks_visibility_guard');
  PERFORM t_expect('struct: job_phases triggers',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_phases'::regclass AND NOT tgisinternal),
    'job_phases_set_updated_at,job_phases_visibility_guard');
  PERFORM t_expect('struct: job_task_links triggers',
    (SELECT string_agg(tgname, ',' ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.job_task_links'::regclass AND NOT tgisinternal),
    'job_task_links_no_cycle,job_task_links_set_updated_at');
END $$;

DO $$
BEGIN
  PERFORM t_expect('struct: job_tasks visibility trigger has exactly 2 args (task_name, empty atom)',
    (SELECT tgnargs::text || ':' || replace(encode(tgargs,'escape'), chr(92)||'000', '|') FROM pg_trigger
      WHERE tgrelid='public.job_tasks'::regclass AND tgname='job_tasks_visibility_guard'), '2:task_name||');
  PERFORM t_expect('struct: job_phases visibility trigger has exactly 2 args (name, empty atom)',
    (SELECT tgnargs::text || ':' || replace(encode(tgargs,'escape'), chr(92)||'000', '|') FROM pg_trigger
      WHERE tgrelid='public.job_phases'::regclass AND tgname='job_phases_visibility_guard'), '2:name||');
  PERFORM t_expect('struct: visibility triggers are BEFORE ROW INSERT OR UPDATE',
    (SELECT count(*)::text FROM pg_trigger WHERE tgname IN ('job_tasks_visibility_guard','job_phases_visibility_guard') AND tgtype = 23), '2');
  PERFORM t_expect('struct: baseline guard is BEFORE ROW INSERT OR UPDATE',
    (SELECT tgtype::text FROM pg_trigger WHERE tgname='job_tasks_baseline_guard'), '23');
  PERFORM t_expect('struct: set_updated_at triggers are BEFORE ROW UPDATE and call set_updated_at()',
    (SELECT count(*)::text FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
      WHERE t.tgname LIKE '%set_updated_at' AND t.tgtype = 19 AND p.proname='set_updated_at'), '3');
  PERFORM t_expect('struct: definer functions pin search_path',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('lock_job_baseline','job_visibility_guard') AND prosecdef
       AND array_to_string(proconfig, ',') LIKE '%search_path=public, pg_temp%'), '2');
  PERFORM t_expect('struct: the status/helper functions are SECURITY INVOKER',
    (SELECT count(*)::text FROM pg_proc WHERE proname IN ('job_schedule_status','job_task_client_visible','job_task_weight','job_task_planned_pct') AND NOT prosecdef), '4');
  PERFORM t_expect('struct: weight and planned helpers IMMUTABLE, status and visible STABLE',
    (SELECT string_agg(proname || '=' || provolatile::text, ',' ORDER BY proname) FROM pg_proc
      WHERE proname IN ('job_schedule_status','job_task_client_visible','job_task_weight','job_task_planned_pct')),
    'job_schedule_status=s,job_task_client_visible=s,job_task_planned_pct=i,job_task_weight=i');
  PERFORM t_expect('struct: indexes exist',
    (SELECT count(*)::text FROM pg_indexes WHERE indexname IN ('job_phases_job_idx','job_phases_company_job_idx','job_tasks_phase_idx',
      'job_task_links_job_idx','job_task_links_company_job_idx','job_task_links_pred_idx')), '6');
  PERFORM t_expect('struct: depends_on FK kept (ON DELETE SET NULL)',
    (SELECT confdeltype::text FROM pg_constraint WHERE conrelid='public.job_tasks'::regclass AND conname='job_tasks_depends_on_fkey'), 'n');
  PERFORM t_expect('struct: no cost-like column on the new tables',
    (SELECT count(*)::text FROM information_schema.columns WHERE table_name IN ('job_phases','job_task_links')
      AND (column_name LIKE '%cost%' OR column_name LIKE '%rate%' OR column_name LIKE '%price%')), '0');
END $$;

-- ===== 2. function exposure (X13) =====
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['lock_job_baseline(uuid,text)','job_task_weight(boolean,numeric,date,date)',
      'job_task_planned_pct(date,date,date,date,date)','job_schedule_status(uuid,date)','job_task_client_visible(uuid)'] LOOP
    PERFORM t_expect('exposure: anon cannot execute ' || f, has_function_privilege('anon', 'public.' || f, 'EXECUTE')::text, 'false');
    PERFORM t_expect('exposure: authenticated can execute ' || f, has_function_privilege('authenticated', 'public.' || f, 'EXECUTE')::text, 'true');
    PERFORM t_expect('exposure: PUBLIC has no EXECUTE on ' || f,
      (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = ('public.' || f)::regprocedure AND a.grantee = 0), '0');
  END LOOP;
  PERFORM t_expect('exposure: job_visibility_guard not executable by authenticated',
    has_function_privilege('authenticated', 'public.job_visibility_guard()', 'EXECUTE')::text, 'false');
  PERFORM t_expect('exposure: job_visibility_guard not executable by anon',
    has_function_privilege('anon', 'public.job_visibility_guard()', 'EXECUTE')::text, 'false');
  PERFORM t_expect('exposure: job_visibility_guard not executable by PUBLIC',
    (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a WHERE p.proname='job_visibility_guard' AND a.grantee = 0), '0');
  PERFORM t_expect('exposure: anon really gets 42501 calling lock_job_baseline',
    t_val('anon', NULL, 'SELECT lock_job_baseline(''b1000000-0000-0000-0000-0000000000a1''::uuid, ''x'')::text'), 'err:42501');
  PERFORM t_expect('exposure: anon really gets 42501 calling job_task_weight',
    t_val('anon', NULL, 'SELECT job_task_weight(false, NULL, NULL, NULL)::text'), 'err:42501');
  PERFORM t_expect('exposure: anon really gets 42501 calling job_schedule_status',
    t_val('anon', NULL, 'SELECT status FROM job_schedule_status(''b1000000-0000-0000-0000-0000000000a1''::uuid)'), 'err:42501');
  PERFORM t_expect('exposure: authenticated really gets 42501 calling job_visibility_guard',
    t_val('authenticated', '11111111-1111-1111-1111-111111111111', 'SELECT job_visibility_guard()::text'), 'err:42501');
END $$;

-- ===== 3. RLS matrix: job_phases (select, insert, update, delete) =====
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f2000000-0000-0000-0000-0000000000d1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',90,'disposable 1'),
 ('f2000000-0000-0000-0000-0000000000d2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',91,'disposable 2'),
 ('f2000000-0000-0000-0000-0000000000d3','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000a1',92,'disposable 3');
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  fin uuid := '13131313-1313-1313-1313-131313131313'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C2 text := 'c2000000-0000-0000-0000-000000000002'; JA text := 'b1000000-0000-0000-0000-0000000000a1';
  ins text := 'INSERT INTO job_phases (company_id, job_id, name) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000a1'',''new'')';
BEGIN
  PERFORM t_expect('phases sel viewer', t_count('authenticated', viewr, 'SELECT 1 FROM job_phases'), 'n:5');
  PERFORM t_expect('phases sel operations_tech', t_count('authenticated', ops, 'SELECT 1 FROM job_phases'), 'n:5');
  PERFORM t_expect('phases sel write-only role', t_count('authenticated', wrt, 'SELECT 1 FROM job_phases'), 'n:5');
  PERFORM t_expect('phases sel company_admin', t_count('authenticated', cadm, 'SELECT 1 FROM job_phases'), 'n:5');
  PERFORM t_expect('phases sel finance (company member without ops atoms, same as job_tasks)', t_count('authenticated', fin, 'SELECT 1 FROM job_phases'), 'n:5');
  PERFORM t_expect('phases sel other company sees only its own', t_count('authenticated', ops2, 'SELECT 1 FROM job_phases'), 'n:1');
  PERFORM t_expect('phases sel other company cannot see C1 rows', t_count('authenticated', ops2, 'SELECT 1 FROM job_phases WHERE job_id=''' || JA || ''''), 'n:0');
  PERFORM t_expect('phases sel multi-company super admin sees both', t_count('authenticated', sup, 'SELECT 1 FROM job_phases'), 'n:6');
  PERFORM t_expect('phases sel client-shaped user sees nothing', t_count('authenticated', clnt, 'SELECT 1 FROM job_phases'), 'n:0');
  PERFORM t_expect('phases sel anon sees nothing', t_count('anon', NULL, 'SELECT 1 FROM job_phases'), 'n:0');
  PERFORM t_expect('phases ins viewer denied', t_dml('authenticated', viewr, ins), 'err:42501');
  PERFORM t_expect('phases ins finance denied', t_dml('authenticated', fin, ins), 'err:42501');
  PERFORM t_expect('phases ins client-shaped denied', t_dml('authenticated', clnt, ins), 'err:42501');
  PERFORM t_expect('phases ins anon denied', t_dml('anon', NULL, ins), 'err:42501');
  PERFORM t_expect('phases ins other company denied', t_dml('authenticated', ops2, ins), 'err:42501');
  PERFORM t_expect('phases ins operations_tech into other company denied',
    t_dml('authenticated', ops, 'INSERT INTO job_phases (company_id, job_id, name) VALUES (''' || C2 || ''',''b2000000-0000-0000-0000-0000000000a2'',''x'')'), 'err:42501');
  PERFORM t_expect('phases ins operations_tech ok', t_dml('authenticated', ops, ins), 'rows:1');
  PERFORM t_expect('phases ins write-only role ok', t_dml('authenticated', wrt, ins), 'rows:1');
  PERFORM t_expect('phases ins company_admin ok', t_dml('authenticated', cadm, ins), 'rows:1');
END $$;

DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; ops2 uuid := '77777777-7777-7777-7777-777777777777';
  wrt uuid := '12121212-1212-1212-1212-121212121212'; fin uuid := '13131313-1313-1313-1313-131313131313';
  clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  upd text := 'UPDATE job_phases SET sort_order=11 WHERE id=''f2000000-0000-0000-0000-000000000001''';
  del text := 'DELETE FROM job_phases WHERE id=''f2000000-0000-0000-0000-0000000000d1''';
BEGIN
  PERFORM t_expect('phases upd viewer denied (0 rows)', t_dml('authenticated', viewr, upd), 'rows:0');
  PERFORM t_expect('phases upd finance denied', t_dml('authenticated', fin, upd), 'rows:0');
  PERFORM t_expect('phases upd other company denied', t_dml('authenticated', ops2, upd), 'rows:0');
  PERFORM t_expect('phases upd client-shaped denied', t_dml('authenticated', clnt, upd), 'rows:0');
  PERFORM t_expect('phases upd anon denied', t_dml('anon', NULL, upd), 'rows:0');
  PERFORM t_expect('phases upd operations_tech ok', t_dml('authenticated', ops, upd), 'rows:1');
  PERFORM t_expect('phases upd write-only ok', t_dml('authenticated', wrt, upd), 'rows:1');
  PERFORM t_expect('phases upd cannot move a row to another company (WITH CHECK)',
    t_dml('authenticated', ops, 'UPDATE job_phases SET company_id=''c2000000-0000-0000-0000-000000000002'' WHERE id=''f2000000-0000-0000-0000-000000000001'''), 'err:42501');
  PERFORM t_expect('phases del viewer denied', t_dml('authenticated', viewr, del), 'rows:0');
  PERFORM t_expect('phases del other company denied', t_dml('authenticated', ops2, del), 'rows:0');
  PERFORM t_expect('phases del anon denied', t_dml('anon', NULL, del), 'rows:0');
  PERFORM t_expect('phases del finance denied', t_dml('authenticated', fin, del), 'rows:0');
  PERFORM t_expect('phases del operations_tech ok', t_dml('authenticated', ops, del), 'rows:1');
  PERFORM t_expect('phases del write-only ok', t_dml('authenticated', wrt, replace(del, 'd1', 'd2')), 'rows:1');
  PERFORM t_expect('phases del company_admin ok', t_dml('authenticated', cadm, replace(del, 'd1', 'd3')), 'rows:1');
END $$;

-- ===== 4. RLS matrix: job_task_links =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; ops2 uuid := '77777777-7777-7777-7777-777777777777';
  wrt uuid := '12121212-1212-1212-1212-121212121212'; fin uuid := '13131313-1313-1313-1313-131313131313';
  clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  pre text := 'INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000a1'',';
  a1 text := '''f1000000-0000-0000-0000-000000000001''';
  a2 text := '''f1000000-0000-0000-0000-000000000002''';
  a3 text := '''f1000000-0000-0000-0000-000000000003''';
BEGIN
  PERFORM t_expect('links ins viewer denied', t_dml('authenticated', viewr, pre || a2 || ',' || a1 || ')'), 'err:42501');
  PERFORM t_expect('links ins finance denied', t_dml('authenticated', fin, pre || a2 || ',' || a1 || ')'), 'err:42501');
  PERFORM t_expect('links ins client-shaped denied (cannot even see the tasks: integrity trigger fires before RLS)', t_dml('authenticated', clnt, pre || a2 || ',' || a1 || ')'), 'err:23514');
  PERFORM t_expect('links ins anon denied (same)', t_dml('anon', NULL, pre || a2 || ',' || a1 || ')'), 'err:23514');
  PERFORM t_expect('links ins other company cannot link C1 tasks (denied)', t_dml('authenticated', ops2, pre || a2 || ',' || a1 || ')'), 'err:23514');
  PERFORM t_expect('links ins operations_tech ok', t_dml('authenticated', ops, pre || a2 || ',' || a1 || ')'), 'rows:1');
  PERFORM t_expect('links ins write-only ok', t_dml('authenticated', wrt, pre || a3 || ',' || a1 || ')'), 'rows:1');
  PERFORM t_expect('links ins company_admin ok', t_dml('authenticated', cadm, pre || a3 || ',' || a2 || ')'), 'rows:1');
  PERFORM t_expect('links sel viewer sees the 3 links', t_count('authenticated', viewr, 'SELECT 1 FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'n:3');
  PERFORM t_expect('links sel other company sees none', t_count('authenticated', ops2, 'SELECT 1 FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'n:0');
  PERFORM t_expect('links sel client-shaped sees none', t_count('authenticated', clnt, 'SELECT 1 FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'n:0');
  PERFORM t_expect('links sel anon sees none', t_count('anon', NULL, 'SELECT 1 FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'n:0');
  PERFORM t_expect('links upd viewer denied', t_dml('authenticated', viewr, 'UPDATE job_task_links SET lag_days=2 WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:0');
  PERFORM t_expect('links upd other company denied', t_dml('authenticated', ops2, 'UPDATE job_task_links SET lag_days=2 WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:0');
  PERFORM t_expect('links upd anon denied', t_dml('anon', NULL, 'UPDATE job_task_links SET lag_days=2 WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:0');
  PERFORM t_expect('links upd operations_tech ok (all 3 rows)', t_dml('authenticated', ops, 'UPDATE job_task_links SET lag_days=2 WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:3');
  PERFORM t_expect('links del viewer denied', t_dml('authenticated', viewr, 'DELETE FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:0');
  PERFORM t_expect('links del other company denied', t_dml('authenticated', ops2, 'DELETE FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:0');
  PERFORM t_expect('links del write-only ok (1 row)', t_dml('authenticated', wrt, 'DELETE FROM job_task_links WHERE task_id=' || a3 || ' AND predecessor_id=' || a2), 'rows:1');
  PERFORM t_expect('links del operations_tech ok (rest)', t_dml('authenticated', ops, 'DELETE FROM job_task_links WHERE job_id=''b1000000-0000-0000-0000-0000000000a1'''), 'rows:2');
END $$;

-- ===== 5. job_tasks (new columns) RLS: viewer read-only, writers write, cross-company invisible =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  t3 text := 'f1000000-0000-0000-0000-000000000003';
  upd text := 'UPDATE job_tasks SET weight=5 WHERE id=''f1000000-0000-0000-0000-000000000003''';
  ins text := 'INSERT INTO job_tasks (company_id, job_id, task_name, is_milestone, weight) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000a1'',''m'', true, 1)';
BEGIN
  PERFORM t_expect('tasks upd weight: viewer denied', t_dml('authenticated', viewr, upd), 'rows:0');
  PERFORM t_expect('tasks upd weight: other company denied', t_dml('authenticated', ops2, upd), 'rows:0');
  PERFORM t_expect('tasks upd weight: client-shaped denied', t_dml('authenticated', clnt, upd), 'rows:0');
  PERFORM t_expect('tasks upd weight: anon denied', t_dml('anon', NULL, upd), 'rows:0');
  PERFORM t_expect('tasks upd weight: operations_tech ok', t_dml('authenticated', ops, upd), 'rows:1');
  PERFORM t_expect('tasks upd is_critical/is_milestone: write-only ok', t_dml('authenticated', wrt, 'UPDATE job_tasks SET is_critical=true, is_milestone=true WHERE id=''' || t3 || ''''), 'rows:1');
  PERFORM t_expect('tasks upd phase_id: write-only ok', t_dml('authenticated', wrt, 'UPDATE job_tasks SET phase_id=''f2000000-0000-0000-0000-000000000002'' WHERE id=''' || t3 || ''''), 'rows:1');
  PERFORM t_expect('tasks ins new task with new columns: viewer denied', t_dml('authenticated', viewr, ins), 'err:42501');
  PERFORM t_expect('tasks ins new task with new columns: operations_tech ok', t_dml('authenticated', ops, ins), 'rows:1');
  PERFORM t_expect('tasks sel: other company sees only its own task',
    t_count('authenticated', ops2, 'SELECT 1 FROM job_tasks WHERE job_id IN (''b1000000-0000-0000-0000-0000000000a1'', ''b2000000-0000-0000-0000-0000000000a2'')'), 'n:1');
  -- ordinary progress edit by a writer is not broken by the new triggers, and it neither unpublishes nor audits
  PERFORM t_expect('tasks ordinary progress update by write-only role works',
    t_dml('authenticated', wrt, 'UPDATE job_tasks SET progress=40, assignee=''Sam'' WHERE id=''f1000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('tasks ordinary progress update by operations_tech works',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET progress=45 WHERE id=''f1000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('tasks ordinary updates wrote no audit row',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id='b1000000-0000-0000-0000-0000000000a1'), '0');
  PERFORM t_expect('tasks progress stored', (SELECT progress::text FROM job_tasks WHERE id='f1000000-0000-0000-0000-000000000001'), '45');
END $$;

-- ===== 6. constraints and the cycle guard (as postgres via SET ROLE so SQLSTATEs are returned) =====
CREATE FUNCTION pg_temp.lk(t text, p text) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L,%L,%L,%L)',
    'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000a1', t, p) $$;
CREATE FUNCTION pg_temp.tk(cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO job_tasks (company_id, job_id, %s) VALUES (%L,%L,%s)', cols,
    'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000a1', vals) $$;
DO $$
DECLARE
  a1 text := 'f1000000-0000-0000-0000-000000000001'; a2 text := 'f1000000-0000-0000-0000-000000000002'; a3 text := 'f1000000-0000-0000-0000-000000000003';
  b1 text := 'f1000000-0000-0000-0000-000000000009';
BEGIN
  PERFORM t_expect('con: self-link rejected (CHECK)', t_dml('postgres', NULL, pg_temp.lk(a1, a1)), 'err:23514');
  PERFORM t_expect('con: link A2<-A1 ok', t_dml('postgres', NULL, pg_temp.lk(a2, a1)), 'rows:1');
  PERFORM t_expect('con: duplicate link rejected (UNIQUE)', t_dml('postgres', NULL, pg_temp.lk(a2, a1)), 'err:23505');
  PERFORM t_expect('con: A1<-A2 closes a 2-cycle, rejected', t_dml('postgres', NULL, pg_temp.lk(a1, a2)), 'err:23514');
  PERFORM t_expect('con: A3<-A2 ok', t_dml('postgres', NULL, pg_temp.lk(a3, a2)), 'rows:1');
  PERFORM t_expect('con: A1<-A3 closes a 3-cycle, rejected', t_dml('postgres', NULL, pg_temp.lk(a1, a3)), 'err:23514');
  PERFORM t_expect('con: updating a link to create a cycle is rejected',
    t_dml('postgres', NULL, format('UPDATE job_task_links SET task_id=%L, predecessor_id=%L WHERE task_id=%L AND predecessor_id=%L', a1, a3, a2, a1)), 'err:23514');
  PERFORM t_expect('con: updating only lag_days of a link is fine',
    t_dml('postgres', NULL, format('UPDATE job_task_links SET lag_days=3 WHERE task_id=%L', a2)), 'rows:1');
  PERFORM t_expect('con: link to a task of another job/company rejected', t_dml('postgres', NULL, pg_temp.lk(a3, b1)), 'err:23514');
  PERFORM t_expect('con: link row with the wrong company rejected',
    t_dml('postgres', NULL, format('INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id) VALUES (%L,%L,%L,%L)',
      'c2000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-0000000000a1', a3, a1)), 'err:23514');
  PERFORM t_expect('con: link to a missing task rejected', t_dml('postgres', NULL, pg_temp.lk(a3, 'aaaaaaaa-0000-0000-0000-000000000000')), 'err:23514');
  PERFORM t_expect('con: lag_days 366 rejected', t_dml('postgres', NULL, format('UPDATE job_task_links SET lag_days=366 WHERE task_id=%L', a2)), 'err:23514');
  PERFORM t_expect('con: lag_days -31 rejected', t_dml('postgres', NULL, format('UPDATE job_task_links SET lag_days=-31 WHERE task_id=%L', a2)), 'err:23514');
  PERFORM t_expect('con: lag_days 365 accepted', t_dml('postgres', NULL, format('UPDATE job_task_links SET lag_days=365 WHERE task_id=%L', a2)), 'rows:1');
  PERFORM t_expect('con: lag_days -30 accepted', t_dml('postgres', NULL, format('UPDATE job_task_links SET lag_days=-30 WHERE task_id=%L', a2)), 'rows:1');
  PERFORM t_expect('con: milestone with start<>end rejected',
    t_dml('postgres', NULL, pg_temp.tk('task_name, is_milestone, start_date, end_date', '''m'', true, ''2026-05-01'', ''2026-05-02''')), 'err:23514');
  PERFORM t_expect('con: milestone with start=end accepted',
    t_dml('postgres', NULL, pg_temp.tk('task_name, is_milestone, start_date, end_date', '''m'', true, ''2026-05-01'', ''2026-05-01''')), 'rows:1');
  PERFORM t_expect('con: milestone with one date only accepted',
    t_dml('postgres', NULL, pg_temp.tk('task_name, is_milestone, start_date', '''m'', true, ''2026-05-01''')), 'rows:1');
  PERFORM t_expect('con: non-milestone with start<>end accepted',
    t_dml('postgres', NULL, pg_temp.tk('task_name, start_date, end_date', '''t'', ''2026-05-01'', ''2026-05-02''')), 'rows:1');
  PERFORM t_expect('con: updating a task into a milestone with start<>end rejected',
    t_dml('postgres', NULL, format('UPDATE job_tasks SET is_milestone=true WHERE id=%L', a1)), 'err:23514');
  PERFORM t_expect('con: weight < 0 rejected', t_dml('postgres', NULL, pg_temp.tk('task_name, weight', '''w'', -0.01')), 'err:23514');
  PERFORM t_expect('con: weight 0 accepted', t_dml('postgres', NULL, pg_temp.tk('task_name, weight', '''w'', 0')), 'rows:1');
  PERFORM t_expect('con: weight NULL accepted', t_dml('postgres', NULL, pg_temp.tk('task_name, weight', '''w'', NULL')), 'rows:1');
  PERFORM t_expect('con: weight 999999.99 exceeds numeric(8,2)', t_dml('postgres', NULL, pg_temp.tk('task_name, weight', '''w'', 1000000')), 'err:22003');
END $$;

CREATE FUNCTION pg_temp.ph(cols text, vals text) RETURNS text LANGUAGE sql AS $$
  SELECT format('INSERT INTO job_phases (company_id, job_id, %s) VALUES (%L,%L,%s)', cols,
    'c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000a1', vals) $$;
DO $$
BEGIN
  PERFORM t_expect('con: bad hex colour rejected (no hash)', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', ''ff0000''')), 'err:23514');
  PERFORM t_expect('con: bad hex colour rejected (3 digits)', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', ''#fff''')), 'err:23514');
  PERFORM t_expect('con: bad hex colour rejected (non-hex digit)', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', ''#gg0000''')), 'err:23514');
  PERFORM t_expect('con: bad hex colour rejected (7 digits)', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', ''#ff00000''')), 'err:23514');
  PERFORM t_expect('con: good hex colour accepted (mixed case)', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', ''#aB09fF''')), 'rows:1');
  PERFORM t_expect('con: NULL colour accepted', t_dml('postgres', NULL, pg_temp.ph('name, colour', '''p'', NULL')), 'rows:1');
  PERFORM t_expect('con: empty phase name rejected', t_dml('postgres', NULL, pg_temp.ph('name', '''''')), 'err:23514');
  PERFORM t_expect('con: 81-char phase name rejected', t_dml('postgres', NULL, pg_temp.ph('name', quote_literal(repeat('x', 81)))), 'err:23514');
  PERFORM t_expect('con: 80-char phase name accepted', t_dml('postgres', NULL, pg_temp.ph('name', quote_literal(repeat('x', 80)))), 'rows:1');
  PERFORM t_expect('con: phase without name column value (NULL) rejected', t_dml('postgres', NULL, pg_temp.ph('sort_order', '1')), 'err:23502');
  PERFORM t_expect('con: baseline_end before baseline_start rejected',
    t_dml('postgres', NULL, 'DO $b$ BEGIN PERFORM set_config(''app.baseline_rpc'',''on'',true); UPDATE job_tasks SET baseline_start=''2026-05-10'', baseline_end=''2026-05-01'' WHERE id=''f1000000-0000-0000-0000-000000000001''; END $b$'), 'err:23514');
  -- referential behaviour
  PERFORM t_expect('fk: phase_id references job_phases (bad id rejected)',
    t_dml('postgres', NULL, 'UPDATE job_tasks SET phase_id=''aaaaaaaa-0000-0000-0000-000000000000'' WHERE id=''f1000000-0000-0000-0000-000000000001'''), 'err:23503');
  PERFORM t_expect('fk: deleting a phase keeps its tasks (phase_id set NULL)',
    t_dml('postgres', NULL, 'DELETE FROM job_phases WHERE id=''f2000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('fk: task A1 survived with phase_id NULL',
    (SELECT coalesce(phase_id::text, 'null') FROM job_tasks WHERE id='f1000000-0000-0000-0000-000000000001'), 'null');
  PERFORM t_expect('fk: deleting a task removes its links (cascade)',
    t_dml('postgres', NULL, 'DELETE FROM job_tasks WHERE id=''f1000000-0000-0000-0000-000000000003'''), 'rows:1');
  PERFORM t_expect('fk: links of the deleted task are gone',
    (SELECT count(*)::text FROM job_task_links WHERE task_id='f1000000-0000-0000-0000-000000000003' OR predecessor_id='f1000000-0000-0000-0000-000000000003'), '0');
  PERFORM t_expect('fk: other links of the job remain',
    (SELECT count(*)::text FROM job_task_links WHERE job_id='b1000000-0000-0000-0000-0000000000a1'), '1');
  PERFORM t_expect('fk: deleting a job cascades phases, tasks and links',
    t_dml('postgres', NULL, 'DELETE FROM jobs WHERE id=''b1000000-0000-0000-0000-0000000000a4'''), 'rows:1');
END $$;

-- ===== 7. baseline: direct writes fail for everyone, lock_job_baseline is the only path =====
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000c1','c1000000-0000-0000-0000-000000000001','WO-C01','Open'),
 ('b1000000-0000-0000-0000-0000000000c2','c1000000-0000-0000-0000-000000000001','WO-C02','Open'),
 ('b1000000-0000-0000-0000-0000000000c3','c1000000-0000-0000-0000-000000000001','WO-C03','Open'),
 ('b1000000-0000-0000-0000-0000000000c4','c1000000-0000-0000-0000-000000000001','WO-C04','Open');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress) VALUES
 ('f3000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c1',1,'C1','2026-06-01','2026-06-10',0),
 ('f3000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c1',2,'C2','2026-06-11','2026-06-20',0),
 ('f3000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c1',3,'C3 undated',NULL,NULL,0),
 ('f3000000-0000-0000-0000-000000000011','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c2',1,'D1','2026-06-01','2026-06-10',0),
 ('f3000000-0000-0000-0000-000000000021','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c3',1,'E1','2026-06-01','2026-06-10',0),
 ('f3000000-0000-0000-0000-000000000031','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000c4',1,'F1',NULL,NULL,0);
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  upd text := 'UPDATE job_tasks SET baseline_start=''2026-01-01'', baseline_end=''2026-01-31'' WHERE id=''f3000000-0000-0000-0000-000000000001''';
  lk text := 'UPDATE job_tasks SET baseline_locked_at=now() WHERE id=''f3000000-0000-0000-0000-000000000001''';
  via_guc text := 'DO $b$ BEGIN PERFORM set_config(''app.baseline_rpc'',''on'',true); ' || 'UPDATE job_tasks SET baseline_start=''2026-01-01'' WHERE id=''f3000000-0000-0000-0000-000000000001''; END $b$';
BEGIN
  PERFORM t_expect('base: direct baseline UPDATE fails for operations_tech', t_dml('authenticated', ops, upd), 'err:P0001');
  PERFORM t_expect('base: direct baseline UPDATE fails for company_admin', t_dml('authenticated', cadm, upd), 'err:P0001');
  PERFORM t_expect('base: direct baseline UPDATE fails for super_admin', t_dml('authenticated', sup, upd), 'err:P0001');
  PERFORM t_expect('base: direct baseline UPDATE fails for write-only role', t_dml('authenticated', wrt, upd), 'err:P0001');
  PERFORM t_expect('base: direct baseline UPDATE: viewer gets nothing (0 rows)', t_dml('authenticated', viewr, upd), 'rows:0');
  PERFORM t_expect('base: direct baseline UPDATE: other company gets nothing', t_dml('authenticated', ops2, upd), 'rows:0');
  PERFORM t_expect('base: direct baseline UPDATE fails even for postgres', t_dml('postgres', NULL, upd), 'err:P0001');
  PERFORM t_expect('base: baseline_locked_at alone cannot be set directly', t_dml('authenticated', ops, lk), 'err:P0001');
  PERFORM t_expect('base: setting app.baseline_rpc=on as operations_tech does NOT open the guard', t_dml('authenticated', ops, via_guc), 'err:P0001');
  PERFORM t_expect('base: setting app.baseline_rpc=on as company_admin does NOT open the guard', t_dml('authenticated', cadm, via_guc), 'err:P0001');
  PERFORM t_expect('base: INSERT with baseline dates fails for operations_tech',
    t_dml('authenticated', ops, 'INSERT INTO job_tasks (company_id, job_id, task_name, baseline_start) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000c1'',''x'',''2026-01-01'')'), 'err:P0001');
  PERFORM t_expect('base: INSERT with baseline_locked_at fails even for postgres',
    t_dml('postgres', NULL, 'INSERT INTO job_tasks (company_id, job_id, task_name, baseline_locked_at) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000c1'',''x'', now())'), 'err:P0001');
  PERFORM t_expect('base: INSERT without baseline columns is unaffected',
    t_dml('authenticated', ops, 'INSERT INTO job_tasks (company_id, job_id, task_name) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000c1'',''plain'')'), 'rows:1');
  PERFORM t_expect('base: baseline columns still empty after all attempts',
    (SELECT count(*)::text FROM job_tasks WHERE job_id='b1000000-0000-0000-0000-0000000000c1' AND (baseline_start IS NOT NULL OR baseline_end IS NOT NULL OR baseline_locked_at IS NOT NULL)), '0');
  PERFORM t_expect('base: owner seeding with the setting on is allowed (used by the fixture runner)',
    t_dml('postgres', NULL, 'DO $b$ BEGIN PERFORM set_config(''app.baseline_rpc'',''on'',true); UPDATE job_tasks SET baseline_start=''2026-06-02'', baseline_end=''2026-06-09'' WHERE id=''f3000000-0000-0000-0000-000000000031''; END $b$'), 'rows:0');
  PERFORM t_expect('base: ... and it took effect',
    (SELECT baseline_start::text FROM job_tasks WHERE id='f3000000-0000-0000-0000-000000000031'), '2026-06-02');
  UPDATE job_tasks SET task_name = task_name WHERE id='f3000000-0000-0000-0000-000000000031';
  PERFORM t_expect('base: touching an already-baselined row without changing baseline passes',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET progress=1 WHERE id=''f3000000-0000-0000-0000-000000000031'''), 'rows:1');
END $$;

-- ===== 8. lock_job_baseline: permission, membership, reason rule, audit =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  fin uuid := '13131313-1313-1313-1313-131313131313'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  j1 text := 'b1000000-0000-0000-0000-0000000000c1'; no_perm text := 'permission denied: ops:work-orders:approve required';
  n text;
BEGIN
  PERFORM t_expect('lock: viewer refused', t_msg('authenticated', viewr, format('SELECT lock_job_baseline(%L)', j1)), no_perm);
  PERFORM t_expect('lock: write-only role (no approve) refused', t_msg('authenticated', wrt, format('SELECT lock_job_baseline(%L)', j1)), no_perm);
  PERFORM t_expect('lock: finance role refused', t_msg('authenticated', fin, format('SELECT lock_job_baseline(%L)', j1)), no_perm);
  PERFORM t_expect('lock: client-shaped user refused', t_msg('authenticated', clnt, format('SELECT lock_job_baseline(%L)', j1)), no_perm);
  PERFORM t_expect('lock: approve holder of ANOTHER company gets job not found', t_msg('authenticated', ops2, format('SELECT lock_job_baseline(%L)', j1)), 'job not found');
  PERFORM t_expect('lock: unknown job', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L)', 'aaaaaaaa-0000-0000-0000-000000000000')), 'job not found');
  PERFORM t_expect('lock: NULL job', t_msg('authenticated', ops, 'SELECT lock_job_baseline(NULL)'), 'job not found');
  PERFORM t_expect('lock: refusals wrote no audit row and no baseline',
    (SELECT (SELECT count(*) FROM job_audit_log WHERE job_id=j1::uuid)::text || ':' ||
            (SELECT count(*) FROM job_tasks WHERE job_id=j1::uuid AND baseline_locked_at IS NOT NULL)::text), '0:0');
  -- first lock by operations_tech: 2 dated tasks baselined, the undated one is not
  PERFORM t_expect('lock: first lock returns the number of dated tasks', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L)', j1)), 'ok:2');
  PERFORM t_expect('lock: baseline copied from current dates',
    (SELECT string_agg(baseline_start::text || '..' || baseline_end::text, ',' ORDER BY sort_order) FROM job_tasks WHERE job_id=j1::uuid AND baseline_locked_at IS NOT NULL), '2026-06-01..2026-06-10,2026-06-11..2026-06-20');
  PERFORM t_expect('lock: undated task stays without baseline',
    (SELECT (baseline_start IS NULL AND baseline_locked_at IS NULL)::text FROM job_tasks WHERE id='f3000000-0000-0000-0000-000000000003'), 'true');
  PERFORM t_expect('lock: exactly one baseline_locked audit row',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id=j1::uuid AND action_type='baseline_locked'), '1');
  PERFORM t_expect('lock: audit username is erp_users.full_name, user_id is the caller',
    (SELECT username || '|' || user_id::text || '|' || job_no FROM job_audit_log WHERE job_id=j1::uuid AND action_type='baseline_locked'), 'ops C1|' || ops::text || '|WO-C01');
  PERFORM t_expect('lock: audit metadata (tasks=2, reason null)',
    (SELECT (metadata->>'tasks') || '|' || coalesce(metadata->>'reason', 'null') FROM job_audit_log WHERE job_id=j1::uuid AND action_type='baseline_locked'), '2|null');
  -- re-baseline needs a reason
  PERFORM t_expect('lock: second call without reason refused', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L)', j1)), 're-baseline requires a reason');
  PERFORM t_expect('lock: second call with empty reason refused', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L, %L)', j1, '')), 're-baseline requires a reason');
  PERFORM t_expect('lock: second call with blank reason refused', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L, %L)', j1, '   ')), 're-baseline requires a reason');
  PERFORM t_expect('lock: refused re-baselines wrote nothing', (SELECT count(*)::text FROM job_audit_log WHERE job_id=j1::uuid), '1');
  PERFORM t_expect('lock: re-baseline by write-only role refused even with a reason', t_msg('authenticated', wrt, format('SELECT lock_job_baseline(%L, %L)', j1, 'x')), no_perm);
  UPDATE job_tasks SET end_date = '2026-06-25' WHERE id='f3000000-0000-0000-0000-000000000002';
  PERFORM t_expect('lock: re-baseline with reason by company_admin', t_msg('authenticated', cadm, format('SELECT lock_job_baseline(%L, %L)', j1, 'client moved delivery')), 'ok:2');
  PERFORM t_expect('lock: re-baseline took the new dates',
    (SELECT baseline_end::text FROM job_tasks WHERE id='f3000000-0000-0000-0000-000000000002'), '2026-06-25');
  PERFORM t_expect('lock: exactly one baseline_reset row with reason, caller name and description',
    (SELECT count(*)::text || '|' || min(metadata->>'reason') || '|' || min(username) || '|' || min(description)
       FROM job_audit_log WHERE job_id=j1::uuid AND action_type='baseline_reset'), '1|client moved delivery|admin C1|Schedule re-baselined: client moved delivery');
  PERFORM t_expect('lock: still exactly one baseline_locked row', (SELECT count(*)::text FROM job_audit_log WHERE job_id=j1::uuid AND action_type='baseline_locked'), '1');
  PERFORM t_expect('lock: super_admin may lock another job', t_msg('authenticated', sup, format('SELECT lock_job_baseline(%L, %L)', 'b1000000-0000-0000-0000-0000000000c2', 'first lock with a reason')), 'ok:1');
  PERFORM t_expect('lock: a first lock with a reason is still baseline_locked and records the reason',
    (SELECT action_type || '|' || (metadata->>'reason') || '|' || username FROM job_audit_log WHERE job_id='b1000000-0000-0000-0000-0000000000c2'), 'baseline_locked|first lock with a reason|super');
  PERFORM t_expect('lock: job with one dated task returns 1', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L)', 'b1000000-0000-0000-0000-0000000000c3')), 'ok:1');
  PERFORM t_expect('lock: job without dated tasks returns 0 and still audits once', t_msg('authenticated', ops, format('SELECT lock_job_baseline(%L)', 'b1000000-0000-0000-0000-0000000000c4')), 'ok:0');
  PERFORM t_expect('lock: ... and a job with nothing locked is still on its first lock', (SELECT count(*)::text FROM job_audit_log WHERE job_id='b1000000-0000-0000-0000-0000000000c4' AND action_type='baseline_locked'), '1');
END $$;

-- ===== 8b. after a lock the guard is closed again (the setting does not leak, and API roles never satisfy the owner check) =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; cadm uuid := '33333333-3333-3333-3333-333333333333';
  blk text := 'DO $b$ BEGIN PERFORM lock_job_baseline(''b1000000-0000-0000-0000-0000000000c2'', ''again''); BEGIN '
    || 'UPDATE job_tasks SET baseline_start=''2000-01-01'' WHERE id=''f3000000-0000-0000-0000-000000000011''; '
    || 'RAISE EXCEPTION ''NOT BLOCKED'' USING ERRCODE=''XX999''; EXCEPTION WHEN raise_exception THEN NULL; END; END $b$';
BEGIN
  PERFORM t_expect('lock: direct baseline write right after lock_job_baseline in the same transaction is still blocked (operations_tech)',
    t_dml('authenticated', ops, blk), 'rows:0');
  PERFORM t_expect('lock: ... and for company_admin', t_dml('authenticated', cadm, replace(blk, 'again', 'again2')), 'rows:0');
  PERFORM t_expect('lock: the setting is switched off after the RPC',
    t_val('authenticated', ops, 'SELECT lock_job_baseline(''b1000000-0000-0000-0000-0000000000c2'', ''check'')::text || ''/'' || current_setting(''app.baseline_rpc'', true)'), '1/off');
  PERFORM t_expect('lock: baseline of D1 was not touched by the blocked write',
    (SELECT baseline_start::text FROM job_tasks WHERE id='f3000000-0000-0000-0000-000000000011'), '2026-06-01');
END $$;

-- ===== 9. publish guard (X5/X19): fixtures. Seeding as postgres is exempt, so visible rows can be created directly. =====
SELECT set_config('request.jwt.claim.sub', '', true);   -- seeding is a plain SQL session: no JWT identity left over from earlier t_* calls
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000d1','c1000000-0000-0000-0000-000000000001','WO-D01','Open');
INSERT INTO job_phases (id, company_id, job_id, sort_order, name, client_visible) VALUES
 ('f4000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',1,'PA hidden',false),
 ('f4000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',2,'PB visible',true),
 ('f4000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',3,'PC visible',true);
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, client_visible) VALUES
 ('f5000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',1,'TA hidden','2026-07-01','2026-07-10',false),
 ('f5000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',2,'TB visible','2026-07-01','2026-07-10',true),
 ('f5000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',3,'TC visible','2026-07-01','2026-07-10',true),
 ('f5000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',4,'TD visible','2026-07-01','2026-07-10',true),
 ('f5000000-0000-0000-0000-0000000000a5','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',5,'TE visible','2026-07-01','2026-07-10',true),
 ('f5000000-0000-0000-0000-0000000000a6','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',6,'TF visible','2026-07-01','2026-07-10',true),
 ('f5000000-0000-0000-0000-0000000000a7','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',7,'TG hidden','2026-07-01','2026-07-10',false);
CREATE FUNCTION pg_temp.audn(p_row text, p_reason text) RETURNS text LANGUAGE sql AS $$
  SELECT count(*)::text FROM job_audit_log WHERE action_type='visibility_changed' AND metadata->>'row_id'=p_row AND metadata->>'reason'=p_reason $$;
DO $$
BEGIN
  PERFORM t_expect('pub: postgres seeding of visible rows is exempt and audited as publish (3 phases/tasks sampled)',
    pg_temp.audn('f5000000-0000-0000-0000-0000000000a2', 'publish') || pg_temp.audn('f4000000-0000-0000-0000-0000000000a2', 'publish'), '11');
  PERFORM t_expect('pub: seeded audit row has no username (no session identity)',
    (SELECT coalesce(username, 'null') FROM job_audit_log WHERE metadata->>'row_id'='f5000000-0000-0000-0000-0000000000a2'), 'null');
  PERFORM t_expect('pub: new rows default to hidden',
    (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a1'), 'false');
END $$;

DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  wrt uuid := '12121212-1212-1212-1212-121212121212';
  pub_t text := 'UPDATE job_tasks SET client_visible=true WHERE id=''f5000000-0000-0000-0000-0000000000a1''';
  pub_p text := 'UPDATE job_phases SET client_visible=true WHERE id=''f4000000-0000-0000-0000-0000000000a1''';
  ins_t text := 'INSERT INTO job_tasks (company_id, job_id, task_name, client_visible) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000d1'',''new'', true)';
  ins_p text := 'INSERT INTO job_phases (company_id, job_id, name, client_visible) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000d1'',''new'', true)';
BEGIN
  PERFORM t_expect('pub: write-only role cannot publish a task', t_dml_api('authenticated', wrt, pub_t), 'err:P0001');
  PERFORM t_expect('pub: write-only role cannot publish a phase', t_dml_api('authenticated', wrt, pub_p), 'err:P0001');
  PERFORM t_expect('pub: write-only role cannot INSERT a visible task', t_dml_api('authenticated', wrt, ins_t), 'err:P0001');
  PERFORM t_expect('pub: write-only role cannot INSERT a visible phase', t_dml_api('authenticated', wrt, ins_p), 'err:P0001');
  PERFORM t_expect('pub: viewer cannot INSERT a visible task', t_dml_api('authenticated', viewr, ins_t), 'err:P0001');
  PERFORM t_expect('pub: viewer publish reaches no row', t_dml_api('authenticated', viewr, pub_t), 'rows:0');
  PERFORM t_expect('pub: refused publishes changed nothing',
    (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a1') || (SELECT client_visible::text FROM job_phases WHERE id='f4000000-0000-0000-0000-0000000000a1'), 'falsefalse');
  PERFORM t_expect('pub: write-only role can INSERT a hidden task (default)',
    t_dml_api('authenticated', wrt, replace(ins_t, ', true)', ', false)')), 'rows:1');
  -- unpublish is always allowed to a writer
  PERFORM t_expect('pub: write-only role can unpublish a task', t_dml_api('authenticated', wrt, 'UPDATE job_tasks SET client_visible=false WHERE id=''f5000000-0000-0000-0000-0000000000a2'''), 'rows:1');
  PERFORM t_expect('pub: unpublish audited once (reason unpublish, to=false, from=true, username)',
    (SELECT count(*)::text || '|' || min(metadata->>'to') || '|' || min(metadata->>'from') || '|' || min(username) || '|' || min(metadata->>'table')
       FROM job_audit_log WHERE metadata->>'row_id'='f5000000-0000-0000-0000-0000000000a2' AND metadata->>'reason'='unpublish'), '1|false|true|writer C1|job_tasks');
  PERFORM t_expect('pub: write-only role can unpublish a phase', t_dml_api('authenticated', wrt, 'UPDATE job_phases SET client_visible=false WHERE id=''f4000000-0000-0000-0000-0000000000a2'''), 'rows:1');
  -- approve holders publish
  PERFORM t_expect('pub: operations_tech publishes a task', t_dml_api('authenticated', ops, pub_t), 'rows:1');
  PERFORM t_expect('pub: task is now visible', (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a1'), 'true');
  PERFORM t_expect('pub: exactly one publish audit row with table/row_id/to/username/job_no',
    (SELECT count(*)::text || '|' || min(metadata->>'table') || '|' || min(metadata->>'to') || '|' || min(metadata->>'from') || '|' || min(username)
        || '|' || min(job_no) || '|' || min(description) || '|' || min(user_id::text)
       FROM job_audit_log WHERE metadata->>'row_id'='f5000000-0000-0000-0000-0000000000a1' AND action_type='visibility_changed'),
    '1|job_tasks|true|false|ops C1|WO-D01|Published to client|' || ops::text);
  PERFORM t_expect('pub: operations_tech publishes a phase', t_dml_api('authenticated', ops, pub_p), 'rows:1');
  PERFORM t_expect('pub: phase publish audited with table job_phases',
    (SELECT count(*)::text || '|' || min(metadata->>'table') FROM job_audit_log WHERE metadata->>'row_id'='f4000000-0000-0000-0000-0000000000a1'), '1|job_phases');
  PERFORM t_expect('pub: company_admin re-publishes a task', t_dml_api('authenticated', cadm, 'UPDATE job_tasks SET client_visible=true WHERE id=''f5000000-0000-0000-0000-0000000000a2'''), 'rows:1');
  PERFORM t_expect('pub: super_admin publishes a task', t_dml_api('authenticated', sup, 'UPDATE job_tasks SET client_visible=true WHERE id=''f5000000-0000-0000-0000-0000000000a7'''), 'rows:1');
  PERFORM t_expect('pub: operations_tech INSERT of a visible task works and is audited',
    t_dml_api('authenticated', ops, ins_t || ' RETURNING id'), 'rows:1');
  PERFORM t_expect('pub: operations_tech INSERT of a visible phase works',
    t_dml_api('authenticated', ops, ins_p), 'rows:1');
  PERFORM t_expect('pub: the INSERTed visible task has a publish audit row with its real row_id (id default applied)',
    (SELECT count(*)::text FROM job_audit_log a JOIN job_tasks t ON t.id::text = a.metadata->>'row_id'
      WHERE t.task_name='new' AND t.client_visible AND a.metadata->>'reason'='publish' AND a.username='ops C1'), '1');
END $$;

-- ===== 9b. wording edits auto-unpublish; dates/progress edits do not =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; wrt uuid := '12121212-1212-1212-1212-121212121212';
BEGIN
  -- TC (visible task): a write-only user edits the wording
  PERFORM t_expect('wording: write-only role edits task_name of a visible task',
    t_dml_api('authenticated', wrt, 'UPDATE job_tasks SET task_name=''TC renamed'' WHERE id=''f5000000-0000-0000-0000-0000000000a3'''), 'rows:1');
  PERFORM t_expect('wording: the task is now hidden (same statement)',
    (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a3'), 'false');
  PERFORM t_expect('wording: one wording_edited audit row (to=false, from=true, username)',
    (SELECT count(*)::text || '|' || min(metadata->>'to') || '|' || min(metadata->>'from') || '|' || min(username) || '|' || min(description)
       FROM job_audit_log WHERE metadata->>'row_id'='f5000000-0000-0000-0000-0000000000a3' AND metadata->>'reason'='wording_edited'),
    '1|false|true|writer C1|Auto-unpublished after wording edit');
  -- PC (visible phase) renamed by operations_tech
  PERFORM t_expect('wording: operations_tech renames a visible phase',
    t_dml_api('authenticated', ops, 'UPDATE job_phases SET name=''PC renamed'' WHERE id=''f4000000-0000-0000-0000-0000000000a3'''), 'rows:1');
  PERFORM t_expect('wording: the phase is now hidden',
    (SELECT client_visible::text FROM job_phases WHERE id='f4000000-0000-0000-0000-0000000000a3'), 'false');
  PERFORM t_expect('wording: phase wording_edited audited with table job_phases',
    (SELECT count(*)::text || '|' || min(metadata->>'table') FROM job_audit_log
      WHERE metadata->>'row_id'='f4000000-0000-0000-0000-0000000000a3' AND metadata->>'reason'='wording_edited'), '1|job_phases');
  -- TD (visible): dates, progress, assignee, weight, flags, phase move, sort order do NOT unpublish
  PERFORM t_expect('wording: dates/progress/assignee/weight/flags/sort edits are not wording',
    t_dml_api('authenticated', ops, 'UPDATE job_tasks SET start_date=''2026-07-02'', end_date=''2026-07-12'', progress=55, assignee=''Z'', weight=3, is_critical=true, sort_order=99, phase_id=''f4000000-0000-0000-0000-0000000000a1'' WHERE id=''f5000000-0000-0000-0000-0000000000a4'''), 'rows:1');
  PERFORM t_expect('wording: ... the task stays visible',
    (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a4'), 'true');
  PERFORM t_expect('wording: ... and no unpublish/wording audit row exists for it',
    pg_temp.audn('f5000000-0000-0000-0000-0000000000a4', 'wording_edited') || pg_temp.audn('f5000000-0000-0000-0000-0000000000a4', 'unpublish'), '00');
  -- a phase edit other than name (colour, sort_order) does not unpublish
  PERFORM t_expect('wording: phase colour/sort_order edit keeps a visible phase visible',
    t_dml_api('authenticated', ops, 'UPDATE job_phases SET colour=''#112233'', sort_order=7 WHERE id=''f4000000-0000-0000-0000-0000000000a1'''), 'rows:1');
  PERFORM t_expect('wording: ... still visible', (SELECT client_visible::text FROM job_phases WHERE id='f4000000-0000-0000-0000-0000000000a1'), 'true');
  -- TE: writing the same name is not an edit
  PERFORM t_expect('wording: setting task_name to its current value is not an edit',
    t_dml_api('authenticated', ops, 'UPDATE job_tasks SET task_name=task_name, progress=10 WHERE id=''f5000000-0000-0000-0000-0000000000a5'''), 'rows:1');
  PERFORM t_expect('wording: ... stays visible', (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a5'), 'true');
  -- TF: an approve holder who edits the name AND keeps client_visible=true still gets auto-unpublished (rule 2)
  PERFORM t_expect('wording: approve holder edits name and re-sends client_visible=true',
    t_dml_api('authenticated', ops, 'UPDATE job_tasks SET task_name=''TF edited'', client_visible=true WHERE id=''f5000000-0000-0000-0000-0000000000a6'''), 'rows:1');
  PERFORM t_expect('wording: ... is still auto-unpublished',
    (SELECT client_visible::text FROM job_tasks WHERE id='f5000000-0000-0000-0000-0000000000a6') || pg_temp.audn('f5000000-0000-0000-0000-0000000000a6', 'wording_edited'), 'false1');
  -- a hidden row that is edited produces no audit
  PERFORM t_expect('wording: editing the name of a hidden row writes no audit row',
    t_dml_api('authenticated', wrt, 'UPDATE job_tasks SET task_name=''hidden renamed'' WHERE id=''f5000000-0000-0000-0000-0000000000a3''') ||
    (SELECT count(*)::text FROM job_audit_log WHERE metadata->>'row_id'='f5000000-0000-0000-0000-0000000000a3'), 'rows:12');
END $$;

-- ===== 9c. X19 exemption: by session_user NAME, unreachable through a PostgREST-like session =====
CREATE ROLE supabase_admin SUPERUSER NOLOGIN;
CREATE ROLE other_superuser SUPERUSER NOLOGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  ins text := 'INSERT INTO job_tasks (company_id, job_id, task_name, client_visible) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000d1'',''%s'', true)';
  as_su text := 'DO $b$ BEGIN SET LOCAL SESSION AUTHORIZATION %s; %s; RESET SESSION AUTHORIZATION; END $b$';
BEGIN
  PERFORM t_expect('exempt: the API-like session really has session_user authenticator', t_api_ident(), 'authenticator/authenticated');
  PERFORM t_expect('exempt: session_user postgres inserting client_visible=true passes (migration/seed style)',
    t_dml('postgres', NULL, format(ins, 'ex-pg')), 'rows:1');
  PERFORM t_expect('exempt: ... and it is audited as a publish',
    (SELECT count(*)::text FROM job_audit_log a JOIN job_tasks t ON t.id::text = a.metadata->>'row_id' WHERE t.task_name='ex-pg' AND a.metadata->>'reason'='publish'), '1');
  PERFORM t_expect('exempt: session_user supabase_admin inserting client_visible=true passes',
    t_dml('postgres', NULL, format(as_su, 'supabase_admin', format(ins, 'ex-sa'))), 'rows:0');
  PERFORM t_expect('exempt: ... the row exists and is visible',
    (SELECT client_visible::text FROM job_tasks WHERE task_name='ex-sa'), 'true');
  PERFORM t_expect('exempt: any other superuser session is NOT exempt (by name, not by power)',
    t_dml('postgres', NULL, format(as_su, 'other_superuser', format(ins, 'ex-other'))), 'err:P0001');
  PERFORM t_expect('exempt: the same insert through the API-like session fails for the write-only role',
    t_dml_api('authenticated', wrt, format(ins, 'ex-api-w')), 'err:P0001');
  PERFORM t_expect('exempt: ... and for service_role-less anon', t_dml_api('anon', NULL, format(ins, 'ex-api-anon')), 'err:P0001');
  PERFORM t_expect('exempt: ... but works through the API for an approve holder',
    t_dml_api('authenticated', ops, format(ins, 'ex-api-ops')), 'rows:1');
  PERFORM t_expect('exempt: no row was created by the refused API inserts',
    (SELECT count(*)::text FROM job_tasks WHERE task_name IN ('ex-api-w','ex-api-anon','ex-other')), '0');
  PERFORM t_expect('exempt: exemption also covers the publish UPDATE path for postgres',
    t_dml('postgres', NULL, 'UPDATE job_tasks SET client_visible=true WHERE id=''f5000000-0000-0000-0000-0000000000a3'''), 'rows:1');
END $$;

-- ===== 10. job_task_client_visible (X22): 5-case truth table + RLS scoping =====
SELECT set_config('request.jwt.claim.sub', '', true);
INSERT INTO job_phases (id, company_id, job_id, name, client_visible) VALUES
 ('f6000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','vis phase',true),
 ('f6000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','hidden phase',false);
INSERT INTO job_tasks (id, company_id, job_id, task_name, phase_id, client_visible) VALUES
 ('f7000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','vis task in hidden phase','f6000000-0000-0000-0000-0000000000a2',true),
 ('f7000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','vis task no phase',NULL,true),
 ('f7000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','vis task in vis phase','f6000000-0000-0000-0000-0000000000a1',true),
 ('f7000000-0000-0000-0000-0000000000a4','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','hidden task in vis phase','f6000000-0000-0000-0000-0000000000a1',false);
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; ops2 uuid := '77777777-7777-7777-7777-777777777777';
BEGIN
  PERFORM t_expect('vis: visible task in an invisible phase is false', job_task_client_visible('f7000000-0000-0000-0000-0000000000a1')::text, 'false');
  PERFORM t_expect('vis: visible task with no phase is true', job_task_client_visible('f7000000-0000-0000-0000-0000000000a2')::text, 'true');
  PERFORM t_expect('vis: visible task in a visible phase is true', job_task_client_visible('f7000000-0000-0000-0000-0000000000a3')::text, 'true');
  PERFORM t_expect('vis: invisible task in a visible phase is false', job_task_client_visible('f7000000-0000-0000-0000-0000000000a4')::text, 'false');
  PERFORM t_expect('vis: unknown id is false (never NULL)', job_task_client_visible('aaaaaaaa-0000-0000-0000-000000000000')::text, 'false');
  PERFORM t_expect('vis: NULL id is false (never NULL)', job_task_client_visible(NULL)::text, 'false');
  PERFORM t_expect('vis: as staff (RLS) the same answer', t_val('authenticated', ops, 'SELECT job_task_client_visible(''f7000000-0000-0000-0000-0000000000a3'')::text'), 'true');
  PERFORM t_expect('vis: another company cannot see the row, so the answer is false', t_val('authenticated', ops2, 'SELECT job_task_client_visible(''f7000000-0000-0000-0000-0000000000a3'')::text'), 'false');
  PERFORM t_expect('vis: client-shaped user gets false', t_val('authenticated', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'SELECT job_task_client_visible(''f7000000-0000-0000-0000-0000000000a3'')::text'), 'false');
END $$;

-- ===== 11. job_task_weight / job_task_planned_pct (X1/X20) =====
DO $$
DECLARE d date := '2026-03-10';
BEGIN
  PERFORM t_expect('weight: milestone with an explicit weight is 0', job_task_weight(true, 7, '2026-03-01', '2026-03-01')::text, '0');
  PERFORM t_expect('weight: milestone with NULL weight is 0', job_task_weight(true, NULL, NULL, NULL)::text, '0');
  PERFORM t_expect('weight: NULL weight = duration in days (inclusive)', job_task_weight(false, NULL, '2026-03-01', '2026-03-10')::text, '10');
  PERFORM t_expect('weight: one-day task = 1', job_task_weight(false, NULL, '2026-03-05', '2026-03-05')::text, '1');
  PERFORM t_expect('weight: undated task = 1', job_task_weight(false, NULL, NULL, NULL)::text, '1');
  PERFORM t_expect('weight: half-dated task = 1', job_task_weight(false, NULL, '2026-03-01', NULL)::text, '1');
  PERFORM t_expect('weight: explicit weight wins over duration', job_task_weight(false, 2.5, '2026-03-01', '2026-03-10')::text, '2.5');
  PERFORM t_expect('weight: explicit 0 stays 0', job_task_weight(false, 0, '2026-03-01', '2026-03-10')::text, '0');
  PERFORM t_expect('weight: inverted dates (never stored) floor at 1', job_task_weight(false, NULL, '2026-03-10', '2026-03-01')::text, '1');
  PERFORM t_expect('planned: day before start is 0', job_task_planned_pct(NULL, NULL, '2026-03-11', '2026-03-20', d)::text, '0');
  PERFORM t_expect('planned: first day counts (1 of 10 days = 10)', round(job_task_planned_pct(NULL, NULL, '2026-03-10', '2026-03-19', d), 4)::text, '10.0000');
  PERFORM t_expect('planned: midpoint 5 of 10 days = 50', round(job_task_planned_pct(NULL, NULL, '2026-03-06', '2026-03-15', d), 4)::text, '50.0000');
  PERFORM t_expect('planned: last day is 100', round(job_task_planned_pct(NULL, NULL, '2026-03-01', '2026-03-10', d), 4)::text, '100.0000');
  PERFORM t_expect('planned: clamps above 100 after the end', job_task_planned_pct(NULL, NULL, '2026-03-01', '2026-03-05', d)::text, '100');
  PERFORM t_expect('planned: clamps below 0 before the start', job_task_planned_pct(NULL, NULL, '2026-04-01', '2026-04-05', d)::text, '0');
  PERFORM t_expect('planned: baseline dates win over current dates', round(job_task_planned_pct('2026-03-10', '2026-03-10', '2026-03-20', '2026-03-30', d), 4)::text, '100.0000');
  PERFORM t_expect('planned: falls back to current dates when no baseline', round(job_task_planned_pct(NULL, NULL, '2026-03-10', '2026-03-10', d), 4)::text, '100.0000');
  PERFORM t_expect('planned: no dates at all = 0', job_task_planned_pct(NULL, NULL, NULL, NULL, d)::text, '0');
  PERFORM t_expect('planned: start only = 0', job_task_planned_pct(NULL, NULL, '2026-03-01', NULL, d)::text, '0');
  PERFORM t_expect('planned: baseline end with current start mixes per field (documented COALESCE per field)',
    round(job_task_planned_pct(NULL, '2026-03-19', '2026-03-10', '2026-03-12', d), 2)::text, '10.00');
  PERFORM t_expect('planned: a NULL day gives 0 (GREATEST ignores NULL)', coalesce(job_task_planned_pct(NULL, NULL, '2026-03-01', '2026-03-10', NULL)::text, 'null'), '0');
  PERFORM t_expect('planned: 7 of 8 days rounds in numeric', round(job_task_planned_pct(NULL, NULL, '2026-03-04', '2026-03-11', d), 2)::text, '87.50');
END $$;

-- ===== 12. updated_at is server-owned (X16) =====
SELECT set_config('request.jwt.claim.sub', '', true);
INSERT INTO job_tasks (id, company_id, job_id, task_name, updated_at) VALUES
 ('f8000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','upd task','2000-01-01');
INSERT INTO job_phases (id, company_id, job_id, name, updated_at) VALUES
 ('f8000000-0000-0000-0000-0000000000b1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1','upd phase','2000-01-01');
INSERT INTO job_task_links (id, company_id, job_id, task_id, predecessor_id, updated_at) VALUES
 ('f8000000-0000-0000-0000-0000000000c1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000d1',
  'f5000000-0000-0000-0000-0000000000a2','f5000000-0000-0000-0000-0000000000a1','2000-01-01');
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; wrt uuid := '12121212-1212-1212-1212-121212121212';
BEGIN
  PERFORM t_expect('updated_at: a PATCH carrying an older updated_at still moves job_tasks forward',
    t_dml('authenticated', ops, 'UPDATE job_tasks SET progress=5, updated_at=''1999-01-01'' WHERE id=''f8000000-0000-0000-0000-0000000000a1'''), 'rows:1');
  PERFORM t_expect('updated_at: job_tasks.updated_at = now()', (SELECT (updated_at = now())::text FROM job_tasks WHERE id='f8000000-0000-0000-0000-0000000000a1'), 'true');
  PERFORM t_expect('updated_at: a PATCH carrying an older updated_at still moves job_phases forward',
    t_dml('authenticated', wrt, 'UPDATE job_phases SET sort_order=2, updated_at=''1999-01-01'' WHERE id=''f8000000-0000-0000-0000-0000000000b1'''), 'rows:1');
  PERFORM t_expect('updated_at: job_phases.updated_at = now()', (SELECT (updated_at = now())::text FROM job_phases WHERE id='f8000000-0000-0000-0000-0000000000b1'), 'true');
  PERFORM t_expect('updated_at: a PATCH carrying an older updated_at still moves job_task_links forward',
    t_dml('authenticated', ops, 'UPDATE job_task_links SET lag_days=1, updated_at=''1999-01-01'' WHERE id=''f8000000-0000-0000-0000-0000000000c1'''), 'rows:1');
  PERFORM t_expect('updated_at: job_task_links.updated_at = now()', (SELECT (updated_at = now())::text FROM job_task_links WHERE id='f8000000-0000-0000-0000-0000000000c1'), 'true');
  PERFORM t_expect('updated_at: a future-dated PATCH value is accepted by RLS', t_dml('authenticated', ops, 'UPDATE job_tasks SET updated_at=''2999-01-01'' WHERE id=''f8000000-0000-0000-0000-0000000000a1'''), 'rows:1');
  PERFORM t_expect('updated_at: ... but overwritten with now()', (SELECT (updated_at = now())::text FROM job_tasks WHERE id='f8000000-0000-0000-0000-0000000000a1'), 'true');
END $$;

-- ===== 13. job_schedule_status contract (X21) =====
SELECT set_config('request.jwt.claim.sub', '', true);
CREATE FUNCTION pg_temp.st(j text, d date) RETURNS text LANGUAGE sql AS $$
  SELECT count(*)::text || ':' || coalesce(string_agg(status || '|' || coalesce(forecast_end::text, 'null') || '|' || coalesce(slip_days::text, 'null'), ','), '-')
    FROM job_schedule_status(j::uuid, d) $$;
CREATE FUNCTION pg_temp.mkjob(n text, st text, due date) RETURNS text LANGUAGE sql AS $$
  INSERT INTO jobs (id, company_id, job_no, status, due_date)
  VALUES (('b1000000-0000-0000-0000-0000000e' || lpad(n, 4, '0'))::uuid, 'c1000000-0000-0000-0000-000000000001', 'WO-S' || n, st, due)
  RETURNING id::text $$;
CREATE FUNCTION pg_temp.mktask(j text, ord int, s date, e date, p int, ms boolean, w numeric) RETURNS void LANGUAGE sql AS $$
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, start_date, end_date, progress, is_milestone, weight)
  VALUES ('c1000000-0000-0000-0000-000000000001', j::uuid, ord, 't' || ord, s, e, p, ms, w) $$;
DO $$
DECLARE j text;
BEGIN
  j := pg_temp.mkjob('1', 'Open', NULL);
  PERFORM t_expect('status: no tasks, no baseline, no due date -> one row On track, NULL forecast and slip', pg_temp.st(j, '2026-03-01'), '1:On track|null|null');
  j := pg_temp.mkjob('2', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-10', 0, false, NULL);
  PERFORM t_expect('status: tasks but neither baseline nor due date -> slip NULL, forecast set', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-11|null');
  j := pg_temp.mkjob('3', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, NULL, NULL, 0, false, NULL);
  PERFORM t_expect('status: only unscheduled tasks -> forecast NULL', pg_temp.st(j, '2026-03-01'), '1:On track|null|null');
  j := pg_temp.mkjob('4', 'Open', '2026-03-11');
  PERFORM t_expect('status: due date but no tasks -> slip NULL (no forecast)', pg_temp.st(j, '2026-03-01'), '1:On track|null|null');
  FOR j IN SELECT pg_temp.mkjob(x.n, x.s, '2026-03-11') FROM (VALUES ('5','Completed'),('6','Invoiced'),('7','Closed'),('8','On Hold')) x(n, s) LOOP
    PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-10', 0, false, NULL);
  END LOOP;
  PERFORM t_expect('status: Completed -> Complete (one row)', pg_temp.st('b1000000-0000-0000-0000-0000000e0005', '2026-03-01'), '1:Complete|2026-03-11|0');
  PERFORM t_expect('status: Invoiced -> Complete', pg_temp.st('b1000000-0000-0000-0000-0000000e0006', '2026-03-01'), '1:Complete|2026-03-11|0');
  PERFORM t_expect('status: Closed -> Complete', pg_temp.st('b1000000-0000-0000-0000-0000000e0007', '2026-03-01'), '1:Complete|2026-03-11|0');
  PERFORM t_expect('status: On Hold -> On hold (forecast still returned)', pg_temp.st('b1000000-0000-0000-0000-0000000e0008', '2026-03-01'), '1:On hold|2026-03-11|0');
  UPDATE jobs SET status = 'Completed', due_date = '2026-01-01' WHERE id = 'b1000000-0000-0000-0000-0000000e0005';
  PERFORM t_expect('status: Complete wins over a hugely late slip', pg_temp.st('b1000000-0000-0000-0000-0000000e0005', '2026-03-01'), '1:Complete|2026-03-11|69');
  PERFORM t_expect('status: unknown job id -> zero rows', pg_temp.st('aaaaaaaa-0000-0000-0000-000000000000', '2026-03-01'), '0:-');
END $$;

-- slip boundaries: task 03-01..03-10, 0%, today 03-01 -> forecast 03-11
DO $$
DECLARE j text; r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('10','2026-03-20','On track','-9'), ('11','2026-03-11','On track','0'), ('12','2026-03-10','At risk','1'),
                                 ('13','2026-03-06','At risk','5'), ('14','2026-03-05','Late','6')) v(n, due, want, slip) LOOP
    j := pg_temp.mkjob(r.n, 'Open', r.due::date);
    PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-10', 0, false, NULL);
    PERFORM t_expect('status: slip ' || r.slip || ' days -> ' || r.want, pg_temp.st(j, '2026-03-01'), '1:' || r.want || '|2026-03-11|' || r.slip);
  END LOOP;
  -- overdue incomplete milestone: lateCrit (overdue by 5 days = At risk, by 6 = Late); a completed one is ignored
  j := pg_temp.mkjob('20', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-15', '2026-03-15', 0, true, NULL);
  PERFORM t_expect('status: milestone overdue by 5 days -> At risk', pg_temp.st(j, '2026-03-20'), '1:At risk|2026-03-20|null');
  j := pg_temp.mkjob('21', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-14', '2026-03-14', 0, true, NULL);
  PERFORM t_expect('status: milestone overdue by 6 days -> Late', pg_temp.st(j, '2026-03-20'), '1:Late|2026-03-20|null');
  j := pg_temp.mkjob('22', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-01', 100, true, NULL);
  PERFORM t_expect('status: completed milestone in the past is fine -> On track', pg_temp.st(j, '2026-03-20'), '1:On track|2026-03-01|null');
  j := pg_temp.mkjob('23', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-14', '2026-03-14', 0, true, NULL);
  PERFORM t_expect('status: the same milestone not yet overdue (today = its date) -> On track', pg_temp.st(j, '2026-03-14'), '1:On track|2026-03-14|null');
  -- overdue incomplete ordinary task on the critical path
  j := pg_temp.mkjob('24', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-10', 50, false, NULL);
  PERFORM t_expect('status: incomplete critical task overdue by 10 days -> Late', pg_temp.st(j, '2026-03-20'), '1:Late|2026-03-06|null');
END $$;

-- precision (X20): the gap uses the 2 dp values. weights 199 and 1 over identical baselines, planned exactly 50.00 on 2026-01-05
CREATE FUNCTION pg_temp.mkbl(n text, p1 int, p2 int, lock_it boolean) RETURNS text LANGUAGE plpgsql AS $$
DECLARE j text;
BEGIN
  j := pg_temp.mkjob(n, 'Open', NULL);
  PERFORM set_config('app.baseline_rpc', 'on', true);
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, start_date, end_date, baseline_start, baseline_end, baseline_locked_at, progress, weight)
  VALUES ('c1000000-0000-0000-0000-000000000001', j::uuid, 1, 'heavy', '2026-01-01', '2026-01-10', CASE WHEN lock_it THEN '2026-01-01'::date END, CASE WHEN lock_it THEN '2026-01-10'::date END, CASE WHEN lock_it THEN now() END, p1, 199),
         ('c1000000-0000-0000-0000-000000000001', j::uuid, 2, 'light', '2026-01-01', '2026-01-10', CASE WHEN lock_it THEN '2026-01-01'::date END, CASE WHEN lock_it THEN '2026-01-10'::date END, CASE WHEN lock_it THEN now() END, p2, 1);
  PERFORM set_config('app.baseline_rpc', 'off', true);
  RETURN j;
END $$;
DO $$
BEGIN
  PERFORM t_expect('precision: overall 39.995 rounds half-up to 40.00, gap exactly -10.00 -> On track (not At risk)',
    pg_temp.st(pg_temp.mkbl('30', 40, 39, true), '2026-01-05'), '1:On track|2026-01-08|-2');
  PERFORM t_expect('precision: overall 39.99 -> gap -10.01 -> At risk',
    pg_temp.st(pg_temp.mkbl('31', 40, 38, true), '2026-01-05'), '1:At risk|2026-01-08|-2');
  PERFORM t_expect('precision: gap -10.00 exactly (40 vs 50) -> On track', pg_temp.st(pg_temp.mkbl('32', 40, 40, true), '2026-01-05'), '1:On track|2026-01-07|-3');
  PERFORM t_expect('precision: gap -11 -> At risk', pg_temp.st(pg_temp.mkbl('33', 39, 39, true), '2026-01-05'), '1:At risk|2026-01-08|-2');
  PERFORM t_expect('precision: gap +50 ahead of plan -> On track', pg_temp.st(pg_temp.mkbl('34', 100, 100, true), '2026-01-05'), '1:On track|2026-01-10|0');
  PERFORM t_expect('precision: no locked baseline -> the gap rule is not evaluated even when far behind',
    pg_temp.st(pg_temp.mkbl('35', 0, 0, false), '2026-01-05'), '1:On track|2026-01-15|null');
END $$;

-- multiple predecessors and lag: C waits for the later of A and B
CREATE FUNCTION pg_temp.mklink(t text, p text, lag int) RETURNS void LANGUAGE sql AS $$
  INSERT INTO job_task_links (company_id, job_id, task_id, predecessor_id, lag_days)
  SELECT company_id, job_id, id, p::uuid, lag FROM job_tasks WHERE id = t::uuid $$;
CREATE FUNCTION pg_temp.tid(j text, ord int) RETURNS text LANGUAGE sql AS $$
  SELECT id::text FROM job_tasks WHERE job_id = j::uuid AND sort_order = ord $$;
DO $$
DECLARE j text;
BEGIN
  j := pg_temp.mkjob('40', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-05', 0, false, NULL);
  PERFORM pg_temp.mktask(j, 2, '2026-03-01', '2026-03-10', 0, false, NULL);
  PERFORM pg_temp.mktask(j, 3, '2026-03-11', '2026-03-15', 0, false, NULL);
  PERFORM t_expect('status: unlinked tasks all start today -> forecast = longest task', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-11|null');
  PERFORM pg_temp.mklink(pg_temp.tid(j, 3), pg_temp.tid(j, 1), 0);
  PERFORM t_expect('status: C after the short predecessor only', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-11|null');
  PERFORM pg_temp.mklink(pg_temp.tid(j, 3), pg_temp.tid(j, 2), 0);
  PERFORM t_expect('status: C after BOTH predecessors starts after the later one (03-11 + 5)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-16|null');
  UPDATE job_task_links SET lag_days = 2 WHERE predecessor_id = pg_temp.tid(j, 2)::uuid;
  PERFORM t_expect('status: lag 2 days on the later link pushes the forecast to 03-18', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-18|null');
  UPDATE jobs SET due_date = '2026-03-10' WHERE id = j::uuid;
  PERFORM t_expect('status: due 03-10 vs forecast 03-18 -> slip 8 -> Late', pg_temp.st(j, '2026-03-01'), '1:Late|2026-03-18|8');
  -- a linked undated task takes part (1 day, starts today); a done undated task stays out
  j := pg_temp.mkjob('41', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-05', 0, false, NULL);
  PERFORM pg_temp.mktask(j, 2, NULL, NULL, 0, false, NULL);
  PERFORM pg_temp.mklink(pg_temp.tid(j, 2), pg_temp.tid(j, 1), 0);
  PERFORM t_expect('status: undated task linked after a dated one is scheduled (1 day after 03-06)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-07|null');
  -- a finished predecessor is not moved and its actual end drives the successor
  j := pg_temp.mkjob('42', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-02-01', '2026-02-10', 100, false, NULL);
  PERFORM pg_temp.mktask(j, 2, '2026-03-05', '2026-03-09', 0, false, NULL);
  PERFORM pg_temp.mklink(pg_temp.tid(j, 2), pg_temp.tid(j, 1), 0);
  PERFORM t_expect('status: done predecessor keeps its actual end; successor starts today (03-01 + 5)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-06|null');
END $$;

-- ===== 14. who can call job_schedule_status and what they get =====
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; ops2 uuid := '77777777-7777-7777-7777-777777777777';
  viewr uuid := '22222222-2222-2222-2222-222222222222'; fin uuid := '13131313-1313-1313-1313-131313131313';
  clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc'; gone uuid := '66666666-6666-6666-6666-666666666666';
  q text := 'SELECT 1 FROM job_schedule_status(''b1000000-0000-0000-0000-0000000e0002''::uuid, ''2026-03-01'')';
BEGIN
  PERFORM t_expect('caller: operations_tech gets exactly one row', t_count('authenticated', ops, q), 'n:1');
  PERFORM t_expect('caller: viewer gets exactly one row', t_count('authenticated', viewr, q), 'n:1');
  PERFORM t_expect('caller: a member without work-order atoms gets zero rows (jobs RLS)', t_count('authenticated', fin, q), 'n:0');
  PERFORM t_expect('caller: a JWT with no company membership gets zero rows', t_count('authenticated', clnt, q), 'n:0');
  PERFORM t_expect('caller: inactive staff gets zero rows', t_count('authenticated', gone, q), 'n:0');
  PERFORM t_expect('caller: another company gets zero rows (invisible job)', t_count('authenticated', ops2, q), 'n:0');
  PERFORM t_expect('caller: anon cannot call it', t_count('anon', NULL, q), 'err:42501');
  PERFORM t_expect('caller: default p_today works (business-local date)',
    t_val('authenticated', ops, 'SELECT status FROM job_schedule_status(''b1000000-0000-0000-0000-0000000e0001''::uuid)'), 'On track');
  PERFORM t_expect('caller: status never NULL and always one of the five labels (all jobs, as postgres)',
    (SELECT count(*)::text FROM jobs j, LATERAL job_schedule_status(j.id, '2026-03-01') s
      WHERE s.status IS NULL OR s.status NOT IN ('On track','At risk','Late','Complete','On hold')), '0');
  PERFORM t_expect('caller: every job yields exactly one row',
    (SELECT count(*)::text FROM jobs j WHERE (SELECT count(*) FROM job_schedule_status(j.id, '2026-03-01')) <> 1), '0');
END $$;

-- ===== 15. backfill of links from depends_on (legacy data seeded before the migration) =====
DO $$
BEGIN
  PERFORM t_expect('backfill: chain T2<-T1 and T3<-T2 became links',
    (SELECT count(*)::text FROM job_task_links WHERE (task_id, predecessor_id) IN
      (('d1000000-0000-0000-0000-000000000002'::uuid,'d1000000-0000-0000-0000-000000000001'::uuid),
       ('d1000000-0000-0000-0000-000000000003'::uuid,'d1000000-0000-0000-0000-000000000002'::uuid))), '2');
  PERFORM t_expect('backfill: links carry the task company and job and lag 0',
    (SELECT count(*)::text FROM job_task_links l JOIN job_tasks t ON t.id = l.task_id
      WHERE l.job_id = t.job_id AND l.company_id = t.company_id AND l.lag_days = 0 AND t.id IN
       ('d1000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000003')), '2');
  PERFORM t_expect('backfill: a legacy depends_on cycle keeps exactly one of its two links',
    (SELECT count(*)::text FROM job_task_links WHERE task_id IN ('d1000000-0000-0000-0000-000000000004','d1000000-0000-0000-0000-000000000005')), '1');
  PERFORM t_expect('backfill: a self-referencing depends_on is skipped',
    (SELECT count(*)::text FROM job_task_links WHERE task_id='d1000000-0000-0000-0000-000000000006'), '0');
  PERFORM t_expect('backfill: a cross-job depends_on is skipped',
    (SELECT count(*)::text FROM job_task_links WHERE task_id='d1000000-0000-0000-0000-000000000007'), '0');
  PERFORM t_expect('backfill: depends_on itself is untouched (all 6 legacy values still set)',
    (SELECT count(*)::text FROM job_tasks WHERE id::text LIKE 'd1000000-%' AND depends_on IS NOT NULL), '6');
  PERFORM t_expect('backfill: exactly 3 links exist for the legacy jobs',
    (SELECT count(*)::text FROM job_task_links WHERE job_id IN ('b1000000-0000-0000-0000-000000000008','b1000000-0000-0000-0000-000000000009')), '3');
  PERFORM t_expect('backfill: legacy tasks got default new columns',
    (SELECT count(*)::text FROM job_tasks WHERE id::text LIKE 'd1000000-%' AND NOT client_visible AND NOT is_milestone AND NOT is_critical AND weight IS NULL AND baseline_locked_at IS NULL), '7');
END $$;

-- ===== 16. extra guards: single-column baseline writes, link whose task is in another job, planned rounding, ceil, future start =====
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; c text;
  t text := 'f3000000-0000-0000-0000-000000000031';
BEGIN
  FOREACH c IN ARRAY ARRAY['baseline_start=''2026-06-03''', 'baseline_end=''2026-06-30''', 'baseline_locked_at=now()'] LOOP
    PERFORM t_expect('base: single-column direct write refused: ' || c, t_dml('authenticated', ops, 'UPDATE job_tasks SET ' || c || ' WHERE id=''' || t || ''''), 'err:P0001');
  END LOOP;
  PERFORM t_expect('con: link whose TASK sits in another job is rejected',
    t_dml('postgres', NULL, pg_temp.lk('d1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001')), 'err:23514');
  PERFORM t_expect('con: link whose PREDECESSOR sits in another job is rejected',
    t_dml('postgres', NULL, pg_temp.lk('f1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002')), 'err:23514');
END $$;
DO $$
DECLARE j text;
BEGIN
  -- planned % keeps 2 dp inside the status: planned 33.33 vs overall 23 -> gap -10.33 -> At risk (a 0 dp planned of 33 would give -10)
  j := pg_temp.mkjob('50', 'Open', NULL);
  PERFORM set_config('app.baseline_rpc', 'on', true);
  INSERT INTO job_tasks (company_id, job_id, sort_order, task_name, start_date, end_date, baseline_start, baseline_end, baseline_locked_at, progress, weight)
  VALUES ('c1000000-0000-0000-0000-000000000001', j::uuid, 1, 'p', '2025-12-20', '2026-01-03', '2026-01-01', '2026-01-03', now(), 23, 1);
  PERFORM set_config('app.baseline_rpc', 'off', true);
  PERFORM t_expect('precision: planned 33.33 is kept to 2 dp in the gap (gap -10.33 -> At risk)', pg_temp.st(j, '2026-01-01'), '1:At risk|2026-01-01|-2');
  -- remaining work rounds UP: 10 days at 33% -> 6.7 -> 7 days
  j := pg_temp.mkjob('51', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-01', '2026-03-10', 33, false, NULL);
  PERFORM t_expect('status: remaining work is rounded up (6.7 -> 7 days)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-08|null');
  -- an unstarted task is planned from today, not from its (future) start date
  j := pg_temp.mkjob('52', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-03-20', '2026-03-25', 0, false, NULL);
  PERFORM t_expect('status: unstarted task starts today in the forecast (6 days from 03-01)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-03-07|null');
  -- a started task keeps its actual start
  j := pg_temp.mkjob('53', 'Open', NULL);
  PERFORM pg_temp.mktask(j, 1, '2026-02-20', '2026-03-01', 50, false, NULL);
  PERFORM t_expect('status: started task keeps its start (02-20 + ceil(10*0.5)=5 days)', pg_temp.st(j, '2026-03-01'), '1:On track|2026-02-25|null');
  -- slack: a short overdue task OFF the critical path does not make the job late
  j := pg_temp.mkjob('54', 'Open', '2026-06-30');
  PERFORM pg_temp.mktask(j, 1, '2026-03-20', '2026-04-10', 0, false, NULL);
  PERFORM pg_temp.mktask(j, 2, '2026-03-01', '2026-03-05', 0, false, NULL);
  PERFORM t_expect('status: overdue short task has MORE slack than the long task, so it is not critical -> On track', pg_temp.st(j, '2026-03-20'), '1:On track|2026-04-11|-80');
END $$;

-- ===== 17. the guard contract for Phases B/C: wording list with several columns and a domain atom =====
CREATE TABLE public.t_guard_probe (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), job_id uuid, title text, body text, note text,
  client_visible boolean NOT NULL DEFAULT false);
CREATE TRIGGER t_guard_probe_visibility BEFORE INSERT OR UPDATE ON public.t_guard_probe
  FOR EACH ROW EXECUTE FUNCTION job_visibility_guard('title,body', 'quality:docs:issue');
INSERT INTO erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000020', 'doc_issuer', '{"ops:work-orders:read":true,"ops:work-orders:write":true,"quality:docs:issue":true}');
INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES ('e0000000-0000-0000-0000-000000000020', '20202020-2020-2020-2020-202020202020', 'issuer C1', true);
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000020', 'c1000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000020');
INSERT INTO t_guard_probe (id, job_id, title, body, note, client_visible) VALUES
 ('f9000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-0000000000d1', 't', 'b', 'n', false),
 ('f9000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-0000000000d1', 't', 'b', 'n', true),
 ('f9000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-0000000000d1', 't', 'b', 'n', true),
 ('f9000000-0000-0000-0000-000000000004', 'b1000000-0000-0000-0000-0000000000d1', 't', 'b', 'n', true);
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  iss uuid := '20202020-2020-2020-2020-202020202020';
  pub text := 'UPDATE t_guard_probe SET client_visible=true WHERE id=''f9000000-0000-0000-0000-000000000001''';
BEGIN
  PERFORM t_expect('probe: a role WITHOUT approve and without the domain atom cannot publish', t_dml_api('authenticated', wrt, pub), 'err:P0001');
  PERFORM t_expect('probe: the refusal names the domain atom',
    (SELECT t_msg_api('authenticated', wrt, pub)), 'permission denied: publishing to the client needs ops:work-orders:approve or quality:docs:issue');
  PERFORM t_expect('probe: a role with the domain atom (no approve) CAN publish', t_dml_api('authenticated', iss, pub), 'rows:1');
  PERFORM t_expect('probe: an approve holder can publish too (approve OR atom)',
    t_dml_api('authenticated', ops, 'UPDATE t_guard_probe SET client_visible=true WHERE id=''f9000000-0000-0000-0000-000000000001'' AND NOT client_visible') , 'rows:0');
  PERFORM t_expect('probe: first listed wording column (title) auto-unpublishes',
    t_dml_api('authenticated', wrt, 'UPDATE t_guard_probe SET title=''t2'' WHERE id=''f9000000-0000-0000-0000-000000000002''') ||
    (SELECT client_visible::text FROM t_guard_probe WHERE id='f9000000-0000-0000-0000-000000000003'), 'rows:1true');
  PERFORM t_expect('probe: ... the edited row is hidden', (SELECT client_visible::text FROM t_guard_probe WHERE id='f9000000-0000-0000-0000-000000000002'), 'false');
  PERFORM t_expect('probe: second listed wording column (body) auto-unpublishes',
    t_dml_api('authenticated', wrt, 'UPDATE t_guard_probe SET body=''b2'' WHERE id=''f9000000-0000-0000-0000-000000000003'''), 'rows:1');
  PERFORM t_expect('probe: ... hidden', (SELECT client_visible::text FROM t_guard_probe WHERE id='f9000000-0000-0000-0000-000000000003'), 'false');
  PERFORM t_expect('probe: an unlisted column (note) does not unpublish',
    t_dml_api('authenticated', wrt, 'UPDATE t_guard_probe SET note=''n2'' WHERE id=''f9000000-0000-0000-0000-000000000004'''), 'rows:1');
  PERFORM t_expect('probe: ... still visible', (SELECT client_visible::text FROM t_guard_probe WHERE id='f9000000-0000-0000-0000-000000000004'), 'true');
  PERFORM t_expect('probe: audit rows record the probe table name',
    (SELECT count(*)::text FROM job_audit_log WHERE metadata->>'table' = 't_guard_probe' AND metadata->>'reason' = 'wording_edited'), '2');
END $$;

-- ===== 18. the exemption follows session_user, not the effective role =====
DO $$
DECLARE wrt uuid := '12121212-1212-1212-1212-121212121212';
BEGIN
  PERFORM t_expect('exempt: a postgres session that SET ROLEs to the write-only user is still exempt (session_user postgres)',
    t_dml('authenticated', wrt, 'INSERT INTO job_tasks (company_id, job_id, task_name, client_visible) VALUES (''c1000000-0000-0000-0000-000000000001'',''b1000000-0000-0000-0000-0000000000d1'',''ex-setrole'', true)'), 'rows:1');
END $$;
ROLLBACK;
