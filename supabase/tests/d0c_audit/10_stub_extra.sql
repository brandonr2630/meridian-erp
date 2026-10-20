-- d0c_audit family stub: real job_audit_log shape (live pg_attribute/pg_constraint/pg_policy, 2026-10-20) + live role atom sets.
-- Fidelity limit: user_id FK to auth.users is omitted (the stub has no auth.users); job_id FK to jobs ON DELETE SET NULL is kept.

DROP TABLE public.job_audit_log CASCADE;
CREATE TABLE public.job_audit_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id      uuid REFERENCES public.jobs(id) ON DELETE SET NULL,
  job_no      text,
  user_id     uuid,
  username    text,
  action_type text NOT NULL,
  description text,
  metadata    jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.job_audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated users full access" ON public.job_audit_log FOR ALL TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY d0_staff_only ON public.job_audit_log AS RESTRICTIVE FOR ALL TO authenticated
  USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()));
CREATE POLICY d0_no_anon ON public.job_audit_log AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);
GRANT ALL ON public.job_audit_log TO anon, authenticated, service_role;

-- live atom sets (verified 2026-10-20). Stub role names map: operations_tech, viewer, company_admin, super_admin, Office Admin.
UPDATE public.erp_roles SET permissions = '{"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:deliveries:read":true,"sales:deliveries:write":true}'::jsonb WHERE name = 'operations_tech';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ar:read":true,"finance:bank:read":true,"finance:coa:read":true,"finance:ledger:read":true,"finance:reports:read":true,"ops:costing:read":true,"ops:delivery:read":true,"ops:work-orders:read":true,"sales:clients:read":true,"sales:crm:read":true,"sales:deliveries:read":true,"sales:orders:read":true,"sales:quotes:read":true,"sales:vendors:read":true}'::jsonb WHERE name = 'viewer';
UPDATE public.erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:approve":true,"finance:ap:read":true,"finance:ap:void":true,"finance:ap:write":true,"finance:ar:approve":true,"finance:ar:read":true,"finance:ar:void":true,"finance:ar:write":true,"finance:bank:read":true,"finance:bank:write":true,"finance:coa:read":true,"finance:coa:write":true,"finance:ledger:read":true,"finance:ledger:write":true,"finance:reports:read":true,"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:clients:read":true,"sales:clients:write":true,"sales:crm:read":true,"sales:crm:write":true,"sales:deliveries:read":true,"sales:deliveries:write":true,"sales:orders:approve":true,"sales:orders:read":true,"sales:orders:write":true,"sales:quotes:approve":true,"sales:quotes:read":true,"sales:quotes:write":true,"sales:vendors:read":true,"sales:vendors:write":true}'::jsonb WHERE name = 'company_admin';
UPDATE public.erp_roles SET permissions = (SELECT permissions FROM public.erp_roles WHERE name = 'company_admin') || '{"admin:companies":true}'::jsonb WHERE name = 'super_admin';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"sales:vendors:write":true}'::jsonb WHERE name = 'Office Admin';
INSERT INTO public.erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','finance_manager','{"finance:ap:approve":true,"finance:ap:read":true,"finance:ap:void":true,"finance:ap:write":true,"finance:ar:approve":true,"finance:ar:read":true,"finance:ar:void":true,"finance:ar:write":true,"finance:bank:read":true,"finance:bank:write":true,"finance:coa:read":true,"finance:coa:write":true,"finance:ledger:read":true,"finance:ledger:write":true,"finance:reports:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','sales_rep','{"finance:ar:read":true,"sales:clients:read":true,"sales:clients:write":true,"sales:crm:read":true,"sales:crm:write":true,"sales:orders:approve":true,"sales:orders:read":true,"sales:orders:write":true,"sales:quotes:approve":true,"sales:quotes:read":true,"sales:quotes:write":true}');

-- extra identities: finance_manager and sales_rep (company C1); the super admin also belongs to C2 (live: multi-company)
INSERT INTO public.erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000008','f0000000-0000-0000-0000-0000000000f1','finance C1', true),
 ('e0000000-0000-0000-0000-000000000009','5a1e5000-0000-0000-0000-000000000001','sales C1', true);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000006'),
 ('e0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000007'),
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- fixtures: one job-scoped row per company, one service-role style row with job_id NULL
INSERT INTO public.job_audit_log (id, job_id, job_no, user_id, username, action_type, description) VALUES
 ('d1000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','WO-001','11111111-1111-1111-1111-111111111111','ops C1','job_saved','Job WO-001 saved'),
 ('d2000000-0000-0000-0000-000000000002','b2000000-0000-0000-0000-000000000002','WO-002','77777777-7777-7777-7777-777777777777','ops C2','job_saved','Job WO-002 saved');
INSERT INTO public.job_audit_log (id, job_id, user_id, action_type, description, metadata) VALUES
 ('d3000000-0000-0000-0000-000000000003', NULL, '44444444-4444-4444-4444-444444444444','staff.access.remove','remove x: ok','{"outcome":"ok"}');
