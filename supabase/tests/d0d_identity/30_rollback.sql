-- AFTER the down script: the original policies are back byte-for-byte (compared with a snapshot taken from the stub, which mirrors
-- the live definitions), every d0d object is gone, and the old holes are open again (the rollback is a deliberate re-opening).
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
  PERFORM t_expect('rollback: no d0d function left', (SELECT count(*)::text FROM pg_proc WHERE proname LIKE 'd0d\_%'), '0');
  PERFORM t_expect('rollback: no d0d trigger left', (SELECT count(*)::text FROM pg_trigger WHERE tgname LIKE 'd0d\_%'), '0');
  PERFORM t_expect('rollback: no restrictive policy left on the 3 tables', (SELECT count(*)::text FROM pg_policies WHERE tablename IN ('erp_users','erp_roles','erp_user_company_roles') AND permissive='RESTRICTIVE'), '0');
  PERFORM t_expect('rollback: policy set identical to the original snapshot (name, roles, cmd, qual, with_check)', (SELECT count(*)::text FROM (
     (SELECT tablename::text, policyname::text, permissive::text, roles::text, cmd::text, qual, with_check FROM pg_policies WHERE tablename IN ('erp_users','erp_roles','erp_user_company_roles')
      EXCEPT SELECT * FROM public.t_orig_policies)
     UNION ALL
     (SELECT * FROM public.t_orig_policies
      EXCEPT SELECT tablename::text, policyname::text, permissive::text, roles::text, cmd::text, qual, with_check FROM pg_policies WHERE tablename IN ('erp_users','erp_roles','erp_user_company_roles'))) d), '0');
  PERFORM t_expect('rollback: 11 original policies', (SELECT count(*)::text FROM pg_policies WHERE tablename IN ('erp_users','erp_roles','erp_user_company_roles')), '11');
  PERFORM t_expect('rollback: D0a function and jobs restrictive pair untouched', (SELECT count(*)::text FROM pg_proc WHERE proname='is_erp_staff') || ':' || (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname IN ('d0_staff_only','d0_no_anon')), '1:2');
  -- the app keeps working
  PERFORM t_expect('rollback: login read of own profile', t_count(A, ops, 'SELECT 1 FROM erp_users WHERE auth_user_id='''||ops||''' AND is_active=true'), 'n:1');
  PERFORM t_expect('rollback: login read of own role', t_count(A, ops, 'SELECT r.permissions FROM erp_user_company_roles u JOIN erp_roles r ON r.id=u.role_id WHERE u.user_id='''||U01||''''), 'n:1');
  PERFORM t_expect('rollback: last_login write', t_dmlm(A, ops, format('UPDATE erp_users SET last_login=now() WHERE auth_user_id=%L', ops)), 'rows:1');
  PERFORM t_expect('rollback: admin edits overrides', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET permission_overrides=%L WHERE user_id=%L AND company_id=%L', '{}', U01, C1)), 'rows:1');
  -- the holes are open again (positive control that the down script really restored the legacy state)
  PERFORM t_expect('rollback: company_admin can assign self super again', t_dmlm(A, cadm, format('UPDATE erp_user_company_roles SET role_id=%L WHERE user_id=%L AND company_id=%L', RS, U03, C1)), 'rows:1');
  PERFORM t_expect('rollback: plain staff can insert a profile again', t_dmlm(A, viewr, format('INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (%L,%L,%L,true,%L)', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'c', 'c@t.test', C1)), 'rows:1');
  PERFORM t_expect('rollback: plain staff can rename a colleague again', t_dmlm(A, viewr, format('UPDATE erp_users SET full_name=%L WHERE id=%L', 'x', U01)), 'rows:1');
  PERFORM t_expect('rollback: client-like login reads roles again', t_count(A, clnt, 'SELECT 1 FROM erp_roles'), 'n:9');
  PERFORM t_expect('rollback: Office Admin can create an admin:companies role again', t_dmlm(A, offc, format('INSERT INTO erp_roles (name, permissions, company_id) VALUES (%L,%L,%L)', 'S', '{"admin:companies":true}', C1)), 'rows:1');
END $$;
ROLLBACK;