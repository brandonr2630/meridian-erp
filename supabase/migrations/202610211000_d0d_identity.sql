-- D0d: identity-table RLS hardening (project-portal spec, Phase D section D0). Closes the privilege-escalation holes on
-- public.erp_user_company_roles (ucr), public.erp_users and public.erp_roles. No data is touched; policies, helpers, 3 triggers.
--
-- Holes closed (verified live 2026-10-21):
--   ucr    any holder of admin:users in ANY company could assign ANY role (incl. super_admin = a role carrying admin:companies) to
--          anyone incl. self, and change role_id / permission_overrides of any row in a company they merely belong to.
--   users  any active staff member could INSERT an erp_users row for any auth_user_id (makes an arbitrary login "staff" and defeats
--          the D0a/D0c staff-only boundary), UPDATE any colleague's profile, or change their own is_active / company_id.
--   roles  a company admin with admin:roles could create/edit a custom role carrying admin:companies and assign it = platform super
--          admin; any logged-in login (incl. a future client login) could read every role definition.
--
-- Helpers (all SECURITY DEFINER STABLE, search_path public,pg_temp, EXECUTE only for authenticated; caller-relative):
--   d0d_atom_true(jsonb,text)          exact same truthiness as the live helpers' (permissions->>'k')::boolean (so the string "true" or
--                                      the number 1 count as true), but never raises (garbage = false). Pure, IMMUTABLE, no table access.
--   d0d_my_erp_user_id()               caller's ACTIVE erp_users.id, else NULL.
--   d0d_actor_has_atom(cid, atom)      caller (active) holds atom through a ROLE assigned IN company cid (overrides do not count).
--   d0d_can_admin_users(cid)           is_super_admin() OR d0d_actor_has_atom(cid,'admin:users')   (company-scoped, unlike user_has_perm).
--   d0d_role_is_super(rid)             role carries admin:companies. Returns false for non-staff callers (no oracle for clients).
--   d0d_user_is_super(uid)             erp user holds a super role anywhere. Returns false for non-staff callers.
--   d0d_role_assignable(cid, rid)      role exists, is global or owned by cid, and (not super or caller is super).
--   d0d_overrides_ok(ov)               non-super callers may not put admin:companies=true into permission_overrides.
-- Triggers (SECURITY INVOKER, so current_user is the real caller; sessions running as postgres / service_role / supabase_admin bypass):
--   d0d_ucr_guard    BEFORE UPDATE on ucr    id / user_id / company_id are immutable for non-super.
--   d0d_users_guard  BEFORE UPDATE on erp_users  column-level rules (self-service = last_login + clearing force_password_change only;
--                    admins: full_name / is_active / company_id (to a company they administer); email and auth_user_id are super-only;
--                    nobody but a super changes their OWN is_active / company_id; non-supers cannot touch a super admin's row).
--   d0d_roles_guard  BEFORE INSERT OR UPDATE on erp_roles  admin:companies only via super; ceiling rule (a non-super may only newly
--                    grant atoms they themselves hold in the role's company); company_id / is_system immutable for non-super.
-- Idempotent. Rollback: supabase/rollbacks/202610211000_d0d_identity_down.sql

-- == 1. helpers ==============================================================================================================
CREATE OR REPLACE FUNCTION public.d0d_atom_true(p jsonb, k text) RETURNS boolean
  LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE SET search_path = public, pg_temp AS $$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN false; END IF;
  RETURN coalesce((p ->> k)::boolean, false);
EXCEPTION WHEN others THEN
  RETURN false;
END $$;

CREATE OR REPLACE FUNCTION public.d0d_my_erp_user_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT eu.id FROM public.erp_users eu WHERE eu.auth_user_id = auth.uid() AND eu.is_active LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public.d0d_actor_has_atom(cid uuid, atom text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.erp_users eu
                   JOIN public.erp_user_company_roles ucr ON ucr.user_id = eu.id AND ucr.company_id = cid
                   JOIN public.erp_roles r ON r.id = ucr.role_id
                  WHERE eu.auth_user_id = auth.uid() AND eu.is_active AND public.d0d_atom_true(r.permissions, atom))
$$;

CREATE OR REPLACE FUNCTION public.d0d_can_admin_users(cid uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_super_admin() OR public.d0d_actor_has_atom(cid, 'admin:users')
$$;

CREATE OR REPLACE FUNCTION public.d0d_role_is_super(rid uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_erp_staff()
         AND coalesce((SELECT public.d0d_atom_true(r.permissions, 'admin:companies') FROM public.erp_roles r WHERE r.id = rid), false)
$$;

CREATE OR REPLACE FUNCTION public.d0d_user_is_super(uid uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_erp_staff()
         AND EXISTS (SELECT 1 FROM public.erp_user_company_roles ucr JOIN public.erp_roles r ON r.id = ucr.role_id
                      WHERE ucr.user_id = uid AND public.d0d_atom_true(r.permissions, 'admin:companies'))
$$;

CREATE OR REPLACE FUNCTION public.d0d_role_assignable(cid uuid, rid uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_erp_staff()
         AND EXISTS (SELECT 1 FROM public.erp_roles r
                      WHERE r.id = rid AND (r.company_id IS NULL OR r.company_id = cid)
                        AND (NOT public.d0d_atom_true(r.permissions, 'admin:companies') OR public.is_super_admin()))
$$;

CREATE OR REPLACE FUNCTION public.d0d_overrides_ok(ov jsonb) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_super_admin() OR NOT public.d0d_atom_true(ov, 'admin:companies')
$$;

REVOKE ALL ON FUNCTION public.d0d_atom_true(jsonb, text), public.d0d_my_erp_user_id(), public.d0d_actor_has_atom(uuid, text),
  public.d0d_can_admin_users(uuid), public.d0d_role_is_super(uuid), public.d0d_user_is_super(uuid),
  public.d0d_role_assignable(uuid, uuid), public.d0d_overrides_ok(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.d0d_atom_true(jsonb, text), public.d0d_my_erp_user_id(), public.d0d_actor_has_atom(uuid, text),
  public.d0d_can_admin_users(uuid), public.d0d_role_is_super(uuid), public.d0d_user_is_super(uuid),
  public.d0d_role_assignable(uuid, uuid), public.d0d_overrides_ok(jsonb) TO authenticated;

-- == 2. erp_user_company_roles ===============================================================================================
DROP POLICY IF EXISTS ucr_select_own ON public.erp_user_company_roles;
CREATE POLICY ucr_select_own ON public.erp_user_company_roles FOR SELECT TO authenticated
  USING (user_id = (SELECT public.d0d_my_erp_user_id()) OR public.d0d_can_admin_users(company_id));

DROP POLICY IF EXISTS ucr_insert ON public.erp_user_company_roles;
CREATE POLICY ucr_insert ON public.erp_user_company_roles FOR INSERT TO authenticated
  WITH CHECK (public.d0d_can_admin_users(company_id)
              AND public.d0d_role_assignable(company_id, role_id)
              AND (user_id IS DISTINCT FROM (SELECT public.d0d_my_erp_user_id()) OR public.is_super_admin())
              AND public.d0d_overrides_ok(permission_overrides));

DROP POLICY IF EXISTS ucr_update ON public.erp_user_company_roles;
CREATE POLICY ucr_update ON public.erp_user_company_roles FOR UPDATE TO authenticated
  USING (public.d0d_can_admin_users(company_id)
         AND (user_id IS DISTINCT FROM (SELECT public.d0d_my_erp_user_id()) OR public.is_super_admin())
         AND (NOT public.d0d_role_is_super(role_id) OR public.is_super_admin()))
  WITH CHECK (public.d0d_can_admin_users(company_id)
              AND public.d0d_role_assignable(company_id, role_id)
              AND (user_id IS DISTINCT FROM (SELECT public.d0d_my_erp_user_id()) OR public.is_super_admin())
              AND public.d0d_overrides_ok(permission_overrides));

-- No DELETE policy for authenticated by design: the app never deletes these rows through REST (the service-role edge functions do).
DROP POLICY IF EXISTS ucr_delete ON public.erp_user_company_roles;

DROP POLICY IF EXISTS d0_no_anon ON public.erp_user_company_roles;
CREATE POLICY d0_no_anon ON public.erp_user_company_roles AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS d0_staff_only ON public.erp_user_company_roles;
CREATE POLICY d0_staff_only ON public.erp_user_company_roles AS RESTRICTIVE FOR ALL TO authenticated
  USING ((SELECT public.is_erp_staff())) WITH CHECK ((SELECT public.is_erp_staff()));

CREATE OR REPLACE FUNCTION public.d0d_ucr_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role', 'supabase_admin') THEN RETURN NEW; END IF;
  IF (NEW.id IS DISTINCT FROM OLD.id OR NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.company_id IS DISTINCT FROM OLD.company_id)
     AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'erp_user_company_roles: id, user_id and company_id cannot be changed (create a new assignment instead)' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.d0d_ucr_guard() FROM PUBLIC, anon;
DROP TRIGGER IF EXISTS d0d_ucr_guard ON public.erp_user_company_roles;
CREATE TRIGGER d0d_ucr_guard BEFORE UPDATE ON public.erp_user_company_roles
  FOR EACH ROW EXECUTE FUNCTION public.d0d_ucr_guard();

-- == 3. erp_users ============================================================================================================
-- SELECT and DELETE policies are intentionally untouched (own row / super / same-company colleagues; delete = super only).
DROP POLICY IF EXISTS rls_erp_users_insert ON public.erp_users;
CREATE POLICY rls_erp_users_insert ON public.erp_users FOR INSERT TO authenticated
  WITH CHECK (company_id IS NOT NULL AND public.d0d_can_admin_users(company_id));

DROP POLICY IF EXISTS rls_erp_users_update ON public.erp_users;
CREATE POLICY rls_erp_users_update ON public.erp_users FOR UPDATE TO authenticated
  USING (id = (SELECT public.d0d_my_erp_user_id()) OR public.d0d_can_admin_users(company_id))
  WITH CHECK (id = (SELECT public.d0d_my_erp_user_id()) OR (company_id IS NOT NULL AND public.d0d_can_admin_users(company_id)));

-- no staff-only restrictive here: a user must be able to read their own row at login. Anon deny only.
DROP POLICY IF EXISTS d0_no_anon ON public.erp_users;
CREATE POLICY d0_no_anon ON public.erp_users AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION public.d0d_users_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_self  boolean;
  v_admin boolean;
BEGIN
  IF current_user IN ('postgres', 'service_role', 'supabase_admin') THEN RETURN NEW; END IF;
  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'erp_users: id and created_at are immutable' USING ERRCODE = '42501';
  END IF;
  IF public.is_super_admin() THEN RETURN NEW; END IF;

  v_self  := coalesce(OLD.id = public.d0d_my_erp_user_id(), false);
  v_admin := OLD.company_id IS NOT NULL AND public.d0d_can_admin_users(OLD.company_id);

  IF NOT v_self AND public.d0d_user_is_super(OLD.id) THEN
    RAISE EXCEPTION 'erp_users: a super admin profile can only be changed by a super admin' USING ERRCODE = '42501';
  END IF;
  IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
    RAISE EXCEPTION 'erp_users: auth_user_id can only be changed by a super admin' USING ERRCODE = '42501';
  END IF;
  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'erp_users: email can only be changed by a super admin (use update-erp-user)' USING ERRCODE = '42501';
  END IF;
  IF v_self AND NEW.force_password_change IS DISTINCT FROM OLD.force_password_change AND NEW.force_password_change THEN
    RAISE EXCEPTION 'erp_users: force_password_change can only be cleared on your own profile' USING ERRCODE = '42501';
  END IF;
  IF v_self AND (NEW.is_active IS DISTINCT FROM OLD.is_active OR NEW.company_id IS DISTINCT FROM OLD.company_id) THEN
    RAISE EXCEPTION 'erp_users: you cannot change your own is_active or company_id' USING ERRCODE = '42501';
  END IF;
  IF NOT v_admin THEN
    -- ordinary self-service: last_login and force_password_change are the only columns that may differ
    IF (to_jsonb(NEW) - 'last_login' - 'force_password_change') IS DISTINCT FROM (to_jsonb(OLD) - 'last_login' - 'force_password_change') THEN
      RAISE EXCEPTION 'erp_users: only last_login and force_password_change can be changed on your own profile' USING ERRCODE = '42501';
    END IF;
  ELSIF NEW.company_id IS DISTINCT FROM OLD.company_id AND (NEW.company_id IS NULL OR NOT public.d0d_can_admin_users(NEW.company_id)) THEN
    RAISE EXCEPTION 'erp_users: company_id can only be moved to a company you administer' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.d0d_users_guard() FROM PUBLIC, anon;
DROP TRIGGER IF EXISTS d0d_users_guard ON public.erp_users;
CREATE TRIGGER d0d_users_guard BEFORE UPDATE ON public.erp_users
  FOR EACH ROW EXECUTE FUNCTION public.d0d_users_guard();

-- == 4. erp_roles ============================================================================================================
DROP POLICY IF EXISTS roles_select ON public.erp_roles;
CREATE POLICY roles_select ON public.erp_roles FOR SELECT TO authenticated USING ((SELECT public.is_erp_staff()));

DROP POLICY IF EXISTS roles_insert ON public.erp_roles;
CREATE POLICY roles_insert ON public.erp_roles FOR INSERT TO authenticated
  WITH CHECK (is_system = false AND company_id IS NOT NULL AND public.d0d_actor_has_atom(company_id, 'admin:roles'));

DROP POLICY IF EXISTS roles_update ON public.erp_roles;
CREATE POLICY roles_update ON public.erp_roles FOR UPDATE TO authenticated
  USING (is_system = false AND company_id IS NOT NULL AND public.d0d_actor_has_atom(company_id, 'admin:roles'))
  WITH CHECK (is_system = false AND company_id IS NOT NULL AND public.d0d_actor_has_atom(company_id, 'admin:roles'));

DROP POLICY IF EXISTS roles_delete ON public.erp_roles;
CREATE POLICY roles_delete ON public.erp_roles FOR DELETE TO authenticated
  USING (is_system = false AND company_id IS NOT NULL AND public.d0d_actor_has_atom(company_id, 'admin:roles')
         AND (public.is_super_admin() OR NOT public.d0d_atom_true(permissions, 'admin:companies')));

DROP POLICY IF EXISTS d0_no_anon ON public.erp_roles;
CREATE POLICY d0_no_anon ON public.erp_roles AS RESTRICTIVE FOR ALL TO anon USING (false) WITH CHECK (false);

CREATE OR REPLACE FUNCTION public.d0d_roles_guard() RETURNS trigger
  LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE k text;
BEGIN
  IF current_user IN ('postgres', 'service_role', 'supabase_admin') THEN RETURN NEW; END IF;
  IF public.is_super_admin() THEN RETURN NEW; END IF;

  IF NEW.permissions IS NOT NULL AND jsonb_typeof(NEW.permissions) <> 'object' THEN
    RAISE EXCEPTION 'erp_roles: permissions must be a JSON object' USING ERRCODE = '42501';
  END IF;
  IF public.d0d_atom_true(NEW.permissions, 'admin:companies') OR (TG_OP = 'UPDATE' AND public.d0d_atom_true(OLD.permissions, 'admin:companies')) THEN
    RAISE EXCEPTION 'erp_roles: only a super admin can create or change a role carrying admin:companies' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' AND (NEW.company_id IS DISTINCT FROM OLD.company_id OR NEW.is_system IS DISTINCT FROM OLD.is_system) THEN
    RAISE EXCEPTION 'erp_roles: company_id and is_system cannot be changed' USING ERRCODE = '42501';
  END IF;
  -- ceiling rule: you can only newly grant atoms you hold yourself, through a role assigned in the role's company
  IF NEW.permissions IS NOT NULL THEN
    FOR k IN SELECT jsonb_object_keys(NEW.permissions) LOOP
      IF public.d0d_atom_true(NEW.permissions, k)
         AND NOT (TG_OP = 'UPDATE' AND public.d0d_atom_true(OLD.permissions, k))
         AND NOT public.d0d_actor_has_atom(NEW.company_id, k) THEN
        RAISE EXCEPTION 'erp_roles: you cannot grant the permission "%" because you do not hold it in this company', k USING ERRCODE = '42501';
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.d0d_roles_guard() FROM PUBLIC, anon;
DROP TRIGGER IF EXISTS d0d_roles_guard ON public.erp_roles;
CREATE TRIGGER d0d_roles_guard BEFORE INSERT OR UPDATE ON public.erp_roles
  FOR EACH ROW EXECUTE FUNCTION public.d0d_roles_guard();