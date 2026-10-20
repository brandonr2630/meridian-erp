-- d0c_jobs family stub: real `jobs` columns (live 2026-10-20), live atom sets for the 7 roles, extra staff, extra fixtures.
-- jobs is ALTERed (not dropped) so the D0a storage policy that references it survives. Legacy open policy + D0a restrictive pair already exist.

ALTER TABLE public.jobs
  ADD COLUMN IF NOT EXISTS job_category text, ADD COLUMN IF NOT EXISTS job_type text, ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'Open', ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'Normal',
  ADD COLUMN IF NOT EXISTS customer text, ADD COLUMN IF NOT EXISTS contact text, ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS email text, ADD COLUMN IF NOT EXISTS date_received date, ADD COLUMN IF NOT EXISTS due_date date,
  ADD COLUMN IF NOT EXISTS description text, ADD COLUMN IF NOT EXISTS part_name text, ADD COLUMN IF NOT EXISTS customer_po text,
  ADD COLUMN IF NOT EXISTS accepted_by text, ADD COLUMN IF NOT EXISTS modified_by text, ADD COLUMN IF NOT EXISTS payment_terms text,
  ADD COLUMN IF NOT EXISTS misc_ttd numeric(12,2) NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS costing_notes text,
  ADD COLUMN IF NOT EXISTS date_completed date, ADD COLUMN IF NOT EXISTS qc_state jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS drawings jsonb NOT NULL DEFAULT '[]', ADD COLUMN IF NOT EXISTS specs jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS reports jsonb NOT NULL DEFAULT '[]', ADD COLUMN IF NOT EXISTS created_by uuid,
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(), ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS overdue_notified_at timestamptz;
ALTER TABLE public.jobs ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.jobs ALTER COLUMN job_no SET NOT NULL;
ALTER TABLE public.jobs ADD CONSTRAINT jobs_company_id_job_no_key UNIQUE (company_id, job_no);
ALTER TABLE public.jobs ADD CONSTRAINT jobs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT;

-- live atom sets (global role rows)
UPDATE public.erp_roles SET permissions = '{"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:deliveries:read":true,"sales:deliveries:write":true}'::jsonb WHERE name='operations_tech';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ar:read":true,"finance:bank:read":true,"finance:coa:read":true,"finance:ledger:read":true,"finance:reports:read":true,"ops:costing:read":true,"ops:delivery:read":true,"ops:work-orders:read":true,"sales:clients:read":true,"sales:crm:read":true,"sales:deliveries:read":true,"sales:orders:read":true,"sales:quotes:read":true,"sales:vendors:read":true}'::jsonb WHERE name='viewer';
UPDATE public.erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ar:read":true,"finance:ar:write":true,"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:quotes:read":true,"sales:quotes:write":true}'::jsonb WHERE name='company_admin';
UPDATE public.erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:ar:read":true,"finance:ar:write":true,"ops:costing:read":true,"ops:costing:write":true,"ops:delivery:read":true,"ops:delivery:write":true,"ops:work-orders:approve":true,"ops:work-orders:read":true,"ops:work-orders:write":true,"sales:quotes:read":true,"sales:quotes:write":true}'::jsonb WHERE name='super_admin';
UPDATE public.erp_roles SET permissions = '{"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"sales:vendors:write":true}'::jsonb WHERE name='Office Admin';
INSERT INTO public.erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','finance_manager','{"finance:ap:read":true,"finance:ap:write":true,"finance:ap:approve":true,"finance:ap:void":true,"finance:ar:read":true,"finance:ar:write":true,"finance:bank:read":true,"finance:bank:write":true,"finance:coa:read":true,"finance:coa:write":true,"finance:ledger:read":true,"finance:ledger:write":true,"finance:reports:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','sales_rep','{"finance:ar:read":true,"sales:clients:read":true,"sales:clients:write":true,"sales:crm:read":true,"sales:crm:write":true,"sales:orders:read":true,"sales:orders:write":true,"sales:orders:approve":true,"sales:quotes:read":true,"sales:quotes:write":true,"sales:quotes:approve":true}');

-- extra staff: 8 finance_manager C1, 9 sales_rep C1, 10 company_admin C2, 11 mixed (company_admin in C1 + operations_tech in C2)
INSERT INTO public.erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000008','88888888-8888-8888-8888-888888888888','finance C1', true),
 ('e0000000-0000-0000-0000-000000000009','99999999-9999-9999-9999-999999999999','sales C1', true),
 ('e0000000-0000-0000-0000-000000000010','10101010-1010-1010-1010-101010101010','admin C2', true),
 ('e0000000-0000-0000-0000-000000000011','11111111-aaaa-1111-1111-111111111111','mixed C1 admin / C2 ops', true);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000006'),
 ('e0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000007'),
 ('e0000000-0000-0000-0000-000000000010','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000011','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000011','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001'),
 -- the multi-company super admin (like live "Brandon"): also a member of C2
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- extra fixtures: 4 more C1 jobs (disposable for delete/update tests) and 1 more C2 job. After: C1 = 5 jobs, C2 = 2 jobs.
INSERT INTO public.jobs (id, company_id, job_no, status, priority, customer, quoted_ttd, costing_notes) VALUES
 ('b1000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','WO-003','Open','Normal','Cust 3',300,'secret 3'),
 ('b1000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000001','WO-004','Open','Normal','Cust 4',400,'secret 4'),
 ('b1000000-0000-0000-0000-000000000005','c1000000-0000-0000-0000-000000000001','WO-005','Open','Normal','Cust 5',500,'secret 5'),
 ('b1000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000001','WO-006','Open','Normal','Cust 6',600,'secret 6'),
 ('b2000000-0000-0000-0000-000000000007','c2000000-0000-0000-0000-000000000002','WO-007','Open','Normal','Cust 7',700,'secret 7');
UPDATE public.jobs SET customer='Cust 1' WHERE id='b1000000-0000-0000-0000-000000000001';
UPDATE public.jobs SET customer='Cust 2' WHERE id='b2000000-0000-0000-0000-000000000002';
