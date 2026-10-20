-- Rollback for 202610210100_d0c_audit.sql: restores the exact legacy open policy and the legacy table grants, drops the d0c_* policies.
-- The D0a restrictive policies (d0_staff_only, d0_no_anon) are left in place.

GRANT UPDATE, DELETE, TRUNCATE ON public.job_audit_log TO authenticated;
GRANT TRUNCATE ON public.job_audit_log TO anon;

DROP POLICY IF EXISTS d0c_job_audit_log_select ON public.job_audit_log;
DROP POLICY IF EXISTS d0c_job_audit_log_insert ON public.job_audit_log;

DROP POLICY IF EXISTS "authenticated users full access" ON public.job_audit_log;
CREATE POLICY "authenticated users full access" ON public.job_audit_log FOR ALL TO authenticated USING (true) WITH CHECK (true);
