-- D0a: staff-only hardening (project-portal spec, Phase D section D0; contract X17, X18, X23).
--
-- What this does (all additive or policy-only; no table data is touched):
--   1. is_erp_staff(): true only for an authenticated user with an ACTIVE erp_users row.
--   2. RESTRICTIVE policies d0_staff_only / d0_no_anon on the 21 tables that carry the legacy
--      "authenticated users full access" (USING true) policy, plus notification_types.
--      Restrictive policies are ANDed with the existing permissive ones, so active staff keep exactly
--      what they have today; users with no active erp_users row (clients, removed staff, strays) get nothing.
--   3. Storage: the bucket-only job-drawings and company-logos policies are replaced with tenant-scoped,
--      permission-checked ones, plus RESTRICTIVE staff-only / anon-deny guards on the ERP buckets.
--   4. Definer-function hardening: pin search_path, REVOKE anon/PUBLIC on next_job_no() and is_company_admin(uuid),
--      and a staff check inside next_job_no().
--   5. Index used by later per-user rate limiting.
--
-- Verified live 2026-10-19/20 (read-only): all 4 auth users have an active erp_users row, so nobody is locked out;
-- the live my_company_ids()/is_super_admin()/user_has_perm() already filter is_active (no body change needed).
-- Rollback: supabase/rollbacks/202610200900_d0a_down.sql
-- Not covered here (D0c, later): replacing the legacy permissive policies with company/permission scoped ones.

-- ── 1. staff identity ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_erp_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.erp_users eu WHERE eu.auth_user_id = auth.uid() AND eu.is_active);
$$;
REVOKE ALL ON FUNCTION public.is_erp_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_erp_staff() TO authenticated;

-- ── 2. restrictive companions on the legacy open tables ─────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','jobs','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types']
  LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE 'D0a: % not found, skipped', t;
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS d0_staff_only ON public.%I', t);
    EXECUTE format('CREATE POLICY d0_staff_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated '
                   'USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()))', t);
    EXECUTE format('DROP POLICY IF EXISTS d0_no_anon ON public.%I', t);
    EXECUTE format('CREATE POLICY d0_no_anon ON public.%I AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false)', t);
  END LOOP;
END $$;

-- ── 3. storage ──────────────────────────────────────────────────────────────
-- job-drawings object keys are <company_id>/<job_id>/<epoch>-<name> (ERP upload path); legacy fallback accepts any
-- object whose name equals a job_drawings.storage_key row in the caller's company, so no existing download breaks.
DROP POLICY IF EXISTS "job-drawings auth read"   ON storage.objects;
DROP POLICY IF EXISTS "job-drawings auth upload" ON storage.objects;
DROP POLICY IF EXISTS "job-drawings auth delete" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated logo upload" ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_select ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_insert ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_delete ON storage.objects;
DROP POLICY IF EXISTS d0_logos_insert ON storage.objects;
DROP POLICY IF EXISTS d0_storage_staff_only ON storage.objects;
DROP POLICY IF EXISTS d0_storage_no_anon ON storage.objects;

CREATE POLICY d0_drawings_select ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'job-drawings' AND public.user_has_perm('ops:work-orders:read') AND (
          (storage.foldername(name))[1] IN (SELECT c::text FROM public.my_company_ids() c)
       OR EXISTS (SELECT 1 FROM public.job_drawings d
                   WHERE d.storage_key = storage.objects.name AND d.company_id IN (SELECT public.my_company_ids()))));

CREATE POLICY d0_drawings_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'job-drawings'
              AND public.user_has_perm('ops:work-orders:write')
              AND (storage.foldername(name))[1] IN (SELECT c::text FROM public.my_company_ids() c)
              AND EXISTS (SELECT 1 FROM public.jobs j
                           WHERE j.id::text = (storage.foldername(storage.objects.name))[2]
                             AND j.company_id::text = (storage.foldername(storage.objects.name))[1]));

CREATE POLICY d0_drawings_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'job-drawings' AND (
          EXISTS (SELECT 1 FROM public.companies co
                   WHERE co.id::text = (storage.foldername(storage.objects.name))[1] AND public.is_company_admin(co.id))
       OR EXISTS (SELECT 1 FROM public.job_drawings d
                   WHERE d.storage_key = storage.objects.name AND public.is_company_admin(d.company_id))));
-- No UPDATE policy (none exists today): an existing object cannot be overwritten by any JWT.

CREATE POLICY d0_logos_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'company-logos' AND (
          public.is_super_admin()
       OR CASE WHEN name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-'
               THEN public.is_company_admin(left(name, 36)::uuid) ELSE false END));

CREATE POLICY d0_storage_staff_only ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
  USING (bucket_id NOT IN ('job-drawings','company-logos','job-updates') OR (SELECT public.is_erp_staff()))
  WITH CHECK (bucket_id NOT IN ('job-drawings','company-logos','job-updates') OR (SELECT public.is_erp_staff()));
CREATE POLICY d0_storage_no_anon ON storage.objects AS RESTRICTIVE FOR ALL TO anon
  USING (bucket_id NOT IN ('job-drawings','company-logos','job-updates'))
  WITH CHECK (bucket_id NOT IN ('job-drawings','company-logos','job-updates'));
-- Public logo URLs (/object/public/...) do not evaluate RLS and keep working.

-- ── 4. definer function hardening ───────────────────────────────────────────
ALTER FUNCTION public.my_company_ids()    SET search_path = public, pg_temp;
ALTER FUNCTION public.is_super_admin()    SET search_path = public, pg_temp;
ALTER FUNCTION public.user_has_perm(text) SET search_path = public, pg_temp;

-- next_job_no(): live body (nextval of job_no_seq, 'WO-' + 3-digit pad) plus a staff check as the first statement.
CREATE OR REPLACE FUNCTION public.next_job_no()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_next bigint;
BEGIN
  IF NOT public.is_erp_staff() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  v_next := nextval('job_no_seq');
  RETURN 'WO-' || LPAD(v_next::text, 3, '0');
END;
$$;
REVOKE ALL ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) TO authenticated;

-- ── 5. rate-limit support index (additive) ──────────────────────────────────
CREATE INDEX IF NOT EXISTS job_audit_log_user_created_idx ON public.job_audit_log (user_id, created_at DESC);
