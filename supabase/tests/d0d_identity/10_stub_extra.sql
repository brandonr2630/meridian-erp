-- spoof-test target: the trigger bypass list names supabase_admin; it must not be reachable from authenticated
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_admin') THEN CREATE ROLE supabase_admin NOLOGIN; END IF; END $$;

-- d0d_identity family stub: real columns, live policies (verified 2026-10-21) and fixtures for erp_users / erp_roles / erp_user_company_roles.
-- The D0a stub created these three tables with only a few columns and RLS enabled but NO policies; here they get the live shape.

-- erp_users
ALTER TABLE public.erp_users
  ADD COLUMN email text, ADD COLUMN last_login timestamptz, ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN company_id uuid REFERENCES public.companies(id), ADD COLUMN force_password_change boolean NOT NULL DEFAULT false;
ALTER TABLE public.erp_users ADD CONSTRAINT erp_users_email_key UNIQUE (email);
ALTER TABLE public.erp_users ADD CONSTRAINT erp_users_auth_user_id_key UNIQUE (auth_user_id);
ALTER TABLE public.erp_users ALTER COLUMN is_active SET NOT NULL;

-- erp_roles
ALTER TABLE public.erp_roles
  ADD COLUMN company_id uuid REFERENCES public.companies(id), ADD COLUMN is_system boolean NOT NULL DEFAULT false,
  ADD COLUMN created_by uuid, ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(), ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.erp_roles ADD CONSTRAINT erp_roles_company_id_name_key UNIQUE (company_id, name);

-- erp_user_company_roles
ALTER TABLE public.erp_user_company_roles
  ADD COLUMN permission_overrides jsonb NOT NULL DEFAULT '{}', ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.erp_user_company_roles ADD CONSTRAINT ucr_user_company_key UNIQUE (user_id, company_id);
ALTER TABLE public.erp_user_company_roles ADD FOREIGN KEY (user_id) REFERENCES public.erp_users(id) ON DELETE CASCADE;
ALTER TABLE public.erp_user_company_roles ADD FOREIGN KEY (company_id) REFERENCES public.companies(id);
ALTER TABLE public.erp_user_company_roles ADD FOREIGN KEY (role_id) REFERENCES public.erp_roles(id);

-- LIVE policies (pg_policies 2026-10-21), all TO public
CREATE POLICY ucr_select_own ON public.erp_user_company_roles FOR SELECT
  USING (user_id = (SELECT erp_users.id FROM public.erp_users WHERE erp_users.auth_user_id = auth.uid() LIMIT 1)
         OR (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids())));
CREATE POLICY ucr_insert ON public.erp_user_company_roles FOR INSERT
  WITH CHECK (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids()));
CREATE POLICY ucr_update ON public.erp_user_company_roles FOR UPDATE
  USING (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids()));

CREATE POLICY rls_erp_users_select ON public.erp_users FOR SELECT
  USING (auth_user_id = auth.uid() OR public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()));
CREATE POLICY rls_erp_users_insert ON public.erp_users FOR INSERT
  WITH CHECK (public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()));
CREATE POLICY rls_erp_users_update ON public.erp_users FOR UPDATE
  USING (auth_user_id = auth.uid() OR public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()))
  WITH CHECK (auth_user_id = auth.uid() OR public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()));
CREATE POLICY rls_erp_users_delete ON public.erp_users FOR DELETE USING (public.is_super_admin());

CREATE POLICY roles_select ON public.erp_roles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY roles_insert ON public.erp_roles FOR INSERT
  WITH CHECK (is_system = false AND company_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.erp_user_company_roles ucr JOIN public.erp_roles rr ON rr.id = ucr.role_id
     WHERE ucr.user_id = (SELECT eu.id FROM public.erp_users eu WHERE eu.auth_user_id = auth.uid() LIMIT 1)
       AND ucr.company_id = erp_roles.company_id AND (rr.permissions ->> 'admin:roles')::boolean = true));
CREATE POLICY roles_update ON public.erp_roles FOR UPDATE
  USING (is_system = false AND EXISTS (
    SELECT 1 FROM public.erp_user_company_roles ucr JOIN public.erp_roles rr ON rr.id = ucr.role_id
     WHERE ucr.user_id = (SELECT eu.id FROM public.erp_users eu WHERE eu.auth_user_id = auth.uid() LIMIT 1)
       AND ucr.company_id = erp_roles.company_id AND (rr.permissions ->> 'admin:roles')::boolean = true));
CREATE POLICY roles_delete ON public.erp_roles FOR DELETE
  USING (is_system = false AND EXISTS (
    SELECT 1 FROM public.erp_user_company_roles ucr JOIN public.erp_roles rr ON rr.id = ucr.role_id
     WHERE ucr.user_id = (SELECT eu.id FROM public.erp_users eu WHERE eu.auth_user_id = auth.uid() LIMIT 1)
       AND ucr.company_id = erp_roles.company_id AND (rr.permissions ->> 'admin:roles')::boolean = true));

-- ── live atom sets and role ownership ──
-- a..01 operations_tech, a..02 viewer, a..03 company_admin, a..04 super_admin, a..05 Office Admin (custom, owned by C1)
UPDATE public.erp_roles SET is_system = true WHERE id IN
 ('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000004');
UPDATE public.erp_roles SET permissions = '{"ops:work-orders:read":true,"ops:work-orders:write":true}'::jsonb WHERE id='a0000000-0000-0000-0000-000000000001';
UPDATE public.erp_roles SET permissions = '{"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true,"ops:work-orders:write":true}'::jsonb WHERE id='a0000000-0000-0000-0000-000000000003';
UPDATE public.erp_roles SET permissions = '{"admin:companies":true,"admin:roles":true,"admin:settings":true,"admin:users":true,"finance:ap:read":true,"finance:ap:write":true,"finance:bank:read":true,"ops:work-orders:read":true,"ops:work-orders:write":true}'::jsonb WHERE id='a0000000-0000-0000-0000-000000000004';
-- Office-Admin-like custom role: holds admin:roles (edits roles) but NOT admin:users and NOT finance:bank:read
UPDATE public.erp_roles SET company_id='c1000000-0000-0000-0000-000000000001', is_system=false,
  permissions = '{"admin:roles":true,"finance:ap:read":true,"finance:ap:write":true,"ops:work-orders:read":true}'::jsonb WHERE id='a0000000-0000-0000-0000-000000000005';
INSERT INTO public.erp_roles (id, company_id, name, is_system, permissions) VALUES
 ('a0000000-0000-0000-0000-000000000006','c1000000-0000-0000-0000-000000000001','C1 Custom',false,'{"ops:work-orders:read":true}'),
 ('a0000000-0000-0000-0000-000000000007','c2000000-0000-0000-0000-000000000002','C2 Custom',false,'{"ops:work-orders:read":true}'),
 ('a0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','C1 Disposable',false,'{"ops:work-orders:read":true}'),
 ('a0000000-0000-0000-0000-000000000009','c1000000-0000-0000-0000-000000000001','C1 Fin Bank',false,'{"finance:bank:read":true}');

-- ── users: homes, emails, extra identities ──
UPDATE public.erp_users SET company_id='c1000000-0000-0000-0000-000000000001', email=full_name||'@t.test' WHERE id <> 'e0000000-0000-0000-0000-000000000007';
UPDATE public.erp_users SET company_id='c2000000-0000-0000-0000-000000000002', email=full_name||'@t.test' WHERE id = 'e0000000-0000-0000-0000-000000000007';
-- e08 second super (C1), e09 company_admin C2 only, e10 mixed (company_admin C1 + operations_tech C2), e11 spare C1 viewer, e12 spare C2 viewer, e13 dual (company_admin in C1 and C2)
INSERT INTO public.erp_users (id, auth_user_id, full_name, email, is_active, company_id, force_password_change) VALUES
 ('e0000000-0000-0000-0000-000000000008','aaaa0008-0000-0000-0000-000000000008','super2','super2@t.test',true,'c1000000-0000-0000-0000-000000000001',false),
 ('e0000000-0000-0000-0000-000000000009','10101010-1010-1010-1010-101010101010','admin C2','adminc2@t.test',true,'c2000000-0000-0000-0000-000000000002',false),
 ('e0000000-0000-0000-0000-000000000010','11111111-aaaa-1111-1111-111111111111','mixed','mixed@t.test',true,'c1000000-0000-0000-0000-000000000001',false),
 ('e0000000-0000-0000-0000-000000000011','aaaa0011-0000-0000-0000-000000000011','spare C1','spare1@t.test',true,'c1000000-0000-0000-0000-000000000001',true),
 ('e0000000-0000-0000-0000-000000000012','aaaa0012-0000-0000-0000-000000000012','spare C2','spare2@t.test',true,'c2000000-0000-0000-0000-000000000002',false),
 ('e0000000-0000-0000-0000-000000000013','aaaa0013-0000-0000-0000-000000000013','dual','dual@t.test',true,'c1000000-0000-0000-0000-000000000001',false);
INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id) VALUES
 ('e0000000-0000-0000-0000-000000000008','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000004'),
 ('e0000000-0000-0000-0000-000000000009','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000010','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000010','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001'),
 ('e0000000-0000-0000-0000-000000000011','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002'),
 ('e0000000-0000-0000-0000-000000000012','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000002'),
 ('e0000000-0000-0000-0000-000000000013','c1000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003'),
 ('e0000000-0000-0000-0000-000000000013','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003'),
 -- the multi-company super admin (like live "Brandon"): also a member of C2
 ('e0000000-0000-0000-0000-000000000004','c2000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000004');

-- ── extra test helpers ──
-- t_dmlm(role, sub, stmt) -> 'rows:<n>' or 'err:<sqlstate>|<message>'
CREATE OR REPLACE FUNCTION public.t_dmlm(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
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
    RETURN 'err:' || SQLSTATE || '|' || SQLERRM;
  END;
END $$;
-- t_has(name, got, needle): PASS when got contains needle
CREATE OR REPLACE FUNCTION public.t_has(p_name text, p_got text, p_needle text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF position(p_needle in coalesce(p_got,'')) = 0 THEN
    RAISE EXCEPTION 'FAIL % : got % expected to contain %', p_name, p_got, p_needle;
  END IF;
  RAISE NOTICE 'PASS %', p_name;
END $$;-- t_deny(name, got): PASS when the statement was refused with SQLSTATE 42501 (RLS violation, trigger refusal or permission denied)
CREATE OR REPLACE FUNCTION public.t_deny(p_name text, p_got text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NULL OR p_got NOT LIKE 'err:42501%' THEN
    RAISE EXCEPTION 'FAIL % : got % expected err:42501', p_name, p_got;
  END IF;
  RAISE NOTICE 'PASS %', p_name;
END $$;
-- t_denym(name, got, needle): refused with 42501 AND the message contains needle (proves WHICH guard fired)
CREATE OR REPLACE FUNCTION public.t_denym(p_name text, p_got text, p_needle text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NULL OR p_got NOT LIKE 'err:42501%' OR position(p_needle in p_got) = 0 THEN
    RAISE EXCEPTION 'FAIL % : got % expected err:42501 containing %', p_name, p_got, p_needle;
  END IF;
  RAISE NOTICE 'PASS %', p_name;
END $$;
-- Spoof tests need a session that resembles production: there the API connects as `authenticator` (not a superuser; member of
-- anon/authenticated) and PostgREST does SET LOCAL ROLE. Here the harness session is postgres (superuser), so SET ROLE would always
-- succeed. t_dmlm_ns first switches the SESSION AUTHORIZATION to a restricted login-like role that is a member of authenticated/anon only.
-- (In Supabase `authenticator` is also a member of service_role; reaching it needs arbitrary SQL execution, which already defeats RLS.)
DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='test_authenticator') THEN CREATE ROLE test_authenticator NOLOGIN; END IF; END $$;
GRANT authenticated, anon TO test_authenticator;
CREATE OR REPLACE FUNCTION public.t_dmlm_ns(p_role text, p_sub uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  EXECUTE 'SET LOCAL SESSION AUTHORIZATION test_authenticator';
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'rows:' || n;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE; RESET SESSION AUTHORIZATION;
    RETURN 'err:' || SQLSTATE || '|' || SQLERRM;
  END;
END $$;
-- snapshot of the original (live) policies so the rollback test can compare them exactly
CREATE TABLE public.t_orig_policies AS
  SELECT tablename::text, policyname::text, permissive::text, roles::text, cmd::text, qual, with_check
    FROM pg_policies WHERE tablename IN ('erp_users','erp_roles','erp_user_company_roles');