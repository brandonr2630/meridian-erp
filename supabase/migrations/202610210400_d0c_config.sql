-- D0c (config family): replace the legacy open permissive policies on the shared catalogs, employees and notification_types
-- with permission-scoped ones. The D0a RESTRICTIVE d0_staff_only / d0_no_anon policies are NOT touched (they still AND with these).
--
-- Tables: config_consumables, config_equipment, config_fuel, config_hardware, config_labour, config_materials,
--         config_qc_checklists, config_tasks, config_tooling, employees, notification_types.
-- All eleven are GLOBAL (no company_id): scope = active staff (D0a) + permission atoms (below).
--
-- Access model (derived from index.html, 2026-10-20; see PR body for the code paths):
--   * Job Config screen (loadJobConfig) is admin only: isAdmin() = admin:users OR admin:settings. It inserts, edits and deletes catalog rows
--     and employees. So INSERT / UPDATE / DELETE on all ten editable tables = admin.
--   * Catalog pickers (jcLoadConfig) run for everyone who opens Work Orders (ops:work-orders:read), the AP bill form
--     (finance:ap:read) and the Job Config screen (admin). They read the nine catalogs and employees (names for the labour dropdown).
--   * Bill approval (jcSyncBillLineCatalog) writes the catalogs from the bill form: INSERT a new approved item into config_equipment /
--     config_materials / config_hardware / config_consumables / config_tooling, and UPDATE default_unit_cost_ttd on the four cost
--     catalogs. The UI lets anyone on the AP page do this; the policies require finance:ap:write (owner decision recorded in the PR).
--   * notification_types is read by every staff member (Settings > Notifications) and written by nobody through the API
--     (edge functions read it with the service role, which bypasses RLS). No write policy, exactly as today.
-- Rollback: supabase/rollbacks/202610210400_d0c_config_down.sql

DO $$
DECLARE
  t   text;
  adm text := '((SELECT public.user_has_perm(''admin:users'')) OR (SELECT public.user_has_perm(''admin:settings'')))';
  rd  text := '((SELECT public.user_has_perm(''ops:work-orders:read'')) OR (SELECT public.user_has_perm(''finance:ap:read'')) OR (SELECT public.user_has_perm(''admin:users'')) OR (SELECT public.user_has_perm(''admin:settings'')))';
  ap  text := '(SELECT public.user_has_perm(''finance:ap:write''))';
BEGIN
  -- ── the nine catalogs + employees: read set / admin writes ──
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour',
                           'config_materials','config_qc_checklists','config_tasks','config_tooling','employees']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "authenticated users full access" ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_select', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_insert', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_update', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_delete', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)', 'd0c_' || t || '_select', t, rd);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (%s)', 'd0c_' || t || '_insert', t, adm);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)', 'd0c_' || t || '_update', t, adm, adm);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (%s)', 'd0c_' || t || '_delete', t, adm);
  END LOOP;

  -- ── bill approval: AP writers may add a new approved item the bill is linked to (their own submission) ──
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_hardware','config_materials','config_tooling']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_insert_ap', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (%s AND submitted_by = (SELECT auth.uid()))',
                   'd0c_' || t || '_insert_ap', t, ap);
  END LOOP;

  -- ── bill approval: AP writers may re-price an approved item (default_unit_cost_ttd); the row must stay approved ──
  FOREACH t IN ARRAY ARRAY['config_consumables','config_hardware','config_materials','config_tooling']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'd0c_' || t || '_update_ap', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (%s AND status = ''approved'') WITH CHECK (%s AND status = ''approved'')',
                   'd0c_' || t || '_update_ap', t, ap, ap);
  END LOOP;
END $$;

-- ── notification_types: staff read, no API writes (as today) ──
DROP POLICY IF EXISTS notif_types_read ON public.notification_types;
DROP POLICY IF EXISTS d0c_notification_types_select ON public.notification_types;
CREATE POLICY d0c_notification_types_select ON public.notification_types FOR SELECT TO authenticated
  USING ((SELECT public.is_erp_staff()));
