-- AFTER the migration: full role x operation x scope matrix for public.jobs. One transaction, rolled back.
-- Order: reads, inserts, updates, deletes (earlier writes must not change later counts).
BEGIN;
DO $$
DECLARE
  ops   uuid := '11111111-1111-1111-1111-111111111111';  -- operations_tech, C1
  viewr uuid := '22222222-2222-2222-2222-222222222222';  -- viewer, C1
  cadm  uuid := '33333333-3333-3333-3333-333333333333';  -- company_admin, C1
  sup   uuid := '44444444-4444-4444-4444-444444444444';  -- super_admin, C1 + C2
  offc  uuid := '55555555-5555-5555-5555-555555555555';  -- Office Admin, C1 (live atoms: read only on work orders)
  gone  uuid := '66666666-6666-6666-6666-666666666666';  -- inactive staff
  ops2  uuid := '77777777-7777-7777-7777-777777777777';  -- operations_tech, C2
  fin   uuid := '88888888-8888-8888-8888-888888888888';  -- finance_manager, C1
  sal   uuid := '99999999-9999-9999-9999-999999999999';  -- sales_rep, C1
  cadm2 uuid := '10101010-1010-1010-1010-101010101010';  -- company_admin, C2
  mixed uuid := '11111111-aaaa-1111-1111-111111111111';  -- company_admin C1 + operations_tech C2
  clnt  uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';  -- client-shaped: no erp_users row
  C1 text := 'c1000000-0000-0000-0000-000000000001'; C2 text := 'c2000000-0000-0000-0000-000000000002';
  B1 text := 'b1000000-0000-0000-0000-000000000001'; B2 text := 'b2000000-0000-0000-0000-000000000002';
  B3 text := 'b1000000-0000-0000-0000-000000000003'; B4 text := 'b1000000-0000-0000-0000-000000000004';
  B5 text := 'b1000000-0000-0000-0000-000000000005'; B6 text := 'b1000000-0000-0000-0000-000000000006';
  B7 text := 'b2000000-0000-0000-0000-000000000007';
BEGIN
  -- ── structure ──
  PERFORM t_expect('policies: 4 d0c_jobs policies', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname LIKE 'd0c_jobs_%'), '4');
  PERFORM t_expect('policies: legacy open policy gone', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname='authenticated users full access'), '0');
  PERFORM t_expect('policies: no permissive policy with qual true', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND permissive='PERMISSIVE' AND (qual='true' OR with_check='true')), '0');
  PERFORM t_expect('policies: D0a restrictive pair kept', (SELECT count(*)::text FROM pg_policies WHERE tablename='jobs' AND policyname IN ('d0_staff_only','d0_no_anon')), '2');

  -- ── SELECT: company scope + ops:work-orders:read ──
  PERFORM t_expect('sel ops C1 sees only C1', t_count('authenticated', ops, 'SELECT 1 FROM jobs'), 'n:5');
  PERFORM t_expect('sel ops C1 cannot see C2 job', t_count('authenticated', ops, 'SELECT 1 FROM jobs WHERE company_id='''||C2||''''), 'n:0');
  PERFORM t_expect('sel ops C1 cannot fetch C2 job by id', t_count('authenticated', ops, 'SELECT 1 FROM jobs WHERE id='''||B2||''''), 'n:0');
  PERFORM t_expect('sel ops C2 sees only C2', t_count('authenticated', ops2, 'SELECT 1 FROM jobs'), 'n:2');
  PERFORM t_expect('sel ops C2 cannot see C1 job', t_count('authenticated', ops2, 'SELECT 1 FROM jobs WHERE id='''||B1||''''), 'n:0');
  PERFORM t_expect('sel viewer C1', t_count('authenticated', viewr, 'SELECT 1 FROM jobs'), 'n:5');
  PERFORM t_expect('sel company_admin C1', t_count('authenticated', cadm, 'SELECT 1 FROM jobs'), 'n:5');
  PERFORM t_expect('sel company_admin C2 sees C2 only', t_count('authenticated', cadm2, 'SELECT 1 FROM jobs'), 'n:2');
  PERFORM t_expect('sel super admin sees C1+C2', t_count('authenticated', sup, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('sel Office Admin (work-orders read) C1', t_count('authenticated', offc, 'SELECT 1 FROM jobs'), 'n:5');
  PERFORM t_expect('sel mixed user sees C1+C2', t_count('authenticated', mixed, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('sel finance_manager has no work-orders atom', t_count('authenticated', fin, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('sel sales_rep has no work-orders atom', t_count('authenticated', sal, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('sel inactive staff sees nothing', t_count('authenticated', gone, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('sel client-shaped user sees nothing', t_count('authenticated', clnt, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('sel anon sees nothing', t_count('anon', NULL, 'SELECT 1 FROM jobs'), 'n:0');
  PERFORM t_expect('sel service_role bypasses RLS', t_count('service_role', NULL, 'SELECT 1 FROM jobs'), 'n:7');
  PERFORM t_expect('sel commercial columns visible to read-role (flag)', t_count('authenticated', viewr, 'SELECT quoted_ttd, costing_notes FROM jobs WHERE quoted_ttd IS NOT NULL'), 'n:5');
  PERFORM t_expect('sel D0a storage policy subquery still works for ops', t_count('authenticated', ops, 'SELECT 1 FROM jobs j WHERE j.id='''||B1||''' AND j.company_id='''||C1||''''), 'n:1');

  -- ── INSERT: company membership + ops:work-orders:write ──
  PERFORM t_expect('ins ops into own company', t_dml('authenticated', ops, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-901'') RETURNING id'), 'rows:1');
  PERFORM t_expect('ins ops into other company denied', t_dml('authenticated', ops, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C2||''',''WO-902'')'), 'err:42501');
  PERFORM t_expect('ins ops C2 into C1 denied', t_dml('authenticated', ops2, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-903'')'), 'err:42501');
  PERFORM t_expect('ins company_admin own company', t_dml('authenticated', cadm, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-904'')'), 'rows:1');
  PERFORM t_expect('ins super admin into C2 (member)', t_dml('authenticated', sup, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C2||''',''WO-905'')'), 'rows:1');
  PERFORM t_expect('ins viewer denied', t_dml('authenticated', viewr, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-906'')'), 'err:42501');
  PERFORM t_expect('ins Office Admin (read only) denied', t_dml('authenticated', offc, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-907'')'), 'err:42501');
  PERFORM t_expect('ins finance_manager denied', t_dml('authenticated', fin, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-908'')'), 'err:42501');
  PERFORM t_expect('ins sales_rep denied', t_dml('authenticated', sal, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-909'')'), 'err:42501');
  PERFORM t_expect('ins inactive staff denied', t_dml('authenticated', gone, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-910'')'), 'err:42501');
  PERFORM t_expect('ins client-shaped denied', t_dml('authenticated', clnt, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-911'')'), 'err:42501');
  PERFORM t_expect('ins anon denied', t_dml('anon', NULL, 'INSERT INTO jobs (company_id, job_no) VALUES ('''||C1||''',''WO-912'')'), 'err:42501');

  -- ── UPDATE: USING (company + write atom), WITH CHECK, company_id immutable ──
  PERFORM t_expect('upd ops own-company job', t_dml('authenticated', ops, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:1');
  PERFORM t_expect('upd ops cannot touch C2 job', t_dml('authenticated', ops, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B2||''''), 'rows:0');
  PERFORM t_expect('upd ops C2 cannot touch C1 job', t_dml('authenticated', ops2, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd company_admin own company', t_dml('authenticated', cadm, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B3||''''), 'rows:1');
  PERFORM t_expect('upd company_admin C1 cannot touch C2', t_dml('authenticated', cadm, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B7||''''), 'rows:0');
  PERFORM t_expect('upd super admin C2 job', t_dml('authenticated', sup, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B7||''''), 'rows:1');
  PERFORM t_expect('upd viewer denied', t_dml('authenticated', viewr, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd Office Admin (read only) denied', t_dml('authenticated', offc, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd finance_manager denied', t_dml('authenticated', fin, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd sales_rep denied', t_dml('authenticated', sal, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd inactive staff denied', t_dml('authenticated', gone, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd client-shaped denied', t_dml('authenticated', clnt, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  PERFORM t_expect('upd anon denied', t_dml('anon', NULL, 'UPDATE jobs SET customer=''edited'' WHERE id='''||B1||''''), 'rows:0');
  -- unqualified statements (no WHERE, so the SELECT policy is not consulted): only the UPDATE policy limits the rows touched
  PERFORM t_expect('upd unqualified: ops touches only its own company rows (5 fixtures + 2 inserted)', t_dml('authenticated', ops, 'UPDATE jobs SET customer=''bulk'''), 'rows:7');
  PERFORM t_expect('upd unqualified: ops C2 touches only C2 rows (2 fixtures + 1 inserted)', t_dml('authenticated', ops2, 'UPDATE jobs SET customer=''bulk2'''), 'rows:3');
  PERFORM t_expect('upd unqualified: viewer touches nothing', t_dml('authenticated', viewr, 'UPDATE jobs SET customer=''bulk3'''), 'rows:0');
  PERFORM t_expect('upd unqualified: C2 jobs keep their values', t_count('service_role', NULL, 'SELECT 1 FROM jobs WHERE customer=''bulk'' AND company_id='''||C2||''''), 'n:0');
  -- company_id cannot move: single-company writer (policy WITH CHECK), multi-company writer (trigger)
  PERFORM t_expect('upd ops cannot move job to a company it is not in', t_dml('authenticated', ops, 'UPDATE jobs SET company_id='''||C2||''' WHERE id='''||B5||''''), 'err:42501');
  PERFORM t_expect('upd super (member of both) cannot move job between companies', t_dml('authenticated', sup, 'UPDATE jobs SET company_id='''||C2||''' WHERE id='''||B5||''''), 'err:42501');
  PERFORM t_expect('upd mixed user cannot move job between companies', t_dml('authenticated', mixed, 'UPDATE jobs SET company_id='''||C2||''' WHERE id='''||B5||''''), 'err:42501');
  PERFORM t_expect('upd same-company company_id write is a no-op and allowed', t_dml('authenticated', ops, 'UPDATE jobs SET company_id='''||C1||''' WHERE id='''||B5||''''), 'rows:1');
  -- WITH CHECK on its own (trigger off): a C1-only writer still cannot push a row into C2
  ALTER TABLE public.jobs DISABLE TRIGGER d0c_jobs_lock_company;
  PERFORM t_expect('upd WITH CHECK alone blocks move to foreign company', t_dml('authenticated', ops, 'UPDATE jobs SET company_id='''||C2||''' WHERE id='''||B5||''''), 'err:42501');
  PERFORM t_expect('upd WITH CHECK alone blocks unqualified bulk move', t_dml('authenticated', ops, 'UPDATE jobs SET company_id='''||C2||''''), 'err:42501');
  ALTER TABLE public.jobs ENABLE TRIGGER d0c_jobs_lock_company;
  PERFORM t_expect('upd trigger re-enabled: still blocked for multi-company user', t_dml('authenticated', sup, 'UPDATE jobs SET company_id='''||C2||''' WHERE id='''||B5||''''), 'err:42501');

  -- ── DELETE: company membership + is_company_admin(company_id) ──
  PERFORM t_expect('del ops (not admin) denied', t_dml('authenticated', ops, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del viewer denied', t_dml('authenticated', viewr, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del Office Admin denied', t_dml('authenticated', offc, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del finance_manager denied', t_dml('authenticated', fin, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del sales_rep denied', t_dml('authenticated', sal, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del inactive staff denied', t_dml('authenticated', gone, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del client-shaped denied', t_dml('authenticated', clnt, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del anon denied', t_dml('anon', NULL, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del ops C2 cannot delete C1 job', t_dml('authenticated', ops2, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del company_admin C2 cannot delete C1 job', t_dml('authenticated', cadm2, 'DELETE FROM jobs WHERE id='''||B6||''''), 'rows:0');
  PERFORM t_expect('del company_admin C1 cannot delete C2 job', t_dml('authenticated', cadm, 'DELETE FROM jobs WHERE id='''||B7||''''), 'rows:0');
  PERFORM t_expect('del mixed user: admin in C1 only, so C2 job denied', t_dml('authenticated', mixed, 'DELETE FROM jobs WHERE id='''||B7||''''), 'rows:0');
  PERFORM t_expect('del mixed user: C1 job allowed (admin there)', t_dml('authenticated', mixed, 'DELETE FROM jobs WHERE id='''||B4||''''), 'rows:1');
  PERFORM t_expect('del company_admin own company', t_dml('authenticated', cadm, 'DELETE FROM jobs WHERE id='''||B3||''''), 'rows:1');
  PERFORM t_expect('del super admin C1 job', t_dml('authenticated', sup, 'DELETE FROM jobs WHERE id='''||B5||''''), 'rows:1');
  PERFORM t_expect('del super admin C2 job (member)', t_dml('authenticated', sup, 'DELETE FROM jobs WHERE id='''||B7||''''), 'rows:1');
  PERFORM t_expect('del job really gone for service_role', t_count('service_role', NULL, 'SELECT 1 FROM jobs WHERE id IN ('''||B3||''','''||B4||''','''||B5||''','''||B7||''')'), 'n:0');
  PERFORM t_expect('del untouched job survives all denied deletes', t_count('service_role', NULL, 'SELECT 1 FROM jobs WHERE id='''||B6||''''), 'n:1');
END $$;
ROLLBACK;
