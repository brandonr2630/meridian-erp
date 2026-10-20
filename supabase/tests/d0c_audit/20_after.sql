-- AFTER the D0c audit migration: full role x operation x scope matrix. One transaction, rolled back.
-- Fixtures: A1 = job b1 (C1), A2 = job b2 (C2), A3 = job_id NULL (service-role style staff.access row).
BEGIN;
DO $$
DECLARE
  ops1    uuid := '11111111-1111-1111-1111-111111111111';  -- operations_tech, C1
  viewer  uuid := '22222222-2222-2222-2222-222222222222';  -- viewer, C1
  cadm    uuid := '33333333-3333-3333-3333-333333333333';  -- company_admin, C1
  sup     uuid := '44444444-4444-4444-4444-444444444444';  -- super_admin, C1 + C2
  office  uuid := '55555555-5555-5555-5555-555555555555';  -- Office Admin, C1
  removed uuid := '66666666-6666-6666-6666-666666666666';  -- inactive staff
  ops2    uuid := '77777777-7777-7777-7777-777777777777';  -- operations_tech, C2
  fin     uuid := 'f0000000-0000-0000-0000-0000000000f1';  -- finance_manager, C1
  sales   uuid := '5a1e5000-0000-0000-0000-000000000001';  -- sales_rep, C1
  client  uuid := '99999999-9999-9999-9999-999999999999';  -- no staff row
  b1 text := 'b1000000-0000-0000-0000-000000000001';
  b2 text := 'b2000000-0000-0000-0000-000000000002';
  u uuid;
  nm text;
  who uuid[]; names text[];
  i int;
  ins text;
BEGIN
  -- ── policy inventory ────────────────────────────────────────────────────
  PERFORM t_expect('legacy policy dropped', (SELECT count(*)::text FROM pg_policies WHERE tablename='job_audit_log' AND policyname='authenticated users full access'), '0');
  PERFORM t_expect('no permissive policy with qual true', (SELECT count(*)::text FROM pg_policies WHERE tablename='job_audit_log' AND permissive='PERMISSIVE' AND (qual='true' OR with_check='true')), '0');
  PERFORM t_expect('d0c policies present', (SELECT string_agg(policyname || ':' || cmd, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='job_audit_log' AND policyname LIKE 'd0c\_%'), 'd0c_job_audit_log_insert:INSERT,d0c_job_audit_log_select:SELECT');
  PERFORM t_expect('D0a restrictive policies untouched', (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies WHERE tablename='job_audit_log' AND permissive='RESTRICTIVE'), 'd0_no_anon,d0_staff_only');
  PERFORM t_expect('priv: authenticated keeps SELECT', has_table_privilege('authenticated','public.job_audit_log','SELECT')::text, 'true');
  PERFORM t_expect('priv: authenticated keeps INSERT', has_table_privilege('authenticated','public.job_audit_log','INSERT')::text, 'true');
  PERFORM t_expect('priv: authenticated has no UPDATE', has_table_privilege('authenticated','public.job_audit_log','UPDATE')::text, 'false');
  PERFORM t_expect('priv: authenticated has no DELETE', has_table_privilege('authenticated','public.job_audit_log','DELETE')::text, 'false');
  PERFORM t_expect('priv: authenticated has no TRUNCATE', has_table_privilege('authenticated','public.job_audit_log','TRUNCATE')::text, 'false');
  PERFORM t_expect('priv: anon has no TRUNCATE', has_table_privilege('anon','public.job_audit_log','TRUNCATE')::text, 'false');
  PERFORM t_expect('priv: service_role keeps UPDATE', has_table_privilege('service_role','public.job_audit_log','UPDATE')::text, 'true');

  -- ── SELECT matrix (3 rows exist: A1 C1 job, A2 C2 job, A3 NULL job) ───────
  PERFORM t_expect('select: operations_tech C1 sees only its company job rows', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log'), 'n:1');
  PERFORM t_expect('select: operations_tech C1 sees A1', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log WHERE id = ''d1000000-0000-0000-0000-000000000001'''), 'n:1');
  PERFORM t_expect('select: operations_tech C1 cannot see C2 row A2', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log WHERE id = ''d2000000-0000-0000-0000-000000000002'''), 'n:0');
  PERFORM t_expect('select: operations_tech C1 cannot see NULL-job row A3', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log WHERE id = ''d3000000-0000-0000-0000-000000000003'''), 'n:0');
  PERFORM t_expect('select: operations_tech C2 sees only A2', t_count('authenticated', ops2, 'SELECT 1 FROM job_audit_log WHERE id = ''d2000000-0000-0000-0000-000000000002'''), 'n:1');
  PERFORM t_expect('select: operations_tech C2 total', t_count('authenticated', ops2, 'SELECT 1 FROM job_audit_log'), 'n:1');
  PERFORM t_expect('select: viewer C1 (read atom) sees A1 only', t_count('authenticated', viewer, 'SELECT 1 FROM job_audit_log'), 'n:1');
  PERFORM t_expect('select: company_admin C1 sees A1 only (not NULL-job rows)', t_count('authenticated', cadm, 'SELECT 1 FROM job_audit_log'), 'n:1');
  PERFORM t_expect('select: Office Admin C1 (read atom) sees A1 only', t_count('authenticated', office, 'SELECT 1 FROM job_audit_log'), 'n:1');
  PERFORM t_expect('select: super_admin multi-company sees A1, A2 and the NULL-job row', t_count('authenticated', sup, 'SELECT 1 FROM job_audit_log'), 'n:3');
  PERFORM t_expect('select: super_admin sees NULL-job row', t_count('authenticated', sup, 'SELECT 1 FROM job_audit_log WHERE job_id IS NULL'), 'n:1');
  PERFORM t_expect('select: finance_manager (no work-order atom) sees nothing', t_count('authenticated', fin, 'SELECT 1 FROM job_audit_log'), 'n:0');
  PERFORM t_expect('select: sales_rep (no work-order atom) sees nothing', t_count('authenticated', sales, 'SELECT 1 FROM job_audit_log'), 'n:0');
  PERFORM t_expect('select: removed (inactive) staff sees nothing', t_count('authenticated', removed, 'SELECT 1 FROM job_audit_log'), 'n:0');
  PERFORM t_expect('select: client without staff row sees nothing', t_count('authenticated', client, 'SELECT 1 FROM job_audit_log'), 'n:0');
  PERFORM t_expect('select: anon sees nothing', t_count('anon', NULL, 'SELECT 1 FROM job_audit_log'), 'n:0');

  -- ── INSERT matrix ─────────────────────────────────────────────────────────
  -- allowed: holders of ops:work-orders:write, own user_id, own-company job
  PERFORM t_expect('insert: operations_tech C1 own job, own uid',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, job_no, user_id, username, action_type, description) VALUES (''' || b1 || ''',''WO-001'',''' || ops1 || ''',''ops C1'',''job_saved'',''x'')'), 'rows:1');
  PERFORM t_expect('insert: operations_tech C1 with RETURNING (the ERP sends return=representation)',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || ops1 || ''',''job_deleted'') RETURNING id'), 'rows:1');
  PERFORM t_expect('insert: company_admin C1 own job',
    t_dml('authenticated', cadm, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || cadm || ''',''job_deleted'')'), 'rows:1');
  PERFORM t_expect('insert: super_admin on C1 job',
    t_dml('authenticated', sup, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || sup || ''',''job_saved'')'), 'rows:1');
  PERFORM t_expect('insert: super_admin multi-company on C2 job',
    t_dml('authenticated', sup, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''',''' || sup || ''',''job_saved'')'), 'rows:1');
  PERFORM t_expect('insert: operations_tech C2 own job',
    t_dml('authenticated', ops2, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''',''' || ops2 || ''',''job_saved'')'), 'rows:1');
  -- cross-company
  PERFORM t_expect('insert: operations_tech C1 on C2 job denied',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''',''' || ops1 || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: operations_tech C2 on C1 job denied',
    t_dml('authenticated', ops2, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || ops2 || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: company_admin C1 on C2 job denied',
    t_dml('authenticated', cadm, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b2 || ''',''' || cadm || ''',''job_saved'')'), 'err:42501');
  -- no forging
  PERFORM t_expect('insert: row stamped with another user_id denied',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || cadm || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: NULL user_id denied',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, action_type) VALUES (''' || b1 || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: NULL job_id denied for authenticated (service role only)',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (user_id, action_type) VALUES (''' || ops1 || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: NULL job_id denied for super_admin too',
    t_dml('authenticated', sup, 'INSERT INTO job_audit_log (user_id, action_type) VALUES (''' || sup || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: forged staff.access.* action denied (writer)',
    t_dml('authenticated', ops1, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || ops1 || ''',''staff.access.remove'')'), 'err:42501');
  PERFORM t_expect('insert: forged staff.access.* action denied (super_admin)',
    t_dml('authenticated', sup, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || sup || ''',''staff.access.deactivate'')'), 'err:42501');
  -- atom on write
  PERFORM t_expect('insert: viewer (read only) denied',
    t_dml('authenticated', viewer, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || viewer || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: Office Admin (work-orders read only) denied',
    t_dml('authenticated', office, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || office || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: finance_manager denied',
    t_dml('authenticated', fin, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || fin || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: sales_rep denied',
    t_dml('authenticated', sales, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || sales || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: removed (inactive) staff denied',
    t_dml('authenticated', removed, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || removed || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: client without staff row denied',
    t_dml('authenticated', client, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',''' || client || ''',''job_saved'')'), 'err:42501');
  PERFORM t_expect('insert: anon denied',
    t_dml('anon', NULL, 'INSERT INTO job_audit_log (job_id, user_id, action_type) VALUES (''' || b1 || ''',NULL,''job_saved'')'), 'err:42501');

  -- the inserts above that succeeded: 6 new rows (ops1 x2, cadm, sup x2, ops2). Counts now: C1 job rows 1+2+1+1=5, C2 job rows 1+1+1=3, NULL 1.
  PERFORM t_expect('select after inserts: operations_tech C1 sees its 5 C1 rows', t_count('authenticated', ops1, 'SELECT 1 FROM job_audit_log'), 'n:5');
  PERFORM t_expect('select after inserts: operations_tech C2 sees its 3 C2 rows', t_count('authenticated', ops2, 'SELECT 1 FROM job_audit_log'), 'n:3');
  PERFORM t_expect('select after inserts: super_admin sees all 9', t_count('authenticated', sup, 'SELECT 1 FROM job_audit_log'), 'n:9');
  PERFORM t_expect('rejected inserts left nothing behind', (SELECT count(*)::text FROM job_audit_log), '9');

  -- ── UPDATE / DELETE: append-only for every authenticated role ──────────────
  names := ARRAY['ops1','viewer','cadm','sup','office','removed','ops2','fin','sales','client'];
  who   := ARRAY[ops1, viewer, cadm, sup, office, removed, ops2, fin, sales, client];
  FOR i IN 1 .. array_length(who, 1) LOOP
    PERFORM t_expect('update: ' || names[i] || ' denied', t_dml('authenticated', who[i], 'UPDATE job_audit_log SET description = ''tampered'''), 'err:42501');
    PERFORM t_expect('delete: ' || names[i] || ' denied', t_dml('authenticated', who[i], 'DELETE FROM job_audit_log'), 'err:42501');
  END LOOP;
  PERFORM t_expect('update: anon touches 0 rows (D0a d0_no_anon)', t_dml('anon', NULL, 'UPDATE job_audit_log SET description = ''tampered'''), 'rows:0');
  PERFORM t_expect('delete: anon touches 0 rows (D0a d0_no_anon)', t_dml('anon', NULL, 'DELETE FROM job_audit_log'), 'rows:0');
  PERFORM t_expect('update/delete changed nothing', (SELECT count(*)::text FROM job_audit_log WHERE description = 'tampered'), '0');
  PERFORM t_expect('table not truncatable by authenticated', t_dml('authenticated', sup, 'TRUNCATE job_audit_log'), 'err:42501');

  -- RLS layer on its own (grants restored inside this rolled-back transaction): still no UPDATE/DELETE row for anyone
  GRANT UPDATE, DELETE ON public.job_audit_log TO authenticated;
  FOR i IN 1 .. array_length(who, 1) LOOP
    PERFORM t_expect('rls-only update: ' || names[i] || ' touches 0 rows', t_dml('authenticated', who[i], 'UPDATE job_audit_log SET description = ''tampered'''), 'rows:0');
    PERFORM t_expect('rls-only delete: ' || names[i] || ' touches 0 rows', t_dml('authenticated', who[i], 'DELETE FROM job_audit_log'), 'rows:0');
  END LOOP;
  PERFORM t_expect('rls-only: nothing was tampered with or deleted', (SELECT count(*)::text FROM job_audit_log WHERE description IS DISTINCT FROM 'tampered'), '9');
  REVOKE UPDATE, DELETE ON public.job_audit_log FROM authenticated;

  -- ── service role / owner paths are unaffected ──────────────────────────────
  SET LOCAL ROLE service_role;
  INSERT INTO job_audit_log (job_id, user_id, action_type, description, metadata) VALUES (NULL, '44444444-4444-4444-4444-444444444444', 'staff.access.activate', 'activate x: ok', '{"outcome":"ok"}');
  RESET ROLE;
  PERFORM t_expect('service role can write job_id NULL staff.access rows (edge function path)', (SELECT count(*)::text FROM job_audit_log WHERE action_type = 'staff.access.activate'), '1');
  PERFORM t_expect('select: super_admin sees the new service-role row', t_count('authenticated', sup, 'SELECT 1 FROM job_audit_log WHERE job_id IS NULL'), 'n:2');
  PERFORM t_expect('select: company_admin still does not', t_count('authenticated', cadm, 'SELECT 1 FROM job_audit_log WHERE job_id IS NULL'), 'n:0');

  -- ── job delete flow: audit row is written first, then the job is deleted; FK SET NULL still works under the new policies ──
  PERFORM t_expect('delete flow: company_admin writes job_deleted audit row first',
    t_dml('authenticated', cadm, 'INSERT INTO job_audit_log (job_id, job_no, user_id, action_type) VALUES (''' || b1 || ''',''WO-001'',''' || cadm || ''',''job_deleted'')'), 'rows:1');
  PERFORM t_expect('delete flow: then deletes the job', t_dml('authenticated', cadm, 'DELETE FROM jobs WHERE id = ''' || b1 || ''''), 'rows:1');
  PERFORM t_expect('delete flow: audit rows survive with job_id NULL (FK SET NULL)', (SELECT count(*)::text FROM job_audit_log WHERE job_no = 'WO-001' AND job_id IS NULL AND action_type = 'job_deleted'), '1');
  PERFORM t_expect('delete flow: orphaned audit rows now visible to super_admin only',
    t_count('authenticated', sup, 'SELECT 1 FROM job_audit_log WHERE action_type = ''job_deleted'' AND job_id IS NULL'), 'n:3');
  PERFORM t_expect('delete flow: and not to the company_admin',
    t_count('authenticated', cadm, 'SELECT 1 FROM job_audit_log WHERE action_type = ''job_deleted'' AND job_id IS NULL'), 'n:0');
  PERFORM t_expect('delete flow: writing the audit row AFTER the job is gone is rejected (why the ERP must await the insert first)',
    t_dml('authenticated', cadm, 'INSERT INTO job_audit_log (job_id, job_no, user_id, action_type) VALUES (''' || b1 || ''',''WO-001'',''' || cadm || ''',''job_deleted'')'), 'err:42501');
END $$;
ROLLBACK;
