-- Stub of the LIVE Terran Group ERP state relevant to D0a, built from read-only queries on 2026-10-19/20.
-- Fidelity limits: storage.objects is a plain table (live is owned by supabase_storage_admin); only columns D0a touches exist;
-- auth.uid() reads request.jwt.claim.sub. Roles, grants, legacy policies and helper-function bodies mirror live.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE storage.buckets (id text PRIMARY KEY, name text, public boolean DEFAULT false);
CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text REFERENCES storage.buckets(id), name text, owner uuid);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE _parts text[];
BEGIN
  SELECT string_to_array(name, '/') INTO _parts;
  RETURN _parts[1:array_length(_parts,1)-1];
END $$;
GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA storage TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION storage.foldername(text) TO anon, authenticated, service_role;

-- live legacy storage policies (bucket-only)
CREATE POLICY "Authenticated logo upload" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'company-logos');
CREATE POLICY "job-drawings auth delete"  ON storage.objects FOR DELETE TO authenticated USING (bucket_id = 'job-drawings');
CREATE POLICY "job-drawings auth read"    ON storage.objects FOR SELECT TO authenticated USING (bucket_id = 'job-drawings');
CREATE POLICY "job-drawings auth upload"  ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'job-drawings');

-- identity / tenancy tables
CREATE TABLE public.companies (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text);
CREATE TABLE public.erp_roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, permissions jsonb);
CREATE TABLE public.erp_users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), auth_user_id uuid, full_name text, is_active boolean DEFAULT true);
CREATE TABLE public.erp_user_company_roles (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, company_id uuid, role_id uuid);
CREATE TABLE public.jobs (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid, job_no text, quoted_ttd numeric);
CREATE TABLE public.job_drawings (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), job_id uuid, company_id uuid, storage_key text, archived boolean NOT NULL DEFAULT false);
CREATE SEQUENCE public.job_no_seq;

-- the other 21 tables: each carries the live open policy
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types']
  LOOP
    EXECUTE format('CREATE TABLE public.%I (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid, note text, user_id uuid, created_at timestamptz DEFAULT now())', t);
  END LOOP;
END $$;

-- an unrelated company-scoped table that D0a must NOT touch (control)
CREATE TABLE public.invoices (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), company_id uuid, note text);

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
  END LOOP;
  -- legacy open policy on the 21 + jobs
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','jobs','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries']
  LOOP
    EXECUTE format('CREATE POLICY "authenticated users full access" ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
  END LOOP;
END $$;
CREATE POLICY notif_types_read ON public.notification_types FOR SELECT TO authenticated USING (true);
-- control table: company scoped via the live pattern (added after helper functions below)

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role;

-- live helper functions (bodies from pg_get_functiondef, 2026-10-20)
CREATE OR REPLACE FUNCTION public.my_company_ids() RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT ucr.company_id FROM erp_users eu JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id
  WHERE eu.auth_user_id = auth.uid() AND eu.is_active = true $$;
CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM erp_users eu JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id
    JOIN erp_roles r ON r.id = ucr.role_id
    WHERE eu.auth_user_id = auth.uid() AND eu.is_active = true AND (r.permissions->>'admin:companies')::boolean = true) $$;
CREATE OR REPLACE FUNCTION public.is_company_admin(cid uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp' AS $$
  SELECT EXISTS (SELECT 1 FROM erp_users eu JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id AND ucr.company_id = cid
    JOIN erp_roles r ON r.id = ucr.role_id
    WHERE eu.auth_user_id = auth.uid() AND eu.is_active = true
      AND ((r.permissions->>'admin:users')::boolean = true OR (r.permissions->>'admin:settings')::boolean = true)) $$;
CREATE OR REPLACE FUNCTION public.user_has_perm(perm text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM erp_users eu JOIN erp_user_company_roles ucr ON ucr.user_id = eu.id
    JOIN erp_roles r ON r.id = ucr.role_id
    WHERE eu.auth_user_id = auth.uid() AND eu.is_active = true AND (r.permissions ->> perm)::boolean = true) $$;
CREATE OR REPLACE FUNCTION public.next_job_no() RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_next bigint;
BEGIN
  v_next := nextval('job_no_seq');
  RETURN 'WO-' || LPAD(v_next::text, 3, '0');
END; $$;

-- live ACLs: user_has_perm/is_super_admin/my_company_ids revoked from PUBLIC+anon; is_company_admin/next_job_no keep PUBLIC
REVOKE ALL ON FUNCTION public.user_has_perm(text), public.is_super_admin(), public.my_company_ids() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.user_has_perm(text), public.is_super_admin(), public.my_company_ids() TO authenticated, service_role;

-- live policies on companies and job_drawings (pg_policies, 2026-10-20); roles = public as live
CREATE POLICY rls_companies ON public.companies FOR ALL
  USING (is_super_admin() OR (id IN (SELECT my_company_ids())))
  WITH CHECK (is_super_admin() OR (id IN (SELECT my_company_ids())));
CREATE POLICY "job_drawings admins delete archived" ON public.job_drawings FOR DELETE
  USING ((company_id IN (SELECT my_company_ids())) AND is_company_admin(company_id) AND (archived = true));
CREATE POLICY "job_drawings admins read all" ON public.job_drawings FOR SELECT
  USING ((company_id IN (SELECT my_company_ids())) AND is_company_admin(company_id));
CREATE POLICY "job_drawings members insert" ON public.job_drawings FOR INSERT
  WITH CHECK (company_id IN (SELECT my_company_ids()));
CREATE POLICY "job_drawings members read active" ON public.job_drawings FOR SELECT
  USING ((company_id IN (SELECT my_company_ids())) AND (archived = false));
CREATE POLICY "job_drawings members update" ON public.job_drawings FOR UPDATE
  USING (company_id IN (SELECT my_company_ids())) WITH CHECK (company_id IN (SELECT my_company_ids()));

CREATE POLICY invoices_scoped ON public.invoices FOR ALL TO authenticated
  USING (company_id IN (SELECT my_company_ids())) WITH CHECK (company_id IN (SELECT my_company_ids()));

-- ── fixtures ───────────────────────────────────────────────────────────────
-- fixed ids so tests are readable
INSERT INTO companies (id, name) VALUES
 ('c1000000-0000-0000-0000-000000000001','C1'), ('c2000000-0000-0000-0000-000000000002','C2');
INSERT INTO erp_roles (id, name, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000001','operations_tech', '{"ops:work-orders:read":true,"ops:work-orders:write":true}'),
 ('a0000000-0000-0000-0000-000000000002','viewer',          '{"ops:work-orders:read":true}'),
 ('a0000000-0000-0000-0000-000000000003','company_admin',   '{"ops:work-orders:read":true,"ops:work-orders:write":true,"admin:users":true,"admin:settings":true}'),
 ('a0000000-0000-0000-0000-000000000004','super_admin',     '{"ops:work-orders:read":true,"ops:work-orders:write":true,"admin:users":true,"admin:settings":true,"admin:companies":true}'),
 ('a0000000-0000-0000-0000-000000000005','Office Admin',    '{"admin:users":true}');
-- staff
INSERT INTO erp_users (id, auth_user_id, full_name, is_active) VALUES
 ('e0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','ops C1', true),
 ('e0000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','viewer C1', true),
 ('e0000000-0000-0000-0000-000000000003','33333333-3333-3333-3333-333333333333','admin C1', true),
 ('e0000000-0000-0000-0000-000000000004','44444444-4444-4444-4444-444444444444','super', true),
 ('e0000000-0000-0000-0000-000000000005','55555555-5555-5555-5555-555555555555','office C1', true),
 ('e0000000-0000-0000-0000-000000000006','66666666-6666-6666-6666-666666666666','removed (inactive)', false),
 ('e0000000-0000-0000-0000-000000000007','77777777-7777-7777-7777-777777777777','ops C2', true);
INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001'),
 ('e0000000-0000-0000-0000-000000000002','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002'),
 ('e0000000-0000-0000-0000-000000000003','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000004','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000004'),
 ('e0000000-0000-0000-0000-000000000005','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000005'),
 ('e0000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001'),
 ('e0000000-0000-0000-0000-000000000007','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001');
-- client-shaped user 88888888-... has NO erp_users row at all
INSERT INTO jobs (id, company_id, job_no, quoted_ttd) VALUES
 ('b1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','WO-001', 1000),
 ('b2000000-0000-0000-0000-000000000002','c2000000-0000-0000-0000-000000000002','WO-002', 2000);
INSERT INTO job_drawings (job_id, company_id, storage_key) VALUES
 ('b1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001','c1000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000001/1-a.pdf'),
 ('b2000000-0000-0000-0000-000000000002','c2000000-0000-0000-0000-000000000002','c2000000-0000-0000-0000-000000000002/b2000000-0000-0000-0000-000000000002/1-b.pdf');
INSERT INTO storage.buckets (id, name, public) VALUES ('job-drawings','job-drawings',false), ('company-logos','company-logos',true);
INSERT INTO storage.objects (bucket_id, name) VALUES
 ('job-drawings','c1000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000001/1-a.pdf'),
 ('job-drawings','c2000000-0000-0000-0000-000000000002/b2000000-0000-0000-0000-000000000002/1-b.pdf'),
 ('company-logos','c1000000-0000-0000-0000-000000000001-1700000000000.png');
-- one row in each open table, one per company
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['bill_edit_events','bill_lines_archive','config_consumables','config_equipment','config_fuel',
    'config_hardware','config_labour','config_materials','config_qc_checklists','config_tasks','config_tooling',
    'consumable_entries','employees','equipment_entries','hardware_entries','job_audit_log','labour_entries',
    'material_entries','subcontractor_entries','tooling_entries','notification_types']
  LOOP
    EXECUTE format('INSERT INTO public.%I (company_id, note) VALUES (''c1000000-0000-0000-0000-000000000001'',''c1''), (''c2000000-0000-0000-0000-000000000002'',''c2'')', t);
  END LOOP;
END $$;
INSERT INTO invoices (company_id, note) VALUES ('c1000000-0000-0000-0000-000000000001','c1'), ('c2000000-0000-0000-0000-000000000002','c2');

-- ── test helpers ───────────────────────────────────────────────────────────
-- t_count(role, sub, sql) -> 'n:<count>' or 'err:<sqlstate>'
CREATE OR REPLACE FUNCTION public.t_count(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') s' INTO n;
    RESET ROLE;
    RETURN 'n:' || n;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'err:' || SQLSTATE;
  END;
END $$;
-- t_dml(role, sub, stmt) -> 'rows:<n>' or 'err:<sqlstate>'
CREATE OR REPLACE FUNCTION public.t_dml(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RESET ROLE;
    RETURN 'rows:' || n;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'err:' || SQLSTATE;
  END;
END $$;
-- t_expect(name, got, expected) raises on mismatch, else prints PASS
CREATE OR REPLACE FUNCTION public.t_expect(p_name text, p_got text, p_expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'FAIL % : got % expected %', p_name, p_got, p_expected;
  END IF;
  RAISE NOTICE 'PASS %', p_name;
END $$;
