-- Rollback of 202610210300_d0c_jobs.sql: restores the legacy open policy on public.jobs.
DROP TRIGGER IF EXISTS d0c_jobs_lock_company ON public.jobs;
DROP FUNCTION IF EXISTS public.d0c_jobs_lock_company();
DROP POLICY IF EXISTS d0c_jobs_select ON public.jobs;
DROP POLICY IF EXISTS d0c_jobs_insert ON public.jobs;
DROP POLICY IF EXISTS d0c_jobs_update ON public.jobs;
DROP POLICY IF EXISTS d0c_jobs_delete ON public.jobs;
DROP POLICY IF EXISTS "authenticated users full access" ON public.jobs;
CREATE POLICY "authenticated users full access" ON public.jobs FOR ALL TO authenticated USING (true) WITH CHECK (true);
