-- AFTER the migration: structure, helper unit tests, read scoping. Each script section is its own transaction, rolled back.
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  n int;
BEGIN
  -- ── structure ──
  PERFORM t_expect('struct: ucr has 3 permissive + 2 restrictive policies', (SELECT count(*)::text FROM pg_policies WHERE tablename='erp_user_company_roles'), '5');
  PERFORM t_expect('struct: ucr permissive set', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='erp_user_company_roles' AND permissive='PERMISSIVE'), 'ucr_insert,ucr_select_own,ucr_update');
  PERFORM t_expect('struct: ucr restrictive set', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='erp_user_company_roles' AND permissive='RESTRICTIVE'), 'd0_no_anon,d0_staff_only');
  PERFORM t_expect('struct: ucr has no permissive DELETE/ALL policy (delete refused)', (SELECT count(*)::text FROM pg_policies WHERE tablename='erp_user_company_roles' AND permissive='PERMISSIVE' AND cmd IN ('DELETE','ALL')), '0');
  PERFORM t_expect('struct: ucr policies all TO authenticated/anon (none public)', (SELECT count(*)::text FROM pg_policies WHERE tablename='erp_user_company_roles' AND roles NOT IN ('{authenticated}','{anon}')), '0');
  PERFORM t_expect('struct: erp_users insert+update TO authenticated', (SELECT count(*)::text FROM pg_policies WHERE tablename='erp_users' AND policyname IN ('rls_erp_users_insert','rls_erp_users_update') AND roles='{authenticated}'), '2');
  PERFORM t_expect('struct: erp_users select+delete policies untouched', (SELECT string_agg(policyname||':'||roles::text, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='erp_users' AND policyname IN ('rls_erp_users_select','rls_erp_users_delete')), 'rls_erp_users_delete:{public},rls_erp_users_select:{public}');
  PERFORM t_expect('struct: erp_users has anon deny but NO staff-only restrictive', (SELECT string_agg(policyname, ',') FROM pg_policies WHERE tablename='erp_users' AND permissive='RESTRICTIVE'), 'd0_no_anon');
  PERFORM t_expect('struct: erp_roles policies', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='erp_roles'), 'd0_no_anon,roles_delete,roles_insert,roles_select,roles_update');
  PERFORM t_expect('struct: erp_roles policies none public', (SELECT count(*)::text FROM pg_policies WHERE tablename='erp_roles' AND roles NOT IN ('{authenticated}','{anon}')), '0');
  PERFORM t_expect('struct: 3 d0d triggers', (SELECT count(*)::text FROM pg_trigger WHERE tgname IN ('d0d_ucr_guard','d0d_users_guard','d0d_roles_guard') AND NOT tgisinternal), '3');
  PERFORM t_expect('struct: 9 helpers + 3 trigger fns exist', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%' AND pronamespace='public'::regnamespace), '12');
  PERFORM t_expect('struct: every d0d function pins search_path', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%' AND pronamespace='public'::regnamespace AND NOT (proconfig::text LIKE '%search_path=public, pg_temp%')), '0');
  PERFORM t_expect('struct: no d0d function executable by PUBLIC or anon', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%' AND pronamespace='public'::regnamespace AND (has_function_privilege('anon', oid, 'EXECUTE') OR coalesce(proacl::text,'=X') ~ '(^|,|\{)=X')), '0');
  PERFORM t_expect('struct: authenticated can execute the 9 helpers', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%' AND proname NOT LIKE '%guard' AND pronamespace='public'::regnamespace AND has_function_privilege('authenticated', oid, 'EXECUTE')), '9');
  PERFORM t_expect('struct: authenticated cannot execute trigger functions', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%guard' AND has_function_privilege('authenticated', oid, 'EXECUTE')), '0');
  PERFORM t_expect('struct: trigger functions are SECURITY INVOKER (so current_user is the real caller)', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%guard' AND prosecdef), '0');
  PERFORM t_expect('struct: helpers except d0d_atom_true are SECURITY DEFINER', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%' AND proname NOT LIKE '%guard' AND proname<>'d0d_atom_true' AND prosecdef), '8');
  PERFORM t_expect('struct: UNIQUE(user_id, company_id) exists on ucr (the self-INSERT equivalence relies on it)', (SELECT count(*)::text FROM pg_constraint WHERE conrelid='public.erp_user_company_roles'::regclass AND contype='u' AND pg_get_constraintdef(oid) = 'UNIQUE (user_id, company_id)'), '1');
  PERFORM t_expect('struct: RLS still enabled on the 3 tables', (SELECT count(*)::text FROM pg_class WHERE relname IN ('erp_users','erp_roles','erp_user_company_roles') AND relrowsecurity), '3');

  -- ── d0d_atom_true (same truthiness as (x->>k)::boolean, never raises) ──
  PERFORM t_expect('atom: true', public.d0d_atom_true('{"a":true}','a')::text, 'true');
  PERFORM t_expect('atom: string "true" counts (live helpers cast it)', public.d0d_atom_true('{"a":"true"}','a')::text, 'true');
  PERFORM t_expect('atom: number 1 counts (live helpers cast it)', public.d0d_atom_true('{"a":1}','a')::text, 'true');
  PERFORM t_expect('atom: string "yes" counts', public.d0d_atom_true('{"a":"yes"}','a')::text, 'true');
  PERFORM t_expect('atom: false', public.d0d_atom_true('{"a":false}','a')::text, 'false');
  PERFORM t_expect('atom: 0', public.d0d_atom_true('{"a":0}','a')::text, 'false');
  PERFORM t_expect('atom: garbage string does not raise', public.d0d_atom_true('{"a":"maybe"}','a')::text, 'false');
  PERFORM t_expect('atom: nested object does not raise', public.d0d_atom_true('{"a":{"x":true}}','a')::text, 'false');
  PERFORM t_expect('atom: missing key', public.d0d_atom_true('{"b":true}','a')::text, 'false');
  PERFORM t_expect('atom: array', public.d0d_atom_true('[true]','a')::text, 'false');
  PERFORM t_expect('atom: null', coalesce(public.d0d_atom_true(NULL,'a')::text,'null'), 'false');
  PERFORM t_expect('atom: agrees with the live is_super_admin cast for string true', (SELECT ((('{"admin:companies":"true"}'::jsonb)->>'admin:companies')::boolean)::text), 'true');

  -- ── d0d_can_admin_users: company scoped ──
  PERFORM t_expect('adm: company_admin C1 on C1', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:1');
  PERFORM t_expect('adm: company_admin C1 NOT on C2', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C2||''')'), 'n:0');
  PERFORM t_expect('adm: mixed admin in C1', t_count(A, mixed, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:1');
  PERFORM t_expect('adm: mixed NOT admin in C2 (member there as ops)', t_count(A, mixed, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C2||''')'), 'n:0');
  PERFORM t_expect('adm: company_admin C2 on C2', t_count(A, cadm2, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C2||''')'), 'n:1');
  PERFORM t_expect('adm: company_admin C2 NOT on C1', t_count(A, cadm2, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: dual admin on both', t_count(A, dual, 'SELECT 1 FROM (VALUES (1)) v WHERE public.d0d_can_admin_users('''||C1||''') AND public.d0d_can_admin_users('''||C2||''')'), 'n:1');
  PERFORM t_expect('adm: super on C1', t_count(A, sup, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:1');
  PERFORM t_expect('adm: super on C2', t_count(A, sup, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C2||''')'), 'n:1');
  PERFORM t_expect('adm: second super (C1 row only) on C2', t_count(A, sup2, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C2||''')'), 'n:1');
  PERFORM t_expect('adm: Office Admin (admin:roles only) is not a user admin', t_count(A, offc, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: ops not admin', t_count(A, ops, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: plain viewer not admin', t_count(A, viewr, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: deactivated staff not admin', t_count(A, gone, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: client-like not admin', t_count(A, clnt, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('adm: anon cannot even execute helper', t_count('anon', NULL, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'err:42501');
  PERFORM t_expect('me: my_erp_user_id of company_admin', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_my_erp_user_id()='''||U03||''''), 'n:1');
  PERFORM t_expect('me: null for deactivated', t_count(A, gone, 'SELECT 1 WHERE public.d0d_my_erp_user_id() IS NULL'), 'n:1');
  PERFORM t_expect('me: null for client-like', t_count(A, clnt, 'SELECT 1 WHERE public.d0d_my_erp_user_id() IS NULL'), 'n:1');
  PERFORM t_expect('atom-held: Office Admin holds admin:roles in C1', t_count(A, offc, 'SELECT 1 WHERE public.d0d_actor_has_atom('''||C1||''',''admin:roles'')'), 'n:1');
  PERFORM t_expect('atom-held: Office Admin lacks admin:users', t_count(A, offc, 'SELECT 1 WHERE public.d0d_actor_has_atom('''||C1||''',''admin:users'')'), 'n:0');
  PERFORM t_expect('atom-held: atoms are company scoped (mixed holds admin:users only in C1)', t_count(A, mixed, 'SELECT 1 WHERE public.d0d_actor_has_atom('''||C2||''',''admin:users'')'), 'n:0');
  PERFORM t_expect('role_is_super: super role true for staff', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_role_is_super('''||RS||''')'), 'n:1');
  PERFORM t_expect('role_is_super: company_admin false', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_role_is_super('''||RA||''')'), 'n:0');
  PERFORM t_expect('role_is_super: no oracle for client-like', t_count(A, clnt, 'SELECT 1 WHERE public.d0d_role_is_super('''||RS||''')'), 'n:0');
  PERFORM t_expect('user_is_super: super user', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_user_is_super('''||U04||''')'), 'n:1');
  PERFORM t_expect('user_is_super: ordinary user', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_user_is_super('''||U01||''')'), 'n:0');
  PERFORM t_expect('user_is_super: no oracle for client-like', t_count(A, clnt, 'SELECT 1 WHERE public.d0d_user_is_super('''||U04||''')'), 'n:0');
  PERFORM t_expect('assignable: company_admin cannot assign super role', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''','''||RS||''')'), 'n:0');
  PERFORM t_expect('assignable: super can assign super role', t_count(A, sup, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''','''||RS||''')'), 'n:1');
  PERFORM t_expect('assignable: global role ok for company_admin', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''','''||RV||''')'), 'n:1');
  PERFORM t_expect('assignable: own-company custom role ok', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''','''||R1||''')'), 'n:1');
  PERFORM t_expect('assignable: other-company custom role refused (even for super)', t_count(A, sup, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''','''||R2||''')'), 'n:0');
  PERFORM t_expect('assignable: unknown role refused', t_count(A, sup, 'SELECT 1 WHERE public.d0d_role_assignable('''||C1||''',gen_random_uuid())'), 'n:0');
  PERFORM t_expect('overrides_ok: plain overrides fine', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_overrides_ok(''{"finance:ap:read":true}'')'), 'n:1');
  PERFORM t_expect('overrides_ok: admin:companies refused for non-super', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_overrides_ok(''{"admin:companies":true}'')'), 'n:0');
  PERFORM t_expect('overrides_ok: admin:companies allowed for super', t_count(A, sup, 'SELECT 1 WHERE public.d0d_overrides_ok(''{"admin:companies":true}'')'), 'n:1');
END $$;
ROLLBACK;

-- read scoping (no state change)
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
BEGIN
  -- ucr SELECT
  PERFORM t_expect('ucr sel: company_admin C1 sees the 10 C1 rows', t_count(A, cadm, 'SELECT 1 FROM erp_user_company_roles'), 'n:10');
  PERFORM t_expect('ucr sel: company_admin C1 sees no C2 row', t_count(A, cadm, 'SELECT 1 FROM erp_user_company_roles WHERE company_id='''||C2||''''), 'n:0');
  PERFORM t_expect('ucr sel: mixed (admin C1, ops C2) sees C1 rows + only OWN C2 row', t_count(A, mixed, 'SELECT 1 FROM erp_user_company_roles'), 'n:11');
  PERFORM t_expect('ucr sel: mixed cannot read other C2 assignments', t_count(A, mixed, 'SELECT 1 FROM erp_user_company_roles WHERE company_id='''||C2||''' AND user_id<>'''||U10||''''), 'n:0');
  PERFORM t_expect('ucr sel: company_admin C2 sees the 6 C2 rows only', t_count(A, cadm2, 'SELECT 1 FROM erp_user_company_roles'), 'n:6');
  PERFORM t_expect('ucr sel: company_admin C2 sees no C1 row', t_count(A, cadm2, 'SELECT 1 FROM erp_user_company_roles WHERE company_id='''||C1||''''), 'n:0');
  PERFORM t_expect('ucr sel: super sees all 16', t_count(A, sup, 'SELECT 1 FROM erp_user_company_roles'), 'n:16');
  PERFORM t_expect('ucr sel: second super sees all 16', t_count(A, sup2, 'SELECT 1 FROM erp_user_company_roles'), 'n:16');
  PERFORM t_expect('ucr sel: dual admin sees all 16', t_count(A, dual, 'SELECT 1 FROM erp_user_company_roles'), 'n:16');
  PERFORM t_expect('ucr sel: plain viewer sees only own row', t_count(A, viewr, 'SELECT 1 FROM erp_user_company_roles'), 'n:1');
  PERFORM t_expect('ucr sel: ops sees only own row', t_count(A, ops, 'SELECT 1 FROM erp_user_company_roles'), 'n:1');
  PERFORM t_expect('ucr sel: Office Admin (admin:roles only) sees only own row', t_count(A, offc, 'SELECT 1 FROM erp_user_company_roles'), 'n:1');
  PERFORM t_expect('ucr sel: deactivated sees nothing', t_count(A, gone, 'SELECT 1 FROM erp_user_company_roles'), 'n:0');
  PERFORM t_expect('ucr sel: client-like sees nothing', t_count(A, clnt, 'SELECT 1 FROM erp_user_company_roles'), 'n:0');
  PERFORM t_expect('ucr sel: anon sees nothing', t_count('anon', NULL, 'SELECT 1 FROM erp_user_company_roles'), 'n:0');
  PERFORM t_expect('ucr sel: service_role bypasses RLS', t_count('service_role', NULL, 'SELECT 1 FROM erp_user_company_roles'), 'n:16');
  -- erp_users SELECT (policy unchanged)
  PERFORM t_expect('users sel: plain viewer sees the 10 C1 colleagues', t_count(A, viewr, 'SELECT 1 FROM erp_users'), 'n:10');
  PERFORM t_expect('users sel: viewer sees no C2 profile', t_count(A, viewr, 'SELECT 1 FROM erp_users WHERE company_id='''||C2||''''), 'n:0');
  PERFORM t_expect('users sel: company_admin C2 sees the 3 C2 profiles', t_count(A, cadm2, 'SELECT 1 FROM erp_users'), 'n:3');
  PERFORM t_expect('users sel: mixed (member of both) sees 13', t_count(A, mixed, 'SELECT 1 FROM erp_users'), 'n:13');
  PERFORM t_expect('users sel: super sees 13', t_count(A, sup, 'SELECT 1 FROM erp_users'), 'n:13');
  PERFORM t_expect('users sel: deactivated user can still read OWN row (login path)', t_count(A, gone, 'SELECT 1 FROM erp_users'), 'n:1');
  PERFORM t_expect('users sel: client-like sees nothing', t_count(A, clnt, 'SELECT 1 FROM erp_users'), 'n:0');
  PERFORM t_expect('users sel: anon is refused (select policy calls is_super_admin, revoked from anon)', t_count('anon', NULL, 'SELECT 1 FROM erp_users'), 'err:42501');
  -- erp_roles SELECT: staff only
  PERFORM t_expect('roles sel: ops reads global + own-company roles (8)', t_count(A, ops, 'SELECT 1 FROM erp_roles'), 'n:8');
  PERFORM t_expect('roles sel: viewer reads roles (8)', t_count(A, viewr, 'SELECT 1 FROM erp_roles'), 'n:8');
  PERFORM t_expect('roles sel: Office Admin reads roles (8)', t_count(A, offc, 'SELECT 1 FROM erp_roles'), 'n:8');
  PERFORM t_expect('roles sel: super reads roles', t_count(A, sup, 'SELECT 1 FROM erp_roles'), 'n:9');
  PERFORM t_expect('roles sel: client-like login cannot read roles', t_count(A, clnt, 'SELECT 1 FROM erp_roles'), 'n:0');
  PERFORM t_expect('roles sel: deactivated cannot read roles', t_count(A, gone, 'SELECT 1 FROM erp_roles'), 'n:0');
  PERFORM t_expect('roles sel: anon cannot read roles', t_count('anon', NULL, 'SELECT 1 FROM erp_roles'), 'n:0');
  PERFORM t_expect('roles sel: service_role sees all', t_count('service_role', NULL, 'SELECT 1 FROM erp_roles'), 'n:9');
  -- login / loadAndBuildPerms shapes still work for every active staff member
  PERFORM t_expect('login: ops reads own active profile', t_count(A, ops, 'SELECT 1 FROM erp_users WHERE auth_user_id='''||ops||''' AND is_active=true'), 'n:1');
  PERFORM t_expect('login: ops reads own ucr row (role_id, permission_overrides)', t_count(A, ops, 'SELECT role_id, permission_overrides FROM erp_user_company_roles WHERE user_id='''||U01||''' AND company_id='''||C1||''''), 'n:1');
  PERFORM t_expect('login: ops reads own role permissions', t_count(A, ops, 'SELECT r.permissions FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE u.user_id='''||U01||''' AND u.company_id='''||C1||''''), 'n:1');
  PERFORM t_expect('login: Office Admin custom role resolves', t_count(A, offc, 'SELECT r.permissions FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE u.user_id='''||U05||''''), 'n:1');
  PERFORM t_expect('login: multi-company super reads both own rows', t_count(A, sup, 'SELECT 1 FROM erp_user_company_roles WHERE user_id='''||U04||''''), 'n:2');
  PERFORM t_expect('login: user admin lists role members with the erp_users embed', t_count(A, cadm, 'SELECT u.*, e.full_name FROM erp_user_company_roles u JOIN erp_users e ON e.id=u.user_id WHERE u.role_id='''||RO||''' AND u.company_id='''||C1||''''), 'n:2');
END $$;
ROLLBACK;
-- ═══ ucr: refusals (no state may change) ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  UPD text := 'UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L';
  INS text := 'INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides) VALUES (%L,%L,%L,''{}'')';
  OVR text := 'UPDATE erp_user_company_roles SET permission_overrides=%L, updated_at=now() WHERE user_id=%L AND company_id=%L';
BEGIN
  -- privilege escalation: super role
  PERFORM t_deny('ucr: company_admin cannot assign super_admin to a colleague (update)', t_dmlm(A, cadm, format(UPD, RS, U01, C1)));
  PERFORM t_deny('ucr: company_admin cannot assign super_admin (insert)', t_dmlm(A, cadm, format(INS, U07, C1, RS)));
  PERFORM t_deny('ucr: company_admin cannot upsert a super_admin assignment', t_dmlm(A, cadm, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L) ON CONFLICT (user_id, company_id) DO UPDATE SET role_id=EXCLUDED.role_id', U01, C1, RS)));
  PERFORM t_deny('ucr: self-upsert of own row refused', t_dmlm(A, cadm, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L) ON CONFLICT (user_id, company_id) DO UPDATE SET role_id=EXCLUDED.role_id', U03, C1, RV)));
  PERFORM t_expect('ucr: company_admin cannot give SELF the super role (row filtered)', t_dmlm(A, cadm, format(UPD, RS, U03, C1)), 'rows:0');
  PERFORM t_expect('ucr: company_admin cannot change own role at all', t_dmlm(A, cadm, format(UPD, RV, U03, C1)), 'rows:0');
  PERFORM t_expect('ucr: company_admin cannot edit own overrides', t_dmlm(A, cadm, format(OVR, '{"finance:ap:read":true}', U03, C1)), 'rows:0');
  PERFORM t_expect('ucr: dual admin cannot edit own overrides either', t_dmlm(A, dual, format(OVR, '{"finance:ap:read":true}', U13, C1)), 'rows:0');
  PERFORM t_expect('ucr: admin cannot demote a super admin row (Brandon-like)', t_dmlm(A, cadm, format(UPD, RV, U04, C1)), 'rows:0');
  PERFORM t_expect('ucr: admin cannot demote the second super admin', t_dmlm(A, cadm, format(UPD, RV, U08, C1)), 'rows:0');
  PERFORM t_expect('ucr: admin cannot edit overrides of a super admin', t_dmlm(A, cadm, format(OVR, '{}', U04, C1)), 'rows:0');
  -- overrides can not mint admin:companies
  PERFORM t_deny('ucr: overrides admin:companies=true refused', t_dmlm(A, cadm, format(OVR, '{"admin:companies":true}', U01, C1)));
  PERFORM t_deny('ucr: overrides admin:companies="true" (string) refused', t_dmlm(A, cadm, format(OVR, '{"admin:companies":"true"}', U01, C1)));
  PERFORM t_deny('ucr: overrides admin:companies=1 refused', t_dmlm(A, cadm, format(OVR, '{"admin:companies":1}', U01, C1)));
  PERFORM t_deny('ucr: insert with admin:companies override refused', t_dmlm(A, cadm, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides) VALUES (%L,%L,%L,''{"admin:companies":true}'')', U07, C1, RO)));
  -- cross-company administration
  PERFORM t_deny('ucr: admin of C1 cannot insert an assignment in C2', t_dmlm(A, cadm, format(INS, U07, C2, RO)));
  PERFORM t_expect('ucr: admin of C1 cannot update a C2 assignment', t_dmlm(A, cadm, format(UPD, RV, U12, C2)), 'rows:0');
  PERFORM t_deny('ucr: mixed (admin C1, only ops in C2) cannot insert in C2', t_dmlm(A, mixed, format(INS, U11, C2, RO)));
  PERFORM t_expect('ucr: mixed cannot update a C2 assignment (user_has_perm hole closed)', t_dmlm(A, mixed, format(UPD, RV, U12, C2)), 'rows:0');
  PERFORM t_deny('ucr: admin of C2 cannot insert in C1', t_dmlm(A, cadm2, format(INS, U07, C1, RO)));
  PERFORM t_expect('ucr: admin of C2 cannot update a C1 assignment', t_dmlm(A, cadm2, format(UPD, RV, U01, C1)), 'rows:0');
  -- role / company mismatch
  PERFORM t_deny('ucr: role owned by C2 cannot be inserted into C1', t_dmlm(A, cadm, format(INS, U07, C1, R2)));
  PERFORM t_deny('ucr: role owned by C2 cannot be updated into a C1 row', t_dmlm(A, cadm, format(UPD, R2, U01, C1)));
  PERFORM t_deny('ucr: role owned by C1 cannot be used in C2', t_dmlm(A, cadm2, format(UPD, R1, U12, C2)));
  PERFORM t_deny('ucr: unknown role refused', t_dmlm(A, cadm, format(INS, U07, C1, 'ffffffff-ffff-ffff-ffff-ffffffffffff')));
  -- re-pointing rows
  PERFORM t_denym('ucr: user_id of a row cannot be changed', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET user_id=%L WHERE user_id=%L AND company_id=%L', U12, U11, C1)), 'cannot be changed');
  PERFORM t_denym('ucr: company_id of a row cannot be changed (single-company admin)', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET company_id=%L WHERE user_id=%L AND company_id=%L', C2, U11, C1)), 'cannot be changed');
  PERFORM t_denym('ucr: dual admin cannot move a row between their two companies', t_dmlm(A, dual, format('UPDATE erp_user_company_roles SET company_id=%L WHERE user_id=%L AND company_id=%L', C2, U11, C1)), 'cannot be changed');
  PERFORM t_denym('ucr: dual admin cannot re-point a row to another user', t_dmlm(A, dual, format('UPDATE erp_user_company_roles SET user_id=%L WHERE user_id=%L AND company_id=%L', U12, U11, C1)), 'cannot be changed');
  PERFORM t_denym('ucr: row id cannot be changed', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET id=gen_random_uuid() WHERE user_id=%L AND company_id=%L', U11, C1)), 'cannot be changed');
  -- non-admins and non-staff
  PERFORM t_expect('ucr: plain staff cannot edit own overrides', t_dmlm(A, viewr, format(OVR, '{"finance:ap:read":true}', U02, C1)), 'rows:0');
  PERFORM t_expect('ucr: plain staff cannot change own role', t_dmlm(A, viewr, format(UPD, RO, U02, C1)), 'rows:0');
  PERFORM t_expect('ucr: plain staff cannot edit a colleague overrides', t_dmlm(A, viewr, format(OVR, '{}', U01, C1)), 'rows:0');
  PERFORM t_expect('ucr: ops cannot edit overrides', t_dmlm(A, ops, format(OVR, '{}', U01, C1)), 'rows:0');
  PERFORM t_expect('ucr: Office Admin (admin:roles, no admin:users) cannot re-role', t_dmlm(A, offc, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('ucr: Office Admin cannot insert', t_dmlm(A, offc, format(INS, U07, C1, RO)));
  PERFORM t_deny('ucr: plain staff cannot insert', t_dmlm(A, viewr, format(INS, U07, C1, RO)));
  PERFORM t_deny('ucr: ops cannot insert', t_dmlm(A, ops, format(INS, U07, C1, RO)));
  PERFORM t_expect('ucr: deactivated admin-role holder cannot update', t_dmlm(A, gone, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('ucr: deactivated cannot insert', t_dmlm(A, gone, format(INS, U07, C1, RO)));
  PERFORM t_expect('ucr: client-like cannot update', t_dmlm(A, clnt, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('ucr: client-like cannot insert', t_dmlm(A, clnt, format(INS, U07, C1, RO)));
  PERFORM t_expect('ucr: anon cannot update', t_dmlm('anon', NULL, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('ucr: anon cannot insert', t_dmlm('anon', NULL, format(INS, U07, C1, RO)));
  -- delete: no policy
  PERFORM t_expect('ucr: company_admin cannot delete', t_dmlm(A, cadm, format('DELETE FROM erp_user_company_roles WHERE user_id=%L', U01)), 'rows:0');
  PERFORM t_expect('ucr: super admin cannot delete via REST either (no policy)', t_dmlm(A, sup, format('DELETE FROM erp_user_company_roles WHERE user_id=%L', U01)), 'rows:0');
  PERFORM t_expect('ucr: dual cannot delete', t_dmlm(A, dual, 'DELETE FROM erp_user_company_roles'), 'rows:0');
  -- statements without a WHERE clause are not filtered by the SELECT policy, so USING alone must scope them
  PERFORM t_expect('ucr: mass update by company_admin touches only C1 rows that are not self/super (7)', t_dmlm(A, cadm, 'UPDATE erp_user_company_roles SET permission_overrides=''{}'''), 'rows:7');
  PERFORM t_expect('ucr: mass update by plain staff touches nothing', t_dmlm(A, viewr, 'UPDATE erp_user_company_roles SET permission_overrides=''{}'''), 'rows:0');
  PERFORM t_expect('ucr: all 16 rows still there', (SELECT count(*)::text FROM erp_user_company_roles), '16');
  PERFORM t_expect('ucr: no role changed during the refusal run', (SELECT count(*)::text FROM erp_user_company_roles WHERE permission_overrides <> '{}'::jsonb), '0');
  PERFORM t_expect('ucr: nobody became super (is_super_admin for ops/cadm/offc/viewr)', (SELECT count(*)::text FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE r.permissions ? 'admin:companies' AND u.user_id NOT IN (U04::uuid, U08::uuid)), '0');
END $$;
ROLLBACK;

-- ═══ ucr: legitimate flows (exact REST shapes of the app) ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  UPD text := 'UPDATE erp_user_company_roles SET role_id=%L, updated_at=now() WHERE user_id=%L AND company_id=%L';
  INS text := 'INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides) VALUES (%L,%L,%L,''{}'')';
  OVR text := 'UPDATE erp_user_company_roles SET permission_overrides=%L, updated_at=now() WHERE user_id=%L AND company_id=%L';
BEGIN
  PERFORM t_expect('ok: Edit Overrides modal (company_admin sets overrides)', t_dmlm(A, cadm, format(OVR, '{"finance:ap:read":true,"finance:ap:write":false}', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: override with admin:companies=false is allowed', t_dmlm(A, cadm, format(OVR, '{"admin:companies":false}', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: Clear Overrides', t_dmlm(A, cadm, format(OVR, '{}', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: Edit Permissions changes role (global viewer)', t_dmlm(A, cadm, format(UPD, RV, U01, C1)), 'rows:1');
  PERFORM t_expect('ok: ... back to operations_tech', t_dmlm(A, cadm, format(UPD, RO, U01, C1)), 'rows:1');
  PERFORM t_expect('ok: assign a C1-owned custom role in C1', t_dmlm(A, cadm, format(UPD, R1, U11, C1)), 'rows:1');
  PERFORM t_expect('ok: Create User / Edit Permissions insert (new C1 membership for a C2 user)', t_dmlm(A, cadm, format(INS, U07, C1, RO)), 'rows:1');
  PERFORM t_expect('ok: the new member reads their new row', t_count(A, ops2, 'SELECT 1 FROM erp_user_company_roles WHERE company_id='''||C1||''' AND user_id='''||U07||''''), 'n:1');
  PERFORM t_expect('ok: upsert shape over an existing colleague row (non-super role)', t_dmlm(A, cadm, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L) ON CONFLICT (user_id, company_id) DO UPDATE SET role_id=EXCLUDED.role_id', U02, C1, RO)), 'rows:1');
  PERFORM t_expect('ok: company_admin C2 re-roles a C2 user with a C2 custom role', t_dmlm(A, cadm2, format(UPD, R2, U12, C2)), 'rows:1');
  PERFORM t_expect('ok: company_admin C2 inserts into C2', t_dmlm(A, cadm2, format(INS, U01, C2, RV)), 'rows:1');
  PERFORM t_expect('ok: dual admin edits in C1', t_dmlm(A, dual, format(UPD, RV, U11, C1)), 'rows:1');
  PERFORM t_expect('ok: dual admin edits in C2', t_dmlm(A, dual, format(UPD, R2, U12, C2)), 'rows:1');
  PERFORM t_expect('ok: mixed admin edits in C1 (their admin company)', t_dmlm(A, mixed, format(UPD, RV, U01, C1)), 'rows:1');
  -- super admin keeps full ability
  PERFORM t_expect('ok: super assigns super_admin', t_dmlm(A, sup, format(UPD, RS, U11, C1)), 'rows:1');
  PERFORM t_expect('ok: ... and that user is now a platform super admin', t_count(A, sp1, 'SELECT 1 WHERE public.is_super_admin()'), 'n:1');
  PERFORM t_expect('ok: super inserts a super assignment in C2', t_dmlm(A, sup, format(INS, U11, C2, RS)), 'rows:1');
  PERFORM t_expect('ok: super sets admin:companies override', t_dmlm(A, sup, format(OVR, '{"admin:companies":true}', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: super edits own row', t_dmlm(A, sup, format(OVR, '{"finance:ap:read":true}', U04, C1)), 'rows:1');
  PERFORM t_expect('ok: second super changes own assignment', t_dmlm(A, sup2, format(UPD, RS, U08, C1)), 'rows:1');
  PERFORM t_expect('ok: super demotes another super', t_dmlm(A, sup, format(UPD, RV, U08, C1)), 'rows:1');
  PERFORM t_expect('ok: super may re-point a row (company move)', t_dmlm(A, sup, format('UPDATE erp_user_company_roles SET company_id=%L WHERE user_id=%L AND company_id=%L', C2, U02, C1)), 'rows:1');
  PERFORM t_expect('ucr: even a super admin cannot use a role owned by another company', t_dmlm(A, sup, format(INS, U05, C2, R1)), 'err:42501|new row violates row-level security policy for table "erp_user_company_roles"');
END $$;
ROLLBACK;
-- ═══ erp_users: refusals ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSU text := 'INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)';
  NEWA text := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
BEGIN
  -- the client-takeover hole: staff status for an arbitrary login
  PERFORM t_deny('users ins: plain staff cannot insert a profile (client takeover)', t_dmlm(A, viewr, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: operations_tech cannot insert', t_dmlm(A, ops, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: Office Admin (admin:roles only) cannot insert', t_dmlm(A, offc, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: deactivated cannot insert', t_dmlm(A, gone, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: client-like cannot insert (self-promote to staff)', t_dmlm(A, clnt, format(INSU, clnt, 'me', 'me@t.test', C1)));
  PERFORM t_deny('users ins: anon cannot insert', t_dmlm('anon', NULL, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: admin of C1 cannot insert into C2', t_dmlm(A, cadm, format(INSU, NEWA, 'client', 'cl@t.test', C2)));
  PERFORM t_deny('users ins: mixed (not admin in C2) cannot insert into C2', t_dmlm(A, mixed, format(INSU, NEWA, 'client', 'cl@t.test', C2)));
  PERFORM t_deny('users ins: admin of C2 cannot insert into C1', t_dmlm(A, cadm2, format(INSU, NEWA, 'client', 'cl@t.test', C1)));
  PERFORM t_deny('users ins: admin cannot insert a profile without a company', t_dmlm(A, cadm, format(INSU, NEWA, 'client', 'cl@t.test', NULL)));
  PERFORM t_expect('users ins: duplicate auth_user_id stays unique (as super)', left(t_dmlm(A, sup, format(INSU, ops, 'dup', 'dup@t.test', C1)), 9), 'err:23505');
  PERFORM t_expect('users ins: the attempted client login is NOT staff', t_count(A, NEWA::uuid, 'SELECT 1 WHERE public.is_erp_staff()'), 'n:0');

  -- UPDATE: colleagues
  PERFORM t_expect('users upd: plain staff cannot rename a colleague', t_dmlm(A, viewr, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'pwned', U01)), 'rows:0');
  PERFORM t_expect('users upd: plain staff cannot deactivate a colleague', t_dmlm(A, viewr, format('UPDATE erp_users SET is_active=false WHERE id=%L', U11)), 'rows:0');
  PERFORM t_expect('users upd: plain staff cannot change a colleague email', t_dmlm(A, viewr, format('UPDATE erp_users SET email=%L WHERE id=%L', 'x@evil.test', U01)), 'rows:0');
  PERFORM t_expect('users upd: plain staff cannot change a colleague auth_user_id', t_dmlm(A, viewr, format('UPDATE erp_users SET auth_user_id=gen_random_uuid() WHERE id=%L', U01)), 'rows:0');
  PERFORM t_expect('users upd: staff cannot touch another company profile', t_dmlm(A, viewr, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U12)), 'rows:0');
  PERFORM t_expect('users upd: admin of C1 cannot touch a C2 profile', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U12)), 'rows:0');
  PERFORM t_expect('users upd: admin of C2 cannot touch a C1 profile', t_dmlm(A, cadm2, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)), 'rows:0');
  PERFORM t_expect('users upd: mixed (not admin in C2) cannot deactivate a C2 user', t_dmlm(A, mixed, format('UPDATE erp_users SET is_active=false WHERE id=%L', U12)), 'rows:0');
  PERFORM t_expect('users upd: Office Admin cannot rename a colleague', t_dmlm(A, offc, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)), 'rows:0');
  PERFORM t_expect('users upd: deactivated cannot update own row', t_dmlm(A, gone, 'UPDATE erp_users SET last_login=now() WHERE auth_user_id='''||gone||''''), 'rows:0');
  PERFORM t_expect('users upd: client-like cannot update', t_dmlm(A, clnt, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)), 'rows:0');
  PERFORM t_deny('users upd: anon cannot update', t_dmlm('anon', NULL, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)));
  -- UPDATE: self-service abuse
  PERFORM t_denym('users upd: staff cannot deactivate self', t_dmlm(A, viewr, format('UPDATE erp_users SET is_active=false WHERE id=%L', U02)), 'your own is_active');
  PERFORM t_denym('users upd: staff cannot move own company_id', t_dmlm(A, viewr, format('UPDATE erp_users SET company_id=%L WHERE auth_user_id=%L', C2, viewr)), 'your own is_active or company_id');
  PERFORM t_denym('users upd: staff cannot rename self', t_dmlm(A, viewr, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U02)), 'only last_login');
  PERFORM t_denym('users upd: staff cannot change own email', t_dmlm(A, viewr, format('UPDATE erp_users SET email=%L WHERE id=%L', 'x@t.test', U02)), 'email can only');
  PERFORM t_denym('users upd: staff cannot change own auth_user_id', t_dmlm(A, viewr, format('UPDATE erp_users SET auth_user_id=gen_random_uuid() WHERE id=%L', U02)), 'auth_user_id can only');
  PERFORM t_denym('users upd: last_login + full_name in one statement refused', t_dmlm(A, viewr, format('UPDATE erp_users SET last_login=now(), full_name=%L WHERE id=%L', 'x', U02)), 'only last_login');
  PERFORM t_denym('users upd: last_login + is_active in one statement refused', t_dmlm(A, viewr, format('UPDATE erp_users SET last_login=now(), is_active=false WHERE id=%L', U02)), 'your own is_active');
  PERFORM t_denym('users upd: last_login + company_id in one statement refused', t_dmlm(A, viewr, format('UPDATE erp_users SET last_login=now(), company_id=%L WHERE id=%L', C2, U02)), 'your own is_active');
  PERFORM t_denym('users upd: force_password_change cannot be set true on self', t_dmlm(A, viewr, format('UPDATE erp_users SET force_password_change=true WHERE id=%L', U02)), 'can only be cleared');
  PERFORM t_denym('users upd: id is immutable (staff)', t_dmlm(A, viewr, format('UPDATE erp_users SET id=gen_random_uuid() WHERE id=%L', U02)), 'immutable');
  PERFORM t_denym('users upd: created_at is immutable (staff)', t_dmlm(A, viewr, format('UPDATE erp_users SET created_at=now() - interval ''1 year'' WHERE id=%L', U02)), 'immutable');
  PERFORM t_denym('users upd: id is immutable even for a super admin', t_dmlm(A, sup, format('UPDATE erp_users SET id=gen_random_uuid() WHERE id=%L', U02)), 'immutable');
  PERFORM t_denym('users upd: created_at is immutable even for a super admin', t_dmlm(A, sup, format('UPDATE erp_users SET created_at=now() - interval ''1 year'' WHERE id=%L', U02)), 'immutable');
  -- mass update
  PERFORM t_denym('users upd: mass deactivate by staff hits own row and is refused', t_dmlm(A, viewr, 'UPDATE erp_users SET is_active=false'), 'your own is_active');
  PERFORM t_expect('users upd: ... nobody was deactivated', (SELECT count(*)::text FROM erp_users WHERE is_active), '12');
  PERFORM t_deny('users upd: mass rename by staff refused', t_dmlm(A, viewr, 'UPDATE erp_users SET full_name=''m'''));
  -- admin limits
  PERFORM t_expect('users upd: company_admin cannot touch a super admin profile that also lives in C2 (filtered)', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U04)), 'rows:0');
  PERFORM t_denym('users upd: company_admin cannot deactivate the second super admin', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=false WHERE id=%L', U08)), 'super admin profile');
  PERFORM t_denym('users upd: company_admin cannot change a colleague email', t_dmlm(A, cadm, format('UPDATE erp_users SET email=%L WHERE id=%L', 'x@evil.test', U01)), 'email can only');
  PERFORM t_denym('users upd: company_admin cannot hijack a colleague via auth_user_id', t_dmlm(A, cadm, format('UPDATE erp_users SET auth_user_id=gen_random_uuid() WHERE id=%L', U01)), 'auth_user_id can only');
  PERFORM t_denym('users upd: company_admin cannot deactivate self (lockout)', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=false WHERE id=%L', U03)), 'your own is_active');
  PERFORM t_denym('users upd: company_admin cannot move own company_id', t_dmlm(A, cadm, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C2, U03)), 'your own is_active or company_id');
  PERFORM t_denym('users upd: company_admin cannot set force_password_change on self', t_dmlm(A, cadm, format('UPDATE erp_users SET force_password_change=true WHERE id=%L', U03)), 'can only be cleared');
  PERFORM t_denym('users upd: company_admin cannot move a colleague into a company they do not administer', t_dmlm(A, cadm, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C2, U01)), 'administer');
  PERFORM t_denym('users upd: company_admin cannot null a colleague company', t_dmlm(A, cadm, format('UPDATE erp_users SET company_id=NULL WHERE id=%L', U01)), 'administer');
  PERFORM t_denym('users upd: Office Admin cannot rename self (not a user admin)', t_dmlm(A, offc, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U05)), 'only last_login');
  PERFORM t_deny('users upd: admin mass update that includes a super admin is refused atomically', t_dmlm(A, cadm, 'UPDATE erp_users SET full_name=''mass'''));
  PERFORM t_expect('users upd: ... and nothing was renamed', (SELECT count(*)::text FROM erp_users WHERE full_name='mass'), '0');
  -- delete: super only
  PERFORM t_expect('users del: company_admin cannot delete', t_dmlm(A, cadm, format('DELETE FROM erp_users WHERE id=%L', U11)), 'rows:0');
  PERFORM t_expect('users del: plain staff cannot delete', t_dmlm(A, viewr, format('DELETE FROM erp_users WHERE id=%L', U11)), 'rows:0');
  PERFORM t_expect('users: 13 profiles untouched', (SELECT count(*)::text FROM erp_users), '13');
END $$;
ROLLBACK;

-- ═══ erp_users: legitimate flows ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSU text := 'INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)';
BEGIN
  -- login-time self-service writes
  PERFORM t_expect('ok: last_login by plain staff', t_dmlm(A, viewr, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), viewr)), 'rows:1');
  PERFORM t_expect('ok: last_login by ops', t_dmlm(A, ops, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), ops)), 'rows:1');
  PERFORM t_expect('ok: last_login by Office Admin', t_dmlm(A, offc, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), offc)), 'rows:1');
  PERFORM t_expect('ok: last_login by C2 ops', t_dmlm(A, ops2, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), ops2)), 'rows:1');
  PERFORM t_expect('ok: last_login by company_admin', t_dmlm(A, cadm, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), cadm)), 'rows:1');
  PERFORM t_expect('ok: last_login by super', t_dmlm(A, sup, format('UPDATE erp_users SET last_login=%L WHERE auth_user_id=%L', now(), sup)), 'rows:1');
  PERFORM t_expect('ok: force_password_change true -> false by self', t_dmlm(A, sp1, format('UPDATE erp_users SET force_password_change=false WHERE auth_user_id=%L', sp1)), 'rows:1');
  PERFORM t_expect('ok: ... flag is cleared', (SELECT force_password_change::text FROM erp_users WHERE id=U11::uuid), 'false');
  PERFORM t_expect('ok: no-op force_password_change=false by plain staff', t_dmlm(A, viewr, format('UPDATE erp_users SET force_password_change=false WHERE auth_user_id=%L', viewr)), 'rows:1');
  -- Edit User / Edit Permissions (company admin)
  PERFORM t_expect('ok: Edit User {full_name, company_id} by company_admin', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L, company_id=%L WHERE auth_user_id=%L', 'Ops Renamed', C1, ops)), 'rows:1');
  PERFORM t_expect('ok: Edit Permissions {company_id} (unchanged) by company_admin', t_dmlm(A, cadm, format('UPDATE erp_users SET company_id=%L WHERE auth_user_id=%L', C1, ops)), 'rows:1');
  PERFORM t_expect('ok: company_admin renames self', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'Admin Renamed', U03)), 'rows:1');
  PERFORM t_expect('ok: company_admin deactivates a colleague', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=false WHERE id=%L', U11)), 'rows:1');
  PERFORM t_expect('ok: company_admin reactivates a colleague', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=true WHERE id=%L', U11)), 'rows:1');
  PERFORM t_expect('ok: company_admin forces a colleague password change', t_dmlm(A, cadm, format('UPDATE erp_users SET force_password_change=true WHERE id=%L', U01)), 'rows:1');
  PERFORM t_expect('ok: admin bulk touch of non-super colleagues that live only in C1 (last_login only; mixed and dual belong to C2 too)', t_dmlm(A, cadm, format('UPDATE erp_users SET last_login=now() WHERE company_id=%L AND id NOT IN (%L,%L)', C1, U04, U08)), 'rows:6');
  PERFORM t_expect('ok: company_admin of C2 edits a C2 user', t_dmlm(A, cadm2, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'C2 Renamed', U12)), 'rows:1');
  PERFORM t_expect('ok: dual admin moves a user C1 -> C2 (administers both)', t_dmlm(A, dual, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C2, U11)), 'rows:1');
  PERFORM t_expect('ok: dual admin moves the user back', t_dmlm(A, dual, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C1, U11)), 'rows:1');
  -- creating profiles (admins only, own company)
  PERFORM t_deny('users ins: company admins can no longer insert profiles (cadm)', t_dmlm(A, cadm, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0001', 'new1', 'new1@t.test', C1)));
  PERFORM t_deny('users ins: company admins can no longer insert profiles (cadm2)', t_dmlm(A, cadm2, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0002', 'new2', 'new2@t.test', C2)));
  PERFORM t_deny('users ins: company admins can no longer insert profiles (mixed)', t_dmlm(A, mixed, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0003', 'new3', 'new3@t.test', C1)));
  PERFORM t_deny('users ins: company admins can no longer insert profiles (dual)', t_dmlm(A, dual, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0004', 'new4', 'new4@t.test', C2)));
  PERFORM t_expect('ok: super inserts anywhere', t_dmlm(A, sup, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0005', 'new5', 'new5@t.test', C2)), 'rows:1');
  PERFORM t_expect('ok: the profile created by the super is visible to the C2 admin', t_count(A, cadm2, format('SELECT 1 FROM erp_users WHERE email=%L', 'new5@t.test')), 'n:1');
  -- super admin
  PERFORM t_expect('ok: super changes a colleague email', t_dmlm(A, sup, format('UPDATE erp_users SET email=%L WHERE id=%L', 'ops-new@t.test', U01)), 'rows:1');
  PERFORM t_expect('ok: super changes a colleague auth_user_id', t_dmlm(A, sup, format('UPDATE erp_users SET auth_user_id=%L WHERE id=%L', 'aaaa0099-0000-0000-0000-000000000099', U01)), 'rows:1');
  PERFORM t_expect('ok: super moves own company_id', t_dmlm(A, sup, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C2, U04)), 'rows:1');
  PERFORM t_expect('ok: super edits another super profile', t_dmlm(A, sup, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'S2', U08)), 'rows:1');
  PERFORM t_expect('ok: second super renames self', t_dmlm(A, sup2, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'S2b', U08)), 'rows:1');
  PERFORM t_expect('ok: super deactivates another super', t_dmlm(A, sup, format('UPDATE erp_users SET is_active=false WHERE id=%L', U08)), 'rows:1');
  PERFORM t_expect('ok: ... who then loses super rights immediately', t_count(A, sup2, 'SELECT 1 WHERE public.is_super_admin()'), 'n:0');
  PERFORM t_expect('ok: super deletes a profile (cascades ucr)', t_dmlm(A, sup, format('DELETE FROM erp_users WHERE id=%L', U12)), 'rows:1');
  PERFORM t_expect('ok: ... assignments went with it', (SELECT count(*)::text FROM erp_user_company_roles WHERE user_id=U12::uuid), '0');
END $$;
ROLLBACK;
-- ═══ erp_roles: refusals ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSR text := 'INSERT INTO erp_roles (name, permissions, company_id, created_by) VALUES (%L,%L,%L,%L)';
  UPDR text := 'UPDATE erp_roles SET name=%L, permissions=%L, updated_at=now() WHERE id=%L';
  RX text := 'a0000000-0000-0000-0000-0000000000f2';
BEGIN
  -- the admin:companies escalation (create / edit / assign)
  PERFORM t_denym('roles: Office Admin cannot create a role carrying admin:companies', t_dmlm(A, offc, format(INSR, 'Sneaky', '{"admin:companies":true}', C1, U05)), 'only a super admin');
  PERFORM t_denym('roles: string "true" variant refused', t_dmlm(A, offc, format(INSR, 'Sneaky', '{"admin:companies":"true"}', C1, U05)), 'only a super admin');
  PERFORM t_denym('roles: number 1 variant refused', t_dmlm(A, offc, format(INSR, 'Sneaky', '{"admin:companies":1}', C1, U05)), 'only a super admin');
  PERFORM t_denym('roles: company_admin cannot create it either', t_dmlm(A, cadm, format(INSR, 'Sneaky', '{"admin:companies":true,"ops:work-orders:read":true}', C1, U03)), 'only a super admin');
  PERFORM t_denym('roles: Office Admin cannot edit a custom role to add admin:companies', t_dmlm(A, offc, format(UPDR, 'C1 Custom', '{"admin:companies":true,"ops:work-orders:read":true}', R1)), 'only a super admin');
  PERFORM t_denym('roles: company_admin cannot edit a custom role to add admin:companies', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '{"admin:companies":true}', R1)), 'only a super admin');
  PERFORM t_denym('roles: admin:companies with a garbage value refused (would make live (x->>k)::boolean raise)', t_dmlm(A, offc, format(INSR, 'Sneaky', '{"admin:companies":"abc"}', C1, U05)), 'only a super admin');
  PERFORM t_denym('roles: admin:companies=null refused', t_dmlm(A, offc, format(INSR, 'Sneaky', '{"admin:companies":null}', C1, U05)), 'only a super admin');
  PERFORM t_denym('roles: admin:companies garbage added by update refused', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '{"admin:companies":"abc"}', R1)), 'only a super admin');
  PERFORM t_denym('roles: role id is immutable', t_dmlm(A, cadm, format('UPDATE erp_roles SET id=gen_random_uuid() WHERE id=%L', R1)), 'cannot be changed');
  PERFORM t_denym('roles: nested/array permissions refused (not an object)', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '[]', R1)), 'JSON object');
  PERFORM t_denym('roles: scalar permissions refused', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '"x"', R1)), 'JSON object');
  -- ceiling rule
  PERFORM t_denym('roles ceiling: Office Admin cannot grant finance:bank:read it lacks', t_dmlm(A, offc, format(INSR, 'Bankers', '{"finance:bank:read":true}', C1, U05)), 'finance:bank:read');
  PERFORM t_denym('roles ceiling: Office Admin cannot grant admin:users it lacks', t_dmlm(A, offc, format(INSR, 'UserAdmins', '{"admin:users":true}', C1, U05)), 'admin:users');
  PERFORM t_denym('roles ceiling: Office Admin cannot add ops:work-orders:write to an existing role', t_dmlm(A, offc, format(UPDR, 'C1 Custom', '{"ops:work-orders:read":true,"ops:work-orders:write":true}', R1)), 'ops:work-orders:write');
  PERFORM t_denym('roles ceiling: company_admin cannot grant finance:bank:read it lacks', t_dmlm(A, cadm, format(INSR, 'Bankers', '{"finance:bank:read":true}', C1, U03)), 'finance:bank:read');
  PERFORM t_denym('roles: string "true" permission value refused (non-boolean)', t_dmlm(A, cadm, format(INSR, 'Bankers', '{"finance:bank:read":"true"}', C1, U03)), 'true or false');
  PERFORM t_denym('roles ceiling: company_admin cannot add an unheld atom on update', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '{"ops:work-orders:read":true,"finance:bank:read":true}', R1)), 'finance:bank:read');
  -- dual: company_admin in C1 (holds admin:roles there) but only finance:bank:read-in-C2 via a C2-owned role
  INSERT INTO erp_roles (id, name, company_id, permissions) VALUES ('a0000000-0000-0000-0000-0000000000b2', 'C2 Bank', C2::uuid, '{"finance:bank:read":true}');
  UPDATE erp_user_company_roles SET role_id='a0000000-0000-0000-0000-0000000000b2' WHERE user_id=U13::uuid AND company_id=C2::uuid;
  PERFORM t_denym('roles ceiling: an atom held only in ANOTHER company does not count', t_dmlm(A, dual, format(INSR, 'X', '{"finance:bank:read":true}', C1, U13)), 'finance:bank:read');
  -- scope
  PERFORM t_deny('roles: company_admin cannot create a role in C2', t_dmlm(A, cadm, format(INSR, 'X', '{"ops:work-orders:read":true}', C2, U03)));
  PERFORM t_deny('roles: mixed (ops only in C2) cannot create a role in C2', t_dmlm(A, mixed, format(INSR, 'X', '{"ops:work-orders:read":true}', C2, U10)));
  PERFORM t_expect('roles: company_admin cannot edit a C2 role', t_dmlm(A, cadm, format(UPDR, 'x', '{}', R2)), 'rows:0');
  PERFORM t_expect('roles: company_admin cannot delete a C2 role', t_dmlm(A, cadm, format('DELETE FROM erp_roles WHERE id=%L', R2)), 'rows:0');
  PERFORM t_deny('roles: cannot create a global (company-less) role', t_dmlm(A, cadm, format(INSR, 'G', '{}', NULL, U03)));
  PERFORM t_deny('roles: cannot create a system role', t_dmlm(A, cadm, format('INSERT INTO erp_roles (name, permissions, company_id, is_system) VALUES (%L,%L,%L,true)', 'S', '{}', C1)));
  PERFORM t_expect('roles: system role company_admin is not editable', t_dmlm(A, cadm, format(UPDR, 'company_admin', '{"admin:companies":true}', RA)), 'rows:0');
  PERFORM t_expect('roles: system role super_admin is not editable', t_dmlm(A, offc, format(UPDR, 'super_admin', '{}', RS)), 'rows:0');
  PERFORM t_expect('roles: system role not deletable', t_dmlm(A, cadm, format('DELETE FROM erp_roles WHERE id=%L', RV)), 'rows:0');
  PERFORM t_deny('roles: a custom role cannot be flipped to system', t_dmlm(A, cadm, format('UPDATE erp_roles SET is_system=true WHERE id=%L', R1)));
  PERFORM t_denym('roles: dual admin cannot move a role between companies', t_dmlm(A, dual, format('UPDATE erp_roles SET company_id=%L WHERE id=%L', C2, R1)), 'cannot be changed');
  -- non admins
  PERFORM t_deny('roles: plain staff cannot create', t_dmlm(A, viewr, format(INSR, 'X', '{}', C1, U02)));
  PERFORM t_expect('roles: plain staff cannot edit', t_dmlm(A, viewr, format(UPDR, 'x', '{}', R1)), 'rows:0');
  PERFORM t_expect('roles: ops cannot delete', t_dmlm(A, ops, format('DELETE FROM erp_roles WHERE id=%L', RD)), 'rows:0');
  PERFORM t_deny('roles: deactivated cannot create', t_dmlm(A, gone, format(INSR, 'X', '{}', C1, U06)));
  PERFORM t_expect('roles: client-like cannot edit', t_dmlm(A, clnt, format(UPDR, 'x', '{}', R1)), 'rows:0');
  PERFORM t_deny('roles: client-like cannot create', t_dmlm(A, clnt, format(INSR, 'X', '{}', C1, U06)));
  PERFORM t_expect('roles: anon cannot edit', t_dmlm('anon', NULL, format(UPDR, 'x', '{}', R1)), 'rows:0');
  PERFORM t_deny('roles: anon cannot create', t_dmlm('anon', NULL, format(INSR, 'X', '{}', C1, U06)));
  INSERT INTO erp_roles (id, name, company_id, is_system, permissions) VALUES ('a0000000-0000-0000-0000-0000000000f4', 'C1 System', C1::uuid, true, '{"ops:work-orders:read":true}');
  PERFORM t_expect('roles: a company-owned SYSTEM role is not editable', t_dmlm(A, cadm, format(UPDR, 'renamed', '{"ops:work-orders:read":true}', 'a0000000-0000-0000-0000-0000000000f4')), 'rows:0');
  PERFORM t_expect('roles: a company-owned SYSTEM role is not deletable', t_dmlm(A, cadm, 'DELETE FROM erp_roles WHERE id=''a0000000-0000-0000-0000-0000000000f4'''), 'rows:0');
  -- a super role that already exists (created by the platform) cannot be edited, deleted or assigned by a company admin
  INSERT INTO erp_roles (id, name, company_id, permissions) VALUES (RX::uuid, 'SuperCustom', C1::uuid, '{"admin:companies":true,"ops:work-orders:read":true}');
  PERFORM t_denym('roles: company_admin cannot rename an existing super role', t_dmlm(A, cadm, format(UPDR, 'renamed', '{"admin:companies":true,"ops:work-orders:read":true}', RX)), 'only a super admin');
  PERFORM t_denym('roles: company_admin cannot strip/alter an existing super role', t_dmlm(A, cadm, format(UPDR, 'SuperCustom', '{"ops:work-orders:read":true}', RX)), 'only a super admin');
  PERFORM t_expect('roles: company_admin cannot delete an existing super role', t_dmlm(A, cadm, format('DELETE FROM erp_roles WHERE id=%L', RX)), 'rows:0');
  PERFORM t_expect('roles: Office Admin cannot delete an existing super role', t_dmlm(A, offc, format('DELETE FROM erp_roles WHERE id=%L', RX)), 'rows:0');
  PERFORM t_deny('roles: company_admin cannot assign an existing super custom role (update)', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', RX, U01, C1)));
  PERFORM t_deny('roles: ... nor insert it', t_dmlm(A, cadm, format('INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (%L,%L,%L)', U07, C1, RX)));
  PERFORM t_expect('roles: nobody is super afterwards but the two supers', t_count(A, ops, 'SELECT 1 WHERE public.is_super_admin()'), 'n:0');
END $$;
ROLLBACK;

-- ═══ erp_roles: legitimate flows ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSR text := 'INSERT INTO erp_roles (name, permissions, company_id, created_by) VALUES (%L,%L,%L,%L)';
  UPDR text := 'UPDATE erp_roles SET name=%L, permissions=%L, updated_at=now() WHERE id=%L';
BEGIN
  PERFORM t_expect('ok: Role Manager create by company_admin (atoms it holds)', t_dmlm(A, cadm, format(INSR, 'Team Lead', '{"ops:work-orders:read":true,"finance:ap:read":true}', C1, U03)), 'rows:1');
  PERFORM t_expect('ok: company_admin creates a role with admin:users + admin:roles (it holds both)', t_dmlm(A, cadm, format(INSR, 'Delegates', '{"admin:users":true,"admin:roles":true}', C1, U03)), 'rows:1');
  PERFORM t_denym('roles: string-true of a HELD atom is refused too (non-boolean)', t_dmlm(A, cadm, format(INSR, 'StrTrue', '{"finance:ap:read":"true"}', C1, U03)), 'true or false');
  PERFORM t_expect('ok: Office Admin creates a role within its own atoms', t_dmlm(A, offc, format(INSR, 'AP Clerk', '{"finance:ap:read":true,"ops:work-orders:read":true}', C1, U05)), 'rows:1');
  PERFORM t_expect('ok: admin:companies=false is not a grant', t_dmlm(A, offc, format(INSR, 'ExplicitFalse', '{"admin:companies":false,"ops:work-orders:read":true}', C1, U05)), 'rows:1');
  PERFORM t_expect('ok: unheld atom with value false is not a grant', t_dmlm(A, offc, format(INSR, 'NoBank', '{"finance:bank:read":false,"finance:ap:write":true}', C1, U05)), 'rows:1');
  PERFORM t_expect('ok: Role Manager edit (add held atom)', t_dmlm(A, cadm, format(UPDR, 'C1 Custom 2', '{"ops:work-orders:read":true,"ops:work-orders:write":true}', R1)), 'rows:1');
  PERFORM t_expect('ok: edit that removes atoms', t_dmlm(A, cadm, format(UPDR, 'C1 Custom 2', '{}', R1)), 'rows:1');
  PERFORM t_expect('ok: Office Admin renames a role keeping an atom it does not hold (not a new grant)', t_dmlm(A, offc, format(UPDR, 'Bank Renamed', '{"finance:bank:read":true}', RB)), 'rows:1');
  PERFORM t_expect('ok: ... and adds a held atom to it', t_dmlm(A, offc, format(UPDR, 'Bank Renamed', '{"finance:bank:read":true,"ops:work-orders:read":true}', RB)), 'rows:1');
  PERFORM t_expect('ok: the new role can be assigned by a user admin of that company', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET role_id=(SELECT id FROM erp_roles WHERE name=%L), updated_at=now() WHERE user_id=%L AND company_id=%L', 'Team Lead', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: Role Manager delete of a custom role', t_dmlm(A, cadm, format('DELETE FROM erp_roles WHERE id=%L', RD)), 'rows:1');
  PERFORM t_expect('ok: Office Admin deletes a custom role of its company', t_dmlm(A, offc, format('DELETE FROM erp_roles WHERE id=%L', RB)), 'rows:1');
  PERFORM t_expect('ok: company_admin of C2 creates in C2', t_dmlm(A, cadm2, format(INSR, 'C2 Lead', '{"ops:work-orders:read":true}', C2, U09)), 'rows:1');
  PERFORM t_expect('ok: dual admin edits a C2 role', t_dmlm(A, dual, format(UPDR, 'C2 Custom', '{"ops:work-orders:write":true}', R2)), 'rows:1');
  -- super admin keeps full ability
  PERFORM t_expect('ok: super creates a role carrying admin:companies', t_dmlm(A, sup, format(INSR, 'Platform Ops', '{"admin:companies":true}', C1, U04)), 'rows:1');
  PERFORM t_expect('ok: second super creates one with string-true', t_dmlm(A, sup2, format(INSR, 'Platform Ops 2', '{"admin:companies":"true"}', C1, U08)), 'rows:1');
  PERFORM t_expect('ok: super edits a role to add any atom', t_dmlm(A, sup, format(UPDR, 'C2 Custom', '{"admin:companies":true,"finance:bank:write":true}', R2)), 'rows:1');
  PERFORM t_expect('ok: super may assign the new super role', t_dmlm(A, sup, format('UPDATE erp_user_company_roles SET role_id=(SELECT id FROM erp_roles WHERE name=%L) WHERE user_id=%L AND company_id=%L', 'Platform Ops', U01, C1)), 'rows:1');
  PERFORM t_expect('ok: ... that user is a super admin through the custom role', t_count(A, ops, 'SELECT 1 WHERE public.is_super_admin()'), 'n:1');
  PERFORM t_expect('ok: super deletes a custom super role (reassign first, FK)', t_dmlm(A, sup, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', RO, U01, C1)), 'rows:1');
  PERFORM t_expect('ok: ... then deletes it', t_dmlm(A, sup, format('DELETE FROM erp_roles WHERE name=%L', 'Platform Ops')), 'rows:1');
END $$;
ROLLBACK;

-- ═══ trusted sessions bypass, and cannot be spoofed ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
BEGIN
  PERFORM t_expect('bypass: service_role changes email + auth_user_id + is_active of a super', t_dmlm('service_role', NULL, format('UPDATE erp_users SET email=%L, auth_user_id=%L, is_active=false WHERE id=%L', 'svc@t.test', 'aaaa0077-0000-0000-0000-000000000077', U04)), 'rows:1');
  PERFORM t_expect('bypass: service_role changes immutable created_at (edge functions / backfills)', t_dmlm('service_role', NULL, format('UPDATE erp_users SET created_at=now() WHERE id=%L', U01)), 'rows:1');
  PERFORM t_expect('bypass: service_role creates a super role', t_dmlm('service_role', NULL, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'svc super', '{"admin:companies":true}', C1)), 'rows:1');
  PERFORM t_expect('bypass: service_role re-points a ucr row', t_dmlm('service_role', NULL, format('UPDATE erp_user_company_roles SET company_id=%L WHERE user_id=%L AND company_id=%L', C2, U02, C1)), 'rows:1');
  -- postgres (migrations / SQL editor)
  UPDATE erp_users SET email = 'pg@t.test', auth_user_id = 'aaaa0066-0000-0000-0000-000000000066' WHERE id = U02::uuid;
  PERFORM t_expect('bypass: postgres can edit auth_user_id and email', (SELECT email FROM erp_users WHERE id=U02::uuid), 'pg@t.test');
  INSERT INTO erp_roles (name, permissions, company_id) VALUES ('pg super', '{"admin:companies":true}', C1::uuid);
  PERFORM t_expect('bypass: postgres can create a super role', (SELECT count(*)::text FROM erp_roles WHERE name='pg super'), '1');
  -- spoofing from the API role
  PERFORM t_deny('spoof: authenticated cannot SET ROLE service_role', t_dmlm_ns(A, cadm, 'SET ROLE service_role'));
  PERFORM t_deny('spoof: authenticated cannot SET ROLE postgres', t_dmlm_ns(A, cadm, 'SET ROLE postgres'));
  PERFORM t_deny('spoof: authenticated cannot SET ROLE supabase_admin', t_dmlm_ns(A, cadm, 'SET ROLE supabase_admin'));
  PERFORM t_deny('spoof: set_config(role) cannot switch to service_role', t_dmlm_ns(A, cadm, 'SELECT set_config(''role'', ''service_role'', false)'));
  PERFORM t_deny('spoof: authenticated cannot switch off triggers (session_replication_role)', t_dmlm(A, cadm, 'SET session_replication_role = replica'));
  PERFORM t_deny('spoof: authenticated cannot disable the users trigger', t_dmlm(A, cadm, 'ALTER TABLE erp_users DISABLE TRIGGER d0d_users_guard'));
  PERFORM t_deny('spoof: authenticated cannot drop a policy', t_dmlm(A, cadm, 'DROP POLICY ucr_update ON erp_user_company_roles'));
  PERFORM t_deny('spoof: authenticated cannot disable RLS', t_dmlm(A, cadm, 'ALTER TABLE erp_users DISABLE ROW LEVEL SECURITY'));
  PERFORM t_deny('spoof: authenticated cannot replace a trigger function', t_dmlm(A, cadm, 'CREATE OR REPLACE FUNCTION public.d0d_users_guard() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN RETURN NEW; END $f$'));
  PERFORM t_deny('spoof: trigger functions are not callable by authenticated', t_dmlm(A, cadm, 'SELECT public.d0d_users_guard()'));
  PERFORM t_deny('spoof: anon cannot call the helpers', t_dmlm('anon', NULL, 'SELECT public.d0d_my_erp_user_id()'));
  PERFORM t_expect('spoof: none of it changed anything', (SELECT count(*)::text FROM pg_trigger WHERE tgname LIKE 'd0d\_%' AND tgenabled='O'), '3');
END $$;
ROLLBACK;
-- ═══ edge identities: deactivated admin, settings-only admin, overrides-only admin, super without company ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  UPD text := 'UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L';
  INS text := 'INSERT INTO erp_user_company_roles (user_id, company_id, role_id, permission_overrides) VALUES (%L,%L,%L,''{}'')';
  INSU text := 'INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)';
  RSET text := 'a0000000-0000-0000-0000-0000000000f3';
BEGIN
  -- a super admin cannot create a profile without a company either
  PERFORM t_deny('edge: super cannot insert a profile without a company', t_dmlm(A, sup, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0009', 'x', 'x9@t.test', NULL)));
  -- settings-only admin: is_company_admin() would count it, d0d_can_admin_users must not
  INSERT INTO erp_roles (id, name, company_id, permissions) VALUES (RSET::uuid, 'Settings Only', C1::uuid, '{"admin:settings":true,"ops:work-orders:read":true}');
  UPDATE erp_user_company_roles SET role_id = RSET::uuid WHERE user_id = U11::uuid AND company_id = C1::uuid;
  PERFORM t_expect('edge: settings-only holder is_company_admin (legacy helper) is true', t_count(A, sp1, 'SELECT 1 WHERE public.is_company_admin('''||C1||''')'), 'n:1');
  PERFORM t_expect('edge: ... but d0d_can_admin_users is false', t_count(A, sp1, 'SELECT 1 WHERE public.d0d_can_admin_users('''||C1||''')'), 'n:0');
  PERFORM t_expect('edge: settings-only holder cannot re-role a colleague', t_dmlm(A, sp1, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('edge: settings-only holder cannot create a profile', t_dmlm(A, sp1, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0008', 'x', 'x8@t.test', C1)));
  PERFORM t_expect('edge: settings-only holder cannot see colleague assignments', t_count(A, sp1, 'SELECT 1 FROM erp_user_company_roles'), 'n:1');
  -- admin:users granted only through permission_overrides does not count (roles only)
  UPDATE erp_user_company_roles SET permission_overrides = '{"admin:users":true}' WHERE user_id = U02::uuid AND company_id = C1::uuid;
  PERFORM t_expect('edge: overrides-only admin:users is not admin (reads)', t_count(A, viewr, 'SELECT 1 FROM erp_user_company_roles'), 'n:1');
  PERFORM t_expect('edge: overrides-only admin:users cannot re-role', t_dmlm(A, viewr, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('edge: overrides-only admin:users cannot insert assignments', t_dmlm(A, viewr, format(INS, U07, C1, RO)));
  -- a deactivated company admin loses every power at once
  UPDATE erp_users SET is_active = false WHERE id = U03::uuid;
  PERFORM t_expect('edge: deactivated admin cannot re-role', t_dmlm(A, cadm, format(UPD, RV, U01, C1)), 'rows:0');
  PERFORM t_deny('edge: deactivated admin cannot insert assignments', t_dmlm(A, cadm, format(INS, U07, C1, RO)));
  PERFORM t_deny('edge: deactivated admin cannot insert profiles', t_dmlm(A, cadm, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0007', 'x', 'x7@t.test', C1)));
  PERFORM t_expect('edge: deactivated admin cannot rename a colleague', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)), 'rows:0');
  PERFORM t_deny('edge: deactivated admin cannot create a role', t_dmlm(A, cadm, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'x', '{"ops:work-orders:read":true}', C1)));
  PERFORM t_expect('edge: deactivated admin cannot read roles or assignments', t_count(A, cadm, 'SELECT 1 FROM erp_roles') || ':' || t_count(A, cadm, 'SELECT 1 FROM erp_user_company_roles'), 'n:0:n:0');
  -- deactivated holder of an admin:roles role cannot edit roles
  UPDATE erp_users SET is_active = false WHERE id = U05::uuid;
  PERFORM t_expect('edge: deactivated Office Admin cannot edit a role', t_dmlm(A, offc, format('UPDATE erp_roles SET name=%L WHERE id=%L', 'x', R1)), 'rows:0');
END $$;
ROLLBACK;
-- ═══ review round 2: puppet inserts, shared users, symmetric ceiling, non-boolean values, info leaks ═══
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSU text := 'INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)';
BEGIN
  PERFORM t_deny('r2-1: company admin cannot insert a profile for an arbitrary auth_user_id', t_dmlm(A, cadm, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0101', 'puppet', 'puppet@t.test', C1)));
  PERFORM t_deny('r2-1: company admin of C2 cannot either', t_dmlm(A, cadm2, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0102', 'puppet2', 'puppet2@t.test', C2)));
  PERFORM t_deny('r2-1: dual admin cannot either', t_dmlm(A, dual, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0103', 'puppet3', 'puppet3@t.test', C1)));
  PERFORM t_expect('r2-1: no puppet exists, so the puppet self-modification chain cannot start', (SELECT count(*)::text FROM erp_users WHERE email LIKE 'puppet%'), '0');
  PERFORM t_expect('r2-1: the arbitrary login is not staff', t_count(A, 'dddddddd-dddd-dddd-dddd-dddddddd0101'::uuid, 'SELECT 1 WHERE public.is_erp_staff()'), 'n:0');
  PERFORM t_expect('r2-1: super admin can still insert', t_dmlm(A, sup, format(INSU, 'dddddddd-dddd-dddd-dddd-dddddddd0104', 'ok', 'ok@t.test', C1)), 'rows:1');
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
BEGIN
  -- U10 'mixed': home C1, administered by cadm in C1 but also an ops member of C2 (cadm is not admin there)
  PERFORM t_expect('r2-2: admin of C1 cannot deactivate a user who also belongs to C2', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=false WHERE id=%L', U10)), 'rows:0');
  PERFORM t_expect('r2-2: ... nor rename him', t_dmlm(A, cadm, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U10)), 'rows:0');
  PERFORM t_expect('r2-2: ... nor force a password change', t_dmlm(A, cadm, format('UPDATE erp_users SET force_password_change=true WHERE id=%L', U10)), 'rows:0');
  PERFORM t_expect('r2-2: ... nor move his company', t_dmlm(A, cadm, format('UPDATE erp_users SET company_id=%L WHERE id=%L', C1, U10)), 'rows:0');
  PERFORM t_expect('r2-2: admin of C2 cannot touch him either (home is C1)', t_dmlm(A, cadm2, format('UPDATE erp_users SET is_active=false WHERE id=%L', U10)), 'rows:0');
  PERFORM t_expect('r2-2: dual admin of both can', t_dmlm(A, dual, format('UPDATE erp_users SET is_active=false WHERE id=%L', U10)), 'rows:1');
  PERFORM t_expect('r2-2: reactivation by the wrong admin (C1 only) is refused', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=true WHERE id=%L', U10)), 'rows:0');
  PERFORM t_expect('r2-2: ... still inactive', (SELECT is_active::text FROM erp_users WHERE id=U10::uuid), 'false');
  PERFORM t_expect('r2-2: a super can reactivate', t_dmlm(A, sup, format('UPDATE erp_users SET is_active=true WHERE id=%L', U10)), 'rows:1');
  PERFORM t_denym('r2-2: mixed (admin of C1 only) cannot rename himself either: self-service stays limited when he belongs to a company he does not administer', t_dmlm(A, mixed, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U10)), 'only last_login');
  PERFORM t_expect('r2-2: dual (member of C1 and C2) is protected from admins of one company', t_dmlm(A, cadm2, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U13)), 'rows:0');
  PERFORM t_expect('r2-2: a user living in C1 only is still manageable by the C1 admin', t_dmlm(A, cadm, format('UPDATE erp_users SET is_active=false WHERE id=%L', U01)), 'rows:1');
  PERFORM t_expect('r2-2: mass update by a C1 admin skips shared users', t_dmlm(A, cadm, format('UPDATE erp_users SET last_login=now() WHERE company_id=%L AND id NOT IN (%L,%L)', C1, U04, U08)), 'rows:6');
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  UPDR text := 'UPDATE erp_roles SET name=%L, permissions=%L, updated_at=now() WHERE id=%L';
  INSR text := 'INSERT INTO erp_roles (name, permissions, company_id, created_by) VALUES (%L,%L,%L,%L)';
  RA5 text := 'a0000000-0000-0000-0000-0000000000f5';
BEGIN
  INSERT INTO erp_roles (id, name, company_id, permissions) VALUES (RA5::uuid, 'Admins', C1::uuid, '{"admin:users":true,"admin:settings":true,"ops:work-orders:read":true,"finance:bank:read":true}');
  PERFORM t_denym('r2-3: Office Admin (admin:roles only) cannot REMOVE admin:users from an admin role', t_dmlm(A, offc, format(UPDR, 'Admins', '{"admin:settings":true,"ops:work-orders:read":true,"finance:bank:read":true}', RA5)), 'admin:users');
  PERFORM t_denym('r2-3: ... nor flip it to false', t_dmlm(A, offc, format(UPDR, 'Admins', '{"admin:users":false,"admin:settings":true,"ops:work-orders:read":true,"finance:bank:read":true}', RA5)), 'admin:users');
  PERFORM t_denym('r2-3: ... nor remove finance:bank:read it does not hold', t_dmlm(A, offc, format(UPDR, 'Admins', '{"admin:users":true,"admin:settings":true,"ops:work-orders:read":true}', RA5)), 'finance:bank:read');
  PERFORM t_denym('r2-3: ... nor wipe all atoms', t_dmlm(A, offc, format(UPDR, 'Admins', '{}', RA5)), 'admin:');
  PERFORM t_expect('r2-3: Office Admin may remove an atom it holds (ops:work-orders:read)', t_dmlm(A, offc, format(UPDR, 'Admins', '{"admin:users":true,"admin:settings":true,"finance:bank:read":true}', RA5)), 'rows:1');
  PERFORM t_expect('r2-3: company_admin removes admin:settings (holds it)', t_dmlm(A, cadm, format(UPDR, 'Admins', '{"admin:users":true,"finance:bank:read":true}', RA5)), 'rows:1');
  PERFORM t_denym('r2-3: company_admin cannot remove finance:bank:read it does not hold', t_dmlm(A, cadm, format(UPDR, 'Admins', '{"admin:users":true}', RA5)), 'finance:bank:read');END $$;
ROLLBACK;
BEGIN;
DO $$
DECLARE
  ops uuid := '11111111-1111-1111-1111-111111111111'; viewr uuid := '22222222-2222-2222-2222-222222222222';
  cadm uuid := '33333333-3333-3333-3333-333333333333'; sup uuid := '44444444-4444-4444-4444-444444444444';
  offc uuid := '55555555-5555-5555-5555-555555555555'; gone uuid := '66666666-6666-6666-6666-666666666666';
  ops2 uuid := '77777777-7777-7777-7777-777777777777'; sup2 uuid := 'aaaa0008-0000-0000-0000-000000000008';
  cadm2 uuid := '10101010-1010-1010-1010-101010101010'; mixed uuid := '11111111-aaaa-1111-1111-111111111111';
  sp1 uuid := 'aaaa0011-0000-0000-0000-000000000011'; sp2 uuid := 'aaaa0012-0000-0000-0000-000000000012';
  dual uuid := 'aaaa0013-0000-0000-0000-000000000013'; clnt uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  U01 text := 'e0000000-0000-0000-0000-000000000001'; U02 text := 'e0000000-0000-0000-0000-000000000002'; U03 text := 'e0000000-0000-0000-0000-000000000003';
  U04 text := 'e0000000-0000-0000-0000-000000000004'; U05 text := 'e0000000-0000-0000-0000-000000000005'; U06 text := 'e0000000-0000-0000-0000-000000000006';
  U07 text := 'e0000000-0000-0000-0000-000000000007'; U08 text := 'e0000000-0000-0000-0000-000000000008'; U09 text := 'e0000000-0000-0000-0000-000000000009';
  U10 text := 'e0000000-0000-0000-0000-000000000010'; U11 text := 'e0000000-0000-0000-0000-000000000011'; U12 text := 'e0000000-0000-0000-0000-000000000012';
  U13 text := 'e0000000-0000-0000-0000-000000000013';
  RO text := 'a0000000-0000-0000-0000-000000000001'; RV text := 'a0000000-0000-0000-0000-000000000002'; RA text := 'a0000000-0000-0000-0000-000000000003';
  RS text := 'a0000000-0000-0000-0000-000000000004'; RF text := 'a0000000-0000-0000-0000-000000000005'; R1 text := 'a0000000-0000-0000-0000-000000000006';
  R2 text := 'a0000000-0000-0000-0000-000000000007'; RD text := 'a0000000-0000-0000-0000-000000000008'; RB text := 'a0000000-0000-0000-0000-000000000009';
  A text := 'authenticated';
  INSR text := 'INSERT INTO erp_roles (name, permissions, company_id, created_by) VALUES (%L,%L,%L,%L)';
  UPDR text := 'UPDATE erp_roles SET name=%L, permissions=%L, updated_at=now() WHERE id=%L';
BEGIN
  PERFORM t_denym('r2-4: non-boolean value on an unheld atom refused (user_has_perm DoS)', t_dmlm(A, offc, format(INSR, 'DoS', '{"admin:users":"x"}', C1, U05)), 'true or false');
  PERFORM t_denym('r2-4: non-boolean value on a held atom refused', t_dmlm(A, offc, format(INSR, 'DoS', '{"ops:work-orders:read":"x"}', C1, U05)), 'true or false');
  PERFORM t_denym('r2-4: number refused', t_dmlm(A, offc, format(INSR, 'DoS', '{"ops:work-orders:read":1}', C1, U05)), 'true or false');
  PERFORM t_denym('r2-4: null refused', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '{"ops:work-orders:read":null}', R1)), 'true or false');
  PERFORM t_denym('r2-4: nested object refused', t_dmlm(A, cadm, format(UPDR, 'C1 Custom', '{"ops:work-orders:read":{"a":1}}', R1)), 'true or false');
  PERFORM t_expect('r2-4: nothing was planted', (SELECT count(*)::text FROM erp_roles WHERE name='DoS'), '0');
  PERFORM t_expect('r2-4: user_has_perm still evaluates for every holder', t_count(A, ops, 'SELECT 1 WHERE public.user_has_perm(''admin:users'') OR true'), 'n:1');
  PERFORM t_expect('r2-4: a super may still write anything (service tooling)', t_dmlm(A, sup2, format(INSR, 'SuperAnything', '{"x":"y"}', C1, U08)), 'rows:1');
  PERFORM t_expect('r2-4: booleans stay fine', t_dmlm(A, cadm, format(INSR, 'Fine', '{"ops:work-orders:read":true,"finance:bank:read":false}', C1, U03)), 'rows:1');

  -- r2-5a user_is_super / role_is_super oracle limited to user admins
  PERFORM t_expect('r2-5a: plain staff learns nothing about who is super', t_count(A, viewr, 'SELECT 1 WHERE public.d0d_user_is_super('''||U04||''')'), 'n:0');
  PERFORM t_expect('r2-5a: ops learns nothing about super roles', t_count(A, ops, 'SELECT 1 WHERE public.d0d_role_is_super('''||RS||''')'), 'n:0');
  PERFORM t_expect('r2-5a: Office Admin (no admin:users) learns nothing', t_count(A, offc, 'SELECT 1 WHERE public.d0d_user_is_super('''||U04||''')'), 'n:0');
  PERFORM t_expect('r2-5a: a user admin can ask', t_count(A, cadm, 'SELECT 1 WHERE public.d0d_user_is_super('''||U04||''')'), 'n:1');
  -- r2-5b roles select scope
  PERFORM t_expect('r2-5b: C1 staff cannot read a C2 custom role', t_count(A, ops, 'SELECT 1 FROM erp_roles WHERE id='''||R2||''''), 'n:0');
  PERFORM t_expect('r2-5b: C1 staff reads a C1 custom role', t_count(A, ops, 'SELECT 1 FROM erp_roles WHERE id='''||R1||''''), 'n:1');
  PERFORM t_expect('r2-5b: C1 staff reads global roles', t_count(A, ops, 'SELECT 1 FROM erp_roles WHERE company_id IS NULL'), 'n:4');
  PERFORM t_expect('r2-5b: C2 staff reads the C2 role, not the C1 one', t_count(A, ops2, 'SELECT 1 FROM erp_roles WHERE id='''||R2||''''), 'n:1');
  PERFORM t_expect('r2-5b: ... not the C1 one', t_count(A, ops2, 'SELECT 1 FROM erp_roles WHERE company_id='''||C1||''''), 'n:0');
  PERFORM t_expect('r2-5b: member of both companies reads both', t_count(A, mixed, 'SELECT 1 FROM erp_roles'), 'n:11');
  PERFORM t_expect('r2-5b: super reads everything', t_count(A, sup2, 'SELECT 1 FROM erp_roles'), 'n:11');
  PERFORM t_expect('r2-5b: Role Manager / Edit Permissions dropdown (global + chosen company) for a C1 admin', t_count(A, cadm, 'SELECT id, name FROM erp_roles WHERE company_id IS NULL OR company_id='''||C1||''''), 'n:10');
  PERFORM t_expect('r2-5b: ... dropdown for a super choosing C2', t_count(A, sup, 'SELECT id, name FROM erp_roles WHERE company_id IS NULL OR company_id='''||C2||''''), 'n:5');
  PERFORM t_expect('r2-5b: client-like still reads nothing', t_count(A, clnt, 'SELECT 1 FROM erp_roles'), 'n:0');

  -- r2-6 formerly "equivalent" mutants
  PERFORM t_deny('r2-6: even a super cannot flip a custom role to is_system=true', t_dmlm(A, sup, format('UPDATE erp_roles SET is_system=true WHERE id=%L', R1)));
  PERFORM t_deny('r2-6: even a super cannot null a colleague company_id', t_dmlm(A, sup, format('UPDATE erp_users SET company_id=NULL WHERE id=%L', U01)));
END $$;
ROLLBACK;