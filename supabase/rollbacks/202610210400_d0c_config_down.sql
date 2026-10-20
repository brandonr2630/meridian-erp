-- Rollback for 202610210400_d0c_config.sql: drops the d0c_* policies and restores the exact legacy open policies.
DO $$
DECLARE t text; s text;
BEGIN
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour',
                           'config_materials','config_qc_checklists','config_tasks','config_tooling','employees']
  LOOP
    FOREACH s IN ARRAY ARRAY['select','insert','update','delete','insert_ap','update_ap']
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_' || s, t);
    END LOOP;
    EXECUTE format('DROP POLICY IF EXISTS "authenticated users full access" ON public.%I', t);
    EXECUTE format('CREATE POLICY "authenticated users full access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;

DROP POLICY IF EXISTS d0c_notification_types_select ON public.notification_types;
DROP POLICY IF EXISTS notif_types_read ON public.notification_types;
CREATE POLICY notif_types_read ON public.notification_types FOR SELECT TO authenticated USING (true);
