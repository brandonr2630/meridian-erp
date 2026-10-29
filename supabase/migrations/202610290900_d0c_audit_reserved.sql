-- Audit hardening (finding E1 of the A2a attack review, 2026-10-28): audit rows that only database functions may write can no longer be
-- inserted from a browser session.
--
-- Before: the D0c insert policy (202610210100_d0c_audit.sql) already requires user_id = auth.uid(), the write atom, a job of the caller's
-- company and a non-'staff.access.%' action, so nobody can forge a row in ANOTHER person's name. What was still open: a writer could insert a
-- row under their OWN name whose action_type is one of the types the database functions write (a made-up 'schedule_imported' with a made-up
-- recovery copy, a made-up 'baseline_locked'), and the ERP reads those rows back as history.
--
-- Now: the insert policy also refuses the reserved action types below. They are written only by SECURITY DEFINER functions owned by the
-- migration owner (which bypass RLS) and by the service role: lock_job_baseline and job_visibility_guard (Phase A), schedule_export_core
-- (A2a export) and import_job_schedule (A2a import). The only types the web app writes itself are 'job_saved' and 'job_deleted' (index.html).
--
-- It is a DENY-list on purpose: a new action type that the web app starts writing keeps working (the app ignores audit write errors, so an
-- allow-list would silently lose those rows). The price is a rule for the future: EVERY action type that a database function writes must be
-- added to the list below, in a new migration. scripts/verify-audit-reserved.mjs checks it (every type written by a migration is reserved,
-- and no type the web app writes is); run it before merging any change that touches job_audit_log.
--
-- Configuration guard: this migration is only effective when the D0c policies are the ones in force. If the legacy open policy
-- ("authenticated users full access") or any other permissive INSERT/ALL policy for the API roles exists (D0c not applied, or a policy added by
-- hand in the dashboard), a permissive policy would let every insert through, so the migration stops with an error instead of silently doing nothing.
--
-- Idempotent. Changes no data. Rollback: supabase/rollbacks/202610290900_d0c_audit_reserved_down.sql (restores the D0c policy).
-- Tests: bash supabase/tests/d0c_common/run.sh d0c_audit_reserved ; mutants: node supabase/tests/d0c_common/mutate.mjs d0c_audit_reserved
DO $$
DECLARE v_other text;
BEGIN
  IF to_regclass('public.job_audit_log') IS NULL THEN
    RAISE EXCEPTION 'public.job_audit_log does not exist' USING ERRCODE = '42P01';
  END IF;
  SELECT string_agg(policyname, ', ' ORDER BY policyname) INTO v_other
    FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'job_audit_log' AND permissive = 'PERMISSIVE'
     AND cmd IN ('INSERT', 'ALL') AND policyname <> 'd0c_job_audit_log_insert'
     AND roles && ARRAY['authenticated', 'public', 'anon']::name[];
  IF v_other IS NOT NULL THEN
    RAISE EXCEPTION 'job_audit_log has another permissive INSERT/ALL policy (%): D0c is not applied or a policy was added by hand; this migration would have no effect', v_other
      USING ERRCODE = '55000';
  END IF;
END $$;

DROP POLICY IF EXISTS d0c_job_audit_log_insert ON public.job_audit_log;
CREATE POLICY d0c_job_audit_log_insert ON public.job_audit_log
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND (SELECT public.user_has_perm('ops:work-orders:write'))
    AND action_type NOT LIKE 'staff.access.%'
    AND action_type NOT IN ('baseline_locked', 'baseline_reset', 'visibility_changed', 'schedule_exported', 'schedule_imported')
    AND job_id IS NOT NULL
    AND job_id IN (SELECT j.id FROM public.jobs j WHERE j.company_id IN (SELECT public.my_company_ids()))
  );
COMMENT ON POLICY d0c_job_audit_log_insert ON public.job_audit_log IS
  'Insert from a session: own user_id, write atom, own-company job, no staff.access.* and no reserved action type (baseline_locked, baseline_reset, visibility_changed, schedule_exported, schedule_imported: written only by database functions). Add every new function-written action type to the list in a new migration; see scripts/verify-audit-reserved.mjs.';
