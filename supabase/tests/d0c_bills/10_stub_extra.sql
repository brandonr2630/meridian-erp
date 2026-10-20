-- d0c_bills family stub: real shapes of bills / bill_edit_events / bill_lines_archive on top of the D0a stub (live columns, 2026-10-20).

-- roles: live atom sets (only the atoms relevant to bills; others irrelevant here)
UPDATE erp_roles SET permissions = '{"ops:work-orders:read":true,"ops:work-orders:write":true,"ops:costing:read":true,"ops:costing:write":true}'::jsonb WHERE name='operations_tech';
UPDATE erp_roles SET permissions = '{"finance:ap:read":true,"finance:ar:read":true,"ops:work-orders:read":true}'::jsonb WHERE name='viewer';
UPDATE erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"ops:work-orders:read":true}'::jsonb WHERE name='company_admin';
UPDATE erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"ops:work-orders:read":true}'::jsonb WHERE name='super_admin';
UPDATE erp_roles SET permissions = '{"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"sales:vendors:write":true}'::jsonb WHERE name='Office Admin';
INSERT INTO erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','finance_manager','{"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:reports:read":true}'),
 ('a0000000-0000-0000-0000-000000000008','settings_only','{"admin:settings":true,"finance:ap:read":true}'),
 ('a0000000-0000-0000-0000-000000000009','users_only','{"admin:users":true,"finance:ap:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','sales_rep','{"finance:ar:read":true,"sales:quotes:read":true,"sales:quotes:write":true}');
-- more staff: finance_manager C1, sales_rep C1, company_admin C2; third company C3 (super is NOT a member)
INSERT INTO companies (id, name) VALUES ('c3000000-0000-0000-0000-000000000003','C3');
INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000008','88880000-0000-0000-0000-000000000008','finance C1', true),
 ('e0000000-0000-0000-0000-000000000009','99990000-0000-0000-0000-000000000009','sales C1', true),
 ('e0000000-0000-0000-0000-00000000000a','aaaa0000-0000-0000-0000-00000000000a','admin C2', true),
 ('e0000000-0000-0000-0000-00000000000b','bbbb0000-0000-0000-0000-00000000000b','settings-only admin C1', true),
 ('e0000000-0000-0000-0000-00000000000c','cccc0000-0000-0000-0000-00000000000c','users-only admin C1', true);
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000006'),
 ('e0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000007'),
 ('e0000000-0000-0000-0000-00000000000a','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-00000000000b','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000008'),
 ('e0000000-0000-0000-0000-00000000000c','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000009'),
 -- the live super admin belongs to several companies: add C2 for the stub super
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- real tables
DROP TABLE IF EXISTS public.bill_lines_archive CASCADE;
DROP TABLE IF EXISTS public.bill_edit_events CASCADE;
CREATE TABLE public.bills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid NOT NULL, bill_no text, status text DEFAULT 'draft', total numeric DEFAULT 0
);
CREATE TABLE public.bill_edit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bill_id uuid NOT NULL REFERENCES public.bills(id) ON DELETE CASCADE,
  edited_by uuid,
  edited_at timestamptz NOT NULL DEFAULT now(),
  reason text NOT NULL
);
CREATE TABLE public.bill_lines_archive (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  edit_event_id uuid NOT NULL REFERENCES public.bill_edit_events(id) ON DELETE CASCADE,
  original_line_id uuid, description text, quantity numeric, unit_price numeric, amount numeric, line_order integer,
  item_category text, item_id uuid, created_at timestamptz NOT NULL DEFAULT now(), po_id uuid, po_line_id uuid
);
ALTER TABLE public.bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bill_edit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bill_lines_archive ENABLE ROW LEVEL SECURITY;
-- live bills policy (roles = public)
CREATE POLICY rls_bills ON public.bills FOR ALL
  USING (is_super_admin() OR (company_id IN (SELECT my_company_ids())))
  WITH CHECK (is_super_admin() OR (company_id IN (SELECT my_company_ids())));
-- legacy open policy + D0a restrictive pair
CREATE POLICY "authenticated users full access" ON public.bill_edit_events FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "authenticated users full access" ON public.bill_lines_archive FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY d0_staff_only ON public.bill_edit_events AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()));
CREATE POLICY d0_no_anon    ON public.bill_edit_events AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);
CREATE POLICY d0_staff_only ON public.bill_lines_archive AS RESTRICTIVE FOR ALL TO authenticated USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()));
CREATE POLICY d0_no_anon    ON public.bill_lines_archive AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);
GRANT ALL ON public.bills, public.bill_edit_events, public.bill_lines_archive TO anon, authenticated, service_role;

-- fixtures. users: adm=3333.., sup=4444.. ; bills b1 (C1), b4 (C1 draft, used for the cascade test), b2 (C2), b3 (C3)
INSERT INTO public.bills (id, company_id, bill_no) VALUES
 ('d1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','B-1'),
 ('d4000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000001','B-4'),
 ('d2000000-0000-0000-0000-000000000002','c2000000-0000-0000-0000-000000000002','B-2'),
 ('d3000000-0000-0000-0000-000000000003','c3000000-0000-0000-0000-000000000003','B-3');
INSERT INTO public.bill_edit_events (id, bill_id, edited_by, reason) VALUES
 ('f1000000-0000-0000-0000-000000000001','d1000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','e1 by adm (C1)'),
 ('f1500000-0000-0000-0000-000000000015','d1000000-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444','e1s by sup (C1)'),
 ('f4000000-0000-0000-0000-000000000004','d4000000-0000-0000-0000-000000000004','33333333-3333-3333-3333-333333333333','e4 (C1 draft bill)'),
 ('f2000000-0000-0000-0000-000000000002','d2000000-0000-0000-0000-000000000002','aaaa0000-0000-0000-0000-00000000000a','e2 by adm2 (C2)'),
 ('f3000000-0000-0000-0000-000000000003','d3000000-0000-0000-0000-000000000003','aaaa0000-0000-0000-0000-00000000000a','e3 (C3)'),
 -- historic events: authored by a caller who is NOT an admin (fin, e5), and by a C1 admin on a C2 bill (e6)
 ('f5000000-0000-0000-0000-000000000005','d1000000-0000-0000-0000-000000000001','88880000-0000-0000-0000-000000000008','e5 by finance_manager (C1)'),
 ('f6000000-0000-0000-0000-000000000006','d2000000-0000-0000-0000-000000000002','33333333-3333-3333-3333-333333333333','e6 by C1 admin on C2 bill');
INSERT INTO public.bill_lines_archive (id, edit_event_id, description, quantity, unit_price, amount, line_order) VALUES
 ('a1000000-0000-0000-0000-000000000001','f1000000-0000-0000-0000-000000000001','a1',1,10,10,1),
 ('a1500000-0000-0000-0000-000000000015','f1500000-0000-0000-0000-000000000015','a1s',1,10,10,1),
 ('a4000000-0000-0000-0000-000000000004','f4000000-0000-0000-0000-000000000004','a4',1,10,10,1),
 ('a2000000-0000-0000-0000-000000000002','f2000000-0000-0000-0000-000000000002','a2',1,10,10,1),
 ('a3000000-0000-0000-0000-000000000003','f3000000-0000-0000-0000-000000000003','a3',1,10,10,1);
