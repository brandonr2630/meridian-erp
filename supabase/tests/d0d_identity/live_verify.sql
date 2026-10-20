-- D0d LIVE VERIFICATION (run AFTER 202610211000_d0d_identity.sql is applied). Read-only in effect: the whole DO block ends with
-- RAISE EXCEPTION, so every probe row and every write below is rolled back. The only objects created outside the DO block are two
-- pg_temp helpers (session-local, gone at disconnect). Run it as postgres (SQL editor or MCP execute_sql); read the RESULTS in the error text.
-- Probes use two throwaway erp_users rows inserted INSIDE the transaction (a company_admin and a plain viewer of the Quarryquip company)
-- plus the four real users (impersonated via SET LOCAL ROLE authenticated + request.jwt.claim.sub). Expect "FAILS: 0".
--   expectation codes: deny = SQLSTATE 42501;  n>0 = select returned rows;  blocked = 0 rows or 42501;  closed = n:0 or 42501;  else exact (rows:N / n:N)
CREATE OR REPLACE FUNCTION pg_temp.t(p_name text, p_uid uuid, p_role text, p_sql text, p_expect text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n bigint; got text; ok boolean;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
  EXECUTE 'SET LOCAL ROLE ' || quote_ident(p_role);
  BEGIN
    IF lower(left(ltrim(p_sql), 6)) = 'select' THEN
      EXECUTE 'SELECT count(*) FROM (' || p_sql || ') s' INTO n; got := 'n:' || n;
    ELSE
      EXECUTE p_sql; GET DIAGNOSTICS n = ROW_COUNT; got := 'rows:' || n;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    got := 'ERR ' || SQLSTATE || ' ' || left(SQLERRM, 80);
  END;
  RESET ROLE;
  ok := CASE p_expect
          WHEN 'deny'    THEN got LIKE 'ERR 42501%'
          WHEN 'n>0'     THEN got LIKE 'n:%' AND n > 0
          WHEN 'blocked' THEN got = 'rows:0' OR got LIKE 'ERR 42501%'
          WHEN 'closed'  THEN got = 'n:0' OR got LIKE 'ERR 42501%'
          ELSE got = p_expect END;
  RETURN (CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || p_name || '  [expect ' || p_expect || ']  got ' || got;
END $$;

DO $$
DECLARE
  brandon uuid := 'eac11002-8591-40bb-b16e-5aac5f7907f3';  -- super_admin in 3 companies
  vanessa uuid := '5838d832-e89f-4b27-847f-c1110839d4f3';  -- super_admin, Quarryquip
  vikash  uuid := 'e2f3d3bd-68b2-4834-8229-bb49b3f5021a';  -- operations_tech, Quarryquip
  asst    uuid := '7aefd0b5-b7f4-45e2-8802-d9079e2441e2';  -- Administrative Asst, Office Admin, Quarryquip
  client  uuid := gen_random_uuid();                       -- authenticated login with NO erp_users row (future client portal user)
  pa_auth uuid := gen_random_uuid(); pv_auth uuid := gen_random_uuid();
  qql uuid; oth uuid; r_super uuid; r_cadm uuid; r_view uuid; r_ops uuid;
  pa uuid; pv uuid; b_id uuid; v_id uuid; k_id uuid; a_id uuid;
  res text := ''; fails int;
  A text := 'authenticated';
BEGIN
  IF to_regprocedure('public.d0d_can_admin_users(uuid)') IS NULL OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'd0d_users_guard') THEN
    RAISE EXCEPTION 'D0d migration is NOT applied here; nothing was verified';
  END IF;
  SELECT eu.id INTO b_id FROM public.erp_users eu WHERE eu.auth_user_id = brandon;
  SELECT eu.id INTO v_id FROM public.erp_users eu WHERE eu.auth_user_id = vanessa;
  SELECT eu.id INTO k_id FROM public.erp_users eu WHERE eu.auth_user_id = vikash;
  SELECT eu.id INTO a_id FROM public.erp_users eu WHERE eu.auth_user_id = asst;
  IF b_id IS NULL OR v_id IS NULL OR k_id IS NULL OR a_id IS NULL THEN RAISE EXCEPTION 'one of the four real users is missing'; END IF;
  SELECT ucr.company_id INTO qql FROM public.erp_user_company_roles ucr WHERE ucr.user_id = k_id LIMIT 1;
  SELECT ucr.company_id INTO oth FROM public.erp_user_company_roles ucr WHERE ucr.user_id = b_id AND ucr.company_id <> qql LIMIT 1;
  SELECT id INTO r_super FROM public.erp_roles WHERE name = 'super_admin'     ORDER BY company_id NULLS FIRST LIMIT 1;
  SELECT id INTO r_cadm  FROM public.erp_roles WHERE name = 'company_admin'   ORDER BY company_id NULLS FIRST LIMIT 1;
  SELECT id INTO r_view  FROM public.erp_roles WHERE name = 'viewer'          ORDER BY company_id NULLS FIRST LIMIT 1;
  SELECT id INTO r_ops   FROM public.erp_roles WHERE name = 'operations_tech' ORDER BY company_id NULLS FIRST LIMIT 1;

  -- throwaway probes (inserted as postgres, rolled back with everything else)
  INSERT INTO public.erp_users (auth_user_id, full_name, email, is_active, company_id, force_password_change)
    VALUES (pa_auth, 'zz probe company admin', 'zz-probe-admin@invalid.test', true, qql, false) RETURNING id INTO pa;
  INSERT INTO public.erp_users (auth_user_id, full_name, email, is_active, company_id, force_password_change)
    VALUES (pv_auth, 'zz probe viewer', 'zz-probe-viewer@invalid.test', true, qql, false) RETURNING id INTO pv;
  INSERT INTO public.erp_user_company_roles (user_id, company_id, role_id, permission_overrides) VALUES (pa, qql, r_cadm, '{}'), (pv, qql, r_view, '{}');

  -- ── reads / login shapes (must keep working) ──
  res := res || pg_temp.t('brandon reads assignments', brandon, A, 'SELECT 1 FROM erp_user_company_roles', 'n>0') || E'\n';
  res := res || pg_temp.t('vanessa is super admin', vanessa, A, 'SELECT 1 WHERE public.is_super_admin()', 'n:1') || E'\n';
  res := res || pg_temp.t('vikash reads ONLY his own assignment', vikash, A, 'SELECT 1 FROM erp_user_company_roles', 'n:1') || E'\n';
  res := res || pg_temp.t('asst reads ONLY her own assignment', asst, A, 'SELECT 1 FROM erp_user_company_roles', 'n:1') || E'\n';
  res := res || pg_temp.t('vikash login: own active profile', vikash, A, format('SELECT 1 FROM erp_users WHERE auth_user_id=%L AND is_active', vikash), 'n:1') || E'\n';
  res := res || pg_temp.t('vikash login: own role permissions', vikash, A, format('SELECT r.permissions FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE u.user_id=%L', k_id), 'n:1') || E'\n';
  res := res || pg_temp.t('asst login: own role permissions', asst, A, format('SELECT r.permissions FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE u.user_id=%L', a_id), 'n:1') || E'\n';
  res := res || pg_temp.t('vikash can read roles', vikash, A, 'SELECT 1 FROM erp_roles', 'n>0') || E'\n';
  res := res || pg_temp.t('asst can read roles', asst, A, 'SELECT 1 FROM erp_roles', 'n>0') || E'\n';
  res := res || pg_temp.t('vikash last_login write (login path)', vikash, A, format('UPDATE erp_users SET last_login=now() WHERE auth_user_id=%L', vikash), 'rows:1') || E'\n';
  res := res || pg_temp.t('vikash force_password_change=false (change-password path)', vikash, A, format('UPDATE erp_users SET force_password_change=false WHERE auth_user_id=%L', vikash), 'rows:1') || E'\n';
  -- ── client-like login and anon ──
  res := res || pg_temp.t('client cannot read roles', client, A, 'SELECT 1 FROM erp_roles', 'n:0') || E'\n';
  res := res || pg_temp.t('client cannot read assignments', client, A, 'SELECT 1 FROM erp_user_company_roles', 'n:0') || E'\n';
  res := res || pg_temp.t('client cannot read profiles', client, A, 'SELECT 1 FROM erp_users', 'n:0') || E'\n';
  res := res || pg_temp.t('client cannot insert a staff profile (takeover hole)', client, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)', client, 'x', 'zz-client@invalid.test', qql), 'deny') || E'\n';
  res := res || pg_temp.t('client cannot insert an assignment', client, A, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L)', k_id, qql, r_view), 'deny') || E'\n';
  res := res || pg_temp.t('anon cannot read roles', NULL, 'anon', 'SELECT 1 FROM erp_roles', 'closed') || E'\n';
  res := res || pg_temp.t('anon cannot read profiles', NULL, 'anon', 'SELECT 1 FROM erp_users', 'closed') || E'\n';
  res := res || pg_temp.t('anon cannot read assignments', NULL, 'anon', 'SELECT 1 FROM erp_user_company_roles', 'closed') || E'\n';
  -- ── operations_tech (vikash) and Office Admin (asst): ordinary staff ──
  res := res || pg_temp.t('vikash cannot rename the probe viewer', vikash, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', pv), 'rows:0') || E'\n';
  res := res || pg_temp.t('vikash cannot rename self', vikash, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', k_id), 'deny') || E'\n';
  res := res || pg_temp.t('vikash cannot move own company', vikash, A, format('UPDATE erp_users SET company_id=%L WHERE id=%L', coalesce(oth, qql), k_id), 'blocked') || E'\n';
  res := res || pg_temp.t('vikash cannot deactivate self', vikash, A, format('UPDATE erp_users SET is_active=false WHERE id=%L', k_id), 'deny') || E'\n';
  res := res || pg_temp.t('vikash cannot insert a profile', vikash, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (gen_random_uuid(),%L,%L,true,%L)', 'x', 'zz-x@invalid.test', qql), 'deny') || E'\n';
  res := res || pg_temp.t('vikash cannot insert an assignment', vikash, A, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L)', pv, qql, r_ops), 'deny') || E'\n';
  res := res || pg_temp.t('vikash cannot make himself super_admin', vikash, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L', r_super, k_id), 'blocked') || E'\n';
  res := res || pg_temp.t('vikash cannot edit his overrides', vikash, A, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L', '{"admin:users":true}', k_id), 'blocked') || E'\n';
  res := res || pg_temp.t('vikash cannot create a role', vikash, A, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'zz vk', '{"ops:work-orders:read":true}', qql), 'deny') || E'\n';
  res := res || pg_temp.t('vikash cannot edit the Office Admin role', vikash, A, 'UPDATE erp_roles SET name=name WHERE name=''Office Admin''', 'rows:0') || E'\n';
  res := res || pg_temp.t('asst cannot insert a profile', asst, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (gen_random_uuid(),%L,%L,true,%L)', 'x', 'zz-y@invalid.test', qql), 'deny') || E'\n';
  res := res || pg_temp.t('asst cannot re-role the probe viewer', asst, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L', r_ops, pv), 'rows:0') || E'\n';
  res := res || pg_temp.t('asst cannot make herself super_admin', asst, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L', r_super, a_id), 'blocked') || E'\n';
  res := res || pg_temp.t('asst cannot create a role carrying admin:companies', asst, A, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'zz sneaky', '{"admin:companies":true}', qql), 'deny') || E'\n';
  res := res || pg_temp.t('asst cannot create a role with string-true admin:companies', asst, A, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'zz sneaky2', '{"admin:companies":"true"}', qql), 'deny') || E'\n';
  -- ── the probe company_admin (non-super): the hole paths ──
  res := res || pg_temp.t('probe admin: can_admin_users(own company)', pa_auth, A, format('SELECT 1 WHERE public.d0d_can_admin_users(%L)', qql), 'n:1') || E'\n';
  res := res || pg_temp.t('probe admin: NOT admin of another company', pa_auth, A, format('SELECT 1 WHERE public.d0d_can_admin_users(%L)', coalesce(oth, gen_random_uuid())), 'n:0') || E'\n';
  res := res || pg_temp.t('probe admin renames the probe viewer (legit)', pa_auth, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'zz renamed', pv), 'rows:1') || E'\n';
  res := res || pg_temp.t('probe admin re-roles the probe viewer to operations_tech (legit)', pa_auth, A, format('UPDATE erp_user_company_roles SET role_id=%L, updated_at=now() WHERE user_id=%L AND company_id=%L', r_ops, pv, qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('probe admin sets overrides on the probe viewer (legit)', pa_auth, A, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L AND company_id=%L', '{"finance:ap:read":true}', pv, qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('probe admin inserts a profile in own company (design allows)', pa_auth, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (gen_random_uuid(),%L,%L,true,%L)', 'zz', 'zz-z@invalid.test', qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT assign the probe viewer super_admin', pa_auth, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', r_super, pv, qql), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT make self super_admin', pa_auth, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', r_super, pa, qql), 'rows:0') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT edit own overrides', pa_auth, A, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L AND company_id=%L', '{"admin:roles":true}', pa, qql), 'rows:0') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT put admin:companies in overrides', pa_auth, A, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L AND company_id=%L', '{"admin:companies":true}', pv, qql), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT demote Brandon (super) in Quarryquip', pa_auth, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', r_view, b_id, qql), 'blocked') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT demote Vanessa (super)', pa_auth, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', r_view, v_id, qql), 'blocked') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT deactivate Vanessa', pa_auth, A, format('UPDATE erp_users SET is_active=false WHERE id=%L', v_id), 'blocked') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT rename Brandon', pa_auth, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', b_id), 'blocked') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT deactivate self (lockout)', pa_auth, A, format('UPDATE erp_users SET is_active=false WHERE id=%L', pa), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT change a colleague email', pa_auth, A, format('UPDATE erp_users SET email=%L WHERE id=%L', 'zz@evil.invalid', pv), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT re-point a colleague auth_user_id', pa_auth, A, format('UPDATE erp_users SET auth_user_id=gen_random_uuid() WHERE id=%L', pv), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT re-point an assignment to another user', pa_auth, A, format('UPDATE erp_user_company_roles SET user_id=%L WHERE user_id=%L AND company_id=%L', k_id, pv, qql), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT create a role carrying admin:companies', pa_auth, A, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'zz sneaky3', '{"admin:companies":true}', qql), 'deny') || E'\n';
  res := res || pg_temp.t('probe admin CANNOT delete assignments (no policy)', pa_auth, A, format('DELETE FROM erp_user_company_roles WHERE user_id=%L', pv), 'rows:0') || E'\n';
  IF oth IS NOT NULL THEN
    res := res || pg_temp.t('probe admin CANNOT read another company assignments', pa_auth, A, format('SELECT 1 FROM erp_user_company_roles WHERE company_id=%L', oth), 'n:0') || E'\n';
    res := res || pg_temp.t('probe admin CANNOT assign roles in another company', pa_auth, A, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L)', pv, oth, r_cadm), 'deny') || E'\n';
    res := res || pg_temp.t('probe admin CANNOT insert a profile in another company', pa_auth, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (gen_random_uuid(),%L,%L,true,%L)', 'zz', 'zz-q@invalid.test', oth), 'deny') || E'\n';
    res := res || pg_temp.t('probe admin CANNOT move self to another company', pa_auth, A, format('UPDATE erp_users SET company_id=%L WHERE id=%L', oth, pa), 'deny') || E'\n';
  END IF;
  -- ── plain staff probe ──
  res := res || pg_temp.t('probe viewer CANNOT rename the probe admin', pv_auth, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', pa), 'rows:0') || E'\n';
  res := res || pg_temp.t('probe viewer CANNOT insert a profile', pv_auth, A, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (gen_random_uuid(),%L,%L,true,%L)', 'x', 'zz-w@invalid.test', qql), 'deny') || E'\n';
  res := res || pg_temp.t('probe viewer CANNOT rename self', pv_auth, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', pv), 'deny') || E'\n';
  res := res || pg_temp.t('probe viewer CAN write own last_login', pv_auth, A, format('UPDATE erp_users SET last_login=now() WHERE id=%L', pv), 'rows:1') || E'\n';
  -- ── super admins keep full ability ──
  res := res || pg_temp.t('brandon renames the probe viewer', brandon, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'zz b', pv), 'rows:1') || E'\n';
  res := res || pg_temp.t('vanessa renames the probe viewer', vanessa, A, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'zz v', pv), 'rows:1') || E'\n';
  res := res || pg_temp.t('brandon deactivates the probe viewer', brandon, A, format('UPDATE erp_users SET is_active=false WHERE id=%L', pv), 'rows:1') || E'\n';
  res := res || pg_temp.t('brandon changes the probe viewer email', brandon, A, format('UPDATE erp_users SET email=%L WHERE id=%L', 'zz-b@invalid.test', pv), 'rows:1') || E'\n';
  res := res || pg_temp.t('vanessa assigns the probe admin super_admin (super may)', vanessa, A, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', r_super, pa, qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('brandon sets overrides on the probe viewer', brandon, A, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L AND company_id=%L', '{"admin:companies":true}', pv, qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('brandon creates a custom super role', brandon, A, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'zz probe super', '{"admin:companies":true}', qql), 'rows:1') || E'\n';
  res := res || pg_temp.t('brandon cannot delete assignments via REST either', brandon, A, format('DELETE FROM erp_user_company_roles WHERE user_id=%L', pv), 'rows:0') || E'\n';

  SELECT count(*) INTO fails FROM regexp_split_to_table(res, E'\n') l WHERE l LIKE 'FAIL %';
  RAISE EXCEPTION E'D0d LIVE VERIFY (everything rolled back)\nRESULTS\n%FAILS: %', res, fails;
END $$;