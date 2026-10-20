-- d0c_entries stub: the 7 entry tables with their REAL live columns (pg_attribute, 2026-10-20), FKs to jobs (cascade),
-- the legacy open policy, the D0a restrictive pair and grants; live role atom sets; extra identities; fixtures.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP EXECUTE format('DROP TABLE IF EXISTS public.%I CASCADE', t); END LOOP;
END $$;

CREATE TABLE public.labour_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, classification text, technician text,
  location text NOT NULL DEFAULT 'Workshop', start_time time, end_time time,
  hours numeric(8,2) NOT NULL DEFAULT 0, rate_ttd numeric(10,2) NOT NULL DEFAULT 0, amount_ttd numeric(12,2) NOT NULL DEFAULT 0,
  is_overtime boolean NOT NULL DEFAULT false, tasks jsonb NOT NULL DEFAULT '[]'::jsonb, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.equipment_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, machine_name text, asset_no text,
  location text NOT NULL DEFAULT 'Workshop', setup_hours numeric(8,2) NOT NULL DEFAULT 0, run_hours numeric(8,2) NOT NULL DEFAULT 0,
  rate_ttd numeric(10,2) NOT NULL DEFAULT 0, amount_ttd numeric(12,2) NOT NULL DEFAULT 0, tasks jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(), fuel_type text, fuel_qty numeric NOT NULL DEFAULT 0,
  fuel_unit_cost_ttd numeric NOT NULL DEFAULT 0, fuel_amount_ttd numeric NOT NULL DEFAULT 0);
CREATE TABLE public.material_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, description text, stock_code text,
  quantity numeric(10,3) NOT NULL DEFAULT 0, unit text, unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0,
  total_cost_ttd numeric(12,2) NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.consumable_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, description text, category text,
  quantity numeric(10,3) NOT NULL DEFAULT 0, unit text, unit_cost_ttd numeric(10,2) NOT NULL DEFAULT 0,
  total_cost_ttd numeric(12,2) NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.hardware_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, description text, spec text,
  quantity numeric NOT NULL DEFAULT 0, unit text, unit_cost_ttd numeric NOT NULL DEFAULT 0,
  total_cost_ttd numeric NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.tooling_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, description text, stock_code text,
  quantity numeric NOT NULL DEFAULT 0, unit text, unit_cost_ttd numeric NOT NULL DEFAULT 0,
  total_cost_ttd numeric NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.subcontractor_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES public.jobs(id) ON DELETE CASCADE,
  sort_order integer NOT NULL DEFAULT 0, entry_date date, name text, service_description text, invoice_ref text,
  cost_ttd numeric(12,2) NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY "authenticated users full access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    EXECUTE format('CREATE POLICY d0_staff_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()))', t);
    EXECUTE format('CREATE POLICY d0_no_anon ON public.%I AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false)', t);
    EXECUTE format('GRANT ALL ON public.%I TO anon, authenticated, service_role', t);
  END LOOP;
END $$;

-- live atom sets (contract section 3)
UPDATE erp_roles SET permissions = '{"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:deliveries:read":true,"sales:deliveries:write":true}'::jsonb WHERE name='operations_tech';
UPDATE erp_roles SET permissions = '{"finance:ap:read":true,"finance:ar:read":true,"finance:bank:read":true,"finance:coa:read":true,"finance:ledger:read":true,"finance:reports:read":true,"ops:costing:read":true,"ops:delivery:read":true,"ops:work-orders:read":true,"sales:clients:read":true,"sales:crm:read":true,"sales:deliveries:read":true,"sales:orders:read":true,"sales:quotes:read":true,"sales:vendors:read":true}'::jsonb WHERE name='viewer';
UPDATE erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ar:read":true,"finance:ar:write":true,"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:quotes:read":true,"sales:quotes:write":true}'::jsonb WHERE name='company_admin';
UPDATE erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ar:read":true,"finance:ar:write":true,"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:quotes:read":true,"sales:quotes:write":true}'::jsonb WHERE name='super_admin';
UPDATE erp_roles SET permissions = '{"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"sales:vendors:write":true}'::jsonb WHERE name='Office Admin';
INSERT INTO erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','finance_manager','{"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:ar:write":true,"finance:bank:read":true,"finance:bank:write":true,"finance:coa:read":true,"finance:coa:write":true,"finance:ledger:read":true,"finance:ledger:write":true,"finance:reports:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','sales_rep','{"finance:ar:read":true,"sales:clients:read":true,"sales:clients:write":true,"sales:crm:read":true,"sales:crm:write":true,"sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,"sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true}');
INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000008','99999999-9999-9999-9999-999999999999','finance C1', true),
 ('e0000000-0000-0000-0000-000000000009','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','sales C1', true);
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000006'),
 ('e0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000007'),
 -- the multi-company super admin (live: 3 companies) also belongs to company 2
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- fixtures: one entry row per table per job (j1 = company 1, j2 = company 2)
DO $$
DECLARE t text; j text;
BEGIN
  FOREACH t IN ARRAY ARRAY['labour_entries','material_entries','consumable_entries','equipment_entries','hardware_entries','tooling_entries','subcontractor_entries']
  LOOP
    FOREACH j IN ARRAY ARRAY['b1000000-0000-0000-0000-000000000001','b2000000-0000-0000-0000-000000000002']
    LOOP EXECUTE format('INSERT INTO public.%I (job_id) VALUES (%L)', t, j); END LOOP;
  END LOOP;
END $$;
