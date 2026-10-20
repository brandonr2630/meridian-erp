-- phase_a_sql family stub: the live pieces Phase A touches that the D0a stub lacks (live state 2026-10-20/21).
-- Supabase default privileges (new functions/tables are granted to anon, authenticated, service_role at creation).
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- set_updated_at(): live body (returns trigger, sets NEW.updated_at = now())
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

-- jobs: the columns Phase A reads; live D0c select policy replaces the legacy open policy (D0a restrictive pair stays)
ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS job_type text, ADD COLUMN IF NOT EXISTS due_date date,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'Open';
DROP POLICY IF EXISTS "authenticated users full access" ON public.jobs;
CREATE POLICY d0c_jobs_select ON public.jobs FOR SELECT TO authenticated
  USING (company_id IN (SELECT public.my_company_ids())
         AND ((SELECT public.user_has_perm('ops:work-orders:read')) OR (SELECT public.user_has_perm('ops:work-orders:write'))));

-- live atom sets (approve is live on operations_tech, company_admin, super_admin; viewer is read only)
UPDATE public.erp_roles SET permissions = '{"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"ops:costing:read":true}'::jsonb WHERE name='operations_tech';
UPDATE public.erp_roles SET permissions = '{"ops:work-orders:read":true,"ops:costing:read":true}'::jsonb WHERE name='viewer';
UPDATE public.erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true}'::jsonb WHERE name='company_admin';
UPDATE public.erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true}'::jsonb WHERE name='super_admin';
UPDATE public.erp_roles SET permissions = '{"ops:work-orders:read":true}'::jsonb WHERE name='Office Admin';
-- test-only role: holds write but NOT approve (none live today, possible later)
INSERT INTO public.erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000008','ops_writer_no_approve','{"ops:work-orders:read":true,"ops:work-orders:write":true}'),
 ('a0000000-0000-0000-0000-000000000009','finance_manager','{"finance:ap:read":true}');
INSERT INTO public.erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000012','12121212-1212-1212-1212-121212121212','writer C1', true),
 ('e0000000-0000-0000-0000-000000000013','13131313-1313-1313-1313-131313131313','finance C1', true);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000012','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000008'),
 ('e0000000-0000-0000-0000-000000000013','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000009'),
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- job_audit_log: live shape (see d0c_audit stub); job_id FK to jobs ON DELETE SET NULL
DROP TABLE public.job_audit_log CASCADE;
CREATE TABLE public.job_audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id      uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  job_no      text,
  user_id     uuid,
  username    text,
  action_type text NOT NULL,
  description text,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.job_audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated users full access" ON public.job_audit_log FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY d0_staff_only ON public.job_audit_log AS RESTRICTIVE FOR ALL TO authenticated
  USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()));
CREATE POLICY d0_no_anon ON public.job_audit_log AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);

-- job_tasks: EXACT live definition (migrations/20261019_job_tasks.sql) incl. its four RLS policies
CREATE TABLE public.job_tasks (
  id           uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   uuid         NOT NULL REFERENCES companies(id),
  job_id       uuid         NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  sort_order   int          NOT NULL DEFAULT 0,
  task_name    text         NOT NULL DEFAULT '',
  start_date   date,
  end_date     date,
  progress     int          NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  assignee     text,
  depends_on   uuid         REFERENCES job_tasks(id) ON DELETE SET NULL,
  created_at   timestamptz  NOT NULL DEFAULT now(),
  updated_at   timestamptz  NOT NULL DEFAULT now(),
  CONSTRAINT job_tasks_dates_chk CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_job_tasks_job_id         ON job_tasks (job_id);
CREATE INDEX idx_job_tasks_company_job    ON job_tasks (company_id, job_id);
CREATE INDEX idx_job_tasks_depends_on     ON job_tasks (depends_on);
ALTER TABLE job_tasks ENABLE ROW LEVEL SECURITY;
CREATE POLICY "job_tasks members read" ON job_tasks
  FOR SELECT TO authenticated
  USING (company_id IN (SELECT my_company_ids()));
CREATE POLICY "job_tasks writers insert" ON job_tasks
  FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
CREATE POLICY "job_tasks writers update" ON job_tasks
  FOR UPDATE TO authenticated
  USING      (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'))
  WITH CHECK (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));
CREATE POLICY "job_tasks writers delete" ON job_tasks
  FOR DELETE TO authenticated
  USING (company_id IN (SELECT my_company_ids()) AND user_has_perm('ops:work-orders:write'));

-- legacy v1 schedule data (before the migration): chain T1<-T2<-T3 in B8; legacy hazards: a depends_on cycle (T4<->T5),
-- a self-reference (T6) and a cross-job parent (T7 in B9 -> T1 in B8). The backfill must keep the chain and skip the hazards.
INSERT INTO public.jobs (id, company_id, job_no, status) VALUES
 ('b1000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','WO-008','Open'),
 ('b1000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','WO-009','Open');
INSERT INTO public.job_tasks (id, company_id, job_id, sort_order, task_name, start_date, end_date, progress) VALUES
 ('d1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',1,'legacy T1','2026-03-01','2026-03-10',100),
 ('d1000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',2,'legacy T2','2026-03-11','2026-03-20',50),
 ('d1000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',3,'legacy T3','2026-03-21','2026-03-30',0),
 ('d1000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',4,'legacy T4',NULL,NULL,0),
 ('d1000000-0000-0000-0000-000000000005','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',5,'legacy T5',NULL,NULL,0),
 ('d1000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000008',6,'legacy T6',NULL,NULL,0),
 ('d1000000-0000-0000-0000-000000000007','c1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000009',1,'legacy T7',NULL,NULL,0);
UPDATE public.job_tasks SET depends_on = 'd1000000-0000-0000-0000-000000000001' WHERE id IN
  ('d1000000-0000-0000-0000-000000000002','d1000000-0000-0000-0000-000000000007');
UPDATE public.job_tasks SET depends_on = 'd1000000-0000-0000-0000-000000000002' WHERE id = 'd1000000-0000-0000-0000-000000000003';
UPDATE public.job_tasks SET depends_on = 'd1000000-0000-0000-0000-000000000005' WHERE id = 'd1000000-0000-0000-0000-000000000004';
UPDATE public.job_tasks SET depends_on = 'd1000000-0000-0000-0000-000000000004' WHERE id = 'd1000000-0000-0000-0000-000000000005';
UPDATE public.job_tasks SET depends_on = 'd1000000-0000-0000-0000-000000000006' WHERE id = 'd1000000-0000-0000-0000-000000000006';

-- PostgREST-like connection role: session_user is authenticator (NOT postgres), then SET ROLE authenticated/anon.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN; END IF;
END $$;
GRANT anon, authenticated, service_role TO authenticator;

-- t_val(role, sub, sql): first column of the first row as text ('<null>' when no row/NULL) or 'err:<sqlstate>'
CREATE OR REPLACE FUNCTION public.t_val(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN coalesce(v, '<null>');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'err:' || SQLSTATE;
  END;
END $$;
-- t_dml_api(role, sub, stmt): like t_dml but through a PostgREST-like session (session_user = authenticator)
CREATE OR REPLACE FUNCTION public.t_dml_api(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL SESSION AUTHORIZATION authenticator';
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'rows:' || n;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'err:' || SQLSTATE;
  END;
END $$;
-- t_api_ident(): session_user/current_user the guard sees through the API-like session (proves the exemption test is real)
CREATE OR REPLACE FUNCTION public.t_api_ident() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE 'SET LOCAL SESSION AUTHORIZATION authenticator';
  EXECUTE 'SET LOCAL ROLE authenticated';
  r := session_user || '/' || current_user;
  RESET ROLE; RESET SESSION AUTHORIZATION;
  RETURN r;
END $$;
-- t_msg(role, sub, sql): 'ok:<first column>' or the error message text (SQLERRM) of the failing statement
CREATE OR REPLACE FUNCTION public.t_msg(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN 'ok:' || coalesce(v, '<null>');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN SQLERRM;
  END;
END $$;
-- t_msg_api(role, sub, stmt): error message of a DML statement run through the PostgREST-like session ('ok' when it succeeds)
CREATE OR REPLACE FUNCTION public.t_msg_api(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL SESSION AUTHORIZATION authenticator';
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql;
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'ok';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN SQLERRM;
  END;
END $$;
