-- Rollback for 202610290900_d0c_audit_reserved.sql: restores the D0c insert policy exactly as 202610210100_d0c_audit.sql defines it
-- (no reserved-action list). Idempotent. The D0c select policy, the D0a restrictive policies and the grants are not touched.
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
COMMENT ON POLICY d0c_job_audit_log_insert ON public.job_audit_log IS NULL;
