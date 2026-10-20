-- Rollback for D0c entries: drop the d0c_* policies and restore the exact legacy open policy on the 7 entry tables.
-- (d0_staff_only / d0_no_anon from D0a stay.)
DO $$
DECLARE
  t text;
  tables text[] := ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries',
                         'hardware_entries','tooling_entries','subcontractor_entries'];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_select ON public.%I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_insert ON public.%I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_update ON public.%I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS d0c_%s_delete ON public.%I', t, t);
    EXECUTE format('DROP POLICY IF EXISTS "authenticated users full access" ON public.%I', t);
    EXECUTE format('CREATE POLICY "authenticated users full access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;
