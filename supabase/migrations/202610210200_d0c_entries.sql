-- D0c (entries family): company- and permission-scoped RLS for the 7 job-card entry tables.
--   labour_entries, material_entries, consumable_entries, equipment_entries, hardware_entries, tooling_entries,
--   subcontractor_entries
--
-- Before: each table carries the legacy PERMISSIVE policy "authenticated users full access" (FOR ALL, constant-true clauses); D0a's RESTRICTIVE d0_staff_only / d0_no_anon pair limits it to active staff, but every
-- active staff member could read and write every company's entries.
-- After: rows are reachable only through a job of one of the caller's companies, and
--   SELECT                 needs ops:work-orders:read OR ops:work-orders:write
--   INSERT / UPDATE / DELETE needs ops:work-orders:write  (the job-card save rewrites entries: delete by job_id, then insert)
-- The entry tables have no company_id; the company path is entry.job_id -> jobs.company_id. The jobs subquery runs under
-- the caller's own RLS on jobs, so these policies behave the same whether jobs is still open or later scoped (d0c_jobs);
-- the explicit company filter keeps them scoped even while jobs is open.
-- user_has_perm() is NOT company scoped (atom held in any of the caller's roles); my_company_ids() carries the tenancy.
-- The d0_staff_only / d0_no_anon restrictive policies are untouched. Idempotent. Rollback:
-- supabase/rollbacks/202610210200_d0c_entries_down.sql

DO $$
DECLARE
  t text;
  tables text[] := ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries',
                         'hardware_entries','tooling_entries','subcontractor_entries'];
  in_company text := 'job_id IN (SELECT j.id FROM public.jobs j WHERE j.company_id IN (SELECT public.my_company_ids()))';
  can_read   text := '((SELECT public.user_has_perm(''ops:work-orders:read'')) OR (SELECT public.user_has_perm(''ops:work-orders:write'')))';
  can_write  text := '(SELECT public.user_has_perm(''ops:work-orders:write''))';
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS "authenticated users full access" ON public.%I', t);

    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_select ON public.%I', t, t);
    EXECUTE format('CREATE POLICY d0c_%s_select ON public.%I FOR SELECT TO authenticated USING (%s AND %s)',
                   t, t, can_read, in_company);

    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_insert ON public.%I', t, t);
    EXECUTE format('CREATE POLICY d0c_%s_insert ON public.%I FOR INSERT TO authenticated WITH CHECK (%s AND %s)',
                   t, t, can_write, in_company);

    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_update ON public.%I', t, t);
    EXECUTE format('CREATE POLICY d0c_%s_update ON public.%I FOR UPDATE TO authenticated USING (%s AND %s) WITH CHECK (%s AND %s)',
                   t, t, can_write, in_company, can_write, in_company);

    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_delete ON public.%I', t, t);
    EXECUTE format('CREATE POLICY d0c_%s_delete ON public.%I FOR DELETE TO authenticated USING (%s AND %s)',
                   t, t, can_write, in_company);
  END LOOP;
END $$;
