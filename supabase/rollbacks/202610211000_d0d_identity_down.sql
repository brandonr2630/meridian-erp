-- Rollback of 202610211000_d0d_identity.sql: restores the pre-D0d policies on erp_user_company_roles, erp_users and erp_roles
-- (as read live 2026-10-21; all TO public, i.e. no TO clause) and removes the D0d triggers, helpers and restrictive policies.
-- WARNING: this re-opens the privilege-escalation holes. Use only to unblock a login/app regression, then fix forward.
-- The roles_* subqueries are reconstructed from the verified description (caller's ucr row joined to erp_roles rr, admin:roles true,
-- in the role's company); compare with pg_policies of the live database if byte-exactness matters.
DROP TRIGGER IF EXISTS d0d_roles_guard ON public.erp_roles;
DROP TRIGGER IF EXISTS d0d_users_guard ON public.erp_users;
DROP TRIGGER IF EXISTS d0d_ucr_guard ON public.erp_user_company_roles;
DROP FUNCTION IF EXISTS public.d0d_roles_guard();
DROP FUNCTION IF EXISTS public.d0d_users_guard();
DROP FUNCTION IF EXISTS public.d0d_ucr_guard();

-- erp_user_company_roles
DROP POLICY IF EXISTS d0_staff_only ON public.erp_user_company_roles;
DROP POLICY IF EXISTS d0_no_anon ON public.erp_user_company_roles;
DROP POLICY IF EXISTS ucr_select_own ON public.erp_user_company_roles;
DROP POLICY IF EXISTS ucr_insert ON public.erp_user_company_roles;
DROP POLICY IF EXISTS ucr_update ON public.erp_user_company_roles;
CREATE POLICY ucr_select_own ON public.erp_user_company_roles FOR SELECT
  USING (user_id = (SELECT erp_users.id FROM public.erp_users WHERE erp_users.auth_user_id = auth.uid() LIMIT 1)
         OR (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids())));
CREATE POLICY ucr_insert ON public.erp_user_company_roles FOR INSERT
  WITH CHECK (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids()));
CREATE POLICY ucr_update ON public.erp_user_company_roles FOR UPDATE
  USING (public.user_has_perm('admin:users') AND company_id IN (SELECT public.my_company_ids()));

-- erp_users
DROP POLICY IF EXISTS d0_no_anon ON public.erp_users;
DROP POLICY IF EXISTS rls_erp_users_insert ON public.erp_users;
DROP POLICY IF EXISTS rls_erp_users_update ON public.erp_users;
CREATE POLICY rls_erp_users_insert ON public.erp_users FOR INSERT
  WITH CHECK (public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()));
CREATE POLICY rls_erp_users_update ON public.erp_users FOR UPDATE
  USING (auth_user_id = auth.uid() OR public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()))
  WITH CHECK (auth_user_id = auth.uid() OR public.is_super_admin() OR company_id IN (SELECT public.my_company_ids()));

-- erp_roles
DROP POLICY IF EXISTS d0_no_anon ON public.erp_roles;
DROP POLICY IF EXISTS roles_select ON public.erp_roles;
DROP POLICY IF EXISTS roles_insert ON public.erp_roles;
DROP POLICY IF EXISTS roles_update ON public.erp_roles;
DROP POLICY IF EXISTS roles_delete ON public.erp_roles;
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

DROP FUNCTION IF EXISTS public.d0d_overrides_ok(jsonb);
DROP FUNCTION IF EXISTS public.d0d_can_admin_user(uuid, uuid);
DROP FUNCTION IF EXISTS public.d0d_role_assignable(uuid, uuid);
DROP FUNCTION IF EXISTS public.d0d_user_is_super(uuid);
DROP FUNCTION IF EXISTS public.d0d_role_is_super(uuid);
DROP FUNCTION IF EXISTS public.d0d_can_admin_users(uuid);
DROP FUNCTION IF EXISTS public.d0d_actor_has_atom(uuid, text);
DROP FUNCTION IF EXISTS public.d0d_my_erp_user_id();
DROP FUNCTION IF EXISTS public.d0d_atom_true(jsonb, text);