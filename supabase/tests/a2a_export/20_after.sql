-- AFTER: prepare_schedule_export behaviour. One transaction (rolled back) then one small committed marker block.
-- Identities (from the D0a + phase_a_sql stubs): ops = operations_tech C1 (read/write/approve), viewr = viewer C1 (read only),
--   wrt = write+read without approve C1, fin = finance (no ops atoms) C1, ops2 = operations_tech C2, sup = super_admin C1+C2,
--   gone = inactive user with an ops role in C1, clnt = client-shaped (no erp_users row), mix = viewer in C1 + operations_tech in C2.
BEGIN;

-- ===== fixtures (as postgres) =====
INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-0000000000e1','e1e1e1e1-e1e1-e1e1-e1e1-e1e1e1e1e1e1','mixed roles', true);
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-0000000000e1','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002'),
 ('e0000000-0000-0000-0000-0000000000e1','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001');
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001');

INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000e1','c1000000-0000-0000-0000-000000000001','WO-E01','Open'),  -- all NULL, tied sort orders
 ('b1000000-0000-0000-0000-0000000000e2','c1000000-0000-0000-0000-000000000001','WO-E02','Open'),  -- pre-existing uids with a gap
 ('b1000000-0000-0000-0000-0000000000e3','c1000000-0000-0000-0000-000000000001','WO-E03','Open'),  -- empty job
 ('b1000000-0000-0000-0000-0000000000e4','c1000000-0000-0000-0000-000000000001','WO-E04','Open'),  -- only a task holds a uid
 ('b1000000-0000-0000-0000-0000000000e5','c1000000-0000-0000-0000-000000000001','WO-E05','Open'),  -- reader-then-nothing
 ('b1000000-0000-0000-0000-0000000000e6','c1000000-0000-0000-0000-000000000001','WO-E06','Open'),  -- second job: uid space is per job
 ('b2000000-0000-0000-0000-0000000000e9','c2000000-0000-0000-0000-000000000002','WO-E09','Open');  -- other company
-- E1: phases Pa(20) Pb(10) Pc(10, ties with Pb: id order); tasks T1(5) T2(1) T3(1, ties with T2: id order) T4(3)
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f6000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',20,'Pa'),
 ('f6000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',10,'Pc'),
 ('f6000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',10,'Pb');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES
 ('f7000000-0000-0000-0000-000000000031','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',5,'T1'),
 ('f7000000-0000-0000-0000-000000000033','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',1,'T2'),
 ('f7000000-0000-0000-0000-000000000032','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',1,'T3'),
 ('f7000000-0000-0000-0000-000000000034','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e1',3,'T4');
-- E2: phase uid 10, task uids 2 and 9, plus one NULL phase and one NULL task. Phase uid 10 > task max 9 (cross-table max matters).
INSERT INTO job_phases (id, company_id, job_id, sort_order, name, msp_uid) VALUES
 ('f6000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e2',1,'E2 old',10),
 ('f6000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e2',2,'E2 new',NULL);
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES
 ('f7000000-0000-0000-0000-0000000000a1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e2',1,'E2 t2',2),
 ('f7000000-0000-0000-0000-0000000000a2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e2',2,'E2 t9',9),
 ('f7000000-0000-0000-0000-0000000000a3','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e2',3,'E2 new',NULL);
-- E4: no phase uid, task uid 30 (a phases-only max would hand out 1)
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f6000000-0000-0000-0000-0000000000b1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e4',1,'E4 p');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name, msp_uid) VALUES
 ('f7000000-0000-0000-0000-0000000000b1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e4',1,'E4 t30',30),
 ('f7000000-0000-0000-0000-0000000000b2','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e4',2,'E4 new',NULL);
-- E5, E6, E9: one phase and one task each, no uids
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f6000000-0000-0000-0000-0000000000c1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e5',1,'E5 p'),
 ('f6000000-0000-0000-0000-0000000000c6','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e6',1,'E6 p'),
 ('f6000000-0000-0000-0000-0000000000c9','c2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-0000000000e9',1,'E9 p');
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES
 ('f7000000-0000-0000-0000-0000000000c1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e5',1,'E5 t'),
 ('f7000000-0000-0000-0000-0000000000c6','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000e6',1,'E6 t'),
 ('f7000000-0000-0000-0000-0000000000c9','c2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-0000000000e9',1,'E9 t');
-- snapshot helpers (pg_temp): uids of a job, in a stable order
CREATE FUNCTION pg_temp.uids(p_job uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(k || '=' || coalesce(u::text, 'null'), ',' ORDER BY k), '') FROM (
    SELECT 'p:' || name AS k, msp_uid AS u FROM job_phases WHERE job_id = p_job
    UNION ALL SELECT 't:' || task_name, msp_uid FROM job_tasks WHERE job_id = p_job) s $$;
CREATE FUNCTION pg_temp.audn(p_job text) RETURNS text LANGUAGE sql AS $$
  SELECT count(*)::text FROM job_audit_log WHERE action_type = 'schedule_exported' AND job_id = p_job::uuid $$;

-- does THIS backend hold the transaction-level advisory lock for hashtext(job)? (pg_advisory_xact_lock(bigint): classid = high 32 bits, objid = low 32)
CREATE FUNCTION pg_temp.lockheld(p_job text) RETURNS text LANGUAGE sql AS $$
  SELECT (count(*) > 0)::text FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
     AND ((classid::bigint << 32) | objid::bigint) = hashtext(p_job)::bigint $$;

-- ===== 1. structure and exposure (X13) =====
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['prepare_schedule_export(uuid,text)', 'schedule_export_core(uuid,text)'] LOOP
    PERFORM t_expect('struct: ' || f || ' is SECURITY DEFINER', (SELECT prosecdef::text FROM pg_proc WHERE oid = ('public.' || f)::regprocedure), 'true');
    PERFORM t_expect('struct: ' || f || ' pins search_path',
      (SELECT coalesce(array_to_string(proconfig, ','), '') FROM pg_proc WHERE oid = ('public.' || f)::regprocedure), 'search_path=public, pg_temp');
    PERFORM t_expect('struct: ' || f || ' returns integer', (SELECT prorettype::regtype::text FROM pg_proc WHERE oid = ('public.' || f)::regprocedure), 'integer');
    PERFORM t_expect('struct: ' || f || ' owned by the owner of lock_job_baseline',
      (SELECT (p.proowner = (SELECT proowner FROM pg_proc WHERE proname = 'lock_job_baseline'))::text FROM pg_proc p WHERE p.oid = ('public.' || f)::regprocedure), 'true');
    PERFORM t_expect('struct: PUBLIC has no EXECUTE on ' || f,
      (SELECT count(*)::text FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = ('public.' || f)::regprocedure AND a.grantee = 0), '0');
    PERFORM t_expect('struct: anon has no EXECUTE on ' || f, has_function_privilege('anon', 'public.' || f, 'EXECUTE')::text, 'false');
  END LOOP;
  PERFORM t_expect('struct: authenticated can execute prepare_schedule_export', has_function_privilege('authenticated', 'public.prepare_schedule_export(uuid,text)', 'EXECUTE')::text, 'true');
  PERFORM t_expect('struct: authenticated can NOT execute the core', has_function_privilege('authenticated', 'public.schedule_export_core(uuid,text)', 'EXECUTE')::text, 'false');
  PERFORM t_expect('struct: service_role can NOT execute the core', has_function_privilege('service_role', 'public.schedule_export_core(uuid,text)', 'EXECUTE')::text, 'false');
  PERFORM t_expect('struct: p_kind defaults to staff (one default argument)', (SELECT pronargdefaults::text FROM pg_proc WHERE proname = 'prepare_schedule_export'), '1');
  PERFORM t_expect('struct: no other prepare_schedule_export overload', (SELECT count(*)::text FROM pg_proc WHERE proname = 'prepare_schedule_export'), '1');
  PERFORM t_expect('struct: anon really gets 42501', t_val('anon', NULL, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e1''::uuid)::text'), 'err:42501');
  PERFORM t_expect('struct: anon really gets 42501 for kind client', t_val('anon', NULL, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e1''::uuid, ''client'')::text'), 'err:42501');
  PERFORM t_expect('struct: authenticated really gets 42501 calling the core',
    t_val('authenticated', '11111111-1111-1111-1111-111111111111'::uuid, 'SELECT schedule_export_core(''b1000000-0000-0000-0000-0000000000e1''::uuid, ''staff'')::text'), 'err:42501');
  PERFORM t_expect('struct: audit action_type has no CHECK in this schema (schedule_exported is legal)',
    (SELECT count(*)::text FROM pg_constraint WHERE conrelid = 'public.job_audit_log'::regclass AND contype = 'c'), '0');
END $$;

-- ===== 2. refusals (error chosen over zero effect; each also leaves no audit row and no uid) =====
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  fin uuid := '13131313-1313-1313-1313-131313131313'; ops2 uuid := '77777777-7777-7777-7777-777777777777';
  gone uuid := '66666666-6666-6666-6666-666666666666'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  j9 text := 'b2000000-0000-0000-0000-0000000000e9'; j1 text := 'b1000000-0000-0000-0000-0000000000e1';
  nf text := 'job not found';
BEGIN
  PERFORM t_expect('refuse: cross-company job (ops of C1 on a C2 job)', t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L)', j9)), nf);
  PERFORM t_expect('refuse: cross-company job even for the writer of the other side (ops2 on a C1 job)', t_msg('authenticated', ops2, format('SELECT prepare_schedule_export(%L)', j1)), nf);
  PERFORM t_expect('refuse: missing job', t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L)', 'aaaaaaaa-0000-0000-0000-000000000000')), nf);
  PERFORM t_expect('refuse: NULL job', t_msg('authenticated', ops, 'SELECT prepare_schedule_export(NULL)'), nf);
  PERFORM t_expect('refuse: client-like login (no erp_users row)', t_msg('authenticated', clnt, format('SELECT prepare_schedule_export(%L)', j1)), nf);
  PERFORM t_expect('refuse: authenticated with no identity at all', t_msg('authenticated', NULL, format('SELECT prepare_schedule_export(%L)', j1)), nf);
  PERFORM t_expect('refuse: deactivated user', t_msg('authenticated', gone, format('SELECT prepare_schedule_export(%L)', j1)), nf);
  PERFORM t_expect('refuse: member without ops:work-orders:read (finance)', t_msg('authenticated', fin, format('SELECT prepare_schedule_export(%L)', j1)), 'permission denied: ops:work-orders:read required');
  PERFORM t_expect('refuse: kind client for authenticated writer',
    t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L, %L)', j1, 'client')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: kind client for authenticated reader',
    t_msg('authenticated', viewr, format('SELECT prepare_schedule_export(%L, %L)', j1, 'client')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: kind client for a client-like login',
    t_msg('authenticated', clnt, format('SELECT prepare_schedule_export(%L, %L)', j1, 'client')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: kind client through a PostgREST-like session (session_user authenticator)',
    t_msg_api('authenticated', ops, format('SELECT prepare_schedule_export(%L, %L)', j1, 'client')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: any other kind for authenticated (bogus)',
    t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L, %L)', j1, 'bogus')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: kind with different case', t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L, %L)', j1, 'STAFF')), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: NULL kind for authenticated', t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L, NULL)', j1)), 'permission denied: client export is not available to this role');
  PERFORM t_expect('refuse: unknown kind in the owner context', t_msg('postgres', NULL, format('SELECT prepare_schedule_export(%L, %L)', j1, 'bogus')), 'unknown export kind');
  PERFORM t_expect('refuse: NULL kind in the owner context', t_msg('postgres', NULL, format('SELECT prepare_schedule_export(%L, NULL)', j1)), 'unknown export kind');
  PERFORM t_expect('refuse: empty kind in the owner context', t_msg('postgres', NULL, format('SELECT prepare_schedule_export(%L, %L)', j1, '')), 'unknown export kind');
  PERFORM t_expect('refuse: missing job for kind client in the owner context', t_msg('postgres', NULL, format('SELECT prepare_schedule_export(%L, %L)', 'aaaaaaaa-0000-0000-0000-000000000000', 'client')), nf);
  PERFORM t_expect('refuse: no uid and no audit row was written by any refusal',
    (SELECT count(*)::text FROM job_audit_log WHERE action_type = 'schedule_exported' AND job_id IN (j1::uuid, j9::uuid))
    || '/' || (SELECT count(*)::text FROM job_phases WHERE msp_uid IS NOT NULL AND job_id IN (j1::uuid, j9::uuid))
    || '/' || (SELECT count(*)::text FROM job_tasks WHERE msp_uid IS NOT NULL AND job_id IN (j1::uuid, j9::uuid)), '0/0/0');
END $$;

-- ===== 3. read-only caller: may export, assigns nothing, audit row says assigned 0 =====
DO $$
DECLARE viewr uuid := '22222222-2222-2222-2222-222222222222'; mix uuid := 'e1e1e1e1-e1e1-e1e1-e1e1-e1e1e1e1e1e1';
  j5 text := 'b1000000-0000-0000-0000-0000000000e5'; j1 text := 'b1000000-0000-0000-0000-0000000000e1';
BEGIN
  PERFORM t_expect('reader: returns 0', t_msg('authenticated', viewr, format('SELECT prepare_schedule_export(%L)', j5)), 'ok:0');
  PERFORM t_expect('reader: no uid assigned', pg_temp.uids(j5::uuid), 'p:E5 p=null,t:E5 t=null');
  PERFORM t_expect('reader: audit row written', pg_temp.audn(j5), '1');
  PERFORM t_expect('reader: audit metadata is exactly kind/tasks/phases/assigned',
    (SELECT metadata::text FROM job_audit_log WHERE job_id = j5::uuid AND action_type = 'schedule_exported'),
    '{"kind": "staff", "tasks": 1, "phases": 1, "assigned": 0}');
  PERFORM t_expect('reader: audit identity and job_no',
    (SELECT user_id::text || '|' || username || '|' || job_no FROM job_audit_log WHERE job_id = j5::uuid AND action_type = 'schedule_exported'),
    viewr::text || '|viewer C1|WO-E05');
  PERFORM t_expect('reader: a reader holds no advisory lock on the job (lock is writer-only)', pg_temp.lockheld(j5), 'false');
  -- a role that is writer only in ANOTHER company is a reader here
  PERFORM t_expect('scoped: viewer in C1 / writer in C2 assigns nothing on a C1 job', t_msg('authenticated', mix, format('SELECT prepare_schedule_export(%L)', j5)), 'ok:0');
  PERFORM t_expect('scoped: ... and left every uid NULL', pg_temp.uids(j5::uuid), 'p:E5 p=null,t:E5 t=null');
  PERFORM t_expect('scoped: ... but is a writer on the C2 job', t_msg('authenticated', mix, 'SELECT prepare_schedule_export(''b2000000-0000-0000-0000-0000000000e9'')'), 'ok:2');
END $$;

-- ===== 4. writer assigns once, in (sort_order, id) order, phases first =====
DO $$
DECLARE wrt uuid := '12121212-1212-1212-1212-121212121212'; ops uuid := '11111111-1111-1111-1111-111111111111';
  viewr uuid := '22222222-2222-2222-2222-222222222222'; j1 text := 'b1000000-0000-0000-0000-0000000000e1';
  snap text;
BEGIN
  PERFORM t_expect('writer: nothing assigned yet', pg_temp.uids(j1::uuid), 'p:Pa=null,p:Pb=null,p:Pc=null,t:T1=null,t:T2=null,t:T3=null,t:T4=null');
  PERFORM t_expect('writer: write+read role (no approve) assigns 7', t_msg('authenticated', wrt, format('SELECT prepare_schedule_export(%L)', j1)), 'ok:7');
  PERFORM t_expect('writer: phases first (Pb=1,Pc=2 tie by id, Pa=3), then tasks (T3=4,T2=5 tie by id, T4=6, T1=7)',
    pg_temp.uids(j1::uuid), 'p:Pa=3,p:Pb=1,p:Pc=2,t:T1=7,t:T2=5,t:T3=4,t:T4=6');
  PERFORM t_expect('writer: the job advisory lock is held for the rest of the transaction (hashtext(job_id::text))', pg_temp.lockheld(j1), 'true');
  PERFORM t_expect('writer: audit row written once', pg_temp.audn(j1), '1');
  PERFORM t_expect('writer: audit metadata', (SELECT metadata::text FROM job_audit_log WHERE job_id = j1::uuid AND action_type = 'schedule_exported'),
    '{"kind": "staff", "tasks": 4, "phases": 3, "assigned": 7}');
  PERFORM t_expect('writer: audit identity, description and job_no',
    (SELECT user_id::text || '|' || username || '|' || job_no || '|' || description FROM job_audit_log WHERE job_id = j1::uuid AND action_type = 'schedule_exported'),
    wrt::text || '|writer C1|WO-E01|Schedule exported (staff)');
  snap := pg_temp.uids(j1::uuid);
  PERFORM t_expect('idempotent: second call by the same writer assigns 0', t_msg('authenticated', wrt, format('SELECT prepare_schedule_export(%L)', j1)), 'ok:0');
  PERFORM t_expect('idempotent: ... and by an approver', t_msg('authenticated', ops, format('SELECT prepare_schedule_export(%L)', j1)), 'ok:0');
  PERFORM t_expect('idempotent: ... and by a reader', t_msg('authenticated', viewr, format('SELECT prepare_schedule_export(%L)', j1)), 'ok:0');
  PERFORM t_expect('idempotent: existing uids never change', pg_temp.uids(j1::uuid), snap);
  PERFORM t_expect('audit: one row per export call (4 calls)', pg_temp.audn(j1), '4');
  PERFORM t_expect('audit: only the first call recorded assigned 7',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id = j1::uuid AND action_type = 'schedule_exported' AND metadata ->> 'assigned' = '7'), '1');
  PERFORM t_expect('audit: the other three recorded assigned 0',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id = j1::uuid AND action_type = 'schedule_exported' AND metadata ->> 'assigned' = '0'), '3');
  PERFORM t_expect('default kind is staff', (SELECT count(*)::text FROM job_audit_log WHERE job_id = j1::uuid AND metadata ->> 'kind' = 'staff'), '4');
END $$;

-- ===== 5. existing uids, the shared UID space, per-job spaces, empty job =====
DO $$
DECLARE ops uuid := '11111111-1111-1111-1111-111111111111';
BEGIN
  PERFORM t_expect('space: max is taken across BOTH tables (phase uid 10 > task max 9): new phase 11, new task 12',
    t_msg('authenticated', ops, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e2'')'), 'ok:2');
  PERFORM t_expect('space: existing uids untouched, gap kept', pg_temp.uids('b1000000-0000-0000-0000-0000000000e2'),
    'p:E2 new=11,p:E2 old=10,t:E2 new=12,t:E2 t2=2,t:E2 t9=9');
  PERFORM t_expect('space: a task-only max counts (task uid 30): new phase 31, new task 32',
    t_msg('authenticated', ops, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e4'')'), 'ok:2');
  PERFORM t_expect('space: ... exact values', pg_temp.uids('b1000000-0000-0000-0000-0000000000e4'), 'p:E4 p=31,t:E4 new=32,t:E4 t30=30');
  PERFORM t_expect('space: another job starts at 1 again (per-job space)', t_msg('authenticated', ops, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e6'')'), 'ok:2');
  PERFORM t_expect('space: ... exact values', pg_temp.uids('b1000000-0000-0000-0000-0000000000e6'), 'p:E6 p=1,t:E6 t=2');
  PERFORM t_expect('empty job: returns 0 and still audits with zero counts',
    t_msg('authenticated', ops, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000e3'')'), 'ok:0');
  PERFORM t_expect('empty job: audit metadata', (SELECT metadata::text FROM job_audit_log WHERE job_id = 'b1000000-0000-0000-0000-0000000000e3' AND action_type = 'schedule_exported'),
    '{"kind": "staff", "tasks": 0, "phases": 0, "assigned": 0}');
  PERFORM t_expect('space: no uid is 0 anywhere', (SELECT count(*)::text FROM (SELECT msp_uid FROM job_phases UNION ALL SELECT msp_uid FROM job_tasks) s WHERE msp_uid = 0), '0');
  PERFORM t_expect('space: no uid is shared by a phase and a task (or two rows) of one job',
    (SELECT count(*)::text FROM (SELECT 1 FROM (SELECT job_id, msp_uid FROM job_phases WHERE msp_uid IS NOT NULL UNION ALL SELECT job_id, msp_uid FROM job_tasks WHERE msp_uid IS NOT NULL) s
       GROUP BY job_id, msp_uid HAVING count(*) > 1) d), '0');
  PERFORM t_expect('space: no NULL uid left in any job a writer exported',
    (SELECT count(*)::text FROM (SELECT msp_uid FROM job_phases WHERE job_id IN ('b1000000-0000-0000-0000-0000000000e1','b1000000-0000-0000-0000-0000000000e2','b1000000-0000-0000-0000-0000000000e4','b1000000-0000-0000-0000-0000000000e6')
       UNION ALL SELECT msp_uid FROM job_tasks WHERE job_id IN ('b1000000-0000-0000-0000-0000000000e1','b1000000-0000-0000-0000-0000000000e2','b1000000-0000-0000-0000-0000000000e4','b1000000-0000-0000-0000-0000000000e6')) s
       WHERE msp_uid IS NULL), '0');
  PERFORM t_expect('space: the other company job was assigned only by its own writer (mix, section 3)',
    pg_temp.uids('b2000000-0000-0000-0000-0000000000e9'), 'p:E9 p=1,t:E9 t=2');
END $$;

-- ===== 6. kind client: owner / service_role context only; refused through the API =====
CREATE FUNCTION public.t_portal_probe_core(p_job uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN RETURN schedule_export_core(p_job, 'client')::text; END $$;
CREATE FUNCTION public.t_portal_probe_public(p_job uuid) RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN RETURN prepare_schedule_export(p_job, 'client')::text; END $$;
GRANT EXECUTE ON FUNCTION public.t_portal_probe_core(uuid), public.t_portal_probe_public(uuid) TO authenticated;
DO $$
DECLARE clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc'; wrt uuid := '12121212-1212-1212-1212-121212121212';
  j5 text := 'b1000000-0000-0000-0000-0000000000e5';
BEGIN
  PERFORM t_expect('client: owner context may call kind client (assigns nothing: no writer identity)', t_msg('postgres', NULL, format('SELECT prepare_schedule_export(%L, %L)', j5, 'client')), 'ok:0');
  PERFORM t_expect('client: service_role may call kind client', t_msg('service_role', NULL, format('SELECT prepare_schedule_export(%L, %L)', j5, 'client')), 'ok:0');
  PERFORM t_expect('client: ... no uid assigned', pg_temp.uids(j5::uuid), 'p:E5 p=null,t:E5 t=null');
  PERFORM t_expect('client: a Phase D definer calling the core from a client session works',
    t_msg('authenticated', clnt, format('SELECT t_portal_probe_core(%L)', j5)), 'ok:0');
  PERFORM t_expect('client: ... but a client session cannot reach kind client through the public function, even inside a definer',
    t_msg('authenticated', clnt, format('SELECT t_portal_probe_public(%L)', j5)), 'permission denied: client export is not available to this role');
  PERFORM t_expect('client: audit rows for kind client recorded (owner, service_role, definer probe)',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id = j5::uuid AND action_type = 'schedule_exported' AND metadata ->> 'kind' = 'client'), '3');
  PERFORM t_expect('client: audit metadata of a client export',
    (SELECT metadata::text FROM job_audit_log WHERE job_id = j5::uuid AND metadata ->> 'kind' = 'client' AND user_id = clnt),
    '{"kind": "client", "tasks": 1, "phases": 1, "assigned": 0}');
  PERFORM t_expect('client: the owner-context audit rows have no user',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id = j5::uuid AND metadata ->> 'kind' = 'client' AND user_id IS NULL), '2');
  PERFORM t_expect('client: a refused call writes nothing',
    (SELECT count(*)::text FROM job_audit_log WHERE job_id IS NULL AND action_type = 'schedule_exported'), '0');
  PERFORM t_expect('client: a deactivated staff identity holds no atoms (kind client, owner context): assigns 0',
    t_msg('postgres', '66666666-6666-6666-6666-666666666666'::uuid, format('SELECT prepare_schedule_export(%L, %L)', j5, 'client')), 'ok:0');
  PERFORM t_expect('client: ... and no uid was written', pg_temp.uids(j5::uuid), 'p:E5 p=null,t:E5 t=null');
  PERFORM t_expect('client: a session whose identity is a writer assigns even for kind client (the rule is the identity, not the kind)',
    t_msg('postgres', wrt, format('SELECT prepare_schedule_export(%L, %L)', j5, 'client')), 'ok:2');
END $$;
ROLLBACK;

-- ===== 7. committed marker (idempotent) so 30_rollback can prove audit rows and uids survive the rollback =====
BEGIN;
INSERT INTO jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-0000000000f1','c1000000-0000-0000-0000-000000000001','WO-F01','Open') ON CONFLICT DO NOTHING;
INSERT INTO job_phases (id, company_id, job_id, sort_order, name) VALUES
 ('f6000000-0000-0000-0000-0000000000f1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000f1',1,'F p') ON CONFLICT DO NOTHING;
INSERT INTO job_tasks (id, company_id, job_id, sort_order, task_name) VALUES
 ('f7000000-0000-0000-0000-0000000000f1','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-0000000000f1',1,'F t') ON CONFLICT DO NOTHING;
DO $$
BEGIN
  PERFORM t_msg('authenticated', '11111111-1111-1111-1111-111111111111'::uuid, 'SELECT prepare_schedule_export(''b1000000-0000-0000-0000-0000000000f1'')');
  PERFORM t_expect('marker: committed export left uids 1 and 2 (phase first)',
    (SELECT string_agg(k || '=' || u, ',' ORDER BY k) FROM (SELECT 'p' AS k, msp_uid::text AS u FROM job_phases WHERE job_id = 'b1000000-0000-0000-0000-0000000000f1'
      UNION ALL SELECT 't', msp_uid::text FROM job_tasks WHERE job_id = 'b1000000-0000-0000-0000-0000000000f1') s), 'p=1,t=2');
END $$;
COMMIT;
