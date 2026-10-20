-- BEFORE the migration: every hole from the D0d problem statement is exploitable (positive control). One transaction, rolled back.
BEGIN;
DO $$
DECLARE
  ops   uuid := '11111111-1111-1111-1111-111111111111';  -- operations_tech C1
  viewr uuid := '22222222-2222-2222-2222-222222222222';  -- viewer C1 (no admin atoms)
  cadm  uuid := '33333333-3333-3333-3333-333333333333';  -- company_admin C1
  offc  uuid := '55555555-5555-5555-5555-555555555555';  -- Office Admin custom role C1 (admin:roles, no admin:users)
  mixed uuid := '11111111-aaaa-1111-1111-111111111111';  -- company_admin C1 + operations_tech C2
  clnt  uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';  -- client-shaped: no erp_users row
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  SUPR text := 'a0000000-0000-0000-0000-000000000004';
BEGIN
  -- ucr: admin:users in one company is enough to mint a super admin
  PERFORM t_expect('before: is_super_admin false for company_admin', t_count('authenticated', cadm, 'SELECT 1 WHERE public.is_super_admin()'), 'n:0');
  PERFORM t_expect('before: company_admin assigns SELF the super_admin role', t_dml('authenticated', cadm, 'UPDATE erp_user_company_roles SET role_id='''||SUPR||''' WHERE user_id=''e0000000-0000-0000-0000-000000000003'' AND company_id='''||C1||''''), 'rows:1');
  PERFORM t_expect('before: ... and is now a platform super admin', t_count('authenticated', cadm, 'SELECT 1 WHERE public.is_super_admin()'), 'n:1');
  PERFORM t_expect('before: company_admin inserts a super_admin assignment for a colleague', t_dml('authenticated', cadm, 'INSERT INTO erp_user_company_roles (user_id, company_id, role_id) VALUES (''e0000000-0000-0000-0000-000000000007'','''||C1||''','''||SUPR||''')'), 'rows:1');
  PERFORM t_expect('before: mixed (admin in C1 only) re-roles a C2 user (user_has_perm not company scoped)', t_dml('authenticated', mixed, 'UPDATE erp_user_company_roles SET role_id=''a0000000-0000-0000-0000-000000000003'' WHERE user_id=''e0000000-0000-0000-0000-000000000012'' AND company_id='''||C2||''''), 'rows:1');
  PERFORM t_expect('before: admin sets admin:companies in permission_overrides', t_dml('authenticated', cadm, 'UPDATE erp_user_company_roles SET permission_overrides=''{"admin:companies":true}'' WHERE user_id=''e0000000-0000-0000-0000-000000000001'' AND company_id='''||C1||''''), 'rows:1');
  PERFORM t_expect('before: ucr row can be re-pointed to another user', t_dml('authenticated', cadm, 'UPDATE erp_user_company_roles SET user_id=''e0000000-0000-0000-0000-000000000012'' WHERE user_id=''e0000000-0000-0000-0000-000000000011'' AND company_id='''||C1||''''), 'rows:1');
  PERFORM t_expect('before: company_admin can demote the super admin Brandon-like row', t_dml('authenticated', cadm, 'UPDATE erp_user_company_roles SET role_id=''a0000000-0000-0000-0000-000000000002'' WHERE user_id=''e0000000-0000-0000-0000-000000000004'' AND company_id='''||C1||''''), 'rows:1');

  -- erp_users: staff-only boundary + profile tampering
  PERFORM t_expect('before: plain staff INSERTs an erp_users row for an arbitrary auth_user_id', t_dml('authenticated', viewr, 'INSERT INTO erp_users (auth_user_id, full_name, email, is_active, company_id) VALUES (''dddddddd-dddd-dddd-dddd-dddddddddddd'',''client taken over'',''cl@t.test'',true,'''||C1||''')'), 'rows:1');
  PERFORM t_expect('before: ... that login is now staff (is_erp_staff)', t_count('authenticated', 'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid, 'SELECT 1 WHERE public.is_erp_staff()'), 'n:1');
  PERFORM t_expect('before: plain staff edits a colleague full_name', t_dml('authenticated', viewr, 'UPDATE erp_users SET full_name=''pwned'' WHERE id=''e0000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('before: plain staff deactivates a colleague', t_dml('authenticated', viewr, 'UPDATE erp_users SET is_active=false WHERE id=''e0000000-0000-0000-0000-000000000011'''), 'rows:1');
  PERFORM t_expect('before: plain staff changes a colleague email', t_dml('authenticated', viewr, 'UPDATE erp_users SET email=''x@evil.test'' WHERE id=''e0000000-0000-0000-0000-000000000001'''), 'rows:1');
  PERFORM t_expect('before: plain staff changes a colleague auth_user_id', t_dml('authenticated', viewr, 'UPDATE erp_users SET auth_user_id=''eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'' WHERE id=''e0000000-0000-0000-0000-000000000011'''), 'rows:1');
  PERFORM t_expect('before: user changes OWN company_id', t_dml('authenticated', viewr, 'UPDATE erp_users SET company_id='''||C2||''' WHERE auth_user_id='''||viewr||''''), 'rows:1');

  -- erp_roles
  PERFORM t_expect('before: client-shaped login reads all role definitions', t_count('authenticated', clnt, 'SELECT 1 FROM erp_roles'), 'n:9');
  PERFORM t_expect('before: Office Admin (admin:roles) creates a role carrying admin:companies', t_dml('authenticated', offc, 'INSERT INTO erp_roles (id, name, company_id, is_system, permissions) VALUES (''a0000000-0000-0000-0000-0000000000f1'',''Sneaky'','''||C1||''',false,''{"admin:companies":true}'')'), 'rows:1');
  PERFORM t_expect('before: Office Admin edits a custom role to gain admin:companies', t_dml('authenticated', offc, 'UPDATE erp_roles SET permissions=''{"admin:companies":true,"ops:work-orders:read":true}'' WHERE id=''a0000000-0000-0000-0000-000000000006'''), 'rows:1');
  PERFORM t_expect('before: ... then assigned (ucr) to ops = platform super admin', t_dml('authenticated', cadm, 'UPDATE erp_user_company_roles SET role_id=''a0000000-0000-0000-0000-000000000006'' WHERE user_id=''e0000000-0000-0000-0000-000000000001'' AND company_id='''||C1||''''), 'rows:1');
  PERFORM t_expect('before: ops is now a platform super admin', t_count('authenticated', ops, 'SELECT 1 WHERE public.is_super_admin()'), 'n:1');
END $$;
ROLLBACK;