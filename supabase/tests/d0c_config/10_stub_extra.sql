-- d0c_config stub: real live shapes of the 11 tables (pg_attribute, 2026-10-20), legacy policies, D0a pair, live role atom sets, fixtures.
DROP TABLE IF EXISTS public.config_consumables, public.config_equipment, public.config_fuel, public.config_hardware, public.config_labour,
  public.config_materials, public.config_qc_checklists, public.config_tasks, public.config_tooling, public.employees,
  public.notification_types CASCADE;

CREATE TABLE public.config_consumables (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_name text NOT NULL, category text, unit text,
  default_unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved',
  is_active boolean NOT NULL DEFAULT true, submitted_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_equipment (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), equipment_name text NOT NULL, description_type text, make text,
  model_no text, serial_no text, shop_number text, year_of_manufacture integer, date_of_acquisition date, capacity_size text,
  workshop_rate_ttd numeric(10,2) NOT NULL DEFAULT 0, onsite_rate_ttd numeric(10,2) NOT NULL DEFAULT 0, accessories jsonb NOT NULL DEFAULT '[]'::jsonb,
  power_type text, mobility_type text, tyre_size text, tyre_qty integer, hp_kw numeric(8,2), voltage numeric(8,2), amps numeric(8,2), frequency numeric(8,2),
  phase_type text, electric_notes text, fuel_capacity numeric(8,2), fuel_filter_no text, fuel_filter_qty integer, engine_oil_filter_no text,
  engine_oil_filter_qty integer, hydraulic_filter_no text, hydraulic_filter_qty integer, coolant_spec text, coolant_capacity numeric(8,2),
  engine_oil_spec text, engine_oil_capacity numeric(8,2), hydraulic_oil_spec text, hydraulic_oil_capacity numeric(8,2),
  sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved', is_active boolean NOT NULL DEFAULT true, submitted_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_fuel (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_name text NOT NULL, unit text NOT NULL DEFAULT 'litre',
  default_unit_cost_ttd numeric NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved',
  is_active boolean NOT NULL DEFAULT true, submitted_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_hardware (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_name text NOT NULL, spec text, unit text,
  default_unit_cost_ttd numeric NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved',
  is_active boolean NOT NULL DEFAULT true, submitted_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_labour (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), classification text NOT NULL,
  workshop_rate_ttd numeric(10,2) NOT NULL DEFAULT 0, onsite_rate_ttd numeric(10,2) NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'approved', is_active boolean NOT NULL DEFAULT true, submitted_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_materials (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_name text NOT NULL, stock_code text, unit text,
  default_unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved',
  is_active boolean NOT NULL DEFAULT true, submitted_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_qc_checklists (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), checklist_item text NOT NULL, job_type text,
  sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved', is_active boolean NOT NULL DEFAULT true, submitted_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_tasks (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), task_name text NOT NULL, category text,
  sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved', is_active boolean NOT NULL DEFAULT true, submitted_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.config_tooling (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), item_name text NOT NULL, stock_code text, unit text,
  default_unit_cost_ttd numeric NOT NULL DEFAULT 0, sort_order integer NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'approved',
  is_active boolean NOT NULL DEFAULT true, submitted_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.employees (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL, job_classification text, nationality text,
  date_of_birth date, date_of_employment date, contact_no text, address text, email text, next_of_kin text, next_of_kin_contact text,
  created_by uuid, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.notification_types (event_key text PRIMARY KEY, label text NOT NULL, subject_tpl text NOT NULL, body_html text NOT NULL,
  recipient text NOT NULL, enabled boolean DEFAULT true);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['config_consumables','config_equipment','config_fuel','config_hardware','config_labour','config_materials',
    'config_qc_checklists','config_tasks','config_tooling','employees','notification_types']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    IF t <> 'notification_types' THEN
      EXECUTE format('CREATE POLICY "authenticated users full access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    END IF;
    EXECUTE format('CREATE POLICY d0_staff_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()))', t);
    EXECUTE format('CREATE POLICY d0_no_anon ON public.%I AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false)', t);
    EXECUTE format('GRANT ALL ON public.%I TO anon, authenticated, service_role', t);
  END LOOP;
END $$;
CREATE POLICY notif_types_read ON public.notification_types FOR SELECT TO authenticated USING (true);

-- live role atom sets (contract section 3). Office Admin is the live company-specific role; the stub row has no company column.
UPDATE public.erp_roles SET permissions = '{"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:deliveries:read":true,"sales:deliveries:write":true}'::jsonb WHERE name = 'operations_tech';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ar:read":true,"finance:bank:read":true,"finance:coa:read":true,"finance:ledger:read":true,"finance:reports:read":true,"ops:costing:read":true,"ops:delivery:read":true,"ops:work-orders:read":true,"sales:clients:read":true,"sales:crm:read":true,"sales:deliveries:read":true,"sales:orders:read":true,"sales:quotes:read":true,"sales:vendors:read":true}'::jsonb WHERE name = 'viewer';
UPDATE public.erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:ar:write":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"ops:work-orders:approve":true,"sales:quotes:write":true}'::jsonb WHERE name = 'company_admin';
UPDATE public.erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:ar:write":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"ops:work-orders:approve":true,"sales:quotes:write":true}'::jsonb WHERE name = 'super_admin';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"sales:vendors:write":true}'::jsonb WHERE name = 'Office Admin';
INSERT INTO public.erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','finance_manager','{"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:ar:write":true,"finance:bank:read":true,"finance:bank:write":true,"finance:coa:read":true,"finance:coa:write":true,"finance:ledger:read":true,"finance:ledger:write":true,"finance:reports:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','sales_rep','{"finance:ar:read":true,"sales:clients:read":true,"sales:clients:write":true,"sales:crm:read":true,"sales:crm:write":true,"sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,"sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true}'),
 ('a0000000-0000-0000-0000-000000000008','settings_only','{"admin:settings":true}'),
 ('a0000000-0000-0000-0000-000000000009','users_only','{"admin:users":true}');
INSERT INTO public.erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000008','cccccccc-cccc-cccc-cccc-cccccccccccc','finance mgr C1', true),
 ('e0000000-0000-0000-0000-000000000009','dddddddd-dddd-dddd-dddd-dddddddddddd','sales rep C1', true),
 ('e0000000-0000-0000-0000-00000000000a','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','settings only C1', true),
 ('e0000000-0000-0000-0000-00000000000b','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','users only C1', true);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000006'),
 ('e0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000007'),
 ('e0000000-0000-0000-0000-00000000000a','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000008'),
 ('e0000000-0000-0000-0000-00000000000b','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000009'),
 -- the multi-company super admin (live: Brandon belongs to 3 companies)
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- fixtures: two rows per catalog (one approved, one pending), two employees, two notification types
INSERT INTO public.config_consumables (item_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_equipment   (equipment_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_fuel        (item_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_hardware    (item_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_labour      (classification, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_materials   (item_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_qc_checklists (checklist_item, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_tasks       (task_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.config_tooling     (item_name, status) VALUES ('fx-approved','approved'), ('fx-pending','pending');
INSERT INTO public.employees (name, date_of_birth, address, next_of_kin) VALUES ('fx-approved','1990-01-01','1 Main St','NOK A'), ('fx-pending','1991-02-02','2 Main St','NOK B');
INSERT INTO public.notification_types (event_key, label, subject_tpl, body_html, recipient) VALUES
 ('ev1','Event 1','s1','<p>b1</p>','direct'), ('ev2','Event 2','s2','<p>b2</p>','role:admin');
