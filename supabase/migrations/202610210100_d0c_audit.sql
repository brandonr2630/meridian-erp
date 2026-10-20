-- D0c (audit family): company- and permission-scoped RLS for public.job_audit_log (project-portal spec, Phase D section D0).
--
-- Replaces the legacy permissive policy "authenticated users full access" (FOR ALL TO authenticated USING (true) WITH CHECK (true))
-- with two scoped permissive policies. The D0a restrictive policies (d0_staff_only, d0_no_anon) are NOT touched and still AND in.
--
-- Design (append-only audit log):
--   SELECT  job rows: caller holds ops:work-orders:read AND the row's job belongs to one of the caller's companies.
--           rows with job_id NULL (written by the erp-user-access edge function as staff.access.*, or orphaned when a job was deleted:
--           the FK is ON DELETE SET NULL) are visible to super admins only.
--   INSERT  caller holds ops:work-orders:write, user_id = auth.uid(), the job exists in one of the caller's companies (job_id NOT NULL),
--           and the action is not a staff.access.* action (those are written by the service role only, which bypasses RLS).
--   UPDATE / DELETE: no policy for any authenticated role (audit rows are immutable). The ERP never updates or deletes audit rows.
--           As defence in depth UPDATE, DELETE and TRUNCATE are also REVOKEd from authenticated (and TRUNCATE from anon): RLS does not
--           cover TRUNCATE at all, and the table owner / service_role / postgres are unaffected (FK SET NULL, renumber migration, edge function).
--
-- No data is changed. Idempotent: safe to run twice.
-- Rollback: supabase/rollbacks/202610210100_d0c_audit_down.sql

DROP POLICY IF EXISTS "authenticated users full access" ON public.job_audit_log;

DROP POLICY IF EXISTS d0c_job_audit_log_select ON public.job_audit_log;
CREATE POLICY d0c_job_audit_log_select ON public.job_audit_log
  FOR SELECT TO authenticated
  USING (
    (
      (SELECT public.user_has_perm('ops:work-orders:read'))
      AND job_id IS NOT NULL
      AND job_id IN (SELECT j.id FROM public.jobs j WHERE j.company_id IN (SELECT public.my_company_ids()))
    )
    OR (job_id IS NULL AND (SELECT public.is_super_admin()))
  );

DROP POLICY IF EXISTS d0c_job_audit_log_insert ON public.job_audit_log;
CREATE POLICY d0c_job_audit_log_insert ON public.job_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND (SELECT public.user_has_perm('ops:work-orders:write'))
    AND action_type NOT LIKE 'staff.access.%'
    AND job_id IS NOT NULL
    AND job_id IN (SELECT j.id FROM public.jobs j WHERE j.company_id IN (SELECT public.my_company_ids()))
  );

-- Immutability backstop (policies already give no UPDATE/DELETE path).
REVOKE UPDATE, DELETE, TRUNCATE ON public.job_audit_log FROM authenticated;
REVOKE TRUNCATE ON public.job_audit_log FROM anon;
