-- Family stub: a SECURITY DEFINER function standing in for the real writers (lock_job_baseline, job_visibility_guard, schedule_export_core,
-- import_job_schedule). It is owned by the migration owner, so it bypasses RLS exactly like they do.
CREATE OR REPLACE FUNCTION public.t_definer_audit(p_job uuid, p_action text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  INSERT INTO public.job_audit_log (job_id, user_id, action_type, description) VALUES (p_job, auth.uid(), p_action, 'written by a function');
  RETURN 1;
END $$;
GRANT EXECUTE ON FUNCTION public.t_definer_audit(uuid, text) TO authenticated;
