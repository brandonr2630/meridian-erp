-- a2a_import family stub (applied after D0a, the Phase A stub + migration and the a2a_schema columns, see requires.txt).
-- Adds one mixed-role user (write+approve in C1, viewer in C2) and payload-building helpers. Test-only, never part of the migration.
INSERT INTO public.erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000020','20202020-2020-2020-2020-202020202020','mixed C1/C2', true);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000020','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001'),
 ('e0000000-0000-0000-0000-000000000020','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000002');

-- t_imp(role, sub, job, mode, payload, reason): 'ok:<result json>' or the error message
CREATE OR REPLACE FUNCTION public.t_imp(p_role text, p_sub uuid, p_job uuid, p_mode text, p_payload jsonb, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  RETURN public.t_msg(p_role, p_sub, format('SELECT import_job_schedule(%L, %L, %L::jsonb, %L)::text', p_job, p_mode, p_payload::text, p_reason));
END $$;
-- t_state(job): 'phases/tasks/links' row counts
CREATE OR REPLACE FUNCTION public.t_state(p_job uuid) RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM job_phases WHERE job_id = p_job) || '/' || (SELECT count(*) FROM job_tasks WHERE job_id = p_job)
         || '/' || (SELECT count(*) FROM job_task_links WHERE job_id = p_job) $$;
-- t_based(job): the value a client passes as payload.based_on (max updated_at over the schedule), NULL for an empty schedule
CREATE OR REPLACE FUNCTION public.t_based(p_job uuid) RETURNS text LANGUAGE sql AS $$
  SELECT max(u)::text FROM (SELECT max(updated_at) u FROM job_tasks WHERE job_id = p_job UNION ALL SELECT max(updated_at) FROM job_phases WHERE job_id = p_job
                            UNION ALL SELECT max(updated_at) FROM job_task_links WHERE job_id = p_job) s $$;
-- payload builders in the codec's toPayload shape
CREATE OR REPLACE FUNCTION public.t_ph(p_uid int, p_name text, p_sort int DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('uid', p_uid, 'name', p_name, 'sort_order', p_sort)) $$;
CREATE OR REPLACE FUNCTION public.t_lk(p_pred int, p_type text DEFAULT 'FS', p_lag int DEFAULT 0) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('pred_uid', p_pred, 'link_type', p_type, 'lag_days', p_lag) $$;
CREATE OR REPLACE FUNCTION public.t_tk(p_uid int, p_name text, p_phase int DEFAULT NULL, p_parent int DEFAULT NULL,
  p_start text DEFAULT '2026-05-01', p_end text DEFAULT '2026-05-05', p_links jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('uid', p_uid, 'name', p_name, 'phase_uid', p_phase, 'parent_uid', p_parent, 'start_date', p_start, 'end_date', p_end,
    'progress', 0, 'is_milestone', false, 'is_summary', false, 'baseline_start', NULL, 'baseline_end', NULL, 'sort_order', p_uid * 10, 'links', p_links) $$;
-- t_pl(phases, tasks, job, extra): a complete wrapper payload; based_on is read from the job so it is fresh unless extra overrides it
CREATE OR REPLACE FUNCTION public.t_pl(p_phases jsonb, p_tasks jsonb, p_job uuid DEFAULT NULL, p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('phases', p_phases, 'tasks', p_tasks, 'file_name', 'test.xml', 'based_on', public.t_based(p_job)) || p_extra $$;
GRANT EXECUTE ON FUNCTION public.t_imp(text, uuid, uuid, text, jsonb, text), public.t_state(uuid), public.t_based(uuid) TO PUBLIC;
-- more helpers: identities, job factory, result readers
CREATE OR REPLACE FUNCTION public.t_u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'ops' THEN '11111111-1111-1111-1111-111111111111' WHEN 'viewr' THEN '22222222-2222-2222-2222-222222222222'
    WHEN 'cadm' THEN '33333333-3333-3333-3333-333333333333' WHEN 'sup' THEN '44444444-4444-4444-4444-444444444444'
    WHEN 'gone' THEN '66666666-6666-6666-6666-666666666666' WHEN 'ops2' THEN '77777777-7777-7777-7777-777777777777'
    WHEN 'wrt' THEN '12121212-1212-1212-1212-121212121212' WHEN 'fin' THEN '13131313-1313-1313-1313-131313131313'
    WHEN 'mix' THEN '20202020-2020-2020-2020-202020202020' WHEN 'clnt' THEN 'cccccccc-cccc-cccc-cccc-cccccccccccc' END::uuid $$;
-- t_jid(n [, company]): the deterministic id of test job n (company 1 by default, 2 for the other company); t_job creates it
CREATE OR REPLACE FUNCTION public.t_jid(p_n int, p_co int DEFAULT 1) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$
  SELECT (CASE WHEN p_co = 1 THEN 'b1000000-0000-0000-0000-' ELSE 'b2000000-0000-0000-0000-' END || lpad(to_hex(p_n + 3584), 12, '0'))::uuid $$;
CREATE OR REPLACE FUNCTION public.t_job(p_n int, p_co int DEFAULT 1) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid := public.t_jid(p_n, p_co);
BEGIN
  INSERT INTO jobs (id, company_id, job_no, status) VALUES (v, (CASE WHEN p_co = 1 THEN 'c1000000-0000-0000-0000-000000000001' ELSE 'c2000000-0000-0000-0000-000000000002' END)::uuid,
    'IMP-' || p_co || '-' || p_n, 'Open');
  RETURN v;
END $$;
-- t_res(result, key): a key of the ok: result json, or the error text unchanged
CREATE OR REPLACE FUNCTION public.t_res(p_res text, p_key text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN p_res LIKE 'ok:%' THEN (substr(p_res, 4)::jsonb) ->> p_key ELSE p_res END $$;
-- t_warn(result, code): the count of one warning code in an ok: result, 'none' if absent
CREATE OR REPLACE FUNCTION public.t_warn(p_res text, p_code text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce((SELECT w ->> 'count' FROM jsonb_array_elements((substr(p_res, 4)::jsonb) -> 'warnings') w WHERE w ->> 'code' = p_code), 'none') $$;
GRANT EXECUTE ON FUNCTION public.t_u(text), public.t_jid(int, int), public.t_job(int, int), public.t_res(text, text), public.t_warn(text, text) TO PUBLIC;
