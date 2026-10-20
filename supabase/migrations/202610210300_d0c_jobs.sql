-- D0c / jobs: replace the legacy open policy "authenticated users full access" (FOR ALL TO authenticated USING (true) WITH CHECK (true))
-- on public.jobs with company- and permission-scoped policies. The D0a restrictive policies d0_staff_only / d0_no_anon are NOT touched.
--
-- Access model (derived from index.html; see the PR for the full code-path list):
--   SELECT  company_id in the caller's companies AND ops:work-orders:read (or :write). Every UI reader of jobs (work-orders
--           dashboard/search/open/PDF-email, dashboard zone 3 and recent activity) is already gated by ops:work-orders:read.
--   INSERT  company in caller's companies AND ops:work-orders:write.
--   UPDATE  same in USING and WITH CHECK, plus trigger d0c_jobs_lock_company() that forbids changing company_id at all
--           (RLS alone cannot stop a multi-company user from moving a job between two of their own companies).
--   DELETE  company in caller's companies AND is_company_admin(company_id) (admin:users or admin:settings in that company),
--           which is what the UI's isAdmin() gate on jcDeleteJob() means.
-- postgres / service_role (edge functions, SECURITY DEFINER code, pg_cron) bypass RLS and are unaffected.
-- Idempotent. Rollback: supabase/rollbacks/202610210300_d0c_jobs_down.sql

DROP POLICY IF EXISTS "authenticated users full access" ON public.jobs;

DROP POLICY IF EXISTS d0c_jobs_select ON public.jobs;
CREATE POLICY d0c_jobs_select ON public.jobs FOR SELECT TO authenticated
  USING (company_id IN (SELECT public.my_company_ids())
         AND ((SELECT public.user_has_perm('ops:work-orders:read')) OR (SELECT public.user_has_perm('ops:work-orders:write'))));

DROP POLICY IF EXISTS d0c_jobs_insert ON public.jobs;
CREATE POLICY d0c_jobs_insert ON public.jobs FOR INSERT TO authenticated
  WITH CHECK (company_id IN (SELECT public.my_company_ids())
              AND (SELECT public.user_has_perm('ops:work-orders:write')));

DROP POLICY IF EXISTS d0c_jobs_update ON public.jobs;
CREATE POLICY d0c_jobs_update ON public.jobs FOR UPDATE TO authenticated
  USING (company_id IN (SELECT public.my_company_ids())
         AND (SELECT public.user_has_perm('ops:work-orders:write')))
  WITH CHECK (company_id IN (SELECT public.my_company_ids())
              AND (SELECT public.user_has_perm('ops:work-orders:write')));

DROP POLICY IF EXISTS d0c_jobs_delete ON public.jobs;
CREATE POLICY d0c_jobs_delete ON public.jobs FOR DELETE TO authenticated
  USING (company_id IN (SELECT public.my_company_ids())
         AND public.is_company_admin(company_id));

-- A job never changes company (the UI always writes currentCompany.id, which equals the job's own company).
CREATE OR REPLACE FUNCTION public.d0c_jobs_lock_company() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.company_id IS DISTINCT FROM OLD.company_id THEN
    RAISE EXCEPTION 'jobs.company_id cannot be changed' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.d0c_jobs_lock_company() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS d0c_jobs_lock_company ON public.jobs;
CREATE TRIGGER d0c_jobs_lock_company BEFORE UPDATE OF company_id ON public.jobs
  FOR EACH ROW EXECUTE FUNCTION public.d0c_jobs_lock_company();
