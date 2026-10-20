-- Rollback for 202610200900_d0a_staff_only_storage.sql. Restores the exact prior live policies and grants.
-- (is_erp_staff() is kept if later migrations depend on it; drop it only after Phase D is rolled back.)

DROP INDEX IF EXISTS public.job_audit_log_user_created_idx;

-- next_job_no back to its original body, and anon/PUBLIC execute restored (original live state)
CREATE OR REPLACE FUNCTION public.next_job_no()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_next bigint;
BEGIN
  v_next := nextval('job_no_seq');
  RETURN 'WO-' || LPAD(v_next::text, 3, '0');
END;
$$;
GRANT EXECUTE ON FUNCTION public.next_job_no(), public.is_company_admin(uuid) TO PUBLIC, anon;

ALTER FUNCTION public.my_company_ids()    RESET search_path;
ALTER FUNCTION public.is_super_admin()    RESET search_path;
ALTER FUNCTION public.user_has_perm(text) SET search_path = public;

-- storage policies back to the bucket-only originals
DROP POLICY IF EXISTS d0_storage_no_anon     ON storage.objects;
DROP POLICY IF EXISTS d0_storage_staff_only  ON storage.objects;
DROP POLICY IF EXISTS d0_logos_insert        ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_delete     ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_insert     ON storage.objects;
DROP POLICY IF EXISTS d0_drawings_select     ON storage.objects;
CREATE POLICY "Authenticated logo upload" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'company-logos');
CREATE POLICY "job-drawings auth read"    ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'job-drawings');
CREATE POLICY "job-drawings auth upload"  ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'job-drawings');
CREATE POLICY "job-drawings auth delete"  ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'job-drawings');

-- restrictive companions on the 22 tables
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','jobs','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types']
  LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP POLICY IF EXISTS d0_no_anon ON public.%I', t);
      EXECUTE format('DROP POLICY IF EXISTS d0_staff_only ON public.%I', t);
    END IF;
  END LOOP;
END $$;
